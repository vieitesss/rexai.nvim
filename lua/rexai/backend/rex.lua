-- The Backend that talks to the real Rex. It runs the `rex` command with an
-- argument list, never a shell string, because the path of the binary can
-- contain a space. It calls every callback from the main loop.
--
-- Snapshots and focus go through the Lua scripts in `scripts/`, run with
-- `rex do`. Creating and peeking use one plain `rex` command each.

local M = {}

local DEFAULT_TIMEOUT_MS = 5000
local DEFAULT_PEEK_LINES = 50

local source = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(source, ':p:h:h:h:h')

---@class rexai.RexOpts
---@field bin string|nil the `rex` executable; default `rex`, found on PATH
---@field timeout_ms integer|nil kill a call after this long; default 5000
---@field scripts_dir string|nil where `snapshot.lua` and `focus.lua` live
---@field peek_lines integer|nil lines `peek` keeps from the end; default 50

-- The first line of Rex's error text, without its `Error: ` prefix.
---@param result vim.SystemCompleted
---@param timeout_ms integer
---@return string
local function describe_failure(result, timeout_ms)
    -- `vim.system` reports a call it killed on a timeout with code 124. A
    -- process that handles SIGTERM, like the stub, leaves its signal at 0.
    if result.code == 124 then
        return string.format('rex timed out after %g s', timeout_ms / 1000)
    end
    for line in (result.stderr or ''):gmatch('[^\r\n]+') do
        local message = vim.trim(line):gsub('^Error:%s*', '')
        if message ~= '' then
            return message
        end
    end
    return 'rex exited with code ' .. result.code
end

