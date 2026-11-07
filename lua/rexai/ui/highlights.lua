-- The Dashboard highlight groups and the group of each Agent status.
--
-- Every group links to a Diagnostic group, so a colorscheme that styles those
-- styles the Dashboard too. `default = true` leaves a user's own definition
-- alone.

local M = {}

-- Groups in the order they are defined. Names are written once, here.
M.LINKS = {
    { 'RexaiNeedsInput', 'DiagnosticWarn' },
    { 'RexaiError', 'DiagnosticError' },
    { 'RexaiDone', 'DiagnosticOk' },
    { 'RexaiWorking', 'DiagnosticInfo' },
    { 'RexaiUnreported', 'Comment' },
    { 'RexaiIdle', 'Comment' },
    { 'RexaiExited', 'Comment' },
    { 'RexaiHeader', 'Title' },
    { 'RexaiDim', 'Comment' },
}

-- One group per Agent status name (`rexai.core.status.ORDER`).
M.STATUS = {
    needs_input = 'RexaiNeedsInput',
    error = 'RexaiError',
    done = 'RexaiDone',
    working = 'RexaiWorking',
    unreported = 'RexaiUnreported',
    idle = 'RexaiIdle',
    exited = 'RexaiExited',
}

-- Defines every group. Safe to call more than once.
function M.define()
    for _, link in ipairs(M.LINKS) do
        vim.api.nvim_set_hl(0, link[1], { link = link[2], default = true })
    end
end

---@param name string|nil an Agent status
---@return string|nil group, nil for a status this plugin does not know
function M.group(name)
    return M.STATUS[name]
end

return M
