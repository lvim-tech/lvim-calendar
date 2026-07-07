-- lvim-calendar.panel: the ONE calendar window — a lvim-ui.surface consumer (never a raw float).
-- One content block whose provider renders the ACTIVE view (month/quarter/year/agenda) through the
-- shared span renderer; a header of a view filter band (+ the agenda span band) and a ‹ Month
-- Year › / today nav band; a shorthand action footer. The cell cursor is MODULE STATE + repaint —
-- the hardware cursor is hidden by the chassis (FRAME_FT via lvim-utils.cursor), and after every
-- repaint the window cursor is parked on the cell-cursor row so a docked (height-capped) layout
-- scrolls it into view natively.
--
-- Repaint discipline: a plain day move inside the visible month only needs `pan.refresh()`; a
-- month/year/view/span change goes through `st.set_header(...)` — it rebuilds the bands (the nav
-- label + active filters), relayouts (the content HEIGHT changes: 4..6-week months, agenda
-- sections) and re-renders in one pass. All panel keys are bound as frame-wide `cfg.keymaps`
-- closures over the module state, so they work from the bar sectors too and stay live across
-- header swaps.
--
---@module "lvim-calendar.panel"

local api = vim.api
local config = require("lvim-calendar.config")
local model = require("lvim-calendar.model")
local sources = require("lvim-calendar.sources")
local grid = require("lvim-calendar.views.grid")
local view_month = require("lvim-calendar.views.month")
local view_quarter = require("lvim-calendar.views.quarter")
local view_year = require("lvim-calendar.views.year")
local view_agenda = require("lvim-calendar.views.agenda")
local surface = require("lvim-ui.surface")
local filters = require("lvim-ui.filters")
local uilib = require("lvim-ui")

local M = {}

---@type string[]  the `v` cycle order
local VIEW_ORDER = { "month", "quarter", "year", "agenda" }

-- Filter-band hotkeys avoid the taken keys: `q` closes (chassis close_keys) so Quarter gets `Q`;
-- `m` is free in every view; the span group avoids `w` (next mark) and `m` with `W`/`M`.
---@type table[]
local VIEW_BUTTONS = {
    { id = "month", label = "Month", key = "m" },
    { id = "quarter", label = "Quarter", key = "Q" },
    { id = "year", label = "Year", key = "y" },
    { id = "agenda", label = "Agenda", key = "a" },
}
---@type table[]
local SPAN_BUTTONS = {
    { id = "day", label = "Day", key = "d" },
    { id = "week", label = "Week", key = "W" },
    { id = "fortnight", label = "Fortnight", key = "f" },
    { id = "month", label = "Month", key = "M" },
}

---@class LvimCalendarPanelState
---@field st table?                    the live surface state
---@field pan table?                   our content panel (buf/win/refresh)
---@field view string                  active view
---@field layout string?               session-sticky layout override (nil = config.layout)
---@field span string                  active agenda span
---@field cursor LvimCalendarDate      the cell cursor
---@field active integer               active agenda entry index (0 = none)
---@field items LvimCalendarAgendaItem[]  agenda selectables of the LAST render
---@field cursor_row integer           output row of the cell cursor (scroll target)
---@field on_select? fun(date: string) consumer callback (nil = insert into the origin buffer)
---@field unsubscribe? fun()           sources.on_update teardown
local state = {
    st = nil,
    pan = nil,
    view = config.view,
    layout = nil,
    span = config.agenda.span,
    cursor = model.today(),
    active = 0,
    items = {},
    cursor_row = 1,
    on_select = nil,
    unsubscribe = nil,
}

--- Whether the panel is currently open.
---@return boolean
function M.is_open()
    return state.st ~= nil and not state.st._closed
end

-- ── data / build ─────────────────────────────────────────────────────────────

