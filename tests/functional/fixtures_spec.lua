local helpers = require('tests.helpers')

local anonymize = dofile(helpers.root() .. '/tools/anonymize.lua')

local function needles()
    local list = { vim.uv.os_homedir() or '' }
    local passwd = vim.uv.os_get_passwd() or {}
    list[#list + 1] = passwd.username or ''
    list[#list + 1] = os.getenv('USER') or ''
    return list
end

local function raw_sample()
    return {
        version = 1,
        sessions = {
            {
                id = 'session:aaaa-1111',
                label = 'secret-project',
                active_window_id = 'window:bbbb-2222',
                windows = {
                    {
                        id = 'window:bbbb-2222',
                        label = 'Window 2222',
                        focused_block_id = 'block:cccc-3333',
                        blocks = {
                            {
                                id = 'block:cccc-3333',
                                label = 'shell',
                                title = 'editing /home/someone/notes',
                                records = {
                                    {
                                        state = 'blocked',
                                        kind = 'permission',
                                        app = 'claude-code',
                                        effective_app = 'claude-code',
                                        msg = 'run rm -rf /home/someone?',
                                        updated_at = '2026-11-06T14:11:45.499979+01:00',
                                    },
                                },
                                process = {
                                    argv0 = '/home/someone/.local/bin/claude',
                                    name = 'claude',
                                    cwd = '/home/someone/code/secret',
                                    last_exit = {
                                        exit_code = 2,
                                        error = 'boom',
                                    },
                                    child = { name = 'zsh', path = '/bin/zsh' },
                                },
                            },
                        },
                    },
                    {
                        id = 'window:dddd-4444',
                        label = 'secret-project',
                        blocks = {},
                    },
                },
            },
        },
    }
end

describe('committed fixtures', function()
    local names = helpers.fixture_names()

    it('exist', function()
        assert.is_true(#names > 0)
    end)

    for _, name in ipairs(names) do
        describe(name, function()
            it(
                'contains neither the home directory nor the username',
                function()
                    local text = helpers.read('tests/fixtures/' .. name)
                    assert.are.same({}, anonymize.leaks(text, needles()))
                end
            )

            it('matches the whitelist', function()
                local snapshot = helpers.fixture(name)
                assert.are.same({}, anonymize.validate(snapshot))
            end)
        end)
    end
end)

describe('anonymize.anonymize', function()
    local result

    before_each(function()
        result = anonymize.anonymize(raw_sample())
    end)

    it('passes validation', function()
        assert.are.same({}, anonymize.validate(result))
    end)

    it('keeps structure, state, kind, app and timestamps', function()
        local block = result.sessions[1].windows[1].blocks[1]
        local record = block.records[1]
        assert.are.equal('blocked', record.state)
        assert.are.equal('permission', record.kind)
        assert.are.equal('claude-code', record.app)
        assert.are.equal('2026-11-06T14:11:45.499979+01:00', record.updated_at)
        assert.are.equal(2, block.process.last_exit.exit_code)
    end)

    it('replaces every free-text field', function()
        local text = anonymize.encode(result)
        assert.are.same({}, anonymize.leaks(text, { 'someone', 'secret' }))
        assert.are.same({}, anonymize.leaks(text, { 'rm -rf', 'boom' }))
    end)

    it(
        'keeps the directory shape of argv0 but drops its directories',
        function()
            local process = result.sessions[1].windows[1].blocks[1].process
            assert.are.equal('/opt/bin/claude', process.argv0)
        end
    )

    it('keeps the default Window label shape', function()
        local window = result.sessions[1].windows[1]
        assert.is_truthy(window.label:match('^Window %x+$'))
    end)

    it('keeps ids consistent across references', function()
        local session = result.sessions[1]
        local window = session.windows[1]
        assert.are.equal(window.id, session.active_window_id)
        assert.are.equal(window.blocks[1].id, window.focused_block_id)
    end)

    it('is deterministic', function()
        local again = anonymize.anonymize(raw_sample())
        assert.are.equal(anonymize.encode(result), anonymize.encode(again))
    end)
end)

describe('anonymize.validate', function()
    it('rejects an unknown key', function()
        local snapshot = anonymize.anonymize(raw_sample())
        snapshot.sessions[1].path = '/somewhere'
        assert.is_true(#anonymize.validate(snapshot) > 0)
    end)

    it('rejects a value that is not a placeholder', function()
        local snapshot = anonymize.anonymize(raw_sample())
        snapshot.sessions[1].windows[1].blocks[1].title = 'real title'
        assert.is_true(#anonymize.validate(snapshot) > 0)
    end)

    it('rejects an unknown status state', function()
        local snapshot = anonymize.anonymize(raw_sample())
        snapshot.sessions[1].windows[1].blocks[1].records[1].state = 'sleeping'
        assert.is_true(#anonymize.validate(snapshot) > 0)
    end)
end)

describe('anonymize.leaks', function()
    it('finds a needle and ignores an empty one', function()
        local found = anonymize.leaks('path /home/someone/x', { '', 'someone' })
        assert.are.same({ 'someone' }, found)
    end)
end)

describe('anonymize.encode', function()
    it('round-trips through the JSON decoder with sorted keys', function()
        local value = { b = 1, a = { 'x', 'y' }, c = {} }
        local text = anonymize.encode(value)
        assert.is_true(text:find('"a"', 1, true) < text:find('"b"', 1, true))
        assert.are.same(value, vim.json.decode(text))
    end)
end)
