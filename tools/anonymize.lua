-- Turns a raw snapshot from scripts/snapshot.lua into a fixture that is safe
-- to commit. Pure Lua: no `vim` global, so tests can load it with dofile.
--
-- The rewrite is a whitelist. Structure, states, app names, kinds,
-- timestamps and exit codes stay. Every free-text field (ids, labels,
-- titles, messages, paths) becomes a deterministic placeholder. The same
-- original value always gets the same placeholder, so a duplicated label
-- stays duplicated.

local M = {}

local ZERO_UUID = '00000000-0000-7000-8000-%012d'

---@param prefix string
---@return fun(value: string|nil): string|nil
local function interner(prefix)
    local seen, count = {}, 0
    return function(value)
        if value == nil then
            return nil
        end
        if value == '' then
            return ''
        end
        if not seen[value] then
            count = count + 1
            seen[value] = prefix .. count
        end
        return seen[value]
    end
end

---@param value string|nil
---@return string|nil
local function basename(value)
    if value == nil then
        return nil
    end
    local name = value:match('([^/]+)$') or value
    if name:match('^[%w._+-]+$') then
        return name
    end
    return nil
end

---@param raw table
---@return table
function M.anonymize(raw)
    local id_counts, id_map = {}, {}
    local function id(value)
        if value == nil then
            return nil
        end
        if not id_map[value] then
            local kind = value:match('^(%a+):') or 'id'
            id_counts[kind] = (id_counts[kind] or 0) + 1
            id_map[value] =
                string.format(kind .. ':' .. ZERO_UUID, id_counts[kind])
        end
        return id_map[value]
    end

    local session_label = interner('session-')
    local window_label = interner('window-')
    local block_label = interner('block-')
    local title = interner('title-')
    local msg = interner('msg-')
    local error_text = interner('error-')
    local proc_name = interner('proc-')
    local cwd_map = interner('/work/project-')

    local function process_name(value)
        return basename(value) or proc_name(value)
    end

    -- An absolute path keeps its shape but loses its directories.
    local function path_like(value)
        if value == nil then
            return nil
        end
        local name = process_name(value)
        if value:find('/', 1, true) then
            return '/opt/bin/' .. name
        end
        return name
    end

    local function label_of_window(w, new_id)
        if (w.label or ''):match('^Window %x+$') then
            return 'Window ' .. new_id:sub(-8)
        end
        return window_label(w.label)
    end

    local function record(r)
        return {
            state = r.state,
            kind = r.kind,
            app = r.app,
            effective_app = r.effective_app,
            msg = msg(r.msg),
            updated_at = r.updated_at,
        }
    end

    local function process(p)
        if p == nil then
            return nil
        end
        local last_exit = p.last_exit
        local child = p.child
        return {
            argv0 = path_like(p.argv0),
            name = process_name(p.name),
            cwd = cwd_map(p.cwd),
            last_exit = last_exit and {
                exit_code = last_exit.exit_code,
                error = error_text(last_exit.error),
            } or nil,
            child = child and {
                name = process_name(child.name),
                path = path_like(child.path),
            } or nil,
        }
    end

    local function block(b)
        local records = {}
        for _, r in ipairs(b.records or {}) do
            records[#records + 1] = record(r)
        end
        return {
            id = id(b.id),
            label = b.label == 'shell' and 'shell' or block_label(b.label),
            title = title(b.title),
            records = records,
            process = process(b.process),
        }
    end

    local function window(w)
        local new_id = id(w.id)
        local blocks = {}
        for _, b in ipairs(w.blocks or {}) do
            blocks[#blocks + 1] = block(b)
        end
        return {
            id = new_id,
            label = label_of_window(w, new_id),
            focused_block_id = id(w.focused_block_id),
            blocks = blocks,
        }
    end

    local sessions = {}
    for _, s in ipairs(raw.sessions or {}) do
        local windows = {}
        for _, w in ipairs(s.windows or {}) do
            windows[#windows + 1] = window(w)
        end
        sessions[#sessions + 1] = {
            id = id(s.id),
            label = session_label(s.label),
            active_window_id = id(s.active_window_id),
            error = s.error and 'error' or nil,
            windows = windows,
        }
    end

    return { version = raw.version, sessions = sessions }
end

-- Validation: every key and value of a fixture must match the whitelist.

local function fail(errors, path, message)
    errors[#errors + 1] = path .. ': ' .. message
end

local function str(...)
    local patterns = { ... }
    return function(v, path, errors, optional)
        if v == nil then
            if not optional then
                fail(errors, path, 'missing')
            end
            return
        end
        if type(v) == 'string' then
            for _, pattern in ipairs(patterns) do
                if v:match(pattern) then
                    return
                end
            end
        end
        fail(errors, path, 'value not allowed')
    end
end

local function num(v, path, errors, optional)
    if v == nil and optional then
        return
    end
    if type(v) ~= 'number' then
        fail(errors, path, 'expected number')
    end
end

local function opt(check)
    return function(v, path, errors)
        check(v, path, errors, true)
    end
end

local function object(fields)
    return function(v, path, errors, optional)
        if v == nil and optional then
            return
        end
        if type(v) ~= 'table' then
            fail(errors, path, 'expected object')
            return
        end
        for key, check in pairs(fields) do
            check(v[key], path .. '.' .. key, errors)
        end
        for key in pairs(v) do
            if not fields[key] then
                fail(errors, path, 'unexpected key ' .. tostring(key))
            end
        end
    end
end

local function array(item)
    return function(v, path, errors)
        if type(v) ~= 'table' then
            fail(errors, path, 'expected array')
            return
        end
        for i, element in ipairs(v) do
            item(element, path .. '[' .. i .. ']', errors)
        end
    end
end

local proc = str('^[%w._+-]+$', '^proc%-%d+$')
local exe = str('^[%w._+-]+$', '^/opt/bin/[%w._+-]+$', '^/opt/bin/proc%-%d+$')

local record_schema = object({
    state = str('^idle$', '^working$', '^done$', '^blocked$', '^error$'),
    kind = opt(str('^permission$', '^question$', '^auth$')),
    app = str('^[%w._-]+$'),
    effective_app = str('^[%w._-]+$'),
    msg = opt(str('^$', '^msg%-%d+$')),
    updated_at = str('^%d%d%d%d%-%d%d%-%d%dT[%d:.]+Z?[+-]?[%d:]*$'),
})

local process_schema = object({
    argv0 = opt(exe),
    name = opt(proc),
    cwd = opt(str('^/work/project%-%d+$')),
    last_exit = opt(object({
        exit_code = num,
        error = opt(str('^error%-%d+$')),
    })),
    child = opt(object({ name = proc, path = exe })),
})

local block_schema = object({
    id = str('^block:[%x-]+$'),
    label = str('^shell$', '^block%-%d+$'),
    title = str('^$', '^title%-%d+$'),
    records = array(record_schema),
    process = opt(process_schema),
})

local window_schema = object({
    id = str('^window:[%x-]+$'),
    label = str('^Window %x+$', '^window%-%d+$'),
    focused_block_id = opt(str('^block:[%x-]+$')),
    blocks = array(block_schema),
})

local session_schema = object({
    id = str('^session:[%x-]+$'),
    label = str('^session%-%d+$'),
    active_window_id = opt(str('^window:[%x-]+$')),
    error = opt(str('^error$')),
    windows = array(window_schema),
})

local snapshot_schema = object({
    version = num,
    sessions = array(session_schema),
})

---@param snapshot table
---@return string[] errors
function M.validate(snapshot)
    local errors = {}
    snapshot_schema(snapshot, 'snapshot', errors)
    return errors
end

---@param text string
---@param needles string[]
---@return string[] found the needles that appear in text
function M.leaks(text, needles)
    local found = {}
    for _, needle in ipairs(needles) do
        if needle ~= '' and text:find(needle, 1, true) then
            found[#found + 1] = needle
        end
    end
    return found
end

-- Canonical JSON: sorted keys, two-space indent, one trailing newline.
-- The output is stable, so a regenerated fixture shows a clean diff.

local ESCAPES = {
    ['"'] = '\\"',
    ['\\'] = '\\\\',
    ['\n'] = '\\n',
    ['\r'] = '\\r',
    ['\t'] = '\\t',
}

---@param s string
---@return string
local function quote(s)
    return '"'
        .. s:gsub('[%c"\\]', function(c)
            return ESCAPES[c] or string.format('\\u%04x', c:byte())
        end)
        .. '"'
end

---@param value any
---@param indent string
---@return string
local function encode_value(value, indent)
    local kind = type(value)
    if kind == 'string' then
        return quote(value)
    elseif kind == 'number' then
        if value == math.floor(value) then
            return string.format('%d', value)
        end
        return string.format('%.14g', value)
    elseif kind == 'boolean' then
        return tostring(value)
    elseif kind ~= 'table' then
        error('cannot encode ' .. kind)
    end

    local inner = indent .. '  '
    local parts = {}
    if next(value) == nil or #value > 0 then
        for _, element in ipairs(value) do
            parts[#parts + 1] = inner .. encode_value(element, inner)
        end
        if #parts == 0 then
            return '[]'
        end
        return '[\n' .. table.concat(parts, ',\n') .. '\n' .. indent .. ']'
    end

    local keys = {}
    for key in pairs(value) do
        keys[#keys + 1] = key
    end
    table.sort(keys)
    for _, key in ipairs(keys) do
        parts[#parts + 1] = inner
            .. quote(key)
            .. ': '
            .. encode_value(value[key], inner)
    end
    return '{\n' .. table.concat(parts, ',\n') .. '\n' .. indent .. '}'
end

---@param value table
---@return string
function M.encode(value)
    return encode_value(value, '') .. '\n'
end

return M
