-- What the Dashboard keys act on when Rex replaces a Block, Window or Session
-- with one of another id but the same text: the buffer needs no write, while
-- the targets must be the new ids. The fake Backend serves invented snapshots
-- and the test fires the poller's timer by hand.

local dashboard = require('rexai.ui.dashboard')
local fake = require('rexai.backend.fake')
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

    function timer.fire()
        local entry = table.remove(timer.pending, 1)
        assert.is_not_nil(entry, 'nothing is scheduled')
        entry.callback()
    end

    return timer
end

-- One Session, one Window and one Agent block. Only the ids change between
-- snapshots, so the render keeps the same lines and highlights.
---@param ids table `session`, `window` and `block` ids
---@return table
local function snapshot(ids)
    return snap.snapshot({
        snap.session({
            id = ids.session,
            label = 'orbit',
            windows = {
                snap.window({
                    id = ids.window,
                    label = 'api',
                    blocks = {
                        snap.block({
                            id = ids.block,
                            app = 'pi',
                            state = 'done',
                            title = 'the docs',
                            updated_at = '2026-11-07T16:14:00Z',
                        }),
                    },
                }),
            },
        }),
    })
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

---@param calls table[]
---@return table|nil the last `focus` argument
local function last_focus(calls)
    for index = #calls, 1, -1 do
        if calls[index].method == 'focus' then
            return calls[index].arg
        end
    end
end

describe('ui.dashboard identity', function()
    local timer
    local scratch

    before_each(function()
        scratch = vim.api.nvim_create_buf(true, false)
        timer = fake_timer()
        vim.env.REX_SESSION = nil
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
    end)

    -- Opens the Dashboard on `first`, then refreshes into `second`. The second
    -- snapshot renders the same text, so the test can check that the targets
    -- moved anyway.
    ---@param first table
    ---@param second table
    ---@return integer win
    ---@return table[] calls
    ---@return fun(): integer buffer line changes seen
    local function open_pair(first, second)
        local backend, calls = fake.new({ snapshots = { first, second } })
        vim.api.nvim_win_set_buf(0, scratch)
        dashboard.open({
            backend = backend,
            after = timer.after,
            now = function()
                return NOW
            end,
        })
        local win = vim.api.nvim_get_current_win()

        local changes = 0
        vim.api.nvim_buf_attach(assert(dashboard_buf()), false, {
            on_lines = function()
                changes = changes + 1
            end,
        })
        local before = vim.api.nvim_buf_get_lines(dashboard_buf(), 0, -1, false)

        timer.fire()

        assert.are.equal(2, #before)
        assert.are.same(
            before,
            vim.api.nvim_buf_get_lines(assert(dashboard_buf()), 0, -1, false)
        )
        return win, calls, function()
            return changes
        end
    end

    local LIVE = {
        session = 'session:i1',
        window = 'window:j1',
        block = 'block:k1',
    }

    ---@param field string one of `session`, `window`, `block`
    ---@param id string
    ---@return table
    local function replaced(field, id)
        local ids = vim.deepcopy(LIVE)
        ids[field] = id
        return ids
    end

    it('acts on a replaced Block id without writing the buffer', function()
        local win, calls, changes =
            open_pair(snapshot(LIVE), snapshot(replaced('block', 'block:k2')))
        vim.api.nvim_win_set_cursor(win, { 2, 0 })

        local target = assert(dashboard.current_target(win))
        assert.are.equal('block:k2', target.block_id)
        assert.are.equal('window:j1', target.window_id)
        assert.are.equal('session:i1', target.session_id)

        press('<CR>')

        assert.are.same({
            session_id = 'session:i1',
            window_id = 'window:j1',
            block_id = 'block:k2',
        }, last_focus(calls))
        assert.are.equal(0, changes())
    end)

    it('acts on a replaced Window id without writing the buffer', function()
        local win, calls, changes =
            open_pair(snapshot(LIVE), snapshot(replaced('window', 'window:j2')))
        vim.api.nvim_win_set_cursor(win, { 2, 0 })

        local target = assert(dashboard.current_target(win))
        assert.are.equal('block:k1', target.block_id)
        assert.are.equal('window:j2', target.window_id)

        press('<CR>')

        assert.are.same({
            session_id = 'session:i1',
            window_id = 'window:j2',
            block_id = 'block:k1',
        }, last_focus(calls))
        assert.are.equal(0, changes())
    end)

    it('acts on a replaced Session id without writing the buffer', function()
        local win, calls, changes = open_pair(
            snapshot(LIVE),
            snapshot(replaced('session', 'session:i2'))
        )

        -- The Session header and the row both point at the new Session.
        assert.are.equal('session:i2', dashboard.current_target(win).session_id)
        vim.api.nvim_win_set_cursor(win, { 2, 0 })
        local target = assert(dashboard.current_target(win))
        assert.are.equal('session:i2', target.session_id)
        assert.are.equal('window:j1', target.window_id)
        assert.are.equal('block:k1', target.block_id)

        press('<CR>')

        assert.are.same({
            session_id = 'session:i2',
            window_id = 'window:j1',
            block_id = 'block:k1',
        }, last_focus(calls))
        assert.are.equal(0, changes())
    end)
end)
