-- The Dashboard keys: `<CR>` takes the user to the Agent block or Session
-- under the cursor, `r` asks Rex at once and `e` shows or hides the Exited
-- rows. The fake Backend serves invented snapshots and the tests fire the
-- poller's timer by hand.

local config = require('rexai.config')
local dashboard = require('rexai.ui.dashboard')
local fake = require('rexai.backend.fake')
local model = require('rexai.core.model')
local render = require('rexai.ui.render')
local snap = require('tests.snapshots')

local AGENTS = config.defaults.agents
local NAME = 'rexai://dashboard'
-- 2026-11-07T16:15:00Z, so the ages never move.
local NOW = 1794068100

-- A timer that records what the poller schedules, so a test fires it.
local function fake_timer()
    local timer = { pending = {} }

    function timer.after(ms, callback)
        local entry = { ms = ms, callback = callback }
        table.insert(timer.pending, entry)
        return function()
            for index, pending in ipairs(timer.pending) do
                if pending == entry then
                    table.remove(timer.pending, index)
                    return
                end
            end
        end
    end

    function timer.fire()
        local entry = table.remove(timer.pending, 1)
        assert.is_not_nil(entry, 'nothing is scheduled')
        entry.callback()
    end

    function timer.count()
        return #timer.pending
    end

    return timer
end

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
                    snap.block({
                        id = 'block:k1',
                        app = 'claude-code',
                        state = 'working',
                    }),
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
                        app = 'pi',
                        state = 'idle',
                    }),
                },
            }),
        },
    }),
})

-- No Agent block at all: one line with no target.
local EMPTY = snap.snapshot({
    snap.session({ id = 'session:solo', label = 'solo', windows = {} }),
})

-- One Session with the Block that comes first and a Block that stays live.
---@param first table the first Block of the Window
---@param second_id string
---@return table
local function with_first(first, second_id)
    return snap.snapshot({
        snap.session({
            id = 'session:orbit',
            label = 'orbit',
            windows = {
                snap.window({
                    id = 'window:w7',
                    label = 'api',
                    blocks = {
                        first,
                        snap.block({
                            id = second_id,
                            app = 'pi',
                            state = 'idle',
                            title = 'the docs',
                        }),
                    },
                }),
            },
        }),
    })
end

---@param calls table[]
---@param method string
---@return integer
local function count(calls, method)
    local total = 0
    for _, call in ipairs(calls) do
        if call.method == method then
            total = total + 1
        end
    end
    return total
end

---@param calls table[]
---@return table|nil the last `focus` argument
local function last_focus(calls)
    for index = #calls, 1, -1 do
        if calls[index].method == 'focus' then
            return calls[index].arg
        end
    end
end

---@param snapshot table
---@return table<integer, rexai.RenderTarget>
local function targets_of(snapshot)
    return render.build(model.build(snapshot, AGENTS), { now = NOW }).targets
end

---@param targets table<integer, rexai.RenderTarget>
---@param block_id string
---@return integer
local function line_of(targets, block_id)
    for line, target in pairs(targets) do
        if target.block_id == block_id then
            return line
        end
    end
    error('no line for ' .. block_id)
end

---@return integer|nil
local function dashboard_buf()
    local buf = vim.fn.bufnr(NAME)
    if buf == -1 then
        return nil
    end
    return buf
end

-- Types `keys` in normal mode and waits for the Dashboard to handle them.
---@param keys string
local function press(keys)
    vim.api.nvim_feedkeys(vim.keycode(keys), 'x', false)
end

---@return string[]
local function dashboard_lines()
    return vim.api.nvim_buf_get_lines(dashboard_buf(), 0, -1, false)
end

