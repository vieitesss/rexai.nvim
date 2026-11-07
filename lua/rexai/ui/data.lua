-- What the Dashboard derives from the snapshot Rex accepted: the model
-- Sessions, what Rex calls the Home session and the directory of every row.
-- The keys look a row up here instead of joining the Session, path and git
-- maps themselves.

local config = require('rexai.config')
local model = require('rexai.core.model')

local M = {}

---@class rexai.RowContext one Agent row and what an action needs about it
---@field row rexai.Row
---@field session rexai.ModelSession
---@field path string|nil the directory the row stands for
---@field git rexai.GitInfo|nil what the git cache knows about `path`

---@class rexai.DataOpts
---@field hooks rexai.Hooks
---@field git rexai.Git|nil
---@field memory rexai.Memory|nil remembers Agent blocks across snapshots

---@class rexai.Data
---@field accept fun(self: rexai.Data, snapshot: table, home_session_id: string|nil)
---@field clear fun(self: rexai.Data)
---@field sessions fun(self: rexai.Data): rexai.ModelSession[]|nil
---@field home_label fun(self: rexai.Data): string|nil
---@field context fun(self: rexai.Data, block_id: string): rexai.RowContext|nil

-- What Rex calls the Home session, from the snapshot itself: the model drops a
-- Session with no Agent blocks, so its name is lost with it.
---@param snapshot table
---@param home_session_id string|nil
---@return string|nil
local function label_of_home(snapshot, home_session_id)
    for _, session in ipairs(snapshot.sessions or {}) do
        if session.id == home_session_id then
            return session.label
        end
    end
end

---@param opts rexai.DataOpts
---@return rexai.Data
function M.new(opts)
    opts = opts or {}
    local hooks = assert(opts.hooks, 'data needs a hooks object')
    local git = opts.git
    local memory = opts.memory or model.new_memory()

    local sessions
    local home_label

    -- One entry per Agent row of the accepted snapshot, by Block id. The path
    -- hook runs once for each of them here, Exited rows included, so a redraw
    -- or an action reuses its result.
    ---@type table<string, { row: rexai.Row, session: rexai.ModelSession, path: string|nil }>
    local rows = {}

    local object = {}

    -- Takes a snapshot Rex accepted: builds the Sessions the render shows,
    -- captures the Home label and resolves the path of every row.
    ---@param snapshot table
    ---@param home_session_id string|nil
    function object.accept(_, snapshot, home_session_id)
        sessions = model.build(snapshot, config.get().agents, memory)
        home_label = label_of_home(snapshot, home_session_id)

        rows = {}
        for _, session in ipairs(sessions) do
            for _, row in ipairs(session.rows) do
                rows[row.block_id] = {
                    row = row,
                    session = session,
                    path = hooks:resolve(row),
                }
            end
        end
    end

    -- The rows of the last accepted snapshot are stale once Rex cannot be
    -- read, so the Dashboard drops them all.
    function object.clear(_)
        sessions, home_label, rows = nil, nil, {}
    end

    ---@return rexai.ModelSession[]|nil
    function object.sessions(_)
        return sessions
    end

    ---@return string|nil
    function object.home_label(_)
        return home_label
    end

    -- The row and everything an action needs about it: its Session, the
    -- directory it stands for and what git knows about that directory at the
    -- moment of the call.
    ---@param block_id string
    ---@return rexai.RowContext|nil
    function object.context(_, block_id)
        local entry = rows[block_id]
        if not entry then
            return nil
        end
        local info = entry.path and git and git:get(entry.path) or nil
        return {
            row = entry.row,
            session = entry.session,
            path = entry.path,
            git = info,
        }
    end

    return object
end

return M
