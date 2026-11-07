-- Builders for hand-made snapshots. Every value is invented. Real Rex data
-- reaches the tests only through `just fixture`.
--
-- The result has the shape of the `scripts/snapshot.lua` output.

local M = {}

local function process(spec)
    if not (spec.argv0 or spec.cwd or spec.last_exit) then
        return nil
    end
    return {
        argv0 = spec.argv0,
        cwd = spec.cwd,
        last_exit = spec.last_exit,
    }
end

-- `spec.records` sets the records. `spec.app` and `spec.state` are shorthand
-- for one record with those fields.
---@param spec table
---@return table
function M.block(spec)
    local records = spec.records or {}
    if spec.state then
        records = {
            {
                state = spec.state,
                kind = spec.kind,
                app = spec.app,
                effective_app = spec.app,
                msg = spec.msg,
                updated_at = spec.updated_at or '2026-01-01T10:00:00+00:00',
            },
        }
    end
    return {
        id = spec.id,
        label = spec.label or 'shell',
        title = spec.title,
        records = records,
        process = process(spec),
    }
end

---@param spec table `id`, `label`, `blocks`
---@return table
function M.window(spec)
    return {
        id = spec.id,
        label = spec.label or 'Window 0000',
        focused_block_id = spec.blocks[1] and spec.blocks[1].id,
        blocks = spec.blocks,
    }
end

---@param spec table `id`, `label`, `windows`, optional `error`
---@return table
function M.session(spec)
    return {
        id = spec.id,
        label = spec.label or 'session',
        active_window_id = spec.windows
            and spec.windows[1]
            and spec.windows[1].id,
        windows = spec.windows or {},
        error = spec.error,
    }
end

---@param sessions table[]
---@return table
function M.snapshot(sessions)
    return { version = 1, sessions = sessions }
end

-- One Session, one Window, one Block. `block` is passed to `M.block`.
---@param block table
---@param window_label string|nil
---@return table
function M.single(block, window_label)
    return M.snapshot({
        M.session({
            id = 'session:s1',
            windows = {
                M.window({
                    id = 'window:w1',
                    label = window_label,
                    blocks = { M.block(block) },
                }),
            },
        }),
    })
end

return M
