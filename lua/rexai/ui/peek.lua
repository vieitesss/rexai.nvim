-- The float of the Dashboard: a hover-like window at the cursor with the lines
-- it is given. One float at a time; it closes as soon as the cursor moves, the
-- Dashboard buffer is left or the user is done with it. A redraw that puts the
-- cursor back where it was is no move: the float stays, and it follows the
-- cursor when the Agent block or Session under it takes another line.
--
-- Only the window mechanics live here. The `K` key shows the lines `core.peek`
-- builds, and `ui.actions` decides when; the `g?` key shows the lines
-- `core.help` builds, and `ui.dashboard` decides when.

local M = {}

M.AUGROUP = 'RexaiPeek'

-- The cells the screen keeps free, so the float never reaches the edge.
M.MARGIN = 4

-- Where the float hangs: one line under the cursor, at its first column.
M.ROW = 1
M.COL = 0

local state = {
    win = nil,
    buf = nil,
    owner = nil,
    cursor = nil,
    entering = false,
}

---@return boolean
function M.is_open()
    return state.win ~= nil and vim.api.nvim_win_is_valid(state.win)
end

-- The window the float hangs under, or nil when nothing is open. A redraw of
-- the Dashboard asks, so the float of its window can follow it or close.
---@return integer|nil
function M.owner()
    if not M.is_open() then
        return nil
    end
    return state.owner
end

-- Closes the float and the buffer it showed. Safe to call when nothing is
-- open, and from an autocmd of the float itself.
function M.close()
    local win, buf = state.win, state.buf
    state.win, state.buf, state.owner, state.cursor = nil, nil, nil, nil
    state.entering = false

    pcall(vim.api.nvim_del_augroup_by_name, M.AUGROUP)
    if win and vim.api.nvim_win_is_valid(win) then
        pcall(vim.api.nvim_win_close, win, true)
    end
    if buf and vim.api.nvim_buf_is_valid(buf) then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
end

-- Puts the cursor into the float, so the user can read a long screen and
-- scroll it. The leave it causes is not a leave by the user.
function M.enter()
    if not M.is_open() then
        return
    end
    state.entering = true
    local ok = pcall(vim.api.nvim_set_current_win, state.win)
    state.entering = false
    if not ok then
        M.close()
    end
end

-- Moves the float under the cursor of the window it hangs under, after a
-- redraw put the cursor back on the same Agent block or Session on another
-- line. The new spot is the one the plugin's own move made, not the user's.
function M.reanchor()
    if not M.is_open() then
        return
    end
    -- The window it hangs under went away: nothing is left to follow.
    if not vim.api.nvim_win_is_valid(state.owner) then
        M.close()
        return
    end
    local cursor = vim.api.nvim_win_get_cursor(state.owner)
    vim.api.nvim_win_set_config(state.win, {
        relative = 'win',
        win = state.owner,
        -- A buffer position of the owner, not the cursor: `relative =
        -- 'cursor'` is resolved against the window the user is in, which is
        -- not the owner once the float is entered or another Dashboard window
        -- holds the cursor.
        bufpos = { cursor[1] - 1, cursor[2] },
        row = M.ROW,
        col = M.COL,
    })
    state.cursor = cursor
end

-- `q` and `<Esc>` belong to a float the user is in.
---@param buf integer
local function keys(buf)
    for _, lhs in ipairs({ 'q', '<Esc>' }) do
        vim.keymap.set('n', lhs, function()
            M.close()
        end, {
            buffer = buf,
            nowait = true,
            desc = 'Close the peek',
        })
    end
end

-- The float follows the Dashboard: a cursor move, an insert mode or a leave of
-- the Dashboard buffer closes it, and so does a leave of the float itself.
---@param owner integer the window the float hangs under
---@param buf integer the float buffer
local function autocmds(owner, buf)
    local group = vim.api.nvim_create_augroup(M.AUGROUP, { clear = true })

    ---@param event string
    ---@param buffer integer
    ---@param callback fun()
    local function on(event, buffer, callback)
        vim.api.nvim_create_autocmd(event, {
            group = group,
            buffer = buffer,
            callback = callback,
        })
    end

    local dashboard = vim.api.nvim_win_get_buf(owner)
    -- A redraw puts the cursor back where it was after it changed the buffer,
    -- and Neovim reports that as a move. A move that ends where the float was
    -- put is the plugin's own, so only any other move closes the float.
    local function moved()
        -- Closing the window the float hangs under happens before its
        -- `WinClosed` callback, so a move that arrives first ends it here.
        if not vim.api.nvim_win_is_valid(owner) then
            M.close()
            return
        end
        -- The Dashboard buffer may show in more than one window, and the
        -- float hangs under one of them: a move in any other closes it.
        if vim.api.nvim_get_current_win() ~= owner then
            M.close()
            return
        end
        if vim.deep_equal(vim.api.nvim_win_get_cursor(owner), state.cursor) then
            return
        end
        M.close()
    end
    on('CursorMoved', dashboard, moved)
    -- A window that goes away takes the float that hangs under it with it.
    vim.api.nvim_create_autocmd('WinClosed', {
        group = group,
        pattern = tostring(owner),
        callback = M.close,
    })
    on('InsertEnter', dashboard, M.close)
    on('BufLeave', dashboard, function()
        -- Entering the float leaves the Dashboard buffer too.
        if state.entering then
            return
        end
        M.close()
    end)
    on('BufLeave', buf, M.close)
end

-- The size of the float: as wide as its widest line and as tall as it has
-- lines, never wider or taller than the screen keeps free.
---@param lines string[]
---@return integer width
---@return integer height
local function size(lines)
    local widest = 1
    for _, line in ipairs(lines) do
        widest = math.max(widest, vim.fn.strdisplaywidth(line))
    end
    local width = math.max(1, vim.o.columns - M.MARGIN)
    local height = math.max(1, vim.o.lines - M.MARGIN)
    return math.min(widest, width), math.min(#lines, height)
end

-- Shows `lines` in a float under the cursor of `win`. An empty list, or a
-- window Neovim no longer shows, opens nothing.
---@param lines string[]
---@param win integer|nil the window the float hangs under; defaults to this one
function M.show(lines, win)
    M.close()
    lines = lines or {}
    win = win or vim.api.nvim_get_current_win()
    if #lines == 0 or not vim.api.nvim_win_is_valid(win) then
        return
    end

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].buftype = 'nofile'
    vim.bo[buf].bufhidden = 'wipe'
    vim.bo[buf].swapfile = false
    vim.bo[buf].modifiable = false

    local width, height = size(lines)
    -- The border is Neovim's own: `winborder` decides, so no option is added
    -- here for it.
    local ok, float_win = pcall(vim.api.nvim_open_win, buf, false, {
        relative = 'cursor',
        win = win,
        row = M.ROW,
        col = M.COL,
        width = width,
        height = height,
        style = 'minimal',
        focusable = true,
    })
    if not ok then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
        return
    end
    vim.api.nvim_set_option_value('wrap', false, { win = float_win })

    state.win, state.buf, state.owner = float_win, buf, win
    state.cursor = vim.api.nvim_win_get_cursor(win)
    keys(buf)
    autocmds(win, buf)
end

return M
