-- Drives Backend snapshots for the Dashboard without overlapping calls.

local M = {}

---@class rexai.PollOpts
---@field backend rexai.Backend
---@field interval_ms integer|nil delay after a success; defaults to 1000
---@field retry_ms integer|nil delay after an error; defaults to 5000
---@field after (fun(ms: integer, callback: fun()): fun())|nil
---@field on_snapshot (fun(snapshot: table))|nil
---@field on_error (fun(err: string))|nil called once per outage, until a snapshot succeeds

---@class rexai.Poller
---@field start fun()
---@field stop fun()
---@field tick fun(): boolean
---@field running fun(): boolean

---@param ms integer
---@param callback fun()
---@return fun() cancel
local function after(ms, callback)
    local timer = assert(vim.uv.new_timer())
    local cancelled = false

    local function cancel()
        if cancelled then
            return
        end
        cancelled = true
        timer:stop()
        timer:close()
    end

    timer:start(
        ms,
        0,
        vim.schedule_wrap(function()
            if cancelled then
                return
            end
            cancel()
            callback()
        end)
    )
    return cancel
end

---@param opts rexai.PollOpts
---@return rexai.Poller
function M.new(opts)
    local schedule_after = opts.after or after
    local poller = {}
    local running = false
    local in_flight = false
    local error_reported = false
    local cancel_pending

    local function cancel_timer()
        if cancel_pending then
            cancel_pending()
            cancel_pending = nil
        end
    end

    local function arm(ms)
        cancel_pending = schedule_after(ms, function()
            cancel_pending = nil
            poller.tick()
        end)
    end

    function poller.tick()
        if not running or in_flight then
            return false
        end
        cancel_timer()
        in_flight = true
        local function finish(err, snapshot)
            in_flight = false
            if not running then
                return
            end
            if err then
                arm(opts.retry_ms or 5000)
                if not error_reported then
                    error_reported = true
                    if opts.on_error then
                        opts.on_error(err)
                    end
                end
            else
                arm(opts.interval_ms or 1000)
                error_reported = false
                if opts.on_snapshot then
                    opts.on_snapshot(snapshot)
                end
            end
        end

        opts.backend.snapshot(function(err, snapshot)
            if vim.in_fast_event() then
                vim.schedule(function()
                    finish(err, snapshot)
                end)
            else
                finish(err, snapshot)
            end
        end)
        return true
    end

    function poller.start()
        if running then
            return
        end
        running = true
        poller.tick()
    end

    function poller.stop()
        running = false
        cancel_timer()
    end

    function poller.running()
        return running
    end

    return poller
end

return M
