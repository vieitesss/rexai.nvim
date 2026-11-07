-- Names for new Sessions, taken from the directory they start in.

local M = {}

---@param path string
---@return string[]
local function split(path)
    local parts = {}
    for part in path:gmatch('[^/]+') do
        parts[#parts + 1] = part
    end
    return parts
end

---@param parts string[]
---@param prefix string[]
---@return boolean
local function starts_with(parts, prefix)
    for index, part in ipairs(prefix) do
        if parts[index] ~= part then
            return false
        end
    end
    return true
end

-- The last two path components joined by `_`, with dots turned into `_`. A
-- directory directly under `home`, or `home` itself, uses only its own name.
--
--   /Users/ana/code/app.web  ->  code_app_web
--   /Users/ana/app.web       ->  app_web
---@param path string
---@param home string|nil
---@return string
function M.from_path(path, home)
    local parts = split(path)
    if #parts == 0 then
        return 'session'
    end

    local home_parts = split(home or '')
    local name
    if
        #home_parts > 0
        and #parts <= #home_parts + 1
        and starts_with(parts, home_parts)
    then
        name = parts[#parts]
    elseif #parts == 1 then
        name = parts[1]
    else
        name = parts[#parts - 1] .. '_' .. parts[#parts]
    end
    return (name:gsub('%.', '_'))
end

return M
