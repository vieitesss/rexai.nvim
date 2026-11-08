-- `:checkhealth rexai` through the fake `rex` first on PATH. The spec replaces
-- the `vim.health` reporters with recorders, so it checks what the user reads
-- without running `:checkhealth`.

local config = require('rexai.config')
local health = require('rexai.health')
local helpers = require('tests.helpers')
local rex_stub = require('tests.rex_stub')
local snap = require('tests.snapshots')

local LEVELS = { 'start', 'ok', 'warn', 'error', 'info' }

-- Everything the module reports, in order: `{ level = 'ok', text, advice }`.
local function record_health()
    local calls = {}
    local saved = {}

    for _, level in ipairs(LEVELS) do
        saved[level] = vim.health[level]
        vim.health[level] = function(text, ...)
            calls[#calls + 1] = { level = level, text = text, ... }
        end
    end

    local function restore()
        for _, level in ipairs(LEVELS) do
            vim.health[level] = saved[level]
        end
    end

    return calls, restore
end

---@param calls table[]
---@param level string
---@return table[] the calls with this level
local function of(calls, level)
    local list = {}
    for _, call in ipairs(calls) do
        if call.level == level then
            list[#list + 1] = call
        end
    end
    return list
end

-- The one call with this level; a second one fails the test.
---@param calls table[]
---@param level string
---@return table
local function only(calls, level)
    local list = of(calls, level)
    assert.are.equal(1, #list, 'expected one ' .. level .. ' message')
    return list[1]
end

-- The first call with this level whose text matches; none fails the test.
---@param calls table[]
---@param level string
---@param pattern string
---@return table
local function matching(calls, level, pattern)
    for _, call in ipairs(of(calls, level)) do
        if call.text:find(pattern) then
            return call
        end
    end
    return assert.fail('no ' .. level .. ' message matching ' .. pattern)
end

local function write_executable(dir, name)
    local file = assert(io.open(dir .. '/' .. name, 'w'))
    file:write('#!/bin/sh\nexit 0\n')
    file:close()
    vim.uv.fs_chmod(dir .. '/' .. name, tonumber('755', 8))
end

local APP = { client_id = 'client:one', info = { kind = 'app' } }
local OTHER_APP = { client_id = 'client:two', info = { kind = 'app' } }

local saved_env, stub, bin_dir, calls, restore_health

---@param name string a fake executable `git` or `rexai`
local function fake(name)
    write_executable(bin_dir, name)
end

local function remove_fake(name)
    vim.uv.fs_unlink(bin_dir .. '/' .. name)
end

describe('health.check', function()
    before_each(function()
        saved_env = {
            PATH = vim.env.PATH,
            REX_BLOCK = vim.env.REX_BLOCK,
            REX_SESSION = vim.env.REX_SESSION,
        }
        bin_dir = vim.fn.tempname()
        vim.fn.mkdir(bin_dir, 'p')

        stub = rex_stub.install({
            snapshot = snap.single({
                id = 'block:b1',
                app = 'pi',
                state = 'idle',
            }),
            whoami = {
                rex_version = '0.0.stub',
                session_id = 'session:stub',
                block_id = 'block:stub',
            },
            clients = { APP },
        })
        stub.on_path()
        -- The stub answers `rex`; nothing else is on PATH but the fakes below.
        vim.env.PATH = stub.dir .. '/bin:' .. bin_dir
        vim.env.REX_BLOCK = 'block:stub'
        vim.env.REX_SESSION = 'session:stub'
        fake('git')
        fake('rexai')

        config.setup({ rex_bin = 'rex' })
        calls, restore_health = record_health()
    end)

    after_each(function()
        restore_health()
        stub.remove()
        vim.fn.delete(bin_dir, 'rf')
        for name, value in pairs(saved_env) do
            vim.env[name] = value
        end
        config.setup()
    end)

    it('reports every item ok when everything is in place', function()
        health.check()

        assert.are.equal(1, #of(calls, 'start'))
        assert.are.same({}, of(calls, 'error'))
        assert.are.same({}, of(calls, 'warn'))
        assert.are.same({}, of(calls, 'info'))
        -- Seven items, every one ok.
        assert.are.equal(7, #of(calls, 'ok'))
        assert.is_truthy(only(calls, 'start').text:find('rexai'))

        local asked = stub.calls()
        assert.are.equal(2, #asked)
        for _, argv in ipairs(asked) do
            assert.are.equal('--autostart=false', argv[1])
        end
    end)

    it('errors once and skips the Rex items when rex is missing', function()
        config.setup({ rex_bin = '/nonexistent/rex' })
        health.check()

        local failed = only(calls, 'error')
        assert.is_truthy(failed.text:find('not executable'))
        assert.are.equal(0, #stub.calls())

        -- The server and the apps are skipped, not reported again.
        local skipped = of(calls, 'info')
        assert.are.equal(2, #skipped)
        assert.is_truthy(skipped[1].text:find('server'))
        assert.is_truthy(skipped[2].text:find('app'))
    end)

    it('errors when the server does not answer', function()
        stub.set({
            fail = { code = 1, message = 'rex server is not running' },
        })
        health.check()

        assert.are.equal('rex server is not running', only(calls, 'error').text)
        assert.is_truthy(only(calls, 'info').text:find('did not answer'))
        assert.are.equal(1, #stub.calls())
    end)

    it('errors without waiting when the server hangs', function()
        stub.set({ delay_ms = 5000 })
        local started = vim.uv.now()

        health.check({ timeout_ms = 200 })

        assert.is_truthy(only(calls, 'error').text:find('timed out'))
        assert.is_true(vim.uv.now() - started < 4000)
    end)

    it('warns, never errors, outside Rex', function()
        vim.env.REX_BLOCK = nil
        vim.env.REX_SESSION = nil
        stub.set({ whoami = { rex_version = '0.0.stub' } })

        health.check()

        local warned = only(calls, 'warn')
        assert.is_truthy(warned.text:find('%$REX_BLOCK'))
        assert.is_truthy(warned[1]:find('Home session'))
        assert.are.same({}, of(calls, 'error'))
    end)

    it('errors when no Rex app is connected', function()
        stub.set({ clients = {} })
        health.check()

        local failed = only(calls, 'error')
        assert.is_truthy(failed.text:find('no Rex app is connected'))
        assert.is_truthy(failed[1]:find('<CR>'))
    end)

    it('ignores a lost app and command line clients', function()
        stub.set({
            clients = {
                {
                    client_id = 'client:lost',
                    info = { kind = 'app' },
                    connection_state = 'lost',
                },
                { client_id = 'client:cli' },
                APP,
            },
        })
        health.check()

        local blessed = matching(calls, 'ok', 'Rex app is connected')
        assert.are.equal('1 Rex app is connected', blessed.text)
    end)

    it('accepts several apps when the caller is inside Rex', function()
        stub.set({ clients = { APP, OTHER_APP } })
        health.check()

        matching(calls, 'ok', 'Rex apps are connected')
        assert.are.same({}, of(calls, 'error'))
        assert.are.same({}, of(calls, 'warn'))
    end)

    it('warns when several apps are connected outside Rex', function()
        vim.env.REX_BLOCK = nil
        vim.env.REX_SESSION = nil
        stub.set({
            whoami = { rex_version = '0.0.stub' },
            clients = { APP, OTHER_APP },
        })
        health.check()

        matching(calls, 'warn', 'Rex apps are connected')
        assert.are.same({}, of(calls, 'error'))
    end)

    it('warns, never errors, when git is missing', function()
        remove_fake('git')
        health.check()

        matching(calls, 'warn', 'git is not executable')
        assert.are.same({}, of(calls, 'error'))
    end)

    it('warns, never errors, when the rexai shim is missing', function()
        remove_fake('rexai')
        health.check()

        local warned = matching(calls, 'warn', 'rexai shim')
        assert.is_truthy(warned[1]:find('bin/rexai'))
        assert.are.same({}, of(calls, 'error'))
    end)

    it('runs from :checkhealth rexai in a child Neovim', function()
        -- `:checkhealth` fills the buffer as the report arrives, so the child
        -- waits for it before printing it.
        local wait = 'lua local nr = vim.fn.bufnr("health://") '
            .. 'vim.wait(10000, function() return nr ~= -1 '
            .. 'and #vim.api.nvim_buf_get_lines(nr, 0, -1, false) > 0 '
            .. 'and not vim.bo[nr].modifiable end, 50)'
        local dump = 'lua io.stdout:write(table.concat('
            .. 'vim.api.nvim_buf_get_lines(vim.fn.bufnr("health://"), '
            .. '0, -1, false), "\\n"))'

        local result = vim.system({
            vim.v.progpath,
            '--headless',
            '--noplugin',
            '-u',
            helpers.root() .. '/tests/minimal_init.lua',
            '-c',
            'checkhealth rexai',
            '-c',
            wait,
            '-c',
            dump,
            '-c',
            'qa!',
        }, { text = true, timeout = 20000 }):wait()

        assert.are.equal(0, result.code)
        assert.is_nil(result.stdout:find('ERROR'))
        assert.is_nil(result.stdout:find('WARNING'))
        assert.is_truthy(result.stdout:find('rexai.nvim'))
        assert.is_truthy(result.stdout:find('Neovim 0.11 or newer'))
    end)
end)
