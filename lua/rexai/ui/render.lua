-- The Dashboard text: the model's Sessions in, lines, highlight spans and
-- line targets out. No buffer, window, keymap or timer lives here, so the
-- whole layout can be checked without Neovim's UI.

local age = require('rexai.core.age')
local config = require('rexai.config')
local highlights = require('rexai.ui.highlights')
local status = require('rexai.core.status')

local M = {}

-- A title wider than the column ends with this.
M.ELLIPSIS = '…'

---@class rexai.Highlight a span of one line
---@field line integer 1-based line number
---@field col_start integer 0-based byte offset
---@field col_end integer 0-based byte offset, end exclusive
---@field group string

---@class rexai.RenderTarget a Backend target plus what it is
---@field kind 'session'|'row'
---@field session_id string
---@field window_id string|nil the Window of a row
---@field block_id string|nil the Block of a row
---@field home boolean|nil true for the header of the Home session

---@class rexai.Render
---@field lines string[] the buffer, one entry per line
---@field highlights rexai.Highlight[]
---@field targets table<integer, rexai.RenderTarget> by line number

---@class rexai.RenderOpts
---@field now number|nil epoch seconds the ages are measured against
---@field glyphs table<string, string>|nil one glyph per Agent status
---@field show_exited boolean|nil list rows whose agent has ended
---@field title_width integer|nil widest title, in display cells
---@field home_session_id string|nil the Session that holds this Neovim
---@field home_label string|nil what Rex calls the Home session
---@field git table<string, string>|nil slot text by Block id
---@field error string|nil why Rex could not be read

---@param text string
---@return integer
local function width(text)
    return vim.api.nvim_strwidth(text)
end

---@param value any|nil
---@param fallback any
---@return any
local function pick(value, fallback)
    if value == nil then
        return fallback
    end
    return value
end

-- Fills in what the caller leaves out from the user config, so the Dashboard
-- may pass only what it knows.
---@param opts rexai.RenderOpts|nil
---@return table
local function resolve(opts)
    opts = opts or {}
    local defaults = config.get()
    return {
        now = opts.now,
        glyphs = vim.tbl_extend('force', defaults.glyphs, opts.glyphs or {}),
        show_exited = pick(opts.show_exited, defaults.show_exited),
        title_width = pick(opts.title_width, defaults.title_width),
        home_session_id = opts.home_session_id,
        home_label = opts.home_label,
        git = opts.git or {},
        error = opts.error,
    }
end

-- Control characters become a space and runs of whitespace become one, so a
-- Window label or a terminal title can never break a line.
---@param text string|nil
---@return string
local function one_line(text)
    local out = (text or ''):gsub('%c', ' '):gsub('%s+', ' ')
    return (out:gsub('^%s+', ''):gsub('%s+$', ''))
end

