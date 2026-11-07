-- The Backend is the only thing that talks to Rex. The Dashboard and the core
-- see this interface and nothing else, so a fake can stand in for Rex.
--
-- Every method takes a callback and calls it as `callback(err, result)`: `err`
-- is a string, or nil on success. A Backend may call the callback before the
-- method returns, or later. Callers must not assume either.

---@class rexai.Target
---@field session_id string
---@field window_id string|nil
---@field block_id string|nil

---@class rexai.Backend
---@field snapshot fun(callback: fun(err: string|nil, snapshot: table|nil))
---@field focus fun(target: rexai.Target, callback: fun(err: string|nil))
---@field create_window fun(spec: table, callback: fun(err: string|nil, target: rexai.Target|nil))
---@field create_session fun(spec: table, callback: fun(err: string|nil, target: rexai.Target|nil))
---@field peek fun(target: rexai.Target, callback: fun(err: string|nil, text: string|nil))
---@field subscribe (fun(on_event: fun()): fun())|nil optional: push events instead of polling

local M = {}

-- Methods every Backend must have. `subscribe` is optional.
M.METHODS = { 'snapshot', 'focus', 'create_window', 'create_session', 'peek' }

return M
