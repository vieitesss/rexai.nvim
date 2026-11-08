-- The text of the `K` float: what is known about one Agent row, then the last
-- lines of its Block's screen.
--
-- This module is pure. It touches neither Neovim nor Rex, so it runs in
-- Neovim's LuaJIT and in Rex's Lua 5.1.

local status = require('rexai.core.status')

local M = {}

-- Between the parts of the header.
M.SEPARATOR = ' · '

-- Above the screen.
M.RULE = '─'

-- A tab becomes this many spaces, so an indented screen line keeps its shape.
M.TAB = '    '

-- One UTF-8 character, so the rule counts characters and not bytes.
local CHARACTER = '[%z\1-\127\194-\244][\128-\191]*'

-- Drops the escape sequences a terminal writes: the colour ones (`ESC [ ...`
-- and a final byte) and the string ones (`ESC ] ...` and a bell or `ESC \`).
---@param text string
---@return string
local function without_escapes(text)
    local out = text:gsub('\27%[[0-?]*[ -/]*[@-~]', '')
    out = out:gsub('\27%][^\7\27]*\7', '')
    out = out:gsub('\27%][^\27]*\27\\', '')
    return out
end

-- What a screen line may hold: no control character but the newline, no DEL,
-- and spaces where the tabs were.
---@param text string|nil
---@return string
function M.sanitize(text)
    local out = without_escapes(tostring(text or ''))
    out = out:gsub('\t', M.TAB)
    return (out:gsub('[%z\1-\9\11-\31\127]', ''))
end

-- One line of the description. Control characters become a space and runs of
-- whitespace become one, so a message can never break the float.
---@param text string|nil
---@return string
local function one_line(text)
    local out = without_escapes(tostring(text or ''))
    out = out:gsub('%c', ' '):gsub('%s+', ' ')
    return (out:gsub('^%s+', ''):gsub('%s+$', ''))
end

---@param text string
---@return integer
local function characters(text)
    local total = 0
    for _ in text:gmatch(CHARACTER) do
        total = total + 1
    end
    return total
end

-- The lines of the Block's screen. The newline `rex capture` ends its output
-- with, and any blank line after it, add no line to the float.
---@param screen string|nil
---@return string[]
local function screen_lines(screen)
    local text = M.sanitize(screen)
    if text == '' then
        return {}
    end

    local out = {}
    for line in (text .. '\n'):gmatch('([^\n]*)\n') do
        out[#out + 1] = line
    end
    while #out > 0 and out[#out] == '' do
        table.remove(out)
    end
    return out
end

---@class rexai.PeekOpts
---@field row rexai.Row the Agent row under the cursor
---@field path string|nil the directory it stands for
---@field git string|nil the git slot as the Dashboard writes it
---@field screen string|nil the last lines of the Block's screen

---@param opts rexai.PeekOpts
---@return string[] lines the float shows
function M.lines(opts)
    local row = assert(opts.row, 'peek needs a row')

    -- A part the row or the caller does not have is left out. Every part is
    -- added on its own: a nil in a list would end `ipairs` and lose the parts
    -- after it.
    ---@param out string[]
    ---@param part string|nil
    local function add(out, part)
        local text = one_line(part)
        if text ~= '' then
            out[#out + 1] = text
        end
    end

    local header = {}
    add(header, row.label)
    add(header, row.harness)
    add(header, status.text(row))

    local out = { table.concat(header, M.SEPARATOR) }
    add(out, row.msg)
    add(out, opts.path)
    add(out, opts.git)

    -- The rule spans the widest line above it.
    local widest = 1
    for _, line in ipairs(out) do
        widest = math.max(widest, characters(line))
    end
    out[#out + 1] = string.rep(M.RULE, widest)

    for _, line in ipairs(screen_lines(opts.screen)) do
        out[#out + 1] = line
    end
    return out
end

return M