describe('ui.dashboard keys', function()
    local timer
    local scratch

    before_each(function()
        scratch = vim.api.nvim_create_buf(true, false)
        timer = fake_timer()
        vim.env.REX_SESSION = nil
        config.setup()
    end)

    after_each(function()
        local buf = dashboard_buf()
        if buf then
            local replacement = scratch
            if not vim.api.nvim_buf_is_valid(replacement) then
                replacement = vim.api.nvim_create_buf(true, false)
                scratch = replacement
            end
            for _, win in ipairs(vim.fn.win_findbuf(buf)) do
                if vim.api.nvim_win_is_valid(win) then
                    vim.api.nvim_win_set_buf(win, replacement)
                end
            end
            pcall(vim.api.nvim_buf_delete, buf, { force = true })
        end
        if vim.api.nvim_buf_is_valid(scratch) then
            vim.api.nvim_buf_delete(scratch, { force = true })
        end
        config.setup()
    end)

    ---@param backend rexai.Backend
    local function open(backend)
        vim.api.nvim_win_set_buf(0, scratch)
        dashboard.open({
            backend = backend,
            after = timer.after,
            now = function()
                return NOW
            end,
        })
    end

    describe('<CR>', function()
        it('focuses the Agent block under the cursor', function()
            local backend, calls = fake.new({ snapshots = { TWO } })
            open(backend)
            local win = vim.api.nvim_get_current_win()
            vim.api.nvim_win_set_cursor(win, {
                line_of(targets_of(TWO), 'block:k1'),
                0,
            })

            press('<CR>')

            assert.are.same({
                session_id = 'session:alpha',
                window_id = 'window:w1',
                block_id = 'block:k1',
            }, last_focus(calls))
        end)

        it('focuses the Session of a header with its id only', function()
            local backend, calls = fake.new({ snapshots = { TWO } })
            open(backend)
            vim.api.nvim_win_set_cursor(vim.api.nvim_get_current_win(), {
                1,
                0,
            })

            press('<CR>')

            assert.are.same({ session_id = 'session:alpha' }, last_focus(calls))
        end)

        it('does nothing on a line with no target', function()
            local backend, calls = fake.new({ snapshots = { TWO, EMPTY } })
            open(backend)
            local win = vim.api.nvim_get_current_win()
            -- Line 3 is the blank line between the two Sessions.
            vim.api.nvim_win_set_cursor(win, { 3, 0 })
            assert.are.equal('', dashboard_lines()[3])

            press('<CR>')

            assert.is_nil(last_focus(calls))
            assert.are.equal(0, count(calls, 'focus'))
        end)

        it('warns once and refreshes when Rex cannot focus', function()
            local backend, calls = fake.new({ snapshots = { TWO } })
            backend.fail_next('focus', 'target not found')
            open(backend)
            vim.api.nvim_win_set_cursor(vim.api.nvim_get_current_win(), {
                line_of(targets_of(TWO), 'block:k1'),
                0,
            })
            local notified = {}
            local notify = vim.notify
            vim.notify = function(message, level)
                notified[#notified + 1] = { message = message, level = level }
            end

            local ok, err = pcall(function()
                press('<CR>')

                assert.are.equal(1, #notified)
                assert.are.equal('rexai: target not found', notified[1].message)
                assert.are.equal(vim.log.levels.WARN, notified[1].level)
                -- The target has probably vanished, so the Dashboard asks
                -- Rex again at once.
                assert.are.equal(2, count(calls, 'snapshot'))
            end)
            vim.notify = notify
            assert(ok, err)
        end)
    end)

    describe('r', function()
        it('asks Rex for one more snapshot', function()
            local backend, calls = fake.new({ snapshots = { TWO } })
            open(backend)
            assert.are.equal(1, count(calls, 'snapshot'))

            press('r')

            assert.are.equal(2, count(calls, 'snapshot'))
        end)

        it('asks Rex when the poller has stopped too', function()
            local backend, calls = fake.new({ snapshots = { TWO } })
            open(backend)
            -- A FocusLost stops the poller while a window still shows the
            -- buffer. A key press means Neovim has the keys again, so `r`
            -- asks Rex even before FocusGained brings the poller back.
            vim.api.nvim_exec_autocmds('FocusLost', {})
            assert.are.equal(1, count(calls, 'snapshot'))

            press('r')

            assert.are.equal(2, count(calls, 'snapshot'))
        end)

        it('does nothing while a snapshot is in flight', function()
            local held
            local snapshots = 0
            local backend = {
                snapshot = function(callback)
                    snapshots = snapshots + 1
                    held = callback
                end,
                focus = function(_, callback)
                    callback(nil)
                end,
                create_window = function(_, callback)
                    callback(nil)
                end,
                create_session = function(_, callback)
                    callback(nil)
                end,
                peek = function(_, callback)
                    callback(nil, '')
                end,
            }
            vim.api.nvim_win_set_buf(0, scratch)
            dashboard.open({
                backend = backend,
                after = timer.after,
                now = function()
                    return NOW
                end,
            })
            assert.are.equal(1, snapshots)

            press('r')
            press('r')
            assert.are.equal(1, snapshots)

            -- The first call comes back: now `r` may ask again.
            held(nil, TWO)
            press('r')
            assert.are.equal(2, snapshots)
        end)
    end)

    describe('e', function()
        -- The first Block ends while the second stays live.
        ---@param ids table `first` and `second` Block ids
        ---@return table first, second snapshots
        local function ending(ids)
            local live = with_first(
                snap.block({
                    id = ids.first,
                    app = 'pi',
                    state = 'working',
                    title = 'the parser',
                }),
                ids.second
            )
            local gone = with_first(
                snap.block({
                    id = ids.first,
                    argv0 = '/bin/zsh',
                    title = 'the parser',
                    last_exit = { exit_code = 3 },
                }),
                ids.second
            )
            return live, gone
        end

        it(
            'hides the Exited row and shows it again with no Rex call',
            function()
                local live, gone =
                    ending({ first = 'block:k8', second = 'block:k9' })
                local backend, calls = fake.new({ snapshots = { live, gone } })
                open(backend)
                timer.fire()
                assert.are.equal(3, #dashboard_lines())
                assert.are.equal(2, count(calls, 'snapshot'))

                press('e')

                assert.are.equal(2, #dashboard_lines())
                assert.are.equal(2, count(calls, 'snapshot'))

                press('e')

                assert.are.equal(3, #dashboard_lines())
                assert.are.equal(2, count(calls, 'snapshot'))
            end
        )

        it('keeps the cursor on the same Agent block', function()
            -- `block:e1` ends in the first Session, so the second Session
            -- moves up a line when the Exited rows go away. The cursor is on
            -- its Agent block and follows it.
            ---@param ended boolean
            ---@return table
            local function two_sessions(ended)
                local last = ended
                        and snap.block({
                            id = 'block:e1',
                            argv0 = '/bin/zsh',
                            title = 'the parser',
                            last_exit = { exit_code = 3 },
                        })
                    or snap.block({
                        id = 'block:e1',
                        app = 'claude-code',
                        state = 'idle',
                        title = 'the parser',
                    })
                return snap.snapshot({
                    snap.session({
                        id = 'session:orbit',
                        label = 'orbit',
                        windows = {
                            snap.window({
                                id = 'window:w7',
                                label = 'api',
                                blocks = {
                                    snap.block({
                                        id = 'block:e0',
                                        app = 'pi',
                                        state = 'working',
                                        title = 'the docs',
                                    }),
                                    last,
                                },
                            }),
                        },
                    }),
                    snap.session({
                        id = 'session:beta',
                        label = 'beta',
                        windows = {
                            snap.window({
                                id = 'window:w8',
                                label = 'web',
                                blocks = {
                                    snap.block({
                                        id = 'block:e2',
                                        app = 'pi',
                                        state = 'idle',
                                        title = 'the schema',
                                    }),
                                },
                            }),
                        },
                    }),
                })
            end
            local backend = fake.new({
                snapshots = { two_sessions(false), two_sessions(true) },
            })
            open(backend)
            timer.fire()
            local win = vim.api.nvim_get_current_win()
            vim.api.nvim_win_set_cursor(win, { 6, 0 })
            assert.are.equal('block:e2', dashboard.current_target(win).block_id)

            press('e')

            assert.are.equal(5, vim.api.nvim_win_get_cursor(win)[1])
            assert.are.equal('block:e2', dashboard.current_target(win).block_id)
        end)

        it('starts from show_exited in the config', function()
            local live, gone =
                ending({ first = 'block:k4', second = 'block:k5' })
            config.setup({ show_exited = false })
            local backend = fake.new({ snapshots = { live, gone } })
            open(backend)
            timer.fire()

            -- `block:k4` exited and is hidden, so only its Session and the
            -- live Block show.
            assert.are.equal(2, #dashboard_lines())

            press('e')

            assert.are.equal(3, #dashboard_lines())
            -- The key is Dashboard state: the config keeps its value.
            assert.is_false(config.get().show_exited)
        end)
    end)

    describe('the keymaps', function()
        it(
            'are only in the Dashboard buffer, with a desc and nowait',
            function()
                local backend = fake.new({ snapshots = { TWO } })
                open(backend)

                local wanted = {
                    ['<CR>'] = 'Go to the Agent block or Session',
                    r = 'Refresh the Dashboard',
                    e = 'Toggle the Exited rows',
                }
                for lhs, desc in pairs(wanted) do
                    local map = vim.fn.maparg(lhs, 'n', false, true)
                    assert.are.equal(desc, map.desc)
                    assert.are.equal(1, map.nowait)
                end

                vim.api.nvim_win_set_buf(0, scratch)
                for lhs in pairs(wanted) do
                    assert.are.equal('', vim.fn.maparg(lhs, 'n'))
                end
            end
        )
    end)
end)
