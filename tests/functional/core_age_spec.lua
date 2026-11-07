-- Ages are calendar arithmetic on a Rex timestamp, never a clock of the
-- process, so the answer is the same under every time zone. The epoch below
-- comes from an independent calendar implementation:
-- 2026-01-01T00:00:00Z is 1767225600.

local age = require('rexai.core.age')

local EPOCH = 1767225600
local NOON = '2026-01-01T00:00:00Z'

describe('core.age', function()
    describe('format', function()
        it('gives no age without a time', function()
            assert.are.equal('', age.format(nil, EPOCH))
            assert.are.equal('', age.format('', EPOCH))
        end)

        it('gives no age for text that is not a time', function()
            assert.are.equal('', age.format('yesterday', EPOCH))
            assert.are.equal('', age.format('2026-01-01', EPOCH))
            assert.are.equal('', age.format('2026-01-01T00:00:00junk', EPOCH))
            assert.are.equal('', age.format('3', EPOCH))
        end)

        it('gives no age for a time out of range', function()
            assert.are.equal('', age.format('2026-13-01T00:00:00Z', EPOCH))
            assert.are.equal('', age.format('2026-01-32T00:00:00Z', EPOCH))
            assert.are.equal('', age.format('2026-01-01T24:00:00Z', EPOCH))
            assert.are.equal('', age.format('2026-01-01T00:60:00Z', EPOCH))
            assert.are.equal('', age.format('2026-01-01T00:00:60Z', EPOCH))
        end)

        it('gives no age without the current time', function()
            assert.are.equal('', age.format(NOON, nil))
        end)

        local CASES = {
            { 0, 'now' },
            { 1, 'now' },
            { 4, 'now' },
            { 5, '5s' },
            { 42, '42s' },
            { 59, '59s' },
            { 60, '1m' },
            { 210, '3m' },
            { 3599, '59m' },
            { 3600, '1h' },
            { 7200, '2h' },
            { 86399, '23h' },
            { 86400, '1d' },
            { 4 * 86400, '4d' },
        }

        for _, case in ipairs(CASES) do
            it(
                'shows '
                    .. case[2]
                    .. ' for '
                    .. case[1]
                    .. ' seconds before now',
                function()
                    assert.are.equal(case[2], age.format(NOON, EPOCH + case[1]))
                end
            )
        end

        it('shows 0s for a time in the future', function()
            assert.are.equal('0s', age.format(NOON, EPOCH - 100))
        end)

        it('reads a fraction', function()
            assert.are.equal(
                '42s',
                age.format('2026-01-01T00:00:00.499979Z', EPOCH + 42)
            )
            assert.are.equal(
                '5s',
                age.format('2026-01-01T00:00:00.999999Z', EPOCH + 5)
            )
        end)

        it('reads a time in no zone as UTC', function()
            assert.are.equal(
                '42s',
                age.format('2026-01-01T00:00:00', EPOCH + 42)
            )
        end)

        it('reads a positive offset', function()
            assert.are.equal(
                '42s',
                age.format('2026-01-01T01:00:00+01:00', EPOCH + 42)
            )
            assert.are.equal(
                '42s',
                age.format('2026-01-01T05:30:00+05:30', EPOCH + 42)
            )
        end)

        it('reads a negative offset', function()
            assert.are.equal(
                '42s',
                age.format('2025-12-31T19:00:00-05:00', EPOCH + 42)
            )
        end)

        it('reads the time Rex reports', function()
            -- The fixture timestamp, with its six-digit fraction and offset.
            assert.are.equal(
                '42s',
                age.format('2026-11-06T14:11:45.499979+01:00', 1793970747)
            )
        end)

        it('crosses a month and a year', function()
            assert.are.equal('2d', age.format('2025-12-30T00:00:00Z', EPOCH))
            assert.are.equal('11d', age.format('2025-12-21T00:00:00Z', EPOCH))
            -- The leap day itself: 1835478000 is 2028-02-29T23:00:00Z.
            assert.are.equal(
                '1d',
                age.format('2028-02-29T23:00:00Z', 1835478000 + 86400)
            )
        end)
    end)
end)
