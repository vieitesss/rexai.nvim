-- Runs inside Rex (`rex do scripts/focus.lua --args JSON`), Lua 5.1.
-- Shows a Session, Window and Block in the Rex app of the caller.
--
-- Arguments (rex.args):
--   session_id  the Session to show
--   window_id   optional: the Window to show
--   block_id    optional: the Block to focus
--
-- The app is the one that owns the caller's Block (REX_BLOCK). Outside Rex
-- the script uses the only connected app, and fails when there are several.
-- It fails with a message when the app cannot be found or Rex refuses.

local TERMINAL = 'com.superlogical.terminal'

local function fail(message)
    error(message, 0)
end

-- `rex.call` returns `nil, message` on failure instead of raising.
local function call(method, params)
    local result, err = rex.call(method, params)
    if result == nil then
        local message =
            tostring(err):gsub('^stream response "[^"]*" failed: ', '')
        fail(message)
    end
    return result
end

-- The app that owns the caller's Block, or nil.
local function owner_of_caller()
    if not rex.session_id or not rex.block_id then
        return nil
    end
    local ok, size = pcall(rex.block.call, TERMINAL, 'size', {
        session_id = rex.session_id,
        block_id = rex.block_id,
    })
    if ok and type(size) == 'table' then
        return size.owner
    end
    return nil
end

local function only_app()
    local apps = {}
    for _, client in
        ipairs(call('client.list', { kinds = { 'app' } }).clients or {})
    do
        if client.connection_state ~= 'lost' then
            apps[#apps + 1] = client
        end
    end
    if #apps == 0 then
        fail('no Rex app is connected')
    end
    if #apps > 1 then
        fail('several Rex apps are connected; run Neovim inside the Rex to use')
    end
    return apps[1].client_id
end

local args = rex.args or {}
local session_id = args.session_id
if type(session_id) ~= 'string' or session_id == '' then
    fail('session_id is required')
end

local client_id = owner_of_caller() or only_app()

local select_args = { session_id = session_id }
if args.window_id then
    select_args.window_id = args.window_id
end
call('client.perform', {
    client_id = client_id,
    action = 'session.select',
    args = select_args,
})

if args.block_id then
    call('session.attach', { session_id = session_id })
    call('session.focus_block', {
        session_id = session_id,
        block_id = args.block_id,
    })
end

return { client_id = client_id }
