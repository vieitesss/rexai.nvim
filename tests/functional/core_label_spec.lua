local label = require('rexai.core.label')

local function rows(...)
    local out = {}
    for _, harness in ipairs({ ... }) do
        out[#out + 1] = { harness = harness }
    end
    return out
end

local function labels(list)
    local out = {}
    for _, row in ipairs(list) do
        out[#out + 1] = row.label
    end
    return out
end

describe('core.label', function()
    describe('default_id', function()
        local cases = {
            { 'Window 0a1b2c3d', '0a1b2c3d' },
            { 'Window 00000001', '00000001' },
            { 'window-1', nil },
            { 'Window', nil },
            { 'Window xyz', nil },
            { 'My Window 0a1b', nil },
            { '', nil },
            { nil, nil },
        }
        for _, case in ipairs(cases) do
            local input, expected = case[1], case[2]
            it('reads the id from "' .. tostring(input) .. '"', function()
                assert.are.equal(expected, label.default_id(input))
            end)
        end
    end)

    describe('assign', function()
        local cases = {
            {
                name = 'a default label becomes harness and short id',
                window = 'Window 0a1b2c3d',
                rows = rows('claude-code'),
                expected = { 'claude-code 2c3d' },
            },
            {
                name = 'a short default id is used whole',
                window = 'Window 1a',
                rows = rows('pi'),
                expected = { 'pi 1a' },
            },
            {
                name = 'a custom label is kept for one row',
                window = 'auth-refactor',
                rows = rows('claude-code'),
                expected = { 'auth-refactor' },
            },
            {
                name = 'a custom label gets the harness for two rows',
                window = 'auth-refactor',
                rows = rows('claude-code', 'pi'),
                expected = { 'auth-refactor claude-code', 'auth-refactor pi' },
            },
            {
                name = 'an empty label becomes the harness',
                window = '',
                rows = rows('pi'),
                expected = { 'pi' },
            },
            {
                name = 'a missing label becomes the harness',
                window = nil,
                rows = rows('pi'),
                expected = { 'pi' },
            },
            {
                name = 'two rows with the same harness are numbered',
                window = 'work',
                rows = rows('pi', 'pi'),
                expected = { 'work pi', 'work pi #2' },
            },
            {
                name = 'a default label with two equal harnesses is numbered',
                window = 'Window 0a1b2c3d',
                rows = rows('pi', 'pi', 'pi'),
                expected = { 'pi 2c3d', 'pi 2c3d #2', 'pi 2c3d #3' },
            },
            {
                name = 'no rows changes nothing',
                window = 'work',
                rows = {},
                expected = {},
            },
        }
        for _, case in ipairs(cases) do
            it('handles ' .. case.name, function()
                label.assign(case.window, case.rows)
                assert.are.same(case.expected, labels(case.rows))
            end)
        end
    end)
end)
