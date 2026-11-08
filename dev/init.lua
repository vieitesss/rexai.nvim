-- Run the plugin from this checkout, with no other config:
--
--   nvim -u dev/init.lua
--
-- It puts the checkout on the runtimepath and calls the plugin's `setup`.
-- Edit `opts` below to try options.

local source = debug.getinfo(1, 'S').source:sub(2)
local dev_dir = vim.fs.dirname(vim.fn.fnamemodify(source, ':p'))
local root = vim.fs.dirname(dev_dir)

vim.opt.runtimepath:prepend(root)

vim.o.swapfile = false
vim.o.termguicolors = true

local opts = {}

require('rexai').setup(opts)
