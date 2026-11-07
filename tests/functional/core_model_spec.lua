local helpers = require('tests.helpers')
local model = require('rexai.core.model')
local snap = require('tests.snapshots')

local agents = {
    apps = { 'claude-code', 'pi' },
    commands = { 'claude', 'codex', 'opencode', 'pi' },
}

local function rows_of(sessions)
    local out = {}
    for _, session in ipairs(sessions) do
        for _, row in ipairs(session.rows) do
            out[#out + 1] = row
        end
    end
    return out
end

local function find(sessions, block_id)
    for _, row in ipairs(rows_of(sessions)) do
        if row.block_id == block_id then
            return row
        end
    end
end

describe('core.model', function()
    describe('new_memory', function()
        it('starts empty and is not shared', function()
            local first, second = model.new_memory(), model.new_memory()
            first.blocks['block:x'] = {}
            assert.is_nil(second.blocks['block:x'])
        end)
    end)

    describe('build', function()
        it('gives no sessions for an empty snapshot', function()
            assert.are.same({}, model.build(snap.snapshot({}), agents))
        end)

        it('builds a row from a reported status', function()
            local sessions = model.build(
                snap.single({
                    id = 'block:b1',
                    app = 'claude-code',
                    state = 'blocked',
                    kind = 'permission',
                    msg = 'run tests?',
                    title = 'fixing the parser',
                    cwd = '/work/app',
                    argv0 = '/bin/claude',
                }, 'Window 0a1b2c3d'),
                agents
            )

            assert.are.equal(1, #sessions)
            local session = sessions[1]
            assert.are.equal('session:s1', session.id)
            assert.are.equal('needs_input', session.status)

            local row = session.rows[1]
            assert.are.equal('session:s1', row.session_id)
            assert.are.equal('window:w1', row.window_id)
            assert.are.equal('block:b1', row.block_id)
            assert.are.equal('claude-code', row.harness)
            assert.are.equal('claude-code 2c3d', row.label)
            assert.are.equal('needs_input', row.status)
            assert.are.equal('permission', row.kind)
            assert.are.equal('run tests?', row.msg)
            assert.are.equal('fixing the parser', row.title)
            assert.are.equal('/work/app', row.cwd)
        end)

        it('shows a detected agent with no status as unreported', function()
            local sessions = model.build(
                snap.single({ id = 'block:b1', argv0 = '/bin/codex' }, 'work'),
                agents
            )
            local row = sessions[1].rows[1]
            assert.are.equal('unreported', row.status)
            assert.are.equal('codex', row.harness)
            assert.are.equal('work', row.label)
        end)

        it('leaves out blocks that are not agents', function()
            local sessions = model.build(
                snap.single({ id = 'block:b1', argv0 = '/usr/bin/nvim' }),
                agents
            )
            assert.are.same({}, sessions)
        end)

        it('leaves out a session with no agent blocks', function()
            local snapshot = snap.snapshot({
                snap.session({
                    id = 'session:plain',
                    windows = {
                        snap.window({
                            id = 'window:w1',
                            blocks = { snap.block({ id = 'block:b1' }) },
                        }),
                    },
                }),
                snap.session({
                    id = 'session:busy',
                    windows = {
                        snap.window({
                            id = 'window:w2',
                            blocks = {
                                snap.block({
                                    id = 'block:b2',
                                    app = 'pi',
                                    state = 'idle',
                                }),
                            },
                        }),
                    },
                }),
            })
            local sessions = model.build(snapshot, agents)
            assert.are.equal(1, #sessions)
            assert.are.equal('session:busy', sessions[1].id)
        end)

        it('keeps a session Rex could not read, with its error', function()
            local snapshot = snap.snapshot({
                snap.session({
                    id = 'session:bad',
                    label = 'broken',
                    error = 'session.attach failed',
                }),
            })
            local sessions = model.build(snapshot, agents)
            assert.are.equal(1, #sessions)
            assert.are.equal('session.attach failed', sessions[1].error)
            assert.are.same({}, sessions[1].rows)
            assert.is_nil(sessions[1].status)
        end)

        it('rolls the rows up to the highest status', function()
            local cases = {
                { { 'idle', 'working' }, 'working' },
                { { 'working', 'done' }, 'done' },
                { { 'done', 'error' }, 'error' },
                { { 'error', 'blocked' }, 'needs_input' },
                { { 'idle', 'idle' }, 'idle' },
            }
            for _, case in ipairs(cases) do
                local blocks = {}
                for index, state in ipairs(case[1]) do
                    blocks[index] = snap.block({
                        id = 'block:b' .. index,
                        app = 'pi',
                        state = state,
                    })
                end
                local snapshot = snap.snapshot({
                    snap.session({
                        id = 'session:s1',
                        windows = {
                            snap.window({
                                id = 'window:w1',
                                label = 'work',
                                blocks = blocks,
                            }),
                        },
                    }),
                })
                local sessions = model.build(snapshot, agents)
                assert.are.equal(case[2], sessions[1].status)
            end
        end)

        it('labels rows per window', function()
            local snapshot = snap.snapshot({
                snap.session({
                    id = 'session:s1',
                    windows = {
                        snap.window({
                            id = 'window:w1',
                            label = 'auth',
                            blocks = {
                                snap.block({
                                    id = 'block:b1',
                                    app = 'claude-code',
                                    state = 'idle',
                                }),
                                snap.block({
                                    id = 'block:b2',
                                    app = 'pi',
                                    state = 'idle',
                                }),
                            },
                        }),
                        snap.window({
                            id = 'window:w2',
                            label = 'docs',
                            blocks = {
                                snap.block({
                                    id = 'block:b3',
                                    app = 'pi',
                                    state = 'idle',
                                }),
                            },
                        }),
                    },
                }),
            })
            local sessions = model.build(snapshot, agents)
            assert.are.equal(
                'auth claude-code',
                find(sessions, 'block:b1').label
            )
            assert.are.equal('auth pi', find(sessions, 'block:b2').label)
            assert.are.equal('docs', find(sessions, 'block:b3').label)
        end)

        it('keeps the order Rex reports', function()
            local snapshot = snap.snapshot({
                snap.session({
                    id = 'session:b',
                    windows = {
                        snap.window({
                            id = 'window:1',
                            label = 'z',
                            blocks = {
                                snap.block({
                                    id = 'block:1',
                                    app = 'pi',
                                    state = 'done',
                                }),
                            },
                        }),
                    },
                }),
                snap.session({
                    id = 'session:a',
                    windows = {
                        snap.window({
                            id = 'window:2',
                            label = 'a',
                            blocks = {
                                snap.block({
                                    id = 'block:2',
                                    app = 'pi',
                                    state = 'idle',
                                }),
                            },
                        }),
                    },
                }),
            })
            local sessions = model.build(snapshot, agents)
            assert.are.equal('session:b', sessions[1].id)
            assert.are.equal('session:a', sessions[2].id)
        end)

        describe('exited', function()
            local function with(block)
                return snap.single(block, 'work')
            end

            it('shows a remembered agent that stopped being one', function()
                local memory = model.new_memory()
                model.build(
                    with({
                        id = 'block:b1',
                        app = 'claude-code',
                        state = 'working',
                        argv0 = '/bin/claude',
                        title = 'task',
                    }),
                    agents,
                    memory
                )

                local sessions = model.build(
                    with({ id = 'block:b1', argv0 = '/bin/zsh' }),
                    agents,
                    memory
                )
                local row = sessions[1].rows[1]
                assert.are.equal('exited', row.status)
                assert.are.equal('working', row.last_status)
                assert.are.equal('claude-code', row.harness)
                assert.are.equal('work', row.label)
                assert.are.equal('task', row.title)
                assert.are.equal('exited', sessions[1].status)
            end)

            it('carries the exit code when Rex reports one', function()
                local memory = model.new_memory()
                model.build(
                    with({ id = 'block:b1', app = 'pi', state = 'working' }),
                    agents,
                    memory
                )
                local sessions = model.build(
                    with({
                        id = 'block:b1',
                        last_exit = { exit_code = 130, error = 'interrupted' },
                    }),
                    agents,
                    memory
                )
                local row = sessions[1].rows[1]
                assert.are.equal(130, row.exit_code)
                assert.are.equal('interrupted', row.exit_error)
            end)

            it('has no exit code when Rex reports none', function()
                local memory = model.new_memory()
                model.build(
                    with({ id = 'block:b1', app = 'pi', state = 'idle' }),
                    agents,
                    memory
                )
                local sessions = model.build(
                    with({ id = 'block:b1', argv0 = '/bin/zsh' }),
                    agents,
                    memory
                )
                assert.is_nil(sessions[1].rows[1].exit_code)
            end)

            it('does not show a block that exited before the start', function()
                local sessions = model.build(
                    with({ id = 'block:b1', argv0 = '/bin/zsh' }),
                    agents,
                    model.new_memory()
                )
                assert.are.same({}, sessions)
            end)

            it('without a memory, never shows exited', function()
                model.build(
                    with({ id = 'block:b1', app = 'pi', state = 'idle' }),
                    agents
                )
                local sessions = model.build(
                    with({ id = 'block:b1', argv0 = '/bin/zsh' }),
                    agents
                )
                assert.are.same({}, sessions)
            end)

            it('forgets a block Rex no longer lists', function()
                local memory = model.new_memory()
                model.build(
                    with({ id = 'block:b1', app = 'pi', state = 'idle' }),
                    agents,
                    memory
                )
                model.build(snap.snapshot({}), agents, memory)
                assert.is_nil(memory.blocks['block:b1'])

                local sessions = model.build(
                    with({ id = 'block:b1', argv0 = '/bin/zsh' }),
                    agents,
                    memory
                )
                assert.are.same({}, sessions)
            end)

            it('goes back to live when the agent runs again', function()
                local memory = model.new_memory()
                local live = {
                    id = 'block:b1',
                    app = 'pi',
                    state = 'working',
                }
                model.build(with(live), agents, memory)
                model.build(with({ id = 'block:b1' }), agents, memory)
                local sessions = model.build(with(live), agents, memory)

                local row = sessions[1].rows[1]
                assert.are.equal('working', row.status)
                assert.is_nil(row.last_status)
            end)

            it('keeps its last status over repeated builds', function()
                local memory = model.new_memory()
                model.build(
                    with({ id = 'block:b1', app = 'pi', state = 'done' }),
                    agents,
                    memory
                )
                local gone = with({ id = 'block:b1' })
                model.build(gone, agents, memory)
                local sessions = model.build(gone, agents, memory)
                assert.are.equal('done', sessions[1].rows[1].last_status)
            end)

            it('keeps the memory of a session Rex could not read', function()
                local memory = model.new_memory()
                model.build(
                    with({ id = 'block:b1', app = 'pi', state = 'idle' }),
                    agents,
                    memory
                )
                model.build(
                    snap.snapshot({
                        snap.session({
                            id = 'session:s1',
                            error = 'unreadable',
                        }),
                    }),
                    agents,
                    memory
                )
                assert.is_not_nil(memory.blocks['block:b1'])
            end)

            it('ranks below every live status in the roll-up', function()
                local memory = model.new_memory()
                local function both(first, second)
                    return snap.snapshot({
                        snap.session({
                            id = 'session:s1',
                            windows = {
                                snap.window({
                                    id = 'window:w1',
                                    label = 'work',
                                    blocks = {
                                        snap.block(first),
                                        snap.block(second),
                                    },
                                }),
                            },
                        }),
                    })
                end
                model.build(
                    both(
                        { id = 'block:b1', app = 'pi', state = 'idle' },
                        { id = 'block:b2', app = 'pi', state = 'idle' }
                    ),
                    agents,
                    memory
                )
                local sessions = model.build(
                    both(
                        { id = 'block:b1' },
                        { id = 'block:b2', app = 'pi', state = 'idle' }
                    ),
                    agents,
                    memory
                )
                assert.are.equal('idle', sessions[1].status)
            end)
        end)

        describe('with the recorded fixture', function()
            local sessions = model.build(helpers.fixture('sample.json'), agents)

            it('keeps only sessions that hold an agent', function()
                assert.are.equal(6, #sessions)
            end)

            it('shows one row per agent block', function()
                assert.are.equal(8, #rows_of(sessions))
            end)

            it('never shows a plain editor as a row', function()
                for _, row in ipairs(rows_of(sessions)) do
                    assert.are_not.equal('nvim', row.harness)
                end
            end)

            it('gives every row a label and a known status', function()
                local status = require('rexai.core.status')
                for _, row in ipairs(rows_of(sessions)) do
                    assert.is_string(row.label)
                    assert.is_not.equal('', row.label)
                    assert.is_number(status.rank(row.status))
                end
            end)

            it('rolls each session up from its rows', function()
                local status = require('rexai.core.status')
                for _, session in ipairs(sessions) do
                    local names = {}
                    for _, row in ipairs(session.rows) do
                        names[#names + 1] = row.status
                    end
                    assert.are.equal(status.rollup(names), session.status)
                end
            end)
        end)
    end)
end)