--- The date range the active view displays — the batched sources fetch window.
---@return { from: string, to: string }
local function visible_range()
    local cur = state.cursor
    if state.view == "quarter" then
        local p = model.shift_months(cur, -1)
        local n = model.shift_months(cur, 1)
        return { from = model.month_range(p.y, p.m).from, to = model.month_range(n.y, n.m).to }
    elseif state.view == "year" then
        return { from = string.format("%04d-01-01", cur.y), to = string.format("%04d-12-31", cur.y) }
    elseif state.view == "agenda" then
        return view_agenda.span_range(state.span, cur, config.first_day)
    end
    return model.month_range(cur.y, cur.m)
end

--- Build the active view's block (+ the agenda item list).
---@param width? integer  pad target for the agenda body boxes (nil = natural size)
---@return LvimCalendarBlock block, LvimCalendarAgendaItem[] items
local function build(width)
    local today = model.today()
    if state.view == "agenda" then
        local range = visible_range()
        local icons = {}
        for _, src in ipairs(sources.list()) do
            icons[src.name] = src.icon or "•"
        end
        return view_agenda.build({
            cursor = state.cursor,
            today = today,
            range = range,
            entries = sources.collect(range),
            icons = icons,
            show_empty = config.agenda.show_empty,
            active = state.active,
        }, width)
    end
    ---@type LvimCalendarGridCtx
    local ctx = {
        cursor = state.cursor,
        today = today,
        marks = sources.marks_for(visible_range()),
        first_day = config.first_day,
        week_numbers = config.week_numbers,
    }
    if state.view == "month" then
        return view_month.build(ctx), {}
    elseif state.view == "year" then
        -- responsive: the float caps at 0.9 editor width minus the border gutter
        return view_year.build(ctx, view_year.columns(math.floor(vim.o.columns * 0.9) - 4)), {}
    end
    return view_quarter.build(ctx), {}
end

-- ── repaint ──────────────────────────────────────────────────────────────────

--- Park the window cursor on the cell-cursor row (hidden hardware cursor; drives native scrolling
--- in a height-capped docked layout).
local function scroll()
    local pan = state.pan
    if pan and pan.win and api.nvim_win_is_valid(pan.win) and pan.buf and api.nvim_buf_is_valid(pan.buf) then
        local row = math.max(1, math.min(state.cursor_row or 1, api.nvim_buf_line_count(pan.buf)))
        pcall(api.nvim_win_set_cursor, pan.win, { row, 0 })
    end
end

local header_spec -- forward declaration (repaint ↔ band builders are mutually recursive)

--- Repaint the panel. `structure` = the bands/size changed (month/year/view/span/entry set) →
--- rebuild the header (nav label + active filters) and relayout; otherwise only re-render the
--- content in place.
---@param structure? boolean
local function repaint(structure)
    if not M.is_open() then
        return
    end
    if structure then
        state.st.set_header(header_spec())
    elseif state.pan and state.pan.refresh then
        state.pan.refresh()
    end
    scroll()
end

--- Fire the `User LvimCalendarDay` event for the cursor day (payload: date + its entries) — the
--- live-preview seam for a notes plugin.
local function fire_day()
    local iso = model.to_string(state.cursor)
    api.nvim_exec_autocmds("User", {
        pattern = "LvimCalendarDay",
        modeline = false,
        data = { date = iso, entries = sources.entries_for(iso) },
    })
end

--- Re-anchor the agenda's active entry onto the cursor day (its first entry when it has one,
--- else the first entry of the span).
local function agenda_anchor()
    state.active = 0
    local _, items = build(nil)
    if #items == 0 then
        return
    end
    state.active = 1
    local iso = model.to_string(state.cursor)
    for i, it in ipairs(items) do
        if it.entry.date == iso then
            state.active = i
            break
        end
    end
end

-- ── navigation ───────────────────────────────────────────────────────────────

