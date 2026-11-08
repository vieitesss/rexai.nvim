-- Checks the plugin against the Rex running on this machine. Run it with
-- `just smoke`; a human runs it on purpose, because CI has no Rex.
--
--   nvim --headless --noplugin -l tools/smoke.lua
--
-- It creates one throwaway Session labelled `rexai-smoke-<random>`, runs the
-- scripts the plugin runs, compares the shape of the live snapshot with every
-- committed fixture, and removes that Session by id on every exit path.
--
-- Live safety: every `rex` call carries `--autostart=false`, nothing selects
-- or focuses anything in the Rex app, no snapshot is written to disk, and no
-- label, title, path or id is printed. The one exception is the id of the
-- throwaway Session, printed only when the cleanup could not remove it.

local source = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
package.path = root
    .. '/lua/?.lua;'
    .. root
    .. '/lua/?/init.lua;'
    .. root
    .. '/?.lua;'
    .. package.path

local anonymize = dofile(root .. '/tools/anonymize.lua')
local shape = dofile(root .. '/tools/shape.lua')
local config = require('rexai.config')
local model = require('rexai.core.model')
local rex_backend = require('rexai.backend.rex')
local helpers = require('tests.helpers')

local TIMEOUT_MS = 10000
local LABEL_PREFIX = 'rexai-smoke-'
local OK_PREFIX = 'smoke: ok ('

local bin = config.get().rex_bin
local checks = 0
local notes = {}
local live_only, fixture_only = {}, {}

-- The Session this run created, kept the moment home.lua names it.
local session_id
-- The Sessions the server listed before it existed.
local sessions_before
-- The directory the throwaway Block starts in.
local workdir

---@param passed boolean
---@param what string which check failed
local function check(passed, what)
    if not passed then
        error(what, 0)
    end
    checks = checks + 1
end