---@param opts rexai.RexOpts|nil
---@return rexai.Backend
function M.new(opts)
    opts = opts or {}
    local bin = opts.bin or 'rex'
    local timeout_ms = opts.timeout_ms or DEFAULT_TIMEOUT_MS
    local scripts_dir = opts.scripts_dir or (root .. '/scripts')
    local peek_lines = opts.peek_lines or DEFAULT_PEEK_LINES

    -- Runs `rex <args>` and calls `done(err, stdout)` on the main loop. It
    -- never starts a Rex server: with none running, there is nothing to show.
    ---@param args string[]
    ---@param done fun(err: string|nil, stdout: string|nil)
    local function run(args, done)
        local argv = { bin, '--autostart=false' }
        vim.list_extend(argv, args)

        local spawned, err = pcall(
            vim.system,
            argv,
            { text = true, timeout = timeout_ms },
            vim.schedule_wrap(function(result)
                if result.code ~= 0 then
                    return done(describe_failure(result, timeout_ms))
                end
                done(nil, result.stdout or '')
            end)
        )
        if not spawned then
            vim.schedule(function()
                done('cannot run ' .. bin .. ': ' .. tostring(err))
            end)
        end
    end

    -- Runs `rex <args>` and calls `done(err, value)` with the JSON it printed.
    ---@param args string[]
    ---@param done fun(err: string|nil, value: any)
    local function run_json(args, done)
        run(args, function(err, stdout)
            if err then
                return done(err)
            end
            local decoded, value = pcall(
                vim.json.decode,
                stdout,
                { luanil = { object = true, array = true } }
            )
            if not decoded then
                return done('rex printed text that is not JSON')
            end
            done(nil, value)
        end)
    end

    -- Runs a script from `scripts/` and decodes the JSON it returns.
    ---@param name string
    ---@param script_args table|nil
    ---@param done fun(err: string|nil, value: any)
    local function run_script(name, script_args, done)
        local args = { 'do', scripts_dir .. '/' .. name, '--json' }
        if script_args then
            vim.list_extend(args, { '--args', vim.json.encode(script_args) })
        end
        run_json(args, done)
    end

    -- Runs a creating command and builds a target from its JSON result.
    ---@param args string[]
    ---@param to_target fun(created: table): rexai.Target|nil
    ---@param callback fun(err: string|nil, target: rexai.Target|nil)
    local function create(args, to_target, callback)
        run_json(args, function(err, created)
            if err then
                return callback(err)
            end
            local target = type(created) == 'table' and to_target(created)
            if not target then
                return callback('rex did not describe what it created')
            end
            callback(nil, target)
        end)
    end

    -- Appends `-- command...` when the spec has a command.
    ---@param args string[]
    ---@param command string[]|nil
    local function with_command(args, command)
        if command and #command > 0 then
            args[#args + 1] = '--'
            vim.list_extend(args, command)
        end
        return args
    end

    local backend = {}

    function backend.snapshot(callback)
        run_script('snapshot.lua', nil, function(err, snapshot)
            if err then
                return callback(err)
            end
            if
                type(snapshot) ~= 'table'
                or snapshot.version ~= 1
                or type(snapshot.sessions) ~= 'table'
            then
                return callback('rex returned a snapshot of an unknown shape')
            end
            callback(nil, snapshot)
        end)
    end

    function backend.focus(target, callback)
        run_script('focus.lua', {
            session_id = target.session_id,
            window_id = target.window_id,
            block_id = target.block_id,
        }, function(err)
            callback(err)
        end)
    end

    -- spec: `session_id`, and optionally `name`, `cwd`, `command` (a list of
    -- words), `keep_open` (the Window stays after its command exits) and
    -- `focus` (false keeps the current focus).
    function backend.create_window(spec, callback)
        if not spec.session_id then
            return callback('session_id is required')
        end
        local args = { 'window', 'new', '-s', spec.session_id }
        if spec.name then
            args[#args + 1] = spec.name
        end
        if spec.cwd then
            vim.list_extend(args, { '-c', spec.cwd })
        end
        if spec.focus == false then
            args[#args + 1] = '--focus=false'
        end
        if spec.keep_open then
            args[#args + 1] = '--keep-open'
        end
        args[#args + 1] = '--json'

        create(with_command(args, spec.command), function(created)
            local block_id = (created.block_ids or {})[1]
            if created.window_id and block_id then
                return {
                    session_id = spec.session_id,
                    window_id = created.window_id,
                    block_id = block_id,
                }
            end
        end, callback)
    end

    -- spec: optionally `name`, `cwd`, `window` (the label of the first Window),
    -- `command` (a list of words) and `keep_open` (the Window stays after its
    -- command exits).
    function backend.create_session(spec, callback)
        local args = { 'new' }
        if spec.name then
            args[#args + 1] = spec.name
        end
        if spec.cwd then
            vim.list_extend(args, { '-c', spec.cwd })
        end
        if spec.window then
            vim.list_extend(args, { '--window', spec.window })
        end
        if spec.keep_open then
            args[#args + 1] = '--keep-open'
        end
        args[#args + 1] = '--json'

        create(with_command(args, spec.command), function(created)
            local first = (created.initial_windows or {})[1] or {}
            local block_id = (first.block_ids or {})[1]
            if created.session_id and first.window_id and block_id then
                return {
                    session_id = created.session_id,
                    window_id = first.window_id,
                    block_id = block_id,
                }
            end
        end, callback)
    end

    -- Gives the last lines of the Block's screen and scrollback.
    function backend.peek(target, callback)
        if not target.block_id then
            return callback('block_id is required')
        end
        run({
            'capture',
            '-s',
            target.session_id,
            '-b',
            target.block_id,
            '--trim',
        }, function(err, stdout)
            if err then
                return callback(err)
            end
            -- `capture` always ends its output with a newline.
            local lines = vim.split(stdout:gsub('\n$', ''), '\n', {
                plain = true,
            })
            if #lines > peek_lines then
                lines = vim.list_slice(lines, #lines - peek_lines + 1)
            end
            callback(nil, table.concat(lines, '\n'))
        end)
    end

    return backend
end

return M
