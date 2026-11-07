-- The lifetime of the Dashboard actions: a result acts only on the Dashboard,
-- and the Backend, that issued the request. The Backend here answers
-- `snapshot` at once and keeps every `focus` until the test answers it, so the
-- test decides when a result arrives and which Dashboard is open then.
-- Snapshots are invented.

local config = require('rexai.config')
local dashboard = require('rexai.ui.dashboard')
local snap = require('tests.snapshots')

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

    return timer
end

-- One Session with one Agent block: its row is line 2 of the Dashboard.
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
                },
            }),
        },
    }),
})

-- A Backend that answers `snapshot` at once and holds every `focus` until the
-- test answers it.
local function backend()
    local object = { snapshots = 0, targets = {}, pending = {} }

    function object.snapshot(callback)
        object.snapshots = object.snapshots + 1
        callback(nil, SNAPSHOT)
    end

    function object.focus(target, callback)
        object.targets[#object.targets + 1] = target
        object.pending[#object.pending + 1] = callback
    end

    function object.create_window(_, callback)
        callback(nil)
    end

    function object.create_session(_, callback)
        callback(nil)
    end

    function object.peek(_, callback)
        callback(nil, '')
    end

    -- Answers the oldest focus call with `err`.
    ---@param err string|nil
    function object.answer(err)
        local callback = table.remove(object.pending, 1)
        assert.is_not_nil(callback, 'no focus call is waiting')
        callback(err)
    end

    return object
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

describe('ui.dashboard actions lifetime', function()
    local timer, scratch, told, real_notify

    before_each(function()
        vim.env.REX_SESSION = nil
        config.setup()
        scratch = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_win_set_buf(0, scratch)
        timer = fake_timer()
        told = { calls = {} }
        real_notify = vim.notify
        vim.notify = function(message, level)
            told.calls[#told.calls + 1] = {
                message = message,
                level = level,
            }
        end
    end)

    after_each(function()
        vim.notify = real_notify
        local buf = dashboard_buf()
        if buf then
            if vim.api.nvim_buf_is_valid(scratch) then
                for _, win in ipairs(vim.fn.win_findbuf(buf)) do
                    if vim.api.nvim_win_is_valid(win) then
                        vim.api.nvim_win_set_buf(win, scratch)
                    end
                end
            end
            pcall(vim.api.nvim_buf_delete, buf, { force = true })
        end
        if vim.api.nvim_buf_is_valid(scratch) then
            vim.api.nvim_buf_delete(scratch, { force = true })
        end
        config.setup()
    end)

    ---@param object table the Backend of the Dashboard
    local function open(object)
        vim.api.nvim_win_set_buf(0, scratch)
        dashboard.open({
            backend = object,
            after = timer.after,
            now = function()
                return NOW
            end,
        })
    end

    -- Puts the cursor on the Agent row of the Dashboard.
    local function put_cursor_on_row()
        local win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_cursor(win, { 2, 0 })
        assert.are.equal('row', dashboard.current_target(win).kind)
    end

    -- Wipes the Dashboard buffer, as `:bwipeout` would: the buffer leaves the
    -- window and every autocmd of the Dashboard fires.
    local function wipe()
        local buf = dashboard_buf()
        assert.is_not_nil(buf)
        for _, win in ipairs(vim.fn.win_findbuf(buf)) do
            if vim.api.nvim_win_is_valid(win) then
                vim.api.nvim_win_set_buf(win, scratch)
            end
        end
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
        assert.is_nil(dashboard_buf())
    end

    it('drops a result that arrives after the Dashboard was wiped', function()
        local first = backend()
        open(first)
        put_cursor_on_row()
        press('<CR>')
        assert.are.equal(1, #first.targets)

        wipe()
        local second = backend()
        open(second)
        assert.are.equal(1, second.snapshots)

        -- The failure of the wiped Dashboard answers now, while the
        -- replacement Dashboard has a window and its own Backend.
        first.answer('target not found')

        assert.are.same({}, told.calls)
        assert.are.equal(1, second.snapshots)
    end)

    it(
        'drops a result when another Backend replaced the one that issued it',
        function()
            local first = backend()
            open(first)
            put_cursor_on_row()
            press('<CR>')

            -- A second `:Rexai` with its own Backend replaces the poller, the
            -- Backend and the actions while the same buffer stays.
            local second = backend()
            open(second)
            assert.are.equal(1, second.snapshots)

            first.answer('target not found')

            assert.are.same({}, told.calls)
            assert.are.equal(1, second.snapshots)
        end
    )

    it(
        'warns and refreshes when the failure belongs to this Dashboard',
        function()
            local object = backend()
            open(object)
            put_cursor_on_row()
            press('<CR>')
            assert.are.equal(1, object.snapshots)

            object.answer('target not found')

            assert.are.equal(1, #told.calls)
            assert.are.equal('rexai: target not found', told.calls[1].message)
            assert.are.equal(vim.log.levels.WARN, told.calls[1].level)
            -- The target has probably vanished, so the Dashboard asks Rex again at
            -- once.
            assert.are.equal(2, object.snapshots)
        end
    )

    it('does nothing when a deferred success arrives', function()
        local object = backend()
        open(object)
        put_cursor_on_row()
        press('<CR>')

        object.answer(nil)

        assert.are.same({}, told.calls)
        assert.are.equal(1, object.snapshots)
    end)

    it(
        'still counts a result that arrives while it is merely hidden',
        function()
            local object = backend()
            open(object)
            put_cursor_on_row()
            press('<CR>')

            -- The window leaves the Dashboard: the poller stops, nothing is
            -- wiped, so the Dashboard is paused, not gone.
            vim.api.nvim_win_set_buf(0, scratch)
            object.answer('target not found')

            assert.are.equal(1, #told.calls)
            assert.are.equal('rexai: target not found', told.calls[1].message)
            -- No window shows the buffer, so the refresh asks Rex nothing.
            assert.are.equal(1, object.snapshots)
        end
    )
end)
