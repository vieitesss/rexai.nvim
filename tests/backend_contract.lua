-- The tests every Backend must pass. The fake Backend and the rex Backend
-- both run them, so the two cannot drift apart.
--
-- A spec file calls `contract.run(name, make)`. `make(snapshot, peek)` builds
-- a Backend that serves `snapshot` and the screen text `peek` (by block id),
-- and returns a harness:
--
--   backend   the rexai.Backend
--   fail      fun(method): the next call to `method` fails with an error
--   teardown  fun(): releases what `make` set up

local snap = require('tests.snapshots')

local M = {}

local TARGET = {
    session_id = 'session:s1',
    window_id = 'window:w1',
    block_id = 'block:b1',
}

-- Runs `call` and returns what its callback received. A Backend may call the
-- callback before the method returns or later, so this waits for it.
local function result(call)
    local got
    call(function(...)
        got = { n = select('#', ...), ... }
    end)
    vim.wait(10000, function()
        return got ~= nil
    end, 5)
    assert.is_not_nil(got, 'the callback was not called')
    return got
end

---@param name string
---@param make fun(snapshot: table, peek: table<string, string>|nil): table
function M.run(name, make)
    describe(name .. ' (Backend contract)', function()
        local harness

        local function setup(snapshot, peek)
            harness = make(snapshot or snap.single({
                id = 'block:b1',
                app = 'pi',
                state = 'idle',
            }), peek)
            return harness.backend
        end

        after_each(function()
            if harness then
                harness.teardown()
                harness = nil
            end
        end)

        it('has every method of the Backend interface', function()
            local backend = setup()
            for _, method in ipairs(require('rexai.backend').METHODS) do
                assert.is_function(backend[method], method)
            end
        end)

        describe('snapshot', function()
            it('returns the Sessions, Windows and Blocks of Rex', function()
                local snapshot = snap.single({
                    id = 'block:b1',
                    label = 'agent',
                    title = 'a title',
                    app = 'pi',
                    state = 'blocked',
                    kind = 'question',
                    msg = 'which one?',
                    argv0 = 'pi',
                    cwd = '/work/tree',
                    last_exit = 0,
                })
                local backend = setup(snapshot)

                local got = result(backend.snapshot)
                assert.is_nil(got[1])
                assert.are.same(snapshot, got[2])
            end)

            it('keeps a Session that could not be read', function()
                local snapshot = snap.snapshot({
                    snap.session({ id = 'session:ok', windows = {} }),
                    snap.session({
                        id = 'session:bad',
                        windows = {},
                        error = 'session not found',
                    }),
                })
                local backend = setup(snapshot)

                local got = result(backend.snapshot)
                assert.is_nil(got[1])
                assert.are.equal('session not found', got[2].sessions[2].error)
            end)

            it('passes an error string when Rex fails', function()
                local backend = setup()
                harness.fail('snapshot')

                local got = result(backend.snapshot)
                assert.is_string(got[1])
                assert.is_nil(got[2])
            end)
        end)

        describe('focus', function()
            it('accepts a Block of the snapshot', function()
                local backend = setup()
                local got = result(function(callback)
                    backend.focus(TARGET, callback)
                end)
                assert.is_nil(got[1])
            end)

            it('accepts a Session or a Window alone', function()
                local backend = setup()
                local by_session = result(function(callback)
                    backend.focus({ session_id = 'session:s1' }, callback)
                end)
                local by_window = result(function(callback)
                    backend.focus({
                        session_id = 'session:s1',
                        window_id = 'window:w1',
                    }, callback)
                end)
                assert.is_nil(by_session[1])
                assert.is_nil(by_window[1])
            end)

            it('fails for a Block that is gone', function()
                local backend = setup()
                local got = result(function(callback)
                    backend.focus({
                        session_id = 'session:s1',
                        window_id = 'window:w1',
                        block_id = 'block:gone',
                    }, callback)
                end)
                assert.is_string(got[1])
            end)

            it('fails for a Session that is gone', function()
                local backend = setup()
                local got = result(function(callback)
                    backend.focus({ session_id = 'session:gone' }, callback)
                end)
                assert.is_string(got[1])
            end)
        end)

        describe('create_window and create_session', function()
            it('return a new target each time', function()
                local backend = setup()
                local window = result(function(callback)
                    backend.create_window(
                        { session_id = 'session:s1' },
                        callback
                    )
                end)
                local session = result(function(callback)
                    backend.create_session({ name = 'new' }, callback)
                end)

                assert.is_nil(window[1])
                assert.is_nil(session[1])
                assert.are.equal('session:s1', window[2].session_id)
                assert.is_string(window[2].window_id)
                assert.is_string(window[2].block_id)
                assert.is_string(session[2].session_id)
                assert.is_string(session[2].window_id)
                assert.is_string(session[2].block_id)
                assert.are_not.equal(window[2].window_id, session[2].window_id)
                assert.are_not.equal(window[2].block_id, session[2].block_id)
            end)

            it('pass an error string when Rex fails', function()
                local backend = setup()
                harness.fail('create_window')
                harness.fail('create_session')

                local window = result(function(callback)
                    backend.create_window(
                        { session_id = 'session:s1' },
                        callback
                    )
                end)
                local session = result(function(callback)
                    backend.create_session({}, callback)
                end)
                assert.is_string(window[1])
                assert.is_string(session[1])
            end)
        end)

        describe('peek', function()
            it('returns the screen text of a Block', function()
                local backend =
                    setup(nil, { ['block:b1'] = 'first line\nlast line' })
                local got = result(function(callback)
                    backend.peek(TARGET, callback)
                end)
                assert.is_nil(got[1])
                assert.are.equal('first line\nlast line', got[2])
            end)

            it('returns empty text for a blank screen', function()
                local backend = setup()
                local got = result(function(callback)
                    backend.peek(TARGET, callback)
                end)
                assert.is_nil(got[1])
                assert.are.equal('', got[2])
            end)

            it('fails for a Block that is gone', function()
                local backend = setup()
                local got = result(function(callback)
                    backend.peek({
                        session_id = 'session:s1',
                        window_id = 'window:w1',
                        block_id = 'block:gone',
                    }, callback)
                end)
                assert.is_string(got[1])
            end)
        end)
    end)
end

M.result = result

return M
