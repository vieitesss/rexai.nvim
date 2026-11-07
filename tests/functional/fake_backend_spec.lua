local backend_api = require('rexai.backend')
local fake = require('rexai.backend.fake')
local snap = require('tests.snapshots')

local function snapshot_with(block_id)
    return snap.single({ id = block_id, app = 'pi', state = 'idle' })
end

-- Runs `call` and returns what the callback received.
local function result(call)
    local got
    call(function(...)
        got = { n = select('#', ...), ... }
    end)
    assert.is_not_nil(got, 'callback was not called before the method returned')
    return got
end

describe('backend.fake', function()
    it('has every method of the Backend interface', function()
        local backend = fake.new({ snapshots = { snapshot_with('block:b1') } })
        for _, method in ipairs(backend_api.METHODS) do
            assert.is_function(backend[method], method)
        end
    end)

    describe('snapshot', function()
        it('serves the snapshots in order, then repeats the last', function()
            local first, second =
                snapshot_with('block:b1'), snapshot_with('block:b2')
            local backend = fake.new({ snapshots = { first, second } })

            assert.are.equal(first, result(backend.snapshot)[2])
            assert.are.equal(second, result(backend.snapshot)[2])
            assert.are.equal(second, result(backend.snapshot)[2])
        end)

        it('passes no error on success', function()
            local backend =
                fake.new({ snapshots = { snapshot_with('block:b1') } })
            assert.is_nil(result(backend.snapshot)[1])
        end)

        it('fails when no snapshot is prepared', function()
            local backend = fake.new({})
            assert.is_string(result(backend.snapshot)[1])
        end)
    end)

    describe('focus', function()
        local backend

        before_each(function()
            backend = fake.new({ snapshots = { snapshot_with('block:b1') } })
            result(backend.snapshot)
        end)

        it('accepts a block in the current snapshot', function()
            local got = result(function(callback)
                backend.focus({
                    session_id = 'session:s1',
                    window_id = 'window:w1',
                    block_id = 'block:b1',
                }, callback)
            end)
            assert.is_nil(got[1])
        end)

        it('accepts a session or a window alone', function()
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

        it('fails for a block that is not in the snapshot', function()
            local got = result(function(callback)
                backend.focus({
                    session_id = 'session:s1',
                    window_id = 'window:w1',
                    block_id = 'block:gone',
                }, callback)
            end)
            assert.is_string(got[1])
        end)

        it('fails for an unknown session', function()
            local got = result(function(callback)
                backend.focus({ session_id = 'session:gone' }, callback)
            end)
            assert.is_string(got[1])
        end)
    end)

    describe('create_window and create_session', function()
        it('return a new target each time', function()
            local backend =
                fake.new({ snapshots = { snapshot_with('block:b1') } })
            local first = result(function(callback)
                backend.create_window({ session_id = 'session:s1' }, callback)
            end)
            local second = result(function(callback)
                backend.create_session({ name = 'new' }, callback)
            end)

            assert.is_nil(first[1])
            assert.is_nil(second[1])
            assert.are.equal('session:s1', first[2].session_id)
            assert.is_string(second[2].session_id)
            assert.are_not.equal(first[2].window_id, second[2].window_id)
            assert.are_not.equal(first[2].block_id, second[2].block_id)
        end)
    end)

    describe('peek', function()
        it('returns the prepared text of a block', function()
            local backend = fake.new({
                snapshots = { snapshot_with('block:b1') },
                peek = { ['block:b1'] = 'last lines' },
            })
            result(backend.snapshot)
            local got = result(function(callback)
                backend.peek({
                    session_id = 'session:s1',
                    window_id = 'window:w1',
                    block_id = 'block:b1',
                }, callback)
            end)
            assert.is_nil(got[1])
            assert.are.equal('last lines', got[2])
        end)

        it('returns empty text when none is prepared', function()
            local backend =
                fake.new({ snapshots = { snapshot_with('block:b1') } })
            result(backend.snapshot)
            local got = result(function(callback)
                backend.peek({
                    session_id = 'session:s1',
                    window_id = 'window:w1',
                    block_id = 'block:b1',
                }, callback)
            end)
            assert.are.equal('', got[2])
        end)

        it('fails for a block that is not in the snapshot', function()
            local backend =
                fake.new({ snapshots = { snapshot_with('block:b1') } })
            result(backend.snapshot)
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

    describe('fail_next', function()
        it('fails the next call of a method, once', function()
            local backend =
                fake.new({ snapshots = { snapshot_with('block:b1') } })
            backend.fail_next('snapshot', 'rex is down')

            assert.are.equal('rex is down', result(backend.snapshot)[1])
            assert.is_nil(result(backend.snapshot)[1])
        end)

        it('does not use up a snapshot on a failure', function()
            local first, second =
                snapshot_with('block:b1'), snapshot_with('block:b2')
            local backend = fake.new({ snapshots = { first, second } })
            backend.fail_next('snapshot', 'rex is down')
            result(backend.snapshot)

            assert.are.equal(first, result(backend.snapshot)[2])
        end)

        it('queues several failures in order', function()
            local backend =
                fake.new({ snapshots = { snapshot_with('block:b1') } })
            backend.fail_next('snapshot', 'one')
            backend.fail_next('snapshot', 'two')

            assert.are.equal('one', result(backend.snapshot)[1])
            assert.are.equal('two', result(backend.snapshot)[1])
            assert.is_nil(result(backend.snapshot)[1])
        end)
    end)

    describe('calls', function()
        it('records every call in order', function()
            local backend, calls =
                fake.new({ snapshots = { snapshot_with('block:b1') } })
            result(backend.snapshot)
            result(function(callback)
                backend.focus({ session_id = 'session:s1' }, callback)
            end)
            result(function(callback)
                backend.create_window({ session_id = 'session:s1' }, callback)
            end)

            assert.are.equal(3, #calls)
            assert.are.equal('snapshot', calls[1].method)
            assert.are.equal('focus', calls[2].method)
            assert.are.equal('session:s1', calls[2].arg.session_id)
            assert.are.equal('create_window', calls[3].method)
        end)

        it('records a failed call too', function()
            local backend, calls =
                fake.new({ snapshots = { snapshot_with('block:b1') } })
            backend.fail_next('snapshot', 'down')
            result(backend.snapshot)
            assert.are.equal(1, #calls)
        end)
    end)
end)
