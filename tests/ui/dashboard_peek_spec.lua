-- The `K` key: a float at the cursor with what is known about the Agent block
-- under it and the last lines of its Block's screen. The fake Backend serves
-- invented snapshots and invented screen text, and the git runner answers by
-- hand.

local config = require('rexai.config')
local dashboard = require('rexai.ui.dashboard')
local fake = require('rexai.backend.fake')
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
-- What `git rev-parse --show-toplevel` prints for a row in a work tree.
local ROOT = '/work/orbit\n'
-- Where the `resolve_path` hook sends the first Agent block, a directory of
-- its own.
local HOOKED = '/work/vendored'
-- The screen of the first Agent block, with a colour and a carriage return.
local SCREEN = '\27[32mthe build is green\27[0m\r\n3 files changed'
-- What the same screen reads as once the control characters are gone.
local PLAIN_FIRST = 'the build is green'
local PLAIN_SECOND = '3 files changed'

-- Two Agent blocks in one Window, both in the work tree.
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
                        msg = 'the tests pass',
                        title = 'the docs',
                        cwd = '/work/orbit',
                        updated_at = '2026-11-07T16:12:00Z',
                    }),
                    snap.block({
                        id = 'block:b2',
                        app = 'claude-code',
                        state = 'working',
                        title = 'the parser',
                        cwd = '/work/orbit',
                        updated_at = '2026-11-07T16:10:00Z',
                    }),
                },
            }),
        },
    }),
})

-- Two Sessions, so a blank line sits between their rows.
local TWO = snap.snapshot({
    snap.session({
        id = 'session:alpha',
        label = 'alpha',
        windows = {
            snap.window({
                id = 'window:w1',
                label = 'api',
                blocks = {
                    snap.block({ id = 'block:k1', app = 'pi', state = 'idle' }),
                },
            }),
        },
    }),
    snap.session({
        id = 'session:beta',
        label = 'beta',
        windows = {
            snap.window({
                id = 'window:w2',
                label = 'web',
                blocks = {
                    snap.block({
                        id = 'block:k2',
                        app = 'claude-code',
                        state = 'idle',
                    }),
                },
            }),
        },
    }),
})

