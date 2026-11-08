-- The text of the `g?` float: one line per key. Every key here is invented.

local help = require('rexai.core.help')

describe('core.help', function()
    describe('lines', function()
        it(
            'puts each description in one column after the widest key',
            function()
                local lines = help.lines({
                    { 'q', 'Close it' },
                    { '<CR>', 'Go there' },
                    { 'N', 'Start one' },
                })

                assert.are.same({
                    'q     Close it',
                    '<CR>  Go there',
                    'N     Start one',
                }, lines)
            end
        )

        it('keeps the order of the keys', function()
            local lines = help.lines({
                { 'z', 'last in the alphabet' },
                { 'a', 'first in the alphabet' },
            })

            assert.are.equal('z  last in the alphabet', lines[1])
            assert.are.equal('a  first in the alphabet', lines[2])
        end)

        it('gives no line for no key', function()
            assert.are.same({}, help.lines({}))
        end)
    end)
end)
