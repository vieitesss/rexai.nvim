-- Agent status: what an Agent block says it is doing.
--
-- Rex reports `idle`, `working`, `done`, `blocked` and `error`. The plugin
-- renames `blocked` to `needs_input` and adds two statuses of its own:
-- `unreported` (an agent that says nothing) and `exited` (an agent that has
-- ended while its Block stays open).

local M = {}

-- Highest priority first. A Session shows the highest of its rows.
M.ORDER = {
    'needs_input',
    'error',
    'done',
    'working',
    'unreported',
    'idle',
    'exited',
}

local RANK = {}
for index, name in ipairs(M.ORDER) do
    RANK[name] = index
end

local FROM_REX = {
    blocked = 'needs_input',
    error = 'error',
    done = 'done',
    working = 'working',
    idle = 'idle',
}

---@param name string
---@return integer|nil rank 1 is the highest priority; nil for an unknown name
function M.rank(name)
    return RANK[name]
end

---@class rexai.Status
---@field name string one of `M.ORDER`
---@field kind string|nil `permission`, `question` or `auth`, only for `needs_input`
---@field msg string|nil
---@field updated_at string|nil

-- A state Rex does not report as a status (`clear`, or one added later) gives
-- nil, so a newer Rex never breaks the Dashboard.
---@param record table one Rex program status record
---@return rexai.Status|nil
function M.from_record(record)
    local name = FROM_REX[record.state]
    if not name then
        return nil
    end
    return {
        name = name,
        kind = name == 'needs_input' and record.kind or nil,
        msg = record.msg,
        updated_at = record.updated_at,
    }
end

-- A Block can carry several records. The highest-priority one wins. With none
-- that map to a status, the agent says nothing.
---@param records table[]|nil
---@return rexai.Status
function M.of_records(records)
    local best
    for _, record in ipairs(records or {}) do
        local status = M.from_record(record)
        if status and (not best or RANK[status.name] < RANK[best.name]) then
            best = status
        end
    end
    return best or { name = 'unreported' }
end

---@param names string[] status names; unknown names are ignored
---@return string|nil name the highest-priority one, nil for an empty list
function M.rollup(names)
    local best
    for _, name in ipairs(names) do
        if RANK[name] and (not best or RANK[name] < RANK[best]) then
            best = name
        end
    end
    return best
end

return M
