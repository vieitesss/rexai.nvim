-- The `:Rexai` command. Nothing is required at load, so the plugin costs
-- nothing until the command runs.

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
