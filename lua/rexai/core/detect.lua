-- Agent detection: is this Block an Agent block, and which harness runs it?

local M = {}

---@param list string[]|nil
---@return table<string, boolean>
local function set(list)
    local out = {}
    for _, value in ipairs(list or {}) do
        out[value] = true
    end
    return out
end

---@param path string
---@return string
function M.basename(path)
    return path:match('([^/]+)$') or path
end

---@class rexai.Agents
---@field apps string[] `app` strings from program status records
---@field commands string[] foreground command names (basename of argv0)
---@field launch table<string, string[]>|nil full argv by agent command name

-- A Block is an Agent block when a status record names an app in
-- `agents.apps`, or its foreground command is in `agents.commands`. The app
-- wins, so a Block that reports status keeps its reported name.
---@param block table a Block from the snapshot
---@param agents rexai.Agents
---@return string|nil harness
function M.harness(block, agents)
    local apps = set(agents.apps)
    for _, record in ipairs(block.records or {}) do
        if record.app and apps[record.app] then
            return record.app
        end
    end

    local argv0 = block.process and block.process.argv0
    if argv0 and argv0 ~= '' then
        local command = M.basename(argv0)
        if set(agents.commands)[command] then
            return command
        end
    end
    return nil
end

return M
