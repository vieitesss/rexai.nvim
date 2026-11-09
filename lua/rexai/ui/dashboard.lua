-- The Dashboard: one buffer shown in the current window, polled through the
-- Backend and drawn with `ui.render`. The buffer, its window options and the
-- poller live here; the layout lives in `ui.render`, what it takes from an
-- accepted snapshot lives in `ui.data`, and the actions on a row live in
-- `ui.actions`.

local actions = require('rexai.ui.actions')
local config = require('rexai.config')
local core_git = require('rexai.core.git')
local data = require('rexai.ui.data')
local float = require('rexai.ui.peek')
local git = require('rexai.git')
local help = require('rexai.core.help')
local highlights = require('rexai.ui.highlights')
local hooks = require('rexai.hooks')
local model = require('rexai.core.model')
local poll = require('rexai.poll')
local render = require('rexai.ui.render')

local M = {}

M.NAME = 'rexai://dashboard'
M.FILETYPE = 'rexai'
M.AUGROUP = 'RexaiDashboard'

-- The window options the Dashboard takes over, and their values.
local WINDOW_OPTIONS = {
    wrap = false,
    cursorline = true,
    number = false,
    relativenumber = false,
    signcolumn = 'no',
    spell = false,
    foldenable = false,
}

-- The model remembers the Agent blocks across snapshots, so an Exited row
-- shows. One memory for the process: it is shared by every Dashboard, so the
-- Exited rows survive a wipe and a later open.
local MEMORY = model.new_memory()

local state = {
    buf = nil,
    lines = nil,
    highlights = nil,
    targets = {},
    data = nil,
    actions = nil,
    show_exited = nil,
    poller = nil,
    git = nil,
    previous_buf = {},
    focused = true,
    saved = {},
    opening = false,
    now = nil,
    home_session_id = nil,
}

---@param buf integer|nil
---@return boolean
local function is_buffer(buf)
    return type(buf) == 'number' and vim.api.nvim_buf_is_valid(buf)
end

---@return integer[]
local function windows()
    if not is_buffer(state.buf) then
        return {}
    end
    return vim.fn.win_findbuf(state.buf)
end

-- The buffer the Dashboard draws in, with the options it keeps. `buftype`
-- stays empty on purpose: it is what makes `:mksession` write
-- `edit rexai://dashboard` rather than `enew` and a `file` rename, and the
-- `edit` lands on this buffer instead of colliding with its name. The
-- `BufReadCmd` of the name answers that `edit`.
---@return integer
local function ensure_buffer()
    if is_buffer(state.buf) then
        return assert(state.buf)
    end

    local buf = vim.fn.bufadd(M.NAME)
    vim.bo[buf].buftype = ''
    vim.bo[buf].bufhidden = 'hide'
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = M.FILETYPE
    vim.bo[buf].modifiable = false

    state.buf = buf
    return buf
end

-- Shows the buffer that was in the window before the Dashboard, closes the
-- window when that buffer is gone, or starts a new one in the last window.
-- The Dashboard buffer and Neovim both stay alive.
local function quit()
    local win = vim.api.nvim_get_current_win()
    if
        not is_buffer(state.buf)
        or vim.api.nvim_win_get_buf(win) ~= state.buf
    then
        return
    end

    local previous = state.previous_buf[win]
    if previous and is_buffer(previous) and previous ~= state.buf then
        return vim.api.nvim_win_set_buf(win, previous)
    end

    if #vim.api.nvim_tabpage_list_wins(0) > 1 then
        return vim.api.nvim_win_close(win, true)
    end

    vim.cmd('enew')
end

-- Takes the window options over, remembering what each window had.
---@param win integer
local function want_window_options(win)
    if not state.saved[win] then
        local saved = {}
        for name in pairs(WINDOW_OPTIONS) do
            saved[name] = vim.api.nvim_get_option_value(name, { win = win })
        end
        state.saved[win] = saved
    end

    for name, value in pairs(WINDOW_OPTIONS) do
        vim.api.nvim_set_option_value(name, value, { win = win })
    end
end

-- Gives a window that leaves the Dashboard its own options back, and forgets
-- the buffer it had before, so nothing outlives the visit.
---@param win integer
local function restore_window_options(win)
    state.previous_buf[win] = nil
    local saved = state.saved[win]
    if not saved then
        return
    end
    state.saved[win] = nil
    for name, value in pairs(saved) do
        pcall(vim.api.nvim_set_option_value, name, value, { win = win })
    end
