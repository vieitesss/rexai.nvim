-- Row labels. A row is one Agent block, named after its Window.

local M = {}

-- Rex names a new Window `Window <hex>`. That says nothing about the work, so
-- the row shows the harness and a short id instead.
M.SHORT_ID = 4

---@param window_label string|nil
---@return string|nil hex the id part of a default Window label
function M.default_id(window_label)
    return (window_label or ''):match('^Window (%x+)$')
end

-- Sets `label` on every row of one Window. Each row needs a `harness`.
--
-- - A custom Window label is used as it is, and gets the harness appended
--   when the Window holds two or more Agent blocks.
-- - A default Window label becomes the harness plus a short id.
-- - Rows that still share a label get ` #2`, ` #3`, and so on.
---@param window_label string|nil
---@param rows table[]
function M.assign(window_label, rows)
    local default_id = M.default_id(window_label)
    local custom = window_label ~= nil and window_label ~= ''
    local seen = {}

    for _, row in ipairs(rows) do
        local label
        if default_id then
            label = row.harness .. ' ' .. default_id:sub(-M.SHORT_ID)
        elseif not custom then
            label = row.harness
        elseif #rows > 1 then
            label = window_label .. ' ' .. row.harness
        else
            label = window_label
        end

        seen[label] = (seen[label] or 0) + 1
        if seen[label] > 1 then
            label = label .. ' #' .. seen[label]
        end
        row.label = label
    end
end

return M
