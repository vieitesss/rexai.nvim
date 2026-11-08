-- What the Dashboard derives from an accepted snapshot: the model Sessions,
-- the Home label, the directory of every row and the context the keys act on.
-- The hooks object and the git cache are stubs, so the test sees exactly what
-- the Dashboard asks them.

local data = require('rexai.ui.data')
local model = require('rexai.core.model')
local snap = require('tests.snapshots')

-- Two Agent blocks in one Session: one in a work tree, one with no directory
-- of its own.
local SNAPSHOT = snap.snapshot({
    snap.session({
        id = 'session:orbit',
        label = 'orbit',
        windows = {
            snap.window({
                id = 'window:api',
                label = 'api',
                blocks = {
                    snap.block({
                        id = 'block:b1',
                        app = 'pi',
                        state = 'done',
                        title = 'the docs',
                        cwd = '/work/orbit',
                    }),
                    snap.block({
                        id = 'block:b2',
                        app = 'claude-code',
                        state = 'working',
                        title = 'the parser',
                    }),
                },
            }),
        },
    }),
})

-- The same two Blocks, after the agent of `block:b1` ended.
local ENDED = snap.snapshot({
    snap.session({
        id = 'session:orbit',
        label = 'orbit',
        windows = {
            snap.window({
                id = 'window:api',
                label = 'api',
                blocks = {
                    snap.block({
                        id = 'block:b1',
                        argv0 = '/bin/zsh',
                        title = 'the docs',
                        last_exit = { exit_code = 3 },
                    }),
                    snap.block({
                        id = 'block:b2',
                        app = 'claude-code',
                        state = 'working',
                        title = 'the parser',
                    }),
                },
            }),
        },
    }),
})

-- The same two Agent blocks and, after them, a Session with no Agent blocks:
-- the model drops it, while Rex still reports it.
local QUIET = snap.snapshot({
    SNAPSHOT.sessions[1],
    snap.session({ id = 'session:quiet', label = 'quiet', windows = {} }),
})

