-- A stand-in for the `rex` command. Tests put it first on PATH, through the
-- one-line `rex` wrapper that `tests/rex_stub.lua` writes. It never talks to a
-- real Rex: it replays a prepared snapshot and answers the few commands the
-- rex Backend runs, plus the read-only ones `:checkhealth rexai` asks for
-- (`whoami`, `client ls`), which come from the `whoami` and `clients` keys of
-- the state.
--
--   nvim --headless --noplugin -u NONE -l tests/stub/rex.lua DIR ARGS...
--
-- DIR holds `state.json` (see `tests/rex_stub.lua`) and receives `calls.jsonl`,
-- one line per call with its argument list.

local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h:h')
package.path = root .. '/lua/?.lua;' .. package.path

local dir = arg[1]
local argv = {}
for i = 2, #arg do
    argv[#argv + 1] = arg[i]
end

local function read(name)
    local file = io.open(dir .. '/' .. name, 'r')
    if not file then
        return nil
    end
    local text = file:read('*a')
    file:close()
    return text
end

local function write(name, text, mode)
    local file = assert(io.open(dir .. '/' .. name, mode or 'w'))
    file:write(text)
    file:close()
end

local function die(code, message)
    io.stderr:write('Error: ', message, '\n')
    os.exit(code)
end

local function out(value)
    io.stdout:write(vim.json.encode(value), '\n')
    os.exit(0)
end

write('calls.jsonl', vim.json.encode(argv) .. '\n', 'a')

local state = vim.json.decode(read('state.json'))

if state.delay_ms then
    -- Not `uv.sleep`: Neovim acts on SIGTERM only while its loop runs.
    vim.wait(state.delay_ms, function()
        return false
    end)
end
if state.fail then
    die(state.fail.code or 1, state.fail.message or 'stub failure')
end
if state.stdout then
    io.stdout:write(state.stdout)
    os.exit(0)
end

local backend = require('rexai.backend.fake').new({
    snapshots = { state.snapshot },
    peek = state.peek,
})

-- The value that follows `flag` in the argument list.
local function option(flag)
    for i = 1, #argv - 1 do
        if argv[i] == flag then
            return argv[i + 1]
        end
    end
end

-- A new number each call, kept across calls in a file.
local function next_number()
    local n = (tonumber(read('counter')) or 0) + 1
    write('counter', tostring(n))
    return n
end

if argv[1] == '--autostart=false' then
    table.remove(argv, 1)
end

local command = argv[1]

-- The read-only calls `:checkhealth rexai` makes.
if command == 'whoami' then
    out(state.whoami or {})
elseif command == 'client' and argv[2] == 'ls' then
    out({ clients = state.clients or {} })
end

if command == 'do' then
    local script = vim.fs.basename(argv[2])
    if script == 'snapshot.lua' then
        out(state.snapshot)
    elseif script == 'focus.lua' then
        local target = vim.json.decode(option('--args'))
        backend.focus(target, function(err)
            if err then
                die(1, 'target not found')
            end
            out({ client_id = 'client:stub' })
        end)
    end
    die(2, 'stub: unknown script ' .. tostring(script))
elseif command == 'window' and argv[2] == 'new' then
    backend.focus({ session_id = option('-s') }, function(err)
        if err then
            die(3, 'session target not found')
        end
    end)
    local n = next_number()
    out({
        window_id = 'window:stub-' .. n,
        block_ids = { 'block:stub-' .. n },
        revision = 2,
    })
elseif command == 'new' then
    local n = next_number()
    out({
        session_id = 'session:stub-' .. n,
        initial_windows = {
            {
                window_id = 'window:stub-' .. n,
                block_ids = { 'block:stub-' .. n },
                revision = 1,
            },
        },
    })
elseif command == 'capture' then
    local target = { session_id = option('-s'), block_id = option('-b') }
    backend.peek(target, function(err, text)
        if err then
            die(3, 'block target not found')
        end
        io.stdout:write(text, '\n')
        os.exit(0)
    end)
end

die(2, 'stub: unsupported command ' .. tostring(command))
