local config = require('rexai.config')
local core_defaults = require('rexai.core.defaults')
local status = require('rexai.core.status')

describe('config', function()
    before_each(function()
        config.setup()
    end)

    describe('defaults', function()
        it('holds the Dashboard options', function()
            assert.are.equal(1000, config.defaults.refresh_ms)
            assert.are.equal(true, config.defaults.show_exited)
            assert.are.equal(40, config.defaults.title_width)
        end)

        it('gives one single-width glyph per Agent status', function()
            for _, name in ipairs(status.ORDER) do
                local glyph = config.defaults.glyphs[name]
                assert.are.equal('string', type(glyph))
                assert.are.equal(
                    1,
                    vim.api.nvim_strwidth(glyph),
                    name .. ' glyph is not one cell wide'
                )
            end
        end)

        it('takes the agent detection lists from the core', function()
            assert.are.same(core_defaults.agents, config.defaults.agents)
        end)
    end)

    describe('get', function()
        it('gives the defaults when setup was never called', function()
            local loaded = package.loaded['rexai.config']
            package.loaded['rexai.config'] = nil
            local fresh = require('rexai.config')
            package.loaded['rexai.config'] = loaded

            assert.are.same(fresh.defaults, fresh.get())
            assert.are.same(config.defaults, config.get())
        end)

        it('gives the merged table after setup', function()
            config.setup({ refresh_ms = 250 })
            assert.are.equal(250, config.get().refresh_ms)
        end)
    end)

    describe('setup', function()
        it('overrides one option and keeps the rest', function()
            local merged = config.setup({ show_exited = false })
            assert.are.equal(false, merged.show_exited)
            assert.are.equal(1000, merged.refresh_ms)
            assert.are.equal(40, merged.title_width)
        end)

        it('replaces a list instead of merging it', function()
            config.setup({
                agents = { apps = { 'other-agent' }, commands = { 'zed' } },
            })
            assert.are.same({ 'other-agent' }, config.get().agents.apps)
            assert.are.same({ 'zed' }, config.get().agents.commands)
        end)

        it('replaces one glyph and keeps the others', function()
            config.setup({ glyphs = { working = '>' } })
            assert.are.equal('>', config.get().glyphs.working)
            assert.are.equal(
                config.defaults.glyphs.needs_input,
                config.get().glyphs.needs_input
            )
        end)

        it('does not change the defaults', function()
            local glyph = config.defaults.glyphs.idle
            config.setup({
                refresh_ms = 5,
                glyphs = { idle = 'Z' },
                agents = { apps = { 'other-agent' } },
            })
            assert.are.same(core_defaults.agents, config.defaults.agents)
            assert.are.equal(1000, config.defaults.refresh_ms)
            assert.are.equal(glyph, config.defaults.glyphs.idle)
        end)

        it('goes back to the defaults when given no options', function()
            config.setup({ refresh_ms = 5, show_exited = false })
            config.setup()
            assert.are.same(config.defaults, config.get())
        end)

        it('returns the merged table', function()
            local merged = config.setup({ refresh_ms = 7 })
            assert.are.same(config.get(), merged)
            assert.are.equal(7, merged.refresh_ms)
        end)
    end)
end)
