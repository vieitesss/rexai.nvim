-- The Dashboard buffer and window: where it shows, how it polls and how the
-- cursor stays on the same row across refreshes. The fake Backend serves
-- invented snapshots and the tests fire the poller's timer by hand.

local config = require('rexai.config')
local dashboard = require('rexai.ui.dashboard')
local fake = require('rexai.backend.fake')
local model = require('rexai.core.model')
local render = require('rexai.ui.render')
local snap = require('tests.snapshots')
local support = require('tests.ui_support')

local AGENTS = config.defaults.agents
-- Not the Session this Neovim runs in, so no Home header shows up by itself.
local HOME = 'session:home'

---@param id string
---@param spec table
---@return table a snapshot with one Session and the Agent blocks given
local function snapshot_of(id, spec)
    local blocks = {}
    for index, block in ipairs(spec.blocks) do
        blocks[index] = snap.block(block)
    end
    return snap.snapshot({
        snap.session({
            id = id,
            label = spec.label or 'orbit',
            windows = {
                snap.window({
                    id = 'window:w1',
                    label = spec.window or 'api',
                    blocks = blocks,
                }),
            },
        }),
    })
end

-- Two Agent blocks, no timestamps, so no clock moves a line.
local UNTIMED = snapshot_of('session:s1', {
    blocks = {
        { id = 'block:b1', app = 'claude-code' },
        { id = 'block:b2', argv0 = '/opt/bin/pi' },
    },
})

-- Two Agent blocks whose Agent statuses swap between snapshots.
local FIRST = snapshot_of('session:s1', {
    blocks = {
        {
            id = 'block:b1',
            app = 'pi',
            state = 'idle',
            title = 'the docs',
            updated_at = '2026-11-07T16:14:00Z',
        },
        {
            id = 'block:b2',
            app = 'claude-code',
            state = 'working',
            title = 'the parser',
            updated_at = '2026-11-07T16:14:00Z',
        },
    },
})

local SECOND = snapshot_of('session:s1', {
    blocks = {
        {
            id = 'block:b1',
            app = 'pi',
            state = 'working',
            title = 'the docs',
            updated_at = '2026-11-07T16:14:00Z',
        },
        {
            id = 'block:b2',
            app = 'claude-code',
            state = 'idle',
            title = 'the parser',
            updated_at = '2026-11-07T16:14:00Z',
        },
    },
})

---@param snapshot table
---@param opts table|nil
---@return rexai.Render
local function expected(snapshot, opts)
    opts = opts or {}
    opts.now = support.NOW
    return render.build(model.build(snapshot, AGENTS), opts)
end

---@param win integer
---@param option string
---@return any
local function window_option(win, option)
    return vim.api.nvim_get_option_value(option, { win = win })
end

