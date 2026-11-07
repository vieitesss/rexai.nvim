local M = {}

local source = debug.getinfo(1, 'S').source:sub(2)

---@return string
function M.root()
    return vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
end

---@param relative string path under the project root
---@return string
function M.read(relative)
    local file = assert(io.open(M.root() .. '/' .. relative, 'r'))
    local text = file:read('*a')
    file:close()
    return text
end

---@param name string fixture file name, e.g. 'sample.json'
---@return table
function M.fixture(name)
    return vim.json.decode(M.read('tests/fixtures/' .. name))
end

---@return string[] names of every committed fixture
function M.fixture_names()
    local names = {}
    for name, kind in vim.fs.dir(M.root() .. '/tests/fixtures') do
        if kind == 'file' and name:match('%.json$') then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    return names
end

return M
