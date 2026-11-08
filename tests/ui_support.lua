-- The deterministic environment the Dashboard UI specs share: a timer the test
-- fires, a git runner it answers, a git clock it moves, a recorder for what
-- the Dashboard told the user, a fake Backend wired to all of them, key input,
-- and the cleanup of everything the harness changed. Scenario data, snapshots
-- and assertions stay in each spec.
--
-- The cleanup is owned, not a sweep: `new` records each value it replaces and
-- `close` puts those values back, wipes the Dashboard buffer and nothing else.
-- A spec that checks for leaked plugin resources sees them, because those
-- checks run before `close`.

local config = require('rexai.config')
local dashboard = require('rexai.ui.dashboard')
local fake = require('rexai.backend.fake')

local M = {}

-- 2026-11-07T16:15:00Z, so the ages of a snapshot never move by themselves.
M.NOW = 1794068100

---@param calls table[] every call a fake Backend recorded
---@param method string
---@return integer how many of those calls are `method`
function M.count(calls, method)
    local total = 0
    for _, call in ipairs(calls) do
        if call.method == method then
            total = total + 1
        end
    end
    return total
end

---@param calls table[]
---@return table|nil the argument of the last `focus` call
function M.last_focus(calls)
    for index = #calls, 1, -1 do
        if calls[index].method == 'focus' then
            return calls[index].arg
        end
    end
end

---@param calls table[]
---@return table|nil the argument of the last `peek` call
function M.last_peek(calls)
    for index = #calls, 1, -1 do
        if calls[index].method == 'peek' then
            return calls[index].arg
        end
    end
end

