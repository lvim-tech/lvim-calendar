-- lvim-calendar.highlights: every panel group, factory-built from the live lvim-utils palette and
-- bound via lvim-utils.highlight.bind, so the calendar re-derives on ColorScheme / palette sync.
-- Tint canon: a coloured cell is its accent mtint-ed toward the background —
--   today   = full accent bold on mtint(blue, 0.3)
--   cursor  = mtint(yellow, 0.4) background (wins over today)
--   weekend = mtint(red, 0.15)
--   mark    = source accent on mtint(accent, 0.25)
--   agenda  = rows striped blue/yellow at 0.2, the active row raised to 0.4; lead boxes 0.4 bold
-- Per-source mark/lead groups are derived on registration (source_group) and folded into build()
-- so they track theme changes exactly like the static ones.
--
---@module "lvim-calendar.highlights"

local c = require("lvim-utils.colors")
local hl = require("lvim-utils.highlight")

local M = {}

--- Blend an accent toward the panel background — the canonical `mtint`.
---@param accent string
---@param t number
---@return string
local function mtint(accent, t)
    return hl.blend(accent, c.bg, t)
end

---@type table<string, string>  source group SUFFIX (PascalCase source name) → palette accent name
local src_accents = {}

--- PascalCase a source name into a highlight-group suffix ("org-notes" → "OrgNotes").
---@param name string
---@return string
local function pascal(name)
    local s = name:gsub("[^%w]+", " "):gsub("(%a)([%w]*)", function(a, rest)
        return a:upper() .. rest
    end)
    return (s:gsub("%s+", ""))
end

--- All calendar groups from the live palette (bound via hl.bind in setup).
---@return table<string, table>
function M.build()
    -- The agenda's accents + strengths come from the live config (never literals here).
    local ag = require("lvim-calendar.config").agenda_colors or {}
    ag.tint = ag.tint or 0.05
    ag.active_tint = ag.active_tint or 0.1
    ag.lead = ag.lead or 0.1
    --- Resolve an accent NAME from the palette (or a literal "#rrggbb").
    ---@param v string?
    ---@param fallback string
    ---@return string
    local function ac(v, fallback)
        v = v or fallback
        if v:sub(1, 1) == "#" then
            return v
        end
        return c[v] or c[fallback] or c.blue
    end
    local groups = {
        LvimCalendarHeading = { fg = c.blue, bold = true },
        LvimCalendarWeekday = { fg = c.comment },
        LvimCalendarWeeknum = { fg = c.comment },
        LvimCalendarDay = { fg = c.fg_light },
        -- other-month padding cells: the day fg dimmed to a 0.6 tint of itself
        LvimCalendarFaded = { fg = mtint(c.fg, 0.6) },
        LvimCalendarWeekend = { fg = c.red, bg = mtint(c.red, 0.15) },
        LvimCalendarToday = { fg = c.blue, bg = mtint(c.blue, 0.3), bold = true },
        LvimCalendarCursor = { fg = c.yellow, bg = mtint(c.yellow, 0.4), bold = true },
        -- generic decorated-day fallback (an entry whose source vanished / a bare `hl` miss)
        LvimCalendarMark = { fg = c.green, bg = mtint(c.green, 0.25) },
        LvimCalendarAgendaHeader = { fg = ac(ag.header, "blue"), bold = true },
        LvimCalendarAgendaTime = { fg = c.comment },
        -- agenda body boxes — accents + strengths from `config.agenda_colors` (never literals)
        LvimCalendarAgendaRowB = { fg = ac(ag.odd, "blue"), bg = mtint(ac(ag.odd, "blue"), ag.tint) },
        LvimCalendarAgendaRowActiveB = { fg = ac(ag.odd, "blue"), bg = mtint(ac(ag.odd, "blue"), ag.active_tint) },
        LvimCalendarAgendaRowY = { fg = ac(ag.even, "yellow"), bg = mtint(ac(ag.even, "yellow"), ag.tint) },
        LvimCalendarAgendaRowActiveY = { fg = ac(ag.even, "yellow"), bg = mtint(ac(ag.even, "yellow"), ag.active_tint) },
        LvimCalendarEmpty = { fg = c.comment, italic = true },
    }
    for suffix, accent in pairs(src_accents) do
        local col = c[accent] or c.green
        groups["LvimCalendarMark" .. suffix] = { fg = col, bg = mtint(col, 0.25) }
        groups["LvimCalendarLead" .. suffix] = { fg = col, bg = mtint(col, ag.lead), bold = true }
    end
    return groups
end

--- Register a source's accent and return its day-mark group name; also derives the matching
--- `LvimCalendarLead<Name>` agenda lead-box group. Applied immediately (a source may register
--- long after setup's bind ran) and re-derived with everything else on theme changes, because
--- build() folds `src_accents` in.
---@param name string    the source name
---@param accent string  lvim-utils palette color name
---@return string group  the mark highlight group
function M.source_group(name, accent)
    local suffix = pascal(name)
    src_accents[suffix] = accent
    local col = c[accent] or c.green
    hl.define("LvimCalendarMark" .. suffix, { fg = col, bg = mtint(col, 0.25) })
    local agl = (require("lvim-calendar.config").agenda_colors or {}).lead or 0.1
    hl.define("LvimCalendarLead" .. suffix, { fg = col, bg = mtint(col, agl), bold = true })
    return "LvimCalendarMark" .. suffix
end

--- The agenda lead-box group for a source name (paired with source_group's derivation).
---@param name string
---@return string
function M.lead_group(name)
    return "LvimCalendarLead" .. pascal(name)
end

return M
