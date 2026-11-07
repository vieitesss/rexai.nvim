-- The Dashboard buffer and window: where it shows, how it polls and how the
-- cursor stays on the same row across refreshes. The fake Backend serves
-- invented snapshots and the tests fire the poller's timer by hand.

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
-- Not the Session this Neovim runs in, so no Home header shows up by itself.
local HOME = 'session:home'

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
    opts.now = NOW
    return render.build(model.build(snapshot, AGENTS), opts)
end

---@param out rexai.Render
---@param block_id string
---@return integer the line of that Agent block
local function line_of(out, block_id)
    for line, target in pairs(out.targets) do
        if target.block_id == block_id then
            return line
        end
    end
    error('no line for ' .. block_id)
end

---@param win integer
---@param option string
---@return any
local function window_option(win, option)
    return vim.api.nvim_get_option_value(option, { win = win })
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
    vim.api.nvim_feedkeys(
        vim.api.nvim_replace_termcodes(keys, true, false, true),
        'x',
        false
    )
end

---@return string[]
local function dashboard_lines()
    return vim.api.nvim_buf_get_lines(dashboard_buf(), 0, -1, false)
end

describe('ui.dashboard', function()
    local timer
    local scratch

    before_each(function()
        scratch = vim.api.nvim_create_buf(true, false)
        timer = fake_timer()
        vim.env.REX_SESSION = nil
        vim.g.loaded_rexai = nil
        vim.cmd('runtime plugin/rexai.lua')
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
        package.loaded['rexai.backend.rex'] = nil
    end)

    ---@param backend rexai.Backend
    local function stub_rex(backend)
        package.loaded['rexai.backend.rex'] = {
            new = function()
                return backend
            end,
        }
    end

    describe('the Rexai command', function()
        it('shows the Dashboard in the current window', function()
            local backend, calls = fake.new({ snapshots = { UNTIMED } })
            stub_rex(backend)
            local win = vim.api.nvim_get_current_win()

            vim.cmd('Rexai')

            assert.are.equal(win, vim.api.nvim_get_current_win())
            local buf = assert(dashboard_buf())
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

            local want = expected(UNTIMED, { home_session_id = nil })
            assert.are.same(want.lines, dashboard_lines())

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
            local backend = fake.new({ snapshots = { UNTIMED } })
            stub_rex(backend)

            vim.cmd('Rexai')
            local first = dashboard_buf()
            vim.cmd('Rexai')

            assert.are.equal(first, dashboard_buf())
            local named = {}
            for _, buf in ipairs(vim.api.nvim_list_bufs()) do
                if vim.api.nvim_buf_get_name(buf) == NAME then
                    named[#named + 1] = buf
                end
            end
            assert.are.same({ first }, named)
        end)

        it('leaves no timer behind when opened twice', function()
            local backend = fake.new({ snapshots = { UNTIMED } })
            stub_rex(backend)

            dashboard.open({ backend = backend, after = timer.after })
            dashboard.open({ backend = backend, after = timer.after })

            -- The second open ticked once and replaced the pending timer, so
            -- only one is left, not two.
            assert.are.equal(1, timer.count())
        end)
    end)

    describe('leaving the Dashboard', function()
        it('returns to the buffer that was in the window', function()
            local backend = fake.new({ snapshots = { UNTIMED } })
            stub_rex(backend)
            vim.api.nvim_win_set_buf(0, scratch)

            vim.cmd('Rexai')
            assert.are.equal('rexai://dashboard', vim.api.nvim_buf_get_name(0))

            press('q')

            assert.are.equal(scratch, vim.api.nvim_get_current_buf())
            assert.are.equal(1, #vim.api.nvim_tabpage_list_wins(0))
        end)

        it('closes the window when there is no buffer to return to', function()
            local backend = fake.new({ snapshots = { UNTIMED } })
            stub_rex(backend)
            vim.api.nvim_win_set_buf(0, scratch)

            vim.cmd('Rexai')
            vim.cmd('vsplit')
            assert.are.equal(2, #vim.api.nvim_tabpage_list_wins(0))
            vim.api.nvim_buf_delete(scratch, { force = true })

            press('q')

            assert.are.equal(1, #vim.api.nvim_tabpage_list_wins(0))
            assert.are.equal('rexai://dashboard', vim.api.nvim_buf_get_name(0))
        end)

        it('starts an empty buffer in a window with nothing else', function()
            local backend = fake.new({ snapshots = { UNTIMED } })
            stub_rex(backend)
            vim.api.nvim_win_set_buf(0, scratch)

            vim.cmd('Rexai')
            vim.api.nvim_buf_delete(scratch, { force = true })

            press('q')

            assert.are.equal(1, #vim.api.nvim_tabpage_list_wins(0))
            assert.are.equal('', vim.api.nvim_buf_get_name(0))
        end)
    end)

    describe('polling', function()
        ---@return integer how many snapshots the Backend served
        local function served(calls)
            local count = 0
            for _, call in ipairs(calls) do
                if call.method == 'snapshot' then
                    count = count + 1
                end
            end
            return count
        end

        it('asks Rex at once and then after the refresh interval', function()
            local backend, calls = fake.new({ snapshots = { UNTIMED } })
            vim.api.nvim_win_set_buf(0, scratch)

            dashboard.open({ backend = backend, after = timer.after })

            assert.are.equal(1, served(calls))
            assert.are.equal(1, timer.count())
            assert.are.equal(config.get().refresh_ms, timer.pending[1].ms)

            timer.fire()
            assert.are.equal(2, served(calls))
            assert.are.equal(1, timer.count())
        end)

        it(
            'stops when no window shows the buffer and starts again on :Rexai',
            function()
                local backend, calls = fake.new({ snapshots = { UNTIMED } })
                vim.api.nvim_win_set_buf(0, scratch)
                dashboard.open({ backend = backend, after = timer.after })

                press('q')
                assert.are.equal(0, timer.count())
                assert.are.equal(1, served(calls))

                vim.cmd('Rexai')
                assert.are.equal(2, served(calls))
                assert.are.equal(1, timer.count())
            end
        )

        it('stops on FocusLost and refreshes on FocusGained', function()
            local backend, calls = fake.new({ snapshots = { UNTIMED } })
            vim.api.nvim_win_set_buf(0, scratch)
            dashboard.open({ backend = backend, after = timer.after })

            vim.api.nvim_exec_autocmds('FocusLost', {})
            assert.are.equal(0, timer.count())

            vim.api.nvim_exec_autocmds('FocusGained', {})
            assert.are.equal(2, served(calls))
            assert.are.equal(1, timer.count())
        end)

        it('keeps polling while another window shows the buffer', function()
            local backend, calls = fake.new({ snapshots = { UNTIMED } })
            vim.api.nvim_win_set_buf(0, scratch)
            dashboard.open({ backend = backend, after = timer.after })
            vim.cmd('vsplit')
            assert.are.equal(2, #vim.api.nvim_tabpage_list_wins(0))

            press('q')

            assert.are.equal(2, #vim.api.nvim_tabpage_list_wins(0))
            assert.are.equal(1, timer.count())
            timer.fire()
            assert.is_true(served(calls) > 1)
        end)

        it('starts when a window shows the buffer again', function()
            local backend, calls = fake.new({ snapshots = { UNTIMED } })
            vim.api.nvim_win_set_buf(0, scratch)
            dashboard.open({ backend = backend, after = timer.after })
            press('q')
            assert.are.equal(0, timer.count())
            local served_before = served(calls)

            vim.api.nvim_win_set_buf(0, dashboard_buf())

            assert.are.equal(served_before + 1, served(calls))
            assert.are.equal(1, timer.count())
        end)

        it('does not write the buffer when nothing changed', function()
            local backend = fake.new({ snapshots = { FIRST } })
            vim.api.nvim_win_set_buf(0, scratch)
            dashboard.open({
                backend = backend,
                after = timer.after,
                now = function()
                    return NOW
                end,
                home_session_id = HOME,
            })
            local changes = 0
            vim.api.nvim_buf_attach(dashboard_buf(), false, {
                on_lines = function()
                    changes = changes + 1
                end,
            })
            local before = dashboard_lines()

            timer.fire()
            timer.fire()

            assert.are.equal(0, changes)
            assert.are.same(before, dashboard_lines())
        end)

        it('makes no Rex call while the buffer is hidden', function()
            local backend, calls = fake.new({ snapshots = { UNTIMED } })
            vim.api.nvim_win_set_buf(0, scratch)
            dashboard.open({ backend = backend, after = timer.after })
            press('q')

            vim.api.nvim_exec_autocmds('FocusGained', {})

            assert.are.equal(1, served(calls))
            assert.are.equal(0, timer.count())
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
            local backend = fake.new({ snapshots = { raw } })
            vim.api.nvim_win_set_buf(0, scratch)

            dashboard.open({
                backend = backend,
                after = timer.after,
                now = function()
                    return NOW
                end,
                home_session_id = HOME,
            })

            assert.are.same({ '  landing (home)' }, dashboard_lines())
        end)
    end)

    describe('an unreadable Rex', function()
        it('shows the error in the buffer and clears it on recovery', function()
            local backend = fake.new({ snapshots = { UNTIMED } })
            backend.fail_next('snapshot', 'rex timed out')
            vim.api.nvim_win_set_buf(0, scratch)
            local notified = 0
            local notify = vim.notify
            vim.notify = function()
                notified = notified + 1
            end

            local ok, err = pcall(function()
                dashboard.open({
                    backend = backend,
                    after = timer.after,
                    now = function()
                        return NOW
                    end,
                    home_session_id = HOME,
                })

                assert.is_truthy(
                    dashboard_lines()[1]:find('Rex unreadable', 1, true)
                )
                -- The poller retries, so the Dashboard recovers by itself.
                assert.are.equal(1, timer.count())
                timer.fire()
                assert.are.same(
                    expected(UNTIMED, { home_session_id = HOME }).lines,
                    dashboard_lines()
                )
                assert.are.equal(0, notified)
            end)
            vim.notify = notify
            assert(ok, err)
        end)
    end)

    describe('window options', function()
        it('gives them back when the window leaves the Dashboard', function()
            local backend = fake.new({ snapshots = { UNTIMED } })
            vim.api.nvim_win_set_buf(0, scratch)
            local win = vim.api.nvim_get_current_win()
            vim.api.nvim_set_option_value('number', true, { win = win })
            vim.api.nvim_set_option_value('signcolumn', 'yes', { win = win })

            dashboard.open({ backend = backend, after = timer.after })
            assert.is_false(window_option(win, 'number'))
            assert.are.equal('no', window_option(win, 'signcolumn'))

            press('q')

            assert.is_true(window_option(win, 'number'))
            assert.are.equal('yes', window_option(win, 'signcolumn'))
        end)
    end)

    describe('closing', function()
        it('leaves no buffer, autocmd or timer behind', function()
            local backend = fake.new({ snapshots = { UNTIMED } })
            vim.api.nvim_win_set_buf(0, scratch)
            local windows = #vim.api.nvim_tabpage_list_wins(0)
            local buffers = #vim.api.nvim_list_bufs()

            dashboard.open({ backend = backend, after = timer.after })
            local buf = dashboard_buf()
            press('q')
            assert.are.equal(0, timer.count())
            vim.api.nvim_buf_delete(buf, { force = true })

            assert.is_false(vim.api.nvim_buf_is_valid(buf))
            assert.are.equal(-1, vim.fn.bufnr(NAME))
            assert.are.equal(0, vim.fn.exists('#RexaiDashboard'))
            assert.are.equal(windows, #vim.api.nvim_tabpage_list_wins(0))
            assert.are.equal(buffers, #vim.api.nvim_list_bufs())
        end)
    end)

    describe('cursor restore', function()
        it(
            'keeps each window on its own Agent block when the rows move',
            function()
                local backend = fake.new({ snapshots = { FIRST, SECOND } })
                local options = {
                    backend = backend,
                    after = timer.after,
                    now = function()
                        return NOW
                    end,
                    home_session_id = HOME,
                }
                vim.api.nvim_win_set_buf(0, scratch)
                dashboard.open(options)
                local first_win = vim.api.nvim_get_current_win()

                vim.cmd('vsplit')
                local second_win = vim.api.nvim_get_current_win()
                local before = expected(FIRST, { home_session_id = HOME })
                vim.api.nvim_win_set_cursor(first_win, {
                    line_of(before, 'block:b1'),
                    0,
                })
                vim.api.nvim_win_set_cursor(second_win, {
                    line_of(before, 'block:b2'),
                    0,
                })

                timer.fire()

                local after = expected(SECOND, { home_session_id = HOME })
                assert.is_true(
                    line_of(after, 'block:b1') ~= line_of(before, 'block:b1')
                )
                assert.are.equal(
                    line_of(after, 'block:b1'),
                    vim.api.nvim_win_get_cursor(first_win)[1]
                )
                assert.are.equal(
                    line_of(after, 'block:b2'),
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
            local backend = fake.new({ snapshots = { FIRST, only } })
            local options = {
                backend = backend,
                after = timer.after,
                now = function()
                    return NOW
                end,
            }
            vim.api.nvim_win_set_buf(0, scratch)
            dashboard.open(options)
            local win = vim.api.nvim_get_current_win()
            local before = expected(FIRST)
            vim.api.nvim_win_set_cursor(win, {
                line_of(before, 'block:b1'),
                0,
            })
            assert.are.equal(3, #dashboard_lines())

            timer.fire()

            assert.are.equal(2, #dashboard_lines())
            assert.are.equal(2, vim.api.nvim_win_get_cursor(win)[1])
        end)
    end)
end)
