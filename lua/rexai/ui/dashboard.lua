-- The Dashboard: one buffer shown in the current window, polled through the
-- Backend and drawn with `ui.render`. The buffer, its window options and the
-- poller live here; the layout lives in `ui.render` and what it takes from an
-- accepted snapshot lives in `ui.data`.

local config = require('rexai.config')
local core_git = require('rexai.core.git')
local data = require('rexai.ui.data')
local git = require('rexai.git')
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
    hooks = nil,
    show_exited = nil,
    backend = nil,
    poller = nil,
    git = nil,
    previous_buf = nil,
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

local function ensure_buffer()
    if is_buffer(state.buf) then
        return state.buf
    end

    local buf = vim.fn.bufadd(M.NAME)
    vim.bo[buf].buftype = 'nofile'
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

    local previous = state.previous_buf
    if is_buffer(previous) and previous ~= state.buf then
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

-- Gives a window that leaves the Dashboard its own options back.
---@param win integer
local function restore_window_options(win)
    local saved = state.saved[win]
    if not saved then
        return
    end
    state.saved[win] = nil
    for name, value in pairs(saved) do
        pcall(vim.api.nvim_set_option_value, name, value, { win = win })
    end
end

-- What the cursor of a window is on: the line, the column and the Agent block
-- or Session the line shows.
---@class rexai.Cursor
---@field win integer
---@field line integer
---@field col integer
---@field key string|nil

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

---@return rexai.Cursor[]
local function cursors()
    local out = {}
    for _, win in ipairs(windows()) do
        if vim.api.nvim_win_is_valid(win) then
            local pos = vim.api.nvim_win_get_cursor(win)
            out[#out + 1] = {
                win = win,
                line = pos[1],
                col = pos[2],
                key = target_key(state.targets[pos[1]]),
            }
        end
    end
    return out
end

