local contract = require('tests.backend_contract')
local helpers = require('tests.helpers')
local rex = require('rexai.backend.rex')
local rex_stub = require('tests.rex_stub')
local snap = require('tests.snapshots')

local result = contract.result

local SNAPSHOT = snap.single({ id = 'block:b1', app = 'pi', state = 'idle' })

contract.run('backend.rex', function(snapshot, peek)
    local stub = rex_stub.install({ snapshot = snapshot, peek = peek })
    stub.on_path()
    return {
        backend = rex.new(),
        fail = function()
            stub.set({ fail = { code = 1, message = 'rex is down' } })
        end,
        teardown = stub.remove,
    }
end)

describe('with a captured snapshot', function()
    local snapshot, stub, backend

    before_each(function()
        snapshot = helpers.fixture('sample.json')
        stub = rex_stub.install({ snapshot = snapshot })
        stub.on_path()
        backend = rex.new()
    end)

    after_each(function()
        stub.remove()
    end)

    it('replays the fixture through the rex subprocess', function()
        local got = result(backend.snapshot)

        assert.is_nil(got[1])
        assert.are.same(snapshot, got[2])
    end)

    it('focuses and peeks the first Block in the fixture', function()
        local target
        for _, session in ipairs(snapshot.sessions) do
            for _, window in ipairs(session.windows) do
                for _, block in ipairs(window.blocks) do
                    target = {
                        session_id = session.id,
                        window_id = window.id,
                        block_id = block.id,
                    }
                    break
                end
                if target then
                    break
                end
            end
            if target then
                break
            end
        end
        assert.is_not_nil(target, 'the fixture must contain a Block')

        local focused = result(function(callback)
            backend.focus(target, callback)
        end)
        local peeked = result(function(callback)
            backend.peek(target, callback)
        end)

        assert.is_nil(focused[1])
        assert.is_nil(peeked[1])
        assert.is_string(peeked[2])
    end)
end)

