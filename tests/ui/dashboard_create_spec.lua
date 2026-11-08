-- The `n` and `N` keys: they ask for an agent and a directory with `vim.ui`
-- and start a new Agent block through the Backend. The prompts come from the
-- harness, which waits for the test to answer them, and the Backend holds
-- every create, so the test decides when a result arrives.

local config = require('rexai.config')
local dashboard = require('rexai.ui.dashboard')
local model = require('rexai.core.model')
local render = require('rexai.ui.render')
local snap = require('tests.snapshots')
local support = require('tests.ui_support')

-- Not the Session this Neovim runs in, so no Home header shows up by itself.
local HOME = 'session:home'

-- One Session with a Block in a work tree and a Block with no directory.
local ONE = snap.snapshot({
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

-- Two Sessions, so a blank line sits between their rows.
local TWO = snap.snapshot({
    snap.session({
        id = 'session:alpha',
        label = 'alpha',
        windows = {
            snap.window({
                id = 'window:w1',
                label = 'api',
                blocks = {
                    snap.block({ id = 'block:k1', app = 'pi', state = 'idle' }),
                },
            }),
        },
    }),
    snap.session({
        id = 'session:beta',
        label = 'beta',
        windows = {
            snap.window({
                id = 'window:w2',
                label = 'web',
                blocks = {
                    snap.block({
                        id = 'block:k2',
                        app = 'claude-code',
                        state = 'idle',
                    }),
                },
            }),
        },
    }),
})

-- The Home session alone: one header with no Agent block.
local HOME_ONLY = snap.snapshot({
    snap.session({ id = 'session:home', label = 'landing', windows = {} }),
})

-- A Backend that answers `snapshot` at once and holds every create and every
-- focus until the test answers it.
---@param snapshot table
---@return table
local function holding_backend(snapshot)
    local object = {
        snapshots = 0,
        creates = {},
        pending = {},
        focused = {},
        focus_pending = {},
    }

    function object.snapshot(callback)
        object.snapshots = object.snapshots + 1
        callback(nil, snapshot)
    end

    function object.focus(target, callback)
        object.focused[#object.focused + 1] = target
        object.focus_pending[#object.focus_pending + 1] = callback
    end

    -- Answers the oldest focus with `err`.
    ---@param err string|nil
    function object.answer_focus(err)
        local callback = table.remove(object.focus_pending, 1)
        assert.is_not_nil(callback, 'no focus is waiting')
        callback(err)
    end

    ---@param method string
    ---@return fun(spec: table, callback: fun(err: string|nil, target: table|nil))
    local function create(method)
        return function(spec, callback)
            object.creates[#object.creates + 1] = {
                method = method,
                spec = spec,
            }
            object.pending[#object.pending + 1] = callback
        end
    end
    object.create_window = create('create_window')
    object.create_session = create('create_session')

    function object.peek(_, callback)
        callback(nil, '')
    end

    -- Answers the oldest create with `err`.
    ---@param err string|nil
    function object.answer(err)
        local callback = table.remove(object.pending, 1)
        assert.is_not_nil(callback, 'no create is waiting')
        callback(err, not err and {
            session_id = 'session:s1',
            window_id = 'window:made',
            block_id = 'block:made',
        } or nil)
    end

    return object
end

---@param snapshot table
---@return table<integer, rexai.RenderTarget>
local function targets_of(snapshot)
    return render.build(model.build(snapshot, config.get().agents), {
        now = support.NOW,
        home_session_id = HOME,
    }).targets
end

describe('ui.dashboard create', function()
    local h, base, dir

    before_each(function()
        h = support.new()
        base = vim.fn.tempname()
        dir = base .. '/orbit/api'
        vim.fn.mkdir(dir, 'p')
    end)

    after_each(function()
        vim.fn.delete(base, 'rf')
        h:close()
    end)

    ---@param line integer
    local function put_cursor_on(line)
        vim.api.nvim_win_set_cursor(vim.api.nvim_get_current_win(), { line, 0 })
    end

    ---@param block_id string
    local function put_cursor_on_block(block_id)
        put_cursor_on(support.line_of(targets_of(ONE), block_id))
        assert.are.equal(block_id, dashboard.current_target().block_id)
    end

    -- Wipes the Dashboard buffer, as `:bwipeout` would: the buffer leaves the
    -- window and every autocmd of the Dashboard fires.
    local function wipe()
        local buf = assert(h:buf())
        for _, win in ipairs(vim.fn.win_findbuf(buf)) do
            if vim.api.nvim_win_is_valid(win) then
                vim.api.nvim_win_set_buf(win, h.scratch)
            end
        end
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
        assert.is_nil(h:buf())
    end

    -- Answers the agent select and the directory input of the newest press.
    ---@param choice string
    ---@param text string
    local function answer_prompts(choice, text)
        h.prompt.answer_select(choice)
        h.prompt.answer_input(text)
    end

    describe('n', function()
        it('asks for an agent and the directory of the row', function()
            local object = holding_backend(ONE)
            h:open({ backend = object, home_session_id = HOME })
            put_cursor_on_block('block:b1')

            h:press('n')

            assert.are.same(
                config.get().agents.commands,
                h.prompt.calls[1].items
            )
            assert.are.equal(
                'Agent for the new Window',
                h.prompt.calls[1].opts.prompt
            )
            h.prompt.answer_select('pi')
            assert.are.equal('/work/orbit', h.prompt.calls[2].default)
            h.prompt.answer_input(dir)

            assert.are.same({
                {
                    session_id = 'session:s1',
                    name = 'pi',
                    cwd = dir,
                    command = { 'pi' },
                    keep_open = true,
                    focus = false,
                },
            }, { object.creates[1].spec })
        end)

        it('selects the new Window and draws it', function()
            local object = holding_backend(ONE)
            h:open({ backend = object, home_session_id = HOME })
            put_cursor_on_block('block:b1')
            h:press('n')
            answer_prompts('pi', dir)
            assert.are.equal(1, object.snapshots)

            object.answer(nil)
            assert.are.equal(1, object.snapshots)

            object.answer_focus(nil)

            assert.are.same({
                {
                    session_id = 'session:s1',
                    window_id = 'window:made',
                    block_id = 'block:made',
                },
            }, object.focused)
            assert.are.equal(2, object.snapshots)
            assert.are.same({}, h.notify.calls)
        end)

        it('starts at the cwd without a row directory', function()
            local object = holding_backend(ONE)
            h:open({ backend = object, home_session_id = HOME })
            put_cursor_on_block('block:b2')

            h:press('n')
            h.prompt.answer_select('pi')

            assert.are.equal(vim.uv.cwd(), h.prompt.calls[2].default)
        end)

        it('starts at the cwd on a Session header', function()
            local object = holding_backend(ONE)
            h:open({ backend = object, home_session_id = HOME })
            put_cursor_on(1)

            h:press('n')
            h.prompt.answer_select('pi')

            assert.are.equal(vim.uv.cwd(), h.prompt.calls[2].default)
        end)

        it('is disabled on the Home session header', function()
            local object = holding_backend(HOME_ONLY)
            h:open({ backend = object, home_session_id = HOME })
            put_cursor_on(1)

            h:press('n')

            assert.are.same({}, h.prompt.calls)
            assert.are.same({}, object.creates)
            assert.are.equal(1, #h.notify.calls)
            assert.are.equal(
                'rexai: the Home session has no Agent block to add a '
                    .. 'Window next to; use N',
                h.notify.calls[1].message
            )
            assert.are.equal(vim.log.levels.INFO, h.notify.calls[1].level)
        end)

        it(
            'says to pick a Session or an Agent block on a blank line',
            function()
                local object = holding_backend(TWO)
                h:open({ backend = object, home_session_id = HOME })
                put_cursor_on(3)
                assert.are.equal('', h:lines()[3])

                h:press('n')

                assert.are.same({}, h.prompt.calls)
                assert.are.same({}, object.creates)
                assert.are.equal(
                    'rexai: put the cursor on a Session or an Agent block',
                    h.notify.calls[1].message
                )
                assert.are.equal(vim.log.levels.INFO, h.notify.calls[1].level)
            end
        )

        it('refuses a directory that does not exist', function()
            local object = holding_backend(ONE)
            h:open({ backend = object, home_session_id = HOME })
            put_cursor_on_block('block:b1')

            h:press('n')
            answer_prompts('pi', dir .. '/missing')

            assert.are.same({}, object.creates)
            assert.are.equal(
                'rexai: not a directory: ' .. dir .. '/missing',
                h.notify.calls[1].message
            )
            assert.are.equal(vim.log.levels.WARN, h.notify.calls[1].level)
        end)

        it('holds only the newest of two presses', function()
            local object = holding_backend(ONE)
            h:open({ backend = object, home_session_id = HOME })
            put_cursor_on_block('block:b1')

            h:press('n')
            h:press('n')
            -- The older prompt answers first and drops its request.
            h.prompt.answer_select('pi')
            assert.are.equal(0, #object.creates)
            h.prompt.answer_select('claude')
            h.prompt.answer_input(dir)

            assert.are.equal(1, #object.creates)
            assert.are.equal('claude', object.creates[1].spec.name)
        end)

        it('drops a directory answered after a newer press', function()
            local object = holding_backend(ONE)
            h:open({ backend = object, home_session_id = HOME })
            put_cursor_on_block('block:b1')

            h:press('n')
            h.prompt.answer_select('pi')
            h:press('n')
            h.prompt.answer_input(dir)

            assert.are.same({}, object.creates)

            h.prompt.answer_select('claude')
            h.prompt.answer_input(dir)

            assert.are.equal(1, #object.creates)
            assert.are.equal('claude', object.creates[1].spec.name)
        end)

        it('drops a create that a newer press replaced', function()
            local object = holding_backend(ONE)
            h:open({ backend = object, home_session_id = HOME })
            put_cursor_on_block('block:b1')
            h:press('n')
            answer_prompts('pi', dir)
            -- The create of the first press is still waiting when the second
            -- press starts.
            h:press('n')

            object.answer(nil)

            assert.are.same({}, object.focused)
            assert.are.equal(1, object.snapshots)
            assert.are.same({}, h.notify.calls)
        end)

        it('drops a focus that a newer press replaced', function()
            local object = holding_backend(ONE)
            h:open({ backend = object, home_session_id = HOME })
            put_cursor_on_block('block:b1')
            h:press('n')
            answer_prompts('pi', dir)
            object.answer(nil)
            -- The focus of the first press is still waiting when the second
            -- press starts.
            h:press('n')

            object.answer_focus('cannot select the Window')

            assert.are.equal(1, #object.focused)
            assert.are.equal(1, object.snapshots)
            assert.are.same({}, h.notify.calls)
        end)
    end)

    describe('N', function()
        it('starts a Session named after the directory', function()
            local object = holding_backend(TWO)
            h:open({ backend = object, home_session_id = HOME })
            put_cursor_on(3)
            assert.is_nil(dashboard.current_target())

            h:press('N')
            h.prompt.answer_select('pi')
            assert.are.equal(vim.uv.cwd(), h.prompt.calls[2].default)
            h.prompt.answer_input(dir)

            assert.are.same({
                {
                    name = 'orbit_api',
                    cwd = dir,
                    window = 'pi',
                    command = { 'pi' },
                    keep_open = true,
                },
            }, { object.creates[1].spec })
            assert.are.equal('create_session', object.creates[1].method)
        end)

        it('selects the new Session and draws it', function()
            local object = holding_backend(ONE)
            h:open({ backend = object, home_session_id = HOME })
            h:press('N')
            answer_prompts('pi', dir)

            object.answer(nil)
            object.answer_focus(nil)

            assert.are.equal(1, #object.focused)
            assert.are.equal(2, object.snapshots)
            assert.are.same({}, h.notify.calls)
        end)

        it('works on the Home session header', function()
            local object = holding_backend(HOME_ONLY)
            h:open({ backend = object, home_session_id = HOME })
            put_cursor_on(1)

            h:press('N')
            answer_prompts('pi', dir)

            assert.are.equal(1, #object.creates)
        end)

        it('adds a Window to a Session with no Agent blocks', function()
            config.setup({
                session_name = function()
                    return 'landing'
                end,
            })
            local object = holding_backend(HOME_ONLY)
            h:open({ backend = object, home_session_id = HOME })
            put_cursor_on(1)

            h:press('N')
            answer_prompts('pi', dir)

            assert.are.equal(1, #object.creates)
            assert.are.equal('create_window', object.creates[1].method)
            assert.are.equal('session:home', object.creates[1].spec.session_id)
        end)

        it('leaves the view alone with focus_new off', function()
            config.setup({ focus_new = false })
            local object = holding_backend(ONE)
            h:open({ backend = object, home_session_id = HOME })
            h:press('N')
            answer_prompts('pi', dir)

            object.answer(nil)

            assert.are.same({}, object.focused)
            assert.are.equal(2, object.snapshots)
        end)
    end)

    -- With no agent configured there is nothing to pick, so the key says so
    -- and opens no prompt.
    describe('with no configured agent', function()
        it('warns and prompts for nothing', function()
            config.setup({ agents = { commands = {} } })
            local object = holding_backend(ONE)
            h:open({ backend = object, home_session_id = HOME })
            put_cursor_on_block('block:b1')

            h:press('n')
            h:press('N')

            assert.are.same({}, h.prompt.calls)
            assert.are.same({}, object.creates)
            assert.are.equal(2, #h.notify.calls)
            for _, call in ipairs(h.notify.calls) do
                assert.are.equal(
                    'rexai: no agent is configured; set agents.commands '
                        .. 'in setup()',
                    call.message
                )
                assert.are.equal(vim.log.levels.WARN, call.level)
            end
        end)
    end)

    describe('a result that arrives too late', function()
        it(
            'creates nothing when the select is still open at the wipe',
            function()
                local object = holding_backend(ONE)
                h:open({ backend = object, home_session_id = HOME })
                put_cursor_on_block('block:b1')
                h:press('n')

                wipe()
                h.prompt.answer_select('pi')

                assert.are.same({}, object.creates)
                -- No input opens either.
                assert.are.equal(1, #h.prompt.calls)
                assert.are.same({}, h.notify.calls)
            end
        )

        it(
            'creates nothing when the input is still open at the wipe',
            function()
                local object = holding_backend(ONE)
                h:open({ backend = object, home_session_id = HOME })
                put_cursor_on_block('block:b1')
                h:press('n')
                h.prompt.answer_select('pi')

                wipe()
                h.prompt.answer_input(dir)

                assert.are.same({}, object.creates)
                assert.are.same({}, h.notify.calls)
            end
        )

        it('does nothing when the create arrives after the wipe', function()
            local object = holding_backend(ONE)
            h:open({ backend = object, home_session_id = HOME })
            put_cursor_on_block('block:b1')
            h:press('n')
            answer_prompts('pi', dir)
            assert.are.equal(1, #object.creates)

            wipe()
            object.answer(nil)

            assert.are.same({}, object.focused)
            assert.are.same({}, h.notify.calls)
        end)

        it('does nothing when another Backend replaced it', function()
            local object = holding_backend(ONE)
            h:open({ backend = object, home_session_id = HOME })
            put_cursor_on_block('block:b1')
            h:press('n')
            answer_prompts('pi', dir)

            local replacement = holding_backend(ONE)
            h:open({ backend = replacement, home_session_id = HOME })
            object.answer(nil)

            assert.are.same({}, object.focused)
            assert.are.same({}, replacement.focused)
            assert.are.equal(1, replacement.snapshots)
            assert.are.same({}, h.notify.calls)
        end)
    end)
end)