-- Puts each window back on the line of the same Agent block or Session, or on
-- the same line number clamped to the new buffer when that line is gone.
---@param saved rexai.Cursor[]
---@param out rexai.Render
local function restore_cursors(saved, out)
    local lines = {}
    for line, target in pairs(out.targets) do
        lines[target_key(target)] = line
    end

    for _, cursor in ipairs(saved) do
        if vim.api.nvim_win_is_valid(cursor.win) then
            local line = cursor.key and lines[cursor.key]
            if not line then
                line = math.min(cursor.line, #out.lines)
            end
            local text = out.lines[line] or ''
            vim.api.nvim_win_set_cursor(cursor.win, {
                line,
                math.min(cursor.col, #text),
            })
        end
    end
end

---@param out rexai.Render
local function show(out)
    local buf = state.buf
    if not is_buffer(buf) then
        return
    end

    -- The targets of every frame are published, even when the text and the
    -- highlights are the same: Rex may replace a Block, Window or Session with
    -- one of another id under the same text, and the keys must act on the id
    -- the model just accepted. The assignment comes after `cursors`, which
    -- reads the targets of the frame the windows still show.
    local unchanged = vim.deep_equal(state.lines, out.lines)
        and vim.deep_equal(state.highlights, out.highlights)
    if unchanged then
        state.targets = out.targets
        return
    end

    local saved = cursors()
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, out.lines)
    vim.bo[buf].modifiable = false

    local ns = vim.api.nvim_create_namespace('rexai')
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for _, span in ipairs(out.highlights) do
        vim.api.nvim_buf_set_extmark(buf, ns, span.line - 1, span.col_start, {
            end_col = span.col_end,
            hl_group = span.group,
        })
    end

    state.lines = out.lines
    state.highlights = out.highlights
    restore_cursors(saved, out)
    state.targets = out.targets
end

-- The git slot of every row the render will show, by Block id, and the paths
-- the cache may keep. A row hidden by the `e` toggle is not asked about.
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
                    if ctx.git then
                        slots[row.block_id] = core_git.format(ctx.git)
                    end
                end
            end
        end
    end
    return slots, paths
end

-- Draws what the model last gave, so `e` re-renders without asking Rex. Git
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

-- `<CR>`: goes to the Agent block under the cursor, or to the Session of a
-- header. Rex changes the view itself, so only a failure needs an answer:
-- the target has probably vanished, and the Dashboard asks Rex again.
local function focus_target()
    local target = M.current_target()
    if not target or not state.backend then
        return
    end

    local request = { session_id = target.session_id }
    if target.kind == 'row' then
        request.window_id = target.window_id
        request.block_id = target.block_id
    end

    state.backend.focus(request, function(err)
        if not err then
            return
        end
        vim.notify('rexai: ' .. err, vim.log.levels.WARN)
        refresh_now()
    end)
end

-- `e`: shows or hides the Exited rows. The buffer is the feedback, and the
-- toggle is Dashboard state, not config.
local function toggle_exited()
    state.show_exited = not state.show_exited
    draw()
end

---@param message string
---@param level integer|nil INFO unless said
local function notify(message, level)
    vim.notify('rexai: ' .. message, level or vim.log.levels.INFO)
end

-- What `review` gets for one row: the directory it stands for, what git knows
-- about it, and the row itself.
---@param ctx rexai.RowContext
---@return table
local function review_ctx(ctx)
    local info = ctx.git
    return {
        path = ctx.path,
        repo_root = info and info.root or nil,
        branch = info and info.branch or nil,
        session = { id = ctx.session.id, label = ctx.session.label },
        window = { id = ctx.row.window_id },
        block = vim.deepcopy(ctx.row),
    }
end

-- `d`: hands the row under the cursor to the `review` hook. A miss says why,
-- in the order a user runs into it: no row, no directory, no hook set.
local function review_row()
    local target = M.current_target()
    local ctx
    if target and target.kind == 'row' and state.data then
        ctx = state.data:context(target.block_id)
    end
    if not ctx then
        return notify('put the cursor on an Agent block')
    end
    if not ctx.path then
        return notify('this Block has no directory to review')
    end
    state.hooks:review(review_ctx(ctx))
end

-- Every normal-mode key of the Dashboard. Later Work Items add their keys
-- here.
---@param buf integer
local function keymaps(buf)
    vim.keymap.set('n', 'q', quit, {
        buffer = buf,
        nowait = true,
        desc = 'Close the Dashboard',
    })
    vim.keymap.set('n', '<CR>', focus_target, {
        buffer = buf,
        nowait = true,
        desc = 'Go to the Agent block or Session',
    })
    vim.keymap.set('n', 'r', ask_rex, {
        buffer = buf,
        nowait = true,
        desc = 'Refresh the Dashboard',
    })
    vim.keymap.set('n', 'e', toggle_exited, {
        buffer = buf,
        nowait = true,
        desc = 'Toggle the Exited rows',
    })
    vim.keymap.set('n', 'd', review_row, {
        buffer = buf,
        nowait = true,
        desc = 'Review the Agent block',
    })
end

-- Forgets everything about the Dashboard once its buffer is wiped, so no
-- timer, autocmd or stale state outlives it.
---@param group integer
local function cleanup(group)
    stop_polling()
    state.poller = nil
    if state.git then
        state.git:stop()
        state.git = nil
    end
    state.buf = nil
    state.lines, state.highlights, state.targets = nil, nil, {}
    state.data, state.show_exited = nil, nil
    state.hooks = nil
    state.backend = nil
    state.previous_buf = nil
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
    -- The rows of the last snapshot are stale, so `e` leaves the error alone
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

    state.backend = backend
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
    -- open, and `cleanup` starts that count again.
    local hooks_opts = opts.hooks or {}
    state.hooks = hooks.new({ notify = hooks_opts.notify })

    -- The snapshot preparation and the joins the keys need. The memory is the
    -- process-wide one, so an Exited row outlives this Dashboard.
    state.data = data.new({
        hooks = state.hooks,
        git = state.git,
        memory = MEMORY,
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

---@param opts rexai.DashboardOpts|nil
function M.open(opts)
    opts = opts or {}
    highlights.define()
    state.now = opts.now
    state.home_session_id = opts.home_session_id or vim.env.REX_SESSION
    if state.show_exited == nil then
        state.show_exited = config.get().show_exited
    end

    local buf = ensure_buffer()
    keymaps(buf)
    ensure_poller(opts)

    -- The buffer goes into the window before the autocmds exist, so the first
    -- render happens once and only once, below.
    local win = vim.api.nvim_get_current_win()
    local before = vim.api.nvim_win_get_buf(win)
    state.opening = true
    if before ~= buf then
        state.previous_buf = before
        vim.api.nvim_win_set_buf(win, buf)
    end
    want_window_options(win)
    ensure_autocmds(buf)
    state.opening = false

    refresh_now()
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
