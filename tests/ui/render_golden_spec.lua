-- The Dashboard text, pinned to committed files. Every case runs with a fixed
-- clock, so a golden file changes only when the layout does.
--
-- Rewrite the goldens with `REXAI_UPDATE_GOLDEN=1` and read each one by eye.
-- Without it a missing golden fails the test.

local config = require('rexai.config')
local helpers = require('tests.helpers')
local model = require('rexai.core.model')
local render = require('rexai.ui.render')
local snap = require('tests.snapshots')

local AGENTS = config.defaults.agents
-- 2026-11-07T16:15:00Z, so the ages in the goldens never move.
local NOW = 1794068100
local GOLDEN = helpers.root() .. '/tests/golden'
local UPDATE = os.getenv('REXAI_UPDATE_GOLDEN') == '1'

---@param spec table
---@return table one Session with one Window
local function session(spec)
    return snap.session({
        id = spec.id,
        label = spec.label,
        error = spec.error,
        windows = {
            snap.window({
                id = 'window:' .. spec.id:gsub('^session:', ''),
                label = spec.window_label,
                blocks = spec.blocks or {},
            }),
        },
    })
end

---@param sessions table[]
---@return rexai.ModelSession[]
local function build_model(sessions)
    return model.build(snap.snapshot(sessions), AGENTS)
end

---@type { name: string, run: fun(): rexai.ModelSession[], table }[]
local CASES = {}

-- Every committed fixture, as it comes out of the model.
for _, fixture in ipairs(helpers.fixture_names()) do
    CASES[#CASES + 1] = {
        name = fixture:gsub('%.json$', ''),
        run = function()
            return model.build(helpers.fixture(fixture), AGENTS), { now = NOW }
        end,
    }
end

CASES[#CASES + 1] = {
    name = 'empty',
    run = function()
        return {}, { now = NOW }
    end,
}

-- Every Agent status the model builds from a snapshot, reported out of order.
-- `exited` needs a second snapshot and has a case of its own.
CASES[#CASES + 1] = {
    name = 'statuses',
    run = function()
        local reported = {
            { state = 'done', label = 'docs', at = '2026-11-07T16:12:00Z' },
            { state = 'idle', label = 'idle-app', at = '2026-11-03T16:15:00Z' },
            {
                state = 'blocked',
                label = 'review',
                at = '2026-11-07T16:14:58Z',
            },
            {
                state = 'error',
                label = 'broken-build',
                at = '2026-11-07T16:14:18Z',
            },
            { label = 'quiet-app' },
            {
                state = 'working',
                label = 'refactor',
                at = '2026-11-07T15:15:00Z',
            },
        }

        local out = {}
        for index, item in ipairs(reported) do
            local block = {
                id = 'block:b' .. index,
                app = 'pi',
                title = 'work on ' .. item.label,
            }
            if item.state then
                block.state = item.state
                block.updated_at = item.at
            else
                -- No status record: the agent says nothing.
                block.argv0 = '/opt/bin/pi'
            end
            out[#out + 1] = session({
                id = 'session:s' .. index,
                label = 'session-' .. index,
                window_label = item.label,
                blocks = { snap.block(block) },
            })
        end
        return build_model(out), { now = NOW }
    end,
}

-- Two Agent blocks in one Window: the label gets the harness appended.
CASES[#CASES + 1] = {
    name = 'two-blocks',
    run = function()
        return build_model({
            session({
                id = 'session:orbit',
                label = 'orbit',
                window_label = 'release',
                blocks = {
                    snap.block({
                        id = 'block:b1',
                        app = 'claude-code',
                        state = 'blocked',
                        kind = 'permission',
                        title = 'waiting on the schema change',
                        updated_at = '2026-11-07T16:14:58Z',
                    }),
                    snap.block({
                        id = 'block:b2',
                        app = 'pi',
                        state = 'working',
                        title = 'writing the migration',
                        updated_at = '2026-11-07T15:15:00Z',
                    }),
                },
            }),
        }),
            { now = NOW }
    end,
}

-- A Block that exited while its Window stays open.
CASES[#CASES + 1] = {
    name = 'exited',
    run = function()
        local memory = model.new_memory()
        local function snapshot(block)
            return snap.snapshot({
                session({
                    id = 'session:orbit',
                    label = 'orbit',
                    window_label = 'api',
                    blocks = {
                        snap.block(vim.tbl_extend('force', {
                            id = 'block:b1',
                            title = 'refactor the parser',
                            updated_at = '2026-11-07T16:10:00Z',
                        }, block)),
                    },
                }),
            })
        end

        model.build(snapshot({ app = 'pi', state = 'working' }), AGENTS, memory)
        -- The agent ended: no status record, no agent command, exit code 3.
        return model.build(
            snapshot({ argv0 = '/bin/zsh', last_exit = { exit_code = 3 } }),
            AGENTS,
            memory
        ),
            { now = NOW }
    end,
}

