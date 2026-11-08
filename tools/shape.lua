-- The shape of a JSON value: which key paths it holds, and which types appear
-- at each of them. `just smoke` compares the shape of a live snapshot with the
-- shape of every committed fixture, so a change in what Rex reports fails a
-- check even though the fixture stays as it is.
--
-- An array collapses into one `[]` step: `sessions[].id` is the `id` key of
-- every Session, whatever their number. A path also records how many objects
-- there are at its parent and how many of them hold the key, so a key that
-- disappears from every object can be told from a key that was optional all
-- along.
--
-- Pure Lua: no `vim` global, so tests load it with dofile.

local M = {}

---@class rexai.ShapeHit what the walk collects at one path
---@field types table<string, boolean>
---@field count integer how many values of this path were seen
---@field parent string the path of the node that holds this one

---@class rexai.ShapeEntry
---@field types table<string, boolean> the types seen at this path, as a set
---@field parent string the path of the objects that hold this key
---@field count integer how many objects at `parent` hold the key
---@field parent_count integer how many objects there are at `parent`

---@class rexai.Shape
---@field entries table<string, rexai.ShapeEntry> keyed by path
---@field objects table<string, integer> how many objects there are at a path

---@class rexai.ShapeDrift
---@field path string
---@field live string[] the live types at this path, none of them in the fixture
---@field fixture string[] the fixture types at this path

---@class rexai.ShapeDiff
---@field ok boolean no drift and no vanished key
---@field drift rexai.ShapeDrift[] paths whose live types the fixture lacks
---@field vanished string[] keys the fixture has on every object at its parent, and live on none
---@field live_only string[] notes: paths only the live shape has
---@field fixture_only string[] notes: paths only the fixture shape has

-- The type of a value, or nil for a value that carries none: `null`, and the
-- sentinel a JSON decoder leaves behind for it.
---@param value any
---@return string|nil
local function type_of(value)
    local kind = type(value)
    if kind == 'table' then
        -- A decoder turns `[]` and `{}` into the same empty table. An empty
        -- table is the array: that is the shape `tools/anonymize.lua` writes,
        -- so both sides of a comparison agree on it.
        if next(value) == nil or value[1] ~= nil then
            return 'array'
        end
        return 'object'
    end
    if kind == 'string' or kind == 'number' or kind == 'boolean' then
        return kind
    end
    return nil
end

---@param path string
---@param key string
---@return string
local function join(path, key)
    if path == '' then
        return key
    end
    return path .. '.' .. key
end

-- Records one node of the tree: its type at `path`, and, for an object, how
-- many objects there are at that path. An array contributes its `[]` step and
-- then hands every element to the same path, so the number of elements never
-- reaches a path.
---@param value any
---@param path string
---@param parent string the path of the node that holds this one
---@param hits table<string, rexai.ShapeHit>
---@param objects table<string, integer>
local function walk(value, path, parent, hits, objects)
    local kind = type_of(value)
    if not kind then
        return
    end

    -- The root holds no key, so it is no path of its own. It still counts as
    -- the parent object of the top-level keys.
    if path ~= '' then
        local hit = hits[path]
        if not hit then
            hit = { types = {}, count = 0, parent = parent }
            hits[path] = hit
        end
        hit.types[kind] = true
        hit.count = hit.count + 1
    end

    if kind == 'object' then
        objects[path] = (objects[path] or 0) + 1
        for key, child in pairs(value) do
            if type(key) == 'string' then
                walk(child, join(path, key), path, hits, objects)
            end
        end
        return
    end
    if kind ~= 'array' then
        return
    end
    for _, child in ipairs(value) do
        walk(child, path .. '[]', path, hits, objects)
    end
end

---@param map table
---@return string[]
local function sorted_keys(map)
    local keys = {}
    for key in pairs(map) do
        keys[#keys + 1] = key
    end
    table.sort(keys)
    return keys
end

---@param types table<string, boolean>
---@return string[]
local function sorted_types(types)
    local names = {}
    for name in pairs(types) do
        names[#names + 1] = name
    end
    table.sort(names)
    return names
end

---@param value any
---@return rexai.Shape
function M.of(value)
    local hits, objects = {}, {}
    walk(value, '', '', hits, objects)
    local entries = {}
    for path, hit in pairs(hits) do
        entries[path] = {
            types = hit.types,
            parent = hit.parent,
            count = hit.count,
            parent_count = objects[hit.parent] or 0,
        }
    end
    return { entries = entries, objects = objects }
end

---@param live rexai.Shape
---@param fixture rexai.Shape
---@return rexai.ShapeDiff
function M.compare(live, fixture)
    local diff = {
        ok = true,
        drift = {},
        vanished = {},
        live_only = {},
        fixture_only = {},
    }

    for _, path in ipairs(sorted_keys(live.entries)) do
        local mine = live.entries[path]
        local theirs = fixture.entries[path]
        if not theirs then
            diff.live_only[#diff.live_only + 1] = path
        else
            local missing = {}
            for name in pairs(mine.types) do
                if not theirs.types[name] then
                    missing[#missing + 1] = name
                end
            end
            if #missing > 0 then
                table.sort(missing)
                diff.drift[#diff.drift + 1] = {
                    path = path,
                    live = missing,
                    fixture = sorted_types(theirs.types),
                }
            end
        end
    end

    for _, path in ipairs(sorted_keys(fixture.entries)) do
        local theirs = fixture.entries[path]
        if not live.entries[path] then
            diff.fixture_only[#diff.fixture_only + 1] = path
            -- A key the fixture has on every object at its parent is a key
            -- live must still have somewhere, unless live has no object at
            -- that path at all: then there is nothing to be missing from.
            if
                theirs.count == theirs.parent_count
                and (live.objects[theirs.parent] or 0) > 0
            then
                diff.vanished[#diff.vanished + 1] = path
            end
        end
    end

    diff.ok = #diff.drift == 0 and #diff.vanished == 0
    return diff
end

return M