describe('ui.dashboard', function()
    local h

    before_each(function()
        h = support.new()
    end)

    after_each(function()
        h:close()
    end)

    describe('the Rexai command', function()
        it('shows the Dashboard in the current window', function()
            local win = vim.api.nvim_get_current_win()

            local _, calls = h:command({ snapshots = { UNTIMED } })

            assert.are.equal(win, vim.api.nvim_get_current_win())
            local buf = assert(h:buf())
            assert.are.equal(buf, vim.api.nvim_win_get_buf(win))

            assert.are.equal('nofile', vim.bo[buf].buftype)
            assert.are.equal('hide', vim.bo[buf].bufhidden)
            assert.is_false(vim.bo[buf].swapfile)
            assert.are.equal('rexai', vim.bo[buf].filetype)
            assert.is_false(vim.bo[buf].modifiable)

            assert.is_false(window_option(win, 'wrap'))
            assert.is_true(window_option(win, 'cursorline'))
            assert.is_false(window_option(win, 'number'))
            assert.is_false(window_option(win, 'relativenumber'))
            assert.are.equal('no', window_option(win, 'signcolumn'))
            assert.is_false(window_option(win, 'spell'))
            assert.is_false(window_option(win, 'foldenable'))

            local want = expected(UNTIMED)
            assert.are.same(want.lines, h:lines())

            -- One highlight span per span of the render, on the buffer.
            local marks = vim.api.nvim_buf_get_extmarks(
                buf,
                vim.api.nvim_create_namespace('rexai'),
                0,
                -1,
                { details = true }
            )
            assert.are.equal(#want.highlights, #marks)
            assert.are.equal(1, #calls)
        end)

        it('reuses the same buffer for a second :Rexai', function()
            h:command({ snapshots = { UNTIMED } })
            local first = h:buf()
            h:command()

            assert.are.equal(first, h:buf())
            local named = {}
            for _, buf in ipairs(vim.api.nvim_list_bufs()) do
                if vim.api.nvim_buf_get_name(buf) == dashboard.NAME then
                    named[#named + 1] = buf
                end
            end
            assert.are.same({ first }, named)
        end)

        it('leaves no timer behind when opened twice', function()
            h:open({ snapshots = { UNTIMED } })
            h:open({ snapshots = { UNTIMED } })

            -- The second open ticked once and replaced the pending timer, so
            -- only one is left, not two.
            assert.are.equal(1, h.timer.count())
        end)
    end)

    describe('leaving the Dashboard', function()
        it('returns to the buffer that was in the window', function()
            h:command({ snapshots = { UNTIMED } })
            assert.are.equal(dashboard.NAME, vim.api.nvim_buf_get_name(0))

            h:press('q')

            assert.are.equal(h.scratch, vim.api.nvim_get_current_buf())
            assert.are.equal(1, #vim.api.nvim_tabpage_list_wins(0))
        end)

        it('closes the window when there is no buffer to return to', function()
            h:command({ snapshots = { UNTIMED } })
            vim.cmd('vsplit')
            assert.are.equal(2, #vim.api.nvim_tabpage_list_wins(0))
            vim.api.nvim_buf_delete(h.scratch, { force = true })

            h:press('q')

            assert.are.equal(1, #vim.api.nvim_tabpage_list_wins(0))
            assert.are.equal(dashboard.NAME, vim.api.nvim_buf_get_name(0))
        end)

        it('returns each window to the buffer it had before', function()
            local first_win = vim.api.nvim_get_current_win()
            h:open({ snapshots = { UNTIMED } })

            -- A second window shows the Dashboard over another buffer.
            vim.cmd('vsplit')
            local second_win = vim.api.nvim_get_current_win()
            local other = vim.api.nvim_create_buf(true, false)
            vim.api.nvim_win_set_buf(second_win, other)
            h:open({ snapshots = { UNTIMED } })
            assert.are.equal(h:buf(), vim.api.nvim_win_get_buf(first_win))
            assert.are.equal(h:buf(), vim.api.nvim_win_get_buf(second_win))

            h:press('q')
            assert.are.equal(other, vim.api.nvim_win_get_buf(second_win))

            vim.api.nvim_set_current_win(first_win)
            h:press('q')
            assert.are.equal(h.scratch, vim.api.nvim_win_get_buf(first_win))

            vim.api.nvim_buf_delete(other, { force = true })
        end)

        it('starts an empty buffer in a window with nothing else', function()
            h:command({ snapshots = { UNTIMED } })
            vim.api.nvim_buf_delete(h.scratch, { force = true })

            h:press('q')

            assert.are.equal(1, #vim.api.nvim_tabpage_list_wins(0))
            assert.are.equal('', vim.api.nvim_buf_get_name(0))
        end)
    end)

    describe('polling', function()
        it('asks Rex at once and then after the refresh interval', function()
            local _, calls = h:open({ snapshots = { UNTIMED } })

            assert.are.equal(1, support.count(calls, 'snapshot'))
            assert.are.equal(1, h.timer.count())
            assert.are.equal(config.get().refresh_ms, h.timer.pending[1].ms)

            h.timer.fire()
            assert.are.equal(2, support.count(calls, 'snapshot'))
            assert.are.equal(1, h.timer.count())
        end)

        it(
            'stops when no window shows the buffer and starts again on :Rexai',
            function()
                local _, calls = h:open({ snapshots = { UNTIMED } })

                h:press('q')
                assert.are.equal(0, h.timer.count())
                assert.are.equal(1, support.count(calls, 'snapshot'))

                h:command()
                assert.are.equal(2, support.count(calls, 'snapshot'))
                assert.are.equal(1, h.timer.count())
            end
        )

        it('stops on FocusLost and refreshes on FocusGained', function()
            local _, calls = h:open({ snapshots = { UNTIMED } })

            vim.api.nvim_exec_autocmds('FocusLost', {})
            assert.are.equal(0, h.timer.count())

            vim.api.nvim_exec_autocmds('FocusGained', {})
            assert.are.equal(2, support.count(calls, 'snapshot'))
            assert.are.equal(1, h.timer.count())
        end)

        it('keeps polling while another window shows the buffer', function()
            local _, calls = h:open({ snapshots = { UNTIMED } })
            vim.cmd('vsplit')
            assert.are.equal(2, #vim.api.nvim_tabpage_list_wins(0))

            h:press('q')

            -- The split was never over another buffer, so it closes.
            assert.are.equal(1, #vim.api.nvim_tabpage_list_wins(0))
            assert.are.equal(1, h.timer.count())
            h.timer.fire()
            assert.is_true(support.count(calls, 'snapshot') > 1)
        end)

        it('starts when a window shows the buffer again', function()
            local _, calls = h:open({ snapshots = { UNTIMED } })
            h:press('q')
            assert.are.equal(0, h.timer.count())
            local served_before = support.count(calls, 'snapshot')

            vim.api.nvim_win_set_buf(0, h:buf())

            assert.are.equal(
                served_before + 1,
                support.count(calls, 'snapshot')
            )
            assert.are.equal(1, h.timer.count())
        end)

        it('does not write the buffer when nothing changed', function()
            h:open({ snapshots = { FIRST }, home_session_id = HOME })
            local changes = 0
            vim.api.nvim_buf_attach(h:buf(), false, {
                on_lines = function()
                    changes = changes + 1
                end,
            })
            local before = h:lines()

            h.timer.fire()
            h.timer.fire()

            assert.are.equal(0, changes)
            assert.are.same(before, h:lines())
        end)

        it('makes no Rex call while the buffer is hidden', function()
            local _, calls = h:open({ snapshots = { UNTIMED } })
            h:press('q')

            vim.api.nvim_exec_autocmds('FocusGained', {})

            assert.are.equal(1, support.count(calls, 'snapshot'))
            assert.are.equal(0, h.timer.count())
        end)
    end)

    describe('the Home session', function()
        it('names it with the label Rex gave it', function()
            local raw = snap.snapshot({
                snap.session({
                    id = HOME,
                    label = 'landing',
                    windows = {
                        snap.window({
                            id = 'window:w9',
                            label = 'shell',
                            blocks = {
                                snap.block({
                                    id = 'block:b9',
                                    argv0 = '/bin/zsh',
                                }),
                            },
                        }),
                    },
                }),
            })

            h:open({ snapshots = { raw }, home_session_id = HOME })

            assert.are.same({ '  landing (home)' }, h:lines())
        end)
    end)

    describe('an unreadable Rex', function()
        it('shows the error in the buffer and clears it on recovery', function()
            local backend = fake.new({ snapshots = { UNTIMED } })
            backend.fail_next('snapshot', 'rex timed out')

            h:open({ backend = backend, home_session_id = HOME })

            assert.is_truthy(h:lines()[1]:find('Rex unreadable', 1, true))
            -- The poller retries, so the Dashboard recovers by itself.
            assert.are.equal(1, h.timer.count())
            h.timer.fire()
            assert.are.same(
                expected(UNTIMED, { home_session_id = HOME }).lines,
                h:lines()
            )
            assert.are.equal(0, #h.notify.calls)
        end)
    end)

    describe('window options', function()
        it('gives them back when the window leaves the Dashboard', function()
            local win = vim.api.nvim_get_current_win()
            vim.api.nvim_set_option_value('number', true, { win = win })
            vim.api.nvim_set_option_value('signcolumn', 'yes', { win = win })

            h:open({ snapshots = { UNTIMED } })
            assert.is_false(window_option(win, 'number'))
            assert.are.equal('no', window_option(win, 'signcolumn'))

            h:press('q')

            assert.is_true(window_option(win, 'number'))
            assert.are.equal('yes', window_option(win, 'signcolumn'))
        end)
    end)

    describe('closing', function()
        it('leaves no buffer, autocmd or timer behind', function()
            local windows = #vim.api.nvim_tabpage_list_wins(0)
            local buffers = #vim.api.nvim_list_bufs()

            h:open({ snapshots = { UNTIMED } })
            local buf = assert(h:buf())
            h:press('q')
            assert.are.equal(0, h.timer.count())
            vim.api.nvim_buf_delete(buf, { force = true })

            assert.is_false(vim.api.nvim_buf_is_valid(buf))
            assert.are.equal(-1, vim.fn.bufnr(dashboard.NAME))
            assert.are.equal(0, vim.fn.exists('#RexaiDashboard'))
            assert.are.equal(windows, #vim.api.nvim_tabpage_list_wins(0))
            assert.are.equal(buffers, #vim.api.nvim_list_bufs())
        end)
    end)

    describe('cursor restore', function()
        it(
            'keeps each window on its own Agent block when the rows move',
            function()
                h:open({
                    snapshots = { FIRST, SECOND },
                    home_session_id = HOME,
                })
                local first_win = vim.api.nvim_get_current_win()

                vim.cmd('vsplit')
                local second_win = vim.api.nvim_get_current_win()
                local before = expected(FIRST, { home_session_id = HOME })
                vim.api.nvim_win_set_cursor(first_win, {
                    support.line_of(before.targets, 'block:b1'),
                    0,
                })
                vim.api.nvim_win_set_cursor(second_win, {
                    support.line_of(before.targets, 'block:b2'),
                    0,
                })

                h.timer.fire()

                local after = expected(SECOND, { home_session_id = HOME })
                assert.is_true(
                    support.line_of(after.targets, 'block:b1')
                        ~= support.line_of(before.targets, 'block:b1')
                )
                assert.are.equal(
                    support.line_of(after.targets, 'block:b1'),
                    vim.api.nvim_win_get_cursor(first_win)[1]
                )
                assert.are.equal(
                    support.line_of(after.targets, 'block:b2'),
                    vim.api.nvim_win_get_cursor(second_win)[1]
                )
                assert.are.equal(
                    'block:b1',
                    dashboard.current_target(first_win).block_id
                )
                -- The window being typed in never loses focus.
                assert.are.equal(second_win, vim.api.nvim_get_current_win())
            end
        )

        it('keeps the line number when the row is gone', function()
            -- `block:b1` leaves Rex: its row is gone and the buffer is one
            -- line shorter than the cursor.
            local only = snapshot_of('session:s1', {
                blocks = {
                    {
                        id = 'block:b2',
                        app = 'claude-code',
                        state = 'working',
                        title = 'the parser',
                        updated_at = '2026-11-07T16:14:00Z',
                    },
                },
            })
            h:open({ snapshots = { FIRST, only } })
            local win = vim.api.nvim_get_current_win()
            local before = expected(FIRST)
            vim.api.nvim_win_set_cursor(win, {
                support.line_of(before.targets, 'block:b1'),
                0,
            })
            assert.are.equal(3, #h:lines())

            h.timer.fire()

            assert.are.equal(2, #h:lines())
            assert.are.equal(2, vim.api.nvim_win_get_cursor(win)[1])
        end)
    end)
end)
