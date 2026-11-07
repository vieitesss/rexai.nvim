local M = {}

function M.run(script_path, rex_fake)
    local chunk = assert(loadfile(script_path))
    setfenv(chunk, setmetatable({ rex = rex_fake }, { __index = _G }))
    return pcall(chunk)
end

function M.fake(handlers)
    local calls = {}
    local function call(method, params, app)
        calls[#calls + 1] = {
            method = method,
            params = vim.deepcopy(params),
            app = app,
        }
        return assert(handlers[method], 'unexpected Rex call: ' .. method)(
            params,
            app
        )
    end

    return {
        call = function(method, params)
            return call(method, params)
        end,
        block = {
            call = function(app, method, params)
                return call(method, params, app)
            end,
        },
        session = {
            view = function(params)
                return call('session.view', params)
            end,
        },
    },
        calls
end

return M
