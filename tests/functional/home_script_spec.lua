local helpers = require('tests.helpers')
local sandbox = require('tests.sandbox')

local script = helpers.root() .. '/scripts/home.lua'

local BLOCK = 'com.superlogical.terminal.shell'

-- The layout of the dashboard Window: one Block that runs the Dashboard.
local function layout(cwd)
    return {
        block = {
            flavor = BLOCK,
            options = {
                command = { 'nvim', '+Rexai' },
                cwd = cwd,
            },
        },
    }
end

local function window(id, label, blocks)
    return {
        window_id = id,
        label = label,
        layers = { { blocks = blocks } },
    }
end

describe('home.lua', function()
    local rex, calls, handlers, sessions, views, created, saved_home

    before_each(function()
        saved_home = vim.env.HOME
        vim.env.HOME = '/example/home'
        sessions = { { session_id = 'session:s1', label = 'rexai' } }
        views = {
            ['session:s1'] = {
                active_window_id = 'window:w1',
                windows = {
                    window('window:w1', 'dashboard', {
                        {
                            block_id = 'block:b1',
                            label = 'Dashboard',
                            flavor = BLOCK,
                        },
                    }),
                },
            },
        }
        created = {
            session = {
                session_id = 'session:new',
                initial_windows = {
                    {
                        window_id = 'window:new',
                        block_ids = { 'block:new' },
                        revision = 1,
                    },
                },
            },
            window = {
                window_id = 'window:new',
                block_ids = { 'block:new' },
                revision = 2,
            },
        }
        handlers = {
            ['session.list'] = function()
                return { sessions = sessions }
            end,
            ['session.attach'] = function()
                return {}
            end,
            ['session.view'] = function(params)
                return views[params.session_id]
            end,
            ['session.create'] = function()
                return created.session
            end,
            ['session.new_window'] = function()
                return created.window
            end,
        }
        rex, calls = sandbox.fake(handlers)
        rex.args = { name = 'rexai', cwd = '/example/work' }
    end)

    after_each(function()
        vim.env.HOME = saved_home
    end)

    it('returns the existing Session, Window and Block', function()
        local ok, value = sandbox.run(script, rex)

        assert.is_true(ok, value)
        assert.are.same({
            session_id = 'session:s1',
            window_id = 'window:w1',
            block_id = 'block:b1',
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
        'creates the Session with a dashboard Window when none has the label',
        function()
            sessions = { { session_id = 'session:other', label = 'other' } }

            local ok, value = sandbox.run(script, rex)

            assert.is_true(ok, value)
            assert.are.same({
                session_id = 'session:new',
                window_id = 'window:new',
                block_id = 'block:new',
                created = 'session',
            }, value)
            assert.are.same({
                { method = 'session.list' },
                {
                    method = 'session.create',
                    params = {
                        label = 'rexai',
                        initial_windows = {
                            {
                                window_label = 'dashboard',
                                layout = layout('/example/work'),
                            },
                        },
                    },
                },
            }, calls)
        end
    )

    it(
        'adds only the Window when the Session has no dashboard Window',
        function()
            views['session:s1'].windows = {
                window('window:w2', 'other', {
                    { block_id = 'block:b2', label = 'Other' },
                }),
            }

            local ok, value = sandbox.run(script, rex)

            assert.is_true(ok, value)
            assert.are.same({
                session_id = 'session:s1',
                window_id = 'window:new',
                block_id = 'block:new',
                created = 'window',
            }, value)
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
                    method = 'session.new_window',
                    params = {
                        session_id = 'session:s1',
                        window_label = 'dashboard',
                        layout = layout('/example/work'),
                    },
                },
            }, calls)
        end
    )

    it('does not reuse a dashboard Window of another Session', function()
        sessions = {
            { session_id = 'session:s1', label = 'rexai' },
            { session_id = 'session:other', label = 'other' },
        }
        views['session:s1'].windows = {
            window('window:w2', 'other', {
                { block_id = 'block:b2', label = 'Other' },
            }),
        }
        views['session:other'] = {
            active_window_id = 'window:w9',
            windows = {
                window('window:w9', 'dashboard', {
                    { block_id = 'block:b9', label = 'Other Dashboard' },
                }),
            },
        }

        local ok, value = sandbox.run(script, rex)

        assert.is_true(ok, value)
        assert.are.equal('window:new', value.window_id)
        assert.are.same({
            method = 'session.new_window',
            params = {
                session_id = 'session:s1',
                window_label = 'dashboard',
                layout = layout('/example/work'),
            },
        }, calls[#calls])
    end)

    it(
        'does not reuse a Session whose label only starts with the name',
        function()
            sessions =
                { { session_id = 'session:longer', label = 'rexai-two' } }

            local ok, value = sandbox.run(script, rex)

            assert.is_true(ok, value)
            assert.are.same('session:new', value.session_id)
            assert.are.same('rexai', calls[2].params.label)
        end
    )

    it(
        'does not reuse a Window whose label only starts with dashboard',
        function()
            views['session:s1'].windows = {
                window('window:w2', 'dashboard-old', {
                    { block_id = 'block:b2', label = 'Old' },
                }),
            }

            local ok, value = sandbox.run(script, rex)

            assert.is_true(ok, value)
            assert.are.same('window:new', value.window_id)
            assert.are.same('dashboard', calls[#calls].params.window_label)
        end
    )

    it('uses the first Session that has the label', function()
        sessions = {
            { session_id = 'session:a', label = 'rexai' },
            { session_id = 'session:b', label = 'rexai' },
        }
        for _, id in ipairs({ 'session:a', 'session:b' }) do
            views[id] = {
                active_window_id = 'window:' .. id,
                windows = {
                    window('window:' .. id, 'other', {
                        { block_id = 'block:' .. id, label = 'Other' },
                    }),
                },
            }
        end

        local ok, value = sandbox.run(script, rex)

        assert.is_true(ok, value)
        assert.are.equal('session:a', value.session_id)
        assert.are.same({
            method = 'session.new_window',
            params = {
                session_id = 'session:a',
                window_label = 'dashboard',
                layout = layout('/example/work'),
            },
        }, calls[#calls])
    end)

    it('uses the first Window that has the label', function()
        views['session:s1'].windows = {
            window('window:first', 'dashboard', {
                { block_id = 'block:first', label = 'First' },
            }),
            window('window:second', 'dashboard', {
                { block_id = 'block:second', label = 'Second' },
            }),
        }

        local ok, value = sandbox.run(script, rex)

        assert.is_true(ok, value)
        assert.are.same('window:first', value.window_id)
        assert.are.same('block:first', value.block_id)
        assert.is_nil(value.created)
    end)

    it('reads the first Block of the Window across its layers', function()
        views['session:s1'].windows = {
            {
                window_id = 'window:w1',
                label = 'dashboard',
                layers = {
                    {
                        blocks = {
                            { block_id = 'block:b1', label = 'First' },
                            { block_id = 'block:b2', label = 'Second' },
                        },
                    },
                    {
                        blocks = { { block_id = 'block:b3', label = 'Third' } },
                    },
                },
            },
        }

        local ok, value = sandbox.run(script, rex)

        assert.is_true(ok, value)
        assert.are.same('block:b1', value.block_id)
    end)

    it('reads the Block that runs Neovim when the Window holds more', function()
        views['session:s1'].windows = {
            window('window:w1', 'dashboard', {
                { block_id = 'block:b1', label = 'Shell', flavor = BLOCK },
                { block_id = 'block:b2', label = 'Dashboard', flavor = BLOCK },
            }),
        }
        handlers['process'] = function(params)
            local argv0 = params.block_id == 'block:b2' and 'nvim' or '-zsh'
            return { foreground = { argv0 = argv0 } }
        end

        local ok, value = sandbox.run(script, rex)

        assert.is_true(ok, value)
        assert.are.same('block:b2', value.block_id)
    end)

    it('falls back to the first Block when none runs Neovim', function()
        views['session:s1'].windows = {
            window('window:w1', 'dashboard', {
                { block_id = 'block:b1', label = 'First', flavor = BLOCK },
                { block_id = 'block:b2', label = 'Second', flavor = BLOCK },
            }),
        }
        handlers['process'] = function()
            return { foreground = { argv0 = '-zsh' } }
        end

        local ok, value = sandbox.run(script, rex)

        assert.is_true(ok, value)
        assert.are.same('block:b1', value.block_id)
    end)

    it('reads a name Rex typed as a number as a string', function()
        sessions = { { session_id = 'session:s2', label = '2' } }
        views['session:s2'] = {
            active_window_id = 'window:w2',
            windows = {
                window('window:w2', 'dashboard', {
                    { block_id = 'block:b2', label = 'Dashboard' },
                }),
            },
        }
        rex.args = { name = 2, cwd = '/example/work' }

        local ok, value = sandbox.run(script, rex)

        assert.is_true(ok, value)
        assert.are.same('session:s2', value.session_id)
    end)

    it('creates a Session labelled with the number Rex typed', function()
        sessions = {}
        rex.args = { name = 2, cwd = '/example/work' }

        local ok, value = sandbox.run(script, rex)

        assert.is_true(ok, value)
        assert.are.same('2', calls[2].params.label)
    end)

    it('falls back to rexai and HOME when Rex passes no argument', function()
        sessions = {}
        rex.args = {}

        local ok, value = sandbox.run(script, rex)

        assert.is_true(ok, value)
        assert.are.same({
            label = 'rexai',
            initial_windows = {
                {
                    window_label = 'dashboard',
                    layout = layout('/example/home'),
                },
            },
        }, calls[2].params)
        assert.are.same('session:new', value.session_id)
    end)

    it('requires cwd when it cannot read HOME', function()
        vim.env.HOME = nil
        rex.args = { name = 'rexai' }

        local ok, message = sandbox.run(script, rex)

        assert.is_false(ok)
        assert.are.equal('cwd is required when HOME is unset', message)
        assert.are.same({}, calls)
    end)

    it('reports a Rex error as its message', function()
        handlers['session.list'] = function()
            return nil, 'stream response "x" failed: server is busy'
        end

        local ok, message = sandbox.run(script, rex)

        assert.is_false(ok)
        assert.are.equal('server is busy', message)
        assert.are.same({ { method = 'session.list' } }, calls)
    end)

    it('reports a failing attach or view as its message', function()
        handlers['session.view'] = function()
            return nil, 'stream response "x" failed: Session is gone'
        end

        local ok, message = sandbox.run(script, rex)

        assert.is_false(ok)
        assert.are.equal('Session is gone', message)
    end)

    it('reports a create that Rex did not describe', function()
        sessions = {}
        created.session = { session_id = 'session:new' }

        local ok, message = sandbox.run(script, rex)

        assert.is_false(ok)
        assert.are.equal('Rex did not describe the Session it created', message)
    end)

    it('reports a new Window that Rex did not describe', function()
        views['session:s1'].windows = {}
        created.window = { window_id = 'window:new' }

        local ok, message = sandbox.run(script, rex)

        assert.is_false(ok)
        assert.are.equal('Rex did not describe the Window it created', message)
    end)

    it('reports a dashboard Window with no Block', function()
        views['session:s1'].windows = { window('window:w1', 'dashboard', {}) }

        local ok, message = sandbox.run(script, rex)

        assert.is_false(ok)
        assert.are.equal('the dashboard Window has no Block', message)
    end)
end)
