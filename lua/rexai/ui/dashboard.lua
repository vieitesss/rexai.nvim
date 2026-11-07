-- The Dashboard: one buffer shown in the current window, polled through the
-- Backend and drawn with `ui.render`. The buffer, its window options and the
-- poller live here; the layout itself lives in `ui.render`.

local config = require('rexai.config')
local highlights = require('rexai.ui.highlights')
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
-- shows. One memory for the process: it lives as long as the Dashboard does.
local MEMORY = model.new_memory()

local state = {
    buf = nil,
    lines = nil,
    highlights = nil,
    targets = {},
    poller = nil,
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

-- Every normal-mode key of the Dashboard. Later Work Items add their keys
-- here.
---@param buf integer
local function keymaps(buf)
    vim.keymap.set('n', 'q', quit, {
        buffer = buf,
        nowait = true,
        desc = 'Close the Dashboard',
    })
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

    if
        vim.deep_equal(state.lines, out.lines)
        and vim.deep_equal(state.highlights, out.highlights)
    then
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
    state.targets = out.targets
    restore_cursors(saved, out)
end

-- What Rex calls the Home session, from the snapshot itself: the model drops
-- a Session with no Agent blocks, so its name is lost with it.
---@param snapshot table
---@return string|nil
local function label_of_home(snapshot)
    for _, session in ipairs(snapshot.sessions or {}) do
        if session.id == state.home_session_id then
            return session.label
        end
    end
end

local function on_snapshot(snapshot)
    local options = config.get()
    local sessions = model.build(snapshot, options.agents, MEMORY)
    show(render.build(sessions, {
        now = (state.now or os.time)(),
        show_exited = options.show_exited,
        title_width = options.title_width,
        home_session_id = state.home_session_id,
        home_label = label_of_home(snapshot),
    }))
end

-- The Dashboard polls only while a window shows it and Neovim has focus.
---@return boolean
local function should_poll()
    return state.focused and #windows() > 0
end

local function stop_polling()
    if state.poller and state.poller.running() then
        state.poller.stop()
    end
end

-- Asks Rex at once and makes sure the poller is running.
local function refresh_now()
    if not state.poller or not should_poll() then
        return
    end
    if state.poller.running() then
        state.poller.tick()
    else
        state.poller.start()
    end
end

-- Forgets everything about the Dashboard once its buffer is wiped, so no
-- timer, autocmd or stale state outlives it.
---@param group integer
local function cleanup(group)
    stop_polling()
    state.poller = nil
    state.buf = nil
    state.lines, state.highlights, state.targets = nil, nil, {}
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

    state.poller = poll.new({
        backend = backend,
        interval_ms = config.get().refresh_ms,
        after = opts.after,
        on_snapshot = on_snapshot,
        on_error = on_error,
    })
    return state.poller
end

---@class rexai.DashboardOpts
---@field backend rexai.Backend|nil
---@field after (fun(ms: integer, callback: fun()): fun())|nil
---@field now (fun(): number)|nil epoch seconds the ages are measured against
---@field home_session_id string|nil the Session that holds this Neovim

---@param opts rexai.DashboardOpts|nil
function M.open(opts)
    opts = opts or {}
    highlights.define()
    state.now = opts.now
    state.home_session_id = opts.home_session_id or vim.env.REX_SESSION

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
