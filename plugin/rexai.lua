-- The `:Rexai` command and the autocmds a session load needs. Nothing is
-- required at load, so the plugin costs nothing until the command or a session
-- load needs it.

if vim.g.loaded_rexai then
    return
end
vim.g.loaded_rexai = 1

if vim.fn.has('nvim-0.11') == 0 then
    vim.notify('rexai.nvim needs Neovim 0.11 or newer', vim.log.levels.ERROR)
    return
end

vim.api.nvim_create_user_command('Rexai', function()
    require('rexai').open()
end, { desc = 'Show the Rexai Dashboard' })

-- A session holds the Dashboard under its buffer name and gives it back with
-- `:edit rexai://dashboard`. The `BufReadCmd` owns that name, so the session
-- lands on the Dashboard this Neovim already has instead of renaming a buffer
-- onto it, which `:restart` turned into E95. The group exists before any
-- `:Rexai`, because a session can load first.
local session_group = vim.api.nvim_create_augroup('RexaiSession', {
    clear = true,
})

-- The name is `dashboard.NAME`, which this file cannot require without loading
-- the Dashboard.
vim.api.nvim_create_autocmd('BufReadCmd', {
    group = session_group,
    pattern = 'rexai://dashboard',
    callback = function()
        require('rexai.ui.dashboard').read()
    end,
})
