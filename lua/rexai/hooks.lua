-- The three user hooks of the Dashboard. `resolve_path` decides which
-- directory an Agent row stands for; `review` receives the context of the row
-- the `o` key is on; `session_name` names a new Session. All are plain
-- functions in the config, read at call time, so a `setup()` after the
-- Dashboard opened counts.

local config = require('rexai.config')

local M = {}

---@class rexai.HooksOpts
---@field notify (fun(message: string, level: integer))|nil test seam

---@class rexai.Hooks
---@field resolve fun(self: rexai.Hooks, row: rexai.Row): string|nil
---@field review fun(self: rexai.Hooks, ctx: table)
---@field session_name fun(self: rexai.Hooks, path: string): string|nil

-- The directory of the Block itself, nil when it has none.
---@param row rexai.Row
---@return string|nil
local function cwd_of(row)
    local cwd = row.cwd
    if type(cwd) == 'string' and cwd ~= '' then
        return cwd
    end
    return nil
end

---@param opts rexai.HooksOpts|nil
---@return rexai.Hooks
function M.new(opts)
    opts = opts or {}
    local notify = opts.notify
        or function(message, level)
            vim.notify(message, level)
        end

    -- A broken `resolve_path` runs for every row of every snapshot, and a
    -- broken `session_name` for every new Session, so the user hears about
    -- each once per Dashboard and the label falls back in silence after that.
    -- The latches are per hook: a failure of one never silences the other.
    ---@return fun(message: string)
    local function once()
        local reported = false
        return function(message)
            if reported then
                return
            end
            reported = true
            notify(message, vim.log.levels.WARN)
        end
    end

    local report_once = once()
    local report_name = once()

    local object = {}

    -- What `resolve_path` gives for this row: a non-empty string wins, nil or
    -- an empty string means the directory of the Block. The hook gets a
    -- shallow copy, so it cannot change the row the render shows.
    ---@param row rexai.Row
    ---@return string|nil
    function object.resolve(_, row)
        local hook = config.get().resolve_path
        if type(hook) ~= 'function' then
            return cwd_of(row)
        end

        local copy = {}
        for key, value in pairs(row) do
            copy[key] = value
        end

        local ok, value = pcall(hook, copy)
        if not ok then
            report_once('rexai: resolve_path failed: ' .. tostring(value))
            return cwd_of(row)
        end
        if type(value) == 'string' then
            if value ~= '' then
                return value
            end
        elseif value ~= nil then
            report_once(
                'rexai: resolve_path must return a string or nil, got '
                    .. type(value)
            )
        end
        return cwd_of(row)
    end

    -- Hands the context of a row to `review`. Every press says why nothing
    -- happened, because the user asked for it.
    ---@param ctx table
    function object.review(_, ctx)
        local hook = config.get().review
        if type(hook) ~= 'function' then
            notify(
                'rexai: no review function is set; add review = '
                    .. 'function(ctx) ... end to setup()',
                vim.log.levels.INFO
            )
            return
        end

        local ok, err = pcall(hook, ctx)
        if not ok then
            notify(
                'rexai: review failed: ' .. tostring(err),
                vim.log.levels.WARN
            )
        end
    end

    -- What `session_name` gives for the path of a new Session: the string, or
    -- nil when there is no hook or the hook gave nothing usable. The label
    -- rule of `core.launch` stays the fallback.
    ---@param path string
    ---@return string|nil
    function object.session_name(_, path)
        local hook = config.get().session_name
        if type(hook) ~= 'function' then
            return nil
        end

        local ok, value = pcall(hook, path)
        if not ok then
            report_name('rexai: session_name failed: ' .. tostring(value))
            return nil
        end
        if type(value) == 'string' and value ~= '' then
            return value
        end
        return nil
    end

    return object
end

return M