---@param text string
---@return string[] its UTF-8 characters
local function characters(text)
    local out = {}
    for char in text:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
        out[#out + 1] = char
    end
    return out
end

-- Cuts text to `cells` display cells, the ellipsis included.
---@param text string
---@param cells integer
---@return string
local function truncate(text, cells)
    if width(text) <= cells then
        return text
    end

    local budget = cells - width(M.ELLIPSIS)
    if budget < 0 then
        return ''
    end

    local out, used = {}, 0
    for _, char in ipairs(characters(text)) do
        local char_width = width(char)
        if used + char_width > budget then
            break
        end
        out[#out + 1] = char
        used = used + char_width
    end
    return table.concat(out) .. M.ELLIPSIS
end

-- The Agent status as a row shows it. An exited agent adds the exit code Rex
-- gave it, zero included.
---@param row rexai.Row
---@return string
local function state_of(row)
    local text = (row.status or ''):gsub('_', ' ')
    if row.status == 'exited' and row.exit_code ~= nil then
        text = text .. ' ' .. tostring(row.exit_code)
    end
    return text
end

local Builder = {}
Builder.__index = Builder

---@return table
local function builder()
    return setmetatable({ parts = {}, spans = {}, bytes = 0 }, Builder)
end

-- Adds a column: its text, padding out to `cells` display cells, and a span
-- when it has a group. A span is in bytes, while the padding counts cells.
---@param text string
---@param cells integer
---@param group string|nil
function Builder:cell(text, cells, group)
    local used = width(text)
    if group and text ~= '' then
        self.spans[#self.spans + 1] = { self.bytes, self.bytes + #text, group }
    end

    self.parts[#self.parts + 1] = text
    self.bytes = self.bytes + #text

    local padding = cells - used
    if padding > 0 then
        self.parts[#self.parts + 1] = string.rep(' ', padding)
        self.bytes = self.bytes + padding
    end
end

-- Adds text that takes only the cells it needs.
---@param text string
---@param group string|nil
function Builder:text(text, group)
    self:cell(text, width(text), group)
end

-- Adds a separator or a run of spaces.
---@param text string
function Builder:raw(text)
    self.parts[#self.parts + 1] = text
    self.bytes = self.bytes + #text
end

---@return string the line, without trailing spaces
function Builder:line()
    return (table.concat(self.parts):gsub('%s+$', ''))
end

-- Sorts a copy of `items` by rank, lowest first, and keeps the given order for
-- equal ranks, because Lua's sort is not stable.
---@param items table[]
---@param rank fun(item: table): integer|nil
---@return table[]
local function ordered(items, rank)
    local keyed = {}
    for index, item in ipairs(items) do
        keyed[#keyed + 1] = {
            item = item,
            index = index,
            rank = rank(item) or math.huge,
        }
    end
    table.sort(keyed, function(a, b)
        if a.rank ~= b.rank then
            return a.rank < b.rank
        end
        return a.index < b.index
    end)

    local out = {}
    for index, entry in ipairs(keyed) do
        out[index] = entry.item
    end
    return out
end

-- The Sessions the Dashboard lists. The Home session is always one of them,
-- with a header of its own when the model has no entry for it.
---@param sessions rexai.ModelSession[]|nil
---@param opts table
---@return rexai.ModelSession[]
local function listed(sessions, opts)
    local out, home_seen = {}, false
    for _, session in ipairs(sessions or {}) do
        local home = session.id == opts.home_session_id
        home_seen = home_seen or home
        if #session.rows > 0 or session.error or home then
            out[#out + 1] = session
        end
    end

    -- The model drops a Session with no Agent blocks, so the Home session is
    -- often missing. Rex's name for it, or its id, is all that is known then.
    if opts.home_session_id and not home_seen then
        out[#out + 1] = {
            id = opts.home_session_id,
            label = opts.home_label or opts.home_session_id,
            status = nil,
            error = nil,
            rows = {},
        }
    end

    return ordered(out, function(session)
        return status.rank(session.status)
    end)
end

---@param session rexai.ModelSession
---@param show_exited boolean
---@return rexai.Row[] the rows it shows, highest Agent status first
local function rows_of(session, show_exited)
    local rows = {}
    for _, row in ipairs(session.rows) do
        if show_exited or row.status ~= 'exited' then
            rows[#rows + 1] = row
        end
    end
    return ordered(rows, function(row)
        return status.rank(row.status)
    end)
end

---@class rexai.RenderCell the text of each column of one row
---@field row rexai.Row
---@field label string
---@field git string
---@field title string
---@field state string
---@field age string

---@param rows rexai.Row[]
---@param opts table
---@return rexai.RenderCell[]
local function cells_of(rows, opts)
    local out = {}
    for index, row in ipairs(rows) do
        out[index] = {
            row = row,
            label = one_line(row.label),
            git = one_line(opts.git[row.block_id]),
            title = truncate(one_line(row.title), opts.title_width),
            state = state_of(row),
            age = age.format(row.updated_at, opts.now),
        }
    end
    return out
end

---@param sessions rexai.ModelSession[]|nil
---@param opts rexai.RenderOpts|nil
---@return rexai.Render
function M.build(sessions, opts)
    local o = resolve(opts)
    local out = { lines = {}, highlights = {}, targets = {} }

    ---@param text string
    ---@param spans table[]|nil `{ col_start, col_end, group }`
    ---@return integer line
    local function push(text, spans)
        local number = #out.lines + 1
        out.lines[number] = text
        for _, span in ipairs(spans or {}) do
            out.highlights[#out.highlights + 1] = {
                line = number,
                col_start = span[1],
                col_end = span[2],
                group = span[3],
            }
        end
        return number
    end

    if o.error then
        local text = 'Rex unreadable: ' .. one_line(o.error)
        push(text, { { 0, #text, 'RexaiError' } })
    end

    local glyph_width = 1
    for _, glyph in pairs(o.glyphs) do
        glyph_width = math.max(glyph_width, width(glyph))
    end

    -- Every column is as wide as its widest value over all rows, so the
    -- columns line up across Sessions.
    local columns = { label = 0, git = 0, title = 0, state = 0 }
    local prepared = {}
    for index, session in ipairs(listed(sessions, o)) do
        local cells = cells_of(rows_of(session, o.show_exited), o)
        prepared[index] = { session = session, cells = cells }
        for _, cell in ipairs(cells) do
            columns.label = math.max(columns.label, width(cell.label))
            columns.git = math.max(columns.git, width(cell.git))
            columns.title = math.max(columns.title, width(cell.title))
            columns.state = math.max(columns.state, width(cell.state))
        end
    end

    for index, entry in ipairs(prepared) do
        local session = entry.session

        if index > 1 then
            push('')
        end

        local header = builder()
        header:cell(
            o.glyphs[session.status] or '',
            glyph_width,
            highlights.group(session.status)
        )
        header:raw(' ')
        header:text(one_line(session.label), 'RexaiHeader')
        if session.id == o.home_session_id then
            header:raw(' ')
            header:text('(home)', 'RexaiDim')
        end
        out.targets[push(header:line(), header.spans)] = {
            kind = 'session',
            session_id = session.id,
            -- A row of the Home session is a normal row; only its header says
            -- it is the Session that holds this Neovim.
            home = session.id == o.home_session_id or nil,
        }

        if session.error then
            local text = '  could not read: ' .. one_line(session.error)
            push(text, { { 0, #text, 'RexaiError' } })
        end

        for _, cell in ipairs(entry.cells) do
            local row = cell.row
            local group = highlights.group(row.status)
            local line = builder()
            line:raw('  ')
            line:cell(o.glyphs[row.status] or '', glyph_width, group)
            line:raw(' ')
            line:cell(cell.label, columns.label)
            line:raw('  ')
            if columns.git > 0 then
                line:cell(cell.git, columns.git)
                line:raw('  ')
            end
            line:cell(cell.title, columns.title, 'RexaiDim')
            line:raw('  ')
            line:cell(cell.state, columns.state, group)
            line:raw(' ')
            line:text(cell.age)

            out.targets[push(line:line(), line.spans)] = {
                kind = 'row',
                session_id = row.session_id,
                window_id = row.window_id,
                block_id = row.block_id,
            }
        end
    end

    if #out.lines == 0 then
        local text = 'No Agent blocks found.'
        push(text, { { 0, #text, 'RexaiDim' } })
    end

    return out
end

return M
