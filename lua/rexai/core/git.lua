-- The git slot of an Agent row: `git status --porcelain=v2 --branch` in, the
-- slot text out.
--
-- This module is pure. It touches neither Neovim nor git, so it runs in
-- Neovim's LuaJIT and in Rex's Lua 5.1.

local M = {}

-- Between the repository and the rest of the slot.
M.SEPARATOR = ' · '

-- A detached HEAD shows this many characters of its commit id.
M.SHORT_OID = 7

---@class rexai.GitInfo the state of one work tree
---@field branch string|nil the branch name; nil when HEAD is detached
---@field oid string|nil the commit HEAD points at; nil before the first commit
---@field detached boolean
---@field ahead integer commits the upstream has not seen; 0 without one
---@field behind integer commits the local branch has not seen; 0 without one
---@field changed integer changed paths, untracked included
---@field repo string|nil the directory name of the work tree root
---@field root string|nil the work tree root itself

---@param value any
---@return integer
local function count(value)
    local number = tonumber(value)
    if not number or number < 0 then
        return 0
    end
    return math.floor(number)
end

-- The first character of an entry line says what the entry is. A header is
-- `#` and an ignored path is `!`; neither is a change.
local ENTRY = { ['1'] = true, ['2'] = true, u = true, ['?'] = true }

-- Reads porcelain v2. Anything git did not print stays at its empty value, so
-- an empty or unexpected text never raises.
---@param text string|nil
---@return rexai.GitInfo
function M.parse_status(text)
    local info = {
        branch = nil,
        oid = nil,
        detached = false,
        ahead = 0,
        behind = 0,
        changed = 0,
    }

    for line in tostring(text or ''):gmatch('[^\r\n]+') do
        local first = line:sub(1, 1)
        if first == '#' then
            local key, value = line:match('^# ([^ ]+) ?(.*)$')
            if key == 'branch.oid' and value ~= '(initial)' and value ~= '' then
                info.oid = value
            elseif key == 'branch.head' then
                if value == '(detached)' then
                    info.detached = true
                elseif value ~= '' then
                    info.branch = value
                end
            elseif key == 'branch.ab' then
                local ahead, behind = value:match('^%+(%d+) %-(%d+)$')
                info.ahead = count(ahead)
                info.behind = count(behind)
            end
        elseif ENTRY[first] then
            info.changed = info.changed + 1
        end
    end

    return info
end

-- The branch, or the short commit id of a detached HEAD.
---@param info rexai.GitInfo
---@return string|nil
local function name(info)
    if info.branch then
        return info.branch
    end
    if info.detached and info.oid and #info.oid >= M.SHORT_OID then
        return info.oid:sub(1, M.SHORT_OID)
    end
    return nil
end

-- `repo · branch ↑ahead ↓behind ●changed`, leaving out every zero count.
---@param info rexai.GitInfo
---@return string
function M.format(info)
    local text = tostring(info.repo or '')
    local branch = name(info)
    if branch then
        text = text .. M.SEPARATOR .. branch
    end

    if count(info.ahead) > 0 then
        text = text .. ' ↑' .. count(info.ahead)
    end
    if count(info.behind) > 0 then
        text = text .. ' ↓' .. count(info.behind)
    end
    if count(info.changed) > 0 then
        text = text .. ' ●' .. count(info.changed)
    end
    return text
end

return M