--- Move the cell cursor to `new`, deciding how much must repaint (see the module header).
---@param new LvimCalendarDate?
local function move_cursor(new)
    if not new then
        return
    end
    local old = state.cursor
    state.cursor = new
    local changed = model.cmp(old, new) ~= 0
    local structure
    if state.view == "agenda" then
        agenda_anchor() -- the span window follows the cursor, so sections always rebuild
        structure = true
    elseif state.view == "year" then
        structure = new.y ~= old.y
    else
        structure = new.y ~= old.y or new.m ~= old.m
    end
    if changed then
        fire_day()
    end
    repaint(structure)
end

--- Move within the agenda entry list (j/k) — the cursor date follows the entry's section.
---@param delta integer
local function agenda_move(delta)
    if #state.items == 0 then
        return
    end
    state.active = math.max(1, math.min((state.active == 0 and 1 or state.active) + delta, #state.items))
    local entry = state.items[state.active].entry
    local d = model.from_string(entry.date)
    local month_changed = d and (d.y ~= state.cursor.y or d.m ~= state.cursor.m) or false
    local day_changed = d and model.cmp(d, state.cursor) ~= 0
    if d then
        state.cursor = d
    end
    if day_changed then
        fire_day()
    end
    repaint(month_changed) -- the nav label only goes stale across a month edge
end

--- Jump to the next/previous DECORATED day (a day with entries) within a year in that direction —
--- the Emacs holiday hopping. Only already-fetchable data can answer: sync sources respond
--- immediately, async sources from their cache (fresh results repaint marks but don't re-run a
--- finished hop).
---@param dir integer  +1 / -1
local function hop(dir)
    local range, pick
    if dir > 0 then
        range = {
            from = model.to_string(model.shift_days(state.cursor, 1)),
            to = model.to_string(model.shift_days(state.cursor, 370)),
        }
        pick = 1
    else
        range = {
            from = model.to_string(model.shift_days(state.cursor, -370)),
            to = model.to_string(model.shift_days(state.cursor, -1)),
        }
    end
    local dates = sources.dates_with_entries(range)
    local iso = dates[pick or #dates]
    if iso then
        move_cursor(model.from_string(iso))
    else
        vim.notify("lvim-calendar: no decorated day in that direction", vim.log.levels.INFO)
    end
end

--- Switch the active view (filter band / `v` cycle / the year-view zoom).
---@param v string
local function set_view(v)
    if v == state.view or not vim.tbl_contains(VIEW_ORDER, v) then
        return
    end
    state.view = v
    if v == "agenda" then
        agenda_anchor()
    end
    repaint(true)
end

--- Cycle month → quarter → year → agenda → month.
local function cycle_view()
    for i, v in ipairs(VIEW_ORDER) do
        if v == state.view then
            set_view(VIEW_ORDER[i % #VIEW_ORDER + 1])
            return
        end
    end
end

--- Switch the agenda span (its filter band).
---@param s string
local function set_span(s)
    if state.view ~= "agenda" or s == state.span then
        return
    end
    state.span = s
    agenda_anchor()
    repaint(true)
end

--- The ‹ / › nav-band shift: a month in the grid views, a year in the year view, one span
--- window in the agenda.
---@param dir integer
local function shift_nav(dir)
    if state.view == "year" then
        move_cursor(model.shift_years(state.cursor, dir))
    elseif state.view == "agenda" then
        local days = { day = 1, week = 7, fortnight = 14 }
        if state.span == "month" then
            move_cursor(model.shift_months(state.cursor, dir))
        else
            move_cursor(model.shift_days(state.cursor, dir * days[state.span]))
        end
    else
        move_cursor(model.shift_months(state.cursor, dir))
    end
end

-- ── prompts (canonical lvim-ui modals — never vim.ui.*) ─────────────────────

--- The `g` goto-date prompt: lvim-ui input, parsed by model.parse_goto (absolute ISO, dd.mm[.yyyy],
--- +3d/-2w/+1m/-1y relative offsets, empty/t = today).
local function goto_date()
    uilib.input({
        title = "GOTO DATE",
        default = "",
        callback = function(confirmed, value)
            if not confirmed then
                return
            end
            local d = model.parse_goto(value or "", state.cursor)
            if d then
                move_cursor(d)
            else
                vim.notify("lvim-calendar: cannot parse date: " .. tostring(value), vim.log.levels.WARN)
            end
        end,
    })
end

--- The nav-band "Month Year" button: month quick-jump via ui.select, then the year via ui.input.
local function quick_jump()
    local items = {}
    for i, name in ipairs(model.MONTHS) do
        items[i] = { label = name }
    end
    uilib.select({
        title = "MONTH",
        items = items,
        current_item = items[state.cursor.m],
        mark_current = false,
        callback = function(confirmed, mi)
            if not confirmed or not mi then
                return
            end
            uilib.input({
                title = "YEAR",
                default = tostring(state.cursor.y),
                callback = function(ok, value)
                    if not ok then
                        return
                    end
                    local y = tonumber(vim.trim(value or ""))
                    if not y or y < 1 or y > 9999 or y % 1 ~= 0 then
                        vim.notify("lvim-calendar: not a year: " .. tostring(value), vim.log.levels.WARN)
                        return
                    end
                    move_cursor({ y = y, m = mi, d = math.min(state.cursor.d, model.days_in_month(y, mi)) })
                end,
            })
        end,
    })
end

-- ── actions ──────────────────────────────────────────────────────────────────

--- <CR>: year view zooms into the month; agenda opens the active entry (source `on_open`, else
--- edit file/line); grid views confirm the cursor day — the consumer callback when one was passed,
--- else the classic default: insert the formatted date into the origin buffer.
local function do_select()
    if not M.is_open() then
        return
    end
    if state.view == "year" then
        set_view("month")
        return
    end
    if state.view == "agenda" then
        local it = state.items[state.active]
        if not it then
            return
        end
        local entry = it.entry
        local src = sources.get_source(entry.source or "")
        state.st.close() -- the surface restores focus to the opener before the jump
        vim.schedule(function()
            if src and src.on_open then
                pcall(src.on_open, entry)
            elseif entry.file then
                vim.cmd.edit(vim.fn.fnameescape(vim.fn.expand(entry.file)))
                if entry.line then
                    pcall(api.nvim_win_set_cursor, 0, { entry.line, 0 })
                end
            end
        end)
        return
    end
    local iso = model.to_string(state.cursor)
    local cb = state.on_select
    local text = model.format(state.cursor, config.insert_format)
    state.st.close()
    vim.schedule(function()
        if cb then
            cb(iso)
        else
            api.nvim_put({ text }, "c", true, true)
        end
    end)
end

--- `i`: create an entry on the cursor day via a source's `on_create` — the single capable source
--- directly, a ui.select chooser when several can.
local function create_entry()
    local iso = model.to_string(state.cursor)
    local creators = {}
    for _, src in ipairs(sources.list()) do
        if src.on_create then
            creators[#creators + 1] = src
        end
    end
    if #creators == 0 then
        vim.notify("lvim-calendar: no registered source can create entries", vim.log.levels.INFO)
        return
    end
    local function run(src)
        state.st.close()
        vim.schedule(function()
            pcall(src.on_create, iso)
        end)
    end
    if #creators == 1 then
        run(creators[1])
        return
    end
    local items = {}
    for i, src in ipairs(creators) do
        items[i] = { label = src.name, icon = src.icon }
    end
    uilib.select({
        title = "NEW ENTRY IN",
        items = items,
        callback = function(confirmed, i)
            if confirmed and i and creators[i] then
                run(creators[i])
            end
        end,
    })
end

-- ── bands ────────────────────────────────────────────────────────────────────

--- The view filter band (canon §5 — one group, live active flag).
---@return table band
local function view_band()
    local groups = { { id = "view", active = state.view, buttons = VIEW_BUTTONS } }
    return filters.bar(groups, {
        on_select = function(_, id)
            set_view(id)
        end,
    }).band
end

--- The agenda span filter band.
---@return table band
local function span_band()
    local groups = { { id = "span", active = state.span, buttons = SPAN_BUTTONS } }
    return filters.bar(groups, {
        on_select = function(_, id)
            set_span(id)
        end,
    }).band
end

--- The ‹ Month Year › / today nav band (the label button opens the quick-jump).
---@return table band
local function nav_band()
    local label = model.MONTHS[state.cursor.m] .. " " .. state.cursor.y
    if state.view == "year" then
        label = tostring(state.cursor.y)
    end
    local items = {
        surface.button({
            name = "‹",
            style = "plain",
            run = function()
                shift_nav(-1)
            end,
        }),
        surface.button({
            name = label,
            style = "plain",
            run = quick_jump,
        }),
        surface.button({
            name = "›",
            style = "plain",
            run = function()
                shift_nav(1)
            end,
        }),
        { type = "separator", text = "●", style = { padding = { 2, 2 }, hl = "LvimUiPeekFilterSep" } },
        surface.button({
            name = "today",
            style = "plain",
            run = function()
                move_cursor(model.today())
            end,
        }),
    }
    return { items = items, align = "center" }
end

--- The full header spec: filter band(s) BEFORE the nav action band (canon §4).
---@return table
header_spec = function()
    local bars = { view_band() }
    if state.view == "agenda" then
        bars[#bars + 1] = span_band()
    end
    bars[#bars + 1] = nav_band()
    return { bars = bars }
end

--- The shorthand action footer (the chassis key-badge style).
---@return table
local function footer_spec()
    return {
        bars = {
            {
                items = {
                    { key = "g", name = "goto", run = goto_date },
                    { key = "v", name = "view", run = cycle_view },
                    {
                        key = "t",
                        name = "today",
                        run = function()
                            move_cursor(model.today())
                        end,
                    },
                    { key = "<CR>", name = "pick", run = do_select },
                    {
                        key = "q",
                        name = "close",
                        run = function(st)
                            st.close()
                        end,
                    },
                },
            },
        },
    }
end

--- Frame-wide keymaps from config.keys — closures over the module state, bound on every frame
--- buffer (content + container) so navigation works from the bar sectors too.
---@return table[]
local function keymaps_spec()
    local k = config.keys
    local maps = {}
    ---@param key string|string[]
    ---@param fn fun()
    local function add(key, fn)
        maps[#maps + 1] = { key = key, run = fn }
    end
    add(k.prev_day, function()
        move_cursor(model.shift_days(state.cursor, -1))
    end)
    add(k.next_day, function()
        move_cursor(model.shift_days(state.cursor, 1))
    end)
    add(k.next_week, function()
        if state.view == "agenda" then
            agenda_move(1)
        else
            move_cursor(model.shift_days(state.cursor, 7))
        end
    end)
    add(k.prev_week, function()
        if state.view == "agenda" then
            agenda_move(-1)
        else
            move_cursor(model.shift_days(state.cursor, -7))
        end
    end)
    add(k.prev_month, function()
        move_cursor(model.shift_months(state.cursor, -1))
    end)
    add(k.next_month, function()
        move_cursor(model.shift_months(state.cursor, 1))
    end)
    add(k.next_year, function()
        move_cursor(model.shift_years(state.cursor, 1))
    end)
    add(k.prev_year, function()
        move_cursor(model.shift_years(state.cursor, -1))
    end)
    add(k.week_start, function()
        move_cursor(model.week_start(state.cursor, config.first_day))
    end)
    add(k.week_end, function()
        move_cursor(model.shift_days(model.week_start(state.cursor, config.first_day), 6))
    end)
    add(k.today, function()
        move_cursor(model.today())
    end)
    add(k.next_mark, function()
        hop(1)
    end)
    add(k.prev_mark, function()
        hop(-1)
    end)
    add(k.goto_date, goto_date)
    add(k.cycle_view, cycle_view)
    add(k.select, do_select)
    add(k.create, create_entry)
    -- direct filter hotkeys (canon §5) — bound here, not via the chassis' open-time map_hotkeys,
    -- so the agenda span keys exist even when that band appears later via set_header
    for _, b in ipairs(VIEW_BUTTONS) do
        add(b.key, function()
            set_view(b.id)
        end)
    end
    for _, b in ipairs(SPAN_BUTTONS) do
        add(b.key, function()
            set_span(b.id)
        end)
    end
    return maps
end

-- ── the provider / open ──────────────────────────────────────────────────────

---@class LvimCalendarOpenOpts
---@field view? "month"|"quarter"|"year"|"agenda"
---@field layout? "float"|"area"|"bottom"   sticky for the session once passed
---@field date? string|LvimCalendarDate     initial cursor day (ISO string or table; default today)
---@field on_select? fun(date: string)      select callback (nil = insert into the origin buffer)

--- Open the calendar panel (closing an already-open one first — a reopen applies the new opts).
---@param opts? LvimCalendarOpenOpts
function M.open(opts)
    opts = opts or {}
    if M.is_open() then
        state.st.close()
    end
    state.view = opts.view or config.view
    if not vim.tbl_contains(VIEW_ORDER, state.view) then
        state.view = "quarter"
    end
    if opts.layout then
        state.layout = opts.layout -- per-command override, sticky for the session
    end
    local layout = state.layout or config.layout
    state.span = config.agenda.span
    local date = opts.date
    if type(date) == "string" then
        date = model.from_string(date)
    end
    state.cursor = date or model.today()
    state.on_select = opts.on_select
    state.active = 0
    state.items = {}
    state.cursor_row = 1
    if state.view == "agenda" then
        agenda_anchor()
    end

    ---@type table  the surface content provider (see how-build-panels.md)
    local provider = {
        hide_cursor = true,
        size = function()
            local block = build(nil)
            return block.width, #block.rows
        end,
        render = function(width)
            local block, items = build(width)
            state.items = items
            state.cursor_row = block.cursor_row or 1
            return grid.flatten(block.rows)
        end,
        keys = function(_, pan)
            state.pan = pan
        end,
    }

    local area = layout == "area"
    local bottom = layout == "bottom"
    state.st = surface.open({
        mode = "float",
        position = area and "cmdline" or (bottom and "bottom") or nil,
        zindex = area and 200 or nil,
        title = { icon = config.icons.title, text = "CALENDAR" },
        border = surface.FRAME_BORDER,
        -- float = a content-fit special float; the docked layouts take the central dock slot
        size = (not area and not bottom) and {
            width = { auto = true, max = 0.9 },
            height = { auto = true, max = 0.9 },
        } or nil,
        header = header_spec(),
        content = { blocks = { { id = "calendar", provider = provider } } },
        footer = footer_spec(),
        keymaps = keymaps_spec(),
        on_close = function()
            if state.unsubscribe then
                state.unsubscribe()
                state.unsubscribe = nil
            end
            state.st = nil
            state.pan = nil
            state.items = {}
            api.nvim_exec_autocmds("User", { pattern = "LvimCalendarClose", modeline = false })
        end,
    })
    -- async source results / refresh() / a late register_source → full repaint (sizes may change)
    state.unsubscribe = sources.on_update(function()
        repaint(true)
    end)
    api.nvim_exec_autocmds("User", {
        pattern = "LvimCalendarOpen",
        modeline = false,
        data = { date = model.to_string(state.cursor), view = state.view },
    })
    fire_day()
    scroll()
end

--- Close the panel when open.
function M.close()
    if M.is_open() then
        state.st.close()
    end
end

--- The current cursor day (ISO) — nil when closed. For consumers reacting to LvimCalendarDay.
---@return string?
function M.cursor_date()
    if not M.is_open() then
        return nil
    end
    return model.to_string(state.cursor)
end

return M
