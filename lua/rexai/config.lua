-- User options. One flat table, merged over the plain data in
-- `rexai.core.defaults`.
--
-- A list replaces the default list instead of growing it: `agents.apps` set to
-- `{ 'my-agent' }` matches that app and no other.

local core_defaults = require('rexai.core.defaults')

local M = {}

---@class rexai.Glyphs one single-width character per Agent status, no font
---@field needs_input string
---@field error string
---@field done string
---@field working string
---@field unreported string
---@field idle string
---@field exited string

---@class rexai.Config
---@field refresh_ms integer how often the Dashboard asks Rex for a snapshot
---@field git_refresh_ms integer how old a git result may be before it is asked again
---@field show_exited boolean list the Agent blocks whose agent has ended
---@field title_width integer widest title, in display cells, `…` included
---@field rex_bin string the `rex` executable the Backend runs
---@field peek_lines integer lines `peek` keeps from the end of a Block
---@field glyphs rexai.Glyphs the glyph of every Agent status
---@field agents rexai.Agents what makes a Block an Agent block

---@type rexai.Config
M.defaults = {
    refresh_ms = 1000,
    git_refresh_ms = 5000,
    show_exited = true,
    title_width = 40,
    rex_bin = 'rex',
    peek_lines = 20,
    glyphs = {
        needs_input = '!',
        error = 'x',
        done = '+',
        working = '*',
        unreported = '?',
        idle = '-',
        exited = '.',
    },
    agents = vim.deepcopy(core_defaults.agents),
}

---@type rexai.Config|nil
local config

-- Merges `opts` over the defaults. With no options, or with an empty table, it
-- goes back to the defaults.
---@param opts table|nil
---@return rexai.Config
function M.setup(opts)
    config = vim.tbl_deep_extend('force', vim.deepcopy(M.defaults), opts or {})
    return config
end

-- The merged options, or the defaults when `setup` was never called.
---@return rexai.Config
function M.get()
    return config or M.defaults
end

return M
