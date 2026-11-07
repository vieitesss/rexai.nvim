-- The Dashboard actions on the target under the cursor: `<CR>` goes to it, `d`
-- hands the row to the `review` hook and `K` peeks at its Block. The Backend
-- holds every `focus` and `peek` until the test answers it, and the effects of
-- the Dashboard (`refresh` and the target reader) are stubs, so the test sees
-- exactly what the actions ask for. The data object is the real one, fed with
-- an invented snapshot.

local actions = require('rexai.ui.actions')
local config = require('rexai.config')
local data_mod = require('rexai.ui.data')
local hooks_mod = require('rexai.hooks')
local snap = require('tests.snapshots')

-- What the Dashboard reader gives for the cursor: the header of the Session,
-- the row of a Block in a work tree, the row of a Block with no directory, or
-- nothing on a blank line.
local HEADER = { kind = 'session', session_id = 'session:s1' }
local ROW_IN_TREE = {
    kind = 'row',
    session_id = 'session:s1',
    window_id = 'window:w1',
    block_id = 'block:b1',
}
local ROW_BARE = {
    kind = 'row',
    session_id = 'session:s1',
    window_id = 'window:w1',
    block_id = 'block:b2',
}
-- The header of the Session that holds this Neovim.
local HOME_HEADER = {
    kind = 'session',
    session_id = 'session:home',
    home = true,
}

-- One Agent block in a work tree and one with no directory at all.
local SNAPSHOT = snap.snapshot({
    snap.session({
        id = 'session:s1',
        label = 'orbit',
        windows = {
            snap.window({
                id = 'window:w1',
                label = 'api',
                blocks = {
                    snap.block({
                        id = 'block:b1',
                        app = 'pi',
                        state = 'done',
                        title = 'the docs',
                        cwd = '/work/orbit',
                        updated_at = '2026-11-07T16:12:00Z',
                    }),
                    snap.block({
                        id = 'block:b2',
                        app = 'claude-code',
                        state = 'working',
                        title = 'the parser',
                        updated_at = '2026-11-07T16:10:00Z',
                    }),
                },
            }),
        },
    }),
})

-- The Row the model builds for `block:b1`.
local ROW = {
    session_id = 'session:s1',
    window_id = 'window:w1',
    block_id = 'block:b1',
    harness = 'pi',
    label = 'api pi',
    status = 'done',
    updated_at = '2026-11-07T16:12:00Z',
    title = 'the docs',
    cwd = '/work/orbit',
}

