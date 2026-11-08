-- The text of the `g?` float: one line per Dashboard key, the key first and
-- what it does after it, in a column of its own.

local M = {}

-- The cells between the key column and the description.
M.GAP = 2

---@class rexai.HelpKey
---@field [1] string the key, as `vim.keymap.set` takes it
---@field [2] string what the key does

---@param keys rexai.HelpKey[]
---@return string[] lines in the order of `keys`; empty for no keys
function M.lines(keys)
    local widest = 0
    for _, key in ipairs(keys) do
        widest = math.max(widest, #key[1])
    end
    local lines = {}
    for _, key in ipairs(keys) do
        local pad = string.rep(' ', widest - #key[1] + M.GAP)
        lines[#lines + 1] = key[1] .. pad .. key[2]
    end
    return lines
end

return M
