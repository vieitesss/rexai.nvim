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

---@class rexai.WindowSpec what `create_window` creates
---@field session_id string the Session the Window goes into
---@field name string|nil the Window label
---@field cwd string|nil the directory its Block starts in
---@field command string[]|nil a list of words, run through the login shell
---@field keep_open boolean|nil keep the Window after its command exits
---@field focus boolean|nil false leaves the current focus alone

---@class rexai.SessionSpec what `create_session` creates
---@field name string|nil the Session label
---@field cwd string|nil the directory its first Block starts in
---@field window string|nil the label of the first Window
---@field command string[]|nil a list of words, run through the login shell
---@field keep_open boolean|nil keep the Window after its command exits

---@class rexai.Backend
---@field snapshot fun(callback: fun(err: string|nil, snapshot: table|nil))
---@field focus fun(target: rexai.Target, callback: fun(err: string|nil))
---@field create_window fun(spec: rexai.WindowSpec, callback: fun(err: string|nil, target: rexai.Target|nil))
---@field create_session fun(spec: rexai.SessionSpec, callback: fun(err: string|nil, target: rexai.Target|nil))
---@field peek fun(target: rexai.Target, callback: fun(err: string|nil, text: string|nil))
---@field subscribe (fun(on_event: fun()): fun())|nil optional: push events instead of polling

local M = {}

-- Methods every Backend must have. `subscribe` is optional.
M.METHODS = { 'snapshot', 'focus', 'create_window', 'create_session', 'peek' }

return M
