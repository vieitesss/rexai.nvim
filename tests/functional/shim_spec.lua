-- Runs the real `bin/rexai` with a fake `rex` first on PATH. The fake records
-- its argument list and the text it got on stdin, so the spec proves what the
-- shim asked Rex for without a running Rex.

local helpers = require('tests.helpers')

local root = helpers.root()
local shim = root .. '/bin/rexai'
local HOME = '/example/home'

local HOME_JSON = vim.json.encode({
    session_id = 'session:stub',
    window_id = 'window:stub',
    block_id = 'block:stub',
    created = 'session',
})

local function write(path, text)
    local file = assert(io.open(path, 'w'))
    file:write(text)
    file:close()
end

local function read(path)
    local file = io.open(path, 'r')
    if not file then
        return nil
    end
    local text = file:read('*a')
    file:close()
    return text
end

local function chmod(path, mode)
    vim.uv.fs_chmod(path, tonumber(mode, 8))
end

-- The fake `rex`: it logs every argument on its own line, ends each call with
-- `--`, answers `home.lua` with the canned JSON and `focus.lua` with the text
-- it read on stdin. A file in DIR sets the status a call exits with.
local function fake_rex(dir)
    return table.concat({
        '#!/bin/sh',
        "dir='" .. dir .. "'",
        '',
        'status_of() {',
        '    if [ -f "$dir/$1" ]; then',
        '        cat "$dir/$1"',
        '    else',
        '        echo 0',
        '    fi',
        '}',
        '',
        '{',
        '    for arg in "$@"; do',
        '        printf \'%s\\n\' "$arg"',
        '    done',
        "    printf '%s\\n' '--'",
        '} >> "$dir/calls"',
        '',
        'is_home=0',
        'is_focus=0',
        'for arg in "$@"; do',
        '    case $arg in',
        '        */home.lua) is_home=1 ;;',
        '        */focus.lua) is_focus=1 ;;',
        '    esac',
        'done',
        '',
        'if [ "$is_home" = 1 ]; then',
        '    code=$(status_of home_status)',
        '    if [ "$code" -ne 0 ]; then',
        '        echo "Error: home script failed" >&2',
        '        exit "$code"',
        '    fi',
        '    cat "$dir/home.json"',
        '    exit 0',
        'fi',
        '',
        'if [ "$is_focus" = 1 ]; then',
        '    cat > "$dir/focus_stdin"',
        '    code=$(status_of focus_status)',
        '    if [ "$code" -ne 0 ]; then',
        '        echo "Error: focus script failed" >&2',
        '        exit "$code"',
        '    fi',
        '    echo \'{"client_id":"client:stub"}\'',
        '    exit 0',
        'fi',
        '',
        'echo "Error: unexpected rex call" >&2',
        'exit 9',
        '',
    }, '\n')
end

