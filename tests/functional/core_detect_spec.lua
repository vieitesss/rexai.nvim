local detect = require('rexai.core.detect')

local agents = {
    apps = { 'claude-code', 'pi' },
    commands = { 'claude', 'codex' },
}

describe('core.detect', function()
    describe('basename', function()
        local cases = {
            { '/usr/local/bin/claude', 'claude' },
            { 'claude', 'claude' },
            { '/opt/some dir/bin/pi', 'pi' },
            { '/trailing/', '/trailing/' },
            { '', '' },
        }
        for _, case in ipairs(cases) do
            local path, expected = case[1], case[2]
            it('takes the last component of "' .. path .. '"', function()
                assert.are.equal(expected, detect.basename(path))
            end)
        end
    end)

    describe('harness', function()
        local cases = {
            {
                name = 'a record from a listed app',
                block = { records = { { app = 'pi', state = 'idle' } } },
                expected = 'pi',
            },
            {
                name = 'a record from an app that is not listed',
                block = { records = { { app = 'vim', state = 'idle' } } },
                expected = nil,
            },
            {
                name = 'a listed command with an absolute path',
                block = {
                    records = {},
                    process = { argv0 = '/opt/bin/claude' },
                },
                expected = 'claude',
            },
            {
                name = 'a listed command by its basename',
                block = { process = { argv0 = 'codex' } },
                expected = 'codex',
            },
            {
                name = 'a command that is not listed',
                block = { process = { argv0 = '/usr/bin/nvim' } },
                expected = nil,
            },
            {
                name = 'a block with no process and no records',
                block = {},
                expected = nil,
            },
            {
                name = 'an empty argv0',
                block = { process = { argv0 = '' } },
                expected = nil,
            },
            {
                name = 'the app over the command',
                block = {
                    records = { { app = 'claude-code', state = 'working' } },
                    process = { argv0 = '/opt/bin/claude' },
                },
                expected = 'claude-code',
            },
            {
                name = 'the command when the app is not listed',
                block = {
                    records = { { app = 'vim', state = 'working' } },
                    process = { argv0 = 'codex' },
                },
                expected = 'codex',
            },
            {
                name = 'the first listed app among several records',
                block = {
                    records = {
                        { app = 'vim', state = 'idle' },
                        { app = 'claude-code', state = 'idle' },
                    },
                },
                expected = 'claude-code',
            },
        }
        for _, case in ipairs(cases) do
            it('handles ' .. case.name, function()
                assert.are.equal(
                    case.expected,
                    detect.harness(case.block, agents)
                )
            end)
        end

        it('finds nothing when no apps or commands are configured', function()
            local block = {
                records = { { app = 'pi', state = 'idle' } },
                process = { argv0 = 'claude' },
            }
            assert.is_nil(detect.harness(block, {}))
        end)

        it('follows a configuration that adds an agent', function()
            local block = { process = { argv0 = '/bin/opencode' } }
            assert.is_nil(detect.harness(block, agents))
            local extended = { commands = { 'opencode' } }
            assert.are.equal('opencode', detect.harness(block, extended))
        end)
    end)
end)
