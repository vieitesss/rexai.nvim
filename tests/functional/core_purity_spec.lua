-- The core must run in Neovim (LuaJIT) and in Rex (Lua 5.1, no `vim`). This
-- spec loads it in a sandbox with only the Lua 5.1 standard library. Reaching
-- for any other global is an error, so `vim` cannot slip in unnoticed.
--
-- Covered: everything under `lua/rexai/core`, plus the Backend interface and
-- the fake Backend. The Rex Backend talks to Neovim and is not pure.

local helpers = require('tests.helpers')
local model_api = require('rexai.core.model')
local fake_api = require('rexai.backend.fake')
local snap = require('tests.snapshots')

local STD_FUNCTIONS = {
    'assert',
    'error',
    'getmetatable',
    'ipairs',
    'next',
    'pairs',
    'pcall',
    'rawequal',
    'rawget',
    'rawset',
    'select',
    'setmetatable',
    'tonumber',
    'tostring',
    'type',
    'unpack',
    'xpcall',
}
local STD_LIBRARIES = { 'math', 'string', 'table' }

local PURE_BACKEND_MODULES = { 'rexai.backend', 'rexai.backend.fake' }

local function copy_table(source)
    local out = {}
    for key, value in pairs(source) do
        out[key] = value
    end
    return out
end

local function module_path(name)
    local base = helpers.root() .. '/lua/' .. (name:gsub('%.', '/'))
    for _, candidate in ipairs({ base .. '.lua', base .. '/init.lua' }) do
        if vim.uv.fs_stat(candidate) then
            return candidate
        end
    end
    error('module not found: ' .. name)
end

local function new_sandbox()
    local env = {}
    for _, name in ipairs(STD_FUNCTIONS) do
        env[name] = _G[name]
    end
    for _, name in ipairs(STD_LIBRARIES) do
        env[name] = copy_table(_G[name])
    end

    local loaded = {}
    function env.require(name)
        if not name:match('^rexai%.') then
            error('the core may only require rexai modules, not ' .. name)
        end
        if loaded[name] == nil then
            local chunk = assert(loadfile(module_path(name)))
            setfenv(chunk, env)
            loaded[name] = chunk(name) or true
        end
        return loaded[name]
    end

    setmetatable(env, {
        __index = function(_, key)
            error('the core read the global "' .. tostring(key) .. '"', 2)
        end,
        __newindex = function(_, key)
            error('the core set the global "' .. tostring(key) .. '"', 2)
        end,
    })
    return env
end

local function core_modules()
    local names = {}
    local dir = helpers.root() .. '/lua/rexai/core'
    for file, kind in vim.fs.dir(dir) do
        if kind == 'file' and file:match('%.lua$') then
            names[#names + 1] = 'rexai.core.' .. file:gsub('%.lua$', '')
        end
    end
    table.sort(names)
    return names
end

local function pure_modules()
    local names = core_modules()
    for _, name in ipairs(PURE_BACKEND_MODULES) do
        names[#names + 1] = name
    end
    return names
end

describe('core purity', function()
    it('finds the core modules', function()
        assert.is_true(#core_modules() >= 5)
    end)

    describe('the sandbox', function()
        it('rejects a read of vim', function()
            local env = new_sandbox()
            local chunk = assert(loadstring('return vim'))
            setfenv(chunk, env)
            local ok, err = pcall(chunk)
            assert.is_false(ok)
            assert.matches('global "vim"', err)
        end)

        it('rejects a global that is set', function()
            local env = new_sandbox()
            local chunk = assert(loadstring('leaked = 1'))
            setfenv(chunk, env)
            local ok, err = pcall(chunk)
            assert.is_false(ok)
            assert.matches('global "leaked"', err)
        end)

        it('rejects a module outside rexai', function()
            local env = new_sandbox()
            local ok, err = pcall(env.require, 'plenary.test_harness')
            assert.is_false(ok)
            assert.matches('may only require rexai', err)
        end)
    end)

    describe('loading', function()
        for _, name in ipairs(pure_modules()) do
            it(name .. ' loads with only the standard library', function()
                local env = new_sandbox()
                local ok, err = pcall(env.require, name)
                assert.is_true(ok, tostring(err))
            end)
        end
    end)

    describe('running', function()
        local agents = {
            apps = { 'claude-code', 'pi' },
            commands = { 'claude', 'codex', 'opencode', 'pi' },
        }

        for _, fixture in ipairs(helpers.fixture_names()) do
            it('builds the model of ' .. fixture .. ' as outside', function()
                local snapshot = helpers.fixture(fixture)
                local env = new_sandbox()

                local inside = env.require('rexai.core.model').build(
                    snapshot,
                    agents,
                    env.require('rexai.core.model').new_memory()
                )
                local outside =
                    model_api.build(snapshot, agents, model_api.new_memory())
                assert.are.same(outside, inside)
            end)
        end

        it('follows an agent to exited as outside', function()
            local live = snap.single(
                { id = 'block:b1', app = 'pi', state = 'working' },
                'work'
            )
            local gone =
                snap.single({ id = 'block:b1', argv0 = '/bin/zsh' }, 'work')

            local env = new_sandbox()
            local inner = env.require('rexai.core.model')
            local inner_memory = inner.new_memory()
            inner.build(live, agents, inner_memory)
            local inside = inner.build(gone, agents, inner_memory)

            local outer_memory = model_api.new_memory()
            model_api.build(live, agents, outer_memory)
            local outside = model_api.build(gone, agents, outer_memory)

            assert.are.equal('exited', inside[1].rows[1].status)
            assert.are.same(outside, inside)
        end)

        it('serves the fake Backend with only the standard library', function()
            local env = new_sandbox()
            local backend = env.require('rexai.backend.fake').new({
                snapshots = { snap.single({ id = 'block:b1', app = 'pi' }) },
            })

            local got
            backend.snapshot(function(err, snapshot)
                got = { err = err, snapshot = snapshot }
            end)
            assert.is_nil(got.err)
            assert.are.equal('session:s1', got.snapshot.sessions[1].id)

            -- The fake Backend and the outside one agree.
            local outside = fake_api.new({
                snapshots = { snap.single({ id = 'block:b1', app = 'pi' }) },
            })
            local expected
            outside.snapshot(function(_, snapshot)
                expected = snapshot
            end)
            assert.are.same(expected, got.snapshot)
        end)
    end)

    describe('source text', function()
        local FORBIDDEN = {
            { '%f[%w_]vim%f[^%w_]', 'the vim global' },
            { '%f[%w_]goto%f[^%w_]', 'goto (Lua 5.2)' },
            { '//', 'integer division (Lua 5.3)' },
            { '<<', 'a shift operator (Lua 5.3)' },
            { '>>', 'a shift operator (Lua 5.3)' },
            { '%f[%w_]bit32?%.', 'a bit library' },
            { '%f[%w_]utf8%.', 'the utf8 library (Lua 5.3)' },
            { '%f[%w_]io%.', 'the io library' },
            { '%f[%w_]os%.', 'the os library' },
        }

        for _, name in ipairs(pure_modules()) do
            it(name .. ' uses only Lua 5.1 and no host API', function()
                local file = assert(io.open(module_path(name), 'r'))
                local text = file:read('*a')
                file:close()
                local code = text:gsub('%-%-[^\n]*', '')
                for _, rule in ipairs(FORBIDDEN) do
                    assert.is_nil(
                        code:find(rule[1]),
                        name .. ' uses ' .. rule[2]
                    )
                end
            end)
        end
    end)
end)
