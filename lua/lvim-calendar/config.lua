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
---@field goto_date string       Prompt for a date (absolute or +3d/-2w/+1m relative) — a `g` CHORD, never a bare `g`
---@field cycle_view string      Cycle month → quarter → year → agenda
---@field select string          Confirm the cursor day in every grid view (callback/insert; agenda: open the entry)
---@field create string          Create an entry on the cursor day (source `on_create`)
---@field help string            Open the keymap cheatsheet (the set-wide `g?` chord)

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
---@field agenda_colors table                     Agenda striping: { odd, even, header, tint, active_tint, lead }
---@field insert_format string                    os.date format used when a selected day is inserted
---@field goto_hint string                        the accepted GOTO formats, shown in the prompt and the error
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
    -- What the GOTO prompt accepts, spelled out — it is shown IN the prompt and repeated in the error, so a
    -- rejected input tells you what would have worked instead of just refusing. Keep it in sync with
    -- `model.parse_goto` (the separator is free: `.` `-` `/` or a space; the 4-digit year decides the order).
    goto_hint = "2026-07-06 · 22.12.2021 · 6.7 · +3d · -2w · +1m · -1y · t",
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
        -- `gd` (a CHORD under the `g` prefix), not a bare `g`: the panel also owns `g?` (the set-wide
        -- cheatsheet chord), and a bare `g` action cannot coexist with a `g…` chord — pressing `g` would
        -- either fire immediately (killing the chord) or hang on `timeoutlen`. Both live under `g` now, and
        -- lvim-ui resolves them without any clock.
        goto_date = "gd",
        cycle_view = "v",
        select = "<CR>",
        create = "i",
        help = "g?", -- the set-wide cheatsheet chord (the panel owns the `g` prefix — see lvim-ui)
    },
    -- The CONTENT block's border. Left UNSET so the grid inherits the SHARED content ring (`lvim-ui.config`
    -- `content_border` — the blank " " ring), like every other content panel; the frame derives its air rows
    -- from whatever ring is in effect, so the spacing above and below the grid stays symmetric either way.
    -- Set it to any lvim-ui border spec ("none", a preset name, or an 8-item ring) to override it here.
    content_border = nil,

    -- The AGENDA's row striping. Every row is one accent: the body box wears it as a wash at `tint`, and the
    -- row under the cursor rises to `active_tint` so it reads as one solid block. `lead` is the strength of
    -- the SOURCE box in front of the row (it carries the source's own accent + icon). They were literals
    -- (0.2 / 0.4 / 0.4) — loud enough to fight the text they sit under.
    agenda_colors = {
        odd = "blue",
        even = "yellow",
        header = "blue",
        tint = 0.05,
        active_tint = 0.1,
        lead = 0.1,
    },

    icons = {
        title = "󰃭",
        holidays = "",
        dates = "󰃶",
        mark = "•",
    },
}
