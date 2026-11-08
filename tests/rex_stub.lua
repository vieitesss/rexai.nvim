-- Installs the stub `rex` of `tests/stub/rex.lua` in a fresh temporary
-- directory whose name has a space, to prove the Backend runs `rex` with an
-- argument list and not a shell string.

local helpers = require('tests.helpers')

local M = {}

---@class rexai.StubState
---@field snapshot table what `scripts/snapshot.lua` returns
---@field peek table<string, string>|nil screen text by block id
---@field delay_ms integer|nil every call waits this long first
---@field fail { code: integer, message: string }|nil every call fails
---@field stdout string|nil raw text every call prints instead of its answer
---@field whoami table|nil what the `whoami --json` of `:checkhealth rexai` prints
---@field clients table[]|nil what the `client ls --json` of `:checkhealth rexai` prints
---@field sessions table[]|nil what `ls --json` lists; `kill` takes a Session out of it
---@field home table|nil what `do home.lua` prints
---@field home_fail boolean|nil `do home.lua` fails
---@field kill_fail boolean|nil `kill` fails

---@class rexai.Stub
---@field dir string
---@field bin string the stub `rex` executable
---@field set fun(patch: table) changes keys of the state
---@field calls fun(): string[][] the argument list of every call so far
---@field remove fun() restores PATH and deletes the directory
---@field on_path fun() puts the stub first on PATH

---@param state rexai.StubState
---@return rexai.Stub
function M.install(state)
    local dir = vim.fn.tempname() .. ' with space'
    local bin_dir = dir .. '/bin'
    vim.fn.mkdir(bin_dir, 'p')

    local stub = { dir = dir, bin = bin_dir .. '/rex' }
    local saved_path = vim.env.PATH

    local function write(path, text)
        local file = assert(io.open(path, 'w'))
        file:write(text)
        file:close()
    end

    local function save()
        write(dir .. '/state.json', vim.json.encode(state))
    end
    save()

    write(
        stub.bin,
        string.format(
            "#!/bin/sh\nexec '%s' --headless --noplugin -u NONE -l '%s' '%s' \"$@\"\n",
            vim.v.progpath,
            helpers.root() .. '/tests/stub/rex.lua',
            dir
        )
    )
    vim.uv.fs_chmod(stub.bin, tonumber('755', 8))

    function stub.set(patch)
        for key, value in pairs(patch) do
            state[key] = value
        end
        save()
    end

    function stub.calls()
        local calls = {}
        local file = io.open(dir .. '/calls.jsonl', 'r')
        if not file then
            return calls
        end
        for line in file:lines() do
            calls[#calls + 1] = vim.json.decode(line)
        end
        file:close()
        return calls
    end

    function stub.on_path()
        vim.env.PATH = bin_dir .. ':' .. saved_path
    end

    function stub.remove()
        vim.env.PATH = saved_path
        vim.fn.delete(dir, 'rf')
    end

    return stub
end

return M
