-- The Dashboard actions on the target under the cursor: `<CR>` goes to the
-- Agent block or Session, `d` hands the row to the `review` hook and `K` peeks
-- at the Agent block. One object per Dashboard lifetime: it is bound to the
-- Backend, the data object and the hooks object it was created with, and
-- `dispose` makes every pending continuation a no-op, so a result never acts
-- on a Dashboard that did not issue the request.

local config = require('rexai.config')
local core_git = require('rexai.core.git')
local core_launch = require('rexai.core.launch')
local core_peek = require('rexai.core.peek')
local float = require('rexai.ui.peek')

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
---@field peek fun(self: rexai.Actions) shows the float of the Agent block
---@field new_window fun(self: rexai.Actions) adds an Agent Window to a Session
---@field new_session fun(self: rexai.Actions) starts a Session with an Agent Window
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

    -- The Block whose float is open, and how many `K` presses there were: only
    -- the newest press shows its result, so a slow one never covers a newer
    -- one.
    local peeked = nil
    local peeks = 0

    -- How many `n` and `N` presses there were: only the newest press creates,
    -- so a second press while the first prompt is open never creates twice.
    local adds = 0

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

    -- `K`: shows the float of the Agent block under the cursor, or enters the
    -- one already open. The result is shown only if it is the newest press,
    -- the cursor is still on that Block and the Dashboard is still there: a
    -- row and its directory are read when the text arrives, not when the key
    -- is pressed.
    function object.peek(_)
        if disposed then
            return
        end
        local target = current_target()
        if not target or target.kind ~= 'row' then
            return notify('put the cursor on an Agent block')
        end
        if peeked == target.block_id and float.is_open() then
            return float.enter()
        end

        local block_id = assert(target.block_id)
        peeks = peeks + 1
        local mine = peeks

        backend.peek(
            {
                session_id = target.session_id,
                window_id = target.window_id,
                block_id = block_id,
            },
            guard(function(err, text)
                if mine ~= peeks then
                    return
                end
                if err then
                    notify(err, vim.log.levels.WARN)
                    return refresh()
                end

                local here = current_target()
                if
                    not here
                    or here.kind ~= 'row'
                    or here.block_id ~= block_id
                then
                    return
                end

                local ctx = data:context(block_id)
                if not ctx then
                    return
                end

                float.show(
                    core_peek.lines({
                        row = ctx.row,
                        path = ctx.path,
                        git = ctx.git and core_git.format(ctx.git) or nil,
                        screen = text,
                    }),
                    vim.api.nvim_get_current_win()
                )
                peeked = block_id
            end)
        )
    end

    -- The directory an answer names: `~` expanded, absolute, without a
    -- trailing slash. An empty answer names none.
    ---@param answer string
    ---@return string|nil
    local function directory(answer)
        if vim.trim(answer) == '' then
            return nil
        end
        return vim.fs.normalize(vim.fn.fnamemodify(answer, ':p'))
    end

    ---@param path string
    ---@return boolean
    local function is_directory(path)
        local stat = vim.uv.fs_stat(path)
        return stat ~= nil and stat.type == 'directory'
    end

    -- The label of a new Session in `path`: what the hooks object gives for
    -- it, or the two last directories.
    ---@param path string
    ---@return string
    local function session_label(path)
        return core_launch.session_label(
            path,
            vim.uv.os_homedir(),
            hooks:session_name(path)
        )
    end

    -- Asks for an agent and a directory and hands both to `create` with the
    -- number of this press. A cancelled prompt ends the flow silently; a press
    -- made after this one makes every continuation of this one return. With no
    -- agent configured there is nothing to choose, so the press only says so.
    ---@param what string 'Window' or 'Session'
    ---@param prefill string|nil directory the prompt starts at
    ---@param create fun(agent: string, dir: string, mine: integer)
    local function ask(what, prefill, create)
        adds = adds + 1
        local mine = adds

        if #config.get().agents.commands == 0 then
            return notify(
                'no agent is configured; set agents.commands in setup()',
                vim.log.levels.WARN
            )
        end

        vim.ui.select(
            config.get().agents.commands,
            {
                prompt = 'Agent for the new ' .. what,
            },
            guard(function(agent)
                if mine ~= adds or agent == nil then
                    return
                end
                vim.ui.input(
                    {
                        prompt = 'Directory of the new ' .. what,
                        default = prefill,
                    },
                    guard(function(answer)
                        if mine ~= adds or answer == nil then
                            return
                        end
                        local dir = directory(answer)
                        if not dir then
                            return
                        end
                        if not is_directory(dir) then
                            return notify(
                                'not a directory: ' .. dir,
                                vim.log.levels.WARN
                            )
                        end
                        create(agent, dir, mine)
                    end)
                )
            end)
        )
    end

    -- Selects what a create made when `focus_new` says so, then asks Rex for a
    -- snapshot. A failure on either step says why and refreshes too.
    ---@param mine integer
    ---@param err string|nil
    ---@param target rexai.Target|nil
    local function after_create(mine, err, target)
        if mine ~= adds then
            return
        end
        if err then
            notify(err, vim.log.levels.WARN)
            return refresh()
        end
        if not config.get().focus_new or not target then
            return refresh()
        end

        backend.focus(
            target,
            guard(function(focus_err)
                if mine ~= adds then
                    return
                end
                if focus_err then
                    notify(focus_err, vim.log.levels.WARN)
                end
                refresh()
            end)
        )
    end

    -- `n`: adds an Agent Window to the Session of the row under the cursor.
    -- The directory starts at the row's own. The header of the Home session is
    -- refused: a Window is added next to an Agent block, and it has none.
    function object.new_window(_)
        if disposed then
            return
        end
        local target = current_target()
        if not target then
            return notify('put the cursor on a Session or an Agent block')
        end
        if target.home then
            return notify(
                'the Home session has no Agent block to add a Window next '
                    .. 'to; use N'
            )
        end

        local prefill = vim.uv.cwd()
        if target.kind == 'row' then
            local ctx = data:context(target.block_id)
            if ctx and ctx.path then
                prefill = ctx.path
            end
        end

        local session_id = target.session_id
        ask('Window', prefill, function(agent, dir, mine)
            backend.create_window(
                {
                    session_id = session_id,
                    name = agent,
                    cwd = dir,
                    command = core_launch.command(
                        agent,
                        config.get().agents.launch
                    ),
                    keep_open = true,
                    focus = false,
                },
                guard(function(err, created)
                    after_create(mine, err, created)
                end)
            )
        end)
    end

    -- `N`: starts a Session with an Agent Window, or adds the Window to the
    -- Session that already has the label of the directory. The data object
    -- holds every Session Rex reported, so a Session with no Agent blocks is
    -- reused too instead of being started twice.
    function object.new_session(_)
        if disposed then
            return
        end

        ask('Session', vim.uv.cwd(), function(agent, dir, mine)
            local label = session_label(dir)
            local command =
                core_launch.command(agent, config.get().agents.launch)
            local existing = data:session_named(label)

            if existing then
                backend.create_window(
                    {
                        session_id = existing.id,
                        name = agent,
                        cwd = dir,
                        command = command,
                        keep_open = true,
                        focus = false,
                    },
                    guard(function(err, created)
                        after_create(mine, err, created)
                    end)
                )
                return
            end

            backend.create_session(
                {
                    name = label,
                    cwd = dir,
                    window = agent,
                    command = command,
                    keep_open = true,
                },
                guard(function(err, created)
                    after_create(mine, err, created)
                end)
            )
        end)
    end

    function object.dispose(_)
        disposed = true
        float.close()
    end

    return object
end

return M
