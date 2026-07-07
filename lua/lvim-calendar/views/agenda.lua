-- lvim-calendar.views.agenda: the date-anchored list (the org-agenda shape) — one section per day
-- over the active span, each section a `➤ Weekday, DD Month YYYY` header plus its entry rows:
-- a source-accent LEAD box (the source icon) + a striped BODY box (time + title) padded to the
-- full panel width so the tints reach the right edge (the help-window row canon: odd rows blue,
-- even rows yellow, body 0.2, the ACTIVE row raised to 0.4). Data arrives pre-collected from the
-- panel (sources.collect over the span range) — the view is pure layout, like every other view.
--
---@module "lvim-calendar.views.agenda"

local model = require("lvim-calendar.model")
local highlights = require("lvim-calendar.highlights")

local M = {}

---@class LvimCalendarAgendaItem
---@field row integer               1-based row of the entry inside the built block
---@field entry LvimCalendarEntry

---@class LvimCalendarAgendaCtx
---@field cursor LvimCalendarDate
---@field today LvimCalendarDate
---@field range { from: string, to: string }   the active span, resolved by the panel
---@field entries LvimCalendarEntry[]          collected over `range`, agenda-sorted
---@field icons table<string, string>          source name → lead icon
---@field show_empty boolean
---@field active integer                       the active entry index (the agenda cell cursor)

--- The inclusive span range for a cursor date. `day` is the cursor day; `week`/`fortnight` start
--- at the cursor's week start (org-agenda anchors at the week, not the cursor); `month` is the
--- cursor month.
---@param span "day"|"week"|"fortnight"|"month"
---@param cursor LvimCalendarDate
---@param first_day "monday"|"sunday"
---@return { from: string, to: string }
function M.span_range(span, cursor, first_day)
    if span == "day" then
        local iso = model.to_string(cursor)
        return { from = iso, to = iso }
    elseif span == "week" or span == "fortnight" then
        local start = model.week_start(cursor, first_day)
        return {
            from = model.to_string(start),
            to = model.to_string(model.shift_days(start, span == "week" and 6 or 13)),
        }
    end
    return model.month_range(cursor.y, cursor.m)
end

--- Build the agenda block. Returns the block plus the flat selectable ITEM list (row ↔ entry) the
--- panel navigates with j/k.
---@param ctx LvimCalendarAgendaCtx
---@param width? integer  pad body boxes to at least this many display cells (nil = natural)
---@return LvimCalendarBlock block, LvimCalendarAgendaItem[] items
function M.build(ctx, width)
    -- bucket the (already sorted) entries per date
    local per_day = {}
    for _, e in ipairs(ctx.entries) do
        per_day[e.date] = per_day[e.date] or {}
        table.insert(per_day[e.date], e)
    end

    -- natural width: the widest header/entry line, floored to a sane minimum so an empty agenda
    -- still opens as a usable panel
    local natural = 44
    local function entry_cells(e)
        local icon = ctx.icons[e.source or ""] or "•"
        -- lead box (1 + icon + 1) + time (6) + title + trailing pad
        return 2 + vim.fn.strdisplaywidth(icon) + 7 + vim.fn.strdisplaywidth(e.title or "") + 2
    end
    for _, e in ipairs(ctx.entries) do
        natural = math.max(natural, entry_cells(e))
    end
    local W = math.max(width or 0, natural)

    local rows = {}
    local items = {}
    local cursor_row = nil
    local idx = 0
    local first_section = true
    for _, date in ipairs(model.range_dates(ctx.range)) do
        local iso = model.to_string(date)
        local day_entries = per_day[iso] or {}
        if #day_entries > 0 or ctx.show_empty then
            if not first_section then
                rows[#rows + 1] = { { text = "" } }
            end
            first_section = false
            -- section header: ➤ Weekday, DD Month YYYY (+ the today / cursor signals)
            local name = model.WEEKDAY_NAMES[model.weekday(date)]
            local label = string.format("%s, %02d %s %d", name, date.d, model.MONTHS[date.m], date.y)
            if model.cmp(date, ctx.today) == 0 then
                label = label .. "  — today"
            end
            rows[#rows + 1] = {
                { text = "➤ ", hl = "LvimCalendarAgendaHeader" },
                { text = label, hl = "LvimCalendarAgendaHeader" },
            }
            if model.cmp(date, ctx.cursor) == 0 and not cursor_row then
                cursor_row = #rows
            end
            if #day_entries == 0 then
                rows[#rows + 1] = { { text = "   no entries", hl = "LvimCalendarEmpty" } }
            end
            for _, e in ipairs(day_entries) do
                idx = idx + 1
                local stripe = (idx % 2 == 1) and "B" or "Y"
                local body_hl = (idx == ctx.active) and ("LvimCalendarAgendaRowActive" .. stripe)
                    or ("LvimCalendarAgendaRow" .. stripe)
                local icon = ctx.icons[e.source or ""] or "•"
                local lead = " " .. icon .. " "
                local body = " " .. (e.time and (e.time .. "  ") or string.rep(" ", 7)) .. (e.title or "")
                local pad = W - vim.fn.strdisplaywidth(lead) - vim.fn.strdisplaywidth(body)
                rows[#rows + 1] = {
                    { text = lead, hl = highlights.lead_group(e.source or "") },
                    { text = body .. string.rep(" ", math.max(0, pad)), hl = body_hl },
                }
                items[#items + 1] = { row = #rows, entry = e }
                if idx == ctx.active then
                    cursor_row = #rows
                end
            end
        end
    end
    if #rows == 0 then
        rows[1] = { { text = "  no entries in this span", hl = "LvimCalendarEmpty" } }
    end
    return { rows = rows, width = W, cursor_row = cursor_row }, items
end

return M