-- Every float window Neovim shows, the Dashboard's `K` float included. A spec
-- that checks for a leaked float finds it here.
---@return integer[]
function M.floats()
    local out = {}
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_config(win).relative ~= '' then
            out[#out + 1] = win
        end
    end
    return out
end

---@param targets table<integer, rexai.RenderTarget>
---@param block_id string
---@return integer the line that Agent block is on
function M.line_of(targets, block_id)
    for line, target in pairs(targets) do
        if target.block_id == block_id then
            return line
        end
    end
    error('no line for ' .. block_id)
end

-- Lets every callback `vim.schedule` queued run.
function M.flush()
    local done = false
    vim.schedule(function()
        done = true
    end)
    assert.is_true(vim.wait(500, function()
        return done
    end, 1))
end

---@return integer|nil the Dashboard buffer of this Neovim
local function dashboard_buf()
    local buf = vim.fn.bufnr(dashboard.NAME)
    if buf == -1 then
        return nil
    end
    return buf
end

-- The timer the poller schedules on: `pending` holds what the test fires, and
-- `after` gives the poller the cancel function it expects.
---@return table
local function timer()
    local t = { pending = {} }

    ---@param ms integer|nil
    ---@param callback fun()
    ---@return fun() cancel
    function t.after(ms, callback)
        local entry = { ms = ms, callback = callback }
        table.insert(t.pending, entry)
        return function()
            for index, pending in ipairs(t.pending) do
                if pending == entry then
                    table.remove(t.pending, index)
                    return
                end
            end
        end
    end

    function t.fire()
        local entry = table.remove(t.pending, 1)
        assert.is_not_nil(entry, 'nothing is scheduled')
        entry.callback()
    end

    ---@return integer how many callbacks are pending
    function t.count()
        return #t.pending
    end

    return t
end

-- The git runner: every call waits in `queue` until the test answers it, and
-- `calls` keeps every argument list git was run with.
---@return table
local function runner()
    local r = { calls = {}, queue = {} }

    ---@param argv string[]
    ---@param callback fun(err: string|nil, stdout: string|nil)
    function r.run(argv, callback)
        r.calls[#r.calls + 1] = argv
        r.queue[#r.queue + 1] = { argv = argv, callback = callback }
    end

    ---@return table the oldest call the test has not answered
    function r.next()
        local call = table.remove(r.queue, 1)
        assert.is_not_nil(call, 'no git call is waiting')
        return call
    end

    -- Answers the status call of a path, then its work tree root call.
    ---@param status string what `git status` printed
    ---@param root string what `git rev-parse --show-toplevel` printed
    function r.answer(status, root)
        r.next().callback(nil, status)
        r.next().callback(nil, root)
    end

    return r
end

-- The prompts the user sees. Every `vim.ui.select` and `vim.ui.input` waits
-- here until the test answers it, and `calls` keeps every prompt, answered or
-- not, in order.
---@return table
local function prompts()
    local p = { calls = {}, open = {} }

    ---@param entry table
    local function record(entry)
        p.calls[#p.calls + 1] = entry
        p.open[#p.open + 1] = entry
    end

    ---@param items string[]
    ---@param opts table
    ---@param answer fun(choice: string|nil)
    function p.select(items, opts, answer)
        record({
            kind = 'select',
            items = items,
            opts = opts,
            answer = answer,
        })
    end

    ---@param opts table
    ---@param answer fun(text: string|nil)
    function p.input(opts, answer)
        record({
            kind = 'input',
            opts = opts,
            default = opts and opts.default,
            answer = answer,
        })
    end

    ---@return table the oldest prompt the test has not answered
    function p.next()
        local entry = table.remove(p.open, 1)
        assert.is_not_nil(entry, 'no prompt is open')
        return entry
    end

    -- Answers the oldest prompt: `2` picks the second item, `'pi'` the item
    -- itself and `nil` cancels, as `<Esc>` does.
    ---@param choice integer|string|nil
    function p.answer_select(choice)
        local entry = p.next()
        assert.are.equal('select', entry.kind)
        local value = choice
        if type(choice) == 'number' then
            value = entry.items[choice]
        end
        entry.answer(value)
    end

    -- Answers the oldest prompt with `text`; nil cancels, as `<Esc>` does.
    ---@param text string|nil
    function p.answer_input(text)
        local entry = p.next()
        assert.are.equal('input', entry.kind)
        entry.answer(text)
    end

    ---@return integer how many prompts the test has not answered
    function p.count()
        return #p.open
    end

    return p
end

-- A git clock the test moves by hand, in milliseconds.
---@return table
local function clock()
    local c = { ms = 1000 }

    function c.now()
        return c.ms
    end

    ---@param ms integer
    function c.advance(ms)
        c.ms = c.ms + ms
    end

    return c
end

-- What the Dashboard told the user: the `vim.notify` route of the actions and
-- the `notify` seam of the hooks record into the same list.
---@return table
local function notifier()
    local n = { calls = {} }

    ---@param message string
    ---@param level integer|nil
    function n.notify(message, level)
        n.calls[#n.calls + 1] = { message = message, level = level }
    end

    return n
end

-- The buffer a window falls back to when the Dashboard leaves it. A spec that
-- deleted the scratch buffer gets a fresh one.
---@param self ui_support.Harness
---@return integer
local function replacement(self)
    if not vim.api.nvim_buf_is_valid(self.scratch) then
        self.scratch = vim.api.nvim_create_buf(true, false)
    end
    return self.scratch
end

---@class ui_support.Harness
---@field scratch integer the buffer the Dashboard is shown over
---@field timer table the poller's timer seam
---@field clock table the git cache's clock seam
---@field git table the git cache's run seam
---@field notify table what the Dashboard told the user
---@field prompt table the `vim.ui` prompts the test answers
---@field opened integer|nil the Dashboard buffer this harness opened

local Harness = {}
Harness.__index = Harness

---@return ui_support.Harness
function M.new()
    local self = setmetatable({}, Harness)
    self.timer, self.clock, self.git, self.notify =
        timer(), clock(), runner(), notifier()
    self.prompt = prompts()

    self.scratch = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(0, self.scratch)

    -- The values the harness replaces, kept for `close`.
    self.rex_session = vim.env.REX_SESSION
    vim.env.REX_SESSION = nil
    self.notify_fn = vim.notify
    vim.notify = self.notify.notify
    self.select_fn = vim.ui.select
    vim.ui.select = self.prompt.select
    self.input_fn = vim.ui.input
    vim.ui.input = self.prompt.input
    self.rex_module = package.loaded['rexai.backend.rex']
    self.loaded_rexai = vim.g.loaded_rexai
    self.saved_config = vim.deepcopy(config.get())
    return self
end

---@return integer|nil the Dashboard buffer, nil once it is wiped
function Harness:buf()
    return dashboard_buf()
end

---@return string[] the buffer lines of the Dashboard
function Harness:lines()
    return vim.api.nvim_buf_get_lines(assert(self:buf()), 0, -1, false)
end

---@return integer|nil the float window shown, nil when there is none
function Harness:float()
    return M.floats()[1]
end

---@return string[]|nil the lines of the float window, nil when there is none
function Harness:float_lines()
    local win = self:float()
    if not win then
        return nil
    end
    local buf = vim.api.nvim_win_get_buf(win)
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

-- Types `keys` in normal mode and waits for the Dashboard to handle them.
---@param keys string
function Harness:press(keys)
    vim.api.nvim_feedkeys(vim.keycode(keys), 'x', false)
end

-- Shows the Dashboard in the current window. The fake Backend serves
-- `opts.snapshots`, or `opts.backend` goes in as it is; the poller, the git
-- cache and the hooks object get the harness seams.
---@param opts table|nil `backend` or `snapshots` and `peek`, `home_session_id`
---@return table backend
---@return table[]|nil calls every Backend call, in order
function Harness:open(opts)
    opts = opts or {}
    local backend, calls = opts.backend, nil
    if not backend then
        backend, calls = fake.new({
            snapshots = opts.snapshots or {},
            peek = opts.peek,
        })
    end

    dashboard.open({
        backend = backend,
        after = self.timer.after,
        now = function()
            return M.NOW
        end,
        home_session_id = opts.home_session_id,
        git = { run = self.git.run, clock = self.clock.now },
        hooks = { notify = self.notify.notify },
    })
    self.opened = dashboard_buf()
    return backend, calls
end

-- Shows the Dashboard with the `:Rexai` command, the way the plugin wires it.
-- With `opts.snapshots`, `rexai.backend.rex` is stubbed with a fake Backend
-- that serves them.
---@param opts table|nil `snapshots`
---@return table|nil backend
---@return table[]|nil calls every Backend call, in order
function Harness:command(opts)
    opts = opts or {}
    local backend, calls
    if opts.snapshots then
        backend, calls = fake.new({ snapshots = opts.snapshots })
        package.loaded['rexai.backend.rex'] = {
            new = function()
                return backend
            end,
        }
    end
    vim.g.loaded_rexai = nil
    vim.cmd('runtime plugin/rexai.lua')
    vim.cmd('Rexai')
    self.opened = dashboard_buf()
    return backend, calls
end

-- Wipes a buffer wherever it is shown, so nothing it owns outlives it.
---@param buf integer|nil
function Harness:wipe(buf)
    if not (buf and vim.api.nvim_buf_is_valid(buf)) then
        return
    end
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
        if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_set_buf(win, replacement(self))
        end
    end
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
end

-- Puts the environment back: wiping the Dashboard buffer stops its poller and
-- its git cache, and every replaced value returns.
function Harness:close()
    self:wipe(self.opened)
    -- A session load wipes the Dashboard buffer and makes a new one under the
    -- same name, so the name finds a buffer `opened` no longer holds.
    self:wipe(dashboard_buf())
    if vim.api.nvim_buf_is_valid(self.scratch) then
        vim.api.nvim_buf_delete(self.scratch, { force = true })
    end

    package.loaded['rexai.backend.rex'] = self.rex_module
    vim.notify = self.notify_fn
    vim.ui.select = self.select_fn
    vim.ui.input = self.input_fn
    vim.env.REX_SESSION = self.rex_session
    vim.g.loaded_rexai = self.loaded_rexai
    config.setup(self.saved_config)
end

return M
