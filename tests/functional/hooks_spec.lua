-- The three user hooks: `resolve_path` decides the directory a row stands
-- for, `review` receives the context of the row the `o` key is on, and
-- `session_name` names a new Session. All are plain functions read from the
-- config at call time.

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

        it('reports that no review function is set', function()
            hooks.new({ notify = told.notify }):review(ctx())

            assert.are.equal(1, #told.calls)
            assert.are.equal(vim.log.levels.INFO, told.calls[1].level)
            assert.are.equal(
                'rexai: no review function is set; add review = '
                    .. 'function(ctx) ... end to setup()',
                told.calls[1].message
            )
        end)

        it('calls the hook with the context', function()
            local got
            config.setup({
                review = function(given)
                    got = given
                end,
            })
            local wanted = ctx()

            hooks.new({ notify = told.notify }):review(wanted)

            assert.are.equal(wanted, got)
            assert.are.same({}, told.calls)
        end)

        it('reports a throwing hook', function()
            config.setup({
                review = function()
                    error('boom', 0)
                end,
            })

            hooks.new({ notify = told.notify }):review(ctx())

            assert.are.equal(1, #told.calls)
            assert.are.equal(vim.log.levels.WARN, told.calls[1].level)
            assert.are.equal(
                'rexai: review failed: boom',
                told.calls[1].message
            )
        end)

        it('honors a setup after the object was made', function()
            local object = hooks.new({ notify = told.notify })
            object:review(ctx())

            local ran = false
            config.setup({
                review = function()
                    ran = true
                end,
            })

            object:review(ctx())
            assert.is_true(ran)
            assert.are.equal(1, #told.calls)
        end)
    end)

    describe('session_name', function()
        it('gives what the hook returned for the path', function()
            config.setup({
                session_name = function()
                    return 'feature-42'
                end,
            })

            assert.are.equal(
                'feature-42',
                hooks.new({ notify = told.notify }):session_name('/work/orbit')
            )
            assert.are.same({}, told.calls)
        end)

        it('honors a setup after the object was made', function()
            local object = hooks.new({ notify = told.notify })
            assert.is_nil(object:session_name('/work/orbit'))

            config.setup({
                session_name = function()
                    return 'later'
                end,
            })

            assert.are.equal('later', object:session_name('/work/orbit'))
        end)

        it('warns once per object for a throwing hook', function()
            config.setup({
                session_name = function()
                    error('boom', 0)
                end,
            })
            local object = hooks.new({ notify = told.notify })

            for _ = 1, 3 do
                assert.is_nil(object:session_name('/work/orbit'))
            end

            assert.are.equal(1, #told.calls)
            assert.are.equal(vim.log.levels.WARN, told.calls[1].level)
            assert.are.equal(
                'rexai: session_name failed: boom',
                told.calls[1].message
            )

            -- A second object is a second Dashboard, so it warns again.
            hooks.new({ notify = told.notify }):session_name('/work/orbit')
            assert.are.equal(2, #told.calls)
        end)

        it('has its own latch, independent of resolve_path', function()
            config.setup({
                resolve_path = function()
                    error('path boom', 0)
                end,
                session_name = function()
                    error('name boom', 0)
                end,
            })

            -- A failing `resolve_path` first.
            local object = hooks.new({ notify = told.notify })
            object:resolve(row())
            object:session_name('/work/orbit')

            assert.are.equal(2, #told.calls)
            assert.are.equal(
                'rexai: resolve_path failed: path boom',
                told.calls[1].message
            )
            assert.are.equal(
                'rexai: session_name failed: name boom',
                told.calls[2].message
            )

            -- And a failing `session_name` first.
            told.calls = {}
            object = hooks.new({ notify = told.notify })
            object:session_name('/work/orbit')
            object:resolve(row())

            assert.are.equal(2, #told.calls)
            assert.are.equal(
                'rexai: session_name failed: name boom',
                told.calls[1].message
            )
            assert.are.equal(
                'rexai: resolve_path failed: path boom',
                told.calls[2].message
            )
        end)

        it('gives nothing and warns nothing for an unusable result', function()
            ---@param value any
            local function with(value)
                config.setup({
                    session_name = function()
                        return value
                    end,
                })
                return hooks
                    .new({ notify = told.notify })
                    :session_name('/work/orbit')
            end

            assert.is_nil(with(nil))
            assert.is_nil(with(''))
            assert.is_nil(with(42))
            assert.is_nil(with(true))
            assert.is_nil(with({}))
            assert.are.same({}, told.calls)
        end)

        it('gives nil, and warns nothing, with no hook set', function()
            local object = hooks.new({ notify = told.notify })

            assert.is_nil(object:session_name('/work/orbit'))

            config.setup({ session_name = 'not a function' })
            assert.is_nil(object:session_name('/work/orbit'))

            assert.are.same({}, told.calls)
        end)

        it('calls the hook with the path alone', function()
            local got = { count = 0 }
            config.setup({
                session_name = function(...)
                    got = { count = select('#', ...), first = ... }
                    return 'feature-42'
                end,
            })

            hooks.new({ notify = told.notify }):session_name('/work/orbit')

            assert.are.equal(1, got.count)
            assert.are.equal('/work/orbit', got.first)
        end)
    end)
end)
