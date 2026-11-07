-- The git slot of a Dashboard row. The fake Backend serves the snapshots and
-- the git runner and clock are seams, so every git call here is answered by
-- the test.

local config = require('rexai.config')
local dashboard = require('rexai.ui.dashboard')
local fake = require('rexai.backend.fake')
local model = require('rexai.core.model')
local render = require('rexai.ui.render')
local snap = require('tests.snapshots')

local NAME = 'rexai://dashboard'
-- 2026-11-07T16:15:00Z, so the ages never move.
local NOW = 1794068100
-- Not the Session this Neovim runs in, so no Home header shows up by itself.
local HOME = 'session:home'
-- The status git prints for a clean branch, and for one with three changes.
local CLEAN = table.concat({
    '# branch.oid 1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b',
    '# branch.head main',
    '# branch.upstream origin/main',
    '# branch.ab +0 -0',
}, '\n')
local DIRTY = CLEAN
    .. table.concat({
        '\n? notes.md',
        '\n? todo.md',
        '\n1 .M N... 100644 100644 100644 old new src/parser.lua',
    }, '')

-- The default timer seam: the test fires what the poller scheduled.
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

-- The git runner seam: the test answers every call, in order.
local function runner()
    local r = { queue = {}, calls = {} }

    function r.run(argv, callback)
        r.queue[#r.queue + 1] = { argv = argv, callback = callback }
        r.calls[#r.calls + 1] = argv
    end

    ---@return table the oldest call the test has not answered
    function r.next()
        local call = table.remove(r.queue, 1)
        assert.is_not_nil(call, 'no git call is waiting')
        return call
    end

    -- Answers the status call, then the work tree root call.
    ---@param status string|nil
    ---@param root string|nil
    function r.answer(status, root)
        r.next().callback(nil, status or CLEAN)
        r.next().callback(nil, root or '/work/orbit\n')
    end

    ---@return integer how many status calls git ran
    function r.status_calls()
        local count = 0
        for _, argv in ipairs(r.calls) do
            if argv[5] == 'status' then
                count = count + 1
            end
        end
        return count
    end

    return r
end

---@return table a clock the test moves by hand, in milliseconds
local function fake_clock()
    local clock = { ms = 1000 }
    function clock.now()
        return clock.ms
    end
    function clock.advance(ms)
        clock.ms = clock.ms + ms
    end
    return clock
end

-- Lets every callback `vim.schedule` queued run.
local function flush()
    local done = false
    vim.schedule(function()
        done = true
    end)
    assert.is_true(vim.wait(500, function()
        return done
    end, 1))
end

---@param spec table
---@return table a snapshot with one Session and one Window
local function snapshot_of(spec)
    local blocks = {}
    for index, block in ipairs(spec.blocks) do
        blocks[index] = snap.block(block)
    end
    return snap.snapshot({
        snap.session({
            id = 'session:s1',
            label = 'orbit',
            windows = {
                snap.window({
                    id = 'window:w1',
                    label = 'api',
                    blocks = blocks,
                }),
            },
        }),
    })
end

-- One Agent block in a git work tree, one that has no directory at all.
local SNAPSHOT = snapshot_of({
    blocks = {
        {
            id = 'block:b1',
            app = 'pi',
            state = 'done',
            title = 'the docs',
            cwd = '/work/orbit',
            updated_at = '2026-11-07T16:12:00Z',
        },
        {
            id = 'block:b2',
            app = 'claude-code',
            state = 'working',
            title = 'the parser',
            updated_at = '2026-11-07T15:15:00Z',
        },
    },
})

---@return integer|nil
local function dashboard_buf()
    local buf = vim.fn.bufnr(NAME)
    if buf == -1 then
        return nil
    end
    return buf
end

---@return string[] the Dashboard lines
local function dashboard_lines()
    return vim.api.nvim_buf_get_lines(dashboard_buf(), 0, -1, false)
end

---@param needle string
---@return string|nil the Dashboard line holding it
local function line_with(needle)
    for _, line in ipairs(dashboard_lines()) do
        if line:find(needle, 1, true) then
            return line
        end
    end
    return nil
end

describe('ui.dashboard git slot', function()
    local timer, scratch, r, clock

    before_each(function()
        config.setup({ git_refresh_ms = 5000 })
        scratch = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_win_set_buf(0, scratch)
        timer, r, clock = fake_timer(), runner(), fake_clock()
        vim.env.REX_SESSION = nil
    end)

    after_each(function()
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

    ---@param snapshot table
    ---@return table the Backend
    local function open_with(snapshot)
        local backend = fake.new({ snapshots = { snapshot } })
        dashboard.open({
            backend = backend,
            after = timer.after,
            now = function()
                return NOW
            end,
            home_session_id = HOME,
            git = { run = r.run, clock = clock.now },
        })
        return backend
    end

    it('shows the slot once git answers, not before', function()
        -- What the Dashboard shows with no git slot at all: the column is
        -- dropped, so the row has no gap where the slot would go.
        local without_git = render.build(
            model.build(SNAPSHOT, config.get().agents),
            { now = NOW, home_session_id = HOME }
        )

        open_with(SNAPSHOT)

        assert.are.same(without_git.lines, dashboard_lines())
        local before = assert(line_with('the docs'))
        assert.is_nil(before:find('orbit · main', 1, true))
        assert.is_nil(before:find('orbit', 1, true))

        r.answer()
        flush()

        local after = assert(line_with('the docs'))
        assert.is_truthy(after:find('orbit · main', 1, true))
        -- The row without a directory gets no slot and no git call.
        local plain = assert(line_with('the parser'))
        assert.is_nil(plain:find('orbit', 1, true))
        assert.are.equal(1, r.status_calls())
    end)

    it('updates the slot when a later result changes the counts', function()
        open_with(SNAPSHOT)
        r.answer()
        flush()
        local before = assert(line_with('the docs'))
        assert.is_truthy(before:find('orbit · main', 1, true))

        clock.advance(5000)
        timer.fire()
        r.answer(DIRTY)
        flush()

        local after = assert(line_with('the docs'))
        assert.are_not.equal(before, after)
        assert.is_truthy(after:find('orbit · main ●3', 1, true))
    end)

    it('asks git once per path inside git_refresh_ms', function()
        open_with(SNAPSHOT)
        r.answer()
        flush()
        assert.are.equal(1, r.status_calls())

        timer.fire()
        timer.fire()
        flush()

        assert.are.equal(1, r.status_calls())
        assert.are.equal(2, #r.calls)
    end)

    it('shows no slot for a path that is not a work tree', function()
        open_with(snapshot_of({
            blocks = {
                {
                    id = 'block:b1',
                    app = 'pi',
                    state = 'done',
                    title = 'the docs',
                    cwd = '/work/plain',
                },
            },
        }))

        r.next().callback('git exited with code 128')
        flush()

        local line = assert(line_with('the docs'))
        assert.is_nil(line:find('orbit', 1, true))
        assert.is_nil(line:find('●', 1, true))

        timer.fire()
        timer.fire()
        assert.are.equal(1, r.status_calls())
    end)

    it('stops git when the buffer is wiped', function()
        open_with(SNAPSHOT)
        local buf = assert(dashboard_buf())
        local late = r.next()

        vim.api.nvim_buf_delete(buf, { force = true })

        assert.has_no.errors(function()
            late.callback(nil, CLEAN)
        end)
        flush()

        assert.is_nil(dashboard_buf())
        -- The late status started no root call and drew nothing.
        assert.are.equal(1, #r.calls)
    end)
end)
