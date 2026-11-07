-- The two user hooks of the Dashboard. `resolve_path` decides which directory
-- an Agent row stands for; `review` receives the context of the row the `d`
-- key is on. Both are plain functions in the config, read at call time, so a
-- `setup()` after the Dashboard opened counts.

local config = require('rexai.config')

local M = {}

---@class rexai.HooksOpts
---@field notify (fun(message: string, level: integer))|nil test seam

---@class rexai.Hooks
---@field resolve fun(self: rexai.Hooks, row: rexai.Row): string|nil
---@field review fun(self: rexai.Hooks, ctx: table): boolean

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

    -- A broken `resolve_path` runs for every row of every snapshot, so the
    -- user hears about it once per Dashboard and the rows fall back in
    -- silence after that.
    local reported = false

    local object = {}

    ---@param message string
    local function report_once(message)
        if reported then
            return
        end
        reported = true
        notify(message, vim.log.levels.WARN)
    end

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

    -- Hands the context of a row to `review`. True only when the function ran
    -- without error. Every press says why nothing happened, because the user
    -- asked for it.
    ---@param ctx table
    ---@return boolean
    function object.review(_, ctx)
        local hook = config.get().review
        if type(hook) ~= 'function' then
            notify(
                'rexai: no review function is set; add review = '
                    .. 'function(ctx) ... end to setup()',
                vim.log.levels.INFO
            )
            return false
        end

        local ok, err = pcall(hook, ctx)
        if not ok then
            notify(
                'rexai: review failed: ' .. tostring(err),
                vim.log.levels.WARN
            )
            return false
        end
        return true
    end

    return object
end

return M
