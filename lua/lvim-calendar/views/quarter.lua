-- lvim-calendar.views.quarter: the Emacs calendar strip — previous / CURRENT / next month side by
-- side. The cursor month is ALWAYS the center block: navigation past an edge lands the cursor in
-- an adjacent month, and since the strip is derived from the cursor month on every build, the
-- strip re-centers itself — exactly like Emacs re-scrolls its three-month window.
--
---@module "lvim-calendar.views.quarter"

local grid = require("lvim-calendar.views.grid")
local model = require("lvim-calendar.model")

local M = {}

---@type integer  display cells between the three month blocks
local GAP = 4

--- Build the quarter view centered on the cursor month.
---@param ctx LvimCalendarGridCtx
---@return LvimCalendarBlock
function M.build(ctx)
    ctx.compact = true -- the same compact grid as the month / year views
    ctx.heading = "full"
    local anchor = { y = ctx.cursor.y, m = ctx.cursor.m, d = 1 }
    local prev = model.shift_months(anchor, -1)
    local next_ = model.shift_months(anchor, 1)
    return grid.hjoin({
        grid.month_block(prev.y, prev.m, ctx),
        grid.month_block(anchor.y, anchor.m, ctx),
        grid.month_block(next_.y, next_.m, ctx),
    }, GAP)
end

return M
