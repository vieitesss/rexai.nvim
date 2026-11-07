-- The Dashboard actions on the target under the cursor: `<CR>` goes to it and
-- `d` hands the row to the `review` hook. The Backend holds every `focus`
-- until the test answers it, and the effects of the Dashboard (`refresh` and
-- the target reader) are stubs, so the test sees exactly what the actions ask
-- for. The data object is the real one, fed with an invented snapshot.

local actions = require('rexai.ui.actions')
local config = require('rexai.config')
local data_mod = require('rexai.ui.data')
local hooks_mod = require('rexai.hooks')
local snap = require('tests.snapshots')

-- What the Dashboard reader gives for the cursor: the header of the Session,
-- the row of a Block in a work tree, the row of a Block with no directory, or
-- nothing on a blank line.
local HEADER = { kind = 'session', session_id = 'session:s1' }
local ROW_IN_TREE = {
    kind = 'row',
    session_id = 'session:s1',
    window_id = 'window:w1',
    block_id = 'block:b1',
}
local ROW_BARE = {
    kind = 'row',
    session_id = 'session:s1',
    window_id = 'window:w1',
    block_id = 'block:b2',
}

-- One Agent block in a work tree and one with no directory at all.
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
                    snap.block({
                        id = 'block:b2',
                        app = 'claude-code',
                        state = 'working',
                        title = 'the parser',
                        updated_at = '2026-11-07T16:10:00Z',
                    }),
                },
            }),
        },
    }),
})

-- The Row the model builds for `block:b1`.
local ROW = {
    session_id = 'session:s1',
    window_id = 'window:w1',
    block_id = 'block:b1',
    harness = 'pi',
    label = 'api pi',
    status = 'done',
    updated_at = '2026-11-07T16:12:00Z',
    title = 'the docs',
    cwd = '/work/orbit',
}

