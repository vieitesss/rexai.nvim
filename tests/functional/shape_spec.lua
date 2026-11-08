-- The shape module `just smoke` compares a live snapshot with the committed
-- fixtures through. It is pure Lua, so the spec loads it the way the tool does
-- and uses invented values only.

local helpers = require('tests.helpers')

local shape = dofile(helpers.root() .. '/tools/shape.lua')

-- Sorted type names of one path of a shape, so an assertion reads as a list.
local function types_at(value, path)
    local entry = shape.of(value).entries[path]
    assert.is_truthy(entry, 'no path ' .. path)
    local names = {}
    for name in pairs(entry.types) do
        names[#names + 1] = name
    end
    table.sort(names)
    return names
end

describe('shape.of', function()
    it('records the type of every path', function()
        local value = {
            version = 1,
            label = 'example',
            active = true,
            windows = { { id = 'window:one' } },
        }

        assert.are.same({ 'number' }, types_at(value, 'version'))
        assert.are.same({ 'string' }, types_at(value, 'label'))
        assert.are.same({ 'boolean' }, types_at(value, 'active'))
        assert.are.same({ 'array' }, types_at(value, 'windows'))
        assert.are.same({ 'object' }, types_at(value, 'windows[]'))
    end)

    it('collapses arrays into one step', function()
        local value =
            { sessions = { { id = 'session:a' }, { id = 'session:b' } } }
        local got = shape.of(value)

        assert.are.same({ 'string' }, types_at(value, 'sessions[].id'))
        assert.is_nil(got.entries['sessions[1].id'])
        assert.are.equal(2, got.entries['sessions[].id'].count)
        assert.are.equal(2, got.entries['sessions[].id'].parent_count)
    end)

    it('records every type of a path that holds more than one', function()
        assert.are.same(
            { 'number', 'string' },
            types_at({ list = { 1, 'two' } }, 'list[]')
        )
    end)

    it('ignores null', function()
        local decoded = vim.json.decode(
            '{"a": 1, "gone": null}',
            { luanil = { object = true, array = true } }
        )

        assert.are.same({ 'number' }, types_at(decoded, 'a'))
        assert.is_nil(shape.of(decoded).entries.gone)
        assert.is_nil(shape.of({ a = 1, b = vim.NIL }).entries.b)
    end)

    it('counts the objects that have a key and those at its parent', function()
        local got = shape.of({
            items = { { id = 'a', name = 'one' }, { id = 'b' } },
        })

        assert.are.equal(1, got.entries['items[].name'].count)
        assert.are.equal(2, got.entries['items[].name'].parent_count)
        assert.are.equal(2, got.entries['items[].id'].count)
        assert.are.equal(1, got.objects[''])
    end)

    it('accepts a value that is not an object', function()
        assert.are.same({}, shape.of(1).entries)
    end)
end)

describe('shape.compare', function()
    it('passes two shapes that agree', function()
        local diff = shape.compare(
            shape.of({ version = 1, sessions = { { id = 'a' } } }),
            shape.of({ version = 1, sessions = { { id = 'b' } } })
        )

        assert.is_true(diff.ok)
        assert.are.same({}, diff.drift)
        assert.are.same({}, diff.vanished)
    end)

    it('fails for a type the fixture does not have', function()
        local diff = shape.compare(
            shape.of({ version = 'one' }),
            shape.of({ version = 1 })
        )

        assert.is_false(diff.ok)
        assert.are.same({
            { path = 'version', live = { 'string' }, fixture = { 'number' } },
        }, diff.drift)
    end)

    it(
        'passes when the live types are a subset of the fixture types',
        function()
            local diff = shape.compare(
                shape.of({ list = { 1 } }),
                shape.of({ list = { 1, 'two' } })
            )

            assert.is_true(diff.ok)
            assert.are.same({}, diff.drift)
        end
    )

    it(
        'fails for a key the fixture has on every object and live has none',
        function()
            local diff = shape.compare(
                shape.of({ items = { { id = 'a' }, { id = 'b' } } }),
                shape.of({
                    items = {
                        { id = 'a', name = 'one' },
                        { id = 'b', name = 'two' },
                    },
                })
            )

            assert.is_false(diff.ok)
            assert.are.same({ 'items[].name' }, diff.vanished)
        end
    )

    it(
        'does not fail for a key the fixture has on some objects only',
        function()
            local diff = shape.compare(
                shape.of({ items = { { id = 'a' }, { id = 'b' } } }),
                shape.of({
                    items = { { id = 'a', name = 'one' }, { id = 'b' } },
                })
            )

            assert.is_true(diff.ok)
            assert.are.same({}, diff.vanished)
        end
    )

    it('does not fail when live has no object at the parent path', function()
        local diff = shape.compare(
            shape.of({ items = {} }),
            shape.of({ items = { { id = 'a', name = 'one' } } })
        )

        assert.is_true(diff.ok)
        assert.are.same({}, diff.vanished)
        assert.are.same(
            { 'items[]', 'items[].id', 'items[].name' },
            diff.fixture_only
        )
    end)

    it('reports the paths only one side has as notes', function()
        local diff = shape.compare(
            shape.of({ version = 1, items = { { id = 'a', tag = 'one' } } }),
            shape.of({
                version = 1,
                items = { { id = 'a', note = 'one' }, { id = 'b' } },
            })
        )

        assert.is_true(diff.ok)
        assert.are.same({ 'items[].tag' }, diff.live_only)
        assert.are.same({ 'items[].note' }, diff.fixture_only)
    end)

    it('reports every failing path, sorted', function()
        local diff = shape.compare(
            shape.of({ b = 'text', a = 'text' }),
            shape.of({ a = 1, b = 2 })
        )

        assert.is_false(diff.ok)
        assert.are.same({ 'a', 'b' }, {
            diff.drift[1].path,
            diff.drift[2].path,
        })
    end)
end)
