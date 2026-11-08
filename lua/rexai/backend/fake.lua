-- A Backend that serves prepared snapshots instead of talking to Rex. Tests
-- and demos use it. It calls every callback before the method returns, so
-- tests need no waiting.

local M = {}

---@class rexai.FakeOpts
---@field snapshots table[]|nil served in order; the last one repeats
---@field peek table<string, string>|nil screen text by block id

---@param snapshot table
---@param target rexai.Target
---@return boolean
local function has_target(snapshot, target)
    for _, session in ipairs(snapshot.sessions or {}) do
        if session.id == target.session_id then
            if not target.window_id and not target.block_id then
                return true
            end
            for _, window in ipairs(session.windows or {}) do
                if not target.window_id or window.id == target.window_id then
                    if not target.block_id then
                        return true
                    end
                    for _, block in ipairs(window.blocks or {}) do
                        if block.id == target.block_id then
                            return true
                        end
                    end
                end
            end
        end
    end
    return false
end

---@class rexai.FakeBackend : rexai.Backend
---@field fail_next fun(method: string, message: string) makes the next call fail

---@param opts rexai.FakeOpts
---@return rexai.FakeBackend backend
---@return table[] calls every call made, in order: `{ method, arg }`
function M.new(opts)
    opts = opts or {}
    local snapshots = opts.snapshots or {}
    local served = 0
    local failures = {}
    local created = 0
    local calls = {}

    local backend = {}

    local function current()
        return snapshots[math.min(math.max(served, 1), #snapshots)]
    end

    -- Returns the queued error for `method`, if any, and consumes it.
    local function failure(method)
        local queue = failures[method]
        if queue and #queue > 0 then
            return table.remove(queue, 1)
        end
        return nil
    end

    local function record(method, arg)
        calls[#calls + 1] = { method = method, arg = arg }
    end

    function backend.snapshot(callback)
        record('snapshot')
        local err = failure('snapshot')
        if err then
            return callback(err)
        end
        if #snapshots == 0 then
            return callback('no snapshot prepared')
        end
        served = served + 1
        callback(nil, current())
    end

    function backend.focus(target, callback)
        record('focus', target)
        local err = failure('focus')
        if err then
            return callback(err)
        end
        if not has_target(current() or {}, target) then
            return callback('target not found')
        end
        callback(nil)
    end

    local function create(method)
        return function(spec, callback)
            record(method, spec)
            local err = failure(method)
            if err then
                return callback(err)
            end
            created = created + 1
            callback(nil, {
                session_id = spec.session_id or ('session:fake-' .. created),
                window_id = 'window:fake-' .. created,
                block_id = 'block:fake-' .. created,
            })
        end
    end
    backend.create_window = create('create_window')
    backend.create_session = create('create_session')

    function backend.peek(target, callback)
        record('peek', target)
        local err = failure('peek')
        if err then
            return callback(err)
        end
        if not has_target(current() or {}, target) then
            return callback('target not found')
        end
        callback(nil, (opts.peek or {})[target.block_id] or '')
    end

    -- Makes the next call to `method` fail with `message`.
    ---@param method string
    ---@param message string
    function backend.fail_next(method, message)
        failures[method] = failures[method] or {}
        table.insert(failures[method], message)
    end

    return backend, calls
end

return M
