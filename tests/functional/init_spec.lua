-- The plugin API: `setup` for the options and the highlight groups, `open`
-- for the Dashboard.

local config = require('rexai.config')
local fake = require('rexai.backend.fake')
local rexai = require('rexai')
local snap = require('tests.snapshots')

-- A snapshot with one Agent block and no timestamp, so no clock shows.
local SNAPSHOT = snap.single({ id = 'block:b1', app = 'pi' })

---@param backend rexai.Backend
local function stub_rex(backend)
    package.loaded['rexai.backend.rex'] = {
        new = function()
            return backend
        end,
    }
end

local function close()
    package.loaded['rexai.backend.rex'] = nil
    local buf = vim.fn.bufnr('rexai://dashboard')
    if buf == -1 then
        return
    end
    local replacement = vim.api.nvim_create_buf(true, false)
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
        vim.api.nvim_win_set_buf(win, replacement)
    end
    vim.api.nvim_buf_delete(buf, { force = true })
    vim.api.nvim_buf_delete(replacement, { force = true })
end

describe('rexai', function()
    describe('open', function()
        it('opens the Dashboard with the default options', function()
            -- Nothing called `setup`, so the defaults are in force.
            assert.are.equal(config.defaults, config.get())
            stub_rex(fake.new({ snapshots = { SNAPSHOT } }))

            rexai.open()

            assert.are_not.equal(-1, vim.fn.bufnr('rexai://dashboard'))
            assert.is_true(#vim.api.nvim_buf_get_lines(0, 0, -1, false) > 0)
            -- The highlight groups are defined without a `setup` call.
            assert.are.equal(
                'DiagnosticWarn',
                vim.api.nvim_get_hl(0, { name = 'RexaiNeedsInput' }).link
            )
            close()
        end)
    end)

    describe('setup', function()
        it('merges the options over the defaults', function()
            rexai.setup({ refresh_ms = 50, show_exited = false })

            assert.are.equal(50, config.get().refresh_ms)
            assert.is_false(config.get().show_exited)
            assert.are.equal(
                config.defaults.title_width,
                config.get().title_width
            )
            assert.are.equal('rex', config.get().rex_bin)
        end)

        it('keeps one ColorScheme autocmd when called twice', function()
            rexai.setup()
            rexai.setup()

            local autocmds =
                vim.api.nvim_get_autocmds({ group = 'RexaiHighlights' })
            assert.are.equal(1, #autocmds)
            assert.are.equal('ColorScheme', autocmds[1].event)
        end)

        it('links every group to its Diagnostic default', function()
            rexai.setup()

            assert.are.equal(
                'DiagnosticWarn',
                vim.api.nvim_get_hl(0, { name = 'RexaiNeedsInput' }).link
            )
            assert.are.equal(
                'Comment',
                vim.api.nvim_get_hl(0, { name = 'RexaiDim' }).link
            )
        end)

        it(
            'leaves a definition of the user alone on a colorscheme change',
            function()
                rexai.setup()
                vim.api.nvim_set_hl(0, 'RexaiHeader', { link = 'ErrorMsg' })

                vim.api.nvim_exec_autocmds('ColorScheme', {})

                assert.are.equal(
                    'ErrorMsg',
                    vim.api.nvim_get_hl(0, { name = 'RexaiHeader' }).link
                )
            end
        )
    end)
end)
