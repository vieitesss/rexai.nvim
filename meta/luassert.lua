---@meta
-- LuaLS ships luassert definitions for its bundled luassert, which rejects the
-- trailing `message` argument that the luassert plenary vendors accepts. These
-- specs use that argument, so this file gives `assert` (from busted's meta) a
-- permissive callable namespace instead of the tighter, wrong one.

---@alias rexai.LuassertCall fun(...: any): any

---@class rexai.Luassert
---@field [string] rexai.LuassertCall

---@type rexai.Luassert
local luassert = {}
return luassert
