-- What the Dashboard keys act on when Rex replaces a Block, Window or Session
-- with one of another id but the same text: the buffer needs no write, while
-- the targets must be the new ids. The fake Backend serves invented snapshots
-- and the test fires the poller's timer by hand.

local dashboard = require('rexai.ui.dashboard')
local snap = require('tests.snapshots')
local support = require('tests.ui_support')

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

describe('ui.dashboard identity', function()
    local h

    before_each(function()
        h = support.new()
    end)

    after_each(function()
        h:close()
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
        local _, calls = h:open({ snapshots = { first, second } })
        local win = vim.api.nvim_get_current_win()

        local changes = 0
        vim.api.nvim_buf_attach(assert(h:buf()), false, {
            on_lines = function()
                changes = changes + 1
            end,
        })
        local before = h:lines()

        h.timer.fire()

        assert.are.equal(3, #before)
        assert.are.same(before, h:lines())
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

        h:press('<CR>')

        assert.are.same({
            session_id = 'session:i1',
            window_id = 'window:j1',
            block_id = 'block:k2',
        }, support.last_focus(calls))
        assert.are.equal(0, changes())
    end)

    it('acts on a replaced Window id without writing the buffer', function()
        local win, calls, changes =
            open_pair(snapshot(LIVE), snapshot(replaced('window', 'window:j2')))
        vim.api.nvim_win_set_cursor(win, { 2, 0 })

        local target = assert(dashboard.current_target(win))
        assert.are.equal('block:k1', target.block_id)
        assert.are.equal('window:j2', target.window_id)

        h:press('<CR>')

        assert.are.same({
            session_id = 'session:i1',
            window_id = 'window:j2',
            block_id = 'block:k1',
        }, support.last_focus(calls))
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

        h:press('<CR>')

        assert.are.same({
            session_id = 'session:i2',
            window_id = 'window:j1',
            block_id = 'block:k1',
        }, support.last_focus(calls))
        assert.are.equal(0, changes())
    end)
end)
