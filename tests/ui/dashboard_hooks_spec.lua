-- The two user hooks in the Dashboard: `resolve_path` decides the directory
-- a row stands for (git and the `o` key use it), and `o` hands the row under
-- the cursor to `review`. The fake Backend serves invented snapshots, and the
-- git runner, git clock and timer are seams.

local config = require('rexai.config')
local model = require('rexai.core.model')
local render = require('rexai.ui.render')
local snap = require('tests.snapshots')
local support = require('tests.ui_support')

-- Not the Session this Neovim runs in, so no Home header shows up by itself.
local HOME = 'session:home'
-- The status git prints for a clean branch.
local CLEAN = table.concat({
    '# branch.oid 1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b',
    '# branch.head main',
    '# branch.upstream origin/main',
    '# branch.ab +0 -0',
}, '\n')
-- What `git rev-parse --show-toplevel` prints for the row in a work tree.
local ROOT = '/work/orbit\n'
-- Where the hook sends the row of `block:b1`, a directory of its own.
local HOOKED = '/work/vendored'

-- One Agent block in a work tree, and one that has no directory at all.
local SNAPSHOT = snap.snapshot({
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
                        state = 'done',
                        title = 'the docs',
                        cwd = '/work/orbit',
                        updated_at = '2026-11-07T16:12:00Z',
                    }),
                    snap.block({
                        id = 'block:b2',
                        app = 'claude-code',
                        state = 'working',
                        title = 'the parser',
                        updated_at = '2026-11-07T15:15:00Z',
                    }),
                },
            }),
        },
    }),
})

---@param snapshot table
---@return table<integer, rexai.RenderTarget>
local function targets_of(snapshot)
    return render.build(
        model.build(snapshot, config.get().agents),
        { now = support.NOW, home_session_id = HOME }
    ).targets
end

