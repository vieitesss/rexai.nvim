-- The two user hooks in the Dashboard: `resolve_path` decides the directory
-- a row stands for (git and the `d` key use it), and `d` hands the row under
-- the cursor to `review`. The fake Backend serves invented snapshots, and the
-- git runner, git clock and timer are seams.

local config = require('rexai.config')
local dashboard = require('rexai.ui.dashboard')
local fake = require('rexai.backend.fake')
local model = require('rexai.core.model')
local render = require('rexai.ui.render')
local snap = require('tests.snapshots')

local NAME = 'rexai://dashboard'
-- 2026-11-07T16:15:00Z, so the ages never move.
local NOW = 1794068100
-- Not the Session this Neovim runs in, so no Home header shows up by itself.
local HOME = 'session:home'
-- The status git prints for a clean branch.
local CLEAN = table.concat({
    '# branch.oid 1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b',
    '# branch.head main',
    '# branch.upstream origin/main',
    '# branch.ab +0 -0',
}, '\n')
-- Where the hook sends the row of `block:b1`, a directory of its own.
local HOOKED = '/work/vendored'

-- A timer the test fires by hand.
local function fake_timer()
    local timer = { pending = {} }

    function timer.after(ms, callback)
        local entry = { ms = ms, callback = callback }
        table.insert(timer.pending, entry)
        return function()
            for index, pending in ipairs(timer.pending) do
                if pending == entry then
                    table.remove(timer.pending, index)
                    return
                end
            end
        end
    end

    function timer.fire()
        local entry = table.remove(timer.pending, 1)
        assert.is_not_nil(entry, 'nothing is scheduled')
        entry.callback()
    end

    return timer
end

