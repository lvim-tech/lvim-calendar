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
    ctx = vim.tbl_extend("force", {}, ctx) -- don't mutate the caller's ctx (see views/year.lua)
    -- COMPACT cells (3-wide, flush) — the same grid the year view draws. A single month rendered with
    -- 4-wide boxes and 1-space gaps reads as "stretched" beside them.
    ctx.compact = true
    ctx.heading = "full"
    return grid.month_block(ctx.cursor.y, ctx.cursor.m, ctx)
end

return M
