-- The Dashboard model: a snapshot from Rex in, Sessions with Agent rows out.
--
-- This module is pure. It touches neither Neovim nor Rex, so it runs in
-- Neovim's LuaJIT and in Rex's Lua 5.1.

local detect = require('rexai.core.detect')
local label = require('rexai.core.label')
local status = require('rexai.core.status')

local M = {}

---@class rexai.Row one Agent block
---@field session_id string
---@field window_id string
---@field block_id string
---@field harness string app or command name that identified the agent
---@field label string
---@field status string one of `rexai.core.status.ORDER`
---@field kind string|nil why it needs input
---@field msg string|nil
---@field updated_at string|nil ISO 8601 time of the last status change
---@field title string|nil terminal title
---@field cwd string|nil
---@field last_status string|nil for `exited`: the status it had before
---@field exit_code integer|nil for `exited`, when Rex reports one
---@field exit_error string|nil for `exited`, when Rex reports one

---@class rexai.ModelSession
---@field id string
---@field label string
---@field status string|nil highest status among its rows
---@field error string|nil why Rex could not be read for this Session
---@field rows rexai.Row[]

---@class rexai.Memory
---@field blocks table<string, rexai.Row> last live row of each Agent block seen

-- A Block that has exited reports no foreground agent and no status, so a
-- snapshot alone cannot say it was an Agent block. The memory carries the last
-- live row of every Agent block across snapshots. It lives only as long as the
-- Dashboard does.
---@return rexai.Memory
function M.new_memory()
    return { blocks = {} }
end

---@param row table
---@return table
local function copy(row)
    local out = {}
    for key, value in pairs(row) do
        out[key] = value
    end
    return out
end

local function live_row(session, window, block, harness)
    local current = status.of_records(block.records)
    local process = block.process or {}
    return {
        session_id = session.id,
        window_id = window.id,
        block_id = block.id,
        harness = harness,
        status = current.name,
        kind = current.kind,
        msg = current.msg,
        updated_at = current.updated_at,
        title = block.title,
        cwd = process.cwd,
    }
end

local function exited_row(remembered, block)
    local row = copy(remembered)
    local last_exit = block.process and block.process.last_exit
    row.last_status = remembered.status
    row.status = 'exited'
    row.exit_code = last_exit and last_exit.exit_code or nil
    row.exit_error = last_exit and last_exit.error or nil
    return row
end

-- Builds the rows of one Window, in Block order.
local function window_rows(session, window, agents, memory, present)
    local rows, live = {}, {}
    for _, block in ipairs(window.blocks or {}) do
        present[block.id] = true
        local harness = detect.harness(block, agents)
        if harness then
            local row = live_row(session, window, block, harness)
            live[#live + 1] = row
            rows[#rows + 1] = row
        elseif memory.blocks[block.id] then
            rows[#rows + 1] = exited_row(memory.blocks[block.id], block)
        end
    end

    -- Exited rows take part in the labels, so a new Agent block in the same
    -- Window never ends up with the label of one that exited.
    label.assign(window.label, rows)
    for _, row in ipairs(live) do
        memory.blocks[row.block_id] = copy(row)
    end
    return rows
end

-- Rows follow the order Rex reports. A Session with no Agent blocks is left
-- out, unless Rex could not be read for it.
--
-- `memory` is updated in place. Pass the same one to every call, so a Block
-- that exited since the last snapshot shows as `exited`. A Block that Rex no
-- longer lists is forgotten, unless its Session could not be read.
---@param snapshot table decoded output of `scripts/snapshot.lua`
---@param agents rexai.Agents
---@param memory rexai.Memory|nil
---@return rexai.ModelSession[] sessions
function M.build(snapshot, agents, memory)
    memory = memory or M.new_memory()
    local present, unreadable = {}, {}
    local sessions = {}

    for _, session in ipairs(snapshot.sessions or {}) do
        if session.error then
            unreadable[session.id] = true
        end

        local rows = {}
        for _, window in ipairs(session.windows or {}) do
            for _, row in
                ipairs(window_rows(session, window, agents, memory, present))
            do
                rows[#rows + 1] = row
            end
        end

        if #rows > 0 or session.error then
            local names = {}
            for _, row in ipairs(rows) do
                names[#names + 1] = row.status
            end
            sessions[#sessions + 1] = {
                id = session.id,
                label = session.label,
                status = status.rollup(names),
                error = session.error,
                rows = rows,
            }
        end
    end

    for block_id, remembered in pairs(memory.blocks) do
        if not present[block_id] and not unreadable[remembered.session_id] then
            memory.blocks[block_id] = nil
        end
    end

    return sessions
end

return M