describe('backend.rex', function()
    local stub

    before_each(function()
        stub = rex_stub.install({ snapshot = SNAPSHOT })
    end)

    after_each(function()
        stub.remove()
    end)

    describe('running rex', function()
        it('uses an argument list, so a space in a path is safe', function()
            local scripts_dir = stub.dir .. '/scripts'
            assert.is_truthy(stub.bin:find(' ', 1, true))
            assert.is_truthy(scripts_dir:find(' ', 1, true))

            local backend =
                rex.new({ bin = stub.bin, scripts_dir = scripts_dir })
            local got = result(backend.snapshot)

            assert.is_nil(got[1])
            assert.are.same({
                {
                    '--autostart=false',
                    'do',
                    scripts_dir .. '/snapshot.lua',
                    '--json',
                },
            }, stub.calls())
        end)

        it('loads the scripts from the plugin directory by default', function()
            stub.on_path()
            result(rex.new().snapshot)

            assert.are.equal(
                helpers.root() .. '/scripts/snapshot.lua',
                stub.calls()[1][3]
            )
        end)

        it('never starts a Rex server', function()
            local backend = rex.new({ bin = stub.bin })
            result(backend.snapshot)
            result(function(callback)
                backend.peek({
                    session_id = 'session:s1',
                    window_id = 'window:w1',
                    block_id = 'block:b1',
                }, callback)
            end)
            result(function(callback)
                backend.create_session({}, callback)
            end)

            for _, argv in ipairs(stub.calls()) do
                assert.are.equal('--autostart=false', argv[1])
            end
        end)

        it('calls back on the main loop', function()
            local backend = rex.new({ bin = stub.bin })
            local fast
            result(function(callback)
                backend.snapshot(function(...)
                    fast = vim.in_fast_event()
                    callback(...)
                end)
            end)
            assert.is_false(fast)
        end)
    end)

    describe('failures', function()
        it('reports a Rex that is not installed', function()
            local backend = rex.new({ bin = stub.dir .. '/no-such-rex' })
            local got = result(backend.snapshot)

            assert.is_truthy(got[1]:find('cannot run', 1, true))
            assert.is_nil(got[2])
        end)

        it('reports the first line of what rex printed on stderr', function()
            stub.set({
                fail = { code = 4, message = 'rex server is not running' },
            })
            local got = result(rex.new({ bin = stub.bin }).snapshot)

            assert.are.equal('rex server is not running', got[1])
        end)

        it('kills a call that takes too long', function()
            stub.set({ delay_ms = 3000 })
            local backend = rex.new({ bin = stub.bin, timeout_ms = 300 })
            local started = vim.uv.hrtime()
            local got = result(backend.snapshot)

            assert.are.equal('rex timed out after 0.3 s', got[1])
            assert.is_true((vim.uv.hrtime() - started) / 1e6 < 2500)
        end)

        it('rejects output that is not JSON', function()
            stub.set({ stdout = 'not json\n' })
            local got = result(rex.new({ bin = stub.bin }).snapshot)

            assert.are.equal('rex printed text that is not JSON', got[1])
        end)

        it('rejects a snapshot of an unknown shape', function()
            local backend = rex.new({ bin = stub.bin })
            for _, stdout in ipairs({
                '{"version":2,"sessions":[]}',
                '{"version":1}',
                '[]',
                '"text"',
            }) do
                stub.set({ stdout = stdout })
                assert.are.equal(
                    'rex returned a snapshot of an unknown shape',
                    result(backend.snapshot)[1],
                    stdout
                )
            end
        end)

        it('rejects a created target it cannot read', function()
            local backend = rex.new({ bin = stub.bin })
            stub.set({ stdout = '{}' })

            local window = result(function(callback)
                backend.create_window({ session_id = 'session:s1' }, callback)
            end)
            local session = result(function(callback)
                backend.create_session({}, callback)
            end)

            assert.are.equal('rex did not describe what it created', window[1])
            assert.are.equal('rex did not describe what it created', session[1])
        end)
    end)

    describe('focus', function()
        it('runs the focus script with the target', function()
            local backend = rex.new({ bin = stub.bin })
            result(function(callback)
                backend.focus({
                    session_id = 'session:s1',
                    window_id = 'window:w1',
                    block_id = 'block:b1',
                }, callback)
            end)

            local argv = stub.calls()[1]
            assert.are.equal('do', argv[2])
            assert.is_truthy(argv[3]:match('/scripts/focus%.lua$'))
            assert.are.equal('--json', argv[4])
            assert.are.equal('--args', argv[5])
            assert.are.same({
                session_id = 'session:s1',
                window_id = 'window:w1',
                block_id = 'block:b1',
            }, vim.json.decode(argv[6]))
        end)

        it('leaves out the parts of the target that are not set', function()
            local backend = rex.new({ bin = stub.bin })
            result(function(callback)
                backend.focus({ session_id = 'session:s1' }, callback)
            end)

            assert.are.same(
                { session_id = 'session:s1' },
                vim.json.decode(stub.calls()[1][6])
            )
        end)
    end)

    describe('create_window', function()
        it('runs `rex window new` with the spec', function()
            local backend = rex.new({ bin = stub.bin })
            result(function(callback)
                backend.create_window({
                    session_id = 'session:s1',
                    name = 'agents',
                    cwd = '/work tree',
                    focus = false,
                    command = { 'pi', '--flag', 'two words' },
                }, callback)
            end)

            assert.are.same({
                '--autostart=false',
                'window',
                'new',
                '-s',
                'session:s1',
                'agents',
                '-c',
                '/work tree',
                '--focus=false',
                '--json',
                '--',
                'pi',
                '--flag',
                'two words',
            }, stub.calls()[1])
        end)

        it('needs a Session', function()
            local backend = rex.new({ bin = stub.bin })
            local got = result(function(callback)
                backend.create_window({}, callback)
            end)

            assert.are.equal('session_id is required', got[1])
            assert.are.same({}, stub.calls())
        end)

        it('fails for a Session that is gone', function()
            local backend = rex.new({ bin = stub.bin })
            local got = result(function(callback)
                backend.create_window({ session_id = 'session:gone' }, callback)
            end)

            assert.is_string(got[1])
        end)
    end)

    describe('create_session', function()
        it('runs `rex new` with the spec', function()
            local backend = rex.new({ bin = stub.bin })
            result(function(callback)
                backend.create_session({
                    name = 'work',
                    cwd = '/work tree',
                    window = 'agent',
                    command = { 'pi' },
                }, callback)
            end)

            assert.are.same({
                '--autostart=false',
                'new',
                'work',
                '-c',
                '/work tree',
                '--window',
                'agent',
                '--json',
                '--',
                'pi',
            }, stub.calls()[1])
        end)

        it('runs a bare `rex new` for an empty spec', function()
            local backend = rex.new({ bin = stub.bin })
            result(function(callback)
                backend.create_session({}, callback)
            end)

            assert.are.same(
                { '--autostart=false', 'new', '--json' },
                stub.calls()[1]
            )
        end)
    end)

    describe('peek', function()
        local target = {
            session_id = 'session:s1',
            window_id = 'window:w1',
            block_id = 'block:b1',
        }

        it('runs `rex capture` for the Block', function()
            local backend = rex.new({ bin = stub.bin })
            result(function(callback)
                backend.peek(target, callback)
            end)

            assert.are.same({
                '--autostart=false',
                'capture',
                '-s',
                'session:s1',
                '-b',
                'block:b1',
                '--trim',
            }, stub.calls()[1])
        end)

        it('keeps the last lines of the screen', function()
            local lines = {}
            for i = 1, 120 do
                lines[i] = 'line ' .. i
            end
            stub.set({ peek = { ['block:b1'] = table.concat(lines, '\n') } })

            local default = result(function(callback)
                rex.new({ bin = stub.bin }).peek(target, callback)
            end)
            local short = result(function(callback)
                rex.new({ bin = stub.bin, peek_lines = 3 })
                    .peek(target, callback)
            end)

            local kept = vim.split(default[2], '\n', { plain = true })
            assert.are.equal(50, #kept)
            assert.are.equal('line 71', kept[1])
            assert.are.equal('line 120', kept[50])
            assert.are.equal('line 118\nline 119\nline 120', short[2])
        end)

        it('needs a Block', function()
            local backend = rex.new({ bin = stub.bin })
            local got = result(function(callback)
                backend.peek({ session_id = 'session:s1' }, callback)
            end)

            assert.are.equal('block_id is required', got[1])
            assert.are.same({}, stub.calls())
        end)
    end)
end)
