-- lvim-calendar.sources: the pluggable entry-source registry — THE seam future org-/markdown-note
-- systems plug into. The calendar core never knows about org or markdown: a source only promises
-- `get(range, done)` returning entries for an inclusive date range (batched — one call per visible
-- range, NEVER per day), plus optional `on_open` (custom entry jump) and `on_create` (new entry on
-- a day). Results are cached per (source, month) and every async reply is GENERATION-GUARDED: a
-- `refresh()` bumps the source's generation, so a stale `done()` that lands afterwards is dropped
-- instead of resurrecting old entries (the lightbulb/cmp cancellation discipline).
--
-- Built-ins registered by setup(): `holidays` (decoration-only fixed/recurring dates from
-- config.holidays) and `dates` (vim-diary-style user dates from config.dates) — both read the live
-- config on every fetch, and double as reference implementations for external sources.
--
---@module "lvim-calendar.sources"

local config = require("lvim-calendar.config")
local model = require("lvim-calendar.model")

local M = {}

---@class LvimCalendarEntry
---@field date string    ISO "YYYY-MM-DD"
---@field title string
---@field time? string   "HH:MM" — sorts entries within a day, shown in the agenda
---@field file? string   jump target of the default agenda open
---@field line? integer
---@field mark? string   per-entry day-cell mark override (single-width glyph)
---@field hl? string     per-entry highlight-group override for the day mark
---@field source? string filled in by the registry — the owning source name

---@class LvimCalendarSource
---@field name string     unique id
---@field icon? string    lead glyph (agenda rows, chooser); single-width Nerd Font
---@field accent? string  lvim-utils palette color NAME (default day tint + agenda lead box)
---@field get fun(range: { from: string, to: string }, done: fun(entries: LvimCalendarEntry[])): LvimCalendarEntry[]?
---@field on_open? fun(entry: LvimCalendarEntry)   custom entry jump (default: edit file/line)
---@field on_create? fun(date: string)             create a new entry on a day (the `i` key)
---@field hl_group? string  filled in by the registry — the source's mark highlight group

---@type LvimCalendarSource[]  registration order (drives mark precedence: first registered wins)
local sources = {}
---@type table<string, LvimCalendarSource>
local by_name = {}
---@type table<string, table<string, LvimCalendarEntry[]>>  source name → "YYYY-MM" → entries of that month
local cache = {}
---@type table<string, integer>  source name → generation (bumped by refresh; stale done() drops)
local gen = {}
---@type table<string, boolean>  "<source>|YYYY-MM" in-flight markers (no duplicate fetches)
local pending = {}
---@type (fun())[]  repaint subscribers (the open panel) — fired when async results/refresh land
local listeners = {}

