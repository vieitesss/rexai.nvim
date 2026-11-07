-- The git slot of a Dashboard row. The fake Backend serves the snapshots and
-- the git runner and clock are seams, so every git call here is answered by
-- the test.

local config = require('rexai.config')
local model = require('rexai.core.model')
local render = require('rexai.ui.render')
local snap = require('tests.snapshots')
local support = require('tests.ui_support')

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
-- What `git rev-parse --show-toplevel` prints for the row in a work tree.
local ROOT = '/work/orbit\n'

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

describe('ui.dashboard git slot', function()
    local h

    before_each(function()
        config.setup({ git_refresh_ms = 5000 })
        h = support.new()
    end)

    after_each(function()
        h:close()
    end)

    ---@param needle string
    ---@return string|nil the Dashboard line holding it
    local function line_with(needle)
        for _, line in ipairs(h:lines()) do
            if line:find(needle, 1, true) then
                return line
            end
        end
        return nil
    end

    ---@return integer how many status calls git ran
    local function status_calls()
        local total = 0
        for _, argv in ipairs(h.git.calls) do
            if argv[5] == 'status' then
                total = total + 1
            end
        end
        return total
    end

    ---@param snapshot table
    ---@return table the Backend
    local function open_with(snapshot)
        local backend = h:open({
            snapshots = { snapshot },
            home_session_id = HOME,
        })
        return backend
    end

    it('shows the slot once git answers, not before', function()
        -- What the Dashboard shows with no git slot at all: the column is
        -- dropped, so the row has no gap where the slot would go.
        local without_git = render.build(
            model.build(SNAPSHOT, config.get().agents),
            { now = support.NOW, home_session_id = HOME }
        )

        open_with(SNAPSHOT)

        assert.are.same(without_git.lines, h:lines())
        local before = assert(line_with('the docs'))
        assert.is_nil(before:find('orbit · main', 1, true))
        assert.is_nil(before:find('orbit', 1, true))

        h.git.answer(CLEAN, ROOT)
        support.flush()

        local after = assert(line_with('the docs'))
        assert.is_truthy(after:find('orbit · main', 1, true))
        -- The row without a directory gets no slot and no git call.
        local plain = assert(line_with('the parser'))
        assert.is_nil(plain:find('orbit', 1, true))
        assert.are.equal(1, status_calls())
    end)

    it('updates the slot when a later result changes the counts', function()
        open_with(SNAPSHOT)
        h.git.answer(CLEAN, ROOT)
        support.flush()
        local before = assert(line_with('the docs'))
        assert.is_truthy(before:find('orbit · main', 1, true))

        h.clock.advance(5000)
        h.timer.fire()
        h.git.answer(DIRTY, ROOT)
        support.flush()

        local after = assert(line_with('the docs'))
        assert.are_not.equal(before, after)
        assert.is_truthy(after:find('orbit · main ●3', 1, true))
    end)

    it('asks git once per path inside git_refresh_ms', function()
        open_with(SNAPSHOT)
        h.git.answer(CLEAN, ROOT)
        support.flush()
        assert.are.equal(1, status_calls())

        h.timer.fire()
        h.timer.fire()
        support.flush()

        assert.are.equal(1, status_calls())
        assert.are.equal(2, #h.git.calls)
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

        h.git.next().callback('git exited with code 128')
        support.flush()

        local line = assert(line_with('the docs'))
        assert.is_nil(line:find('orbit', 1, true))
        assert.is_nil(line:find('●', 1, true))

        h.timer.fire()
        h.timer.fire()
        assert.are.equal(1, status_calls())
    end)

    it('stops git when the buffer is wiped', function()
        open_with(SNAPSHOT)
        local buf = assert(h:buf())
        local late = h.git.next()

        vim.api.nvim_buf_delete(buf, { force = true })

        assert.has_no.errors(function()
            late.callback(nil, CLEAN)
        end)
        support.flush()

        assert.is_nil(h:buf())
        -- The late status started no root call and drew nothing.
        assert.are.equal(1, #h.git.calls)
    end)
end)
