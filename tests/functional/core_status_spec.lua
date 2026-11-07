local status = require('rexai.core.status')

describe('core.status', function()
    describe('ORDER and rank', function()
        it('lists the statuses from highest priority to lowest', function()
            assert.are.same({
                'needs_input',
                'error',
                'done',
                'working',
                'unreported',
                'idle',
                'exited',
            }, status.ORDER)
        end)

        it('ranks every status by its place in ORDER', function()
            for index, name in ipairs(status.ORDER) do
                assert.are.equal(index, status.rank(name))
            end
        end)

        it('gives nil for an unknown name', function()
            assert.is_nil(status.rank('sleeping'))
        end)
    end)

    describe('from_record', function()
        local cases = {
            { 'idle', 'idle' },
            { 'working', 'working' },
            { 'done', 'done' },
            { 'error', 'error' },
            { 'blocked', 'needs_input' },
        }
        for _, case in ipairs(cases) do
            local state, expected = case[1], case[2]
            it('maps ' .. state .. ' to ' .. expected, function()
                local result = status.from_record({ state = state })
                assert.are.equal(expected, result.name)
            end)
        end

        it('gives nil for clear', function()
            assert.is_nil(status.from_record({ state = 'clear' }))
        end)

        it('gives nil for a state added by a newer Rex', function()
            assert.is_nil(status.from_record({ state = 'napping' }))
        end)

        it('keeps the kind only for needs_input', function()
            local blocked = status.from_record({
                state = 'blocked',
                kind = 'permission',
            })
            assert.are.equal('permission', blocked.kind)

            local working = status.from_record({
                state = 'working',
                kind = 'permission',
            })
            assert.is_nil(working.kind)
        end)

        it('carries the message and the time', function()
            local result = status.from_record({
                state = 'done',
                msg = 'finished',
                updated_at = '2026-01-01T10:00:00+00:00',
            })
            assert.are.equal('finished', result.msg)
            assert.are.equal('2026-01-01T10:00:00+00:00', result.updated_at)
        end)
    end)

    describe('of_records', function()
        local cases = {
            { 'no records', {}, 'unreported' },
            { 'nil records', nil, 'unreported' },
            { 'only clear', { { state = 'clear' } }, 'unreported' },
            { 'one record', { { state = 'working' } }, 'working' },
            {
                'the highest priority among several',
                {
                    { state = 'idle' },
                    { state = 'working' },
                    { state = 'done' },
                },
                'done',
            },
            {
                'needs_input over error',
                { { state = 'error' }, { state = 'blocked' } },
                'needs_input',
            },
            {
                'a known state next to an unknown one',
                { { state = 'napping' }, { state = 'idle' } },
                'idle',
            },
        }
        for _, case in ipairs(cases) do
            local name, records, expected = case[1], case[2], case[3]
            it('gives ' .. expected .. ' for ' .. name, function()
                assert.are.equal(expected, status.of_records(records).name)
            end)
        end

        it('returns the winning record details', function()
            local result = status.of_records({
                { state = 'working', msg = 'thinking' },
                { state = 'blocked', kind = 'question', msg = 'which one?' },
            })
            assert.are.same({
                name = 'needs_input',
                kind = 'question',
                msg = 'which one?',
            }, result)
        end)
    end)

    describe('rollup', function()
        local cases = {
            { 'an empty list', {}, nil },
            { 'one name', { 'idle' }, 'idle' },
            {
                'needs_input first',
                { 'done', 'needs_input', 'error' },
                'needs_input',
            },
            { 'error over done', { 'done', 'error' }, 'error' },
            { 'done over working', { 'working', 'done' }, 'done' },
            {
                'working over unreported',
                { 'unreported', 'working' },
                'working',
            },
            { 'unreported over idle', { 'idle', 'unreported' }, 'unreported' },
            { 'idle over exited', { 'exited', 'idle' }, 'idle' },
            { 'only exited', { 'exited', 'exited' }, 'exited' },
            { 'ignoring unknown names', { 'bogus', 'idle' }, 'idle' },
        }
        for _, case in ipairs(cases) do
            local name, names, expected = case[1], case[2], case[3]
            it('handles ' .. name, function()
                assert.are.equal(expected, status.rollup(names))
            end)
        end
    end)
end)
