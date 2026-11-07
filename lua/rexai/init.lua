-- The plugin: `setup` for the options and the highlight groups, `open` for
-- the Dashboard.

local config = require('rexai.config')
local highlights = require('rexai.ui.highlights')

local M = {}

M.AUGROUP = 'RexaiHighlights'

-- Merges the user options, defines the highlight groups and keeps them
-- defined across a colorscheme change. Calling it again replaces the previous
-- options and autocmds instead of adding to them.
---@param opts table|nil
---@return rexai.Config
function M.setup(opts)
    local merged = config.setup(opts)
    highlights.define()

    local group = vim.api.nvim_create_augroup(M.AUGROUP, { clear = true })
    vim.api.nvim_create_autocmd('ColorScheme', {
        group = group,
        callback = function()
            highlights.define()
        end,
    })

    return merged
end

-- Shows the Dashboard in the current window.
function M.open()
    return require('rexai.ui.dashboard').open()
end

return M
