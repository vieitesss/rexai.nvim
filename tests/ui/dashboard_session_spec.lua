-- Sourcing a session that holds the Dashboard. `:restart` starts Neovim again
-- and sources the session it wrote, and a later `:mksession` can be sourced by
-- hand. Either way the Dashboard has to come back whole: the same buffer name,
-- keymaps, polling and a render, never a blank buffer and never E95. The fake
-- Backend serves invented snapshots, so no Rex runs.

local dashboard = require('rexai.ui.dashboard')
local snap = require('tests.snapshots')
local support = require('tests.ui_support')

-- One Session, one Window, one Agent block.
local ONE = snap.snapshot({
    snap.session({
        id = 'session:s1',
        label = 'orbit',
        windows = {
            snap.window({
                id = 'window:w1',
                label = 'api',
                blocks = {
                    snap.block({
                        id = 'block:b1',
                        app = 'pi',
                        state = 'working',
                        title = 'the docs',
                    }),
                },
            }),
        },
    }),
})

-- A few of the Dashboard keymaps, with the `desc` of each. Keys every layout
-- of the Dashboard keeps, so this says nothing about the order `g?` lists.
local KEYMAPS = {
    q = 'Close the Dashboard',
    ['<CR>'] = 'Go to the Agent block or Session',
    r = 'Refresh the Dashboard',
}

-- The plugin file, which holds the session autocmds. It is loaded again even
-- when an earlier test loaded it.
local function load_plugin()
    vim.g.loaded_rexai = nil
    vim.cmd('runtime plugin/rexai.lua')
end

-- The live Dashboard: rendered from a snapshot and with its keymaps.
---@param buf integer
local function assert_live(buf)
    assert.is_true(vim.api.nvim_buf_is_valid(buf))
    assert.are.equal('rexai', vim.bo[buf].filetype)
    assert.are.equal('', vim.bo[buf].buftype)

    -- The lines come from the Backend, so the poller ran and drew.
    local text =
        table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
    assert.is_not_nil(text:find('orbit', 1, true))
    assert.is_not_nil(text:find('the docs', 1, true))

    local maps = {}
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
        maps[map.lhs] = map.desc
    end
    for lhs, desc in pairs(KEYMAPS) do
        assert.are.equal(desc, maps[lhs])
    end
end

-- The Dashboard a session load leaves: the one buffer under the name, shown in
-- `win`.
---@param win integer the window the session gave the Dashboard
local function assert_dashboard(win)
    local buf = vim.fn.bufnr(dashboard.NAME)
    assert.are_not.equal(-1, buf)
    assert.are.equal(buf, vim.api.nvim_win_get_buf(win))
    assert_live(buf)
end

describe('a session that holds the Dashboard', function()
    local h
    local cwd

    before_each(function()
        h = support.new()
        cwd = vim.fn.getcwd()
    end)

    after_each(function()
        vim.cmd('cd ' .. vim.fn.fnameescape(cwd))
        vim.cmd('silent! only')
        vim.cmd('silent! tabonly')
        h:close()
    end)

    it('sources over an open Dashboard', function()
        local session = vim.fn.tempname()
        local win = vim.api.nvim_get_current_win()
        h:command({ snapshots = { ONE } })
        assert.is_not_nil(h:buf())
        vim.cmd('mksession! ' .. vim.fn.fnameescape(session))

        vim.cmd('source ' .. vim.fn.fnameescape(session))

        assert_dashboard(win)
    end)

    it('gives the Dashboard back to two windows', function()
        local session = vim.fn.tempname()
        h:command({ snapshots = { ONE } })
        vim.cmd('vsplit')
        vim.cmd('mksession! ' .. vim.fn.fnameescape(session))

        vim.cmd('source ' .. vim.fn.fnameescape(session))

        local wins = vim.api.nvim_tabpage_list_wins(0)
        assert.are.equal(2, #wins)
        assert_dashboard(wins[1])
        assert_dashboard(wins[2])
    end)

    it('gives the Dashboard back to two Tabpages', function()
        local session = vim.fn.tempname()
        h:command({ snapshots = { ONE } })
        vim.cmd('tab split')
        vim.cmd('mksession! ' .. vim.fn.fnameescape(session))

        vim.cmd('source ' .. vim.fn.fnameescape(session))

        local tabs = vim.api.nvim_list_tabpages()
        assert.are.equal(2, #tabs)
        for _, tab in ipairs(tabs) do
            local wins = vim.api.nvim_tabpage_list_wins(tab)
            assert.are.equal(1, #wins)
            assert_dashboard(wins[1])
        end
    end)

    it('gives two windows the Dashboard back after a wipe', function()
        local session = vim.fn.tempname()
        h:command({ snapshots = { ONE } })
        vim.cmd('vsplit')
        vim.cmd('mksession! ' .. vim.fn.fnameescape(session))
        h:wipe(assert(h:buf()))
        assert.are.equal(-1, vim.fn.bufnr(dashboard.NAME))

        vim.cmd('source ' .. vim.fn.fnameescape(session))

        local wins = vim.api.nvim_tabpage_list_wins(0)
        assert.are.equal(2, #wins)
        assert_dashboard(wins[1])
        assert_dashboard(wins[2])
    end)

    it('shows a live Dashboard where it had none before', function()
        local session = vim.fn.tempname()
        local win = vim.api.nvim_get_current_win()
        h:command({ snapshots = { ONE } })
        vim.cmd('mksession! ' .. vim.fn.fnameescape(session))
        -- This Neovim starts with no Dashboard, as the one `:restart` starts
        -- does before the session loads.
        vim.api.nvim_buf_delete(assert(h:buf()), { force = true })
        assert.are.equal(-1, vim.fn.bufnr(dashboard.NAME))

        vim.cmd('source ' .. vim.fn.fnameescape(session))

        assert_dashboard(win)
    end)

    it('leaves a hidden Dashboard for a session without one', function()
        local session = vim.fn.tempname()
        h:command({ snapshots = { ONE } })
        local buf = assert(h:buf())
        vim.cmd('enew')
        vim.cmd('mksession! ' .. vim.fn.fnameescape(session))

        vim.cmd('source ' .. vim.fn.fnameescape(session))

        -- The same buffer, hidden and whole: the session gave no window the
        -- Dashboard, so nothing had to wipe it to make room for the name.
        assert.are.equal(buf, vim.fn.bufnr(dashboard.NAME))
        assert.are.same({}, vim.fn.win_findbuf(buf))
        assert_live(buf)
    end)

    it('makes no Dashboard buffer for a session without one', function()
        local session = vim.fn.tempname()
        local notes = vim.fn.tempname() .. '.txt'
        vim.fn.writefile({ 'notes' }, notes)
        local win = vim.api.nvim_get_current_win()
        load_plugin()
        vim.cmd('edit ' .. vim.fn.fnameescape(notes))
        vim.cmd('mksession! ' .. vim.fn.fnameescape(session))
        vim.cmd('enew')

        vim.cmd('source ' .. vim.fn.fnameescape(session))

        assert.are.equal(-1, vim.fn.bufnr(dashboard.NAME))
        assert.are.equal(win, vim.api.nvim_get_current_win())
        assert.are.same(
            { 'notes' },
            vim.api.nvim_buf_get_lines(
                vim.api.nvim_win_get_buf(win),
                0,
                -1,
                false
            )
        )
        os.remove(notes)
    end)
end)