---@param resolve fun(row: rexai.Row): string|nil
---@return table a hooks object that records every row it is asked about
local function stub_hooks(resolve)
    local object = { asked = {} }

    function object.resolve(_, row)
        object.asked[#object.asked + 1] = row.block_id
        return resolve(row)
    end

    function object.review()
        error('data must not call review')
    end

    return object
end

---@param info table<string, rexai.GitInfo|false>
---@return table a git cache stub that records every path it is asked about
local function stub_git(info)
    local object = { asked = {} }

    function object.get(_, path)
        object.asked[#object.asked + 1] = path
        return info[path] or nil
    end

    return object
end

-- The `resolve_path` of the tests: `block:b1` stands for a directory of its
-- own, and `block:b2` for none.
---@param row rexai.Row
---@return string|nil
local function resolve(row)
    if row.block_id == 'block:b1' then
        return '/work/vendored'
    end
end

describe('ui.data', function()
    local hooks, git

    before_each(function()
        hooks = stub_hooks(resolve)
        git = stub_git({})
    end)

    ---@param memory rexai.Memory|nil
    ---@return rexai.Data
    local function object(memory)
        return data.new({ hooks = hooks, git = git, memory = memory })
    end

    describe('accept', function()
        it('builds the model Sessions of the snapshot', function()
            local d = object()
            d:accept(SNAPSHOT, 'session:orbit')

            local sessions = assert(d:sessions())
            assert.are.equal(1, #sessions)
            assert.are.equal('session:orbit', sessions[1].id)
            assert.are.equal('orbit', sessions[1].label)
            assert.are.same({ 'block:b1', 'block:b2' }, {
                sessions[1].rows[1].block_id,
                sessions[1].rows[2].block_id,
            })
        end)

        it('captures what Rex calls the Home session', function()
            local d = object()
            d:accept(SNAPSHOT, 'session:orbit')
            assert.are.equal('orbit', d:home_label())

            -- The model drops a Session with no Agent blocks, so a Home
            -- session outside the snapshot has no label to capture.
            d:accept(SNAPSHOT, 'session:elsewhere')
            assert.is_nil(d:home_label())
        end)

        it('keeps a Session Rex could not read, with its error', function()
            local lost = snap.snapshot({
                snap.session({
                    id = 'session:lost',
                    label = 'lost',
                    error = 'rex timed out',
                }),
            })
            local d = object()
            d:accept(lost, 'session:lost')

            local sessions = assert(d:sessions())
            assert.are.equal(1, #sessions)
            assert.are.equal('rex timed out', sessions[1].error)
            assert.are.same({}, sessions[1].rows)
            assert.are.equal('lost', d:home_label())
        end)

        it('asks the path hook once per row of the snapshot', function()
            local d = object()
            d:accept(SNAPSHOT, nil)
            assert.are.same({ 'block:b1', 'block:b2' }, hooks.asked)

            d:accept(SNAPSHOT, nil)
            assert.are.same(
                { 'block:b1', 'block:b2', 'block:b1', 'block:b2' },
                hooks.asked
            )
        end)

        it(
            'captures the Home label of a Session with no Agent blocks',
            function()
                local d = object()
                d:accept(QUIET, 'session:quiet')

                -- The model keeps only the Session with Agent rows, so the label
                -- comes from the Session catalog.
                local sessions = assert(d:sessions())
                assert.are.equal(1, #sessions)
                assert.are.equal('orbit', sessions[1].label)
                assert.are.equal('quiet', d:home_label())
            end
        )

        it('forgets the snapshot on clear', function()
            local d = object()
            d:accept(SNAPSHOT, 'session:orbit')
            d:clear()

            assert.is_nil(d:sessions())
            assert.is_nil(d:home_label())
            assert.is_nil(d:context('block:b1'))
        end)
    end)

    describe('session_named', function()
        it('finds a Session with no Agent blocks', function()
            local d = object()
            d:accept(QUIET, nil)

            local found = assert(d:session_named('quiet'))
            assert.are.equal('session:quiet', found.id)
            assert.are.equal('quiet', found.label)
        end)

        it('finds nothing for a label the snapshot does not hold', function()
            local d = object()
            d:accept(QUIET, nil)

            assert.is_nil(d:session_named('elsewhere'))
        end)

        it('gives the first of two Sessions with one label', function()
            local twins = snap.snapshot({
                snap.session({ id = 'session:one', label = 'twin' }),
                snap.session({ id = 'session:two', label = 'twin' }),
            })
            local d = object()
            d:accept(twins, nil)

            assert.are.equal('session:one', assert(d:session_named('twin')).id)
        end)

        it('forgets a renamed Session when a snapshot replaces it', function()
            local renamed = snap.snapshot({
                SNAPSHOT.sessions[1],
                snap.session({
                    id = 'session:quiet',
                    label = 'renamed',
                    windows = {},
                }),
            })
            local d = object()
            d:accept(QUIET, nil)
            d:accept(renamed, nil)

            assert.is_nil(d:session_named('quiet'))
            local found = assert(d:session_named('renamed'))
            assert.are.equal('session:quiet', found.id)
        end)

        it('forgets every Session on clear', function()
            local d = object()
            d:accept(QUIET, nil)
            d:clear()

            assert.is_nil(d:session_named('quiet'))
            assert.is_nil(d:session_named('orbit'))
        end)
    end)

    describe('context', function()
        it('gives the row, its Session, its path and its git info', function()
            git = stub_git({
                ['/work/vendored'] = {
                    root = '/work',
                    branch = 'main',
                    detached = false,
                    ahead = 0,
                    behind = 0,
                    changed = 0,
                },
            })
            local d = object()
            d:accept(SNAPSHOT, nil)

            local ctx = assert(d:context('block:b1'))
            assert.are.equal('block:b1', ctx.row.block_id)
            assert.are.equal('session:orbit', ctx.session.id)
            assert.are.equal('/work/vendored', ctx.path)
            assert.are.equal('/work', ctx.git.root)
            assert.are.equal('main', ctx.git.branch)
            assert.are.same({ '/work/vendored' }, git.asked)
        end)

        it(
            'gives no path and asks git nothing for a row without one',
            function()
                local d = object()
                d:accept(SNAPSHOT, nil)

                local ctx = assert(d:context('block:b2'))
                assert.is_nil(ctx.path)
                assert.is_nil(ctx.git)
                assert.are.same({}, git.asked)
            end
        )

        it('gives nil for a Block the snapshot does not list', function()
            local d = object()
            d:accept(SNAPSHOT, nil)

            assert.is_nil(d:context('block:gone'))
        end)

        it('reads git when asked, so a late answer is seen', function()
            local info = {}
            git = stub_git(info)
            local d = object()
            d:accept(SNAPSHOT, nil)
            assert.is_nil(assert(d:context('block:b1')).git)

            info['/work/vendored'] = { root = '/work', branch = 'main' }

            local ctx = assert(d:context('block:b1'))
            assert.are.equal('main', ctx.git.branch)
        end)

        it('keeps the path of a row the `x` toggle hides', function()
            local d = object()
            d:accept(SNAPSHOT, nil)
            d:accept(ENDED, nil)

            local ctx = assert(d:context('block:b1'))
            assert.are.equal('exited', ctx.row.status)
            assert.are.equal('/work/vendored', ctx.path)
        end)
    end)

    describe('memory', function()
        it('shows an Exited row through two data objects', function()
            local memory = model.new_memory()
            object(memory):accept(SNAPSHOT, nil)

            local reopened = object(memory)
            reopened:accept(ENDED, nil)

            local ctx = assert(reopened:context('block:b1'))
            assert.are.equal('exited', ctx.row.status)
            assert.are.equal('done', ctx.row.last_status)
            assert.are.equal(3, ctx.row.exit_code)
            -- The Exited row got a path too, though the hook cannot read one
            -- from a Block of its own any more.
            assert.are.equal('/work/vendored', ctx.path)
        end)

        it('leaves the Exited row out with a memory of its own', function()
            object():accept(SNAPSHOT, nil)

            local fresh = object(model.new_memory())
            fresh:accept(ENDED, nil)

            assert.is_nil(fresh:context('block:b1'))
        end)
    end)
end)
