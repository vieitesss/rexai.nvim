local helpers = require('tests.helpers')
local sandbox = require('tests.sandbox')

local script = helpers.root() .. '/scripts/focus.lua'

describe('focus.lua', function()
    local rex, calls, handlers

    before_each(function()
        local attached = {}
        handlers = {
            size = function()
                return { owner = 'client:x' }
            end,
            ['client.list'] = function()
                return { clients = { { client_id = 'client:app' } } }
            end,
            ['client.perform'] = function()
                return {}
            end,
            ['session.attach'] = function(params)
                attached[params.session_id] = true
                return {}
            end,
            ['session.focus_block'] = function(params)
                if not attached[params.session_id] then
                    return nil,
                        'stream is not attached to session '
                            .. params.session_id
                end
                return {}
            end,
        }
        rex, calls = sandbox.fake(handlers)
        rex.session_id = 'session:caller'
        rex.block_id = 'block:caller'
        rex.args = { session_id = 'session:s1', block_id = 'block:b1' }
    end)

    it('returns the app that owns the caller Block', function()
        local ok, value = sandbox.run(script, rex)

        assert.is_true(ok, value)
        assert.are.same({ client_id = 'client:x' }, value)
    end)

    it(
        'selects the target Window and attaches before focusing its Block in the caller app',
        function()
            rex.args.window_id = 'window:w1'

            local ok, value = sandbox.run(script, rex)

            assert.is_true(ok, value)
            assert.are.same({
                {
                    method = 'size',
                    app = 'com.superlogical.terminal',
                    params = {
                        session_id = 'session:caller',
                        block_id = 'block:caller',
                    },
                },
                {
                    method = 'client.perform',
                    params = {
                        client_id = 'client:x',
                        action = 'session.select',
                        args = {
                            session_id = 'session:s1',
                            window_id = 'window:w1',
                        },
                    },
                },
                {
                    method = 'session.attach',
                    params = { session_id = 'session:s1' },
                },
                {
                    method = 'session.focus_block',
                    params = {
                        session_id = 'session:s1',
                        block_id = 'block:b1',
                    },
                },
            }, calls)
        end
    )

    it(
        'selects and attaches the Session before focusing a Block when no Window is given',
        function()
            local ok, value = sandbox.run(script, rex)

            assert.is_true(ok, value)
            assert.are.same({
                {
                    method = 'size',
                    app = 'com.superlogical.terminal',
                    params = {
                        session_id = 'session:caller',
                        block_id = 'block:caller',
                    },
                },
                {
                    method = 'client.perform',
                    params = {
                        client_id = 'client:x',
                        action = 'session.select',
                        args = { session_id = 'session:s1' },
                    },
                },
                {
                    method = 'session.attach',
                    params = { session_id = 'session:s1' },
                },
                {
                    method = 'session.focus_block',
                    params = {
                        session_id = 'session:s1',
                        block_id = 'block:b1',
                    },
                },
            }, calls)
        end
    )

    for _, case in ipairs({
        { name = 'missing' },
        { name = 'unknown', connection_state = 'unknown' },
    }) do
        it(
            'counts apps with ' .. case.name .. ' connection_state as connected',
            function()
                rex.session_id = nil
                rex.block_id = nil
                handlers['client.list'] = function()
                    return {
                        clients = {
                            {
                                client_id = 'client:app',
                                connection_state = case.connection_state,
                            },
                        },
                    }
                end

                local ok, value = sandbox.run(script, rex)

                assert.is_true(ok, value)
                assert.are.same({ client_id = 'client:app' }, value)
            end
        )
    end

    it('asks only for apps outside Rex and selects before focusing', function()
        rex.session_id = nil
        rex.block_id = nil

        local ok, value = sandbox.run(script, rex)

        assert.is_true(ok, value)
        assert.are.same({
            { method = 'client.list', params = { kinds = { 'app' } } },
            {
                method = 'client.perform',
                params = {
                    client_id = 'client:app',
                    action = 'session.select',
                    args = { session_id = 'session:s1' },
                },
            },
            {
                method = 'session.attach',
                params = { session_id = 'session:s1' },
            },
            {
                method = 'session.focus_block',
                params = { session_id = 'session:s1', block_id = 'block:b1' },
            },
        }, calls)
    end)

    it('focuses the connected app when another app is lost', function()
        rex.session_id = nil
        handlers['client.list'] = function()
            return {
                clients = {
                    { client_id = 'client:lost', connection_state = 'lost' },
                    { client_id = 'client:a', connection_state = 'connected' },
                },
            }
        end

        local ok, value = sandbox.run(script, rex)

        assert.is_true(ok, value)
        assert.are.same({ client_id = 'client:a' }, value)
        assert.are.same({
            method = 'client.perform',
            params = {
                client_id = 'client:a',
                action = 'session.select',
                args = { session_id = 'session:s1' },
            },
        }, calls[2])
    end)

    it('refuses two connected apps even when a third app is lost', function()
        rex.session_id = nil
        handlers['client.list'] = function()
            return {
                clients = {
                    { client_id = 'client:a', connection_state = 'connected' },
                    { client_id = 'client:lost', connection_state = 'lost' },
                    { client_id = 'client:b', connection_state = 'connected' },
                },
            }
        end

        local ok, message = sandbox.run(script, rex)

        assert.is_false(ok)
        assert.is_truthy(message:match('^several Rex apps are connected'))
        assert.are.same({
            { method = 'client.list', params = { kinds = { 'app' } } },
        }, calls)
    end)

    it('refuses to select a Session when only a lost app remains', function()
        rex.session_id = nil
        handlers['client.list'] = function()
            return {
                clients = {
                    { client_id = 'client:lost', connection_state = 'lost' },
                },
            }
        end

        local ok, message = sandbox.run(script, rex)

        assert.is_false(ok)
        assert.are.equal('no Rex app is connected', message)
        assert.are.same({
            { method = 'client.list', params = { kinds = { 'app' } } },
        }, calls)
    end)

    it('refuses to select a Session when no app is connected', function()
        rex.session_id = nil
        handlers['client.list'] = function()
            return { clients = {} }
        end

        local ok, message = sandbox.run(script, rex)

        assert.is_false(ok)
        assert.are.equal('no Rex app is connected', message)
        assert.are.same({
            { method = 'client.list', params = { kinds = { 'app' } } },
        }, calls)
    end)

    for _, case in ipairs({
        {
            name = 'the owner lookup raises',
            answer = function()
                error('size unavailable', 0)
            end,
        },
        {
            name = 'the owner lookup has no owner',
            answer = function()
                return {}
            end,
        },
    }) do
        it('falls back to the single app when ' .. case.name, function()
            handlers.size = case.answer

            local ok, value = sandbox.run(script, rex)

            assert.is_true(ok, value)
            assert.are.same({
                {
                    method = 'size',
                    app = 'com.superlogical.terminal',
                    params = {
                        session_id = 'session:caller',
                        block_id = 'block:caller',
                    },
                },
                { method = 'client.list', params = { kinds = { 'app' } } },
                {
                    method = 'client.perform',
                    params = {
                        client_id = 'client:app',
                        action = 'session.select',
                        args = { session_id = 'session:s1' },
                    },
                },
                {
                    method = 'session.attach',
                    params = { session_id = 'session:s1' },
                },
                {
                    method = 'session.focus_block',
                    params = {
                        session_id = 'session:s1',
                        block_id = 'block:b1',
                    },
                },
            }, calls)
        end)
    end

    it('falls back to the single app when the caller has no Block', function()
        rex.block_id = nil
        rex.args = { session_id = 'session:s1' }

        local ok, value = sandbox.run(script, rex)

        assert.is_true(ok, value)
        assert.are.same({
            { method = 'client.list', params = { kinds = { 'app' } } },
            {
                method = 'client.perform',
                params = {
                    client_id = 'client:app',
                    action = 'session.select',
                    args = { session_id = 'session:s1' },
                },
            },
        }, calls)
    end)

    it(
        'selects a Session alone without attaching or focusing a Block',
        function()
            rex.args = { session_id = 'session:s1' }

            local ok, value = sandbox.run(script, rex)

            assert.is_true(ok, value)
            assert.are.same({
                {
                    method = 'size',
                    app = 'com.superlogical.terminal',
                    params = {
                        session_id = 'session:caller',
                        block_id = 'block:caller',
                    },
                },
                {
                    method = 'client.perform',
                    params = {
                        client_id = 'client:x',
                        action = 'session.select',
                        args = { session_id = 'session:s1' },
                    },
                },
            }, calls)
        end
    )

    it('selects a Window without attaching or focusing a Block', function()
        rex.args = { session_id = 'session:s1', window_id = 'window:w1' }

        local ok, value = sandbox.run(script, rex)

        assert.is_true(ok, value)
        assert.are.same({
            {
                method = 'size',
                app = 'com.superlogical.terminal',
                params = {
                    session_id = 'session:caller',
                    block_id = 'block:caller',
                },
            },
            {
                method = 'client.perform',
                params = {
                    client_id = 'client:x',
                    action = 'session.select',
                    args = {
                        session_id = 'session:s1',
                        window_id = 'window:w1',
                    },
                },
            },
        }, calls)
    end)

    for _, case in ipairs({
        { name = 'missing args' },
        { name = 'a missing Session id', args = {} },
        { name = 'an empty Session id', args = { session_id = '' } },
        { name = 'a non-string Session id', args = { session_id = 7 } },
    }) do
        it('rejects ' .. case.name .. ' without calling Rex', function()
            rex.args = case.args

            local ok, message = sandbox.run(script, rex)

            assert.is_false(ok)
            assert.are.equal('session_id is required', message)
            assert.are.same({}, calls)
        end)
    end

    it('strips the stream response prefix from a failed selection', function()
        handlers['client.perform'] = function()
            return nil, 'stream response "x" failed: target not found'
        end

        local ok, message = sandbox.run(script, rex)

        assert.is_false(ok)
        assert.are.equal('target not found', message)
    end)

    it('does not focus a Block when Session selection fails', function()
        handlers['client.perform'] = function()
            return nil, 'Session is gone'
        end

        local ok, message = sandbox.run(script, rex)

        assert.is_false(ok)
        assert.are.equal('Session is gone', message)
        assert.are.same({
            {
                method = 'size',
                app = 'com.superlogical.terminal',
                params = {
                    session_id = 'session:caller',
                    block_id = 'block:caller',
                },
            },
            {
                method = 'client.perform',
                params = {
                    client_id = 'client:x',
                    action = 'session.select',
                    args = { session_id = 'session:s1' },
                },
            },
        }, calls)
    end)

    it('raises a stripped attach error without focusing a Block', function()
        handlers['session.attach'] = function()
            return nil, 'stream response "x" failed: Session is gone'
        end

        local ok, message = sandbox.run(script, rex)

        assert.is_false(ok)
        assert.are.equal('Session is gone', message)
        assert.are.same({
            {
                method = 'size',
                app = 'com.superlogical.terminal',
                params = {
                    session_id = 'session:caller',
                    block_id = 'block:caller',
                },
            },
            {
                method = 'client.perform',
                params = {
                    client_id = 'client:x',
                    action = 'session.select',
                    args = { session_id = 'session:s1' },
                },
            },
            {
                method = 'session.attach',
                params = { session_id = 'session:s1' },
            },
        }, calls)
    end)

    it('raises the message when focusing the Block fails', function()
        handlers['session.focus_block'] = function()
            return nil, 'Block is gone'
        end

        local ok, message = sandbox.run(script, rex)

        assert.is_false(ok)
        assert.are.equal('Block is gone', message)
    end)
end)
