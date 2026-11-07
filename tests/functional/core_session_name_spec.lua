local session_name = require('rexai.core.session_name')

describe('core.session_name', function()
    describe('from_path', function()
        local home = '/Users/ana'
        local cases = {
            { '/Users/ana/code/app.web', home, 'code_app_web' },
            { '/Users/ana/app.web', home, 'app_web' },
            { '/Users/ana', home, 'ana' },
            { '/Users/ana/', home, 'ana' },
            { '/Users/ana/a/b/c/repo', home, 'c_repo' },
            { '/Users/ana/code/my.app.v2', home, 'code_my_app_v2' },
            { '/srv/app', home, 'srv_app' },
            { '/srv', home, 'srv' },
            { '/', home, 'session' },
            { '', home, 'session' },
            { '/Users/ana/code/app', nil, 'code_app' },
            { '/Users/ana/code/app', '', 'code_app' },
            { '/Users/anabel/app', home, 'anabel_app' },
        }
        for _, case in ipairs(cases) do
            local path, home_dir, expected = case[1], case[2], case[3]
            it('names "' .. path .. '" ' .. expected, function()
                assert.are.equal(
                    expected,
                    session_name.from_path(path, home_dir)
                )
            end)
        end
    end)
end)
