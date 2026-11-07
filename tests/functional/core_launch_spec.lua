-- Starting a new Agent block: the argv of an agent and the label of a new
-- Session. Both are pure, so the spec runs them through their API only.

local launch = require('rexai.core.launch')

describe('core.launch', function()
    describe('command', function()
        it('runs the agent under its own name by default', function()
            assert.are.same({ 'claude' }, launch.command('claude'))
            assert.are.same({ 'pi' }, launch.command('pi', {}))
        end)

        it('replaces the command with the argv of one agent', function()
            local map = {
                claude = { 'claude', '--continue' },
                pi = { 'pi', '--model', 'fast' },
            }

            assert.are.same(
                { 'claude', '--continue' },
                launch.command('claude', map)
            )
            assert.are.same(
                { 'pi', '--model', 'fast' },
                launch.command('pi', map)
            )
            -- An agent the map does not name keeps its own name.
            assert.are.same({ 'codex' }, launch.command('codex', map))
        end)

        it('ignores a value that is not a list of strings', function()
            local map = {
                empty = {},
                words = 'claude --continue',
                number = 3,
                mixed = { 'claude', true },
            }

            assert.are.same({ 'empty' }, launch.command('empty', map))
            assert.are.same({ 'words' }, launch.command('words', map))
            assert.are.same({ 'number' }, launch.command('number', map))
            assert.are.same({ 'mixed' }, launch.command('mixed', map))
        end)

        it('gives an argv of its own, so a caller may change it', function()
            local map = { claude = { 'claude', '--continue' } }

            local argv = launch.command('claude', map)
            argv[2] = '--resume'

            assert.are.same({ 'claude', '--continue' }, map.claude)
        end)
    end)

    describe('session_label', function()
        local home = '/Users/ana'

        it('uses the name the hook gave', function()
            assert.are.equal(
                'feature-42',
                launch.session_label('/work/tree/app', home, 'feature-42')
            )
        end)

        it('falls back to the two-last-directories rule', function()
            assert.are.equal(
                'tree_app',
                launch.session_label('/work/tree/app', home)
            )
            assert.are.equal(
                'tree_app',
                launch.session_label('/work/tree/app', home, '')
            )
            assert.are.equal(
                'tree_app',
                launch.session_label('/work/tree/app', home, 42)
            )
            assert.are.equal(
                'app',
                launch.session_label('/Users/ana/app', home, nil)
            )
        end)
    end)
end)