end

-- What the cursor of a window is on: the line, the column, the Agent block or
-- Session the line shows, and how far into that target's lines it sits.
---@class rexai.Cursor
---@field win integer
---@field line integer
---@field col integer
---@field key string|nil
---@field offset integer how many lines below the first line of the target

---@param target rexai.RenderTarget|nil
---@return string|nil
local function target_key(target)
    if not target then
        return nil
    end
    if target.kind == 'session' then
        return 'session:' .. target.session_id
    end
    return 'row:' .. tostring(target.block_id)
end

-- The lines a target of a frame takes. A row takes two, so its first and last
-- line are both kept: the cursor goes back on the same one.
---@class rexai.TargetLines
---@field first integer
---@field last integer

-- The lines each Agent block or Session of a frame takes, by the key the
-- cursor of a window remembers.
---@param targets table<integer, rexai.RenderTarget>
---@return table<string, rexai.TargetLines>
local function target_lines(targets)
    local lines = {}
    for line, target in pairs(targets) do
        local key = target_key(target)
        if key then
            local span = lines[key]
            if not span then
                lines[key] = { first = line, last = line }
            else
                span.first = math.min(span.first, line)
                span.last = math.max(span.last, line)
            end
        end
    end
    return lines
end

---@return rexai.Cursor[]
local function cursors()
    local lines = target_lines(state.targets)
    local out = {}
    for _, win in ipairs(windows()) do
        if vim.api.nvim_win_is_valid(win) then
            local pos = vim.api.nvim_win_get_cursor(win)
            local key = target_key(state.targets[pos[1]])
            local span = key and lines[key]
            out[#out + 1] = {
                win = win,
                line = pos[1],
                col = pos[2],
                key = key,
                offset = span and (pos[1] - span.first) or 0,
            }
        end
    end
    return out
end

