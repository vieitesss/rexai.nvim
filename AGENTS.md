## About the plugin

`rexai.nvim` is a Neovim plugin, written in Lua, that shows a Dashboard of the AI coding agents running in the Rex terminal multiplexer. It reads what Rex reports, takes the user to an agent, and starts new agent Sessions. Use the words in `GLOSSARY.md` for every concept it defines.

The plugin knows nothing about any workflow that launches agents. It never reads or mentions one, in code, tests, docs or fixtures.

## Public repository

This repository is public. Never commit private data: usernames, home paths, session or project names, prompts, titles or any text copied from a real Rex.

- Fixtures under `tests/fixtures/` are produced only by `just fixture`. It rewrites a live capture through a whitelist and refuses to write a file that fails the whitelist or contains `$HOME` or the username. The raw capture is never written to disk.
- Do not edit a fixture by hand to add real data. Hand-built test data uses invented values.

## Talking to Rex

- Run `rex` with an argument list, never a shell string. The binary path can contain a space.
- Rex runs Lua scripts in Lua 5.1 with `rex.*` available. `io.popen` and `os.execute` fail there.
- The local `rex` CLI is the source of truth for Rex facts. Check it instead of copying facts into the repo.
- Tests never need a running Rex. They stub `rex` by placing a fake executable first on `PATH`, or they use the fake backend.

## Tests

- Use `plenary.nvim` for creating and managing tests.
- Get information about how to create tests from this URL: https://raw.githubusercontent.com/nvim-lua/plenary.nvim/refs/heads/master/TESTS_README.md
- There should be:
    - Functional tests in `tests/functional`: only for functions that are part of each module's API. Do NOT create tests for local functions.
    - UI tests in `tests/ui`: check that windows and buffers are created and deleted correctly, and that the Dashboard is shown as expected during and after the execution of the plugin.
- Run them with `just test`. The first run clones `plenary.nvim` at a pinned commit into the ignored `plenary.nvim/` directory.
- Use `tests/helpers.lua` to read fixtures.

## Formatting

Use `stylua` for formatting. `just check` verifies it and `just format` applies it.

## Releases

- When creating a new release, do not create a new branch, do it from main.
- If you are not in the main branch, ask the user for confirmation.
