-- lvim-calendar.views.grid: the SHARED cell renderer every view is a layout of. A month renders
-- into a BLOCK — rows of spans `{ text, hl? }` — so views compose blocks (side by side, stacked)
-- without byte-offset bookkeeping: offsets are computed ONCE, in flatten(), when the panel turns
-- span rows into the `lines, hls` shape the lvim-ui surface provider contract expects. Two cell
-- shapes: normal (4-cell boxes ` 17•` + 1-space gaps) and compact (3-cell boxes `17•`, flush — the
-- year view's mini-months, marks collapsed to the dot).
--
-- Cell highlight precedence (one box group per cell): other-month FADED beats everything (padding
-- cells never carry cursor/today/marks — the same date renders "for real" in its own month, so
-- decorating the padding would double it), then CURSOR > TODAY > MARK > WEEKEND > DAY.
--
---@module "lvim-calendar.views.grid"

local model = require("lvim-calendar.model")

local M = {}

---@class LvimCalendarSpan
---@field text string
---@field hl? string
---@field date? string  -- ISO date this span IS a clickable day cell for (mouse hit-testing; see flatten)

---@class LvimCalendarBlock
---@field rows LvimCalendarSpan[][]
---@field width integer
---@field cursor_row? integer  1-based row of the cursor cell within the block, when it holds it
---@field cursor_last? integer  the LAST row of the block holding the cursor (keep the whole month on screen)

---@class LvimCalendarGridCtx
---@field cursor LvimCalendarDate
---@field today LvimCalendarDate
---@field marks table<string, { mark: string, hl: string }>  ISO date → day decoration
---@field first_day "monday"|"sunday"
---@field week_numbers boolean
---@field compact? boolean  3-cell mini-month cells (year view)
---@field heading? "full"|"month"|false  block heading: "July 2026" | "July" | none

--- Pad/center `text` into a field of `width` display cells.
---@param text string
---@param width integer
---@return string
local function center(text, width)
    local w = vim.fn.strdisplaywidth(text)
    local left = math.floor((width - w) / 2)
    return string.rep(" ", math.max(0, left)) .. text .. string.rep(" ", math.max(0, width - w - left))
end

--- Weekday column order for the configured week start: indices into model.WEEKDAYS
--- (Monday-first), rotated so Sunday leads when first_day = "sunday".
---@param first_day "monday"|"sunday"
---@return integer[]
local function day_order(first_day)
    if first_day == "sunday" then
        return { 7, 1, 2, 3, 4, 5, 6 }
    end
    return { 1, 2, 3, 4, 5, 6, 7 }
end

--- The highlight group of one day cell (see the precedence in the module header).
---@param cell LvimCalendarCell
---@param ctx LvimCalendarGridCtx
---@return string group, { mark: string, hl: string }? mark
local function cell_group(cell, ctx)
    if cell.other then
        return "LvimCalendarFaded", nil
    end
    local iso = model.to_string(cell.date)
    local mark = ctx.marks[iso]
    if model.cmp(cell.date, ctx.cursor) == 0 then
        return "LvimCalendarCursor", mark
    end
    if model.cmp(cell.date, ctx.today) == 0 then
        return "LvimCalendarToday", mark
    end
    if mark then
        return mark.hl, mark
    end
    if model.is_weekend(cell.date) then
        return "LvimCalendarWeekend", nil
    end
    return "LvimCalendarDay", nil
end

--- Render ONE month block for `y`/`m`.
---@param y integer
---@param m integer
---@param ctx LvimCalendarGridCtx
---@return LvimCalendarBlock
function M.month_block(y, m, ctx)
    local compact = ctx.compact == true
    local cellw = compact and 3 or 4
    local gap = compact and 0 or 1
    -- Week numbers are a CONTENT choice (`week_numbers`), not a cell-shape one: a compact grid keeps them,
    -- just in a tighter column. Only the year view opts out (its mini-months carry no week column).
    local weeknums = ctx.week_numbers == true
    local wn_w = weeknums and (compact and 3 or 4) or 0
    local width = wn_w + 7 * cellw + 6 * gap

    local rows = {}
    -- heading — "July 2026" / "July" in the heading group, centered over the grid
    if ctx.heading then
        local text = ctx.heading == "month" and model.MONTHS[m] or (model.MONTHS[m] .. " " .. y)
        rows[#rows + 1] = { { text = center(text, width), hl = "LvimCalendarHeading" } }
    end
    -- weekday header — the labels rotated to the configured week start, dim
    local order = day_order(ctx.first_day)
    local hdr = {}
    if weeknums then
        hdr[#hdr + 1] = { text = string.rep(" ", wn_w) }
    end
    for i, di in ipairs(order) do
        local label = model.WEEKDAYS[di]
        hdr[#hdr + 1] = { text = compact and (label .. " ") or (" " .. label .. " "), hl = "LvimCalendarWeekday" }
        if gap > 0 and i < 7 then
            hdr[#hdr + 1] = { text = " " }
        end
    end
    rows[#rows + 1] = hdr

    local cursor_row = nil
    for _, week in ipairs(model.month_grid(y, m, ctx.first_day)) do
        local row = {}
        if weeknums then
            -- the ISO week is defined Monday-based, so number the row by its Monday cell
            -- (column 1 on a Monday grid, column 2 on a Sunday grid)
            local monday = ctx.first_day == "sunday" and week[2].date or week[1].date
            row[#row + 1] = { text = string.format("%2d  ", model.iso_week(monday)), hl = "LvimCalendarWeeknum" }
        end
        for i, cell in ipairs(week) do
            local group, mark = cell_group(cell, ctx)
            local markch = " "
            if mark and not cell.other then
                markch = compact and "•" or mark.mark
            end
            local text
            if compact then
                text = string.format("%2d", cell.date.d) .. markch
            else
                text = string.format(" %2d", cell.date.d) .. markch
            end
            -- The cell carries its ISO date so `flatten` can emit a mouse hitbox (a click on the day box
            -- lands on that date, exactly as the arrow keys do) — for EVERY day incl. faded other-month
            -- cells, since arrow navigation also crosses month edges.
            row[#row + 1] = { text = text, hl = group, date = model.to_string(cell.date) }
            if gap > 0 and i < 7 then
                row[#row + 1] = { text = " " }
            end
            if group == "LvimCalendarCursor" then
                cursor_row = #rows + 1
            end
        end
        rows[#rows + 1] = row
    end

    -- `cursor_last` = the block's LAST row when this block holds the cursor. The panel scrolls to keep the
    -- WHOLE month visible, not just the cursor's line: landing on a date in the bottom band of the year view
    -- otherwise parks that line on the last screen row and cuts the rest of its month off.
    return { rows = rows, width = width, cursor_row = cursor_row, cursor_last = cursor_row and #rows or nil }
end

--- Join blocks SIDE BY SIDE with `gap` spaces between them; shorter blocks are padded with blank
--- rows (a 4-week February beside a 6-week month) and every block's rows are padded to its own
--- width so the columns stay aligned.
---@param blocks LvimCalendarBlock[]
---@param gap integer
---@return LvimCalendarBlock
function M.hjoin(blocks, gap)
    local nrows, width = 0, 0
    local cursor_last = nil
    for i, b in ipairs(blocks) do
        nrows = math.max(nrows, #b.rows)
        width = width + b.width + (i > 1 and gap or 0)
    end
    local rows = {}
    local cursor_row = nil
    for r = 1, nrows do
        local row = {}
        for i, b in ipairs(blocks) do
            if i > 1 then
                row[#row + 1] = { text = string.rep(" ", gap) }
            end
            local brow = b.rows[r]
            if brow then
                local w = 0
                for _, sp in ipairs(brow) do
                    row[#row + 1] = sp
                    w = w + vim.fn.strdisplaywidth(sp.text)
                end
                if w < b.width then
                    row[#row + 1] = { text = string.rep(" ", b.width - w) }
                end
            else
                row[#row + 1] = { text = string.rep(" ", b.width) }
            end
            if b.cursor_row == r then
                cursor_row = r
                cursor_last = b.cursor_last
            end
        end
        rows[#rows + 1] = row
    end
    return { rows = rows, width = width, cursor_row = cursor_row, cursor_last = cursor_last }
end

--- Stack blocks VERTICALLY with one blank row between them, tracking the cursor row through the
--- accumulated offset.
---@param blocks LvimCalendarBlock[]
---@return LvimCalendarBlock
function M.vjoin(blocks)
    local rows = {}
    local width = 0
    local cursor_row = nil
    local cursor_last = nil
    for i, b in ipairs(blocks) do
        if i > 1 then
            rows[#rows + 1] = { { text = "" } }
        end
        local off = #rows
        for _, row in ipairs(b.rows) do
            rows[#rows + 1] = row
        end
        if b.cursor_row then
            cursor_row = off + b.cursor_row
            cursor_last = b.cursor_last and (off + b.cursor_last) or nil
        end
        width = math.max(width, b.width)
    end
    return { rows = rows, width = width, cursor_row = cursor_row, cursor_last = cursor_last }
end

--- Centre a block inside `width`: every row gets the same left pad, so the grid sits in the middle of the
--- panel instead of hugging its left edge. A block WIDER than the panel is returned untouched (the frame
--- clips / the view degrades — see the panel's fit logic).
---@param block LvimCalendarBlock
---@param width integer  the panel's content width
---@return LvimCalendarBlock
function M.center_block(block, width)
    local pad = math.floor((width - block.width) / 2)
    if pad <= 0 then
        return block
    end
    local lead = string.rep(" ", pad)
    local rows = {}
    for i, row in ipairs(block.rows) do
        local out = { { text = lead } }
        for _, span in ipairs(row) do
            out[#out + 1] = span
        end
        rows[i] = out
    end
    return { rows = rows, width = width, cursor_row = block.cursor_row, cursor_last = block.cursor_last }
end

--- Flatten span rows into the surface provider's `lines, hls` shape, plus per-day mouse `hitboxes`. THE
--- one place display columns meet byte offsets: padding above is computed in DISPLAY cells (strdisplaywidth
--- — a multibyte mark glyph must not break the column alignment), while the extmark highlight ranges here
--- are BYTE offsets (`#text`), which is what nvim_buf_set_extmark consumes. A span carrying a `date` (a day
--- cell) also emits a hitbox `{ row (0-based), c0, c1 (byte cols), date }` the panel hit-tests a click
--- against — the box's own rendered byte span, so the click maps precisely to that day and no other.
---@param rows LvimCalendarSpan[][]
---@return string[] lines, table[] hls, table[] hitboxes
function M.flatten(rows)
    local lines, hls, hitboxes = {}, {}, {}
    for r, row in ipairs(rows) do
        local parts = {}
        local byte = 0
        for _, sp in ipairs(row) do
            parts[#parts + 1] = sp.text
            local len = #sp.text
            if sp.hl and len > 0 then
                hls[#hls + 1] = { r - 1, byte, byte + len, sp.hl }
            end
            if sp.date and len > 0 then
                hitboxes[#hitboxes + 1] = { row = r - 1, c0 = byte, c1 = byte + len, date = sp.date }
            end
            byte = byte + len
        end
        lines[r] = table.concat(parts)
    end
    return lines, hls, hitboxes
end

return M