-- The windows whose Agent block or Session is not in `lines`: the row they
-- show is gone. A line with no target has no key, so it is never lost.
---@param saved rexai.Cursor[]
---@param lines table<string, rexai.TargetLines>
---@return integer[]
local function lost_windows(saved, lines)
    local lost = {}
    for _, cursor in ipairs(saved) do
        if
            cursor.key
            and not lines[cursor.key]
            and vim.api.nvim_win_is_valid(cursor.win)
        then
            lost[#lost + 1] = cursor.win
        end
    end
    return lost
end

-- A float open on this Dashboard follows the cursor its Agent block or Session
-- just moved to, and closes when that row is gone: a redraw is no cursor move
-- by the user.
---@param lost integer[]
local function settle_float(lost)
    if vim.tbl_contains(lost, float.owner()) then
        float.close()
    else
        float.reanchor()
    end
end

-- Puts each window back on the same line of the same Agent block or Session,
-- or on the same line number clamped to the new buffer when that line is gone.
---@param saved rexai.Cursor[]
---@param out rexai.Render
---@return integer[] lost the windows whose Agent block or Session is gone
local function restore_cursors(saved, out)
    local lines = target_lines(out.targets)
    local lost = lost_windows(saved, lines)

    for _, cursor in ipairs(saved) do
        if vim.api.nvim_win_is_valid(cursor.win) then
            local line
            local span = cursor.key and lines[cursor.key]
            if span then
                line = math.min(span.first + cursor.offset, span.last)
            else
                line = math.min(cursor.line, #out.lines)
            end
            local text = out.lines[line] or ''
            vim.api.nvim_win_set_cursor(cursor.win, {
                line,
                math.min(cursor.col, #text),
            })
        end
    end
    return lost
end

-- Writes a frame into the buffer: its lines and their highlights. A session
-- gives the buffer back with `:edit rexai://dashboard`, which empties it, so
-- the frame on screen is written again there.
---@param lines string[]
---@param highlights rexai.Highlight[]
local function paint(lines, highlights)
    local buf = state.buf
    if not is_buffer(buf) then
        return
    end
    ---@cast buf integer

    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    -- `:edit` refuses a modified buffer with E37. Nothing writes this buffer,
    -- so the flag goes: while 'modifiable' is still set, or it stays.
    vim.bo[buf].modified = false
    vim.bo[buf].modifiable = false

    local ns = vim.api.nvim_create_namespace('rexai')
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for _, span in ipairs(highlights) do
        vim.api.nvim_buf_set_extmark(buf, ns, span.line - 1, span.col_start, {
            end_col = span.col_end,
            hl_group = span.group,
        })
    end
end

---@param out rexai.Render
local function show(out)
    local buf = state.buf
    if not is_buffer(buf) then
        return
    end
    ---@cast buf integer

    -- The targets of every frame are published, even when the text and the
    -- highlights are the same: Rex may replace a Block, Window or Session with
    -- one of another id under the same text, and the keys must act on the id
    -- the model just accepted. `cursors` reads the targets of the frame the
    -- windows still show, so it runs before this assignment in both branches.
    local unchanged = vim.deep_equal(state.lines, out.lines)
        and vim.deep_equal(state.highlights, out.highlights)
    if unchanged then
        -- The text stays, but a row may hold another Block, Window or Session,
        -- so the saved cursors are compared with this frame too. No cursor
        -- moves here.
        local saved = cursors()
        local lost = lost_windows(saved, target_lines(out.targets))
        state.targets = out.targets
        settle_float(lost)
        return
    end

    local saved = cursors()
    paint(out.lines, out.highlights)

    state.lines = out.lines
    state.highlights = out.highlights
    local lost = restore_cursors(saved, out)
    state.targets = out.targets
    settle_float(lost)
end

-- The git slot of every row the render will show, by Block id, and the paths
-- the cache may keep. A row hidden by the `x` toggle is not asked about.
---@param sessions rexai.ModelSession[]
---@return table<string, string> slots
---@return string[] paths
local function git_slots(sessions)
    local slots, paths = {}, {}
    if not state.git or not state.data then
        return slots, paths
    end

    for _, session in ipairs(sessions) do
        for _, row in ipairs(session.rows) do
            if state.show_exited or row.status ~= 'exited' then
                local ctx = state.data:context(row.block_id)
                local path = ctx and ctx.path
                if path then
                    state.git:request(path)
                    paths[#paths + 1] = path
                    if ctx and ctx.git then
                        slots[row.block_id] = core_git.format(ctx.git)
                    end
                end
            end
        end
    end
    return slots, paths
end

-- Draws what the model last gave, so `x` re-renders without asking Rex. Git
-- is asked only while a window shows the buffer, so a Dashboard left behind
-- makes no call.
local function draw()
    if not state.data then
        return
    end
    local sessions = state.data:sessions()
    if not sessions then
        return
    end
    local options = config.get()
    local slots = {}
    if state.git and #windows() > 0 then
        local paths
        slots, paths = git_slots(sessions)
        state.git:retain(paths)
    end

    show(render.build(sessions, {
        now = (state.now or os.time)(),
        show_exited = state.show_exited,
        title_width = options.title_width,
        home_session_id = state.home_session_id,
        home_label = state.data:home_label(),
        git = slots,
    }))
end

local function on_snapshot(snapshot)
    state.data:accept(snapshot, state.home_session_id)
    draw()
end

local function stop_polling()
    if state.poller and state.poller.running() then
        state.poller.stop()
    end
end

-- Asks Rex at once, whatever the focus flag says, as long as a window shows
-- the buffer.
local function ask_rex()
    if not state.poller or #windows() == 0 then
        return
    end
    if state.poller.running() then
        state.poller.tick()
    else
        state.poller.start()
    end
end

-- Asks Rex at once and makes sure the poller is running. The Dashboard
-- polls only while a window shows it and Neovim has focus.
local function refresh_now()
    if state.focused and #windows() > 0 then
        ask_rex()
    end
end

-- `x`: shows or hides the Exited rows. The buffer is the feedback, and the
-- toggle is Dashboard state, not config.
local function toggle_exited()
    state.show_exited = not state.show_exited
    draw()
end

-- Every normal-mode key of the Dashboard, in the order `g?` lists them: the key,
-- what it does (the `desc` of its keymap) and what it runs.
---@type { [1]: string, [2]: string, [3]: fun() }[]
local KEYS

-- `g?`: a float at the cursor with every key of the Dashboard. It closes as
-- soon as the cursor moves, like the float of `K`.
local function show_keys()
    state.actions:cancel_peek()
    float.show(help.lines(KEYS))
end

KEYS = {
    {
        '<CR>',
        'Go to the Agent block or Session',
        function()
            state.actions:focus()
        end,
    },
    {
        'K',
        'Peek at the Agent block',
        function()
            state.actions:peek()
        end,
    },
    {
        'o',
        'Review the Agent block',
        function()
            state.actions:review()
        end,
    },
    { 'r', 'Refresh the Dashboard', ask_rex },
    { 'x', 'Toggle the Exited rows', toggle_exited },
    {
        'a',
        'Add a Window to the Session',
        function()
            state.actions:new_window()
        end,
    },
    {
        'A',
        'Start a Session',
        function()
            state.actions:new_session()
        end,
    },
    { 'q', 'Close the Dashboard', quit },
    { 'g?', 'Show these keys', show_keys },
}

---@param buf integer
local function keymaps(buf)
    for _, key in ipairs(KEYS) do
        vim.keymap.set('n', key[1], key[3], {
            buffer = buf,
            nowait = true,
            desc = key[2],
        })
    end
end

-- Forgets everything about the Dashboard once its buffer is wiped, so no
-- timer, autocmd or stale state outlives it.
---@param group integer
local function cleanup(group)
    stop_polling()
    state.poller = nil
    if state.actions then
        state.actions:dispose()
        state.actions = nil
    end
    if state.git then
        state.git:stop()
        state.git = nil
    end
    state.buf = nil
    state.lines, state.highlights, state.targets = nil, nil, {}
    state.data, state.show_exited = nil, nil
    state.previous_buf = {}
    state.focused = true
    state.saved = {}
    pcall(vim.api.nvim_del_augroup_by_id, group)
end

-- The events the Dashboard listens to. The group is rebuilt on every open, so
-- there is one set of autocmds and no more.
---@param buf integer
local function ensure_autocmds(buf)
    local group = vim.api.nvim_create_augroup(M.AUGROUP, { clear = true })

    ---@param event string
    ---@param callback fun()
    local function on_buffer(event, callback)
        vim.api.nvim_create_autocmd(event, {
            group = group,
            buffer = buf,
            callback = callback,
        })
    end

    ---@param event string
    ---@param callback fun()
    local function on_editor(event, callback)
        vim.api.nvim_create_autocmd(
            event,
            { group = group, callback = callback }
        )
    end

    on_buffer('BufWinEnter', function()
        -- `open` puts the buffer into the window itself and refreshes there.
        if state.opening then
            return
        end
        want_window_options(vim.api.nvim_get_current_win())
        refresh_now()
    end)

    on_buffer('BufWinLeave', function()
        restore_window_options(vim.api.nvim_get_current_win())
        if #windows() <= 1 then
            stop_polling()
        end
    end)

    on_buffer('BufHidden', function()
        if #windows() == 0 then
            stop_polling()
        end
    end)

    on_editor('FocusGained', function()
        state.focused = true
        refresh_now()
    end)

    on_editor('FocusLost', function()
        state.focused = false
        stop_polling()
    end)

    on_buffer('BufWipeout', function()
        cleanup(group)
    end)
end

-- An unreadable Rex is shown in the buffer itself. The poller retries, and
-- the next snapshot draws over the error.
---@param err string
local function on_error(err)
    -- The rows of the last snapshot are stale, so `x` leaves the error alone
    -- until a snapshot succeeds.
    state.data:clear()
    show(render.build({}, { error = err, now = (state.now or os.time)() }))
end

-- The poller of the Dashboard. A second `:Rexai` reuses it, so one Dashboard
-- never runs two of them. An injected Backend makes a new one.
---@param opts rexai.DashboardOpts
---@return rexai.Poller
local function ensure_poller(opts)
    local backend = opts.backend
    if not backend and state.poller then
        return state.poller
    end
    if not backend then
        backend = require('rexai.backend.rex').new({
            bin = config.get().rex_bin,
            peek_lines = config.get().peek_lines,
        })
    end
    if state.poller then
        state.poller.stop()
    end
    -- The actions of the old Backend belong to a Dashboard lifetime that ends
    -- here: a result it still waits for must not reach this one.
    if state.actions then
        state.actions:dispose()
        state.actions = nil
    end

    state.poller = poll.new({
        backend = backend,
        interval_ms = config.get().refresh_ms,
        after = opts.after,
        on_snapshot = on_snapshot,
        on_error = on_error,
    })

    -- One git cache per Dashboard: the poller and the git object are replaced
    -- together, and a result that arrives after that is dropped.
    if state.git then
        state.git:stop()
    end
    local git_opts = opts.git or {}
    state.git = git.new({
        run = git_opts.run,
        clock = git_opts.clock,
        on_change = function()
            if is_buffer(state.buf) and #windows() > 0 then
                draw()
            end
        end,
    })

    -- One hooks object per Dashboard too: a hook that failed reports once per
    -- open, and `cleanup` starts that count again. The data and the actions
    -- hold it for as long as they live.
    local hooks_opts = opts.hooks or {}
    local hook_object = hooks.new({ notify = hooks_opts.notify })

    -- The snapshot preparation and the joins the keys need. The memory is the
    -- process-wide one, so an Exited row outlives this Dashboard.
    state.data = data.new({
        hooks = hook_object,
        git = state.git,
        memory = MEMORY,
    })

    -- `<CR>` and `o`: one object per Dashboard, so a late result of an older
    -- one is dropped by its `dispose`.
    state.actions = actions.new({
        backend = backend,
        data = state.data,
        hooks = hook_object,
        refresh = refresh_now,
        current_target = M.current_target,
    })
    return state.poller
end

---@class rexai.DashboardOpts
---@field backend rexai.Backend|nil
---@field after (fun(ms: integer, callback: fun()): fun())|nil
---@field now (fun(): number)|nil epoch seconds the ages are measured against
---@field home_session_id string|nil the Session that holds this Neovim
---@field git table|nil test seam: `run` and `clock` of the git cache
---@field hooks table|nil test seam: `notify` of the hooks object

-- The state, buffer, keys and poller of a Dashboard, before a window shows it.
-- An open and a window a session gave the Dashboard back to both start here.
---@param opts rexai.DashboardOpts
---@return integer buf
local function prepare(opts)
    highlights.define()
    state.now = opts.now
    state.home_session_id = opts.home_session_id or vim.env.REX_SESSION
    if state.show_exited == nil then
        state.show_exited = config.get().show_exited
    end

    local buf = ensure_buffer()
    keymaps(buf)
    ensure_poller(opts)
    return buf
end

-- The Dashboard on screen in `wins`: their window options, the autocmds that
-- keep it drawn, a frame `:edit` emptied to write back, and the ask of Rex that
-- fills it.
---@param buf integer
---@param wins integer[] the windows that show the buffer
---@param frame { lines: string[], highlights: rexai.Highlight[] }|nil already drawn, then emptied
local function present(buf, wins, frame)
    for _, win in ipairs(wins) do
        want_window_options(win)
    end
    ensure_autocmds(buf)
    if frame then
        paint(frame.lines, frame.highlights)
    end
    refresh_now()
end

---@param opts rexai.DashboardOpts|nil
function M.open(opts)
    opts = opts or {}
    local buf = prepare(opts)

    -- The buffer goes into the window before the autocmds exist, so the first
    -- render happens once and only once, in `present`.
    local win = vim.api.nvim_get_current_win()
    local before = vim.api.nvim_win_get_buf(win)
    state.opening = true
    if before ~= buf then
        state.previous_buf[win] = before
        vim.api.nvim_win_set_buf(win, buf)
    end
    state.opening = false

    present(buf, { win })
end

-- `:edit rexai://dashboard`, from a session the user sources or from
-- `:restart`: the `BufReadCmd` of the name sends it here instead of Neovim
-- reading a file. The buffer is the Dashboard this Neovim already has, so
-- every window the session gave it shows the same live buffer, and a session
-- that found no Dashboard here gets one where the session put it.
---@param opts rexai.DashboardOpts|nil
function M.read(opts)
    -- Showing a buffer Neovim has not loaded yet loads it, and that read lands
    -- here too. `open` is already building the Dashboard, so it takes over.
    if state.opening then
        return
    end

    opts = opts or {}
    local buf = prepare(opts)

    -- The `edit` emptied the buffer before this ran, so the frame on screen
    -- goes back as it was: no window is blank while Rex is asked again.
    local frame
    if state.lines then
        frame = { lines = state.lines, highlights = assert(state.highlights) }
    end
    present(buf, windows(), frame)
end

-- The target under the cursor of a window that shows the Dashboard. The
-- keymap Work Item acts on it.
---@param win integer|nil defaults to the current window
---@return rexai.RenderTarget|nil
function M.current_target(win)
    win = win or vim.api.nvim_get_current_win()
    if
        not vim.api.nvim_win_is_valid(win)
        or not is_buffer(state.buf)
        or vim.api.nvim_win_get_buf(win) ~= state.buf
    then
        return nil
    end
    return state.targets[vim.api.nvim_win_get_cursor(win)[1]]
end

return M
