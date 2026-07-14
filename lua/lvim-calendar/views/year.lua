-- lvim-calendar.views.year: 12 compact mini-months in a responsive grid — 4 columns when the
-- editor is wide enough, 3 otherwise (the panel re-asks on every build, so a resize relayouts).
-- Mini-month cells are 3-wide (`17•`) with marks collapsed to the dot; a centered year heading
-- tops the block. <CR> picks the day under the cursor, exactly as in the month / quarter views.
--
---@module "lvim-calendar.views.year"

local grid = require("lvim-calendar.views.grid")

local M = {}

---@type integer  a compact month block is exactly 7 * 3 cells wide
local BLOCK_W = 21
---@type integer  display cells between mini-month columns
local GAP = 4

--- Columns that fit a width: 4 when the editor can host them, else 3 (the plan's 3×4 / 4×3).
---@param avail integer  available display width
---@return integer
function M.columns(avail)
    return avail >= 4 * BLOCK_W + 3 * GAP and 4 or 3
end

--- Build the year view for the cursor year.
---@param ctx LvimCalendarGridCtx
---@param cols integer  mini-months per row (3 or 4)
---@return LvimCalendarBlock
function M.build(ctx, cols)
    ctx.compact = true
    ctx.heading = "month"
    ctx.week_numbers = false -- a mini-month has no room for a week column
    local band_rows = {}
    local m = 1
    while m <= 12 do
        local blocks = {}
        for _ = 1, cols do
            if m <= 12 then
                blocks[#blocks + 1] = grid.month_block(ctx.cursor.y, m, ctx)
                m = m + 1
            end
        end
        band_rows[#band_rows + 1] = grid.hjoin(blocks, GAP)
    end
    local body = grid.vjoin(band_rows)
    -- the year heading + a blank spacer, prepended AFTER vjoin so the cursor row offset is exact
    local ys = tostring(ctx.cursor.y)
    local head = {
        rows = {
            {
                { text = string.rep(" ", math.floor((body.width - #ys) / 2)) },
                { text = ys, hl = "LvimCalendarHeading" },
            },
        },
        width = body.width,
    }
    return grid.vjoin({ head, body })
end

return M
