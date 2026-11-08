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
local support = require('tests.ui_support')

local AGENTS = config.defaults.agents

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

---@param snapshot table
---@return table<integer, rexai.RenderTarget>
local function targets_of(snapshot)
    return render.build(model.build(snapshot, AGENTS), { now = support.NOW }).targets
end

describe('ui.dashboard keys', function()
    local h

    before_each(function()
        h = support.new()
    end)

    after_each(function()
        h:close()
    end)

    describe('<CR>', function()
        it('focuses the Agent block under the cursor', function()
            local _, calls = h:open({ snapshots = { TWO } })
            local win = vim.api.nvim_get_current_win()
            vim.api.nvim_win_set_cursor(win, {
                support.line_of(targets_of(TWO), 'block:k1'),
                0,
            })

            h:press('<CR>')

            assert.are.same({
                session_id = 'session:alpha',
                window_id = 'window:w1',
                block_id = 'block:k1',
            }, support.last_focus(calls))
        end)

        it('focuses the Session of a header with its id only', function()
            local _, calls = h:open({ snapshots = { TWO } })
            vim.api.nvim_win_set_cursor(
                vim.api.nvim_get_current_win(),
                { 1, 0 }
            )

            h:press('<CR>')

            assert.are.same(
                { session_id = 'session:alpha' },
                support.last_focus(calls)
            )
        end)

        it('does nothing on a line with no target', function()
            local _, calls = h:open({ snapshots = { TWO, EMPTY } })
            local win = vim.api.nvim_get_current_win()
            -- Line 3 is the blank line between the two Sessions.
            vim.api.nvim_win_set_cursor(win, { 3, 0 })
            assert.are.equal('', h:lines()[3])

            h:press('<CR>')

            assert.is_nil(support.last_focus(calls))
            assert.are.equal(0, support.count(calls, 'focus'))
        end)

        it('warns once and refreshes when Rex cannot focus', function()
            local backend, calls = fake.new({ snapshots = { TWO } })
            backend.fail_next('focus', 'target not found')
            h:open({ backend = backend })
            vim.api.nvim_win_set_cursor(vim.api.nvim_get_current_win(), {
                support.line_of(targets_of(TWO), 'block:k1'),
                0,
            })

            h:press('<CR>')

            assert.are.equal(1, #h.notify.calls)
            assert.are.equal(
                'rexai: target not found',
                h.notify.calls[1].message
            )
            assert.are.equal(vim.log.levels.WARN, h.notify.calls[1].level)
            -- The target has probably vanished, so the Dashboard asks
            -- Rex again at once.
            assert.are.equal(2, support.count(calls, 'snapshot'))
        end)
    end)

    describe('r', function()
        it('asks Rex for one more snapshot', function()
            local _, calls = h:open({ snapshots = { TWO } })
            assert.are.equal(1, support.count(calls, 'snapshot'))

            h:press('r')

            assert.are.equal(2, support.count(calls, 'snapshot'))
        end)

        it('asks Rex when the poller has stopped too', function()
            local _, calls = h:open({ snapshots = { TWO } })
            -- A FocusLost stops the poller while a window still shows the
            -- buffer. A key press means Neovim has the keys again, so `r`
            -- asks Rex even before FocusGained brings the poller back.
            vim.api.nvim_exec_autocmds('FocusLost', {})
            assert.are.equal(1, support.count(calls, 'snapshot'))

            h:press('r')

            assert.are.equal(2, support.count(calls, 'snapshot'))
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
            h:open({ backend = backend })
            assert.are.equal(1, snapshots)

            h:press('r')
            h:press('r')
            assert.are.equal(1, snapshots)

            -- The first call comes back: now `r` may ask again.
            held(nil, TWO)
            h:press('r')
            assert.are.equal(2, snapshots)
        end)
    end)

    describe('e', function()
        -- The first Block ends while the second stays live.
        ---@param ids table `first` and `second` Block ids
        ---@return table, table first and second snapshots
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
                local _, calls = h:open({ snapshots = { live, gone } })
                h.timer.fire()
                assert.are.equal(3, #h:lines())
                assert.are.equal(2, support.count(calls, 'snapshot'))

                h:press('e')

                assert.are.equal(2, #h:lines())
                assert.are.equal(2, support.count(calls, 'snapshot'))

                h:press('e')

                assert.are.equal(3, #h:lines())
                assert.are.equal(2, support.count(calls, 'snapshot'))
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
            h:open({
                snapshots = { two_sessions(false), two_sessions(true) },
            })
            h.timer.fire()
            local win = vim.api.nvim_get_current_win()
            vim.api.nvim_win_set_cursor(win, { 6, 0 })
            assert.are.equal('block:e2', dashboard.current_target(win).block_id)

            h:press('e')

            assert.are.equal(5, vim.api.nvim_win_get_cursor(win)[1])
            assert.are.equal('block:e2', dashboard.current_target(win).block_id)
        end)

        it('starts from show_exited in the config', function()
            local live, gone =
                ending({ first = 'block:k4', second = 'block:k5' })
            config.setup({ show_exited = false })
            h:open({ snapshots = { live, gone } })
            h.timer.fire()

            -- `block:k4` exited and is hidden, so only its Session and the
            -- live Block show.
            assert.are.equal(2, #h:lines())

            h:press('e')

            assert.are.equal(3, #h:lines())
            -- The key is Dashboard state: the config keeps its value.
            assert.is_false(config.get().show_exited)
        end)
    end)

    describe('the keymaps', function()
        it(
            'are only in the Dashboard buffer, with a desc and nowait',
            function()
                h:open({ snapshots = { TWO } })

                local wanted = {
                    ['<CR>'] = 'Go to the Agent block or Session',
                    r = 'Refresh the Dashboard',
                    e = 'Toggle the Exited rows',
                    K = 'Peek at the Agent block',
                    n = 'Add a Window to the Session',
                    N = 'Start a Session',
                }
                for lhs, desc in pairs(wanted) do
                    local map = vim.fn.maparg(lhs, 'n', false, true)
                    assert.are.equal(desc, map.desc)
                    assert.are.equal(1, map.nowait)
                end

                vim.api.nvim_win_set_buf(0, h.scratch)
                for lhs in pairs(wanted) do
                    assert.are.equal('', vim.fn.maparg(lhs, 'n'))
                end
            end
        )
    end)
end)
