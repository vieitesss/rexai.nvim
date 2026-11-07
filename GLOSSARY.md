# rexai.nvim

A Neovim dashboard that lists the AI coding agents running in Rex, shows what each one is doing, takes the user to one, and starts new agent Sessions. It reads only what Rex reports and knows nothing about any workflow that launched the agents.

## Language

### Rex hierarchy

**Session**:
A Rex session, shown with the name Rex gives it.
_Avoid_: Workspace, project

**Window**:
A Rex window, which the Rex app shows as a tab. This project never says "tab" for it.
_Avoid_: Tab, pane

**Block**:
A Rex terminal inside a Window.
_Avoid_: Pane, terminal

**Tabpage**:
A Neovim tabpage. Only Neovim has these.
_Avoid_: Tab

### Agents

**Agent block**:
A Block that runs an AI coding agent. It is the unit the Dashboard lists, under its Session.
_Avoid_: Agent pane, agent terminal, agent window, agent tab

**Agent status**:
What an Agent block says it is doing: needs input, error, done, working or idle. An Agent block that says nothing is shown as unreported.
_Avoid_: State, blocked, waiting

**Exited**:
An Agent block whose agent has ended while the Block stays open. It keeps its last known status and shows the exit code.
_Avoid_: Dead, stopped, finished

### Dashboard

**Dashboard**:
The Neovim buffer that lists the Agent blocks, each with its Agent status.
_Avoid_: Picker, list view

**Home session**:
The Session that holds the Neovim running the Dashboard. The `rexai` command creates it on first use and always returns the user to it.
_Avoid_: Main session
