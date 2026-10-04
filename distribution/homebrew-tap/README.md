# scottisloud/tap

Homebrew tap and release downloads for **rcc**, which gives Claude Desktop access to
Calendar and Reminders on macOS. rcc is a local MCP server that works with every account
your Mac already has (iCloud, Google, Exchange and others) through EventKit.

Requires macOS 26 or later on Apple silicon.

## Install

With Homebrew:

```bash
brew install --cask scottisloud/tap/rcc
rcc setup
```

Without Homebrew (it uses Homebrew anyway if it's installed):

```bash
curl -fsSL https://raw.githubusercontent.com/scottisloud/homebrew-tap/main/install.sh | bash
```

`rcc setup` is the one step a person has to do. macOS asks for Calendar and Reminders
access, so approve both prompts. Setup then registers rcc with Claude Desktop and offers to
restart it so the change takes effect.

## Installing with an AI agent

Ask your agent: *"Install rcc from github.com/scottisloud/homebrew-tap."*

**Instructions for agents:** run exactly this, then tell the user what it printed.

```bash
curl -fsSL https://raw.githubusercontent.com/scottisloud/homebrew-tap/main/install.sh | bash
```

- Don't run `rcc setup` yourself. It needs a person to approve macOS permission dialogs,
  and it won't get access from an agent's shell. When the script has no terminal, it opens
  a Terminal window running `rcc setup` for the user.
- Tell the user to approve the Calendar and Reminders prompts in that window. Setup then
  asks whether to restart Claude Desktop. If you're running inside Claude Desktop, warn
  them that saying yes restarts this conversation's app.
- Afterwards, `rcc doctor` (safe to run from any shell) reports whether everything is
  healthy.
- Don't change, copy or re-sign the binary. Its signature and location are what macOS's
  permission grant is tied to.

## Update and remove

```bash
brew upgrade rcc               # or re-run the curl installer
brew uninstall --zap rcc       # removes rcc, its LaunchAgent, Desktop entry and state
```

Without Homebrew, remove it with
`rcc setup --uninstall --purge-state --remove-binary`. Installing, updating and removing
rcc never change your Calendar or Reminders data.

## What gets installed

- `~/Library/Application Support/reminder-calendar-control/bin/rcc`: the binary. macOS
  ties the permission grant to this one fixed path, so `rcc` on your PATH is a symlink to
  it.
- An entry for `rcc serve` in Claude Desktop's `claude_desktop_config.json`.
- A LaunchAgent that runs `rcc automations run` every 30 minutes (rule-based automations;
  it does nothing until you create a rule).

Releases are signed with Developer ID (team `T879Q2BE7Q`) and notarized by Apple. The
installer checks both before installing.