-- A Backend that holds every `focus` until the test answers it.
---@return table
local function stub_backend()
    local object = { targets = {}, pending = {} }

    function object.focus(target, callback)
        object.targets[#object.targets + 1] = target
        object.pending[#object.pending + 1] = callback
    end

    function object.snapshot(callback)
        callback(nil, SNAPSHOT)
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

-- A git cache that knows one directory.
---@param info table<string, rexai.GitInfo>
---@return table
local function stub_git(info)
    local object = {}

    function object.get(_, path)
        return info[path]
    end

    return object
end

describe('ui.actions', function()
    local told, real_notify, backend, refreshed, target, object

    before_each(function()
        config.setup()
        told = { calls = {} }
        function told.notify(message, level)
            told.calls[#told.calls + 1] = {
                message = message,
                level = level,
            }
        end
        -- The actions report through `vim.notify`; the hooks object gets the
        -- same recorder as its test seam. One list, so the order the user sees
        -- the messages in is the order the test reads.
        real_notify = vim.notify
        vim.notify = told.notify
        backend = stub_backend()
        refreshed = 0
        target = nil

        local hooks = hooks_mod.new({ notify = told.notify })
        local git = stub_git({
            ['/work/orbit'] = { root = '/work/orbit', branch = 'main' },
        })
        local data = data_mod.new({ hooks = hooks, git = git })
        data:accept(SNAPSHOT, nil)

        object = actions.new({
            backend = backend,
            data = data,
            hooks = hooks,
            refresh = function()
                refreshed = refreshed + 1
            end,
            current_target = function()
                return target
            end,
        })
    end)

    after_each(function()
        vim.notify = real_notify
        config.setup()
    end)

    describe('focus', function()
        it('asks Rex for the whole target of a row', function()
            target = ROW_IN_TREE

            object:focus()

            assert.are.same({
                {
                    session_id = 'session:s1',
                    window_id = 'window:w1',
                    block_id = 'block:b1',
                },
            }, backend.targets)
        end)

        it('asks Rex for the Session of a header with its id only', function()
            target = HEADER

            object:focus()

            assert.are.same({ { session_id = 'session:s1' } }, backend.targets)
        end)

        it('does nothing on a line with no target', function()
            object:focus()

            assert.are.same({}, backend.targets)
            assert.are.same({}, told.calls)
            assert.are.equal(0, refreshed)
        end)

        it('warns and refreshes once when Rex cannot focus', function()
            target = ROW_IN_TREE
            object:focus()

            backend.answer('target not found')

            assert.are.equal(1, #told.calls)
            assert.are.equal('rexai: target not found', told.calls[1].message)
            assert.are.equal(vim.log.levels.WARN, told.calls[1].level)
            assert.are.equal(1, refreshed)
        end)

        it('says nothing when the focus works', function()
            target = ROW_IN_TREE
            object:focus()

            backend.answer(nil)

            assert.are.same({}, told.calls)
            assert.are.equal(0, refreshed)
        end)

        it('drops a result that arrives after dispose', function()
            target = ROW_IN_TREE
            object:focus()
            object:dispose()

            backend.answer('target not found')

            assert.are.same({}, told.calls)
            assert.are.equal(0, refreshed)
        end)

        it('makes no call once disposed', function()
            target = ROW_IN_TREE
            object:dispose()

            object:focus()

            assert.are.same({}, backend.targets)
        end)
    end)

    describe('review', function()
        it('reports a line with no Agent block and calls nothing', function()
            config.setup({
                review = function()
                    error('review must not run')
                end,
            })

            object:review()

            assert.are.equal(1, #told.calls)
            assert.are.equal(
                'rexai: put the cursor on an Agent block',
                told.calls[1].message
            )
            assert.are.equal(vim.log.levels.INFO, told.calls[1].level)
        end)

        it('reports a row without a directory and calls nothing', function()
            config.setup({
                review = function()
                    error('review must not run')
                end,
            })
            target = ROW_BARE

            object:review()

            assert.are.equal(1, #told.calls)
            assert.are.equal(
                'rexai: this Block has no directory to review',
                told.calls[1].message
            )
            assert.are.equal(vim.log.levels.INFO, told.calls[1].level)
        end)

        it('reports a row whose review function is not set', function()
            target = ROW_IN_TREE

            object:review()

            assert.are.equal(1, #told.calls)
            assert.are.equal(
                'rexai: no review function is set; add review = '
                    .. 'function(ctx) ... end to setup()',
                told.calls[1].message
            )
            assert.are.equal(vim.log.levels.INFO, told.calls[1].level)
        end)

        it('gives review the row, the path and what git knows', function()
            local got = {}
            config.setup({
                review = function(ctx)
                    got[#got + 1] = ctx
                end,
            })
            target = ROW_IN_TREE

            object:review()

            assert.are.same({
                {
                    path = '/work/orbit',
                    repo_root = '/work/orbit',
                    branch = 'main',
                    session = { id = 'session:s1', label = 'orbit' },
                    window = { id = 'window:w1' },
                    block = ROW,
                },
            }, got)
            assert.are.same({}, told.calls)
        end)

        it('keeps working when the review function throws', function()
            local ran = 0
            config.setup({
                review = function()
                    ran = ran + 1
                    error('boom', 0)
                end,
            })
            target = ROW_IN_TREE

            object:review()
            object:review()

            assert.are.equal(2, ran)
            assert.are.equal(2, #told.calls)
            assert.are.equal(
                'rexai: review failed: boom',
                told.calls[1].message
            )
            assert.are.equal(vim.log.levels.WARN, told.calls[1].level)
        end)

        it('does nothing once disposed', function()
            local ran = 0
            config.setup({
                review = function()
                    ran = ran + 1
                end,
            })
            target = ROW_IN_TREE
            object:dispose()

            object:review()

            assert.are.equal(0, ran)
            assert.are.same({}, told.calls)
        end)
    end)
end)
