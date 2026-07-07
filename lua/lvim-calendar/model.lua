-- lvim-calendar.model: the pure date math — month grids, day/week/month/year shifts, ISO week
-- numbers, date ⇄ string conversion, and the goto-date parser. No UI, no sources: every view is a
-- consumer of this module, so it is deliberately side-effect free and headless-testable.
--
-- Dates are plain `{ y, m, d }` tables internally and ISO "YYYY-MM-DD" strings at the source-API
-- boundary. Arithmetic that crosses month/year edges goes through os.time/os.date with `hour = 12`:
-- noon is immune to the DST wall-clock jumps (a spring-forward day is 23h long, so midnight ± 86400s
-- can land on the SAME calendar day twice or skip one; noon never does). Month shifts are done in
-- month-index arithmetic (not seconds) so "Jan 31 + 1 month" clamps to Feb 28/29 instead of
-- overflowing into March.
--
---@module "lvim-calendar.model"

local M = {}

---@class LvimCalendarDate
---@field y integer  year (full, e.g. 2026)
---@field m integer  month 1..12
---@field d integer  day 1..31

---@type string[]  English month names, indexed 1..12 (locale-independent — os.date("%B") follows LC_TIME)
M.MONTHS = {
    "January",
    "February",
    "March",
    "April",
    "May",
    "June",
    "July",
    "August",
    "September",
    "October",
    "November",
    "December",
}

---@type string[]  Two-letter weekday labels, Monday-first (re-ordered per config.first_day at render)
M.WEEKDAYS = { "Mo", "Tu", "We", "Th", "Fr", "Sa", "Su" }

---@type string[]  Full weekday names, Monday-first (agenda section headers)
M.WEEKDAY_NAMES = { "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday" }

-- ── basics ───────────────────────────────────────────────────────────────────

