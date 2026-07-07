# lvim-calendar

A month / quarter / year / agenda calendar for the **lvim-tech** set — the Emacs calendar feature
model on the canonical lvim-ui chassis. Four views over one date model, Emacs-grade date
navigation (`h/l` day, `j/k` week, `H/L` month, `J/K` year, `g` goto-date, `w/b` hop between
decorated days), day **marks** from pluggable **sources** (the diary/holidays mechanism), and a
stable source API so org- and markdown-note systems plug in without touching calendar code.

- **month** — one full month grid.
- **quarter** (default) — previous / **current** / next month side by side; navigating past an
  edge re-centers the strip, exactly like Emacs re-scrolls.
- **year** — 12 mini-months in a responsive 3×4 / 4×3 grid; `<CR>` on a month zooms into it.
- **agenda** — a date-anchored entry list over a `day/week/fortnight/month` span (the org-agenda
  shape); `<CR>` jumps to the entry's `file:line` (or calls the source's `on_open`).

[![License: BSD-3-Clause](https://img.shields.io/badge/License-BSD--3--Clause-blue.svg)](https://github.com/lvim-tech/lvim-calendar/blob/main/LICENSE)

## Requirements

Requires **Neovim >= 0.10**, [lvim-ui](https://github.com/lvim-tech/lvim-ui) (the surface chassis
that renders the panel) and [lvim-utils](https://github.com/lvim-tech/lvim-utils) (palette,
self-theming, cursor management).

## Installation

### lvim-installer (recommended)

```vim
:LvimInstaller plugins
```

lvim-installer installs plugins through Neovim's built-in `vim.pack`, so no external plugin manager
is needed.

### Native (vim.pack)

```lua
vim.pack.add({
    { src = "https://github.com/lvim-tech/lvim-utils" },
    { src = "https://github.com/lvim-tech/lvim-ui" },
    { src = "https://github.com/lvim-tech/lvim-calendar" },
})
require("lvim-calendar").setup({})
```

## Usage

```vim
:LvimCalendar                        " open with the configured view + layout
:LvimCalendar month                  " a view token: month | quarter | year | agenda
:LvimCalendar agenda area           " + a layout token: float | area | bottom (any order)
```

A layout token is recognised anywhere in the arguments and is **sticky for the session**;
`layout` in `setup()` is the cross-session default.

```lua
require("lvim-calendar").open({ view = "quarter", date = "2026-07-06" })
require("lvim-calendar").close()
require("lvim-calendar").pick({ -- date-picker for another plugin's form
    callback = function(date) -- "YYYY-MM-DD"
        print("picked " .. date)
    end,
})
```

### Panel keys

| Key | Action |
| --- | --- |
| `h` / `l` | one day back / forward |
| `j` / `k` | one week forward / back (agenda: next / previous entry) |
| `H` / `L` | one month back / forward |
| `J` / `K` | one year forward / back |
| `0` / `$` | start / end of the cursor week |
| `t` / `.` | today |
| `w` / `b` | next / previous **decorated** day (a day with entries) |
| `g` | goto date — `2026-07-06`, `06.07`, `6.7.2027`, `+3d`, `-2w`, `+1m`, `-1y` |
| `v` | cycle month → quarter → year → agenda |
| `m` `Q` `y` `a` | switch view directly (the header filter band) |
| `d` `W` `f` `M` | agenda span: day / week / fortnight / month |
| `<CR>` | confirm the day (callback / insert); agenda: open the entry; year: zoom into the month |
| `i` | create an entry on the cursor day (source `on_create`; a chooser when several can) |
| `q` / `<Esc>` | close |

The header carries the view filter band, the agenda span band, and a `‹ Month Year ›` / `today`
nav band — the month-year button opens a quick-jump (month picker, then year prompt). `<C-j>` /
`<C-k>` move between the bands, the grid and the footer (the chassis sectors).

`<CR>` on a day calls the `on_select` callback when one was passed to `open()` / `pick()`;
without one it inserts the day (formatted with `insert_format`) into the buffer the calendar was
opened from.

## Sources — the org/markdown integration seam

Day marks and agenda entries come from registered **sources**. The calendar core never knows
about org or markdown — sources are the only contract:

```lua
require("lvim-calendar").register_source({
    name = "org-notes", -- unique id
    icon = "", -- agenda lead glyph (single-width Nerd Font)
    accent = "green", -- lvim-utils palette color name: day tint + lead box
    -- REQUIRED: entries for an inclusive date range (batched — one call per visible
    -- range, never per day). Return the list synchronously, or call done(list) async;
    -- async replies are generation-guarded (a stale reply after refresh() is dropped).
    get = function(range, done) -- range = { from = "2026-07-01", to = "2026-07-31" }
        return {
            {
                date = "2026-07-06",
                title = "standup",
                time = "09:30",
                file = "~/notes/2026-07-06.md",
                line = 12,
                mark = "•", -- optional per-entry mark override
                hl = nil, -- optional per-entry highlight override
            },
        }
    end,
    on_open = nil, -- optional: entry → custom jump (default: edit file/line)
    on_create = nil, -- optional: (date) → make a new entry (the `i` key)
})
```

Consumer API (both directions):

```lua
local cal = require("lvim-calendar")
cal.entries_for("2026-07-06") -- merged entries of one day
cal.dates_with_entries({ from = "2026-07-01", to = "2026-07-31" })
cal.refresh("org-notes") -- drop the cache (a notes plugin calls it after writing)
cal.refresh() -- all sources
```

Events (`autocmd User`): `LvimCalendarOpen`, `LvimCalendarClose`, and `LvimCalendarDay` — fired
when the cell cursor lands on a day, with `data = { date, entries }`, so a notes plugin can
live-preview the day under the cursor.

Two built-in sources ship as reference implementations: `holidays` (decoration-only fixed or
recurring dates from `config.holidays`) and `dates` (vim-diary-style user dates from
`config.dates`). Both read the live config on every fetch.

## Default configuration

```lua
require("lvim-calendar").setup({
    view = "quarter", -- "month" | "quarter" | "year" | "agenda"
    layout = "float", -- "float" | "area" | "bottom" (per-command override is session-sticky)
    first_day = "monday", -- "monday" | "sunday"
    week_numbers = false, -- ISO week numbers left of each grid row
    insert_format = "%Y-%m-%d", -- os.date format for the default <CR> insert
    agenda = {
        span = "week", -- "day" | "week" | "fortnight" | "month"
        show_empty = false, -- show day sections without entries
    },
    -- built-in holidays source: { date, title } — "MM-DD" recurs yearly, "YYYY-MM-DD" is one-off
    holidays = {},
    -- built-in user dates source: { date, title, time?, mark?, file?, line? }
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
        title = "󰃭", -- panel border-title glyph
        holidays = "", -- built-in holidays source lead icon
        dates = "󰃶", -- built-in dates source lead icon
        mark = "•", -- default day-cell mark for a decorated day
    },
})
```

## Highlights

All groups are self-themed from the lvim-utils palette (re-derived on `ColorScheme` / palette
sync) and overwritable by a colorscheme:

| Group | Role |
| --- | --- |
| `LvimCalendarHeading` | month/year headings (blue, bold) |
| `LvimCalendarWeekday` / `LvimCalendarWeeknum` | weekday header / ISO week numbers (dim) |
| `LvimCalendarDay` | a plain day cell |
| `LvimCalendarFaded` | other-month padding cells |
| `LvimCalendarWeekend` | Saturday/Sunday cells (red 0.15 tint) |
| `LvimCalendarToday` | today (blue 0.3 tint, bold) |
| `LvimCalendarCursor` | the cell cursor (yellow 0.4 tint — wins over today) |
| `LvimCalendarMark<Source>` / `LvimCalendarLead<Source>` | per-source day mark / agenda lead box |
| `LvimCalendarAgendaHeader` | agenda day-section headers |
| `LvimCalendarAgendaRow(Active)B/Y` | agenda entry rows, striped blue/yellow |
| `LvimCalendarEmpty` | "no entries" placeholders |

## Health

```vim
:checkhealth lvim-calendar
```

Reports the lvim-ui / lvim-utils base, verifies every configured glyph is single-width, and lists
each registered source with its cache state (months cached, generation).