-- The git runner seam: the test answers every call, in order.
local function runner()
    local r = { queue = {}, calls = {} }

    function r.run(argv, callback)
        r.queue[#r.queue + 1] = { argv = argv, callback = callback }
        r.calls[#r.calls + 1] = argv
    end

    ---@return table the oldest call the test has not answered
    function r.next()
        local call = table.remove(r.queue, 1)
        assert.is_not_nil(call, 'no git call is waiting')
        return call
    end

    -- Answers the status call, then the work tree root call.
    ---@param status string|nil
    ---@param root string|nil
    function r.answer(status, root)
        r.next().callback(nil, status or CLEAN)
        r.next().callback(nil, root or '/work/orbit\n')
    end

    ---@return string[] the paths git was pointed at with `-C`
    function r.paths()
        local out = {}
        for _, argv in ipairs(r.calls) do
            if argv[2] == '-C' then
                out[#out + 1] = argv[3]
            elseif argv[3] == '-C' then
                out[#out + 1] = argv[4]
            end
        end
        return out
    end

    return r
end

---@return table a clock the test moves by hand, in milliseconds
local function fake_clock()
    local clock = { ms = 1000 }
    function clock.now()
        return clock.ms
    end
    function clock.advance(ms)
        clock.ms = clock.ms + ms
    end
    return clock
end

---@param calls table[]
---@return integer how many snapshots the Dashboard asked for
local function snapshot_calls(calls)
    local total = 0
    for _, call in ipairs(calls) do
        if call.method == 'snapshot' then
            total = total + 1
        end
    end
    return total
end

---@return table a notifier that records what it was told
local function notifier()
    local out = { calls = {} }

    function out.notify(message, level)
        out.calls[#out.calls + 1] = { message = message, level = level }
    end

    return out
end

-- Lets every callback `vim.schedule` queued run.
local function flush()
    local done = false
    vim.schedule(function()
        done = true
    end)
    assert.is_true(vim.wait(500, function()
        return done
    end, 1))
end

-- Types `keys` in normal mode and waits for the Dashboard to handle them.
---@param keys string
local function press(keys)
    vim.api.nvim_feedkeys(vim.keycode(keys), 'x', false)
end

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

---@return integer|nil
local function dashboard_buf()
    local buf = vim.fn.bufnr(NAME)
    if buf == -1 then
        return nil
    end
    return buf
end

---@return string[]
local function dashboard_lines()
    return vim.api.nvim_buf_get_lines(dashboard_buf(), 0, -1, false)
end

---@param targets table<integer, rexai.RenderTarget>
---@param block_id string
---@return integer
local function line_of(targets, block_id)
    for line, target in pairs(targets) do
        if target.block_id == block_id then
            return line
        end
    end
    error('no line for ' .. block_id)
end

---@param snapshot table
---@return table<integer, rexai.RenderTarget>
local function targets_of(snapshot)
    return render.build(
        model.build(snapshot, config.get().agents),
        { now = NOW, home_session_id = HOME }
    ).targets
end

describe('ui.dashboard hooks', function()
    local timer, scratch, r, clock, told, real_notify

    before_each(function()
        config.setup()
        scratch = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_win_set_buf(0, scratch)
        timer, r, clock, told = fake_timer(), runner(), fake_clock(), notifier()
        -- The `d` key reports through `vim.notify`; the hooks object gets the
        -- same recorder as its test seam.
        real_notify = vim.notify
        vim.notify = told.notify
        vim.env.REX_SESSION = nil
    end)

    after_each(function()
        vim.notify = real_notify
        local buf = dashboard_buf()
        if buf then
            if vim.api.nvim_buf_is_valid(scratch) then
                for _, win in ipairs(vim.fn.win_findbuf(buf)) do
                    if vim.api.nvim_win_is_valid(win) then
                        vim.api.nvim_win_set_buf(win, scratch)
                    end
                end
            end
            pcall(vim.api.nvim_buf_delete, buf, { force = true })
        end
        if vim.api.nvim_buf_is_valid(scratch) then
            vim.api.nvim_buf_delete(scratch, { force = true })
        end
        config.setup()
    end)

    ---@param snapshot table
    ---@return table the Backend
    ---@return table[] every Backend call, in order
    local function open_with(snapshot)
        local backend, calls = fake.new({ snapshots = { snapshot } })
        dashboard.open({
            backend = backend,
            after = timer.after,
            now = function()
                return NOW
            end,
            home_session_id = HOME,
            git = { run = r.run, clock = clock.now },
            hooks = { notify = told.notify },
        })
        return backend, calls
    end

    ---@param block_id string
    local function put_cursor_on(snapshot, block_id)
        vim.api.nvim_win_set_cursor(vim.api.nvim_get_current_win(), {
            line_of(targets_of(snapshot), block_id),
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

            assert.are.same({ HOOKED }, r.paths())
            r.answer()
            flush()

            -- The work tree root is asked about the same path.
            assert.are.same({ HOOKED, HOOKED }, r.paths())
            -- The row without a hook result and without a directory is not
            -- asked about at all.
            assert.are.equal(2, #r.calls)
        end)

        it('runs once per row and snapshot, and not again on e', function()
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
            local backend = fake.new({ snapshots = { SNAPSHOT, gone } })
            dashboard.open({
                backend = backend,
                after = timer.after,
                now = function()
                    return NOW
                end,
                home_session_id = HOME,
                git = { run = r.run, clock = clock.now },
                hooks = { notify = told.notify },
            })
            assert.are.same({ 'block:b1', 'block:b2' }, seen)

            press('e')
            assert.are.same({ 'block:b1', 'block:b2' }, seen)

            timer.fire()
            assert.are.same(
                { 'block:b1', 'block:b2', 'block:b1', 'block:b2' },
                seen
            )

            -- The Exited row is hidden now, and the hook still does not run.
            press('e')
            assert.are.equal(4, #seen)
        end)

        it('reports a throwing hook once and git gets the cwd', function()
            config.setup({
                resolve_path = function()
                    error('boom')
                end,
            })
            open_with(SNAPSHOT)
            timer.fire()
            timer.fire()
            flush()

            assert.are.equal(1, #told.calls)
            assert.are.equal(vim.log.levels.WARN, told.calls[1].level)
            assert.is_truthy(
                told.calls[1].message:find('rexai: resolve_path', 1, true)
            )
            assert.are.equal('/work/orbit', r.paths()[1])
        end)
    end)

    describe('d', function()
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
            r.answer()
            flush()
            put_cursor_on(ONE, 'block:b1')

            press('d')

            assert.are.equal(1, #got)
            assert.are.same({
                path = '/work/orbit',
                repo_root = '/work/orbit',
                branch = 'main',
                session = { id = 'session:s1', label = 'orbit' },
                window = { id = 'window:w1' },
                block = ROW,
            }, got[1])
            assert.are.same({}, told.calls)
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

                press('d')

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

            press('d')

            assert.are.equal(0, calls)
            assert.are.equal(1, #told.calls)
            assert.are.equal(vim.log.levels.INFO, told.calls[1].level)
            assert.are.equal(
                'rexai: put the cursor on an Agent block',
                told.calls[1].message
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

            press('d')

            assert.are.equal(0, calls)
            assert.are.equal(1, #told.calls)
            assert.are.equal(vim.log.levels.INFO, told.calls[1].level)
            assert.are.equal(
                'rexai: this Block has no directory to review',
                told.calls[1].message
            )
        end)

        it('reports that no review function is set', function()
            open_with(ONE)
            put_cursor_on(ONE, 'block:b1')

            press('d')

            assert.are.equal(1, #told.calls)
            assert.are.equal(vim.log.levels.INFO, told.calls[1].level)
            assert.are.equal(
                'rexai: no review function is set; add review = '
                    .. 'function(ctx) ... end to setup()',
                told.calls[1].message
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
                assert.are.equal(1, snapshot_calls(calls))
                put_cursor_on(ONE, 'block:b1')

                press('d')

                assert.are.equal(1, #told.calls)
                assert.are.equal(vim.log.levels.WARN, told.calls[1].level)
                assert.are.equal(
                    'rexai: review failed: boom',
                    told.calls[1].message
                )
                -- The Session header, the row, and the Home session header.
                assert.are.equal(4, #dashboard_lines())

                -- `r` still asks Rex, so the Dashboard is not stuck.
                press('r')
                timer.fire()
                flush()
                assert.are.equal(3, snapshot_calls(calls))
            end
        )
    end)
end)
