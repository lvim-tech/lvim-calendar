-- lvim-calendar: a month/quarter/year/agenda calendar for the lvim-tech set — the Emacs calendar
-- feature model on the canonical lvim-ui chassis. Views share one date model and one cell
-- renderer; day DECORATIONS come from pluggable SOURCES (`register_source`), with built-in
-- `holidays` and `dates` reference sources, so future org-/markdown-note systems plug in without
-- touching calendar code.
--
--   :LvimCalendar [month|quarter|year|agenda] [float|area|bottom]
--   require("lvim-calendar").open({ view, layout, date, on_select })
--   require("lvim-calendar").pick({ callback })          -- date-picker for other plugins' forms
--   require("lvim-calendar").register_source({ ... })    -- the org/md integration seam
--
-- Events (nvim_exec_autocmds User): LvimCalendarOpen, LvimCalendarClose, LvimCalendarDay (cursor
-- moved to a day; data = { date, entries } — the live-preview seam).
--
---@module "lvim-calendar"

local config = require("lvim-calendar.config")
local model = require("lvim-calendar.model")
local sources = require("lvim-calendar.sources")
local panel = require("lvim-calendar.panel")
local highlights = require("lvim-calendar.highlights")
local hl = require("lvim-utils.highlight")
local merge = require("lvim-utils.utils").merge

local M = {}

---@type boolean  one-time setup (highlight bind, built-in sources, command) done
local registered = false

---@type string[]  the :LvimCalendar view tokens
local VIEWS = { "month", "quarter", "year", "agenda" }
---@type string[]  the :LvimCalendar layout tokens (recognised anywhere in the args)
local LAYOUTS = { "float", "area", "bottom" }

-- ── public API ───────────────────────────────────────────────────────────────

--- Open the calendar panel.
---@param opts? LvimCalendarOpenOpts  { view?, layout?, date?, on_select? }
function M.open(opts)
    panel.open(opts)
end

--- Close the panel when open.
function M.close()
    panel.close()
end

--- Whether the panel is open.
---@return boolean
function M.is_open()
    return panel.is_open()
end

--- Date-picker convenience for OTHER plugins' forms: opens the calendar and resolves the picked
--- day through `callback(date)` ("YYYY-MM-DD"). `opts` otherwise matches open() (view/layout/date).
---@param opts { callback: fun(date: string), view?: string, layout?: string, date?: string|LvimCalendarDate }
function M.pick(opts)
    opts = opts or {}
    panel.open({
        view = opts.view or config.view,
        layout = opts.layout,
        date = opts.date,
        on_select = opts.callback,
    })
end

--- Register an entry source (see lvim-calendar.sources for the contract).
---@param spec LvimCalendarSource
---@return boolean ok
function M.register_source(spec)
    return sources.register_source(spec)
end

--- Drop cached entries (one source or all) and repaint an open panel — a notes plugin calls this
--- after writing a file.
---@param name? string
function M.refresh(name)
    sources.refresh(name)
end

--- All entries on one day ("YYYY-MM-DD"), merged across sources.
---@param date string
---@return LvimCalendarEntry[]
function M.entries_for(date)
    return sources.entries_for(date)
end

--- Sorted unique dates carrying at least one entry inside an inclusive ISO range.
---@param range { from: string, to: string }
---@return string[]
function M.dates_with_entries(range)
    return sources.dates_with_entries(range)
end

-- ── command ──────────────────────────────────────────────────────────────────

--- Parse the :LvimCalendar fargs — a view token and/or a layout token, in any order.
---@param fargs string[]
---@return { view?: string, layout?: string }? opts, string? bad  the unknown token, when any
local function parse_args(fargs)
    local opts = {}
    for _, a in ipairs(fargs) do
        if vim.tbl_contains(VIEWS, a) then
            opts.view = a
        elseif vim.tbl_contains(LAYOUTS, a) then
            opts.layout = a
        else
            return nil, a
        end
    end
    return opts, nil
end

--- Merge user options into the live config, bind the highlights, register the built-in sources
--- and the :LvimCalendar command. Optional — the defaults work without it.
---@param opts? LvimCalendarConfig
function M.setup(opts)
    if opts then
        merge(config, opts)
    end
    if registered then
        return
    end
    registered = true

    hl.setup()
    hl.bind(highlights.build)
    sources.setup_builtins()

    vim.api.nvim_create_user_command("LvimCalendar", function(cmd)
        local parsed, bad = parse_args(cmd.fargs)
        if not parsed then
            vim.notify("lvim-calendar: unknown argument " .. tostring(bad), vim.log.levels.WARN)
            return
        end
        panel.open(parsed)
    end, {
        nargs = "*",
        desc = "lvim-calendar: open the calendar ([view] [layout], in any order)",
        complete = function(_, line)
            local out = {}
            for _, v in ipairs(VIEWS) do
                if not line:find(v, 1, true) then
                    out[#out + 1] = v
                end
            end
            for _, l in ipairs(LAYOUTS) do
                if not line:find(l, 1, true) then
                    out[#out + 1] = l
                end
            end
            return out
        end,
    })
end

--- Re-export the date model for consumers (a notes plugin computing ranges, tests).
M.model = model

return M
