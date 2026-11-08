-- The float of the Dashboard: a hover-like window at the cursor with the lines
-- it is given. One float at a time; it closes as soon as the cursor moves, the
-- Dashboard buffer is left or the user is done with it.
--
-- Only the window mechanics live here. The `K` key shows the lines `core.peek`
-- builds, and `ui.actions` decides when; the `?` key shows the lines
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
    entering = false,
}

---@return boolean
function M.is_open()
    return state.win ~= nil and vim.api.nvim_win_is_valid(state.win)
end

-- Closes the float and the buffer it showed. Safe to call when nothing is
-- open, and from an autocmd of the float itself.
function M.close()
    local win, buf = state.win, state.buf
    state.win, state.buf, state.entering = nil, nil, false

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
    on('CursorMoved', dashboard, M.close)
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

    state.win, state.buf = float_win, buf
    keys(buf)
    autocmds(win, buf)
end

return M
