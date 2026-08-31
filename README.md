# reminder-calendar-control

`rcc` — a native macOS tool that gives Claude Desktop read/write access to Calendar and
Reminders through EventKit, plus an unattended automation layer that runs without any chat
session open.

Personal-use, single-machine, macOS 26+. See [SPEC.md](SPEC.md) for the full design.

## Status

**Milestone 1a of 7 — platform & packaging proof.**

Delivered: the TCC self-disclaim mechanism and its one-time guard, the embedded
`Info.plist` and Hardened Runtime signing profile, one authoritative install path,
`rcc doctor`, the tool-owned dev calendar and reminder list, a minimal MCP stdio server,
and an acceptance harness that proves read/write from all three launch contexts.

Not delivered, and gated on an Apple Developer ID certificate this machine does not have:
the Developer-ID-signed, notarized artifact SPEC §18 asks Milestone 1 to be proven against.
See [docs/milestone-1.md](docs/milestone-1.md) for exactly what that blocks and what it
costs day to day.

Calendar and reminder CRUD arrives in Milestones 3 and 4; automation in 6 and 7.

## Install

```bash
./Scripts/install.sh
"$HOME/Library/Application Support/reminder-calendar-control/bin/rcc" setup --dev
```

`setup` must run from the installed path — macOS records the Calendar and Reminders grant
against whichever binary asked for it, so granting from a build directory grants it to a
copy nothing else runs.

Then quit Claude Desktop fully (⌘Q) and relaunch; it does not reload its config file.

## Commands

| Command | What it does |
|---|---|
| `rcc setup [--dev] [--verify] [--uninstall]` | Grant access, register with Claude Desktop, install the LaunchAgent |
| `rcc doctor [--json]` | Check every part of the install, with remediation for anything broken |
| `rcc status [--json]` | One-line health snapshot |
| `rcc serve` | MCP server over stdio — what Claude Desktop spawns |
| `rcc selftest [--json] [--context <name>]` | Prove read/write against the dev fixtures from this launch context |
| `rcc automations run` | What launchd invokes on a schedule (a no-op until Milestone 6) |

Approval of staged automation actions is deliberately CLI-only and will never be an MCP
tool (SPEC §6.4, §8.3): a model-callable approval tool does not prove a human approved
anything.

## Development

```bash
swift build            # debug
swift test             # 107 tests, no EventKit or TCC involvement
./Scripts/build-release.sh
./Scripts/m1-acceptance.sh
```

Everything above the `CalendarRepository` protocol is testable against an in-memory fake,
so the unit suite never touches a real calendar or triggers a permission prompt.

## Layout

```
Sources/
  CDisclaim/       C shim over the two private libquarantine symbols
  RCCBootstrap/    the self-disclaim mechanism — runs before anything else
  RCCCore/         paths, exit codes, logging, redaction, SQLite state
  RCCCalendar/     EventKit protocol, real adapter, in-memory fake, dev fixtures
  RCCPlatform/     code signing, launchd, Claude Desktop config, Keychain, notifications
  RCCDiagnostics/  rcc doctor and the acceptance self-test
  RCCMCP/          MCP stdio server
  rcc/             CLI entry point and subcommands
```
