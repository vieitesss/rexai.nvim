-- The text of the `K` float: what is known about one Agent row, then the last
-- lines of its Block's screen. Every value here is invented.

local peek = require('rexai.core.peek')

-- One Agent row, as `core.model` builds it.
local ROW = {
    session_id = 'session:s1',
    window_id = 'window:w1',
    block_id = 'block:b1',
    harness = 'pi',
    label = 'api pi',
    status = 'done',
    msg = 'the tests pass',
    updated_at = '2026-11-07T16:12:00Z',
    title = 'the docs',
    cwd = '/work/orbit',
}

-- The rule spans the widest line above it, in characters.
local function rule(characters)
    return string.rep(peek.RULE, characters)
end

---@param changes table|nil
---@return table
local function row(changes)
    local out = vim.deepcopy(ROW)
    for key, value in pairs(changes or {}) do
        out[key] = value
    end
    return out
end

describe('core.peek', function()
    describe('the header', function()
        it('holds the label, the harness and the status', function()
            local out = peek.lines({ row = row({ msg = '' }) })

            assert.are.equal('api pi · pi · done', out[1])
        end)

        it('writes the status the way the Dashboard writes it', function()
            local out = peek.lines({ row = row({ status = 'needs_input' }) })

            assert.are.equal('api pi · pi · needs input', out[1])
        end)

        it('adds the exit code of an Exited agent', function()
            local out =
                peek.lines({ row = row({ status = 'exited', exit_code = 3 }) })

            assert.are.equal('api pi · pi · exited 3', out[1])
        end)

        it('leaves out a part the row does not have', function()
            local out = peek.lines({ row = row({ harness = '', msg = nil }) })

            assert.are.equal('api pi · done', out[1])
        end)

        it('keeps a row with control characters on one line', function()
            local out = peek.lines({
                row = row({ msg = 'one\rtwo\nthree' }),
            })

            assert.are.equal('one two three', out[2])
        end)

        it('drops the escape sequences of a message', function()
            local out = peek.lines({ row = row({ msg = '\27[1mbold\27[0m' }) })

            assert.are.equal('bold', out[2])
        end)
    end)

    describe('the description', function()
        it('is the message of the row when it has one', function()
            local out = peek.lines({ row = ROW })

            assert.are.equal('the tests pass', out[2])
        end)

        it('is left out when the row says nothing', function()
            local out = peek.lines({ row = row({ msg = '' }) })

            assert.is_nil(out[2]:find('the tests pass', 1, true))
        end)

        it('holds the path and then the git slot', function()
            local out = peek.lines({
                row = ROW,
                path = '/work/orbit',
                git = 'orbit · main ↑1 ●2',
            })

            assert.are.equal('the tests pass', out[2])
            assert.are.equal('/work/orbit', out[3])
            assert.are.equal('orbit · main ↑1 ●2', out[4])
            assert.are.equal(rule(18), out[5])
        end)

        it('holds the path alone when git knows nothing', function()
            local out = peek.lines({ row = row({ msg = '' }), path = '/tmp' })

            assert.are.equal('/tmp', out[2])
            assert.are.equal(rule(18), out[3])
            assert.are.equal(3, #out)
        end)
    end)

    describe('the separator', function()
        it('comes after the description and before the screen', function()
            local out = peek.lines({
                row = row({ msg = '' }),
                screen = 'first line',
            })

            assert.are.equal(rule(18), out[2])
            assert.are.equal('first line', out[3])
        end)

        it('is the whole float when there is no screen', function()
            local out = peek.lines({ row = row({ msg = '' }) })

            assert.are.same({ 'api pi · pi · done', rule(18) }, out)
        end)

        it('is a blank screen with a newline at the end too', function()
            assert.are.same(
                { 'api pi · pi · done', rule(18) },
                peek.lines({ row = row({ msg = '' }), screen = '\n' })
            )
        end)
    end)

    describe('the screen', function()
        it('keeps its lines, in order', function()
            local out = peek.lines({
                row = row({ msg = '' }),
                screen = 'first line\nsecond line',
            })

            assert.are.equal('first line', out[3])
            assert.are.equal('second line', out[4])
            assert.are.equal(4, #out)
        end)

        it('drops the newline `rex capture` ends its output with', function()
            local out = peek.lines({
                row = row({ msg = '' }),
                screen = 'only line\n',
            })

            assert.are.equal('only line', out[3])
            assert.are.equal(3, #out)
        end)

        it('drops whole escape sequences', function()
            local out = peek.lines({
                row = row({ msg = '' }),
                screen = '\27[32mgreen\27[0m \27]0;a title\7bold',
            })

            assert.are.equal('green bold', out[3])
        end)

        it('drops an escape sequence ended by a string terminator', function()
            local out = peek.lines({
                row = row({ msg = '' }),
                screen = '\27]8;;http://example.test\27\\link\27]8;;\27\\',
            })

            assert.are.equal('link', out[3])
        end)

        it('drops the control characters and the carriage returns', function()
            local out = peek.lines({
                row = row({ msg = '' }),
                screen = 'a\rb\27[2K\7c\127d',
            })

            assert.are.equal('abcd', out[3])
        end)

        it('turns a tab into spaces and keeps the newlines', function()
            local out = peek.lines({
                row = row({ msg = '' }),
                screen = 'a\tb\nc',
            })

            assert.are.equal('a    b', out[3])
            assert.are.equal('c', out[4])
        end)

        it('holds no control character at all', function()
            local out = peek.lines({
                row = row({ msg = 'a\27[1mb\rc' }),
                path = '/work/orbit',
                git = 'orbit · main',
                screen = '\27[31mred\27[0m\r\n\t2 lines\7',
            })

            for _, line in ipairs(out) do
                assert.is_nil(
                    line:find('%c'),
                    'control character in ' .. vim.inspect(line)
                )
            end
        end)
    end)
end)
