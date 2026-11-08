# rexai.nvim

A Neovim Dashboard for the AI coding agents running in Rex. It lists each Agent block under its Session with its Agent status, takes you to one with a key, and starts new agent Sessions. It shows only what Rex reports and knows nothing about what started the agents.

Requirements:

- Neovim 0.11 or newer.
- Rex, with its `rex` command on `PATH` (or set `rex_bin`). The Dashboard never starts a Rex server: its calls carry `--autostart=false`.
- `git`, optional. Without it, rows show no branch.

## Install

With lazy.nvim:

```lua
{
    'vieitesss/rexai.nvim',
    cmd = 'Rexai',
    opts = {},
}
```

With any other manager, call `setup()` yourself:

```lua
require('rexai').setup()
```

The plugin defines only `:Rexai` at startup. The Dashboard code loads when the command runs. `setup()` is optional: without it the defaults apply.

## Use

Run `:Rexai`. The Dashboard is a buffer in the current window, and `q` gives that window back its previous buffer. The Dashboard lists the Sessions that hold Agent blocks, with the Home session always listed and marked `(home)`. Each Agent block has an Agent status:

```
! api
  ! claude-code 4d5e  add the migration      needs input 1m
  x pi 7a8b           fix the failing test   error       4m
  + claude-code 0b1c  write the parser docs  done        14m
  ? opencode 6b7c     look at the logs       unreported
  - pi 9e0f           waiting for review     idle        2h
  . pi 2b3c           port the old script    exited 1    9m

* my-project (home)
  * pi 1b2c           refactor the parser    working     45s
```

The sample is a real render of invented names. A Session header shows the highest Agent status among its rows. When git works in a row's directory, a git column shows `repo · branch ↑ahead ↓behind ●changed`, leaving out zero counts. A row with no git result leaves that column blank.

| Agent status | Glyph | Meaning |
| --- | --- | --- |
| needs input | `!` | Rex reports the Block as blocked. |
| error | `x` | Rex reports an error. |
| done | `+` | Rex reports the agent is done. |
| working | `*` | Rex reports the agent is working. |
| unreported | `?` | The agent is running but reports no status. |
| idle | `-` | Rex reports the agent is idle. |
| exited | `.` | The agent has ended while its Block stays open. It shows the exit code. |

Keys in the Dashboard:

| Key | Action |
| --- | --- |
| `q` | Close the Dashboard. Shows the buffer that was in the window before. |
| `<CR>` | Go to the Agent block under the cursor, or to the Session of a header. |
| `r` | Ask Rex for a snapshot now. |
| `e` | Show or hide the Exited rows. The Dashboard keeps the choice until its buffer is wiped. |
| `d` | Hand the row under the cursor to the `review` hook. |
| `K` | Open a float with what is known about the Agent block and the last lines of its screen. Press `K` again to enter the float. |
| `n` | Add a Window to the Session under the cursor. |
| `N` | Start a Session for a directory you name. |

While a window shows the Dashboard and Neovim has focus, it asks Rex every `refresh_ms`. It also asks when it opens, on `r`, and when Neovim gains focus. When Rex cannot be read, the Dashboard shows `Rex unreadable:` with the reason and retries after 5 seconds.

## Configuration

Every option is flat. A list replaces the default list; it does not add to it. A table such as `glyphs` keeps the entries you do not set.

