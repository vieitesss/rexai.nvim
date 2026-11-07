-- The two user hooks: `resolve_path` decides the directory a row stands for
-- and `review` receives the context of the row the `d` key is on. Both are
-- plain functions read from the config at call time.

local config = require('rexai.config')
local hooks = require('rexai.hooks')

-- One invented Agent row, the shape `core.model` gives.
---@return rexai.Row
local function row()
    return {
        session_id = 'session:orbit',
        window_id = 'window:api',
        block_id = 'block:b1',
        harness = 'pi',
        status = 'working',
        updated_at = '2026-01-01T10:00:00+00:00',
        title = 'the parser',
        cwd = '/work/orbit',
    }
end

---@return table a notifier that records what it was told
local function notifier()
    local out = { calls = {} }

    function out.notify(message, level)
        out.calls[#out.calls + 1] = { message = message, level = level }
    end

    return out
end

describe('hooks', function()
    local told

    before_each(function()
        config.setup()
        told = notifier()
    end)

    after_each(function()
        config.setup()
    end)

    describe('resolve', function()
        it('gives the directory of the Block when no hook is set', function()
            local object = hooks.new({ notify = told.notify })
            assert.are.equal('/work/orbit', object:resolve(row()))
        end)

        it('gives nil for a Block without a directory', function()
            config.setup({})
            local bare = row()
            bare.cwd = nil
            assert.is_nil(hooks.new({ notify = told.notify }):resolve(bare))

            local empty = row()
            empty.cwd = ''
            assert.is_nil(hooks.new({ notify = told.notify }):resolve(empty))
        end)

        it('uses what the hook returns', function()
            config.setup({
                resolve_path = function()
                    return '/work/vendored'
                end,
            })
            assert.are.equal(
                '/work/vendored',
                hooks.new({ notify = told.notify }):resolve(row())
            )
            assert.are.same({}, told.calls)
        end)

        it(
            'gives the directory of the Block for nil or an empty string',
            function()
                ---@param value string|nil
                local function with(value)
                    config.setup({
                        resolve_path = function()
                            return value
                        end,
                    })
                    return hooks.new({ notify = told.notify }):resolve(row())
                end

                assert.are.equal('/work/orbit', with(nil))
                assert.are.equal('/work/orbit', with(''))
                assert.are.same({}, told.calls)
            end
        )

        it('hands the hook a copy, so the row stays as it was', function()
            config.setup({
                resolve_path = function(block)
                    block.cwd = '/work/elsewhere'
                    block.title = 'gone'
                    table.insert(block, 'junk')
                    return '/work/vendored'
                end,
            })
            local given = row()
            hooks.new({ notify = told.notify }):resolve(given)

            assert.are.equal('/work/orbit', given.cwd)
            assert.are.equal('the parser', given.title)
        end)

        it(
            'reports a throwing hook once and still gives the directory',
            function()
                config.setup({
                    resolve_path = function()
                        error('boom')
                    end,
                })
                local object = hooks.new({ notify = told.notify })

                for _ = 1, 3 do
                    assert.are.equal('/work/orbit', object:resolve(row()))
                end

                assert.are.equal(1, #told.calls)
                assert.are.equal(vim.log.levels.WARN, told.calls[1].level)
                assert.is_truthy(
                    told.calls[1].message:find('rexai: resolve_path', 1, true)
                )
            end
        )

        it('reports a wrong return type once', function()
            config.setup({
                resolve_path = function()
                    return 42
                end,
            })
            local object = hooks.new({ notify = told.notify })

            for _ = 1, 3 do
                assert.are.equal('/work/orbit', object:resolve(row()))
            end

            assert.are.equal(1, #told.calls)
            assert.are.equal(vim.log.levels.WARN, told.calls[1].level)
            assert.is_truthy(
                told.calls[1].message:find('rexai: resolve_path', 1, true)
            )
        end)

        it('honors a setup after the object was made', function()
            local object = hooks.new({ notify = told.notify })
            assert.are.equal('/work/orbit', object:resolve(row()))

            config.setup({
                resolve_path = function()
                    return '/work/later'
                end,
            })

            assert.are.equal('/work/later', object:resolve(row()))
        end)
    end)

    describe('review', function()
        -- One invented context, the shape the Dashboard builds.
        ---@return table
        local function ctx()
            return {
                path = '/work/orbit',
                repo_root = '/work/orbit',
                branch = 'main',
                session = { id = 'session:orbit', label = 'orbit' },
                window = { id = 'window:api' },
                block = row(),
            }
        end

        it(
            'reports that no review function is set, and returns false',
            function()
                assert.is_false(
                    hooks.new({ notify = told.notify }):review(ctx())
                )

                assert.are.equal(1, #told.calls)
                assert.are.equal(vim.log.levels.INFO, told.calls[1].level)
                assert.are.equal(
                    'rexai: no review function is set; add review = '
                        .. 'function(ctx) ... end to setup()',
                    told.calls[1].message
                )
            end
        )

        it('calls the hook with the context and returns true', function()
            local got
            config.setup({
                review = function(given)
                    got = given
                end,
            })
            local wanted = ctx()

            assert.is_true(hooks.new({ notify = told.notify }):review(wanted))

            assert.are.equal(wanted, got)
            assert.are.same({}, told.calls)
        end)

        it('reports a throwing hook, and returns false', function()
            config.setup({
                review = function()
                    error('boom', 0)
                end,
            })

            assert.is_false(hooks.new({ notify = told.notify }):review(ctx()))

            assert.are.equal(1, #told.calls)
            assert.are.equal(vim.log.levels.WARN, told.calls[1].level)
            assert.are.equal(
                'rexai: review failed: boom',
                told.calls[1].message
            )
        end)

        it('honors a setup after the object was made', function()
            local object = hooks.new({ notify = told.notify })
            assert.is_false(object:review(ctx()))

            local ran = false
            config.setup({
                review = function()
                    ran = true
                end,
            })

            assert.is_true(object:review(ctx()))
            assert.is_true(ran)
            assert.are.equal(1, #told.calls)
        end)
    end)
end)
