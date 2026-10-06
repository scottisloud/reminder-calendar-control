# scottisloud/homebrew-tap

Homebrew tap for tools by [@scottisloud](https://github.com/scottisloud).

## How do I install these?

```bash
brew install --cask scottisloud/tap/<name>
```

Or tap once, then install by name:

```bash
brew tap scottisloud/tap
brew install --cask <name>
```

## Available casks

| Cask | Command | Description | Requires |
|---|---|---|---|
| [`rcc`](#rcc) | `rcc` | Calendar and Reminders for Claude Desktop, as a local MCP server | macOS 26+, Apple silicon |

---

## rcc

`rcc` (reminder-calendar-control) gives Claude Desktop read and write access to your Mac's Calendar and Reminders. It is a native Swift binary that runs as a local MCP server and works with every account your Mac already syncs, including iCloud, Google, Exchange and Fastmail, through Apple's EventKit. It has no telemetry and opens no network port; Claude Desktop starts it and talks to it over stdio.

With it, Claude can:

- Answer "what's on my plate today?" from your reminders and calendar.
- Create, reschedule and delete events, including single occurrences of repeating ones.
- Create, complete and edit reminders, singly or in batches, due on a day or at a time.
- Manage reminder lists.
- Set up automation rules that run on a schedule with Claude closed, such as flagging meetings with no location. Anything destructive is staged until you approve it in Terminal.

### Install

```bash
brew install --cask scottisloud/tap/rcc
rcc setup
```

`rcc setup` is the one step a person has to do. macOS asks for Calendar and Reminders access, so approve both prompts. Setup then registers rcc with Claude Desktop and offers to restart it so the tools appear.

Without Homebrew (the script still uses Homebrew if it is installed):

```bash
curl -fsSL https://raw.githubusercontent.com/scottisloud/homebrew-tap/main/install.sh | bash
```

### Installing with an AI agent

Ask your agent: *"Install rcc from github.com/scottisloud/homebrew-tap."*

**Instructions for agents:** run exactly this, then tell the user what it printed.

```bash
curl -fsSL https://raw.githubusercontent.com/scottisloud/homebrew-tap/main/install.sh | bash
```

- Do not run `rcc setup` yourself. It needs a person to approve the macOS permission dialogs, and it does not get access from an agent's shell. When the script has no terminal, it opens a Terminal window running `rcc setup` for the user.
- Tell the user to approve the Calendar and Reminders prompts in that window. Setup then asks whether to restart Claude Desktop. If you are running inside Claude Desktop, warn the user that saying yes restarts the app this conversation is in.
- Afterwards, `rcc doctor` (safe to run from any shell) reports whether everything is healthy.
- Do not change, copy or re-sign the binary. Its signature and location are what the macOS permission grant is tied to.

### Commands

- `rcc setup` — grant Calendar and Reminders access and register with Claude Desktop.
- `rcc doctor` — check the install and print a fix for anything broken.
- `rcc status` — one-line health summary.
- `rcc automations pending` / `rcc automations approve <id>` — review and approve changes staged by automation rules.
- `rcc automations log` — recent automation runs and every change they made.
- `rcc serve` — the MCP server itself; Claude Desktop runs this, you do not need to.

Run `rcc --help` for the full list.

### Update and remove

```bash
brew upgrade rcc
```

The permission grant carries over. Without Homebrew, re-run the curl installer.

```bash
brew uninstall --zap rcc
```

This removes rcc, its LaunchAgent, its Claude Desktop entry and its state. A plain `brew uninstall rcc` leaves rcc registered with Claude Desktop. Without Homebrew, run `rcc setup --uninstall --purge-state --remove-binary`. Installing, updating and removing rcc never change your Calendar or Reminders data.

### What gets installed

- `~/Library/Application Support/reminder-calendar-control/bin/rcc` — the binary. macOS ties the permission grant to this one fixed path, so the `rcc` on your PATH is a symlink to it.
- An entry for `rcc serve` in Claude Desktop's `claude_desktop_config.json`.
- A LaunchAgent that runs `rcc automations run` every 30 minutes. It does nothing until you create a rule.

Releases are signed with Developer ID (team `T879Q2BE7Q`) and notarized by Apple. The installer checks both before installing. Each release's `rcc.zip` and its SHA-256 are attached to the [GitHub release](https://github.com/scottisloud/homebrew-tap/releases).

## Documentation

`brew help`, `man brew`, or the [Homebrew documentation](https://docs.brew.sh).
