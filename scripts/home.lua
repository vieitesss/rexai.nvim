-- Runs inside Rex (`rex do scripts/home.lua --json name=rexai cwd=/path`),
-- Lua 5.1. Finds or creates the Home session, labelled `rexai` unless a name is
-- given, and its Window labelled `dashboard`, and returns the ids of the Block
-- that runs the Dashboard. It selects nothing: `scripts/focus.lua` shows the
-- result in the Rex app of the caller.
--
-- Arguments (rex.args, KEY=VALUE pairs, so each value's type comes from how it
-- is written):
--   name  the Session's label; defaults to `rexai`
--   cwd   the directory the Dashboard starts in; defaults to HOME
--
-- `name` and `cwd` are turned into strings: a name like `2` arrives as a
-- number. Without a `cwd` and without a readable HOME the script fails.

local FLAVOR = 'com.superlogical.terminal.shell'
local DEFAULT_NAME = 'rexai'
local WINDOW_LABEL = 'dashboard'

local function fail(message)
    error(message, 0)
end

-- `rex.call` returns `nil, message` on failure instead of raising.
local function reason(err)
    return (
        tostring(err or 'rex failed'):gsub(
            '^stream response "[^"]*" failed: ',
            ''
        )
    )
end

---@param method string
---@param params table|nil
---@return table
local function call(method, params)
    local result, err = rex.call(method, params)
    if result == nil then
        fail(reason(err))
    end
    ---@cast result table
    return result
end

-- An argument as a string, or nil when it is missing or empty.
local function text(value)
    if value == nil then
        return nil
    end
    value = tostring(value)
    if value == '' then
        return nil
    end
    return value
end

-- An environment variable, when this Rex lets a script read one.
local function environment(name)
    if type(os) == 'table' and type(os.getenv) == 'function' then
        return os.getenv(name)
    end
    return nil
end

local args = rex.args or {}
local name = text(args.name) or DEFAULT_NAME
local cwd = text(args.cwd) or text(environment('HOME'))
if not cwd then
    fail('cwd is required when HOME is unset')
end

-- The dashboard Window holds one Block that runs the Dashboard in Neovim.
local function layout()
    return {
        block = {
            flavor = FLAVOR,
            options = { command = { 'nvim', '+Rexai' }, cwd = cwd },
        },
    }
end

-- The first Block of a Window, in layout order: its layers, then each layer's
-- blocks.
local function first_block(window)
    for _, layer in ipairs(window.layers or {}) do
        for _, block in ipairs(layer.blocks or {}) do
            if block.block_id then
                return block.block_id
            end
        end
    end
    return nil
end

local sessions = call('session.list').sessions or {}

-- The Session is the first one labelled `name`.
local session_id
for _, session in ipairs(sessions) do
    if session.label == name then
        session_id = session.session_id
        break
    end
end

if not session_id then
    local created = call('session.create', {
        label = name,
        initial_windows = {
            { window_label = WINDOW_LABEL, layout = layout() },
        },
    })
    local first = (created.initial_windows or {})[1] or {}
    local block_id = (first.block_ids or {})[1]
    if not (created.session_id and first.window_id and block_id) then
        fail('Rex did not describe the Session it created')
    end
    return {
        session_id = created.session_id,
        window_id = first.window_id,
        block_id = block_id,
        created = 'session',
    }
end

call('session.attach', { session_id = session_id })
local view, view_err = rex.session.view({ session_id = session_id })
if view == nil then
    fail(reason(view_err))
end
---@cast view table

-- The Window is the first one of that Session labelled `dashboard`.
local window
for _, candidate in ipairs(view.windows or {}) do
    if candidate.label == WINDOW_LABEL then
        window = candidate
        break
    end
end

if not window then
    local created = call('session.new_window', {
        session_id = session_id,
        window_label = WINDOW_LABEL,
        layout = layout(),
    })
    local block_id = (created.block_ids or {})[1]
    if not (created.window_id and block_id) then
        fail('Rex did not describe the Window it created')
    end
    return {
        session_id = session_id,
        window_id = created.window_id,
        block_id = block_id,
        created = 'window',
    }
end

local block_id = first_block(window)
if not block_id then
    fail('the dashboard Window has no Block')
end

return {
    session_id = session_id,
    window_id = window.window_id,
    block_id = block_id,
}
