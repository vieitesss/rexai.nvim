-- Plain data. The user config in Neovim is merged over this elsewhere.

return {
    agents = {
        -- `app` strings seen in Rex program status records.
        apps = { 'claude-code', 'pi' },
        -- Foreground command names (basename of argv0) for agents that do
        -- not report a status. A match with no status is `unreported`.
        commands = { 'claude', 'codex', 'opencode', 'pi' },
        -- A full argv that replaces `{ command }` as the command of one
        -- agent, e.g. `launch = { claude = { 'claude', '--continue' } }`.
        launch = {},
    },
}
