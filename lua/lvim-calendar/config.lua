-- lvim-calendar.config: the live configuration table.
-- Holds the defaults; setup() merges user overrides into it in place (lvim-utils.utils.merge),
-- so every require("lvim-calendar.config") reader sees the effective values. Everything here is
-- CONFIGURATION — runtime state (the cursor date, the active view, the open panel) lives in
-- panel.lua, never here.
--
---@module "lvim-calendar.config"

---@class LvimCalendarAgendaConfig
---@field span "day"|"week"|"fortnight"|"month"  Default agenda span (live-switchable in the panel)
---@field show_empty boolean                     Show day sections that have no entries

---@class LvimCalendarKeysConfig
---@field prev_day string        Move the cell cursor one day back
---@field next_day string        Move the cell cursor one day forward
---@field next_week string       Move one week forward (down)
---@field prev_week string       Move one week back (up)
---@field prev_month string      Shift one month back
---@field next_month string      Shift one month forward
---@field next_year string       Shift one year forward
---@field prev_year string       Shift one year back
---@field week_start string      Jump to the start of the cursor week
---@field week_end string        Jump to the end of the cursor week
---@field today string[]         Jump to today (both keys)
---@field next_mark string       Jump to the next decorated day (a day with entries)
---@field prev_mark string       Jump to the previous decorated day
---@field goto_date string       Prompt for a date (absolute or +3d/-2w/+1m relative)
---@field cycle_view string      Cycle month → quarter → year → agenda
---@field select string          Confirm the cursor day (callback/insert; agenda: open the entry; year: zoom)
---@field create string          Create an entry on the cursor day (source `on_create`)

---@class LvimCalendarIconsConfig
---@field title string           The panel border-title glyph
---@field holidays string        Lead icon of the built-in `holidays` source
---@field dates string           Lead icon of the built-in `dates` source
---@field mark string            Default day-cell mark glyph for a decorated day

---@class LvimCalendarConfig
---@field view "month"|"quarter"|"year"|"agenda"  Default view (quarter = the Emacs calendar strip)
---@field layout "float"|"area"|"bottom"          Default panel layout (per-open override wins)
---@field first_day "monday"|"sunday"             First column of the week grid
---@field week_numbers boolean                    Show ISO week numbers left of each grid row
---@field insert_format string                    os.date format used when a selected day is inserted
---@field agenda LvimCalendarAgendaConfig         Agenda view defaults
---@field holidays table[]                        Built-in `holidays` source input (see sources.lua)
---@field dates table[]                           Built-in `dates` source input (see sources.lua)
---@field keys LvimCalendarKeysConfig             Panel keys (vim notation)
---@field icons LvimCalendarIconsConfig           Nerd Font glyphs used by the panel

---@type LvimCalendarConfig
return {
    view = "quarter",
    layout = "float",
    first_day = "monday",
    week_numbers = false,
    -- Format handed to os.date() when a selected day is INSERTED into the buffer the calendar
    -- was opened from (the default <CR> action when no on_select callback was passed).
    insert_format = "%Y-%m-%d",
    agenda = {
        span = "week",
        show_empty = false,
    },
    -- Built-in HOLIDAYS source: decoration-only dates. Each entry is `{ date, title }` (positional
    -- or keyed): `date` is "MM-DD" (recurs every year) or "YYYY-MM-DD" (a single occurrence).
    --   holidays = { { "01-01", "New Year" }, { "2026-04-13", "Easter Monday" } }
    holidays = {},
    -- Built-in user DATES source (the vim-diary shape): entries you want on the calendar/agenda.
    -- `{ date, title, time?, mark?, file?, line? }` — `date` as above; `file`/`line` make <CR>
    -- in the agenda jump there.
    --   dates = { { "2026-07-06", "standup", time = "09:30", file = "~/notes/standup.md" } }
    dates = {},
    keys = {
        prev_day = "h",
        next_day = "l",
        next_week = "j",
        prev_week = "k",
        prev_month = "H",
        next_month = "L",
        next_year = "J",
        prev_year = "K",
        week_start = "0",
        week_end = "$",
        today = { "t", "." },
        next_mark = "w",
        prev_mark = "b",
        goto_date = "g",
        cycle_view = "v",
        select = "<CR>",
        create = "i",
    },
    icons = {
        title = "󰃭",
        holidays = "",
        dates = "󰃶",
        mark = "•",
    },
}
