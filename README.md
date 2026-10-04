# reminder-calendar-control

`rcc` — a native macOS tool that gives Claude Desktop read/write access to Calendar and
Reminders through EventKit, plus an unattended automation layer that runs without any chat
session open.

Personal-use, single-machine, macOS 26+. See [SPEC.md](SPEC.md) for the full design.

## Status

**Milestones 1–5 of 7 done, plus the daily-driver write surface** (M4 core; the
automation-only staging flow is M6). Next: Milestone 6 — Tier 0 automation.

**M5 — release proof.** Install, update (`setup --verify`), and uninstall proven live;
uninstall never changes Calendar or Reminders data. Full write round trips on iCloud,
Google (which surfaces as CalDAV), and Fastmail. iOS parity corpus 18/18 on the rcc side
([docs/parity-corpus.md](docs/parity-corpus.md)). Measured: idle CPU 0.0%, 29 ms startup,
12–17 ms everyday reads, 0.83 s for three years of events. Measuring found a 20× listing
slowdown and a per-query memory leak in `rcc serve`; both fixed.
[docs/milestone-5-findings.md](docs/milestone-5-findings.md).

**M1 — platform & packaging proof.** Claude Desktop can talk to `rcc` end to end: a
Desktop-spawned `rcc serve` has full Calendar and Reminders access and passes its platform
self-test.

**M2 — core model & mutation journal.** Schema v2 adds the operation journal (a
crash-safe `prepared → executing → succeeded|failed`, `executing → outcome_unknown`
state machine), opaque server-issued locators with generation invalidation, idempotency
keys with replay, a `RecurrenceRule` DTO that round-trips through EventKit, and
`ContentVersion`/`if_match` for optimistic concurrency. `Reconciler.run()` recovers every
mid-flight operation on startup — verified against a fault injected at every journal
transition. The `if_match` / recurrence-scope / locator *enforcement* wiring lands with
M4's write path.

**M3 — read path.** Nine MCP read tools: `list_sources`, `list_calendars`,
`list_reminder_lists`, `list_events`, `search_events`, `get_event`, `list_reminders`,
`search_reminders`, `get_reminder`. The full §9.1–9.3 DTO model (every field, enum
name+raw value, `DateComponents` granularity, a `version` per item). Opaque base64url page
cursors; `MCPServer` watches `EKEventStoreChanged` and turns an outstanding cursor
`cursor_stale` on any external edit.

**M4 — write path.** Ten write tools (`create/update/delete_event`,
`create/update/complete/delete_reminder`, `create/update/delete_reminder_list`), each run
through `MutationExecutor`: the §9.6 journal sequence, `if_match` optimistic concurrency,
locator resolution, recurrence-scope validation, idempotency replay, and omit/null/set
patch semantics. `Reconciler` runs on `serve` startup. Verified live: full create → edit →
conflict → delete lifecycle on a real event. 216 tests. The automation staging/impact
matrix (§8.3) is Milestone 6.

**Daily-driver write surface.** Lists and calendars by name ("Personal") anywhere an id
is accepted; reminders due on a *day* or at a *time* (timed ones alert by default, and the
alert follows a reschedule); repeat rules, alerts, priority, location, URL, and moves between
lists/calendars on create and update; `complete_reminders` / `update_reminders` batches (one
Desktop confirmation for many items); `list_reminders` `due_window` ("overdue_or_today");
list rows labelled with their list's name; per-occurrence locators for recurring events.
Fixed along the way: `list_events` collapsed every recurring series to its first
occurrence, and occurrence-scoped edits/deletes hit the wrong occurrence. 240 tests.

Built: the embedded `Info.plist` + Hardened Runtime + `personal-information` entitlements
signing profile, notarization, one authoritative install path, the TCC self-disclaim
mechanism (kept but redundant — Claude Desktop disclaims MCP servers itself), a foreground
`NSApplication` grant flow for `rcc setup`, `rcc doctor`, the tool-owned dev calendar and
reminder list, the EventKit adapter, and a hand-rolled MCP stdio server.

The blocker that stood from the initial commit — a disclaimed headless binary could not
obtain a Calendar/Reminders grant on macOS 26 — turned out to need two things a Developer
ID signature alone did not provide: the `com.apple.security.personal-information.*`
entitlements (macOS 26.5 gates the prompt on them) and a foreground `NSApplication` for the
request. Plus a `read(2)` fix for a stdin hang that only a live MCP client triggered. Full
account in [docs/milestone-1b-findings.md](docs/milestone-1b-findings.md).

