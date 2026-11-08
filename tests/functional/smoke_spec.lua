-- `tools/smoke.lua` run as a child Neovim with the fake `rex` first on PATH.
-- The fake replays a prepared snapshot and records every call, so the spec
-- proves what smoke asked Rex for without a running Rex. Values are invented;
-- the snapshot of the throwaway Session is a copy of the committed fixture.

local helpers = require('tests.helpers')
local rex_stub = require('tests.rex_stub')

local root = helpers.root()
local smoke = root .. '/tools/smoke.lua'
local HOME = '/example/home'

local SESSION_ID = 'session:smoke'
local WINDOW_ID = 'window:smoke'
local BLOCK_ID = 'block:smoke'

-- The live snapshot the fake replays: the fixture, plus the Session, Window
-- and Block the canned home.lua reply names. The shape stays the fixture's, so
-- a run that changes nothing passes the comparison.
local function snapshot()
    local value = helpers.fixture('sample.json')
    local session = vim.deepcopy(value.sessions[1])
    local window = session.windows[1]
    session.id = SESSION_ID
    session.label = 'smoke'
    session.active_window_id = WINDOW_ID
    session.windows = { window }
    window.id = WINDOW_ID
    window.focused_block_id = BLOCK_ID
    window.blocks[1].id = BLOCK_ID
    value.sessions[#value.sessions + 1] = session
    return value
end

local function state()
    return {
        whoami = { rex_version = '0.0.0-example' },
        sessions = { { session_id = 'session:other', label = 'other' } },
        home = {
            session_id = SESSION_ID,
            window_id = WINDOW_ID,
            block_id = BLOCK_ID,
            created = 'session',
        },
        snapshot = snapshot(),
    }
end

-- Runs smoke in a child Neovim and returns the status and the text it printed.
-- `path` replaces PATH, so a test can hide `rex`.
local function run(stub, path)
    local result = vim.system({
        vim.v.progpath,
        '--headless',
        '--noplugin',
        '-l',
        smoke,
    }, {
        text = true,
        cwd = root,
        env = {
            PATH = path
                or (vim.fs.dirname(stub.bin) .. ':' .. (vim.env.PATH or '')),
            HOME = HOME,
        },
    }):wait()
    return {
        code = result.code,
        stdout = result.stdout or '',
        stderr = result.stderr or '',
    }
end

-- Every call the fake recorded, its argument list without the autostart flag.
local function commands(stub)
    local list = {}
    for _, argv in ipairs(stub.calls()) do
        local rest = {}
        for i = (argv[1] == '--autostart=false' and 2 or 1), #argv do
            rest[#rest + 1] = argv[i]
        end
        list[#list + 1] = rest
    end
    return list
end

---@param stub rexai.Stub
---@return string[][] the calls whose command is `kill`
local function kills(stub)
    local list = {}
    for _, argv in ipairs(commands(stub)) do
        if argv[1] == 'kill' then
            list[#list + 1] = argv
        end
    end
    return list
end

local function status()
    local result = vim.system({ 'git', '-C', root, 'status', '--porcelain' }, {
        text = true,
    }):wait()
    return result.stdout or ''
end

describe('tools/smoke.lua', function()
    local stub

    before_each(function()
        stub = rex_stub.install(state())
        stub.on_path()
    end)

    after_each(function()
        stub.remove()
    end)

    it('passes and kills the Session it created, by id', function()
        local before = status()

        local got = run(stub)

        assert.are.equal(0, got.code, got.stderr)
        assert.is_truthy(got.stdout:find('smoke: ok (', 1, true))
        assert.is_truthy(got.stdout:find('1 fixture', 1, true))
        assert.are.same(
            { { 'kill', SESSION_ID } },
            kills(stub),
            'the fake saw another kill'
        )
        assert.are.equal(before, status(), 'smoke wrote into the repository')
    end)

    it('carries --autostart=false on every call', function()
        run(stub)

        assert.is_true(#stub.calls() > 0)
        for _, argv in ipairs(stub.calls()) do
            assert.are.equal('--autostart=false', argv[1])
        end
    end)

    it('never focuses or selects anything', function()
        run(stub)

        for _, argv in ipairs(commands(stub)) do
            assert.are_not.equal('focus', argv[1])
            for _, word in ipairs(argv) do
                assert.is_nil(
                    word:find('focus', 1, true),
                    'smoke ran focus: ' .. table.concat(argv, ' ')
                )
                assert.is_nil(
                    word:find('select', 1, true),
                    'smoke ran select: ' .. table.concat(argv, ' ')
                )
                assert.is_nil(
                    word:find('attach', 1, true),
                    'smoke ran attach: ' .. table.concat(argv, ' ')
                )
            end
        end
    end)

    it('fails on a shape drift and still kills the Session', function()
        local drifted = snapshot()
        for _, session in ipairs(drifted.sessions) do
            for _, window in ipairs(session.windows or {}) do
                for _, block in ipairs(window.blocks or {}) do
                    block.process.child = nil
                end
            end
        end
        stub.set({ snapshot = drifted })

        local got = run(stub)

        assert.are.equal(1, got.code)
        assert.is_truthy(got.stderr:find('process.child', 1, true))
        assert.are.same({ { 'kill', SESSION_ID } }, kills(stub))
    end)

    it('fails without a kill when home.lua fails', function()
        stub.set({ home_fail = true })

        local got = run(stub)

        assert.are.equal(1, got.code)
        assert.is_truthy(got.stderr:find('home.lua', 1, true))
        assert.are.same({}, kills(stub))
    end)

    it('fails before creating anything when rex is missing', function()
        local empty = vim.fn.tempname()
        vim.fn.mkdir(empty, 'p')

        local got = run(stub, empty)

        vim.fn.delete(empty, 'rf')
        assert.are.equal(1, got.code)
        assert.is_truthy(got.stderr:find('PATH', 1, true))
        assert.are.same({}, stub.calls())
    end)

    it('fails and names the Session when the kill fails', function()
        stub.set({ kill_fail = true })

        local got = run(stub)

        assert.are.equal(1, got.code)
        assert.is_truthy(got.stderr:find(SESSION_ID, 1, true))
    end)
end)
