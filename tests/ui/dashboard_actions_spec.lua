-- The lifetime of the Dashboard actions: a result acts only on the Dashboard,
-- and the Backend, that issued the request. The Backend here answers
-- `snapshot` at once and keeps every `focus` until the test answers it, so the
-- test decides when a result arrives and which Dashboard is open then.
-- Snapshots are invented.

local dashboard = require('rexai.ui.dashboard')
local snap = require('tests.snapshots')
local support = require('tests.ui_support')

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

describe('ui.dashboard actions lifetime', function()
    local h

    before_each(function()
        h = support.new()
    end)

    after_each(function()
        h:close()
    end)

    -- Puts the cursor on the Agent row of the Dashboard.
    local function put_cursor_on_row()
        local win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_cursor(win, { 2, 0 })
        assert.are.equal('row', dashboard.current_target(win).kind)
    end

    -- Wipes the Dashboard buffer, as `:bwipeout` would: the buffer leaves the
    -- window and every autocmd of the Dashboard fires.
    local function wipe()
        local buf = h:buf()
        assert.is_not_nil(buf)
        for _, win in ipairs(vim.fn.win_findbuf(buf)) do
            if vim.api.nvim_win_is_valid(win) then
                vim.api.nvim_win_set_buf(win, h.scratch)
            end
        end
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
        assert.is_nil(h:buf())
    end

    it('drops a result that arrives after the Dashboard was wiped', function()
        local first = backend()
        h:open({ backend = first })
        put_cursor_on_row()
        h:press('<CR>')
        assert.are.equal(1, #first.targets)

        wipe()
        local second = backend()
        h:open({ backend = second })
        assert.are.equal(1, second.snapshots)

        -- The failure of the wiped Dashboard answers now, while the
        -- replacement Dashboard has a window and its own Backend.
        first.answer('target not found')

        assert.are.same({}, h.notify.calls)
        assert.are.equal(1, second.snapshots)
    end)

    it(
        'drops a result when another Backend replaced the one that issued it',
        function()
            local first = backend()
            h:open({ backend = first })
            put_cursor_on_row()
            h:press('<CR>')

            -- A second `:Rexai` with its own Backend replaces the poller, the
            -- Backend and the actions while the same buffer stays.
            local second = backend()
            h:open({ backend = second })
            assert.are.equal(1, second.snapshots)

            first.answer('target not found')

            assert.are.same({}, h.notify.calls)
            assert.are.equal(1, second.snapshots)
        end
    )

    it(
        'warns and refreshes when the failure belongs to this Dashboard',
        function()
            local object = backend()
            h:open({ backend = object })
            put_cursor_on_row()
            h:press('<CR>')
            assert.are.equal(1, object.snapshots)

            object.answer('target not found')

            assert.are.equal(1, #h.notify.calls)
            assert.are.equal(
                'rexai: target not found',
                h.notify.calls[1].message
            )
            assert.are.equal(vim.log.levels.WARN, h.notify.calls[1].level)
            -- The target has probably vanished, so the Dashboard asks Rex again at
            -- once.
            assert.are.equal(2, object.snapshots)
        end
    )

    it('does nothing when a deferred success arrives', function()
        local object = backend()
        h:open({ backend = object })
        put_cursor_on_row()
        h:press('<CR>')

        object.answer(nil)

        assert.are.same({}, h.notify.calls)
        assert.are.equal(1, object.snapshots)
    end)

    it(
        'still counts a result that arrives while it is merely hidden',
        function()
            local object = backend()
            h:open({ backend = object })
            put_cursor_on_row()
            h:press('<CR>')

            -- The window leaves the Dashboard: the poller stops, nothing is
            -- wiped, so the Dashboard is paused, not gone.
            vim.api.nvim_win_set_buf(0, h.scratch)
            object.answer('target not found')

            assert.are.equal(1, #h.notify.calls)
            assert.are.equal(
                'rexai: target not found',
                h.notify.calls[1].message
            )
            -- No window shows the buffer, so the refresh asks Rex nothing.
            assert.are.equal(1, object.snapshots)
        end
    )
end)
