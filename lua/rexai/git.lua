-- The git slot of each Agent row, asked for in the background and cached per
-- path. A status call never blocks the Dashboard and never runs more often
-- than `git_refresh_ms` for one path.

local config = require('rexai.config')
local core_git = require('rexai.core.git')

local M = {}

local TIMEOUT_MS = 3000

-- Runs one `git` command with an argument list, never a shell string.
---@param argv string[]
---@param callback fun(err: string|nil, stdout: string|nil)
local function spawn(argv, callback)
    local ok, err = pcall(
        vim.system,
        argv,
        { text = true, timeout = TIMEOUT_MS },
        vim.schedule_wrap(function(result)
            if result.code ~= 0 then
                return callback('git exited with code ' .. result.code)
            end
            callback(nil, result.stdout or '')
        end)
    )
    if not ok then
        vim.schedule(function()
            callback('cannot run git: ' .. tostring(err))
        end)
    end
end

---@class rexai.GitOpts
---@field refresh_ms integer|nil how old a result may be before it is asked again
---@field run (fun(argv: string[], callback: fun(err: string|nil, stdout: string|nil)))|nil
---@field clock (fun(): integer)|nil milliseconds, monotonic
---@field on_change (fun())|nil called when a result changes what `get` returns

---@class rexai.Git
---@field get fun(self: rexai.Git, path: string|nil): rexai.GitInfo|nil
---@field request fun(self: rexai.Git, path: string|nil)
---@field retain fun(self: rexai.Git, paths: string[])
---@field stop fun(self: rexai.Git)

---@class rexai.GitEntry
---@field at integer when the result arrived, in `clock` milliseconds
---@field value rexai.GitInfo|false `false` for a path git could not describe

---@param opts rexai.GitOpts|nil
---@return rexai.Git
function M.new(opts)
    opts = opts or {}
    local refresh_ms = opts.refresh_ms or config.get().git_refresh_ms
    local run = opts.run or spawn
    local clock = opts.clock or vim.uv.now
    local on_change = opts.on_change

    -- Everything below is per path: the last result, and the token of the
    -- call in flight. A token that no longer matches is a late result and is
    -- dropped.
    local entries = {}
    local inflight = {}
    local token = 0

    local object = {}

    ---@param path string|nil
    ---@return rexai.GitInfo|nil
    local function current(path)
        local entry = entries[path]
        if entry and entry.value then
            return entry.value
        end
        return nil
    end

    -- Keeps `value` for `path` and reports a change. `ticket` must still be
    -- the call in flight, or the result belongs to a path nobody wants.
    ---@param path string
    ---@param ticket integer
    ---@param value rexai.GitInfo|false
    local function finish(path, ticket, value)
        if inflight[path] ~= ticket then
            return
        end
        inflight[path] = nil

        local before = current(path)
        entries[path] = { at = clock(), value = value }
        if on_change and not vim.deep_equal(before, current(path)) then
            vim.schedule(on_change)
        end
    end

    ---@param path string
    ---@param ticket integer
    local function ask(path, ticket)
        run({
            'git',
            '--no-optional-locks',
            '-C',
            path,
            'status',
            '--porcelain=v2',
            '--branch',
            '--untracked-files=all',
        }, function(err, stdout)
            if inflight[path] ~= ticket then
                return
            end
            if err then
                return finish(path, ticket, false)
            end

            local info = core_git.parse_status(stdout)
            run({
                'git',
                '-C',
                path,
                'rev-parse',
                '--show-toplevel',
            }, function(root_err, root)
                if inflight[path] ~= ticket then
                    return
                end
                root = vim.trim(root or '')
                if root_err or root == '' then
                    return finish(path, ticket, false)
                end
                info.repo = vim.fs.basename(root)
                info.root = root
                finish(path, ticket, info)
            end)
        end)
    end

    ---@param path string|nil
    ---@return rexai.GitInfo|nil
    function object.get(_, path)
        return current(path)
    end

    ---@param path string|nil
    function object.request(_, path)
        if type(path) ~= 'string' or path == '' then
            return
        end
        if inflight[path] then
            return
        end
        local entry = entries[path]
        if entry and clock() - entry.at < refresh_ms then
            return
        end

        token = token + 1
        inflight[path] = token
        ask(path, token)
    end

    ---@param paths string[]
    function object.retain(_, paths)
        local keep = {}
        for _, path in ipairs(paths) do
            keep[path] = true
        end
        for path in pairs(entries) do
            if not keep[path] then
                entries[path] = nil
            end
        end
        -- A dropped path is no longer in flight: its late result is ignored.
        for path in pairs(inflight) do
            if not keep[path] then
                inflight[path] = nil
            end
        end
    end

    function object.stop(_)
        entries = {}
        inflight = {}
    end

    return object
end

return M