--- Subscribe to cache updates (async results landing, refresh, source registration). Returns an
--- unsubscribe function; the panel subscribes while open.
---@param fn fun()
---@return fun()
function M.on_update(fn)
    listeners[#listeners + 1] = fn
    return function()
        for i, f in ipairs(listeners) do
            if f == fn then
                table.remove(listeners, i)
                return
            end
        end
    end
end

--- Fire every update listener (scheduled — a source's done() may run in a fast event context).
local function notify()
    vim.schedule(function()
        for _, fn in ipairs(listeners) do
            pcall(fn)
        end
    end)
end

--- The month keys ("YYYY-MM") an inclusive ISO range spans.
---@param range { from: string, to: string }
---@return string[]
local function month_keys(range)
    local from = model.from_string(range.from)
    local to = model.from_string(range.to)
    local out = {}
    if not from or not to or model.cmp(from, to) > 0 then
        return out
    end
    local cur = { y = from.y, m = from.m, d = 1 }
    while cur.y < to.y or (cur.y == to.y and cur.m <= to.m) do
        out[#out + 1] = string.format("%04d-%02d", cur.y, cur.m)
        cur = model.shift_months(cur, 1)
    end
    return out
end

--- Store a fetch result: bucket the entries per month INSIDE the fetched range (months with no
--- entries get an explicit {} so they count as cached — an empty month is an answer, not a miss),
--- normalise each entry, and clear the in-flight markers.
---@param src LvimCalendarSource
---@param range { from: string, to: string }
---@param entries LvimCalendarEntry[]
local function store(src, range, entries)
    local keys = month_keys(range)
    cache[src.name] = cache[src.name] or {}
    local buckets = {}
    for _, mk in ipairs(keys) do
        buckets[mk] = {}
        pending[src.name .. "|" .. mk] = nil
    end
    for _, e in ipairs(entries or {}) do
        if type(e) == "table" and type(e.date) == "string" and model.from_string(e.date) then
            local mk = e.date:sub(1, 7)
            if buckets[mk] then
                e.source = src.name
                table.insert(buckets[mk], e)
            end
        end
    end
    for mk, list in pairs(buckets) do
        -- entries of a day sort by time (untimed last), then title — the agenda order
        table.sort(list, function(a, b)
            if a.date ~= b.date then
                return a.date < b.date
            end
            local ta, tb = a.time or "99:99", b.time or "99:99"
            if ta ~= tb then
                return ta < tb
            end
            return (a.title or "") < (b.title or "")
        end)
        cache[src.name][mk] = list
    end
end

--- Fetch the visible range from one source when any of its months is uncached (one batched call
--- per visible range — never per day, never per month). The asked range is EXPANDED to whole-month
--- boundaries first: the cache is per (source, month), so a sub-month ask (entries_for on one day)
--- must never seed a month bucket with only its slice — that bucket would satisfy later full-month
--- reads and silently hide the rest of the month. A sync return is stored immediately; an async
--- `done()` is generation-guarded and triggers a repaint via the listeners.
---@param src LvimCalendarSource
---@param range { from: string, to: string }
local function fetch(src, range)
    local keys = month_keys(range)
    if #keys == 0 then
        return
    end
    -- whole-month expansion: first day of the first month .. last day of the last month
    local fy, fm = keys[1]:match("^(%d+)-(%d+)$")
    local ly, lm = keys[#keys]:match("^(%d+)-(%d+)$")
    range = {
        from = string.format("%s-%s-01", fy, fm),
        to = string.format("%s-%s-%02d", ly, lm, model.days_in_month(tonumber(ly) or 0, tonumber(lm) or 1)),
    }
    local monthly = cache[src.name] or {}
    local miss = false
    for _, mk in ipairs(keys) do
        if monthly[mk] == nil and not pending[src.name .. "|" .. mk] then
            miss = true
        end
    end
    if not miss then
        return
    end
    for _, mk in ipairs(keys) do
        if monthly[mk] == nil then
            pending[src.name .. "|" .. mk] = true
        end
    end
    local g = gen[src.name]
    local done_called = false
    local ok, res = pcall(src.get, range, function(entries)
        -- async completion: drop a reply from a superseded generation (refresh ran meanwhile)
        done_called = true
        if gen[src.name] ~= g then
            return
        end
        store(src, range, entries or {})
        notify()
    end)
    if not ok then
        -- a crashing source must not leave permanent in-flight markers (it would never be re-asked)
        for _, mk in ipairs(keys) do
            pending[src.name .. "|" .. mk] = nil
        end
        vim.schedule(function()
            vim.notify("lvim-calendar: source '" .. src.name .. "' failed: " .. tostring(res), vim.log.levels.WARN)
        end)
        return
    end
    if type(res) == "table" and not done_called then
        store(src, range, res)
    elseif not done_called then
        -- The source went async (or returned nothing without calling done): its months are now flagged
        -- in-flight. Arm a one-shot timeout so a `done()` that never lands cannot wedge them as "pending"
        -- forever. On expiry, if this generation is still current and the markers are still set, clear them
        -- (the next fetch re-asks) and warn once. The pending map is the plugin's own bookkeeping, so the
        -- plugin owns its expiry — no fighting the source.
        local timeout = config.source_timeout_ms or 0
        if timeout > 0 then
            vim.defer_fn(function()
                if gen[src.name] ~= g then
                    return -- a refresh() superseded this fetch; its markers were already reset
                end
                local stuck = false
                for _, mk in ipairs(keys) do
                    if pending[src.name .. "|" .. mk] then
                        pending[src.name .. "|" .. mk] = nil
                        stuck = true
                    end
                end
                if stuck then
                    vim.notify_once(
                        ("lvim-calendar: source '%s' did not answer within %dms — will retry"):format(
                            src.name,
                            timeout
                        ),
                        vim.log.levels.WARN
                    )
                end
            end, timeout)
        end
    end
end

-- ── public API ───────────────────────────────────────────────────────────────

--- Register an entry source. Re-registering a name replaces the source and drops its cache.
--- The source's mark highlight group is derived from its accent by lvim-calendar.highlights.
---@param spec LvimCalendarSource
---@return boolean ok
function M.register_source(spec)
    if type(spec) ~= "table" or type(spec.name) ~= "string" or spec.name == "" or type(spec.get) ~= "function" then
        vim.notify("lvim-calendar: register_source needs { name = string, get = function }", vim.log.levels.ERROR)
        return false
    end
    if by_name[spec.name] then
        for i, s in ipairs(sources) do
            if s.name == spec.name then
                table.remove(sources, i)
                break
            end
        end
    end
    spec.accent = spec.accent or "green"
    -- inline require: highlights requires config only, but keep the edge lazy so a bare
    -- `require("lvim-calendar.sources")` in a headless spec never pulls the UI layer
    spec.hl_group = require("lvim-calendar.highlights").source_group(spec.name, spec.accent)
    sources[#sources + 1] = spec
    by_name[spec.name] = spec
    cache[spec.name] = {}
    gen[spec.name] = (gen[spec.name] or 0) + 1
    -- Re-registering over an in-flight fetch bumps the generation, so the old done()/timeout are
    -- dropped WITHOUT clearing this name's pending markers — leaving its months flagged in-flight
    -- forever (fetch's miss check never re-asks). Clear them here, exactly as refresh() does, so the
    -- invariant the timeout early-return relies on holds: every generation bump resets the markers.
    for k in pairs(pending) do
        if k:sub(1, #spec.name + 1) == spec.name .. "|" then
            pending[k] = nil
        end
    end
    notify()
    return true
end

--- The registered sources, in registration order (health, the create-entry chooser).
---@return LvimCalendarSource[]
function M.list()
    return sources
end

--- A registered source by name.
---@param name string
---@return LvimCalendarSource?
function M.get_source(name)
    return by_name[name]
end

--- Drop cached entries (one source, or all) and bump the generation so in-flight replies are
--- discarded. A notes plugin calls this after writing a file; the open panel repaints and re-asks.
---@param name? string
function M.refresh(name)
    for _, src in ipairs(sources) do
        if not name or src.name == name then
            cache[src.name] = {}
            gen[src.name] = (gen[src.name] or 0) + 1
        end
    end
    -- clear the in-flight markers of the refreshed source(s) so the re-ask is not suppressed
    for k in pairs(pending) do
        if not name or k:sub(1, #name + 1) == name .. "|" then
            pending[k] = nil
        end
    end
    notify()
end

--- All cached entries for an inclusive ISO range, merged across sources and sorted by
--- (date, time, title). Triggers ONE batched fetch per source whose cache misses any month of the
--- range; async results land later (subscribe via on_update). Sync sources answer completely on
--- the first call.
---@param range { from: string, to: string }
---@return LvimCalendarEntry[]
function M.collect(range)
    local out = {}
    for _, src in ipairs(sources) do
        fetch(src, range)
        local monthly = cache[src.name] or {}
        for _, mk in ipairs(month_keys(range)) do
            for _, e in ipairs(monthly[mk] or {}) do
                if e.date >= range.from and e.date <= range.to then
                    out[#out + 1] = e
                end
            end
        end
    end
    table.sort(out, function(a, b)
        if a.date ~= b.date then
            return a.date < b.date
        end
        local ta, tb = a.time or "99:99", b.time or "99:99"
        if ta ~= tb then
            return ta < tb
        end
        return (a.title or "") < (b.title or "")
    end)
    return out
end

--- Entries on one day ("YYYY-MM-DD"), across sources, agenda-sorted.
---@param date string
---@return LvimCalendarEntry[]
function M.entries_for(date)
    return M.collect({ from = date, to = date })
end

--- Sorted unique dates carrying at least one entry inside the range (the w/b mark hopping and
--- a notes plugin's "which days have notes" query).
---@param range { from: string, to: string }
---@return string[]
function M.dates_with_entries(range)
    local seen, out = {}, {}
    for _, e in ipairs(M.collect(range)) do
        if not seen[e.date] then
            seen[e.date] = true
            out[#out + 1] = e.date
        end
    end
    return out
end

--- Day decorations for a range: date → `{ mark, hl }` from the FIRST entry (sources in
--- registration order; an entry-level `mark`/`hl` overrides its source's defaults).
---@param range { from: string, to: string }
---@return table<string, { mark: string, hl: string }>
function M.marks_for(range)
    local out = {}
    for _, e in ipairs(M.collect(range)) do
        if not out[e.date] then
            local src = by_name[e.source or ""] or {}
            out[e.date] = {
                mark = e.mark or config.icons.mark,
                hl = e.hl or src.hl_group or "LvimCalendarMark",
            }
        end
    end
    return out
end

--- Cache statistics for :checkhealth — per source: cached month count + generation.
---@return table<string, { months: integer, generation: integer }>
function M.stats()
    local out = {}
    for _, src in ipairs(sources) do
        local n = 0
        for _ in pairs(cache[src.name] or {}) do
            n = n + 1
        end
        out[src.name] = { months = n, generation = gen[src.name] or 0 }
    end
    return out
end

-- ── built-in sources ─────────────────────────────────────────────────────────

--- Expand a config date table (`{ date, title, time?, mark?, hl?, file?, line? }`, positional or
--- keyed) into concrete entries inside `range`. A "MM-DD" date recurs in EVERY year the range
--- touches; "YYYY-MM-DD" is a single occurrence. Feb 29 recurrences simply don't exist in
--- non-leap years (skipped, not shifted).
---@param list table[]
---@param range { from: string, to: string }
---@return LvimCalendarEntry[]
local function expand_config_dates(list, range)
    local from = model.from_string(range.from)
    local to = model.from_string(range.to)
    local out = {}
    if not from or not to then
        return out
    end
    for _, item in ipairs(list or {}) do
        local date = item.date or item[1]
        local title = item.title or item[2] or ""
        if type(date) == "string" then
            local mm, dd = date:match("^(%d%d)-(%d%d)$")
            local dates = {}
            if mm then
                -- recurring: one instance per year of the range (validity checked per year — Feb 29)
                for y = from.y, to.y do
                    local iso = string.format("%04d-%s-%s", y, mm, dd)
                    if model.from_string(iso) then
                        dates[#dates + 1] = iso
                    end
                end
            elseif model.from_string(date) then
                dates[1] = date
            end
            for _, iso in ipairs(dates) do
                if iso >= range.from and iso <= range.to then
                    out[#out + 1] = {
                        date = iso,
                        title = title,
                        time = item.time,
                        mark = item.mark,
                        hl = item.hl,
                        file = item.file,
                        line = item.line,
                    }
                end
            end
        end
    end
    return out
end

--- Register the built-in `holidays` + `dates` sources (called once from setup). Both read the
--- LIVE config tables on every fetch, so a runtime mutation followed by `refresh()` is enough —
--- no re-registration.
function M.setup_builtins()
    M.register_source({
        name = "holidays",
        icon = config.icons.holidays,
        accent = "red",
        get = function(range)
            return expand_config_dates(config.holidays, range)
        end,
    })
    M.register_source({
        name = "dates",
        icon = config.icons.dates,
        accent = "green",
        get = function(range)
            return expand_config_dates(config.dates, range)
        end,
    })
end

return M
