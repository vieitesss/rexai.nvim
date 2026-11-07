-- How long ago an Agent status changed.
--
-- The time is Rex's ISO 8601 string. The calendar arithmetic lives here, so
-- the answer is the same under any time zone: no `os.time`, no `os.date`, no
-- clock of the process but the `now` the caller passes in.

local M = {}

local SECONDS_PER_MINUTE = 60
local SECONDS_PER_HOUR = 3600
local SECONDS_PER_DAY = 86400

-- The age below which a status reads as `now`, in seconds.
M.NOW = 5

-- Days from 1970-01-01 to a date of the proleptic Gregorian calendar.
-- Howard Hinnant's `days_from_civil`, which counts the era, the year in it and
-- the day in it, so it needs no table of month lengths and no leap year rule
-- of its own.
---@param year integer
---@param month integer
---@param day integer
---@return integer
local function days_from_civil(year, month, day)
    if month <= 2 then
        year = year - 1
    end
    local era = math.floor(year / 400)
    local year_of_era = year - era * 400
    local month_prime = (month + 9) % 12
    local day_of_year = math.floor((153 * month_prime + 2) / 5) + day - 1
    local day_of_era = year_of_era * 365
        + math.floor(year_of_era / 4)
        - math.floor(year_of_era / 100)
        + day_of_year
    return era * 146097 + day_of_era - 719468
end

-- The offset of a timestamp from UTC, in seconds. The tail is what follows
-- the seconds: a fraction, `Z`, an offset, or nothing at all.
---@param tail string
---@return integer|nil seconds East of UTC, nil when the tail is not an offset
local function offset_of(tail)
    tail = tail:gsub('^%.%d+', '')
    if tail == '' or tail == 'Z' or tail == 'z' then
        return 0
    end

    local sign, hours, minutes = tail:match('^([%+%-])(%d%d):(%d%d)$')
    if not sign then
        return nil
    end
    local seconds = tonumber(hours) * SECONDS_PER_HOUR
        + tonumber(minutes) * SECONDS_PER_MINUTE
    if sign == '-' then
        return -seconds
    end
    return seconds
end

-- Epoch seconds of an ISO 8601 timestamp, with or without a fraction and an
-- offset. Nil when the text is not a timestamp.
---@param text string|nil
---@return integer|nil
local function epoch(text)
    if type(text) ~= 'string' then
        return nil
    end

    local year, month, day, hour, minute, second =
        text:match('^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)')
    if not year then
        return nil
    end

    year, month, day = tonumber(year), tonumber(month), tonumber(day)
    hour, minute, second = tonumber(hour), tonumber(minute), tonumber(second)
    if
        month < 1
        or month > 12
        or day < 1
        or day > 31
        or hour > 23
        or minute > 59
        or second > 59
    then
        return nil
    end

    local offset = offset_of(text:sub(20))
    if not offset then
        return nil
    end

    return days_from_civil(year, month, day) * SECONDS_PER_DAY
        + hour * SECONDS_PER_HOUR
        + minute * SECONDS_PER_MINUTE
        + second
        - offset
end

-- A short age: `now`, then seconds, minutes, hours and days. A status from a
-- time the process has not reached yet is `0s`. Anything unreadable is empty,
-- so a row shows nothing rather than a wrong age.
---@param updated_at string|nil ISO 8601 time of the last status change
---@param now number epoch seconds
---@return string
function M.format(updated_at, now)
    if type(now) ~= 'number' then
        return ''
    end
    local then_at = epoch(updated_at)
    if not then_at then
        return ''
    end

    local seconds = math.floor(now - then_at)
    if seconds < 0 then
        return '0s'
    end

    if seconds < M.NOW then
        return 'now'
    elseif seconds < SECONDS_PER_MINUTE then
        return seconds .. 's'
    elseif seconds < SECONDS_PER_HOUR then
        return math.floor(seconds / SECONDS_PER_MINUTE) .. 'm'
    elseif seconds < SECONDS_PER_DAY then
        return math.floor(seconds / SECONDS_PER_HOUR) .. 'h'
    end
    return math.floor(seconds / SECONDS_PER_DAY) .. 'd'
end

return M