-- The calls the fake recorded, each as its own argument list.
local function calls(dir)
    local text = read(dir .. '/calls')
    if not text then
        return {}
    end
    local out = {}
    local current = {}
    for line in (text .. '\n'):gmatch('([^\n]*)\n') do
        if line == '--' then
            out[#out + 1] = current
            current = {}
        else
            current[#current + 1] = line
        end
    end
    return out
end

describe('bin/rexai', function()
    local dir, saved_home

    before_each(function()
        dir = vim.fn.tempname()
        vim.fn.mkdir(dir .. '/bin', 'p')
        write(dir .. '/bin/rex', fake_rex(dir))
        chmod(dir .. '/bin/rex', '755')
        write(dir .. '/home.json', HOME_JSON)
        saved_home = vim.env.HOME
        vim.env.HOME = HOME
    end)

    after_each(function()
        vim.env.HOME = saved_home
        vim.fn.delete(dir, 'rf')
    end)

    -- Runs a command with the fake `rex` first on PATH.
    local function run(argv, env)
        env = env
            or { PATH = dir .. '/bin:' .. (vim.env.PATH or '/bin:/usr/bin') }
        env.HOME = HOME
        local result = vim.system(argv, { text = true, env = env, cwd = root })
            :wait()
        return {
            code = result.code,
            stdout = result.stdout or '',
            stderr = result.stderr or '',
        }
    end

    it('runs home.lua and pipes its JSON into focus.lua', function()
        local got = run({ shim })

        assert.are.equal(0, got.code)
        assert.are.same({
            {
                'do',
                root .. '/scripts/home.lua',
                'name=rexai',
                'cwd=' .. HOME,
                '--json',
            },
            { 'do', root .. '/scripts/focus.lua', '--args', '-', '--json' },
        }, calls(dir))
        assert.are.equal(HOME_JSON, vim.trim(read(dir .. '/focus_stdin')))
    end)

    it('passes the label of --name to home.lua', function()
        local got = run({ shim, '--name', 'example' })

        assert.are.equal(0, got.code)
        assert.are.same('name=example', calls(dir)[1][3])
    end)

    it('passes the label of --name=NAME to home.lua', function()
        local got = run({ shim, '--name=example' })

        assert.are.equal(0, got.code)
        assert.are.same('name=example', calls(dir)[1][3])
    end)

    it('stops with the status of a failing home.lua', function()
        write(dir .. '/home_status', '3\n')

        local got = run({ shim })

        assert.are.equal(3, got.code)
        assert.is_truthy(got.stderr:find('home script failed', 1, true))
        assert.are.equal(1, #calls(dir))
    end)

    it('ends with the status of a failing focus.lua', function()
        write(dir .. '/focus_status', '4\n')

        local got = run({ shim })

        assert.are.equal(4, got.code)
        assert.is_truthy(got.stderr:find('focus script failed', 1, true))
    end)

    it('prints the usage and calls no script for --help', function()
        local got = run({ shim, '--help' })

        assert.are.equal(0, got.code)
        assert.is_truthy(got.stdout:find('usage: rexai', 1, true))
        assert.are.same({}, calls(dir))
    end)

    it('rejects an unknown option with the usage on stderr', function()
        local got = run({ shim, '--unknown' })

        assert.are.equal(2, got.code)
        assert.is_truthy(got.stderr:find('usage: rexai', 1, true))
        assert.are.same({}, calls(dir))
    end)

    it('rejects --name without a value', function()
        local got = run({ shim, '--name' })

        assert.are.equal(2, got.code)
        assert.is_truthy(got.stderr:find('usage: rexai', 1, true))
        assert.are.same({}, calls(dir))
    end)

    it('rejects an empty --name', function()
        local got = run({ shim, '--name=' })

        assert.are.equal(2, got.code)
        assert.is_truthy(got.stderr:find('usage: rexai', 1, true))
        assert.are.same({}, calls(dir))
    end)

    it('finds its root when it is run through a symlink', function()
        local links = vim.fn.tempname()
        vim.fn.mkdir(links, 'p')
        vim.uv.fs_symlink(shim, links .. '/rexai')

        local got = run({ links .. '/rexai' })

        assert.are.equal(0, got.code)
        assert.are.equal(root .. '/scripts/home.lua', calls(dir)[1][2])
        vim.fn.delete(links, 'rf')
    end)

    it('handles a root whose path has a space', function()
        local spaced = vim.fn.tempname() .. ' with space'
        for _, name in ipairs({ 'bin', 'scripts' }) do
            vim.fn.mkdir(spaced .. '/' .. name, 'p')
        end
        for _, name in ipairs({ 'bin/rexai', 'scripts/home.lua' }) do
            write(spaced .. '/' .. name, assert(read(root .. '/' .. name)))
        end
        chmod(spaced .. '/bin/rexai', '755')

        local got = run({ spaced .. '/bin/rexai' })

        assert.are.equal(0, got.code)
        assert.are.equal(
            vim.uv.fs_realpath(spaced) .. '/scripts/home.lua',
            calls(dir)[1][2]
        )
        vim.fn.delete(spaced, 'rf')
    end)

    it('tells the user when rex is not on PATH', function()
        local got = run({ shim }, { PATH = '' })

        assert.are.equal(127, got.code)
        assert.are.equal('rexai: rex is not on PATH\n', got.stderr)
        assert.are.same({}, calls(dir))
    end)
end)
