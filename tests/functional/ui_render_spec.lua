local config = require('rexai.config')
local highlights = require('rexai.ui.highlights')
local model = require('rexai.core.model')
local render = require('rexai.ui.render')
local snap = require('tests.snapshots')
local status = require('rexai.core.status')

-- 2026-11-07T16:15:00Z. The age of a row is measured against this.
local NOW = 1794068100

local GLYPHS = config.defaults.glyphs

---@param spec table
---@return table a row of the model
local function row(spec)
    return {
        session_id = spec.session_id or 'session:s1',
        window_id = spec.window_id or 'window:w1',
        block_id = spec.block_id or 'block:b1',
        harness = spec.harness or 'pi',
        label = spec.label or 'pi 2c3d',
        status = spec.status or 'idle',
        kind = spec.kind,
        msg = spec.msg,
        updated_at = spec.updated_at,
        title = spec.title,
        exit_code = spec.exit_code,
    }
end

---@param spec table
---@return table a Session of the model
local function session(spec)
    local rows = spec.rows or {}
    local names = {}
    for _, item in ipairs(rows) do
        names[#names + 1] = item.status
    end
    return {
        id = spec.id or 'session:s1',
        label = spec.label or 'orbit',
        status = spec.status or status.rollup(names),
        error = spec.error,
        rows = rows,
    }
end

---@return rexai.Render
local function build(sessions, opts)
    opts = opts or {}
    opts.now = opts.now or NOW
    return render.build(sessions, opts)
end

---@param out rexai.Render
---@param span rexai.Highlight
---@return string
local function text_of(out, span)
    return out.lines[span.line]:sub(span.col_start + 1, span.col_end)
end

---@param out rexai.Render
---@param group string
---@param text string|nil
---@return rexai.Highlight|nil
local function find(out, group, text)
    for _, span in ipairs(out.highlights) do
        if
            span.group == group and (text == nil or text_of(out, span) == text)
        then
            return span
        end
    end
end

---@param out rexai.Render
---@param line integer
---@return rexai.Highlight[]
local function spans_on(out, line)
    local list = {}
    for _, span in ipairs(out.highlights) do
        if span.line == line then
            list[#list + 1] = span
        end
    end
    return list
end

---@param out rexai.Render
---@param line integer
---@return rexai.Highlight|nil the status span, last on its line
local function row_status(out, line)
    local spans = spans_on(out, line)
    return spans[#spans]
end

---@param out rexai.Render
---@param kind string
---@return rexai.RenderTarget[] in line order
local function targets_of(out, kind)
    local list = {}
    for line = 1, #out.lines do
        local target = out.targets[line]
        if target and target.kind == kind then
            list[#list + 1] = target
        end
    end
    return list
end

---@param out rexai.Render
---@return string
local function labels_of(out)
    local list = {}
    for _, target in ipairs(targets_of(out, 'session')) do
        list[#list + 1] = target.session_id
    end
    return table.concat(list, ' ')
end

describe('ui.highlights', function()
    describe('group', function()
        it('names the group of every Agent status', function()
            for _, name in ipairs(status.ORDER) do
                assert.are.equal(
                    'Rexai'
                        .. name:gsub('_(%l)', function(letter)
                            return letter:upper()
                        end):gsub('^%l', string.upper),
                    highlights.group(name)
                )
            end
        end)

        it('names no group for a status it does not know', function()
            assert.is_nil(highlights.group('nonsense'))
            assert.is_nil(highlights.group(nil))
        end)
    end)

    describe('define', function()
        it('links every group to its default', function()
            highlights.define()
            local links = {
                RexaiNeedsInput = 'DiagnosticWarn',
                RexaiError = 'DiagnosticError',
                RexaiDone = 'DiagnosticOk',
                RexaiWorking = 'DiagnosticInfo',
                RexaiUnreported = 'Comment',
                RexaiIdle = 'Comment',
                RexaiExited = 'Comment',
                RexaiHeader = 'Title',
                RexaiDim = 'Comment',
            }
            for name, link in pairs(links) do
                assert.are.equal(
                    link,
                    vim.api.nvim_get_hl(0, { name = name }).link,
                    name
                )
            end
        end)
    end)
end)

describe('ui.render', function()
    before_each(function()
        config.setup()
    end)

    describe('build', function()
        it('gives the empty state for no Sessions', function()
            local out = build({})
            assert.are.same({ 'No Agent blocks found.' }, out.lines)
            assert.are.same({}, out.targets)

            local span = assert(find(out, 'RexaiDim'))
            assert.are.equal(1, span.line)
            assert.are.equal(0, span.col_start)
            assert.are.equal(#out.lines[1], span.col_end)
        end)

        it('renders the model of a snapshot', function()
            local sessions = model.build(
                snap.single({
                    id = 'block:b1',
                    app = 'claude-code',
                    state = 'working',
                    title = 'chasing a bug',
                }, 'api'),
                config.defaults.agents
            )
            local out = build(sessions)
            assert.are.equal(2, #out.lines)
            assert.are.equal('* session', out.lines[1])
            assert.is_truthy(out.lines[2]:find('api', 1, true))
            assert.are.equal('row', out.targets[2].kind)
            assert.are.equal('block:b1', out.targets[2].block_id)
        end)

        it('adds an empty header for a Home session the model lacks', function()
            local out = build({}, { home_session_id = 'session:home' })
            assert.are.same({ '  session:home (home)' }, out.lines)

            local target = assert(out.targets[1])
            assert.are.same(
                { kind = 'session', session_id = 'session:home', home = true },
                target
            )

            local label = assert(find(out, 'RexaiHeader', 'session:home'))
            assert.are.equal(2, label.col_start)
            local marker = assert(find(out, 'RexaiDim', '(home)'))
            assert.are.equal(#out.lines[1] - #'(home)', marker.col_start)

            -- No status, so the glyph slot is blank and carries no group.
            assert.is_nil(find(out, assert(highlights.group('idle'))))
        end)

        it(
            'names a Home session the model lacks with the label given',
            function()
                local out = build({}, {
                    home_session_id = 'session:home',
                    home_label = 'landing',
                })
                assert.are.same({ '  landing (home)' }, out.lines)
                assert.is_truthy(find(out, 'RexaiHeader', 'landing'))
            end
        )

        it(
            'keeps the id of a Home session that has a label in the model',
            function()
                local sessions = {
                    session({ id = 'session:home', label = 'orbit' }),
                }
                local out = build(sessions, {
                    home_session_id = 'session:home',
                    home_label = 'landing',
                })
                assert.are.same({ '  orbit (home)' }, out.lines)
            end
        )

        it('marks the Home session when the model has it', function()
            local sessions = {
                session({
                    id = 'session:home',
                    label = 'orbit',
                    rows = {
                        row({ status = 'idle' }),
                    },
                }),
            }
            local out = build(sessions, { home_session_id = 'session:home' })
            assert.are.equal('- orbit (home)', out.lines[1])
        end)

        it('keeps the Home session when it has no rows', function()
            local sessions = {
                session({ id = 'session:home', label = 'orbit' }),
            }
            local out = build(sessions, { home_session_id = 'session:home' })
            assert.are.same({ '  orbit (home)' }, out.lines)
        end)

        it('drops a Session with no rows and no error', function()
            local sessions = { session({ id = 'session:s2', rows = {} }) }
            assert.are.same({ 'No Agent blocks found.' }, build(sessions).lines)
        end)

        it(
            'sorts Sessions by Agent status, ties as Rex reported them',
            function()
                local sessions = {
                    session({
                        id = 'session:done1',
                        rows = { row({ status = 'done' }) },
                    }),
                    session({
                        id = 'session:error',
                        status = nil,
                        error = 'timeout',
                        rows = {},
                    }),
                    session({
                        id = 'session:needs',
                        rows = { row({ status = 'needs_input' }) },
                    }),
                    session({
                        id = 'session:done2',
                        rows = { row({ status = 'done' }) },
                    }),
                }
                local out = build(sessions)
                assert.are.equal(
                    'session:needs session:done1 session:done2 session:error',
                    labels_of(out)
                )
            end
        )

        it('sorts rows by Agent status, ties as Rex reported them', function()
            local sessions = {
                session({
                    rows = {
                        row({ block_id = 'block:idle', status = 'idle' }),
                        row({ block_id = 'block:work', status = 'working' }),
                        row({ block_id = 'block:ask', status = 'needs_input' }),
                        row({ block_id = 'block:work2', status = 'working' }),
                    },
                }),
            }
            local ids = {}
            for _, target in ipairs(targets_of(build(sessions), 'row')) do
                ids[#ids + 1] = target.block_id
            end
            assert.are.same(
                { 'block:ask', 'block:work', 'block:work2', 'block:idle' },
                ids
            )
        end)

        it('shows exited rows by default', function()
            local sessions = {
                session({
                    rows = {
                        row({ block_id = 'block:a', status = 'idle' }),
                        row({ block_id = 'block:b', status = 'exited' }),
                    },
                }),
            }
            assert.are.equal(3, #build(sessions).lines)
        end)

        it('hides exited rows when show_exited is false', function()
            local sessions = {
                session({
                    status = 'done',
                    rows = {
                        row({ block_id = 'block:a', status = 'idle' }),
                        row({ block_id = 'block:b', status = 'exited' }),
                    },
                }),
            }
            local out = build(sessions, { show_exited = false })
            assert.are.equal(2, #out.lines)
            assert.are.equal('+ orbit', out.lines[1])
            assert.are.same({ 'block:a' }, {
                targets_of(out, 'row')[1].block_id,
            })
            -- The rollup is the Session's, not the visible rows' one.
            assert.are.equal('+', out.lines[1]:sub(1, 1))
        end)

        it('keeps the header when every row is hidden', function()
            local sessions = {
                session({ rows = { row({ status = 'exited' }) } }),
            }
            local out = build(sessions, { show_exited = false })
            assert.are.same({ '. orbit' }, out.lines)
            assert.are.equal(1, #targets_of(out, 'session'))
            assert.are.same({}, targets_of(out, 'row'))
        end)

        it('gives a target for every header and row', function()
            local sessions = {
                session({
                    id = 'session:s1',
                    rows = {
                        row({ window_id = 'window:w1', block_id = 'block:b1' }),
                    },
                }),
            }
            local out = build(sessions)
            assert.are.same(
                { kind = 'session', session_id = 'session:s1' },
                out.targets[1]
            )
            assert.are.same({
                kind = 'row',
                session_id = 'session:s1',
                window_id = 'window:w1',
                block_id = 'block:b1',
            }, out.targets[2])
        end)

        it('says why a Session could not be read', function()
            local sessions = {
                session({ id = 'session:s1', error = 'timeout', rows = {} }),
            }
            local out = build(sessions)
            assert.are.same(
                { '  orbit', '  could not read: timeout' },
                out.lines
            )
            local span = assert(find(out, 'RexaiError'))
            assert.are.equal(2, span.line)
            assert.are.equal(0, span.col_start)
            assert.are.equal(#out.lines[2], span.col_end)
        end)

        it('puts a top-level error first', function()
            local sessions = {
                session({ id = 'session:s1', rows = { row({}) } }),
            }
            local out = build(sessions, { error = 'socket closed' })
            assert.are.equal('Rex unreadable: socket closed', out.lines[1])
            local span = assert(find(out, 'RexaiError'))
            assert.are.equal(1, span.line)
            assert.are.equal(0, span.col_start)
            assert.are.equal(#out.lines[1], span.col_end)
            assert.are.equal(3, #out.lines)
            assert.are.equal('session', out.targets[2].kind)
        end)

        it('keeps a one-line error one line', function()
            local sessions = { session({ error = 'bad\nread', rows = {} }) }
            local out = build(sessions, { error = 'a\nb' })
            assert.are.equal('Rex unreadable: a b', out.lines[1])
            assert.are.equal('  could not read: bad read', out.lines[3])
        end)

        it('shows no empty state beside an error', function()
            assert.are.same(
                { 'Rex unreadable: socket closed' },
                build({}, {
                    error = 'socket closed',
                }).lines
            )
        end)

        it('separates Sessions with a blank line', function()
            local sessions = {
                session({ id = 'session:a', rows = { row({}) } }),
                session({ id = 'session:b', rows = { row({}) } }),
            }
            local out = build(sessions)
            assert.are.equal(5, #out.lines)
            assert.are.equal('', out.lines[3])
            assert.is_nil(out.targets[3])
            assert.are.equal('session:a session:b', labels_of(out))
        end)

        it('shows glyph, status and age of a row', function()
            local sessions = {
                session({
                    rows = {
                        row({
                            status = 'needs_input',
                            updated_at = '2026-11-07T16:14:18Z',
                        }),
                    },
                }),
            }
            local out = build(sessions)
            local spans = spans_on(out, 2)
            assert.are.equal('!', text_of(out, spans[1]))
            assert.are.equal('RexaiNeedsInput', spans[1].group)
            local status_span = assert(row_status(out, 2))
            assert.are.equal('needs input', text_of(out, status_span))
            assert.are.equal('RexaiNeedsInput', status_span.group)
            assert.are.equal(
                'needs input 42s',
                out.lines[2]:sub(status_span.col_start + 1)
            )
        end)

        it('shows the exit code of an exited row', function()
            local function status_of(exit_code)
                local sessions = {
                    session({
                        rows = {
                            row({
                                status = 'exited',
                                exit_code = exit_code,
                            }),
                        },
                    }),
                }
                local out = build(sessions)
                local span = assert(row_status(out, 2))
                assert.are.equal('RexaiExited', span.group)
                return text_of(out, span)
            end
            assert.are.equal('exited 3', status_of(3))
            assert.are.equal('exited 0', status_of(0))
            assert.are.equal('exited', status_of(nil))
        end)

        it('shows no age without a time', function()
            local sessions = { session({ rows = { row({}) } }) }
            local out = build(sessions)
            assert.is_nil(out.lines[2]:find(' $'))
            local span = assert(find(out, 'RexaiIdle', 'idle'))
            assert.are.equal(#out.lines[2], span.col_end)
        end)

        it('shows now for a fresh status', function()
            local sessions = {
                session({
                    rows = {
                        row({
                            status = 'done',
                            updated_at = '2026-11-07T16:14:58Z',
                        }),
                    },
                }),
            }
            assert.are.equal(
                'done now',
                build(sessions).lines[2]:match('%S+ %S+$')
            )
        end)

        it('sanitises a title', function()
            local sessions = {
                session({
                    rows = {
                        row({ title = '  fix\tthe\n\nparser\1  now  ' }),
                    },
                }),
            }
            local out = build(sessions)
            local span = assert(find(out, 'RexaiDim'))
            assert.are.equal('fix the parser now', text_of(out, span))
        end)

        it('truncates a title to title_width', function()
            local sessions = {
                session({ rows = { row({ title = 'abcdefghijklmnop' }) } }),
            }
            local out = build(sessions, { title_width = 10 })
            local span = assert(find(out, 'RexaiDim'))
            assert.are.equal('abcdefghi…', text_of(out, span))
        end)

        it('truncates a title by display cells', function()
            local sessions = {
                session({ rows = { row({ title = 'ab中日defghij' }) } }),
            }
            local out = build(sessions, { title_width = 7 })
            local span = assert(find(out, 'RexaiDim'))
            assert.are.equal('ab中日…', text_of(out, span))
            assert.are.equal(7, vim.api.nvim_strwidth(text_of(out, span)))
        end)

        it('keeps a short title shorter than its column', function()
            local sessions = {
                session({
                    rows = {
                        row({ block_id = 'block:a', title = 'ab' }),
                        row({ block_id = 'block:b', title = 'abcdefghij' }),
                    },
                }),
            }
            local out = build(sessions)
            assert.are.equal(
                'ab',
                text_of(out, assert(find(out, 'RexaiDim', 'ab')))
            )
        end)

        it('pads every row to the widest value of a column', function()
            local sessions = {
                session({
                    rows = {
                        row({ block_id = 'block:a', label = 'pi', title = 'x' }),
                        row({
                            block_id = 'block:b',
                            label = 'long-label',
                            title = 'y',
                        }),
                    },
                }),
            }
            local out = build(sessions)
            local first = assert(find(out, 'RexaiDim', 'x'))
            local second = assert(find(out, 'RexaiDim', 'y'))
            assert.are.equal(first.col_start, second.col_start)
        end)

        it('counts a column in display cells', function()
            local sessions = {
                session({
                    rows = {
                        row({ block_id = 'block:a', label = 'pi', title = 'x' }),
                        row({
                            block_id = 'block:b',
                            label = '中中',
                            title = 'y',
                        }),
                    },
                }),
            }
            local out = build(sessions)
            local first = assert(find(out, 'RexaiDim', 'x'))
            local second = assert(find(out, 'RexaiDim', 'y'))
            assert.are.equal(
                vim.api.nvim_strwidth(out.lines[2]:sub(1, first.col_start)),
                vim.api.nvim_strwidth(out.lines[3]:sub(1, second.col_start))
            )
        end)

        it('keeps a blank git slot at its width', function()
            local sessions = {
                session({
                    rows = {
                        row({ block_id = 'block:a', title = 'x' }),
                        row({ block_id = 'block:b', title = 'y' }),
                    },
                }),
            }
            local without = build(sessions)
            local with = build(sessions, { git = { ['block:a'] = 'main*' } })

            local first = assert(find(with, 'RexaiDim', 'x'))
            local second = assert(find(with, 'RexaiDim', 'y'))
            assert.are.equal(first.col_start, second.col_start)
            assert.is_true(
                first.col_start
                    > assert(find(without, 'RexaiDim', 'x')).col_start
            )
            assert.is_nil(with.lines[3]:find('main', 1, true))
            assert.is_truthy(with.lines[2]:find('main*', 1, true))
        end)

        it('uses the configured glyphs', function()
            local sessions = {
                session({
                    rows = {
                        row({ block_id = 'block:a', status = 'idle' }),
                        row({ block_id = 'block:b', status = 'working' }),
                    },
                    status = 'working',
                }),
            }
            local out = build(sessions, { glyphs = { working = '>' } })
            assert.is_truthy(find(out, 'RexaiWorking', '>'))
            assert.is_truthy(find(out, 'RexaiIdle', GLYPHS.idle))
        end)

        it('points every span into its line', function()
            local sessions = {
                session({
                    id = 'session:s1',
                    rows = {
                        row({
                            status = 'needs_input',
                            title = 'a title',
                            updated_at = '2026-11-07T16:14:58Z',
                        }),
                        row({
                            block_id = 'block:b',
                            status = 'exited',
                            exit_code = 1,
                        }),
                    },
                }),
                session({ id = 'session:s2', error = 'timeout', rows = {} }),
            }
            local out = build(sessions)
            local known = {}
            for _, name in ipairs(status.ORDER) do
                known[highlights.group(name)] = true
            end
            known.RexaiHeader = true
            known.RexaiDim = true

            assert.is_true(#out.highlights > 0)
            for _, span in ipairs(out.highlights) do
                local line = out.lines[span.line]
                assert.is_not_nil(line, 'span on a line that does not exist')
                assert.is_true(span.col_start < span.col_end, span.group)
                assert.is_true(span.col_end <= #line, span.group)
                assert.is_truthy(known[span.group], span.group)
            end
        end)
    end)
end)
