-- The git slot text: `git status --porcelain=v2 --branch` in, one short
-- string out. Every sample here is written by hand with invented names.

local git = require('rexai.core.git')

describe('core.git', function()
    describe('parse_status', function()
        local HEADERS = table.concat({
            '# branch.oid 1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b',
            '# branch.head main',
            '# branch.upstream origin/main',
            '# branch.ab +0 -0',
        }, '\n') .. '\n'

        local cases = {
            {
                name = 'a clean branch with nothing to report',
                text = HEADERS,
                want = {
                    branch = 'main',
                    oid = '1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b',
                    detached = false,
                    ahead = 0,
                    behind = 0,
                    changed = 0,
                },
            },
            {
                name = 'an empty string',
                text = '',
                want = {
                    branch = nil,
                    oid = nil,
                    detached = false,
                    ahead = 0,
                    behind = 0,
                    changed = 0,
                },
            },
            {
                name = 'text that is not git output',
                text = 'fatal: not a git repository\n',
                want = {
                    branch = nil,
                    oid = nil,
                    detached = false,
                    ahead = 0,
                    behind = 0,
                    changed = 0,
                },
            },
            {
                name = 'a detached HEAD',
                text = table.concat({
                    '# branch.oid 9f8e7d6c5b4a39281706f5e4d3c2b1a09f8e7d6c',
                    '# branch.head (detached)',
                }, '\n'),
                want = {
                    branch = nil,
                    oid = '9f8e7d6c5b4a39281706f5e4d3c2b1a09f8e7d6c',
                    detached = true,
                    ahead = 0,
                    behind = 0,
                    changed = 0,
                },
            },
            {
                name = 'a branch with no commit yet',
                text = table.concat({
                    '# branch.oid (initial)',
                    '# branch.head main',
                }, '\n'),
                want = {
                    branch = 'main',
                    oid = nil,
                    detached = false,
                    ahead = 0,
                    behind = 0,
                    changed = 0,
                },
            },
            {
                name = 'a branch with no upstream',
                text = table.concat({
                    '# branch.oid 1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b',
                    '# branch.head feature/parser',
                    '1 .M N... 100644 100644 100644 old new src/parser.lua',
                    '? notes.md',
                }, '\n'),
                want = {
                    branch = 'feature/parser',
                    oid = '1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b',
                    detached = false,
                    ahead = 0,
                    behind = 0,
                    changed = 2,
                },
            },
            {
                name = 'every kind of entry, with ignored files left out',
                text = table.concat({
                    '# branch.oid 1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b',
                    '# branch.head feature/parser',
                    '# branch.upstream origin/feature/parser',
                    '# branch.ab +2 -1',
                    '1 .M N... 100644 100644 100644 old new src/parser.lua',
                    '1 M. N... 100644 100644 100644 old new src/tokens.lua',
                    '2 R. N... 100644 100644 100644 h1 h2 R100 src/new.lua\tsrc/old.lua',
                    'u UU N... 100644 100644 100644 100644 h1 h2 h3 conflict.lua',
                    '? notes.md',
                    '! build/output.log',
                }, '\n'),
                want = {
                    branch = 'feature/parser',
                    oid = '1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b',
                    detached = false,
                    ahead = 2,
                    behind = 1,
                    changed = 5,
                },
            },
            {
                name = 'garbage counts',
                text = '# branch.ab +x -y\n# branch.head main\n',
                want = {
                    branch = 'main',
                    oid = nil,
                    detached = false,
                    ahead = 0,
                    behind = 0,
                    changed = 0,
                },
            },
            {
                name = 'carriage returns',
                text = '# branch.oid (initial)\r\n# branch.head main\r\n',
                want = {
                    branch = 'main',
                    oid = nil,
                    detached = false,
                    ahead = 0,
                    behind = 0,
                    changed = 0,
                },
            },
        }

        for _, case in ipairs(cases) do
            it('reads ' .. case.name, function()
                assert.are.same(case.want, git.parse_status(case.text))
            end)
        end

        it('reads a header with no value as missing', function()
            local info = git.parse_status('# branch.head\n? notes.md\n')
            assert.is_nil(info.branch)
            assert.are.equal(1, info.changed)
        end)
    end)

    describe('format', function()
        local cases = {
            {
                name = 'a clean branch',
                info = {
                    repo = 'orbit',
                    branch = 'main',
                    ahead = 0,
                    behind = 0,
                    changed = 0,
                },
                want = 'orbit · main',
            },
            {
                name = 'changed paths',
                info = {
                    repo = 'orbit',
                    branch = 'main',
                    ahead = 0,
                    behind = 0,
                    changed = 3,
                },
                want = 'orbit · main ●3',
            },
            {
                name = 'commits ahead',
                info = {
                    repo = 'orbit',
                    branch = 'main',
                    ahead = 1,
                    behind = 0,
                    changed = 3,
                },
                want = 'orbit · main ↑1 ●3',
            },
            {
                name = 'commits behind',
                info = {
                    repo = 'orbit',
                    branch = 'main',
                    ahead = 0,
                    behind = 2,
                    changed = 0,
                },
                want = 'orbit · main ↓2',
            },
            {
                name = 'ahead and behind and changed',
                info = {
                    repo = 'orbit',
                    branch = 'feature/parser',
                    ahead = 2,
                    behind = 1,
                    changed = 12,
                },
                want = 'orbit · feature/parser ↑2 ↓1 ●12',
            },
            {
                name = 'a detached HEAD',
                info = {
                    repo = 'orbit',
                    branch = nil,
                    oid = '9f8e7d6c5b4a39281706f5e4d3c2b1a09f8e7d6c',
                    detached = true,
                    ahead = 0,
                    behind = 0,
                    changed = 0,
                },
                want = 'orbit · 9f8e7d6',
            },
            {
                name = 'a branch with no commit yet',
                info = {
                    repo = 'orbit',
                    branch = 'main',
                    oid = nil,
                    detached = false,
                    ahead = 0,
                    behind = 0,
                    changed = 0,
                },
                want = 'orbit · main',
            },
            {
                name = 'no branch at all',
                info = {
                    repo = 'orbit',
                    ahead = 0,
                    behind = 0,
                    changed = 2,
                },
                want = 'orbit ●2',
            },
            {
                name = 'no information at all',
                info = { repo = 'orbit', ahead = 0, behind = 0, changed = 0 },
                want = 'orbit',
            },
        }

        for _, case in ipairs(cases) do
            it('writes ' .. case.name, function()
                assert.are.equal(case.want, git.format(case.info))
            end)
        end

        it('writes the parse of a real status', function()
            local info = git.parse_status(table.concat({
                '# branch.oid 1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b',
                '# branch.head feature/parser',
                '# branch.upstream origin/feature/parser',
                '# branch.ab +2 -1',
                '1 .M N... 100644 100644 100644 old new src/parser.lua',
                '? notes.md',
            }, '\n'))
            info.repo = 'orbit'

            assert.are.equal(
                'orbit · feature/parser ↑2 ↓1 ●2',
                git.format(info)
            )
        end)
    end)
end)