| Option | Type | Default | What it does |
| --- | --- | --- | --- |
| `refresh_ms` | integer | `1000` | How often the Dashboard asks Rex for a snapshot. |
| `git_refresh_ms` | integer | `5000` | How old a git result may be before it is asked again. |
| `show_exited` | boolean | `true` | The starting value of the `e` toggle: whether Exited rows are listed. |
| `title_width` | integer | `40` | The widest title, in display cells, `…` included. |
| `rex_bin` | string | `'rex'` | The `rex` executable the Dashboard and `:checkhealth` run. |
| `peek_lines` | integer | `20` | How many lines from the end of a Block the `K` float keeps. |
| `focus_new` | boolean | `true` | Whether `n` and `N` select the Window or Session they made. `false` leaves the view where it is. |
| `session_name` | function or nil | `nil` | Names a new Session from its directory. See [Recipes](#recipes). |
| `glyphs` | table | see below | One single-width character per Agent status. |
| `resolve_path` | function or nil | `nil` | Gives the directory a row stands for. See [Recipes](#recipes). |
| `review` | function or nil | `nil` | What `d` calls with the context of a row. See [Recipes](#recipes). |
| `agents.apps` | list | `{ 'claude-code', 'pi' }` | `app` names in Rex program status records that make a Block an Agent block. |
| `agents.commands` | list | `{ 'claude', 'codex', 'opencode', 'pi' }` | Foreground command names that make a Block an Agent block, and the agents `n` and `N` offer. An empty list makes both refuse. |
| `agents.launch` | table | `{}` | Maps an agent name to the full argv that starts it. |

The full `setup()` call with every default:

```lua
require('rexai').setup({
    refresh_ms = 1000,
    git_refresh_ms = 5000,
    show_exited = true,
    title_width = 40,
    rex_bin = 'rex',
    peek_lines = 20,
    focus_new = true,
    -- nil: the last two directories of the path name a new Session.
    session_name = nil,
    glyphs = {
        needs_input = '!',
        error = 'x',
        done = '+',
        working = '*',
        unreported = '?',
        idle = '-',
        exited = '.',
    },
    agents = {
        apps = { 'claude-code', 'pi' },
        commands = { 'claude', 'codex', 'opencode', 'pi' },
        -- A full argv that replaces `{ command }` for one agent.
        launch = {},
    },
    -- nil: a row stands for the directory of its Block.
    resolve_path = nil,
    -- nil: `d` only says that no review function is set.
    review = nil,
})
```

## Recipes

Each hook is a plain function in the config. It is read when it is called, so a `setup()` after the Dashboard opened counts.

### `resolve_path`

Rex reports a directory for each Block. Set `resolve_path` when the directory to show git for is another one. The hook runs for every row of every snapshot, so keep it cheap. It receives a copy of the row, with `block_id`, `session_id`, `window_id`, `harness`, `label`, `status`, `title` and `cwd`. It returns an absolute directory. A non-empty string wins; `nil` or `''` keeps `row.cwd`. The plugin does not expand `~`, so use `vim.fn.expand`.

```lua
require('rexai').setup({
    -- A Block that runs in a scratch directory shows the project instead.
    resolve_path = function(row)
        if row.cwd and row.cwd:find('/scratch$') then
            return vim.fn.expand('~/code/app')
        end
    end,
})
```

The git slot, `d` and `n` all use the directory it returns.

### `review`

`d` calls `review` with the context of the row under the cursor. `ctx.path` is always set, because `d` does not call the hook for a row with no directory.

```lua
require('rexai').setup({
    review = function(ctx)
        -- ctx.path: the directory of the row
        -- ctx.repo_root, ctx.branch: from git, nil when unknown
        -- ctx.session: { id, label }; ctx.window: { id }
        -- ctx.block: a copy of the row
        vim.cmd.tabnew()
        vim.cmd.tcd(vim.fn.fnameescape(ctx.path))
    end,
})
```

If the hook throws, the Dashboard warns with the error. Without a hook, `d` says `rexai: no review function is set; add review = function(ctx) ... end to setup()`.

### `session_name`

`N` asks for a directory, then calls `session_name` with that absolute path, with `~` already expanded and no trailing slash. The label it returns names the new Session, and `N` looks for a Session with that label before it creates one: if one exists, `N` adds a Window to it.

```lua
require('rexai').setup({
    session_name = function(path)
        return vim.fs.basename(path)
    end,
})
```

When the hook returns `nil` or `''`, the label is the last two directories joined by `_`, so `~/code/app` gives `code_app`. When the hook throws, the Dashboard warns once with `rexai: session_name failed: …` and uses the same rule.

### `agents.launch`

`launch` maps a name from `agents.commands` to the full argv that starts that agent. Rex runs the argv directly, without a shell. A value that is not a list of strings is ignored, and the bare name starts the agent.

```lua
require('rexai').setup({
    agents = {
        launch = {
            pi = { 'pi', '--continue' },
        },
    },
})
```

## Starting Agent blocks

`n` asks for an agent from `agents.commands`, then for a directory that starts at the row's directory, or at Neovim's on a Session header. It adds a Window to the Session under the cursor. On the header of the Home session it refuses, because a Window is added next to an Agent block, and the Home session may have none. Use `N` there.

`N` asks for an agent, then for a directory that starts at Neovim's current directory. It starts a Session labelled by `session_name`, or adds a Window to the Session that already has that label.

When `agents.commands` is empty, both keys warn `rexai: no agent is configured; set agents.commands in setup()` and open no picker.

With `focus_new = true`, the plugin selects the new Window or Session after it is made. With `focus_new = false`, neither key selects it; the create calls pass no focus flag.

## The `rexai` command

`bin/rexai` puts you in the Dashboard from any shell, inside Rex or outside it. It finds or creates the Home session, labelled `rexai`, with one Window labelled `dashboard`. That Block runs `nvim +Rexai` in your home directory. It then selects that Window and its Block in the Rex app that owns the shell, or in the only connected app. Outside Rex with several apps connected, it stops with an error. It always returns you to that Session. Unlike the Dashboard, the shim does not pass `--autostart=false`, so rex may start a server for it.

Requirements and setup:

- `rex` must be on `PATH`. The shim ignores `rex_bin`.
- The `nvim` that Rex runs must have this plugin installed, because the Block runs `nvim +Rexai`.
- Put the shim on `PATH` with a symbolic link. A copy does not work, because the shim finds `scripts/` beside its own checkout.

```sh
ln -s ~/code/rexai.nvim/bin/rexai ~/.local/bin/rexai
```

`rexai --name NAME` labels the Session `NAME` instead of `rexai`. `rexai --help` prints the usage.

## Health

Run `:checkhealth rexai`. It checks, item by item:

- Neovim is 0.11 or newer.
- The `rex_bin` executable exists.
- The Rex server answers `rex whoami`. If not, it suggests `rex server start`.
- The Neovim runs inside Rex (`$REX_BLOCK` is set). If not, it warns.
- Rex apps are connected. None is an error. Several is a warning when this Neovim is not inside one of them.
- `git` is executable. If not, it warns.
- The `rexai` shim is on `PATH`. If not, it warns.

The checks never start a server and never switch your view.

## Limits

- Whether Rex clears the `done` Agent status after you view its Block is not verified. The plugin shows the status Rex reports and never changes it.
- The Dashboard knows only what Rex reports. An agent that reports nothing shows `unreported`. An agent that no `agents.apps` or `agents.commands` entry matches is not listed.
- An Exited row appears only for an Agent block the Dashboard saw live in this Neovim process. Restarting Neovim forgets them. When Rex no longer lists a Block, its row goes too.
- The plugin only reads and selects. It never closes a Block or a Session.

## Development

- `just test`: runs every plenary spec. The first run clones `plenary.nvim` into the ignored `plenary.nvim/` directory.
- `just check`: runs `stylua --check` and `lua-language-server`. It needs `stylua`, `nvim` and `lua-language-server` on `PATH`. Outside `just check`, set `VIMRUNTIME` to your Neovim runtime directory. The `.luarc.json` reads `vim.*` from `${env:VIMRUNTIME}`, so without it your editor's LuaLS reports `vim` as undefined.
- `just format`: formats every Lua file with `stylua`.
- `just dev`: runs Neovim with this checkout through `dev/init.lua`.
- `just fixture`: records an anonymized fixture from a live Rex. It is the only way fixtures are made.
- `just smoke`: checks the plugin against the live Rex by hand. It creates a throwaway `rexai-smoke-<hex>` Session, never selects or focuses anything, and removes that Session by id. CI has no Rex, so CI never runs it.

## License

MIT. See the `LICENSE` file.