Calendar and reminder CRUD arrives in Milestones 3 and 4; automation in 6 and 7.

## Install

Needs an Apple Developer ID certificate and a `notarytool` keychain profile — macOS 26
will not present the Calendar/Reminders prompt for an ad-hoc binary.

```bash
export RCC_NOTARY_PROFILE=<your-notarytool-profile>
./Scripts/build-release.sh --notarize          # Developer ID + entitlements + notarize
./Scripts/install.sh --skip-build              # atomic install to the stable path
"$HOME/Library/Application Support/reminder-calendar-control/bin/rcc" setup --dev
```

`setup` **must be run interactively from a real terminal** (Terminal.app, Ghostty, …). It
brings up a foreground `NSApplication` and requests Calendar and Reminders access — approve
both macOS dialogs. A non-interactive run reports what is missing and exits non-zero. The
grant is recorded against `rcc`'s own designated requirement, so a later Desktop-spawned
`rcc serve` matches it.

`setup` must also run from the installed path — macOS records the grant against whichever
binary asked for it, so granting from a build directory grants a copy nothing else runs.

Then quit Claude Desktop fully (⌘Q) and relaunch; it does not reload its config file.

A headless app bundle (`./Scripts/install.sh --bundle` → `RCC.app`, `LSUIElement`, no
windows) exists only so the tool can carry an app icon, which a bare Mach-O cannot. It is
not required for TCC — that was measured directly. The bare binary is the default because
replacing one file is a true atomic rename; replacing a bundle is not.

## Commands

| Command | What it does |
|---|---|
| `rcc setup [--dev] [--verify] [--uninstall]` | Grant access, register with Claude Desktop, install the LaunchAgent. `--verify` after an update; `--uninstall [--keep-state\|--purge-state] [--remove-binary]` removes rcc and never touches Calendar or Reminders data; `--remove-dev` deletes only the `--dev` test calendar and list |
| `rcc doctor [--json]` | Check every part of the install, with remediation for anything broken |
| `rcc status [--json]` | One-line health snapshot |
| `rcc serve` | MCP server over stdio — what Claude Desktop spawns |
| `rcc selftest [--json] [--context <name>]` | Prove read/write against the dev fixtures from this launch context |
| `rcc automations run` | What launchd invokes on a schedule (a no-op until Milestone 6) |

Build the bundle on its own with `./Scripts/make-app-bundle.sh`.

Approval of staged automation actions is deliberately CLI-only and will never be an MCP
tool (SPEC §6.4, §8.3): a model-callable approval tool does not prove a human approved
anything.

## Development

```bash
swift build            # debug
swift test             # 246 tests, no EventKit or TCC involvement
./Scripts/build-release.sh
./Scripts/m1-acceptance.sh
Scripts/benchmark.py   # SPEC §7.3 measurements against the installed binary
Scripts/parity.py      # rcc side of docs/parity-corpus.md (writes only to the dev fixtures)
```

Everything above the `CalendarRepository` protocol is testable against an in-memory fake,
so the unit suite never touches a real calendar or triggers a permission prompt. Under
`swift test`, every writable path — state, logs, LaunchAgents, the Claude Desktop config —
is redirected to a throwaway directory, so a test cannot reach your real ones.

## Layout

```
Resources/         embedded Info.plist, Entitlements.plist, app icon (.icns + Icon Composer)
Sources/
  CDisclaim/       C shim over the two private libquarantine symbols
  RCCBootstrap/    the self-disclaim mechanism — runs before anything else (redundant with
                   Claude Desktop's own disclaimer shim; kept for `rcc setup` attribution)
  RCCCore/         paths, exit codes, logging, redaction, SQLite state
  RCCCalendar/     EventKit protocol, real adapter, in-memory fake, dev fixtures,
                   InteractiveGrant (foreground NSApplication for the first TCC prompt)
  RCCPlatform/     code signing, launchd, Claude Desktop config, Keychain, notifications
  RCCDiagnostics/  rcc doctor and the acceptance self-test
  RCCMCP/          MCP stdio server
  rcc/             CLI entry point and subcommands
```
