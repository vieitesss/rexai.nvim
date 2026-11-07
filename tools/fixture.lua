-- Records a fixture from the live Rex. Run it with `just fixture`.
--
--   nvim -l tools/fixture.lua [output.json]
--
-- The raw capture stays in memory. Only the anonymized result is written, and
-- only after it passes the whitelist check and the leak check.

local source = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
local anonymize = dofile(root .. '/tools/anonymize.lua')

local function die(message)
    io.stderr:write('fixture: ' .. message .. '\n')
    os.exit(1)
end

if vim.fn.exepath('rex') == '' then
    die('`rex` is not on PATH')
end

local result = vim.system(
    { 'rex', 'do', root .. '/scripts/snapshot.lua', '--json' },
    { text = true }
):wait()
if result.code ~= 0 then
    die('rex do failed: ' .. (result.stderr or ''))
end

local ok, raw = pcall(
    vim.json.decode,
    result.stdout,
    { luanil = { object = true, array = true } }
)
if not ok or type(raw) ~= 'table' then
    die('rex did not return a JSON object')
end

local snapshot = anonymize.anonymize(raw)

local errors = anonymize.validate(snapshot)
if #errors > 0 then
    die(
        'anonymized snapshot is not allowed:\n  '
            .. table.concat(errors, '\n  ')
    )
end

local text = anonymize.encode(snapshot)

local home = vim.uv.os_homedir() or ''
local user = (vim.uv.os_get_passwd() or {}).username or ''
local leaks = anonymize.leaks(text, { home, user })
if #leaks > 0 then
    die('anonymized snapshot still contains ' .. table.concat(leaks, ', '))
end

local out = arg[1] or (root .. '/tests/fixtures/sample.json')
vim.fn.mkdir(vim.fs.dirname(out), 'p')
local file = assert(io.open(out, 'w'))
file:write(text)
file:close()

local blocks = 0
for _, s in ipairs(snapshot.sessions) do
    for _, w in ipairs(s.windows) do
        blocks = blocks + #w.blocks
    end
end
print(
    string.format(
        'fixture: wrote %s (%d sessions, %d blocks)',
        out,
        #snapshot.sessions,
        blocks
    )
)