-- A Backend that holds every `focus` and every `peek` until the test answers
-- it, and answers every create at once with a target of its own.
---@return table
local function stub_backend()
    local object = {
        targets = {},
        pending = {},
        peeks = {},
        peek_pending = {},
        windows = {},
        sessions = {},
        created = 0,
    }

    function object.focus(target, callback)
        object.targets[#object.targets + 1] = target
        object.pending[#object.pending + 1] = callback
    end

    function object.snapshot(callback)
        callback(nil, SNAPSHOT)
    end

    -- A target for what a create made, so the actions have something to
    -- select. `window_error` and `session_error` make the next create fail.
    ---@param spec table
    ---@return rexai.Target
    local function made(spec)
        object.created = object.created + 1
        object.last_created = {
            session_id = spec.session_id or ('session:new-' .. object.created),
            window_id = 'window:new-' .. object.created,
            block_id = 'block:new-' .. object.created,
        }
        return object.last_created
    end

    function object.create_window(spec, callback)
        object.windows[#object.windows + 1] = spec
        if object.window_error then
            return callback(object.window_error)
        end
        callback(nil, made(spec))
    end

    function object.create_session(spec, callback)
        object.sessions[#object.sessions + 1] = spec
        if object.session_error then
            return callback(object.session_error)
        end
        callback(nil, made(spec))
    end

    function object.peek(target, callback)
        object.peeks[#object.peeks + 1] = target
        object.peek_pending[#object.peek_pending + 1] = callback
    end

    -- Answers the oldest focus call with `err`.
    ---@param err string|nil
    function object.answer(err)
        local callback = table.remove(object.pending, 1)
        assert.is_not_nil(callback, 'no focus call is waiting')
        callback(err)
    end

    -- Answers the oldest peek call with `err`.
    ---@param err string|nil
    function object.answer_peek(err)
        local callback = table.remove(object.peek_pending, 1)
        assert.is_not_nil(callback, 'no peek call is waiting')
        callback(err)
    end

    return object
end

-- A git cache that knows one directory.
---@param info table<string, rexai.GitInfo>
---@return table
local function stub_git(info)
    local object = {}

    function object.get(_, path)
        return info[path]
    end

    return object
end

-- The prompts `vim.ui` shows: every call is recorded and the test answers it
-- by hand, oldest open prompt first, so a prompt may stay open as long as the
-- test needs.
---@return table
local function stub_prompts()
    local p = { calls = {}, open = {} }

    ---@param entry table
    local function record(entry)
        p.calls[#p.calls + 1] = entry
        p.open[#p.open + 1] = entry
    end

    function p.select(items, opts, callback)
        record({
            kind = 'select',
            items = items,
            opts = opts,
            callback = callback,
        })
    end

    function p.input(opts, callback)
        record({
            kind = 'input',
            opts = opts,
            default = opts.default,
            callback = callback,
        })
    end

    ---@param choice string|nil
    function p.answer_select(choice)
        for index, entry in ipairs(p.open) do
            if entry.kind == 'select' then
                table.remove(p.open, index)
                return entry.callback(choice)
            end
        end
        error('no select is open')
    end

    ---@param text string|nil
    function p.answer_input(text)
        for index, entry in ipairs(p.open) do
            if entry.kind == 'input' then
                table.remove(p.open, index)
                return entry.callback(text)
            end
        end
        error('no input is open')
    end

    ---@return table|nil the newest input prompt
    function p.last_input()
        for index = #p.calls, 1, -1 do
            local entry = p.calls[index]
            if entry.kind == 'input' then
                return entry
            end
        end
    end

    return p
end

describe('ui.actions', function()
    local told, real_notify, backend, refreshed, target, object
    local prompts, real_select, real_input

    before_each(function()
        config.setup()
        told = { calls = {} }
        function told.notify(message, level)
            told.calls[#told.calls + 1] = {
                message = message,
                level = level,
            }
        end
        -- The actions report through `vim.notify`; the hooks object gets the
        -- same recorder as its test seam. One list, so the order the user sees
        -- the messages in is the order the test reads.
        real_notify = vim.notify
        vim.notify = told.notify
        prompts = stub_prompts()
        real_select = vim.ui.select
        vim.ui.select = prompts.select
        real_input = vim.ui.input
        vim.ui.input = prompts.input
        backend = stub_backend()
        refreshed = 0
        target = nil

        local hooks = hooks_mod.new({ notify = told.notify })
        local git = stub_git({
            ['/work/orbit'] = { root = '/work/orbit', branch = 'main' },
        })
        local data = data_mod.new({ hooks = hooks, git = git })
        data:accept(SNAPSHOT, nil)

        object = actions.new({
            backend = backend,
            data = data,
            hooks = hooks,
            refresh = function()
                refreshed = refreshed + 1
            end,
            current_target = function()
                return target
            end,
        })
    end)

    after_each(function()
        vim.notify = real_notify
        vim.ui.select = real_select
        vim.ui.input = real_input
        config.setup()
    end)

    describe('focus', function()
        it('asks Rex for the whole target of a row', function()
            target = ROW_IN_TREE

            object:focus()

            assert.are.same({
                {
                    session_id = 'session:s1',
                    window_id = 'window:w1',
                    block_id = 'block:b1',
                },
            }, backend.targets)
        end)

        it('asks Rex for the Session of a header with its id only', function()
            target = HEADER

            object:focus()

            assert.are.same({ { session_id = 'session:s1' } }, backend.targets)
        end)

        it('does nothing on a line with no target', function()
            object:focus()

            assert.are.same({}, backend.targets)
            assert.are.same({}, told.calls)
            assert.are.equal(0, refreshed)
        end)

        it('warns and refreshes once when Rex cannot focus', function()
            target = ROW_IN_TREE
            object:focus()

            backend.answer('target not found')

            assert.are.equal(1, #told.calls)
            assert.are.equal('rexai: target not found', told.calls[1].message)
            assert.are.equal(vim.log.levels.WARN, told.calls[1].level)
            assert.are.equal(1, refreshed)
        end)

        it('says nothing when the focus works', function()
            target = ROW_IN_TREE
            object:focus()

            backend.answer(nil)

            assert.are.same({}, told.calls)
            assert.are.equal(0, refreshed)
        end)

        it('drops a result that arrives after dispose', function()
            target = ROW_IN_TREE
            object:focus()
            object:dispose()

            backend.answer('target not found')

            assert.are.same({}, told.calls)
            assert.are.equal(0, refreshed)
        end)

        it('makes no call once disposed', function()
            target = ROW_IN_TREE
            object:dispose()

            object:focus()

            assert.are.same({}, backend.targets)
        end)
    end)

    describe('review', function()
        it('reports a line with no Agent block and calls nothing', function()
            config.setup({
                review = function()
                    error('review must not run')
                end,
            })

            object:review()

            assert.are.equal(1, #told.calls)
            assert.are.equal(
                'rexai: put the cursor on an Agent block',
                told.calls[1].message
            )
            assert.are.equal(vim.log.levels.INFO, told.calls[1].level)
        end)

        it('reports a row without a directory and calls nothing', function()
            config.setup({
                review = function()
                    error('review must not run')
                end,
            })
            target = ROW_BARE

            object:review()

            assert.are.equal(1, #told.calls)
            assert.are.equal(
                'rexai: this Block has no directory to review',
                told.calls[1].message
            )
            assert.are.equal(vim.log.levels.INFO, told.calls[1].level)
        end)

        it('reports a row whose review function is not set', function()
            target = ROW_IN_TREE

            object:review()

            assert.are.equal(1, #told.calls)
            assert.are.equal(
                'rexai: no review function is set; add review = '
                    .. 'function(ctx) ... end to setup()',
                told.calls[1].message
            )
            assert.are.equal(vim.log.levels.INFO, told.calls[1].level)
        end)

        it('gives review the row, the path and what git knows', function()
            local got = {}
            config.setup({
                review = function(ctx)
                    got[#got + 1] = ctx
                end,
            })
            target = ROW_IN_TREE

            object:review()

            assert.are.same({
                {
                    path = '/work/orbit',
                    repo_root = '/work/orbit',
                    branch = 'main',
                    session = { id = 'session:s1', label = 'orbit' },
                    window = { id = 'window:w1' },
                    block = ROW,
                },
            }, got)
            assert.are.same({}, told.calls)
        end)

        it('keeps working when the review function throws', function()
            local ran = 0
            config.setup({
                review = function()
                    ran = ran + 1
                    error('boom', 0)
                end,
            })
            target = ROW_IN_TREE

            object:review()
            object:review()

            assert.are.equal(2, ran)
            assert.are.equal(2, #told.calls)
            assert.are.equal(
                'rexai: review failed: boom',
                told.calls[1].message
            )
            assert.are.equal(vim.log.levels.WARN, told.calls[1].level)
        end)

        it('does nothing once disposed', function()
            local ran = 0
            config.setup({
                review = function()
                    ran = ran + 1
                end,
            })
            target = ROW_IN_TREE
            object:dispose()

            object:review()

            assert.are.equal(0, ran)
            assert.are.same({}, told.calls)
        end)
    end)

    describe('peek', function()
        it('reports a line with no Agent block and asks nothing', function()
            object:peek()

            assert.are.same({}, backend.peeks)
            assert.are.equal(1, #told.calls)
            assert.are.equal(
                'rexai: put the cursor on an Agent block',
                told.calls[1].message
            )
            assert.are.equal(vim.log.levels.INFO, told.calls[1].level)
        end)

        it('reports a Session header too', function()
            target = HEADER

            object:peek()

            assert.are.same({}, backend.peeks)
            assert.are.equal(
                'rexai: put the cursor on an Agent block',
                told.calls[1].message
            )
            assert.are.equal(vim.log.levels.INFO, told.calls[1].level)
        end)

        it('asks Rex for the whole target of the row', function()
            target = ROW_IN_TREE

            object:peek()

            assert.are.same({
                {
                    session_id = 'session:s1',
                    window_id = 'window:w1',
                    block_id = 'block:b1',
                },
            }, backend.peeks)
            assert.are.same({}, told.calls)
        end)

        it('warns and refreshes once when Rex cannot peek', function()
            target = ROW_IN_TREE
            object:peek()

            backend.answer_peek('cannot read the Block')

            assert.are.equal(1, #told.calls)
            assert.are.equal(
                'rexai: cannot read the Block',
                told.calls[1].message
            )
            assert.are.equal(vim.log.levels.WARN, told.calls[1].level)
            assert.are.equal(1, refreshed)
        end)

        it('makes no call once disposed', function()
            target = ROW_IN_TREE
            object:dispose()

            object:peek()

            assert.are.same({}, backend.peeks)
            assert.are.same({}, told.calls)
        end)
    end)

    -- The `n` and `N` keys start a new Agent block: the agent comes from a
    -- select, the directory from an input, and the create from the Backend.
    -- Every directory is a temporary one this spec makes and removes.
    describe('a new Agent block', function()
        local base, dir
        -- A directory whose two last components name a Session.
        local LABEL = 'orbit_api'

        before_each(function()
            base = vim.fn.tempname()
            dir = base .. '/orbit/api'
            vim.fn.mkdir(dir, 'p')
        end)

        after_each(function()
            vim.fn.delete(base, 'rf')
        end)

        -- Presses the key that asks for `what`, then answers both prompts.
        ---@param what string 'Window' or 'Session'
        ---@param choice string|nil
        ---@param text string|nil
        local function answer(what, choice, text)
            if what == 'Window' then
                object:new_window()
            else
                object:new_session()
            end
            assert.are.equal(
                what,
                prompts.calls[1].opts.prompt:match('new (%a+)$')
            )
            prompts.answer_select(choice)
            if choice == nil then
                return
            end
            prompts.answer_input(text)
        end

        describe('new_window', function()
            it('asks for an agent and a directory', function()
                target = ROW_IN_TREE

                object:new_window()

                assert.are.same(
                    config.get().agents.commands,
                    prompts.calls[1].items
                )
                assert.are.equal(
                    'Agent for the new Window',
                    prompts.calls[1].opts.prompt
                )
                prompts.answer_select('pi')
                assert.are.equal(
                    'Directory of the new Window',
                    prompts.calls[2].opts.prompt
                )
                -- The row stands for a directory, so it is the prefill.
                assert.are.equal('/work/orbit', prompts.calls[2].default)
            end)

            it('adds the Window to the Session of the row', function()
                target = ROW_IN_TREE

                answer('Window', 'pi', dir)

                assert.are.same({
                    {
                        session_id = 'session:s1',
                        name = 'pi',
                        cwd = dir,
                        command = { 'pi' },
                        keep_open = true,
                        focus = false,
                    },
                }, backend.windows)
            end)

            it('selects the new Window and refreshes once', function()
                target = ROW_IN_TREE

                answer('Window', 'pi', dir)
                -- The focus waits for its answer.
                assert.are.equal(0, refreshed)
                backend.answer(nil)

                assert.are.same({ backend.last_created }, backend.targets)
                assert.are.equal(1, refreshed)
                assert.are.same({}, told.calls)
            end)

            it('leaves the view alone with focus_new off', function()
                config.setup({ focus_new = false })
                target = ROW_IN_TREE

                answer('Window', 'pi', dir)

                assert.are.equal(1, #backend.windows)
                assert.are.same({}, backend.targets)
                assert.are.equal(1, refreshed)
            end)

            it('adds the Window to the Session of a header', function()
                target = HEADER

                answer('Window', 'claude', dir)

                assert.are.equal('session:s1', backend.windows[1].session_id)
                assert.are.equal('claude', backend.windows[1].name)
                assert.are.same({ 'claude' }, backend.windows[1].command)
            end)

            it('prefills the directory of Neovim without a row path', function()
                target = ROW_BARE

                object:new_window()
                prompts.answer_select('pi')

                assert.are.equal(vim.uv.cwd(), prompts.last_input().default)
            end)

            it('prefills the directory of Neovim for a header', function()
                target = HEADER

                object:new_window()
                prompts.answer_select('pi')

                assert.are.equal(vim.uv.cwd(), prompts.last_input().default)
            end)

            it('refuses the header of the Home session', function()
                target = HOME_HEADER

                object:new_window()

                assert.are.same({}, prompts.calls)
                assert.are.same({}, backend.windows)
                assert.are.equal(1, #told.calls)
                assert.are.equal(
                    'rexai: the Home session has no Agent block to add a '
                        .. 'Window next to; use N',
                    told.calls[1].message
                )
                assert.are.equal(vim.log.levels.INFO, told.calls[1].level)
            end)

            it('refuses a blank line', function()
                object:new_window()

                assert.are.same({}, prompts.calls)
                assert.are.same({}, backend.windows)
                assert.are.equal(1, #told.calls)
                assert.are.equal(
                    'rexai: put the cursor on a Session or an Agent block',
                    told.calls[1].message
                )
                assert.are.equal(vim.log.levels.INFO, told.calls[1].level)
            end)

            it('refuses a path that is not a directory', function()
                target = ROW_IN_TREE
                local missing = dir .. '/missing'

                answer('Window', 'pi', missing)

                assert.are.same({}, backend.windows)
                assert.are.equal(1, #told.calls)
                assert.are.equal(
                    'rexai: not a directory: ' .. missing,
                    told.calls[1].message
                )
                assert.are.equal(vim.log.levels.WARN, told.calls[1].level)
                assert.are.equal(0, refreshed)
            end)

            it('expands and cleans the directory it was given', function()
                target = ROW_IN_TREE

                answer('Window', 'pi', dir .. '/')

                assert.are.equal(dir, backend.windows[1].cwd)

                answer('Window', 'pi', '~')

                assert.are.equal(
                    vim.fs.normalize(vim.uv.os_homedir()),
                    backend.windows[2].cwd
                )
            end)

            it('ends in silence when the user answers nothing', function()
                target = ROW_IN_TREE

                answer('Window', 'pi', '')

                assert.are.same({}, backend.windows)
                assert.are.same({}, told.calls)
                assert.are.equal(0, refreshed)
            end)

            it('ends in silence when the agent prompt is cancelled', function()
                target = ROW_IN_TREE

                answer('Window', nil)

                assert.are.equal(1, #prompts.calls)
                assert.are.same({}, backend.windows)
                assert.are.same({}, told.calls)
            end)

            it(
                'ends in silence when the directory prompt is cancelled',
                function()
                    target = ROW_IN_TREE

                    object:new_window()
                    prompts.answer_select('pi')
                    prompts.answer_input(nil)

                    assert.are.same({}, backend.windows)
                    assert.are.same({}, told.calls)
                end
            )

            it('replaces the command with the launch argv', function()
                config.setup({
                    agents = { launch = { pi = { 'pi', '--continue' } } },
                })
                target = ROW_IN_TREE

                answer('Window', 'pi', dir)

                assert.are.same(
                    { 'pi', '--continue' },
                    backend.windows[1].command
                )
            end)

            it(
                'warns and refreshes when Rex cannot create the Window',
                function()
                    backend.window_error = 'rex is down'
                    target = ROW_IN_TREE

                    answer('Window', 'pi', dir)

                    assert.are.same({}, backend.targets)
                    assert.are.equal(1, #told.calls)
                    assert.are.equal(
                        'rexai: rex is down',
                        told.calls[1].message
                    )
                    assert.are.equal(vim.log.levels.WARN, told.calls[1].level)
                    assert.are.equal(1, refreshed)
                end
            )

            it('warns and refreshes when Rex cannot select it', function()
                target = ROW_IN_TREE

                answer('Window', 'pi', dir)
                backend.answer('cannot select the Window')

                assert.are.equal(1, #told.calls)
                assert.are.equal(
                    'rexai: cannot select the Window',
                    told.calls[1].message
                )
                assert.are.equal(vim.log.levels.WARN, told.calls[1].level)
                assert.are.equal(1, refreshed)
            end)

            it('keeps only the newest of two presses', function()
                target = ROW_IN_TREE

                object:new_window()
                object:new_window()
                -- The older prompt is answered first, and drops its request.
                prompts.answer_select('pi')
                assert.are.equal(0, #backend.windows)
                prompts.answer_select('claude')
                prompts.answer_input(dir)

                assert.are.equal(1, #backend.windows)
                assert.are.equal('claude', backend.windows[1].name)
            end)
        end)

        describe('new_session', function()
            it('starts a Session named after the directory', function()
                answer('Session', 'claude', dir)

                assert.are.same({
                    {
                        name = LABEL,
                        cwd = dir,
                        window = 'claude',
                        command = { 'claude' },
                        keep_open = true,
                    },
                }, backend.sessions)
                assert.are.same({}, backend.windows)
            end)

            it('prefills the directory of Neovim', function()
                object:new_session()
                prompts.answer_select('pi')

                assert.are.equal(vim.uv.cwd(), prompts.last_input().default)
            end)

            it('selects the new Session and refreshes once', function()
                answer('Session', 'pi', dir)
                backend.answer(nil)

                assert.are.same({ backend.last_created }, backend.targets)
                assert.are.equal(1, refreshed)
                assert.are.same({}, told.calls)
            end)

            it('leaves the view alone with focus_new off', function()
                config.setup({ focus_new = false })

                answer('Session', 'pi', dir)

                assert.are.same({}, backend.targets)
                assert.are.equal(1, refreshed)
            end)

            it('adds a Window to a Session that has the label', function()
                config.setup({
                    session_name = function()
                        return 'orbit'
                    end,
                })

                answer('Session', 'pi', dir)

                assert.are.same({}, backend.sessions)
                assert.are.same({
                    {
                        session_id = 'session:s1',
                        name = 'pi',
                        cwd = dir,
                        command = { 'pi' },
                        keep_open = true,
                        focus = false,
                    },
                }, backend.windows)
            end)

            it('uses the label the session_name hook gave', function()
                config.setup({
                    session_name = function(path)
                        assert.are.equal(dir, path)
                        return 'feature-42'
                    end,
                })

                answer('Session', 'pi', dir)

                assert.are.equal('feature-42', backend.sessions[1].name)
            end)

            it('falls back when the session_name hook gives nothing', function()
                config.setup({
                    session_name = function()
                        return nil
                    end,
                })

                answer('Session', 'pi', dir)
                answer('Session', 'pi', dir)

                assert.are.equal(LABEL, backend.sessions[1].name)
                assert.are.same({}, told.calls)

                config.setup({
                    session_name = function()
                        return ''
                    end,
                })
                answer('Session', 'pi', dir)

                assert.are.equal(LABEL, backend.sessions[3].name)
                assert.are.same({}, told.calls)
            end)

            it('warns once when the session_name hook throws', function()
                config.setup({
                    session_name = function()
                        error('boom', 0)
                    end,
                })

                answer('Session', 'pi', dir)
                answer('Session', 'pi', dir)

                assert.are.equal(LABEL, backend.sessions[1].name)
                assert.are.equal(LABEL, backend.sessions[2].name)
                assert.are.equal(1, #told.calls)
                assert.are.equal(
                    'rexai: session_name failed: boom',
                    told.calls[1].message
                )
                assert.are.equal(vim.log.levels.WARN, told.calls[1].level)
            end)

            it('works on a blank line and on the Home header', function()
                answer('Session', 'pi', dir)
                target = HOME_HEADER
                answer('Session', 'claude', dir)

                assert.are.equal(2, #backend.sessions)
                assert.are.same({}, told.calls)
            end)

            it('refuses a path that is not a directory', function()
                local missing = dir .. '/missing'

                answer('Session', 'pi', missing)

                assert.are.same({}, backend.sessions)
                assert.are.equal(
                    'rexai: not a directory: ' .. missing,
                    told.calls[1].message
                )
                assert.are.equal(vim.log.levels.WARN, told.calls[1].level)
            end)

            it('ends in silence when the user cancels', function()
                answer('Session', nil)

                assert.are.same({}, backend.sessions)
                assert.are.same({}, told.calls)
            end)

            it('replaces the command with the launch argv', function()
                config.setup({
                    agents = { launch = { claude = { 'claude', '-c' } } },
                })

                answer('Session', 'claude', dir)

                assert.are.same({ 'claude', '-c' }, backend.sessions[1].command)
            end)

            it(
                'warns and refreshes when Rex cannot start the Session',
                function()
                    backend.session_error = 'no Rex server'

                    answer('Session', 'pi', dir)

                    assert.are.same({}, backend.targets)
                    assert.are.equal(
                        'rexai: no Rex server',
                        told.calls[1].message
                    )
                    assert.are.equal(vim.log.levels.WARN, told.calls[1].level)
                    assert.are.equal(1, refreshed)
                end
            )
        end)
    end)
end)
