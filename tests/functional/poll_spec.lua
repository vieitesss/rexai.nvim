local poll = require('rexai.poll')
local fake = require('rexai.backend.fake')
local snap = require('tests.snapshots')

local function snapshot_with(block_id)
    return snap.single({ id = block_id, app = 'pi', state = 'idle' })
end

local function fake_timer()
    local timer = { pending = {} }

    function timer.after(ms, fn)
        local entry = { ms = ms, fn = fn }
        table.insert(timer.pending, entry)
        return function()
            for i, pending in ipairs(timer.pending) do
                if pending == entry then
                    table.remove(timer.pending, i)
                    return
                end
            end
        end
    end

    function timer.fire()
        local entry = table.remove(timer.pending, 1)
        assert.is_not_nil(entry)
        entry.fn()
    end

    return timer
end

local function async_backend()
    local callbacks = {}
    local backend = { calls = 0 }

    function backend.snapshot(callback)
        backend.calls = backend.calls + 1
        table.insert(callbacks, callback)
    end

    local function finish(err, snapshot)
        local callback = table.remove(callbacks, 1)
        assert.is_not_nil(callback)
        callback(err, snapshot)
    end

    return backend, finish
end

describe('poll', function()
    it(
        'starts with a snapshot and waits the success interval before the next',
        function()
            local first, second =
                snapshot_with('block:b1'), snapshot_with('block:b2')
            local backend, calls = fake.new({ snapshots = { first, second } })
            local timer = fake_timer()
            local received = {}
            local poller = poll.new({
                backend = backend,
                interval_ms = 120,
                after = timer.after,
                on_snapshot = function(snapshot)
                    table.insert(received, snapshot)
                end,
            })

            poller.start()
            assert.are.same({ first }, received)
            assert.are.equal(1, #calls)
            assert.are.equal(1, #timer.pending)
            assert.are.equal(120, timer.pending[1].ms)

            timer.fire()
            assert.are.same({ first, second }, received)
            assert.are.equal(2, #calls)
            assert.are.equal(1, #timer.pending)
            assert.are.equal(120, timer.pending[1].ms)
        end
    )

    it(
        'skips a tick while a snapshot is in flight and allows it after completion',
        function()
            local backend, finish = async_backend()
            local timer = fake_timer()
            local poller = poll.new({ backend = backend, after = timer.after })

            poller.start()
            assert.are.equal(1, backend.calls)
            assert.is_false(poller.tick())
            assert.are.equal(1, backend.calls)
            assert.are.equal(0, #timer.pending)

            finish(nil, snapshot_with('block:b1'))
            assert.are.equal(1, #timer.pending)
            assert.is_true(poller.tick())
            assert.are.equal(0, #timer.pending)
            assert.are.equal(2, backend.calls)
            assert.is_false(poller.tick())
            assert.are.equal(2, backend.calls)
            finish(nil, snapshot_with('block:b2'))
            assert.are.equal(1, #timer.pending)
        end
    )

    it(
        'reports one error per outage, retries, and resets after recovery',
        function()
            local snapshot = snapshot_with('block:b1')
            local backend, calls = fake.new({ snapshots = { snapshot } })
            local timer = fake_timer()
            local errors, received = {}, {}
            local poller = poll.new({
                backend = backend,
                retry_ms = 750,
                after = timer.after,
                on_error = function(err)
                    table.insert(errors, err)
                end,
                on_snapshot = function(result)
                    table.insert(received, result)
                end,
            })
            backend.fail_next('snapshot', 'connection refused')
            backend.fail_next('snapshot', 'connection reset by peer')
            backend.fail_next('snapshot', 'connection refused')

            poller.start()
            assert.are.same({ 'connection refused' }, errors)
            assert.are.equal(1, #timer.pending)
            assert.are.equal(750, timer.pending[1].ms)
            timer.fire()
            assert.are.same({ 'connection refused' }, errors)
            assert.are.equal(1, #timer.pending)
            assert.are.equal(750, timer.pending[1].ms)
            timer.fire()
            assert.are.same({ 'connection refused' }, errors)
            assert.are.equal(1, #timer.pending)
            assert.are.equal(750, timer.pending[1].ms)
            assert.are.equal(0, #received)

            timer.fire()
            assert.are.same({ snapshot }, received)
            assert.are.equal(1000, timer.pending[1].ms)
            backend.fail_next('snapshot', 'connection refused')
            timer.fire()
            assert.are.same(
                { 'connection refused', 'connection refused' },
                errors
            )
            assert.are.equal(750, timer.pending[1].ms)
            assert.are.equal(1, #timer.pending)
            assert.are.equal(5, #calls)
        end
    )

    it('reflects start and stop and refuses ticks while stopped', function()
        local backend, calls =
            fake.new({ snapshots = { snapshot_with('block:b1') } })
        local timer = fake_timer()
        local poller = poll.new({ backend = backend, after = timer.after })

        assert.is_false(poller.running())
        assert.is_false(poller.tick())
        assert.are.equal(0, #calls)
        poller.start()
        assert.is_true(poller.running())
        assert.are.equal(1, #timer.pending)
        poller.stop()
        assert.is_false(poller.running())
        assert.are.equal(0, #timer.pending)
        assert.is_false(poller.tick())
        assert.are.equal(1, #calls)
        poller.stop()
        assert.is_false(poller.running())
    end)

    it('drops a snapshot arriving while stopped and can start again', function()
        local backend, finish = async_backend()
        local timer = fake_timer()
        local received, errors = {}, {}
        local poller = poll.new({
            backend = backend,
            after = timer.after,
            on_snapshot = function(snapshot)
                table.insert(received, snapshot)
            end,
            on_error = function(err)
                table.insert(errors, err)
            end,
        })

        poller.start()
        poller.stop()
        finish(nil, snapshot_with('block:b1'))
        assert.are.same({}, received)
        assert.are.equal(0, #timer.pending)
        poller.start()
        assert.are.equal(2, backend.calls)
        poller.stop()
        finish('rex is unreachable')
        assert.are.same({}, errors)
        assert.are.equal(0, #timer.pending)
        poller.start()
        local snapshot = snapshot_with('block:b2')
        finish(nil, snapshot)
        assert.are.same({ snapshot }, received)
        assert.are.equal(1, #timer.pending)
    end)

    it(
        'reuses an in-flight call when stopped and started before it finishes',
        function()
            local backend, finish = async_backend()
            local timer = fake_timer()
            local snapshot = snapshot_with('block:b1')
            local received = {}
            local poller = poll.new({
                backend = backend,
                interval_ms = 120,
                after = timer.after,
                on_snapshot = function(result)
                    table.insert(received, result)
                end,
            })

            poller.start()
            poller.stop()
            poller.start()
            assert.is_true(poller.running())
            assert.are.equal(1, backend.calls)
            assert.is_false(poller.tick())
            assert.are.equal(0, #timer.pending)
            finish(nil, snapshot)
            assert.are.same({ snapshot }, received)
            assert.are.equal(1, #timer.pending)
            assert.are.equal(120, timer.pending[1].ms)
            timer.fire()
            assert.are.equal(2, backend.calls)
        end
    )

    it('replaces the pending timer after a manual tick', function()
        local backend, calls =
            fake.new({ snapshots = { snapshot_with('block:b1') } })
        local timer = fake_timer()
        local poller = poll.new({
            backend = backend,
            interval_ms = 120,
            after = timer.after,
        })

        poller.start()
        assert.are.equal(1, #timer.pending)
        assert.is_true(poller.tick())
        assert.are.equal(2, #calls)
        assert.are.equal(1, #timer.pending)
        assert.are.equal(120, timer.pending[1].ms)
        timer.fire()
        assert.are.equal(3, #calls)
        assert.are.equal(1, #timer.pending)
    end)

    it('does not double up when started twice', function()
        local backend, calls =
            fake.new({ snapshots = { snapshot_with('block:b1') } })
        local timer = fake_timer()
        local poller = poll.new({ backend = backend, after = timer.after })

        poller.start()
        poller.start()
        assert.are.equal(1, #calls)
        assert.are.equal(1, #timer.pending)
        timer.fire()
        assert.are.equal(2, #calls)
        assert.are.equal(1, #timer.pending)
    end)

    it('leaves no timer when the snapshot handler stops the poller', function()
        local backend = fake.new({ snapshots = { snapshot_with('block:b1') } })
        local timer = fake_timer()
        local poller
        poller = poll.new({
            backend = backend,
            after = timer.after,
            on_snapshot = function()
                assert.are.equal(1, #timer.pending)
                poller.stop()
            end,
        })

        poller.start()
        assert.is_false(poller.running())
        assert.are.equal(0, #timer.pending)
    end)

    it('keeps polling after the snapshot handler throws', function()
        local backend, calls =
            fake.new({ snapshots = { snapshot_with('block:b1') } })
        local timer = fake_timer()
        local delivered = 0
        local poller = poll.new({
            backend = backend,
            interval_ms = 120,
            after = timer.after,
            on_snapshot = function()
                delivered = delivered + 1
                if delivered == 2 then
                    error('snapshot handler failed')
                end
            end,
        })

        poller.start()
        local ok, err = pcall(timer.fire)
        assert.is_false(ok)
        assert.matches('snapshot handler failed', err, 1, true)
        assert.is_true(poller.running())
        assert.are.equal(1, #timer.pending)
        assert.are.equal(120, timer.pending[1].ms)
        timer.fire()
        assert.are.equal(3, delivered)
        assert.are.equal(3, #calls)
        assert.are.equal(1, #timer.pending)
    end)

    it('leaves no timer when the error handler stops the poller', function()
        local backend = fake.new({ snapshots = { snapshot_with('block:b1') } })
        local timer = fake_timer()
        local poller
        poller = poll.new({
            backend = backend,
            retry_ms = 750,
            after = timer.after,
            on_error = function()
                assert.are.equal(1, #timer.pending)
                assert.are.equal(750, timer.pending[1].ms)
                poller.stop()
            end,
        })
        backend.fail_next('snapshot', 'rex is unreachable')

        poller.start()
        assert.is_false(poller.running())
        assert.are.equal(0, #timer.pending)
    end)

    it('keeps retrying without repeating a throwing error handler', function()
        local backend, calls =
            fake.new({ snapshots = { snapshot_with('block:b1') } })
        local timer = fake_timer()
        local reported = 0
        local poller = poll.new({
            backend = backend,
            retry_ms = 750,
            after = timer.after,
            on_error = function()
                reported = reported + 1
                error('error handler failed')
            end,
        })

        poller.start()
        backend.fail_next('snapshot', 'rex is unreachable')
        backend.fail_next('snapshot', 'rex is unreachable')
        local ok, err = pcall(timer.fire)
        assert.is_false(ok)
        assert.matches('error handler failed', err, 1, true)
        assert.are.equal(1, #timer.pending)
        assert.are.equal(750, timer.pending[1].ms)
        timer.fire()
        assert.are.equal(1, reported)
        assert.are.equal(1, #timer.pending)
        assert.are.equal(750, timer.pending[1].ms)
        timer.fire()
        assert.are.equal(4, #calls)
        assert.are.equal(1000, timer.pending[1].ms)
    end)

    it('retries and recovers when both handlers are omitted', function()
        local backend, calls =
            fake.new({ snapshots = { snapshot_with('block:b1') } })
        local timer = fake_timer()
        local poller = poll.new({ backend = backend, after = timer.after })
        backend.fail_next('snapshot', 'rex is missing')

        poller.start()
        assert.are.equal(5000, timer.pending[1].ms)
        timer.fire()
        assert.are.equal(2, #calls)
        assert.are.equal(1, #timer.pending)
        assert.are.equal(1000, timer.pending[1].ms)
    end)

    it('polls with the default timer on the main loop and stops', function()
        local backend, calls =
            fake.new({ snapshots = { snapshot_with('block:b1') } })
        local received = 0
        local main_loop = true
        local poller = poll.new({
            backend = backend,
            interval_ms = 20,
            on_snapshot = function()
                main_loop = main_loop and not vim.in_fast_event()
                received = received + 1
            end,
        })

        poller.start()
        local completed = vim.wait(1000, function()
            return received >= 3
        end, 1)
        poller.stop()
        assert.is_true(completed)
        assert.are.equal(3, received)
        assert.are.equal(3, #calls)
        assert.is_true(main_loop)
        assert.is_false(poller.running())
        assert.is_false(vim.wait(60, function()
            return received > 3
        end, 1))
    end)

    it('delivers asynchronous snapshots and errors on the main loop', function()
        local backend, finish = async_backend()
        local timer = fake_timer()
        local snapshot = snapshot_with('block:b1')
        local received, errors = {}, {}
        local main_loop = true
        local poller = poll.new({
            backend = backend,
            after = timer.after,
            on_snapshot = function(result)
                main_loop = main_loop and not vim.in_fast_event()
                table.insert(received, result)
            end,
            on_error = function(err)
                main_loop = main_loop and not vim.in_fast_event()
                table.insert(errors, err)
            end,
        })
        local function complete(err, result)
            local event = vim.uv.new_timer()
            event:start(0, 0, function()
                event:close()
                finish(err, result)
            end)
        end

        poller.start()
        complete(nil, snapshot)
        assert.is_true(vim.wait(1000, function()
            return #received == 1
        end, 1))
        assert.are.same({ snapshot }, received)
        timer.fire()
        complete('rex is unreachable')
        assert.is_true(vim.wait(1000, function()
            return #errors == 1
        end, 1))
        assert.are.same({ 'rex is unreachable' }, errors)
        assert.is_true(main_loop)
        assert.are.equal(1, #timer.pending)
        assert.are.equal(5000, timer.pending[1].ms)
        poller.stop()
    end)

    it(
        'cancels a default timer after it fires but before its scheduled callback',
        function()
            local backend, calls =
                fake.new({ snapshots = { snapshot_with('block:b1') } })
            local poller = poll.new({ backend = backend, interval_ms = 20 })
            local barrier = vim.uv.new_timer()
            local fired = false

            poller.start()
            barrier:start(40, 0, function()
                fired = true
                barrier:close()
            end)
            -- Process timer events without running the scheduled main-loop callbacks.
            local completed = vim.wait(1000, function()
                return fired
            end, 1, true)
            if not fired then
                barrier:stop()
                barrier:close()
            end
            local calls_before_stop = #calls
            poller.stop()
            poller.stop()
            poller.start()
            local drained = false
            vim.schedule(function()
                poller.stop()
                drained = true
            end)
            local callbacks_drained = vim.wait(1000, function()
                return drained
            end, 1)
            poller.stop()
            assert.is_true(completed)
            assert.are.equal(1, calls_before_stop)
            assert.is_true(callbacks_drained)
            assert.are.equal(2, #calls)
            assert.is_false(vim.wait(60, function()
                return #calls > 2
            end, 1))
        end
    )
end)
