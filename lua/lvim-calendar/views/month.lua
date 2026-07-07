-- lvim-calendar.views.month: the single-month view — one full-size grid block with its
-- "Month Year" heading. The simplest layout over the shared cell renderer; quarter and year are
-- compositions of the same block.
--
---@module "lvim-calendar.views.month"

local grid = require("lvim-calendar.views.grid")

local M = {}

--- Build the month view for the cursor month.
---@param ctx LvimCalendarGridCtx
---@return LvimCalendarBlock
function M.build(ctx)
    ctx.compact = false
    ctx.heading = "full"
    return grid.month_block(ctx.cursor.y, ctx.cursor.m, ctx)
end

return M