describe('ui.dashboard hooks', function()
    local h

    before_each(function()
        h = support.new()
    end)

    after_each(function()
        h:close()
    end)

    ---@return string[] the paths git was pointed at with `-C`
    local function paths()
        local out = {}
        for _, argv in ipairs(h.git.calls) do
            if argv[2] == '-C' then
                out[#out + 1] = argv[3]
            elseif argv[3] == '-C' then
                out[#out + 1] = argv[4]
            end
        end
        return out
    end

    ---@param snapshot table
    ---@return table the Backend
    ---@return table[] every Backend call, in order
    local function open_with(snapshot)
        return h:open({
            snapshots = { snapshot },
            home_session_id = HOME,
        })
    end

    ---@param block_id string
    local function put_cursor_on(snapshot, block_id)
        vim.api.nvim_win_set_cursor(vim.api.nvim_get_current_win(), {
            support.line_of(targets_of(snapshot), block_id),
            0,
        })
    end

    describe('resolve_path', function()
        it('is what git is asked about', function()
            config.setup({
                resolve_path = function(block)
                    if block.block_id == 'block:b1' then
                        return HOOKED
                    end
                end,
            })
            open_with(SNAPSHOT)

            assert.are.same({ HOOKED }, paths())
            h.git.answer(CLEAN, ROOT)
            support.flush()

            -- The work tree root is asked about the same path.
            assert.are.same({ HOOKED, HOOKED }, paths())
            -- The row without a hook result and without a directory is not
            -- asked about at all.
            assert.are.equal(2, #h.git.calls)
        end)

        it('runs once per row and snapshot, and not again on x', function()
            local seen = {}
            config.setup({
                resolve_path = function(block)
                    seen[#seen + 1] = block.block_id
                end,
            })
            -- `block:b1` ends in the second snapshot, and stays listed as an
            -- Exited row.
            local gone = snap.snapshot({
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
                                    argv0 = '/bin/zsh',
                                    title = 'the docs',
                                    last_exit = { exit_code = 3 },
                                }),
                                snap.block({
                                    id = 'block:b2',
                                    app = 'claude-code',
                                    state = 'working',
                                    title = 'the parser',
                                }),
                            },
                        }),
                    },
                }),
            })
            h:open({
                snapshots = { SNAPSHOT, gone },
                home_session_id = HOME,
            })
            assert.are.same({ 'block:b1', 'block:b2' }, seen)

            h:press('x')
            assert.are.same({ 'block:b1', 'block:b2' }, seen)

            h.timer.fire()
            assert.are.same(
                { 'block:b1', 'block:b2', 'block:b1', 'block:b2' },
                seen
            )

            -- The Exited row is hidden now, and the hook still does not run.
            h:press('x')
            assert.are.equal(4, #seen)
        end)

        it('reports a throwing hook once and git gets the cwd', function()
            config.setup({
                resolve_path = function()
                    error('boom')
                end,
            })
            open_with(SNAPSHOT)
            h.timer.fire()
            h.timer.fire()
            support.flush()

            assert.are.equal(1, #h.notify.calls)
            assert.are.equal(vim.log.levels.WARN, h.notify.calls[1].level)
            assert.is_truthy(
                h.notify.calls[1].message:find('rexai: resolve_path', 1, true)
            )
            assert.are.equal('/work/orbit', paths()[1])
        end)
    end)

    describe('o', function()
        -- One Session with one Agent block in a work tree.
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
                                state = 'done',
                                title = 'the docs',
                                cwd = '/work/orbit',
                                updated_at = '2026-11-07T16:12:00Z',
                            }),
                        },
                    }),
                },
            }),
        })

        -- The row the model builds for that Block.
        local ROW = {
            session_id = 'session:s1',
            window_id = 'window:w1',
            block_id = 'block:b1',
            harness = 'pi',
            status = 'done',
            updated_at = '2026-11-07T16:12:00Z',
            title = 'the docs',
            cwd = '/work/orbit',
            label = 'api',
        }

        it('gives review the context of the row', function()
            local got = {}
            config.setup({
                review = function(ctx)
                    got[#got + 1] = ctx
                end,
            })
            open_with(ONE)
            h.git.answer(CLEAN, ROOT)
            support.flush()
            put_cursor_on(ONE, 'block:b1')

            h:press('o')

            assert.are.equal(1, #got)
            assert.are.same({
                path = '/work/orbit',
                repo_root = '/work/orbit',
                branch = 'main',
                session = { id = 'session:s1', label = 'orbit' },
                window = { id = 'window:w1' },
                block = ROW,
            }, got[1])
            assert.are.same({}, h.notify.calls)
        end)

        it(
            'gives the resolved path and leaves git fields nil until git answers',
            function()
                local got
                config.setup({
                    resolve_path = function()
                        return HOOKED
                    end,
                    review = function(ctx)
                        got = ctx
                    end,
                })
                open_with(ONE)
                put_cursor_on(ONE, 'block:b1')

                h:press('o')

                assert.are.equal(HOOKED, got.path)
                assert.is_nil(got.repo_root)
                assert.is_nil(got.branch)
            end
        )

        it('reports a Session header and calls nothing', function()
            local calls = 0
            config.setup({
                review = function()
                    calls = calls + 1
                end,
            })
            open_with(ONE)
            vim.api.nvim_win_set_cursor(vim.api.nvim_get_current_win(), {
                1,
                0,
            })

            h:press('o')

            assert.are.equal(0, calls)
            assert.are.equal(1, #h.notify.calls)
            assert.are.equal(vim.log.levels.INFO, h.notify.calls[1].level)
            assert.are.equal(
                'rexai: put the cursor on an Agent block',
                h.notify.calls[1].message
            )
        end)

        it('reports a row without a directory and calls nothing', function()
            local calls = 0
            config.setup({
                review = function()
                    calls = calls + 1
                end,
            })
            local bare = snap.snapshot({
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
                                    state = 'done',
                                    title = 'the docs',
                                }),
                            },
                        }),
                    },
                }),
            })
            open_with(bare)
            put_cursor_on(bare, 'block:b1')

            h:press('o')

            assert.are.equal(0, calls)
            assert.are.equal(1, #h.notify.calls)
            assert.are.equal(vim.log.levels.INFO, h.notify.calls[1].level)
            assert.are.equal(
                'rexai: this Block has no directory to review',
                h.notify.calls[1].message
            )
        end)

        it('reports that no review function is set', function()
            open_with(ONE)
            put_cursor_on(ONE, 'block:b1')

            h:press('o')

            assert.are.equal(1, #h.notify.calls)
            assert.are.equal(vim.log.levels.INFO, h.notify.calls[1].level)
            assert.are.equal(
                'rexai: no review function is set; add review = '
                    .. 'function(ctx) ... end to setup()',
                h.notify.calls[1].message
            )
        end)

        it(
            'reports a throwing review and keeps the Dashboard working',
            function()
                config.setup({
                    review = function()
                        error('boom', 0)
                    end,
                })
                local _, calls = open_with(ONE)
                assert.are.equal(1, support.count(calls, 'snapshot'))
                put_cursor_on(ONE, 'block:b1')

                h:press('o')

                assert.are.equal(1, #h.notify.calls)
                assert.are.equal(vim.log.levels.WARN, h.notify.calls[1].level)
                assert.are.equal(
                    'rexai: review failed: boom',
                    h.notify.calls[1].message
                )
                -- The Session header, the two lines of the row, and the Home
                -- session header.
                assert.are.equal(5, #h:lines())

                -- `r` still asks Rex, so the Dashboard is not stuck.
                h:press('r')
                h.timer.fire()
                support.flush()
                assert.are.equal(3, support.count(calls, 'snapshot'))
            end
        )
    end)
end)
