-- `:checkhealth rexai`: says, item by item, whether the plugin can work.
--
-- Every Rex call is read-only and carries `--autostart=false`, so a check
-- never starts a server and never switches the user's view. `checkhealth` is
-- synchronous, so the calls block; `check` takes a timeout for the whole of
-- one call, which is the seam the spec uses for the hanging-server case.

local config = require('rexai.config')

local M = {}

local TIMEOUT_MS = 3000
local APP_KIND = 'app'

-- The first line of Rex's error text, without its `Error: ` prefix. The same
-- rule the rex Backend uses, kept here so `checkhealth` needs no Backend.
---@param result vim.SystemCompleted
---@param timeout_ms integer
---@return string
local function describe_failure(result, timeout_ms)
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

-- Runs `rex --autostart=false <args>` and returns the JSON it printed, or nil
-- and the reason it did not.
---@param bin string
---@param args string[]
---@param timeout_ms integer
---@return table|nil value
---@return string|nil err
local function rex_json(bin, args, timeout_ms)
    local argv = { bin, '--autostart=false' }
    vim.list_extend(argv, args)

    local spawned, process =
        pcall(vim.system, argv, { text = true, timeout = timeout_ms })
    if not spawned then
        return nil, 'cannot run ' .. bin .. ': ' .. tostring(process)
    end

    local result = process:wait()
    if result.code ~= 0 then
        return nil, describe_failure(result, timeout_ms)
    end

    local decoded, value = pcall(
        vim.json.decode,
        result.stdout or '',
        { luanil = { object = true, array = true } }
    )
    if not decoded then
        return nil, 'rex printed text that is not JSON'
    end
    return type(value) == 'table' and value or nil
end

-- The clients that are a connected Rex app: kind `app`, not `lost`.
---@param value table|nil the reply of `rex client ls --json`
---@return table[]
local function connected_apps(value)
    local apps = {}
    for _, client in ipairs(value and value.clients or {}) do
        if
            type(client) == 'table'
            and type(client.info) == 'table'
            and client.info.kind == APP_KIND
            and client.connection_state ~= 'lost'
        then
            apps[#apps + 1] = client
        end
    end
    return apps
end

---@param version table vim.version()
---@return string
local function version_text(version)
    return string.format(
        '%d.%d.%d',
        version.major,
        version.minor,
        version.patch
    )
end

-- ` (rex <version>)` for a message, from the version Rex reports; empty when
-- Rex reports none.
---@param version any
---@return string
local function rex_version_text(version)
    if type(version) ~= 'string' or version == '' then
        return ''
    end
    return ' (rex ' .. version .. ')'
end

---@class rexai.HealthOpts
---@field timeout_ms integer|nil kill one `rex` call after this long; default 3000

-- Reports every item to `:checkhealth rexai`. `opts` exists for the spec: the
-- command never passes it.
---@param opts rexai.HealthOpts|nil
function M.check(opts)
    local timeout_ms = (opts or {}).timeout_ms or TIMEOUT_MS
    local bin = config.get().rex_bin
    local out = vim.health

    out.start('rexai.nvim')

    local version = vim.version()
    if vim.fn.has('nvim-0.11') == 1 then
        out.ok('Neovim 0.11 or newer (' .. version_text(version) .. ')')
    else
        out.error(
            'Neovim 0.11 or newer is required; found ' .. version_text(version),
            'install a newer Neovim'
        )
    end

    local runnable = vim.fn.executable(bin) == 1
    if runnable then
        out.ok(bin .. ' is executable (' .. vim.fn.exepath(bin) .. ')')
    else
        out.error(bin .. ' is not executable', 'install Rex or set rex_bin')
    end

    -- `whoami` proves the server answers, and says where the caller is.
    local whoami, server_error
    if runnable then
        whoami, server_error = rex_json(bin, { 'whoami', '--json' }, timeout_ms)
    end
    if not runnable then
        out.info('Rex server not checked: no ' .. bin .. ' executable')
    elseif whoami then
        out.ok('Rex server is running' .. rex_version_text(whoami.rex_version))
    else
        out.error(
            server_error,
            'start the server with `rex server start`, or open the Rex app'
        )
    end

    if os.getenv('REX_BLOCK') then
        out.ok('running inside Rex ($REX_BLOCK is set)')
    else
        out.warn(
            'not running inside Rex ($REX_BLOCK is unset)',
            'the Home session cannot be found and <CR> picks the only '
                .. 'connected Rex app'
        )
    end

    -- The caller's own Block, which is what `focus.lua` needs to pick an app.
    local caller_known = whoami ~= nil
        and type(whoami.session_id) == 'string'
        and type(whoami.block_id) == 'string'
    local clients
    local apps_error
    if whoami then
        clients, apps_error =
            rex_json(bin, { 'client', 'ls', '--json' }, timeout_ms)
    end

    if not runnable then
        out.info('connected Rex apps not checked: no ' .. bin .. ' executable')
    elseif not whoami then
        out.info('connected Rex apps not checked: the server did not answer')
    elseif not clients then
        out.error(apps_error, 'the Dashboard cannot list what Rex has')
    else
        local apps = connected_apps(clients)
        if #apps == 0 then
            out.error(
                'no Rex app is connected',
                '<CR> has nothing to select in; open the Rex app'
            )
        elseif #apps == 1 then
            out.ok('1 Rex app is connected')
        elseif caller_known then
            out.ok(
                #apps
                    .. ' Rex apps are connected; the one that owns this '
                    .. 'Neovim is used'
            )
        else
            out.warn(
                #apps
                    .. ' Rex apps are connected and this Neovim is not '
                    .. 'inside one of them',
                '<CR> cannot pick one; run Neovim inside the Rex app to use'
            )
        end
    end

    if vim.fn.executable('git') == 1 then
        out.ok('git is executable (' .. vim.fn.exepath('git') .. ')')
    else
        out.warn(
            'git is not executable',
            'the Dashboard still works, it shows no branch'
        )
    end

    if vim.fn.executable('rexai') == 1 then
        out.ok('rexai is executable (' .. vim.fn.exepath('rexai') .. ')')
    else
        out.warn(
            'the rexai shim is not on PATH',
            'link bin/rexai into a directory on PATH to run it from any shell'
        )
    end
end

return M
