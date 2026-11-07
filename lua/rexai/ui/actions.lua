-- The Dashboard actions on the target under the cursor: `<CR>` goes to the
-- Agent block or Session and `d` hands the row to the `review` hook. One
-- object per Dashboard lifetime: it is bound to the Backend, the data object
-- and the hooks object it was created with, and `dispose` makes every pending
-- continuation a no-op, so a result never acts on a Dashboard that did not
-- issue the request.

local M = {}

---@class rexai.ActionsOpts
---@field backend rexai.Backend the Backend the requests go to
---@field data rexai.Data the rows the actions read
---@field hooks rexai.Hooks what `review` calls
---@field refresh fun() asks Rex again now
---@field current_target fun(): rexai.RenderTarget|nil the target under the cursor

---@class rexai.Actions
---@field focus fun(self: rexai.Actions) goes to the Agent block or Session
---@field review fun(self: rexai.Actions) reviews the Agent block of the row
---@field dispose fun(self: rexai.Actions) drops every pending continuation

---@param opts rexai.ActionsOpts
---@return rexai.Actions
function M.new(opts)
    local backend = assert(opts.backend, 'actions need a Backend')
    local data = assert(opts.data, 'actions need a data object')
    local hooks = assert(opts.hooks, 'actions need a hooks object')
    local refresh = assert(opts.refresh, 'actions need a refresh function')
    local current_target =
        assert(opts.current_target, 'actions need a current_target reader')

    local disposed = false

    local object = {}

    ---@param message string
    ---@param level integer|nil INFO unless said
    local function notify(message, level)
        vim.notify('rexai: ' .. message, level or vim.log.levels.INFO)
    end

    -- The continuation of a request. It does nothing once the Dashboard that
    -- issued it is gone, so a late result neither notifies a replacement
    -- Dashboard nor makes its Backend take a snapshot.
    ---@param callback fun(...)
    ---@return fun(...)
    local function guard(callback)
        return function(...)
            if disposed then
                return
            end
            callback(...)
        end
    end

    -- `<CR>`: goes to the Agent block under the cursor, or to the Session of a
    -- header. Rex changes the view itself, so only a failure needs an answer:
    -- the target has probably vanished, and the Dashboard asks Rex again.
    function object.focus(_)
        if disposed then
            return
        end
        local target = current_target()
        if not target then
            return
        end

        local request = { session_id = target.session_id }
        if target.kind == 'row' then
            request.window_id = target.window_id
            request.block_id = target.block_id
        end

        backend.focus(
            request,
            guard(function(err)
                if not err then
                    return
                end
                notify(err, vim.log.levels.WARN)
                refresh()
            end)
        )
    end

    -- What `review` gets for one row: the directory it stands for, what git
    -- knows about it, and the row itself.
    ---@param ctx rexai.RowContext
    ---@return table
    local function review_ctx(ctx)
        local info = ctx.git
        return {
            path = ctx.path,
            repo_root = info and info.root or nil,
            branch = info and info.branch or nil,
            session = { id = ctx.session.id, label = ctx.session.label },
            window = { id = ctx.row.window_id },
            block = vim.deepcopy(ctx.row),
        }
    end

    -- `d`: hands the row under the cursor to the `review` hook. A miss says
    -- why, in the order a user runs into it: no row, no directory, no hook
    -- set.
    function object.review(_)
        if disposed then
            return
        end
        local target = current_target()
        local ctx
        if target and target.kind == 'row' then
            ctx = data:context(target.block_id)
        end
        if not ctx then
            return notify('put the cursor on an Agent block')
        end
        if not ctx.path then
            return notify('this Block has no directory to review')
        end
        hooks:review(review_ctx(ctx))
    end

    function object.dispose(_)
        disposed = true
    end

    return object
end

return M