--- Gregorian leap year: divisible by 4, except century years unless divisible by 400
--- (1900 was not a leap year, 2000 was).
---@param y integer
---@return boolean
function M.is_leap(y)
    return (y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0
end

---@type integer[]  Month lengths of a NON-leap year; February is patched by days_in_month.
local MONTH_DAYS = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

--- Number of days in month `m` of year `y`.
---@param y integer
---@param m integer  1..12
---@return integer
function M.days_in_month(y, m)
    if m == 2 and M.is_leap(y) then
        return 29
    end
    return MONTH_DAYS[m]
end

--- Today as a date table (local time).
---@return LvimCalendarDate
function M.today()
    local t = os.date("*t") --[[@as osdate]]
    return { y = t.year, m = t.month, d = t.day }
end

--- ISO weekday of a date: 1 = Monday .. 7 = Sunday. os.date("*t").wday is 1 = SUNDAY .. 7 =
--- Saturday, so shift by one and wrap Sunday to 7.
---@param date LvimCalendarDate
---@return integer
function M.weekday(date)
    local t = os.date("*t", os.time({ year = date.y, month = date.m, day = date.d, hour = 12 })) --[[@as osdate]]
    return (t.wday + 5) % 7 + 1
end

--- Compare two dates; -1 / 0 / 1 for a < b / a == b / a > b.
---@param a LvimCalendarDate
---@param b LvimCalendarDate
---@return integer
function M.cmp(a, b)
    local ka = a.y * 10000 + a.m * 100 + a.d
    local kb = b.y * 10000 + b.m * 100 + b.d
    if ka < kb then
        return -1
    elseif ka > kb then
        return 1
    end
    return 0
end

-- ── string boundary ──────────────────────────────────────────────────────────

--- Format a date as the ISO "YYYY-MM-DD" string (the source-API shape).
---@param date LvimCalendarDate
---@return string
function M.to_string(date)
    return string.format("%04d-%02d-%02d", date.y, date.m, date.d)
end

--- Parse an ISO "YYYY-MM-DD" string into a date table; nil for a malformed or impossible date
--- (2026-02-30 is rejected, not normalised — the boundary must not silently move an entry).
---@param s string
---@return LvimCalendarDate?
function M.from_string(s)
    if type(s) ~= "string" then
        return nil
    end
    local y, m, d = s:match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
    if not y then
        return nil
    end
    local yy, mm, dd = tonumber(y), tonumber(m), tonumber(d)
    if not (yy and mm and dd) or mm < 1 or mm > 12 or dd < 1 or dd > M.days_in_month(yy, mm) then
        return nil
    end
    return { y = yy, m = mm, d = dd }
end

--- Format a date via os.date `fmt` (the config.insert_format path).
---@param date LvimCalendarDate
---@param fmt string
---@return string
function M.format(date, fmt)
    return tostring(os.date(fmt, os.time({ year = date.y, month = date.m, day = date.d, hour = 12 })))
end

-- ── shifts ───────────────────────────────────────────────────────────────────

--- Shift a date by `n` days (n may be negative). Noon-based (see the module header) so DST
--- transitions never skip or repeat a calendar day.
---@param date LvimCalendarDate
---@param n integer
---@return LvimCalendarDate
function M.shift_days(date, n)
    local t = os.date("*t", os.time({ year = date.y, month = date.m, day = date.d, hour = 12 }) + n * 86400) --[[@as osdate]]
    return { y = t.year, m = t.month, d = t.day }
end

--- Shift a date by `n` months, keeping the day-of-month and CLAMPING it to the target month's
--- length (Jan 31 + 1 month = Feb 28/29 — month-index arithmetic, never seconds).
---@param date LvimCalendarDate
---@param n integer
---@return LvimCalendarDate
function M.shift_months(date, n)
    local mi = date.m - 1 + n
    local y = date.y + math.floor(mi / 12)
    local m = mi % 12 + 1
    return { y = y, m = m, d = math.min(date.d, M.days_in_month(y, m)) }
end

--- Shift a date by `n` years (Feb 29 clamps to Feb 28 on a non-leap target).
---@param date LvimCalendarDate
---@param n integer
---@return LvimCalendarDate
function M.shift_years(date, n)
    local y = date.y + n
    return { y = y, m = date.m, d = math.min(date.d, M.days_in_month(y, date.m)) }
end

-- ── weeks ────────────────────────────────────────────────────────────────────

--- The column (1..7) a date occupies in a grid that starts on `first_day`.
--- With "monday" the offset is 0 (ISO weekday IS the column); with "sunday" the week rotates one
--- left, so Sunday (ISO 7) becomes column 1.
---@param date LvimCalendarDate
---@param first_day "monday"|"sunday"
---@return integer
function M.week_col(date, first_day)
    local wd = M.weekday(date)
    if first_day == "sunday" then
        return wd % 7 + 1
    end
    return wd
end

--- First day of the week containing `date` for the given week start.
---@param date LvimCalendarDate
---@param first_day "monday"|"sunday"
---@return LvimCalendarDate
function M.week_start(date, first_day)
    return M.shift_days(date, 1 - M.week_col(date, first_day))
end

--- The "week-parity" anchor weekday of Jan 1st used by the ISO week formula: the ISO weekday of
--- Dec 31st of year `y` (0 = Monday .. 6 = Sunday in this helper's own 0-based terms).
---@param y integer
---@return integer
local function iso_p(y)
    return (y + math.floor(y / 4) - math.floor(y / 100) + math.floor(y / 400)) % 7
end

--- Number of ISO weeks in year `y` (52, or 53 when the year starts or — after a leap year —
--- ends on a Thursday).
---@param y integer
---@return integer
function M.iso_weeks_in_year(y)
    return (iso_p(y) == 4 or iso_p(y - 1) == 3) and 53 or 52
end

--- ISO 8601 week number of a date, computed in pure Lua (strftime "%V" is not portable across
--- neovim's platforms). Standard formula: week = floor((yday - isowday + 10) / 7); a result of 0
--- belongs to the LAST week of the previous year, one past the year's week count to week 1 of the
--- next.
---@param date LvimCalendarDate
---@return integer
function M.iso_week(date)
    local t = os.date("*t", os.time({ year = date.y, month = date.m, day = date.d, hour = 12 })) --[[@as osdate]]
    local isowd = (t.wday + 5) % 7 + 1
    local week = math.floor((t.yday - isowd + 10) / 7)
    if week < 1 then
        return M.iso_weeks_in_year(date.y - 1)
    elseif week > M.iso_weeks_in_year(date.y) then
        return 1
    end
    return week
end

-- ── the month grid ───────────────────────────────────────────────────────────

---@class LvimCalendarCell
---@field date LvimCalendarDate
---@field other boolean  true when the cell belongs to the previous/next month (grid padding)

--- Build the week-aligned grid of month `m`/`y`: a list of week rows, each exactly 7 cells,
--- padded with the previous month's tail and the next month's head so every row is full. The
--- number of rows is the month's REAL week span (4..6 — never a fixed 6, so a 4-week February
--- renders no phantom rows).
---@param y integer
---@param m integer
---@param first_day "monday"|"sunday"
---@return LvimCalendarCell[][] weeks
function M.month_grid(y, m, first_day)
    local first = { y = y, m = m, d = 1 }
    local lead = M.week_col(first, first_day) - 1 -- other-month cells before the 1st
    local total = M.days_in_month(y, m)
    local rows = math.ceil((lead + total) / 7)
    local weeks = {}
    local cur = M.shift_days(first, -lead) -- the grid's top-left cell
    for _ = 1, rows do
        local row = {}
        for _ = 1, 7 do
            row[#row + 1] = { date = cur, other = not (cur.m == m and cur.y == y) }
            cur = M.shift_days(cur, 1)
        end
        weeks[#weeks + 1] = row
    end
    return weeks
end

--- Whether a date falls on a weekend (Saturday/Sunday — ISO weekday 6/7, independent of the
--- configured grid start).
---@param date LvimCalendarDate
---@return boolean
function M.is_weekend(date)
    local wd = M.weekday(date)
    return wd == 6 or wd == 7
end

-- ── ranges ───────────────────────────────────────────────────────────────────

--- Inclusive ISO-string range `{ from, to }` covering whole month `m`/`y` (the shape the source
--- API consumes).
---@param y integer
---@param m integer
---@return { from: string, to: string }
function M.month_range(y, m)
    return {
        from = string.format("%04d-%02d-01", y, m),
        to = string.format("%04d-%02d-%02d", y, m, M.days_in_month(y, m)),
    }
end

--- Iterate the dates of an inclusive `{ from, to }` ISO range in order. Returns an empty list for
--- a malformed or inverted range.
---@param range { from: string, to: string }
---@return LvimCalendarDate[]
function M.range_dates(range)
    local from = M.from_string(range.from)
    local to = M.from_string(range.to)
    local out = {}
    if not from or not to or M.cmp(from, to) > 0 then
        return out
    end
    local cur = from
    while M.cmp(cur, to) <= 0 do
        out[#out + 1] = cur
        cur = M.shift_days(cur, 1)
    end
    return out
end

-- ── the goto-date parser ─────────────────────────────────────────────────────

--- Parse a goto-date prompt string relative to `base`. Accepted forms:
---   "2026-07-06"          absolute ISO
---   "06.07" / "6.7"        day.month of the base year
---   "06.07.2026"           day.month.year
---   "+3d" / "-2w" / "+1m" / "-1y"   relative offset in days/weeks/months/years
---   "" / "t"               today
--- Returns nil for anything unparseable or an impossible date.
---@param input string
---@param base LvimCalendarDate
---@return LvimCalendarDate?
function M.parse_goto(input, base)
    local s = vim.trim(input or "")
    if s == "" or s == "t" or s == "today" then
        return M.today()
    end
    -- absolute ISO
    local abs = M.from_string(s)
    if abs then
        return abs
    end
    -- relative: sign + count + unit
    local sign, count, unit = s:match("^([+-])(%d+)([dwmy])$")
    if sign then
        local n = tonumber(count) or 0
        if sign == "-" then
            n = -n
        end
        if unit == "d" then
            return M.shift_days(base, n)
        elseif unit == "w" then
            return M.shift_days(base, n * 7)
        elseif unit == "m" then
            return M.shift_months(base, n)
        end
        return M.shift_years(base, n)
    end
    -- day.month[.year] (the European short form)
    local d, m, y = s:match("^(%d%d?)%.(%d%d?)%.(%d%d%d%d)$")
    if not d then
        d, m = s:match("^(%d%d?)%.(%d%d?)$")
        y = tostring(base.y)
    end
    if d then
        local dd, mm, yy = tonumber(d), tonumber(m), tonumber(y)
        if dd and mm and yy and mm >= 1 and mm <= 12 and dd >= 1 and dd <= M.days_in_month(yy, mm) then
            return { y = yy, m = mm, d = dd }
        end
    end
    return nil
end

return M
