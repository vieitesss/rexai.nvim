-- Starting a new Agent block: the argv of an agent and the label of a new
-- Session. Both are pure, so they run in Neovim and in Rex's Lua 5.1.

local session_name = require('rexai.core.session_name')

local M = {}

-- The argv of `agent`: the list the user gave in `launch` when it is a list of
-- words, the name of the agent alone otherwise. The copy belongs to the
-- caller, which may hand it to Rex and change it.
---@param agent string
---@param launch table<string, string[]>|nil
---@return string[]
function M.command(agent, launch)
    local argv = type(launch) == 'table' and launch[agent] or nil
    if type(argv) == 'table' and #argv > 0 then
        local out = {}
        for index = 1, #argv do
            if type(argv[index]) ~= 'string' then
                return { agent }
            end
            out[index] = argv[index]
        end
        return out
    end
    return { agent }
end

-- The label of a Session started in `path`: the string the `session_name` hook
-- gave when it is not empty, the last two directories otherwise.
---@param path string
---@param home string|nil
---@param custom any what the hook returned
---@return string
function M.session_label(path, home, custom)
    if type(custom) == 'string' and custom ~= '' then
        return custom
    end
    return session_name.from_path(path, home)
end

return M
