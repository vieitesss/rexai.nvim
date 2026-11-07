local helpers = require('tests.helpers')
local sandbox = require('tests.sandbox')

local script = helpers.root() .. '/scripts/snapshot.lua'

describe('snapshot.lua', function()
    local rex, calls, handlers, sessions, view

    before_each(function()
        sessions = { { session_id = 'session:s1', label = 'Example Session' } }
        view = {
            active_window_id = 'window:w1',
            windows = {
                {
                    window_id = 'window:w1',
                    label = 'Example Window',
                    focused_block_id = 'block:b1',
                    layers = {
                        {
                            blocks = {
                                {
                                    block_id = 'block:b1',
                                    label = 'Example Block',
                                    flavor = 'com.superlogical.terminal.demo',
                                },
                            },
                        },
                    },
                },
            },
        }
        handlers = {
            ['session.list'] = function()
                return { sessions = sessions }
            end,
            ['session.attach'] = function()
                return {}
            end,
            ['session.view'] = function()
                return view
            end,
            program_status = function()
                return {
                    records = {
                        {
                            state = 'working',
                            kind = 'agent',
                            app = 'sample-agent',
                            effective_app = 'pi',
                            msg = 'Checking sample code',
                            updated_at = 42,
                            ignored = function() end,
                        },
                        {
                            state = 'done',
                            kind = 'agent',
                            app = 'sample-agent',
                            effective_app = 'pi',
                            msg = 'Sample check complete',
                            updated_at = 43,
                        },
                    },
                }
            end,
            title = function()
                return { title = 'Example title', ignored = function() end }
            end,
            process = function()
                return {
                    foreground = {
                        argv0 = '/opt/example/bin/sample-agent',
                        name = 'sample-agent',
                        cwd = '/work/example',
                        ignored = function() end,
                    },
                    last_exit = 0,
                    child = {
                        name = 'sample-child',
                        path = '/opt/example/bin/sample-child',
                        ignored = function() end,
                    },
                    ignored = function() end,
                }
            end,
        }
        rex, calls = sandbox.fake(handlers)
    end)

    it('returns version 1 with no Sessions when Rex has none', function()
        sessions = {}

        local ok, value = sandbox.run(script, rex)

        assert.is_true(ok, value)
        assert.are.same({ version = 1, sessions = {} }, value)
    end)

    it(
        'maps Sessions, Windows, Blocks, Agent status records and process facts',
        function()
            local ok, value = sandbox.run(script, rex)

            assert.is_true(ok, value)
            assert.are.same({
                version = 1,
                sessions = {
                    {
                        id = 'session:s1',
                        label = 'Example Session',
                        active_window_id = 'window:w1',
                        windows = {
                            {
                                id = 'window:w1',
                                label = 'Example Window',
                                focused_block_id = 'block:b1',
                                blocks = {
                                    {
                                        id = 'block:b1',
                                        label = 'Example Block',
                                        title = 'Example title',
                                        records = {
                                            {
                                                state = 'working',
                                                kind = 'agent',
                                                app = 'sample-agent',
                                                effective_app = 'pi',
                                                msg = 'Checking sample code',
                                                updated_at = 42,
                                            },
                                            {
                                                state = 'done',
                                                kind = 'agent',
                                                app = 'sample-agent',
                                                effective_app = 'pi',
                                                msg = 'Sample check complete',
                                                updated_at = 43,
                                            },
                                        },
                                        process = {
                                            argv0 = '/opt/example/bin/sample-agent',
                                            name = 'sample-agent',
                                            cwd = '/work/example',
                                            last_exit = 0,
                                            child = {
                                                name = 'sample-child',
                                                path = '/opt/example/bin/sample-child',
                                            },
                                        },
                                    },
                                },
                            },
                        },
                    },
                },
            }, value)
        end
    )

    it(
        'reads each Block through the terminal app with its Session and Block ids',
        function()
            local ok, value = sandbox.run(script, rex)

            assert.is_true(ok, value)
            assert.are.same({
                { method = 'session.list' },
                {
                    method = 'session.attach',
                    params = { session_id = 'session:s1' },
                },
                {
                    method = 'session.view',
                    params = { session_id = 'session:s1' },
                },
                {
                    method = 'program_status',
                    app = 'com.superlogical.terminal',
                    params = {
                        session_id = 'session:s1',
                        block_id = 'block:b1',
                    },
                },
                {
                    method = 'title',
                    app = 'com.superlogical.terminal',
                    params = {
                        session_id = 'session:s1',
                        block_id = 'block:b1',
                    },
                },
                {
                    method = 'process',
                    app = 'com.superlogical.terminal',
                    params = {
                        session_id = 'session:s1',
                        block_id = 'block:b1',
                    },
                },
            }, calls)
        end
    )

    it(
        'leaves out Blocks whose flavor does not start with the terminal app',
        function()
            local blocks = view.windows[1].layers[1].blocks
            blocks[#blocks + 1] = {
                block_id = 'block:document',
                label = 'Example document',
                flavor = 'com.example.document',
            }
            blocks[#blocks + 1] = {
                block_id = 'block:no-flavor',
                label = 'Example without flavor',
            }
            blocks[#blocks + 1] = {
                block_id = 'block:wrong-prefix',
                label = 'Example wrong prefix',
                flavor = 'other.com.superlogical.terminal',
            }

            local ok, value = sandbox.run(script, rex)

            assert.is_true(ok, value)
            assert.are.equal(1, #value.sessions[1].windows[1].blocks)
            assert.are.equal(
                'block:b1',
                value.sessions[1].windows[1].blocks[1].id
            )
            for _, call in ipairs(calls) do
                if call.app then
                    assert.are.equal('block:b1', call.params.block_id)
                end
            end
        end
    )

    it('keeps a Block when all of its optional answers raise', function()
        for _, method in ipairs({ 'program_status', 'title', 'process' }) do
            handlers[method] = function()
                error('answer unavailable', 0)
            end
        end

        local ok, value = sandbox.run(script, rex)

        assert.is_true(ok, value)
        assert.are.same({
            {
                id = 'block:b1',
                label = 'Example Block',
                records = {},
            },
        }, value.sessions[1].windows[1].blocks)
        assert.are.same({
            { method = 'session.list' },
            {
                method = 'session.attach',
                params = { session_id = 'session:s1' },
            },
            { method = 'session.view', params = { session_id = 'session:s1' } },
            {
                method = 'program_status',
                app = 'com.superlogical.terminal',
                params = { session_id = 'session:s1', block_id = 'block:b1' },
            },
            {
                method = 'title',
                app = 'com.superlogical.terminal',
                params = { session_id = 'session:s1', block_id = 'block:b1' },
            },
            {
                method = 'process',
                app = 'com.superlogical.terminal',
                params = { session_id = 'session:s1', block_id = 'block:b1' },
            },
        }, calls)
    end)

    for _, case in ipairs({
        {
            name = 'attachment returns nil and a message',
            fail = function()
                return nil, 'boom'
            end,
        },
        {
            name = 'attachment raises',
            fail = function()
                error('boom', 0)
            end,
        },
    }) do
        it('isolates the failed Session when ' .. case.name, function()
            table.insert(sessions, 1, {
                session_id = 'session:gone',
                label = 'Unavailable Session',
            })
            handlers['session.attach'] = function(params)
                if params.session_id == 'session:gone' then
                    return case.fail()
                end
                return {}
            end

            local ok, value = sandbox.run(script, rex)

            assert.is_true(ok, value)
            assert.are.equal(2, #value.sessions)
            assert.are.same({
                id = 'session:gone',
                label = 'Unavailable Session',
                error = 'boom',
                windows = {},
            }, value.sessions[1])
            assert.are.equal('session:s1', value.sessions[2].id)
            assert.are.equal('window:w1', value.sessions[2].active_window_id)
            assert.are.equal(
                'Example title',
                value.sessions[2].windows[1].blocks[1].title
            )
            assert.are.same({
                { method = 'session.list' },
                {
                    method = 'session.attach',
                    params = { session_id = 'session:gone' },
                },
                {
                    method = 'session.attach',
                    params = { session_id = 'session:s1' },
                },
                {
                    method = 'session.view',
                    params = { session_id = 'session:s1' },
                },
            }, { calls[1], calls[2], calls[3], calls[4] })
        end)
    end

    it('reports a Session whose view returns nil and a message', function()
        handlers['session.view'] = function()
            return nil, 'gone'
        end

        local ok, value = sandbox.run(script, rex)

        assert.is_true(ok, value)
        assert.are.same({
            version = 1,
            sessions = {
                {
                    id = 'session:s1',
                    label = 'Example Session',
                    error = 'gone',
                    windows = {},
                },
            },
        }, value)
        assert.are.same({
            { method = 'session.list' },
            {
                method = 'session.attach',
                params = { session_id = 'session:s1' },
            },
            { method = 'session.view', params = { session_id = 'session:s1' } },
        }, calls)
    end)

    it(
        'preserves Window and layer order when collecting terminal Blocks',
        function()
            view.windows[1].layers[2] = {
                blocks = {
                    {
                        block_id = 'block:b2',
                        label = 'Second Block',
                        flavor = 'com.superlogical.terminal',
                    },
                },
            }
            view.windows[2] = {
                window_id = 'window:w2',
                label = 'Second Window',
                focused_block_id = 'block:b3',
                layers = {
                    {
                        blocks = {
                            {
                                block_id = 'block:b3',
                                label = 'Third Block',
                                flavor = 'com.superlogical.terminal',
                            },
                        },
                    },
                },
            }
            handlers.program_status = function()
                return { records = {} }
            end
            handlers.title = function()
                return nil
            end
            handlers.process = function()
                return nil
            end

            local ok, value = sandbox.run(script, rex)

            assert.is_true(ok, value)
            assert.are.same({
                {
                    id = 'window:w1',
                    label = 'Example Window',
                    focused_block_id = 'block:b1',
                    blocks = {
                        {
                            id = 'block:b1',
                            label = 'Example Block',
                            records = {},
                        },
                        {
                            id = 'block:b2',
                            label = 'Second Block',
                            records = {},
                        },
                    },
                },
                {
                    id = 'window:w2',
                    label = 'Second Window',
                    focused_block_id = 'block:b3',
                    blocks = {
                        {
                            id = 'block:b3',
                            label = 'Third Block',
                            records = {},
                        },
                    },
                },
            }, value.sessions[1].windows)
        end
    )

    it(
        'survives JSON encoding without leaking unmapped function fields',
        function()
            local ok, value = sandbox.run(script, rex)

            assert.is_true(ok, value)
            local encoded_ok, encoded = pcall(vim.json.encode, value)
            assert.is_true(encoded_ok, encoded)
            assert.are.same(value, vim.json.decode(encoded))
        end
    )
end)
