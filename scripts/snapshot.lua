-- Runs inside Rex (`rex do scripts/snapshot.lua --json`), Lua 5.1.
-- Returns one table describing every Session, Window and terminal Block,
-- with the Agent status records and process facts the Dashboard needs.
-- Reading only: this script never changes anything in Rex.

local TERMINAL = 'com.superlogical.terminal'

local function call(method, args)
    local ok, value = pcall(rex.block.call, TERMINAL, method, args)
    if ok then
        return value
    end
    return nil
end

local function record(r)
    return {
        state = r.state,
        kind = r.kind,
        app = r.app,
        effective_app = r.effective_app,
        msg = r.msg,
        updated_at = r.updated_at,
    }
end

local function process(p)
    if not p then
        return nil
    end
    local fg = p.foreground
    local child = p.child
    return {
        argv0 = fg and fg.argv0 or nil,
        name = fg and fg.name or nil,
        cwd = fg and fg.cwd or nil,
        last_exit = p.last_exit,
        child = child and { name = child.name, path = child.path } or nil,
    }
end

local function block(session_id, b)
    local args = { session_id = session_id, block_id = b.block_id }
    local status = call('program_status', args)
    local title = call('title', args)
    local records = {}
    for _, r in ipairs(status and status.records or {}) do
        records[#records + 1] = record(r)
    end
    return {
        id = b.block_id,
        label = b.label,
        title = title and title.title or nil,
        records = records,
        process = process(call('process', args)),
    }
end

local function window(session_id, w)
    local blocks = {}
    for _, layer in ipairs(w.layers or {}) do
        for _, b in ipairs(layer.blocks or {}) do
            if (b.flavor or ''):find(TERMINAL, 1, true) == 1 then
                blocks[#blocks + 1] = block(session_id, b)
            end
        end
    end
    return {
        id = w.window_id,
        label = w.label,
        focused_block_id = w.focused_block_id,
        blocks = blocks,
    }
end

local function session(s)
    local out = { id = s.session_id, label = s.label, windows = {} }
    -- `rex.call` returns `nil, message` on failure instead of raising.
    local ok, attached, attach_err =
        pcall(rex.call, 'session.attach', { session_id = s.session_id })
    if not ok or attached == nil then
        out.error = tostring(ok and attach_err or attached)
        return out
    end
    local view, view_err = rex.session.view({ session_id = s.session_id })
    if not view then
        out.error = tostring(view_err)
        return out
    end
    out.active_window_id = view.active_window_id
    for _, w in ipairs(view.windows or {}) do
        out.windows[#out.windows + 1] = window(s.session_id, w)
    end
    return out
end

local sessions = {}
for _, s in ipairs(rex.call('session.list').sessions or {}) do
    sessions[#sessions + 1] = session(s)
end

return { version = 1, sessions = sessions }
