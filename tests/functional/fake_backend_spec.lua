local contract = require('tests.backend_contract')
local fake = require('rexai.backend.fake')
local snap = require('tests.snapshots')

local result = contract.result

local function snapshot_with(block_id)
    return snap.single({ id = block_id, app = 'pi', state = 'idle' })
end

contract.run('backend.fake', function(snapshot, peek)
    local backend = fake.new({ snapshots = { snapshot }, peek = peek })
    return {
        backend = backend,
        fail = function(method)
            backend.fail_next(method, 'rex is down')
        end,
        teardown = function() end,
    }
end)

describe('backend.fake', function()
    describe('snapshot', function()
        it('serves the snapshots in order, then repeats the last', function()
            local first, second =
                snapshot_with('block:b1'), snapshot_with('block:b2')
            local backend = fake.new({ snapshots = { first, second } })

            assert.are.equal(first, result(backend.snapshot)[2])
            assert.are.equal(second, result(backend.snapshot)[2])
            assert.are.equal(second, result(backend.snapshot)[2])
        end)

        it('fails when no snapshot is prepared', function()
            local backend = fake.new({})
            assert.is_string(result(backend.snapshot)[1])
        end)
    end)

    describe('focus and peek', function()
        it('check the target against the latest snapshot served', function()
            local backend = fake.new({
                snapshots = {
                    snapshot_with('block:b1'),
                    snapshot_with('block:b2'),
                },
            })
            local target = {
                session_id = 'session:s1',
                window_id = 'window:w1',
                block_id = 'block:b1',
            }
            result(backend.snapshot)
            assert.is_nil(result(function(callback)
                backend.focus(target, callback)
            end)[1])

            result(backend.snapshot)
            assert.is_string(result(function(callback)
                backend.focus(target, callback)
            end)[1])
            assert.is_string(result(function(callback)
                backend.peek(target, callback)
            end)[1])
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
