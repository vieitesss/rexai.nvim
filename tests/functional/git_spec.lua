-- The git slot of the Dashboard, asked for in the background and cached per
-- path. The runner and the clock are seams, so no test here waits on a real
-- process except the one that builds a throwaway repository.

local core_git = require('rexai.core.git')
local git = require('rexai.git')

-- The status git prints for a clean branch with one untracked file.
local CLEAN = table.concat({
    '# branch.oid 1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b',
    '# branch.head main',
    '# branch.upstream origin/main',
    '# branch.ab +0 -0',
    '? notes.md',
}, '\n')

---@return table a runner that queues calls for the test to answer
local function runner()
    local r = { queue = {} }

    function r.run(argv, callback)
        r.queue[#r.queue + 1] = { argv = argv, callback = callback }
    end

    ---@return table the oldest call the test has not answered
    function r.next()
        local call = table.remove(r.queue, 1)
        assert.is_not_nil(call, 'no git call is waiting')
        return call
    end

    -- Answers the oldest waiting call.
    ---@param err string|nil
    ---@param stdout string|nil
    function r.answer(err, stdout)
        r.next().callback(err, stdout)
    end

    return r
end

---@return table a clock the test moves by hand, in milliseconds
local function fake_clock()
    local clock = { ms = 0 }
    function clock.now()
        return clock.ms
    end
    function clock.advance(ms)
        clock.ms = clock.ms + ms
    end
    return clock
end

-- Lets every callback `vim.schedule` queued run. A marker scheduled after
-- them runs last, because the queue is first in, first out.
local function flush()
    local done = false
    vim.schedule(function()
        done = true
    end)
    assert.is_true(vim.wait(500, function()
        return done
    end, 1))
end

-- Answers both calls of one request: the status, then the work tree root.
---@param r table
---@param status string|nil
---@param root string|nil
local function complete(r, status, root)
    r.answer(nil, status or CLEAN)
    r.answer(nil, root or '/work/orbit\n')
end

describe('git', function()
    describe('request and get', function()
        it('asks git about a path and keeps what it says', function()
            local r = runner()
            local g = git.new({ run = r.run })
            assert.is_nil(g:get('/work/orbit'))

            g:request('/work/orbit')

            local status = r.next()
            assert.are.same({
                'git',
                '--no-optional-locks',
                '-C',
                '/work/orbit',
                'status',
                '--porcelain=v2',
                '--branch',
                '--untracked-files=normal',
            }, status.argv)
            status.callback(nil, CLEAN)

            local root = r.next()
            assert.are.same({
                'git',
                '-C',
                '/work/orbit',
                'rev-parse',
                '--show-toplevel',
            }, root.argv)
            root.callback(nil, '/work/orbit\n')

            local info = g:get('/work/orbit')
            assert.are.equal('orbit', info.repo)
            assert.are.equal('/work/orbit', info.root)
            assert.are.equal('main', info.branch)
            assert.are.equal(1, info.changed)
            assert.are.equal(0, #r.queue)
        end)

        it('does nothing for a path that is nil or empty', function()
            local r = runner()
            local g = git.new({ run = r.run })

            g:request(nil)
            g:request('')

            assert.are.equal(0, #r.queue)
            assert.is_nil(g:get(nil))
            assert.is_nil(g:get(''))
        end)
    end)

    describe('the refresh window', function()
        it('asks a path again only after git_refresh_ms', function()
            local clock = fake_clock()
            local r = runner()
            local g = git.new({
                run = r.run,
                clock = clock.now,
                refresh_ms = 5000,
            })
            g:request('/work/orbit')
            complete(r)

            clock.advance(4999)
            g:request('/work/orbit')
            assert.are.equal(0, #r.queue)

            clock.advance(1)
            g:request('/work/orbit')
            assert.are.equal(1, #r.queue)
        end)

        it('never runs two calls for one path at a time', function()
            local r = runner()
            local g = git.new({ run = r.run })

            g:request('/work/orbit')
            g:request('/work/orbit')
            assert.are.equal(1, #r.queue)

            -- The status came back; the root call is in flight now.
            r.answer(nil, CLEAN)
            g:request('/work/orbit')
            assert.are.equal(1, #r.queue)

            r.answer(nil, '/work/orbit\n')
            assert.is_not_nil(g:get('/work/orbit'))
        end)

        it('caches a path git cannot describe and asks again later', function()
            local clock = fake_clock()
            local r = runner()
            local g = git.new({
                run = r.run,
                clock = clock.now,
                refresh_ms = 1000,
            })

            g:request('/not/a/repo')
            r.answer('git exited with code 128')
            assert.is_nil(g:get('/not/a/repo'))
            -- A failed status needs no root call.
            assert.are.equal(0, #r.queue)

            g:request('/not/a/repo')
            assert.are.equal(0, #r.queue)

            clock.advance(1000)
            g:request('/not/a/repo')
            assert.are.equal(1, #r.queue)
        end)

        it('gives no slot when the work tree root is unreadable', function()
            local clock = fake_clock()
            local r = runner()
            local g = git.new({
                run = r.run,
                clock = clock.now,
                refresh_ms = 1000,
            })

            g:request('/work/orbit')
            r.answer(nil, CLEAN)
            r.answer('git exited with code 128')
            assert.is_nil(g:get('/work/orbit'))

            clock.advance(1000)
            g:request('/work/orbit')
            r.answer(nil, CLEAN)
            r.answer(nil, '\n')
            assert.is_nil(g:get('/work/orbit'))
        end)
    end)

    describe('on_change', function()
        it('reports a change once, and only when get changes', function()
            local clock = fake_clock()
            local r = runner()
            local changes = 0
            local g = git.new({
                run = r.run,
                clock = clock.now,
                refresh_ms = 1000,
                on_change = function()
                    changes = changes + 1
                end,
            })

            g:request('/work/orbit')
            complete(r)
            flush()
            assert.are.equal(1, changes)

            -- The same status again is not a change.
            clock.advance(1000)
            g:request('/work/orbit')
            complete(r)
            flush()
            assert.are.equal(1, changes)

            -- One more changed path is.
            clock.advance(1000)
            g:request('/work/orbit')
            complete(r, CLEAN .. '\n? second.md')
            flush()
            assert.are.equal(2, changes)

            -- So is a path that stops being a work tree.
            clock.advance(1000)
            g:request('/work/orbit')
            r.answer('git exited with code 128')
            flush()
            assert.are.equal(3, changes)
            assert.is_nil(g:get('/work/orbit'))
        end)

        it('does not report a path that never had a slot', function()
            local r = runner()
            local changes = 0
            local g = git.new({
                run = r.run,
                on_change = function()
                    changes = changes + 1
                end,
            })

            g:request('/not/a/repo')
            r.answer('git exited with code 128')
            flush()

            assert.are.equal(0, changes)
        end)
    end)

    describe('retain', function()
        it('drops a path no longer shown and drops its late result', function()
            local r = runner()
            local changes = 0
            local g = git.new({
                run = r.run,
                on_change = function()
                    changes = changes + 1
                end,
            })
            g:request('/work/orbit')
            complete(r)
            g:request('/work/ledger')
            local late = r.next()

            g:retain({ '/work/orbit' })

            assert.is_nil(g:get('/work/ledger'))
            late.callback(nil, CLEAN)
            assert.is_nil(g:get('/work/ledger'))
            -- The late status started no root call and reported no change.
            assert.are.equal(0, #r.queue)
            flush()
            assert.are.equal(1, changes)
            assert.is_not_nil(g:get('/work/orbit'))

            -- A path it was told to forget is asked about again at once.
            g:request('/work/ledger')
            assert.are.equal(1, #r.queue)
        end)
    end)

    describe('stop', function()
        it(
            'drops the cache and every late result, and is safe twice',
            function()
                local r = runner()
                local changes = 0
                local g = git.new({
                    run = r.run,
                    on_change = function()
                        changes = changes + 1
                    end,
                })
                g:request('/work/orbit')
                complete(r)
                g:request('/work/ledger')
                local late = r.next()

                g:stop()
                g:stop()

                assert.is_nil(g:get('/work/orbit'))
                late.callback(nil, CLEAN)
                late.callback(nil, CLEAN)
                assert.is_nil(g:get('/work/ledger'))
                assert.are.equal(0, #r.queue)
                flush()
                assert.are.equal(1, changes)
            end
        )
    end)

    describe('the real git', function()
        -- The developer's own git config must not reach the child.
        local ENV = {
            GIT_CONFIG_GLOBAL = '/dev/null',
            GIT_CONFIG_SYSTEM = '/dev/null',
        }

        ---@param args string[]
        ---@return string stdout
        local function run_git(args)
            local argv = { 'git' }
            vim.list_extend(argv, args)
            local result = vim.system(argv, { text = true, env = ENV }):wait()
            assert.are.equal(0, result.code, result.stderr)
            return result.stdout
        end

        it('describes a throwaway work tree', function()
            if vim.fn.executable('git') ~= 1 then
                pending('git is not on PATH')
                return
            end

            local dir = vim.fn.tempname()
            local repo = dir .. '/orbit'
            vim.fn.mkdir(repo .. '/src', 'p')
            vim.fn.writefile({ 'return 1' }, repo .. '/src/parser.lua')

            run_git({ 'init', '-q', repo })
            run_git({ '-C', repo, 'add', '-A' })
            run_git({
                '-C',
                repo,
                '-c',
                'user.name=Test',
                '-c',
                'user.email=test@example.invalid',
                'commit',
                '-q',
                '-m',
                'first',
            })
            run_git({ '-C', repo, 'checkout', '-q', '-b', 'feature/parser' })
            vim.fn.writefile({ 'return 2' }, repo .. '/src/parser.lua')
            vim.fn.writefile({ 'notes' }, repo .. '/notes.md')

            local before = {
                global = vim.env.GIT_CONFIG_GLOBAL,
                system = vim.env.GIT_CONFIG_SYSTEM,
            }
            vim.env.GIT_CONFIG_GLOBAL = ENV.GIT_CONFIG_GLOBAL
            vim.env.GIT_CONFIG_SYSTEM = ENV.GIT_CONFIG_SYSTEM

            local g = git.new({ refresh_ms = 60000 })
            local ok, err = pcall(function()
                g:request(repo)
                local arrived = vim.wait(10000, function()
                    return g:get(repo) ~= nil
                end, 10)
                assert.is_true(arrived, 'git never answered')

                assert.are.equal(
                    'orbit · feature/parser ●2',
                    core_git.format(g:get(repo))
                )
            end)

            g:stop()
            vim.env.GIT_CONFIG_GLOBAL = before.global
            vim.env.GIT_CONFIG_SYSTEM = before.system
            vim.fn.delete(dir, 'rf')
            assert(ok, err)
        end)
    end)
end)