---@param text string
local function note(text)
    notes[#notes + 1] = text
end

-- Runs `rex --autostart=false <argv>`. The flag is part of every call, so a
-- missing one cannot slip in; with it, smoke never starts a server.
---@param argv string[]
---@return vim.SystemCompleted
local function rex(argv)
    local call = { bin, '--autostart=false' }
    vim.list_extend(call, argv)
    return vim.system(call, { text = true, timeout = TIMEOUT_MS }):wait()
end

---@param text string
---@return any
local function decode(text)
    local ok, value = pcall(
        vim.json.decode,
        text,
        { luanil = { object = true, array = true } }
    )
    if ok then
        return value
    end
    return nil
end

-- The Sessions Rex lists. Only their number is ever printed.
---@return table[]
local function listed_sessions()
    local result = rex({ 'ls', '--json' })
    if result.code ~= 0 then
        error('`rex ls` failed (exit ' .. result.code .. ')', 0)
    end
    local listed = decode(result.stdout)
    if type(listed) ~= 'table' or type(listed.sessions) ~= 'table' then
        error('`rex ls` printed no Session list', 0)
    end
    return listed.sessions
end

-- Rex answers, and the binary is where the plugin looks for it. Rex's own
-- text stays out of the failure: it may name a Session or a path.
local function preflight()
    check(vim.fn.exepath(bin) ~= '', '`' .. bin .. '` is not on PATH')

    local result = rex({ 'whoami', '--json' })
    check(
        result.code == 0,
        '`rex whoami` failed (exit '
            .. result.code
            .. '): is a Rex server running?'
    )
    check(decode(result.stdout) ~= nil, '`rex whoami` printed no JSON')
end

-- Creates the throwaway Session through the script the plugin runs.
---@return table the reply of home.lua
local function create()
    workdir = vim.fn.tempname()
    vim.fn.mkdir(workdir, 'p')
    check(vim.fn.isdirectory(workdir) == 1, 'cannot create a directory')

    local label = LABEL_PREFIX
        .. string.format('%x', vim.uv.hrtime() % 0x100000000)
    local result = rex({
        'do',
        root .. '/scripts/home.lua',
        'name=' .. label,
        'cwd=' .. workdir,
        '--json',
    })
    check(
        result.code == 0,
        '`rex do home.lua` failed (exit ' .. result.code .. ')'
    )

    local home = decode(result.stdout)
    -- The id is kept before anything else can fail: it is what the cleanup
    -- removes.
    if type(home) == 'table' and type(home.session_id) == 'string' then
        session_id = home.session_id
    end

    check(
        type(session_id) == 'string' and session_id ~= '',
        'home.lua returned no session_id'
    )
    check(
        type(home) == 'table' and type(home.window_id) == 'string',
        'home.lua returned no window_id'
    )
    check(
        type(home) == 'table' and type(home.block_id) == 'string',
        'home.lua returned no block_id'
    )
    check(
        type(home) == 'table' and home.created == 'session',
        'home.lua did not create the Session'
    )
    return home
end

-- Takes a snapshot with the Backend the Dashboard uses, so the Backend is
-- proven against the live Rex too.
---@return table
local function take_snapshot()
    local backend = rex_backend.new({ bin = bin, timeout_ms = TIMEOUT_MS })
    local answer, failure, called = nil, nil, false
    backend.snapshot(function(err, value)
        called = true
        failure = err
        answer = value
    end)

    vim.wait(TIMEOUT_MS + 5000, function()
        return called
    end, 25)
    check(called, 'the rex Backend returned no snapshot')
    check(failure == nil, 'the rex Backend failed to read a snapshot')
    check(type(answer) == 'table', 'the rex Backend returned no snapshot')
    ---@cast answer table
    return answer
end

-- Whether the snapshot holds that Session, its Window and its Block.
---@param snapshot table
---@param home table
---@return boolean
local function holds(snapshot, home)
    for _, session in ipairs(snapshot.sessions or {}) do
        if session.id == home.session_id then
            for _, window in ipairs(session.windows or {}) do
                if window.id == home.window_id then
                    for _, block in ipairs(window.blocks or {}) do
                        if block.id == home.block_id then
                            return true
                        end
                    end
                end
            end
        end
    end
    return false
end

-- The anonymized snapshot, checked against the whitelist and for leaks. The
-- text never reaches the disk.
---@param snapshot table
---@return table
local function clean(snapshot)
    local anonymized = anonymize.anonymize(snapshot)

    local errors = anonymize.validate(anonymized)
    check(
        #errors == 0,
        'the anonymized snapshot is not allowed: ' .. tostring(errors[1])
    )

    local passwd = vim.uv.os_get_passwd() or {}
    local leaks = anonymize.leaks(anonymize.encode(anonymized), {
        vim.uv.os_homedir() or '',
        passwd.username or '',
    })
    check(
        #leaks == 0,
        'the anonymized snapshot leaks the home directory or the username'
    )

    return anonymized
end

---@param name string
---@param diff rexai.ShapeDiff
---@return string
local function describe(name, diff)
    local parts = {}
    local drift = diff.drift[1]
    if drift then
        parts[#parts + 1] = string.format(
            'type drift at %s (live %s, fixture %s)',
            drift.path,
            table.concat(drift.live, ', '),
            table.concat(drift.fixture, ', ')
        )
    end
    if diff.vanished[1] then
        parts[#parts + 1] = 'vanished key ' .. diff.vanished[1]
    end
    return 'fixture '
        .. name
        .. ': '
        .. table.concat(parts, '; ')
        .. string.format(
            ' (%d paths only live, %d only the fixture)',
            #diff.live_only,
            #diff.fixture_only
        )
end

-- Compares the live shape with every committed fixture. Paths only one side
-- has are notes, never failures.
---@param anonymized table
---@return integer how many fixtures were compared
local function compare(anonymized)
    local live = shape.of(anonymized)
    local names = helpers.fixture_names()
    check(#names > 0, 'there is no committed fixture to compare with')

    for _, name in ipairs(names) do
        local diff = shape.compare(live, shape.of(helpers.fixture(name)))
        check(diff.ok, describe(name, diff))
        for _, path in ipairs(diff.live_only) do
            live_only[path] = true
        end
        for _, path in ipairs(diff.fixture_only) do
            fixture_only[path] = true
        end
    end

    return #names
end

-- Removes the throwaway Session by id and proves it is gone. Only this runs
-- after a failed check, so the id it names is the only one ever printed.
local function cleanup()
    local result = rex({ 'kill', session_id })
    if result.code ~= 0 then
        error(
            string.format(
                '`rex kill` failed (exit %d): remove the Session with '
                    .. '`rex kill %s`',
                result.code,
                session_id
            ),
            0
        )
    end

    local asked, listed = pcall(listed_sessions)
    if not asked then
        error(
            '`rex kill` ran but could not be checked: make sure it is gone '
                .. 'with `rex kill '
                .. session_id
                .. '`',
            0
        )
    end

    for _, session in ipairs(listed) do
        if session.session_id == session_id then
            error(
                'Rex still lists the throwaway Session: remove it with '
                    .. '`rex kill '
                    .. session_id
                    .. '`',
                0
            )
        end
    end
    checks = checks + 1

    -- Another Session of the user's own may have come or gone meanwhile, so a
    -- count that moved is a note: the id above is the proof.
    if #listed ~= sessions_before then
        note(
            string.format(
                'the Session count is %d, was %d',
                #listed,
                sessions_before
            )
        )
    end
end

---@param set table<string, boolean>
---@return integer
local function count(set)
    local n = 0
    for _ in pairs(set) do
        n = n + 1
    end
    return n
end

local function main()
    preflight()
    sessions_before = #listed_sessions()
    local home = create()
    local snapshot = take_snapshot()

    check(
        holds(snapshot, home),
        'the snapshot does not hold the Session, Window and Block it created'
    )

    local built, sessions =
        pcall(model.build, snapshot, config.get().agents, model.new_memory())
    check(
        built and type(sessions) == 'table',
        'the Dashboard model rejected the snapshot'
    )

    return compare(clean(snapshot))
end

local ok, result = pcall(main)

local cleaned, cleanup_error = true, nil
if session_id then
    cleaned, cleanup_error = pcall(cleanup)
end

if workdir then
    vim.fn.delete(workdir, 'rf')
end

local failed = {}
if not ok then
    failed[#failed + 1] = tostring(result)
end
if not cleaned then
    failed[#failed + 1] = tostring(cleanup_error)
end

if #failed > 0 then
    for _, line in ipairs(failed) do
        io.stderr:write('smoke: ', line, '\n')
    end
    os.exit(1)
end

local fixtures = result

-- The summary carries counts only: never a label, a path or an id.
print(
    string.format(
        '%s%d checks, %d %s, %d live-only paths, %d fixture-only paths%s)',
        OK_PREFIX,
        checks,
        fixtures,
        fixtures == 1 and 'fixture' or 'fixtures',
        count(live_only),
        count(fixture_only),
        #notes > 0 and (', ' .. table.concat(notes, '; ')) or ''
    )
)
