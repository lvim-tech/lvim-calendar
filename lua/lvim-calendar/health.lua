-- lvim-calendar: :checkhealth lvim-calendar.
-- Reports the UI/palette base (lvim-ui chassis + lvim-utils), verifies the configured glyphs are
-- single-width (the grid's fixed cell boxes break on a double-width icon), and lists every
-- registered entry source with its cache state (months cached + generation). Read-only.
--
---@module "lvim-calendar.health"

local config = require("lvim-calendar.config")
local sources = require("lvim-calendar.sources")

local M = {}

--- Entry point for `:checkhealth lvim-calendar`.
---@return nil
function M.check()
    local health = vim.health
    health.start("lvim-calendar")

    if pcall(require, "lvim-ui.surface") then
        health.ok("lvim-ui found (the surface chassis renders the panel)")
    else
        health.error("lvim-ui not found — the calendar panel cannot open")
    end
    if pcall(require, "lvim-utils.highlight") then
        health.ok("lvim-utils found (palette + self-theming)")
    else
        health.error("lvim-utils not found — the calendar highlights cannot derive")
    end

    -- every glyph rendered into a fixed-width cell/lead box must be single-width
    for name, glyph in pairs(config.icons) do
        local w = vim.fn.strdisplaywidth(glyph)
        if w == 1 then
            health.ok(string.format("icons.%s %q is single-width", name, glyph))
        else
            health.warn(
                string.format("icons.%s %q is %d cells wide — the grid columns will misalign", name, glyph, w)
            )
        end
    end

    local list = sources.list()
    if #list == 0 then
        health.info("no sources registered yet — setup() registers the built-in holidays/dates")
    end
    local stats = sources.stats()
    for _, src in ipairs(list) do
        local s = stats[src.name] or { months = 0, generation = 0 }
        local caps = {}
        if src.on_open then
            caps[#caps + 1] = "on_open"
        end
        if src.on_create then
            caps[#caps + 1] = "on_create"
        end
        health.ok(
            string.format(
                "source %q (accent %s): %d month(s) cached, generation %d%s",
                src.name,
                src.accent or "green",
                s.months,
                s.generation,
                #caps > 0 and (", " .. table.concat(caps, "+")) or ""
            )
        )
        if src.icon and vim.fn.strdisplaywidth(src.icon) ~= 1 then
            health.warn(string.format("source %q icon %q is not single-width", src.name, src.icon))
        end
    end

    health.info(string.format("defaults: view=%s layout=%s first_day=%s", config.view, config.layout, config.first_day))
end

return M