-- A Backend that answers `snapshot` at once and holds every `peek` until the
-- test answers it, so the test decides when a result arrives.
---@param snapshot table
---@return table
local function holding_backend(snapshot)
    local object = { snapshots = 0, targets = {}, pending = {} }

    function object.snapshot(callback)
        object.snapshots = object.snapshots + 1
        callback(nil, snapshot)
    end

    function object.focus(_, callback)
        callback(nil)
    end

    function object.create_window(_, callback)
        callback(nil)
    end

    function object.create_session(_, callback)
        callback(nil)
    end

    function object.peek(target, callback)
        object.targets[#object.targets + 1] = target
        object.pending[#object.pending + 1] = callback
    end

    -- Answers the oldest `peek` call.
    ---@param err string|nil
    ---@param text string|nil
    function object.answer(err, text)
        local callback = table.remove(object.pending, 1)
        assert.is_not_nil(callback, 'no peek call is waiting')
        callback(err, text)
    end

    return object
end

---@param snapshot table
---@return table<integer, rexai.RenderTarget>
local function targets_of(snapshot)
    return render.build(
        model.build(snapshot, config.get().agents),
        { now = support.NOW, home_session_id = HOME }
    ).targets
end

describe('ui.dashboard peek', function()
    local h

    before_each(function()
        h = support.new()
    end)

    after_each(function()
        h:close()
    end)

    ---@param block_id string
    local function put_cursor_on(block_id)
        vim.api.nvim_win_set_cursor(vim.api.nvim_get_current_win(), {
            support.line_of(targets_of(SNAPSHOT), block_id),
            0,
        })
        assert.are.equal(
            block_id,
            dashboard.current_target().block_id,
            'the cursor is on the Agent block'
        )
    end

    ---@param line integer
    local function put_cursor_on_line(line)
        vim.api.nvim_win_set_cursor(vim.api.nvim_get_current_win(), { line, 0 })
    end

    -- Wipes the Dashboard buffer, as `:bwipeout` would: the buffer leaves the
    -- window and every autocmd of the Dashboard fires.
    local function wipe()
        local buf = assert(h:buf())
        for _, win in ipairs(vim.fn.win_findbuf(buf)) do
            if vim.api.nvim_win_is_valid(win) then
                vim.api.nvim_win_set_buf(win, h.scratch)
            end
        end
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
        assert.is_nil(h:buf())
    end

    ---@param lines string[]
    ---@return string
    local function text_of(lines)
        return table.concat(lines, '\n')
    end

    describe('the float', function()
        it(
            'opens with the row, its path, its git slot and its screen',
            function()
                h:open({
                    snapshots = { SNAPSHOT },
                    peek = { ['block:b1'] = SCREEN },
                    home_session_id = HOME,
                })
                h.git.answer(CLEAN, ROOT)
                support.flush()
                put_cursor_on('block:b1')

                h:press('K')

                assert.are.equal(1, #support.floats())
                local lines = assert(h:float_lines())
                assert.are.equal('api pi · pi · done', lines[1])
                assert.are.equal('the tests pass', lines[2])
                assert.are.equal('/work/orbit', lines[3])
                assert.are.equal('orbit · main', lines[4])
                assert.are.equal(PLAIN_FIRST, lines[6])
                assert.are.equal(PLAIN_SECOND, lines[7])
                assert.are.equal(7, #lines)
            end
        )

        it('holds no control character', function()
            h:open({
                snapshots = { SNAPSHOT },
                peek = { ['block:b1'] = SCREEN },
                home_session_id = HOME,
            })
            put_cursor_on('block:b1')

            h:press('K')

            local lines = assert(h:float_lines())
            for _, line in ipairs(lines) do
                assert.is_nil(
                    line:find('%c'),
                    'control character in ' .. vim.inspect(line)
                )
            end
        end)

        it('asks Rex once, for the whole target of the row', function()
            local _, calls = h:open({
                snapshots = { SNAPSHOT },
                peek = { ['block:b1'] = SCREEN },
                home_session_id = HOME,
            })
            put_cursor_on('block:b1')

            h:press('K')

            assert.are.equal(1, support.count(calls, 'peek'))
            assert.are.same({
                session_id = 'session:s1',
                window_id = 'window:w1',
                block_id = 'block:b1',
            }, support.last_peek(calls))
        end)

        it('shows the screen alone when the row has no directory', function()
            local plain = snap.snapshot({
                snap.session({
                    id = 'session:s1',
                    label = 'orbit',
                    windows = {
                        snap.window({
                            id = 'window:w1',
                            label = 'api',
                            blocks = {
                                snap.block({
                                    id = 'block:b9',
                                    app = 'pi',
                                    state = 'idle',
                                    title = 'the docs',
                                }),
                            },
                        }),
                    },
                }),
            })
            h:open({
                snapshots = { plain },
                peek = { ['block:b9'] = 'a plain line' },
                home_session_id = HOME,
            })
            vim.api.nvim_win_set_cursor(
                vim.api.nvim_get_current_win(),
                { 2, 0 }
            )

            h:press('K')

            local lines = assert(h:float_lines())
            assert.are.equal('api · pi · idle', lines[1])
            assert.are.equal('a plain line', lines[3])
            assert.are.equal(3, #lines)
        end)

        it('shows the path the resolve_path hook gave', function()
            local hooked = snap.snapshot({
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
                                    msg = 'the tests pass',
                                    title = 'the docs',
                                    cwd = '/work/orbit',
                                }),
                            },
                        }),
                    },
                }),
            })
            config.setup({
                resolve_path = function(block)
                    if block.block_id == 'block:b1' then
                        return HOOKED
                    end
                end,
            })
            h:open({
                snapshots = { hooked },
                peek = { ['block:b1'] = SCREEN },
                home_session_id = HOME,
            })
            h.git.answer(CLEAN, ROOT)
            support.flush()
            put_cursor_on_line(2)
            assert.are.equal('block:b1', dashboard.current_target().block_id)

            h:press('K')

            local lines = assert(h:float_lines())
            assert.are.equal(HOOKED, lines[3])
            assert.are.equal('orbit · main', lines[4])
        end)

        it('closes when the cursor moves', function()
            h:open({
                snapshots = { SNAPSHOT },
                peek = { ['block:b1'] = SCREEN },
                home_session_id = HOME,
            })
            put_cursor_on('block:b1')
            h:press('K')
            assert.is_not_nil(h:float())

            -- A headless Neovim fires no CursorMoved for a keystroke, so the
            -- spec moves the cursor and fires the event the float listens to.
            put_cursor_on_line(3)
            vim.api.nvim_exec_autocmds(
                'CursorMoved',
                { buffer = assert(h:buf()) }
            )

            assert.is_nil(h:float())
        end)

        it('closes when the Dashboard enters insert mode', function()
            h:open({
                snapshots = { SNAPSHOT },
                peek = { ['block:b1'] = SCREEN },
                home_session_id = HOME,
            })
            put_cursor_on('block:b1')
            h:press('K')
            assert.is_not_nil(h:float())

            vim.api.nvim_exec_autocmds(
                'InsertEnter',
                { buffer = assert(h:buf()) }
            )

            assert.is_nil(h:float())
        end)

        it('closes when the Dashboard buffer leaves its window', function()
            h:open({
                snapshots = { SNAPSHOT },
                peek = { ['block:b1'] = SCREEN },
                home_session_id = HOME,
            })
            put_cursor_on('block:b1')
            h:press('K')
            assert.is_not_nil(h:float())

            vim.api.nvim_win_set_buf(0, h.scratch)

            assert.is_nil(h:float())
        end)

        it('is entered by a second K and closed by q', function()
            local _, calls = h:open({
                snapshots = { SNAPSHOT },
                peek = { ['block:b1'] = SCREEN },
                home_session_id = HOME,
            })
            put_cursor_on('block:b1')
            h:press('K')
            local win = assert(h:float())
            assert.are_not.equal(win, vim.api.nvim_get_current_win())

            h:press('K')

            assert.are.equal(win, vim.api.nvim_get_current_win())
            -- The second K enters the float instead of asking Rex again.
            assert.are.equal(1, support.count(calls, 'peek'))
            assert.are.equal(1, #support.floats())

            h:press('q')

            assert.is_nil(h:float())
            assert.are.equal(h:buf(), vim.api.nvim_win_get_buf(0))
        end)

        it('is closed by <Esc> once it is entered', function()
            h:open({
                snapshots = { SNAPSHOT },
                peek = { ['block:b1'] = SCREEN },
                home_session_id = HOME,
            })
            put_cursor_on('block:b1')
            h:press('K')
            h:press('K')
            assert.is_not_nil(h:float())

            h:press('<Esc>')

            assert.is_nil(h:float())
            assert.are.equal(h:buf(), vim.api.nvim_win_get_buf(0))
        end)

        it('closes when the user leaves it for another window', function()
            h:open({
                snapshots = { SNAPSHOT },
                peek = { ['block:b1'] = SCREEN },
                home_session_id = HOME,
            })
            put_cursor_on('block:b1')
            h:press('K')
            h:press('K')
            assert.is_not_nil(h:float())

            vim.cmd('wincmd p')

            assert.is_nil(h:float())
        end)
    end)

    describe('a line without an Agent block', function()
        it('is reported and asks Rex nothing', function()
            local _, calls = h:open({
                snapshots = { TWO },
                home_session_id = HOME,
            })
            -- Line 1 is the header of a Session.
            put_cursor_on_line(1)

            h:press('K')

            assert.are.equal(1, #h.notify.calls)
            assert.are.equal(
                'rexai: put the cursor on an Agent block',
                h.notify.calls[1].message
            )
            assert.are.equal(vim.log.levels.INFO, h.notify.calls[1].level)
            assert.are.equal(0, support.count(calls, 'peek'))
            assert.is_nil(h:float())
        end)

        it('is reported on a blank line too', function()
            local _, calls = h:open({
                snapshots = { TWO },
                home_session_id = HOME,
            })
            -- Line 3 is the blank line between the two Sessions.
            put_cursor_on_line(3)
            assert.are.equal('', h:lines()[3])

            h:press('K')

            assert.are.equal(1, #h.notify.calls)
            assert.are.equal(
                'rexai: put the cursor on an Agent block',
                h.notify.calls[1].message
            )
            assert.are.equal(0, support.count(calls, 'peek'))
            assert.is_nil(h:float())
        end)
    end)

    describe('a peek that fails', function()
        it('warns and asks Rex again, and opens nothing', function()
            local backend, calls = fake.new({ snapshots = { SNAPSHOT } })
            backend.fail_next('peek', 'cannot read the Block')
            h:open({ backend = backend, home_session_id = HOME })
            put_cursor_on('block:b1')
            assert.are.equal(1, support.count(calls, 'snapshot'))

            h:press('K')

            assert.are.equal(1, #h.notify.calls)
            assert.are.equal(
                'rexai: cannot read the Block',
                h.notify.calls[1].message
            )
            assert.are.equal(vim.log.levels.WARN, h.notify.calls[1].level)
            -- The Block has probably vanished, so the Dashboard asks Rex
            -- again at once.
            assert.are.equal(2, support.count(calls, 'snapshot'))
            assert.is_nil(h:float())
        end)
    end)

    describe('a late result', function()
        it('opens nothing when the cursor moved to another row', function()
            local object = holding_backend(SNAPSHOT)
            h:open({ backend = object, home_session_id = HOME })
            put_cursor_on('block:b1')
            h:press('K')
            assert.are.equal(1, #object.targets)

            put_cursor_on('block:b2')
            object.answer(nil, SCREEN)

            assert.is_nil(h:float())
            assert.are.same({}, h.notify.calls)
        end)

        it('opens nothing when the Dashboard was wiped', function()
            local object = holding_backend(SNAPSHOT)
            h:open({ backend = object, home_session_id = HOME })
            put_cursor_on('block:b1')
            h:press('K')

            wipe()
            local replacement = holding_backend(SNAPSHOT)
            h:open({ backend = replacement, home_session_id = HOME })
            put_cursor_on('block:b1')
            object.answer(nil, SCREEN)

            assert.is_nil(h:float())
            assert.are.same({}, h.notify.calls)
        end)

        it('opens nothing when another Backend replaced it', function()
            local object = holding_backend(SNAPSHOT)
            h:open({ backend = object, home_session_id = HOME })
            put_cursor_on('block:b1')
            h:press('K')

            local replacement = holding_backend(SNAPSHOT)
            h:open({ backend = replacement, home_session_id = HOME })
            object.answer(nil, SCREEN)

            assert.is_nil(h:float())
            assert.are.same({}, h.notify.calls)
        end)

        it('keeps only the newest of two quick presses', function()
            local object = holding_backend(SNAPSHOT)
            h:open({ backend = object, home_session_id = HOME })
            put_cursor_on('block:b1')
            h:press('K')
            h:press('K')
            assert.are.equal(2, #object.targets)

            object.answer(nil, 'the older screen')

            assert.is_nil(h:float())

            object.answer(nil, 'the newer screen')

            local lines = assert(h:float_lines())
            assert.are.equal(1, #support.floats())
            assert.is_truthy(text_of(lines):find('the newer screen', 1, true))
            assert.is_nil(text_of(lines):find('the older screen', 1, true))
        end)
    end)

    describe('a refresh', function()
        -- A copy of SNAPSHOT whose Window holds what `change` returns: the next
        -- poll serves it instead, as a poll that brings new text would.
        ---@param change fun(blocks: table[]): table[]
        ---@return table
        local function redrawn(change)
            local copy = vim.deepcopy(SNAPSHOT)
            local window = copy.sessions[1].windows[1]
            window.blocks = change(window.blocks)
            window.focused_block_id = window.blocks[1].id
            return copy
        end

        -- Fires the poll that serves the second snapshot, then the
        -- `CursorMoved` a real Neovim fires after the redraw put the cursor
        -- back. A headless Neovim fires neither by itself.
        local function poll()
            h.timer.fire()
            vim.api.nvim_exec_autocmds(
                'CursorMoved',
                { buffer = assert(h:buf()) }
            )
        end

        -- Where the float hangs: the screen row of its top and its distance to
        -- the cursor line, which says it is under it whatever the border.
        ---@param win integer the window the float hangs under
        ---@return integer row the top of the float, in screen rows
        ---@return integer gap from the cursor line to that top
        local function hang(win)
            local float = assert(h:float())
            local line = vim.api.nvim_win_get_cursor(win)[1]
            local row = vim.api.nvim_win_get_position(float)[1]
            return row, row - (vim.fn.screenpos(win, line, 1).row - 1)
        end

        it('keeps the float when only the text of a row changes', function()
            h:open({
                snapshots = {
                    SNAPSHOT,
                    redrawn(function(blocks)
                        blocks[2].title = 'the parser, edited'
                        return blocks
                    end),
                },
                peek = { ['block:b2'] = SCREEN },
                home_session_id = HOME,
            })
            put_cursor_on('block:b2')
            h:press('K')
            assert.is_not_nil(h:float())

            poll()

            assert.is_not_nil(h:float())
        end)

        it('moves the float under the cursor that follows its Block', function()
            -- An Agent block below the cursor gains the status that ranks
            -- first, so it moves above the cursor and the cursor follows its
            -- own Agent block down.
            local reordered = redrawn(function(blocks)
                blocks[2].records[1].state = 'blocked'
                return blocks
            end)
            h:open({
                snapshots = { SNAPSHOT, reordered },
                peek = { ['block:b1'] = SCREEN },
                home_session_id = HOME,
            })
            put_cursor_on('block:b1')
            h:press('K')
            local row_before, gap_before = hang(0)

            poll()

            assert.is_not_nil(h:float())
            assert.are.equal('block:b1', dashboard.current_target().block_id)
            assert.are.equal(
                support.line_of(targets_of(reordered), 'block:b1'),
                vim.api.nvim_win_get_cursor(0)[1]
            )
            -- The float kept its distance to the cursor line and went down
            -- with it, so it hangs under the new line.
            local row_after, gap_after = hang(0)
            assert.are.equal(gap_before, gap_after)
            assert.is_true(row_after > row_before)
        end)

        it('closes the float when its Block leaves the snapshot', function()
            h:open({
                snapshots = {
                    SNAPSHOT,
                    redrawn(function(blocks)
                        return { blocks[2] }
                    end),
                },
                peek = { ['block:b1'] = SCREEN },
                home_session_id = HOME,
            })
            put_cursor_on('block:b1')
            h:press('K')
            assert.is_not_nil(h:float())

            -- The redraw alone closes it: the row it described is gone, and no
            -- cursor move is needed to say so.
            h.timer.fire()

            assert.is_nil(h:float())
            assert.are.equal(0, #support.floats())
        end)

        it('keeps a `g?` help float over a line with no Agent block', function()
            -- The first Session leaves the snapshot, so the buffer changes
            -- and the cursor stays on line 3. That line has no Agent block,
            -- so nothing it described is gone and the float stays.
            local shorter = vim.deepcopy(TWO)
            shorter.sessions = { shorter.sessions[2] }
            h:open({ snapshots = { TWO, shorter }, home_session_id = HOME })
            put_cursor_on_line(3)
            assert.are.equal('', h:lines()[3])
            h:press('g?')
            assert.is_not_nil(h:float())

            poll()

            assert.is_not_nil(h:float())
        end)

        -- A Backend that serves the frame the test has put in `frame`, so only
        -- the poll the test fires brings the redraw, whatever else asks Rex.
        ---@param first table
        ---@return table
        local function staged_backend(first)
            local object = { frame = first }

            function object.snapshot(callback)
                callback(nil, object.frame)
            end

            function object.peek(_, callback)
                callback(nil, SCREEN)
            end

            function object.focus(_, callback)
                callback(nil)
            end

            function object.create_window(_, callback)
                callback(nil)
            end

            function object.create_session(_, callback)
                callback(nil)
            end

            return object
        end

        -- The next frame of SNAPSHOT: the title of `block:b2` changes, so the
        -- text changes and the rows keep their places.
        ---@return table
        local function retitled()
            return redrawn(function(blocks)
                blocks[2].title = 'the parser, edited'
                return blocks
            end)
        end

        it('hangs under the owner window after the user entered it', function()
            h:open({
                snapshots = { SNAPSHOT, retitled() },
                peek = { ['block:b2'] = SCREEN },
                home_session_id = HOME,
            })
            put_cursor_on('block:b2')
            h:press('K')
            local win = assert(h:float())
            h:press('K')
            assert.are.equal(win, vim.api.nvim_get_current_win())
            local before = vim.api.nvim_win_get_position(win)

            -- The user scrolls the float, then a poll changes a title.
            vim.api.nvim_win_set_cursor(win, { 4, 0 })
            h.timer.fire()

            local after_win = assert(h:float())
            local after = vim.api.nvim_win_get_position(after_win)
            assert.are.same(before, after)
        end)

        it(
            'hangs under the owner window when another window is current',
            function()
                local backend = staged_backend(SNAPSHOT)
                h:open({ backend = backend, home_session_id = HOME })
                local other = vim.api.nvim_get_current_win()
                put_cursor_on('block:b2')
                vim.cmd('vsplit')
                put_cursor_on('block:b2')
                vim.api.nvim_win_set_cursor(other, { 1, 0 })
                h:press('K')
                local float = assert(h:float())
                local before = vim.api.nvim_win_get_position(float)

                vim.api.nvim_set_current_win(other)
                backend.frame = retitled()
                h.timer.fire()

                local after_float = assert(h:float())
                assert.are.same(
                    before,
                    vim.api.nvim_win_get_position(after_float)
                )
            end
        )

        it('closes the float when the owner window is closed', function()
            h:open({
                snapshots = { SNAPSHOT },
                peek = { ['block:b1'] = SCREEN },
                home_session_id = HOME,
            })
            -- A second window shows the same Dashboard, and the float hangs
            -- under that one.
            vim.cmd('vsplit')
            local owner = vim.api.nvim_get_current_win()
            put_cursor_on('block:b1')
            h:press('K')
            assert.is_not_nil(h:float())

            vim.api.nvim_win_close(owner, true)

            assert.is_nil(h:float())
            -- The Dashboard of the other window still answers a move.
            vim.api.nvim_exec_autocmds(
                'CursorMoved',
                { buffer = assert(h:buf()) }
            )
            assert.is_nil(h:float())
        end)

        it(
            'closes the float when the user moves in another Dashboard window',
            function()
                h:open({
                    snapshots = { SNAPSHOT },
                    peek = { ['block:b1'] = SCREEN },
                    home_session_id = HOME,
                })
                local other = vim.api.nvim_get_current_win()
                -- The float hangs under the new window, whose cursor stays on
                -- the Agent block through every move below.
                vim.cmd('vsplit')
                put_cursor_on('block:b1')
                vim.api.nvim_win_set_cursor(other, { 3, 0 })
                h:press('K')
                assert.is_not_nil(h:float())

                vim.api.nvim_set_current_win(other)
                vim.api.nvim_win_set_cursor(other, { 1, 0 })
                vim.api.nvim_exec_autocmds(
                    'CursorMoved',
                    { buffer = assert(h:buf()) }
                )

                assert.is_nil(h:float())
            end
        )

        -- One Session, one Window, one Agent block: the smallest Dashboard
        -- that shows a single row under its Session header.
        ---@param session_id string
        ---@param block_id string
        ---@return table
        local function one_row(session_id, block_id)
            return snap.snapshot({
                snap.session({
                    id = session_id,
                    label = 'orbit',
                    windows = {
                        snap.window({
                            id = 'window:w1',
                            label = 'api',
                            blocks = {
                                snap.block({
                                    id = block_id,
                                    app = 'pi',
                                    state = 'working',
                                    title = 'the parser',
                                    cwd = '/work/orbit',
                                    updated_at = '2026-11-07T16:10:00Z',
                                }),
                            },
                        }),
                    },
                }),
            })
        end

        it('closes the float of a Block an identical frame replaces', function()
            local backend = staged_backend(one_row('session:s1', 'block:old'))
            h:open({ backend = backend, home_session_id = HOME })
            put_cursor_on_line(2)
            assert.are.equal('block:old', dashboard.current_target().block_id)
            h:press('K')
            assert.is_not_nil(h:float())

            -- The same text, another Block: only the target says the row the
            -- float described is gone.
            backend.frame = one_row('session:s1', 'block:new')
            h.timer.fire()

            assert.are.equal('block:new', dashboard.current_target().block_id)
            assert.is_nil(h:float())
        end)

        it(
            'closes a `g?` float of a Session an identical frame replaces',
            function()
                local backend =
                    staged_backend(one_row('session:s1', 'block:b1'))
                h:open({ backend = backend, home_session_id = HOME })
                put_cursor_on_line(1)
                assert.are.equal(
                    'session:s1',
                    dashboard.current_target().session_id
                )
                h:press('g?')
                assert.is_not_nil(h:float())

                backend.frame = one_row('session:new', 'block:b1')
                h.timer.fire()

                assert.are.equal(
                    'session:new',
                    dashboard.current_target().session_id
                )
                assert.is_nil(h:float())
            end
        )

        it('closes the float when the user moves after a redraw', function()
            h:open({
                snapshots = {
                    SNAPSHOT,
                    redrawn(function(blocks)
                        blocks[2].title = 'the parser, edited'
                        return blocks
                    end),
                },
                peek = { ['block:b2'] = SCREEN },
                home_session_id = HOME,
            })
            put_cursor_on('block:b2')
            h:press('K')
            poll()
            assert.is_not_nil(h:float())

            -- A redraw leaves the float open, a move by the user never does.
            put_cursor_on('block:b1')
            vim.api.nvim_exec_autocmds(
                'CursorMoved',
                { buffer = assert(h:buf()) }
            )

            assert.is_nil(h:float())
        end)
    end)

    describe('wiping the Dashboard', function()
        it('closes the float it left open', function()
            local wins, bufs =
                #vim.api.nvim_list_wins(), #vim.api.nvim_list_bufs()
            h:open({
                snapshots = { SNAPSHOT },
                peek = { ['block:b1'] = SCREEN },
                home_session_id = HOME,
            })
            put_cursor_on('block:b1')
            h:press('K')
            assert.are.equal(1, #support.floats())

            wipe()

            assert.is_nil(h:float())
            assert.are.equal(wins, #vim.api.nvim_list_wins())
            assert.are.equal(bufs, #vim.api.nvim_list_bufs())
        end)
    end)
end)