CASES[#CASES + 1] = {
    name = 'session-error',
    run = function()
        return build_model({
            session({
                id = 'session:ledger',
                label = 'ledger',
                error = 'no answer from the app',
            }),
            session({
                id = 'session:orbit',
                label = 'orbit',
                window_label = 'api',
                blocks = {
                    snap.block({
                        id = 'block:b1',
                        app = 'pi',
                        state = 'done',
                        title = 'ship the fix',
                        updated_at = '2026-11-07T16:12:00Z',
                    }),
                },
            }),
        }),
            { now = NOW }
    end,
}

CASES[#CASES + 1] = {
    name = 'home',
    run = function()
        return build_model({
            session({
                id = 'session:home',
                label = 'home',
                window_label = 'dashboard',
                blocks = {
                    snap.block({
                        id = 'block:b1',
                        app = 'pi',
                        state = 'working',
                        title = 'the dashboard itself',
                        updated_at = '2026-11-07T16:14:00Z',
                    }),
                },
            }),
            session({
                id = 'session:orbit',
                label = 'orbit',
                window_label = 'api',
                blocks = {
                    snap.block({
                        id = 'block:b2',
                        app = 'claude-code',
                        state = 'error',
                        title = 'a failing test',
                        updated_at = '2026-11-07T16:14:58Z',
                    }),
                },
            }),
        }),
            { now = NOW, home_session_id = 'session:home' }
    end,
}

CASES[#CASES + 1] = {
    name = 'home-empty',
    run = function()
        return build_model({
            session({
                id = 'session:orbit',
                label = 'orbit',
                window_label = 'api',
                blocks = {
                    snap.block({
                        id = 'block:b1',
                        app = 'pi',
                        state = 'idle',
                        title = 'nothing to do',
                        updated_at = '2026-11-07T14:15:00Z',
                    }),
                },
            }),
        }),
            { now = NOW, home_session_id = 'session:home' }
    end,
}

-- A git slot, whose column is dropped when no row has one.
CASES[#CASES + 1] = {
    name = 'git',
    run = function()
        local sessions = build_model({
            session({
                id = 'session:orbit',
                label = 'orbit',
                window_label = 'api',
                blocks = {
                    snap.block({
                        id = 'block:b1',
                        app = 'pi',
                        state = 'working',
                        title = 'the parser again',
                        updated_at = '2026-11-07T16:14:00Z',
                    }),
                    snap.block({
                        id = 'block:b2',
                        app = 'claude-code',
                        state = 'done',
                        title = 'the docs',
                        updated_at = '2026-11-07T16:00:00Z',
                    }),
                },
            }),
        })
        return sessions,
            {
                now = NOW,
                git = { ['block:b1'] = '2+ 1-' },
            }
    end,
}

CASES[#CASES + 1] = {
    name = 'rex-error',
    run = function()
        return build_model({
            session({
                id = 'session:orbit',
                label = 'orbit',
                window_label = 'api',
                blocks = {
                    snap.block({
                        id = 'block:b1',
                        app = 'pi',
                        state = 'working',
                        title = 'still running',
                        updated_at = '2026-11-07T16:14:00Z',
                    }),
                },
            }),
        }),
            { now = NOW, error = 'connection refused' }
    end,
}

---@param out rexai.Render
---@return string
local function as_text(out)
    return table.concat(out.lines, '\n') .. '\n'
end

---@param out rexai.Render
---@return string
local function as_highlights(out)
    local lines = {}
    for _, span in ipairs(out.highlights) do
        lines[#lines + 1] = string.format(
            '%d:%d-%d %s',
            span.line,
            span.col_start,
            span.col_end,
            span.group
        )
    end
    if #lines == 0 then
        return ''
    end
    return table.concat(lines, '\n') .. '\n'
end

---@param name string
---@return string
local function golden_path(name)
    return GOLDEN .. '/' .. name
end

---@param path string
---@param text string
local function check(path, text)
    if UPDATE then
        vim.fn.mkdir(GOLDEN, 'p')
        local file = assert(io.open(path, 'w'))
        file:write(text)
        file:close()
        return
    end

    local file = io.open(path, 'r')
    assert.is_not_nil(
        file,
        path .. ' is missing: run the spec with REXAI_UPDATE_GOLDEN=1'
    )
    local expected = file:read('*a')
    file:close()
    assert.are.equal(expected, text)
end

describe('ui.render golden', function()
    for _, case in ipairs(CASES) do
        it('renders ' .. case.name, function()
            local sessions, opts = case.run()
            opts.now = opts.now or NOW
            local out = render.build(sessions, opts)
            check(golden_path(case.name .. '.txt'), as_text(out))
            check(golden_path(case.name .. '.hl'), as_highlights(out))
        end)
    end
end)
