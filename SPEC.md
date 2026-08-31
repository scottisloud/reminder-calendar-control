# reminder-calendar-control — Specification

Status: **Draft v4** — revised after a fourth independent external review (GPT/Codex, adversarial pass on v3)
Owner: Scott Lougheed
Scope: personal-use macOS integration giving Claude Desktop full read/write access to Calendar.app and Reminders.app via EventKit, plus unattended automation independent of any open Claude session.

Changes are tagged **[v2]**/**[v3]**/**[v4]** inline where the correction matters for implementation. v4's most important change is structural: §6 ("Bootstrap, Identity & Trust Boundaries") is new and consolidates several things that were previously scattered and, in places, self-contradictory — the self-disclaim mechanism's one-time guard, the actual entitlement/signing profile, one authoritative install/update path, and where model authority stops and human authority starts.

---

## 1. Overview

macOS exposes Calendar and Reminders data to native apps through EventKit, but Claude Desktop lacks a built-in native EventKit connector. **[v4, reworded — "no way to interact with desktop applications" overclaimed; the specific gap is EventKit access, not desktop interaction generally.]** Claude for iOS already has this integration natively. This project closes that gap on macOS with a locally-run, native Swift tool that:

- Gives Claude Desktop full CRUD over Calendar events and Reminders items via a local MCP server, within the limits of what public EventKit actually exposes (§8.4 for the one confirmed gap).
- Matches (and where sensible, exceeds) what Claude for iOS already does, evaluated against a dated test corpus rather than a static claim (§12).
- Adds an unattended automation layer that can act on calendar/reminder data on a schedule, without Claude Desktop or any chat session open.

**Minimum OS: macOS 26.** **[v4 — raised from macOS 14 per explicit direction; no backward compatibility is needed.]** This removes any reason to carry legacy Info.plist usage-description keys or the deprecated unified EventKit access API — v1 uses only the modern full-access APIs and keys, full stop, with no fallback path for an older OS.

## 2. Goals

- Enumerate all calendars, reminder lists, and items EventKit exposes for the authorized macOS user — in practice, this Mac's iCloud and CalDAV-backed accounts, which is how Google Calendar is added to macOS (Google has no dedicated `EKSourceType`; it surfaces as `.calDAV` or another generic source type — confirmed via Apple's `EKSourceType` docs that there is no Google-specific case; the exact mapping needs one-time empirical confirmation against a live Google account, see §8.2).
- Full CRUD on events and reminders, to the extent EventKit itself permits (read-only/subscribed calendars stay read-only; RSVP/attendee-response writes are not supported by public EventKit at all — see §8.4).
- Available to Claude Desktop persistently, defined operationally (§7.2) rather than assumed from undocumented client behavior.
- Extremely resource-efficient: native Swift, no interpreter/runtime, near-zero idle cost, measured against a concrete benchmark matrix rather than a qualitative claim (§7.3).
- Rich, complete, structured data returned to Claude — formatting/presentation is Claude's job, not the server's. **[v4]** "Complete" is qualified against pagination's best-effort consistency guarantee (§10) — see the correction there.
- Unattended automation: scheduled or triggered actions on calendar/reminder data with no live chat session, with every Tier 1 (LLM-judged) write staged for human review regardless of impact level (§11.2) — untrusted calendar text should never turn into an unattended write with nobody checking it.
- At least at parity with Claude for iOS's Calendar/Reminders integration; free to exceed it, evaluated against a dated, reproducible test corpus that distinguishes documented behavior from observed behavior from this project's own constraints (§12).

## 3. Non-Goals

- Not a GUI app or menu bar app — headless CLI/MCP server only.
- Not a calendar sync engine — only ever talks to what's already registered with Calendar.app/Reminders.app via EventKit. A calendar that's read-only there stays read-only here.
- Not a distributable/general-audience product for v1 — built and tuned for this Mac, this user.
- **[v4, new]** Not a `.mcpb` "one-click install" product for v1. Packaging as a Desktop Extension is deferred — see §6.1 for why bundling introduces an install-topology problem that isn't worth solving before the core tool works, given this is explicitly a single-user, single-machine tool for now.
- Not built on Anthropic's own scheduled-tasks/routines infrastructure — see §11.1 for why, dated as of this research pass and independent of which specific Anthropic product name is current.
- Not a replacement for Claude's native iOS integration — a harmonized macOS counterpart to it.
- Not an RSVP/attendee-response tool. Confirmed via Apple's own documentation that public, headless EventKit cannot change participation status or add/remove attendees, and EventKitUI's RSVP-capable UI is iOS/Catalyst/visionOS-only. Read-only participation status is in scope; writing it is not (§8.4).
- No independent product telemetry from `rcc` itself. **[v4, corrected — see §13 for the precise claim.]** This does not mean calendar data never leaves the machine — it means `rcc` reports nothing about usage anywhere on its own initiative.
- **[v4, new]** Not solving the general same-logged-in-user confused-deputy problem. Any process running as the same OS user that can speak `rcc serve`'s stdio protocol can call its tools — this is true of every local MCP server and every CLI tool on the system, not a `rcc`-specific weakness, and is explicitly out of scope to solve uniquely here (§6.4).

## 4. Decisions Already Locked

| Decision | Choice | Why |
|---|---|---|
| Language/runtime | Native Swift | Direct EventKit access, no runtime overhead, smallest possible footprint |
| Audience | Personal use, this Mac only | Skip generalized onboarding/installer polish |
| Minimum OS | macOS 26 | **[v4]** No backward compatibility needed; use only modern APIs/keys, no legacy fallback |
| Write safety (automation, Tier 0) | Destructive/high-impact ops staged for human approval; non-destructive single-item creates execute directly | Fixed, user-authored rule actions — not derived from untrusted text at trigger time |
| Write safety (automation, Tier 1) | **[v4] Every proposed write is staged, regardless of impact level** | Tier 1's proposals are LLM-derived from untrusted calendar text — the prompt-injection surface a fixed Tier-0 rule doesn't have |
| Approval mechanism | **[v4] CLI-only (`rcc automations approve/reject`), never an MCP tool** | A model-callable approval tool doesn't prove a human approved anything, even mid-chat |
| Write safety (live chat) | Rely on Claude Desktop's own tool-confirmation UI, documented as an accepted, unenforced tradeoff | Simpler than a universal server-enforced queue; single-operator tool |
| RSVP/attendee-response | Out of scope, read-only status only | Confirmed impossible via public EventKit |
| Distribution (v1) | Single physical binary at a stable path; manual config, not `.mcpb` | Eliminates the two-physical-copies problem a bundled `.mcpb` would introduce (§6.1) |
| Process | Spec first, then implement | This document |
| Codebase origin | Build from scratch | Reuse *techniques* from prior art (§5), not their code |

## 5. Prior Art (reference, not dependency)

- **[PsychQuant/che-ical-mcp](https://github.com/psychquant/che-ical-mcp)** — pure Swift MCP server, 29 tools, signed & notarized, conflict/duplicate detection, undo/redo.
- **[FradSer/mcp-server-apple-events](https://github.com/FradSer/mcp-server-apple-events)** — TS wrapper around a vendored Swift CLI; source of the TCC-disclaim technique, verified directly against its actual source (`scripts/disclaim.c`).
- **[keith/reminders-cli](https://github.com/keith/reminders-cli)** — battle-tested minimal Reminders-only CLI.
- **[JonathanRReed/Apple-MCPs](https://github.com/JonathanRReed/Apple-MCPs)** — `safe_readonly` / `safe_manage` / `full_access` permission-tier pattern.
- Avoid as a base: icalBuddy (dead since 2020, unlicensed, read-only), icalPal (GPL-3.0, read-only).

**Why build from scratch rather than fork:** deliberate choice. che-ical-mcp solves the hardest problem (TCC) and has a richer starting feature set; the trade-off accepted is slower time-to-parity for a codebase shaped around this project's specific automation/safety design. If implementation reveals this was the wrong call, the prior art above are ready-made black-box comparison fixtures (TCC behavior, field round-tripping, recurring mutations, resource usage).

## 6. Bootstrap, Identity & Trust Boundaries

**[v4, new section — the previous drafts scattered these decisions across §6/§7 in a way that produced an actual infinite-loop bug and an underspecified install story. This section is the single source of truth for all of it.]**

### 6.1 Physical binary & install/update topology

**One physical binary. No duplicate copies, no bundling ambiguity.**

1. Build produces one signed, notarized executable, tentatively named **`rcc`**.
2. Install (a plain shell script / `make install` for v1 — explicitly **not** a `.mcpb`, see §3) copies it to the stable path `~/Library/Application Support/reminder-calendar-control/bin/rcc`, **atomically**: write to a temp file in the same directory, `rename()` over the previous binary, so the path is never observed half-written.
3. The user runs `rcc setup` **from that stable path**. This single command: obtains the TCC grant (§6.2/§8.1), installs the `launchd` LaunchAgent pointed at that exact path (never a transient extraction directory), requests notification permission, provisions Keychain access (for Tier 1, if enabled — §11.2), and writes the `mcpServers` entry in `claude_desktop_config.json` pointing at that same stable path.

There is exactly **one authoritative file** for MCP, setup, and automation — the one at the stable path. This is why `.mcpb` packaging is deferred: MCPB's manifest describes a bundled server launched relative to the extension's own directory, with no defined arbitrary-install or post-install provisioning hook, and no mechanism preventing Claude Desktop from running a newer bundled copy while `launchd` still runs an older external one. Solving that properly means either a real signed installer/app or an explicit two-step "install extension, then run one setup command" flow — neither is worth building before the core tool works, for a tool with exactly one user. Milestone 5 (§18) is scoped accordingly: a working install script + one setup command, not a one-click claim.

**Updates:** repeat step 2's atomic replace, then run `rcc setup --verify` — a fast, idempotent check (not a full re-grant) confirming the TCC grant, LaunchAgent, and Keychain access still resolve correctly against the new binary's signature. `rcc doctor` reports the exact path, version, and signing identity of the binary currently serving MCP and confirms the LaunchAgent plist points at the identical path, so a partial/failed update is immediately visible rather than silently running mismatched versions.

**Uninstall:** removes the LaunchAgent and the `claude_desktop_config.json` entry, and — per the existing uninstall behavior — asks explicitly whether to preserve or delete persisted state (§16).

### 6.2 Self-disclaim mechanism & one-time guard

**[v4, corrected — the v3 description of this mechanism was a genuine bug: re-executing itself unconditionally at the top of `main()` on every launch means the replacement process also re-enters `main()` and re-executes again, forever.]**

At the very start of `main()`:

1. Check for a sentinel environment variable, e.g. `__RCC_DISCLAIMED=1`.
2. **If absent** (first invocation): resolve `rcc`'s own canonical executable path (via `_NSGetExecutablePath` + `realpath`, resolving symlinks — never trusted from `argv[0]` alone, which a caller can set to anything). Set the sentinel in the environment to be passed to the replacement image. Call `posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETEXEC)` and `responsibility_spawnattrs_setdisclaim(&attr, true)`, then `posix_spawn()` targeting that resolved path with the sentinel included in the environment. `POSIX_SPAWN_SETEXEC` replaces the calling process's image in place (same PID) — this is functionally equivalent to `execve`, so open file descriptors, the environment (plus the added sentinel), working directory, process group, and signal mask are inherited by construction; nothing needs separate handling for those. Any failure at any step of this sequence (attribute setup or the `posix_spawn` call itself) is treated as "mechanism unavailable," not ignored — see the degradation path below.
3. **If present** (this is the replacement image): skip straight to TCC-sensitive work. No second disclaim, ever.

This guarantees **exactly one image replacement per process lifetime**. Milestone 1's acceptance test (§18) asserts exactly one re-exec is observed in every real launch context (Terminal, manual config, LaunchAgent) — not just that the mechanism runs without crashing.

`rcc setup` itself goes through this same disclaimed image before requesting access — **[v4, corrected]** Terminal being the interactive host does not itself reinforce attribution; the entire point of self-disclaiming is that attribution no longer depends on the parent process's identity at all, Terminal included. Ensure the permission request happens before any EventKit fetch on that first run; if `rcc setup` has queried the store while authorization was still undetermined, recreate the `EKEventStore` (or call its `reset()`) after the grant lands, before using it for anything real.

**Degradation path [v4, new]:** this remains empirical, reverse-engineered behavior, not a documented Apple contract. The private symbol is resolved dynamically/weakly-linked. If it's unavailable — a future OS removes or restricts it — `rcc` is **non-functional**, not silently misattributing or falling back to a weaker mechanism, until a replacement approach ships. `rcc doctor` states this plainly. There is no fallback launch strategy that avoids depending on this mechanism; that's a deliberate, accepted single point of failure, which is exactly why §6.1's Milestone 1 gate must exercise the **final Developer ID-signed, Hardened Runtime-enabled, notarized artifact** — not a development/ad-hoc build — since community reports suggest this exact pattern can behave differently once hardened.

### 6.3 Signing, entitlements, and OS floor

- One canonical bundle identifier, Developer ID Team ID, and designated requirement for every physical copy of the binary — these are code-signing properties, distinct from the `Info.plist` purpose strings below.
- Embedded `Info.plist` (SwiftPM linker `-sectcreate __TEXT __info_plist`) declaring `CFBundleIdentifier` and, given the macOS 26 floor (§1), **only** the modern keys: `NSCalendarsFullAccessUsageDescription`, `NSRemindersFullAccessUsageDescription`. No legacy `NSCalendarsUsageDescription`/`NSRemindersUsageDescription` — there's no OS version in scope that needs them.
- **Hardened Runtime: enabled** (required for notarization). **App Sandbox: disabled.** This is deliberate, not an oversight: `rcc` is Developer-ID-distributed outside the Mac App Store, so sandboxing isn't required, and the raw `posix_spawn`-based self-disclaim in §6.2 depends on process-spawning capabilities that App Sandbox restricts — enabling it would likely break the one mechanism the whole permission story depends on.
- Access requests use the Swift API names — `requestFullAccessToEvents()` / `requestFullAccessToReminders()` (or their `completion:` forms) — not Objective-C selector spellings. Request only full access to both; there's no reason to request write-only event access when the whole point is reading and writing.
- The deprecated unified access API (`requestAccess(to:completion:)`) is consistently described as: on a modern SDK, it does not prompt and throws an error — **[v4, corrected]** not "silent no-op," which contradicted itself between two places in v3. It is simply never called by this codebase.

### 6.4 Threat-model boundary: callers and model-vs-human authority

**[v4, new — consolidating what was previously an unresolved flag in §12/§13.]**

- **Caller boundary (accepted, not solved):** any process running as the same logged-in OS user that can speak `rcc serve`'s stdio protocol can invoke its tools. This is true of essentially every local MCP server and CLI tool on the system and is not treated as a `rcc`-specific vulnerability to engineer around — it's explicitly out of scope (§3). What *is* in scope: `rcc`'s own TCC-authorized identity should not become an amplifier for a compromise that already has same-user code execution, which is why Tier 1's tool schema restriction (§11.2) and the CLI-only approval boundary (§8.3) are treated as correctness/authority boundaries, not just UX.
- **Model-vs-human authority, stated plainly:** in **live Claude Desktop chat**, `rcc` does not guarantee a per-call human confirmation — the operator has accepted Claude Desktop's own tool-confirmation policy, including the possibility of "Allow always" (§8.3). In **unattended automation**, no destructive/high-impact write ever executes without a human running `rcc automations approve` at the CLI — a boundary a model cannot invoke on its own initiative, because it is not exposed as a callable tool at all (§8.3). These are two different, deliberately different guarantees; nothing in this spec should imply the live-chat context has the automation context's enforcement, or vice versa.
- **Data leaving the machine, stated plainly:** `rcc` emits no independent product telemetry. Local state and logs remain on this Mac (§14). Data returned through the local MCP transport to Claude Desktop is processed according to the user's Claude plan and settings — that's the entire point of the tool, and is not a leak. A Tier 1 automation rule additionally sends only its previewed, user-enabled field projection to the configured Claude API endpoint directly (§11.2/§13).

## 7. Architecture

### 7.1 Single binary, multiple modes

- `rcc setup [--verify] [--uninstall] [--enable-tier1] [--rotate-key] [--dev]` — interactive, run manually in Terminal (§6.1/§6.2). `--enable-tier1` is the only path that provisions a Tier 1 API key; core setup never requires one (§11.2). `--dev` provisions a dedicated test calendar/list for §15.
- `rcc doctor [--json]` — signature/identity/entitlements, TCC authorization status, MCP registration state, LaunchAgent install/load state and path match against the running binary (§6.1), Keychain accessibility, notification permission state, native EventKit error passthrough for the last failure (§10.1).
- `rcc status` — quick health snapshot: schema versions, pending-approval count, last/next automation run, recent failures.
- `rcc serve` — MCP server over stdio; what Claude Desktop's config points at.
- `rcc automations {add, list, remove, edit, run, review, approve, reject, log}` — `edit` opens the rule's stored definition in `$EDITOR`, schema-validated on save (the normal path is describing the change to Claude in chat, which calls `update_automation`, §10). `approve`/`reject` are **CLI-only, human-run commands** — deliberately not exposed anywhere in the MCP tool surface (§6.4/§8.3).
- `rcc automations run [--dry-run] [--rule <id>]` — what `launchd` invokes on schedule (§11.3); `--dry-run` previews without staging or executing.

### 7.2 Process lifecycle

- `rcc serve` is spawned by Claude Desktop as a child process over stdio. **[v4, corrected]** Its correctness must not depend on undocumented assumptions about when or how often Desktop spawns/respawns it — Claude's own local-MCP documentation does not guarantee "spawn at startup, keep alive for the app's lifetime." `rcc serve` tolerates lazy launch, disconnect, reconnect, and multiple sequential sessions by construction (no in-memory state that isn't safe to lose — durable state lives in SQLite, §9.6); exact host respawn timing is tested per Desktop version (§15), not assumed.
- "Persistently available" is defined operationally: installed and enabled once; discoverable in a fresh conversation without re-editing config; restartable/reconnectable after a crash; durable state survives process restarts; no correctness depends on implicit MCP connection state surviving a restart.
- `rcc automations run` is invoked by a per-user `launchd` LaunchAgent on a schedule (§11.3) and exits when done.

### 7.3 Resource budget

**[v4 — replacing qualitative/literal claims with an actual benchmark matrix, per review.]** These are targets to measure on the real target Mac with the final signed artifact, not yet-measured guarantees, and not pass/fail claims until measured this way:

- **Fixed conditions:** target hardware, exact macOS 26.x point release, Release build configuration, the final Developer-ID-signed/notarized/Hardened-Runtime artifact (not a dev build) — §6.2's degradation note applies here too.
- **Idle:** mean and p95 CPU over a 60s idle window with a stated measurement tolerance (not a literal "0%" claim); steady-state RSS and post-24–72h-soak RSS.
- **Cold start:** `rcc automations run` no-op-rule cold-start-to-exit, p50/p95.
- **Read latency:** `list_events`/`list_reminders` p50/p95 at fixed dataset sizes, including a deliberately large-calendar case.
- **Response bounds:** maximum response bytes/items per page, and a request deadline/cancellation behavior for slow queries.
- **Automation:** wall-clock duration, energy/wake-up count, and (Tier 1) token/network/retry ceilings per firing.
- `launchd` wake frequency at default cadence (15–30 min) is **~50–100 launches/day — stated as a proposed tradeoff, not "zero-cost."** There is no resident process between firings (that part is genuinely free), but each launch itself has a nonzero, measured cost; if the measured Energy impact of that launch frequency conflicts with the resource-efficiency goal, the default cadence drops.
- Tier 1 cost ceiling: target under $0.01/firing on the default model — tracked per-run by actual model ID and token usage (§11.2), not assumed from a dollar figure alone, since pricing changes independent of this spec.

### 7.4 Concurrency & freshness model

- Each process (`rcc serve`, `rcc automations run`) holds exactly one `EKEventStore`, wrapped behind a single Swift actor so concurrent MCP requests are serialized rather than racing.
- Fetched `EKEvent`/`EKReminder`/`EKCalendar` objects are converted to value DTOs immediately and never retained across requests — Apple documents that objects fetched before an `EKEventStoreChanged` notification must be treated as stale afterward.
- `rcc serve` observes `EKEventStoreChanged` and invalidates cached values before serving the next read; every read hits EventKit fresh (no TTL cache in v1) — see §10 for what this means for pagination specifically.
- Persisted state (automation rules, pending actions, the operation journal in §9.6, audit log, opaque locators) lives in SQLite in WAL mode with a `schema_version` from day one — this is what makes atomic writes and a per-rule lease/lock achievable without hand-rolled file-locking.

## 8. Permissions & Security Model

### 8.1 The core problem: TCC "responsible process" reattribution

When Claude Desktop spawns `rcc` as a child process, macOS's TCC subsystem attributes the permission request to Claude Desktop's own identity, not `rcc`'s — and Claude Desktop's `Info.plist` doesn't declare Calendar/Reminders usage strings, so the request fails silently, with no prompt. **[v4, reworded]** This is **reproduced, version-specific behavior** documented in real bug reports (`anthropics/claude-code#63032`, `openai/codex#21228` — the same failure mode hits Codex Desktop) — not a universal result Apple or Anthropic formally documents, which is exactly why §6.1's release-gate test matrix (below) exists rather than trusting this description alone. Mitigation is the self-disclaim mechanism in §6.2.

**Release-gate test matrix:** verify access works from all real launch contexts — Terminal (`rcc setup`), manual `claude_desktop_config.json` child-process spawn, and the `launchd` LaunchAgent — plus fresh grant, denial, re-grant, revocation, app restart, machine reboot, binary replacement, and reinstall. A single long-lived `EKEventStore` per process (§7.4) avoids exhausting `calaccessd`'s connection limit. Headless calls (`rcc automations run`) fast-fail (~15s) rather than hang if a TCC prompt can never render in a **noninteractive background context** — **[v4, reworded]** a per-user LaunchAgent belongs to the logged-in user's launchd session even with no foreground UI; "no GUI session" undersells that it still can't safely depend on a prompt appearing.

If permission state gets stuck, `rcc doctor` documents the fix but never runs a global `tccutil reset Calendar`/`tccutil reset Reminders` without separate, explicit confirmation — prefer bundle-scoped resets.

### 8.2 Account & source scope

No special-casing needed in code — EventKit exposes accounts as `EKSource`s regardless of provider. There is no dedicated `EKSourceType` for Google (confirmed: the real cases are `.local`, `.exchange`, `.calDAV`, `.mobileMe`, `.subscribed`, `.birthdays`). A Google account added via macOS Internet Accounts most likely surfaces as `.calDAV`, but that specific mapping is an inference — confirm it empirically during Milestone 2 rather than asserting it as fact anywhere in code or user-facing text.

Test matrix: iCloud, configured Google (via CalDAV), plain CalDAV, Exchange if available, local ("On My Mac"), subscribed (read-only), and the birthdays calendar — full coverage of what EventKit exposes, not a promise every provider supports every write operation identically. Provider capability flags (§9.3) are surfaced per-object/per-source, and an unsupported field returns `unsupported` rather than being silently dropped.

### 8.3 Write-safety / confirmation model

**Unattended automation — always server-enforced, no exceptions, and the approval step is not model-callable.**

1. A prepare/stage step resolves current targets and produces an exact preview.
2. The server persists canonical arguments, the target's current `version`/`etag` (§9.4), an impact classification, an operation-journal entry (§9.6), an expiry, and an opaque approval handle.
3. A macOS User Notification summarizes what's pending (advisory only — notification delivery never gates whether the underlying staging happened, and is never itself treated as approval).
4. **[v4, corrected — this is the fix for the review's sharpest finding.]** The user approves/rejects **only** via `rcc automations approve <id>` / `reject <id>` at the CLI — a human physically at the keyboard. `approve_action`/`reject_action` are **not MCP tools** and never will be, in any context, including live chat: a model-callable approval tool doesn't prove a human approved anything, since a model could invoke it as part of an autonomous sequence or in response to prompt-injected content. Claude can (and should) surface pending items via the read-only `list_pending_actions` tool and tell the user which CLI command to run — it cannot execute the approval itself.
5. Execution re-resolves every target and requires `if_match` against the current `version`/`etag` (§9.4) — a changed or missing target produces `approval_stale`/`conflict` rather than acting on stale data. Approval is one-use and expires quickly.
6. **Impact matrix** decides what requires staging in the automation context: any deletion (single item or bulk); reminder-list deletion, restricted to reminder-only calendars (§9.3); recurring-event changes scoped `this_and_future`; moving an item between calendars/lists; clearing notes/alarms/recurrence/dates; a sequence of related single-item mutations proposed together. **[v4]** This impact matrix applies as described **only in the automation context**; the live-chat policy is separate (below) — a prior draft incorrectly implied `this_and_future` and list deletion were staged "regardless of context," which directly contradicted the live-chat policy stated in the same document. **[v4]** For **Tier 1 specifically**, every proposed write is staged regardless of impact level (§11.2) — the impact matrix's "non-destructive single create executes directly" carve-out applies only to Tier 0's fixed, user-authored rule actions, not to Tier 1's LLM-derived proposals.

**Live Claude Desktop chat — relies on Claude Desktop's own tool-confirmation UI, an accepted and explicitly unenforced tradeoff.** Destructive/bulk MCP tools are annotated `readOnlyHint`/`destructiveHint`/`idempotentHint`/`openWorldHint` as applicable, and where the client honors it, `_meta["anthropic/requiresUserInteraction"]: true` requests a forced per-call approval with no "always allow" bypass — confirmed for Claude Code, **not yet confirmed for Claude Desktop specifically** (verify empirically at Milestone 4; §17). **[v4, stated precisely]** The accurate claim is: *`rcc` does not guarantee a per-call human confirmation in live chat; the operator accepts Claude Desktop's current permission policy, including "Allow always."* MCP annotations are useful client UX metadata, not an authorization mechanism — the spec doesn't claim otherwise. This is an accepted trade-off for a single-operator tool, not an oversight; revisit if that ever changes. `this_and_future` recurring mutations and list deletion, in the live-chat context, execute directly subject to this same policy — **[v4]** consistent with every other high-impact op in live chat, resolving the earlier internal contradiction.

### 8.4 RSVP / participant-response limitation

Public EventKit provides no way, on native headless macOS, to change participation status or add/remove attendees: `EKParticipant.participantStatus` has no public setter; Apple's own documentation states EventKit "cannot add participants to an event nor change participant information"; `EKCalendarItem.attendees` is documented read-only; EventKitUI's RSVP-capable UI (`EKEventViewController`) is iOS/iPadOS/Mac Catalyst/visionOS only.

**Decision (confirmed with the user): drop RSVP writes entirely for v1.** Participation status is read-only data on events (§9.1/§10). A future, explicitly separate spike could investigate CalDAV/iTIP `REPLY` directly to the calendar server, bypassing EventKit — out of scope here.

## 9. Data Model

EventKit's own object model is rich enough that we expose it close to verbatim — completeness over invention. The server returns structured data; Claude presents it. **[v4]** Where a prior draft said "stable identifier(s)," the accurate phrase throughout is **identifiers and opaque locator (§9.4)** — no EventKit identifier is durably stable on its own.

### 9.1 Events (`EKEvent`)

title, notes, location (+ structured geo location if present), start/end, all-day flag, timezone, recurrence rule (§9.4's DTO), `occurrenceDate` and `isDetached` (distinguishing a modified single instance from the series), availability (busy/free/tentative/unavailable, **plus `.notSupported`** — **[v4, added]**), status (confirmed/tentative/canceled, **plus `.none`** — **[v4, added]**; only canceled status is reliably supported across sources, per Apple's own caveat), URL, calendar + source, created/modified timestamps, `birthdayContactIdentifier` when sourced from the Birthdays calendar, identifiers + locator (§9.4). All enums return both a normalized name and the raw value, so a future OS-added case remains representable rather than silently coerced.

Participants: name, participant **URL** (canonical; an email is *derived* only from a `mailto:` URL, never a native property), `isCurrentUser`, type, role, participation status (read-only, §8.4). Organizer, same shape.

Alarms: type (display/sound/email, **plus `.procedure`** — **[v4, added]**; macOS may expose an existing procedure-alarm even though its URL can't be viewed or newly created on modern macOS — an existing one is preserved unchanged, and a patch touching it returns a warning rather than silently dropping it), relative or absolute trigger, and for location-triggered alarms, the structured location's title/coordinates/radius and proximity.

### 9.2 Reminders (`EKReminder`)

title, notes, `startDateComponents`/`dueDateComponents` with original `DateComponents` fidelity (§9.5), completed flag + completion date, raw priority (0–9) plus a derived bucket (**[v4, spelled out]** 1–4 high, 5 medium, 6–9 low, 0 none — raw value always retained regardless of bucket), alarms (incl. location-triggered), recurrence rule (§9.4), URL, list (calendar) + source, creation/modification timestamps (inherited from `EKCalendarItem`, same as events), **`location` and `timeZone`** (**[v4, added]** — also inherited from `EKCalendarItem`, omitted from the v3 reminder field list), identifiers + locator (§9.4).

**Confirmed no native subtask support** (verified against Apple's docs). This is a real, permanent parity gap versus the Reminders app UI.

**Recurring-reminder limitation, restated precisely:** only the currently-exposed incomplete occurrence of a recurring reminder is fetchable at all; completing it may expose the next occurrence, which `complete_reminder`'s result returns when resolvable rather than leaving Claude to guess whether a "next one" exists.

### 9.3 Calendars/Lists (`EKCalendar`) and Accounts (`EKSource`)

Calendar: identifier, title, color, type, source, `isImmutable`, `allowedEntityTypes`, `allowsContentModifications` (item-level writability — distinct from whether the container itself can be renamed/deleted, which `isImmutable` and source capabilities govern), **`isSubscribed`** and **`supportedEventAvailabilities`** (**[v4, added]**).

Source: identifier, **`title`** (**[v4, added]**), source type (§8.2), `isDelegate` (verified real, public, read-only, macOS 13+ — true when the source represents a delegated/shared calendar account).

**[v4, new — reminder-list deletion guard.]** An `EKCalendar` can allow both event and reminder entity types; removing such a calendar can delete both its events and its reminders if the process has access to both, which a preview that only counts reminders would understate materially. For v1, `delete_reminder_list`/`update_reminder_list` operate **only** on calendars whose `allowedEntityTypes` is reminder-only — a mixed-entity calendar returns `unsupported`. Mixed-entity calendar deletion (as general calendar deletion, enumerating both event and reminder impact) is out of scope for v1.

### 9.4 Identifiers, versions & locators

- `calendarItemIdentifier`/`eventIdentifier` are **not durable long-term identifiers**: a full account sync can invalidate `calendarItemIdentifier`, `eventIdentifier` "most likely changes" when an event's calendar changes, and **[v4, added]** `calendarIdentifier` itself can also change after a full sync — no identifier in this object graph should be treated as permanently durable on its own.
- `calendarItemExternalIdentifier` can have duplicate values across calendars/sources in one database, and all occurrences of a recurring event share one external identifier.
- `EKEventStore.event(withIdentifier:)` returns only the first occurrence of a recurring series, never explicitly "the master."
- `predicateForEvents(withStart:end:calendars:)` silently truncates any range over four years to the first four years — no error thrown. `list_events`/`search_events` chunk a longer request transparently rather than silently returning a truncated range (§10).

**Opaque locators [v4, corrected — security/lifecycle semantics added.]** A locator is a **server-issued random handle**, recorded in a SQLite `locators` table (handle, calendar/source identity, `occurrenceDate` if recurring, issued-at, expiry, `schema_version`) — not a client-decodable token encoding those fields directly, which a caller (or prompt-injected model output) could otherwise fabricate or tamper with. Locators are invalidated wholesale on `EKEventStoreChanged` and expire independent of that. The server never resolves a mutation target by title/time fuzzy-matching, and never treats a bare `eventIdentifier` as sufficient on its own for a recurring item.

**Versions/`if_match` [v4, new.]** Re-resolving a locator only proves the target still *exists*, not that it's unchanged. Every mutable DTO carries a server-generated `version` (a hash of canonical content fields, combined with `lastModifiedDate` when EventKit provides it). `update_*`, `delete_*`, and staged-approval execution all require an `if_match: <version>` — a mismatch returns `conflict`, a missing target returns `not_found`, and a value the source doesn't populate (low-precision or absent `lastModifiedDate`) is documented per-source rather than silently treated as "always matches."

Recurring-event mutations require an explicit `recurrence_scope` (`this_occurrence` | `this_and_future`) — ambiguous requests are rejected. Creates and automation-triggered mutations accept an idempotency key (§9.6) retained for 30 days; replaying a key within that window returns the original recorded outcome rather than re-executing, even if the target has since changed. Outside the window, a reused key is a new operation.

### 9.5 Date/time & patch semantics

Instants: RFC 3339 plus the original IANA timezone identifier, never a bare UTC offset. All-day events: local calendar dates with an explicitly documented **exclusive** end date. Reminder start/due values preserve their original `DateComponents` granularity (date-only vs. date+time vs. floating) rather than being coerced to one representation. On `update_*`: an **omitted** field means unchanged; an explicit `null` means clear it.

**Recurrence rule DTO [v4, new — was previously "exposed" with no defined shape.]** frequency, interval, days-of-week/days-of-month/months-of-year, weeks-of-year, set positions, first day of week, and an end (a date, an occurrence count, or neither/never).

### 9.6 Operation journal & crash recovery

**[v4, new — SQLite can make its own rows atomic, but it cannot atomically commit an `EKEventStore.save`/`remove` call together with an audit entry, idempotency result, or schedule watermark. A prior draft claimed a "transactional commit" spanning both, which isn't achievable and needed replacing with something that's actually true.]**

Every mutating operation (live or automated) is tracked through a durable state machine, persisted **before** calling EventKit:

```
prepared -> executing -> succeeded
                     \-> failed
                     \-> outcome_unknown -> reconciled | needs_human_review
```

The canonical intent and idempotency key are persisted at `prepared`. After a crash mid-operation, `rcc` reconciles any `executing` row against live EventKit state on next start: if the outcome is unambiguous (the target clearly exists/doesn't exist in the expected post-write state), it's marked `succeeded`/`failed`; if it can't be determined unambiguously, it's marked `outcome_unknown` and **never automatically retried** — it surfaces via `rcc doctor`/`get_system_status` for a human to check. An idempotency-key row can legitimately record `outcome_unknown` itself; replaying that key must not trigger a blind retry (§9.4).

**Batch commit policy:** each item in a multi-item operation is committed to EventKit independently (`commit: true` per item, not a manually-batched `commit: false` sequence) and recorded in the journal per item — an item is never reported successful before its own commit succeeds. This is what makes the MCP layer's "best-effort, per-item results" promise (§10.1) actually true rather than aspirational.

**Retention:** the journal itself records identifiers, an operation hash, and outcome — not full note/content text (§13). Whether a "recorded outcome" needs to include enough content to support restoring a delete is a separate, explicitly deferred question — see §14 for why the audit log and a hypothetical restore feature are not the same thing.

## 10. MCP Tool Surface

Naming convention: `verb_noun`, plural for list operations, singular for single-item operations. List/search tools return compact summary projections by default; `get_*` tools return full detail. Non-EventKit-native filters (free-text, attendee match) are documented as post-fetch filters, applied **before** page construction so page semantics don't shift under a text filter.

**Pagination is best-effort, not a consistency boundary.** **[v4, reconfirmed as a deliberate v1 constraint, not silently contradicting the "complete" language elsewhere — see §2's correction.]** A page cursor encodes query parameters plus an offset/last-seen identifier, not a snapshot (§7.4's no-cache model). If the store changes between pages, later pages may include duplicates or skip items. A cursor additionally carries a store-generation marker; if the overall EventKit change-generation has advanced since the cursor was issued, the next page returns `cursor_stale` (**[v4, new error code]**) rather than silently returning a mismatched page — this doesn't make pagination a hard consistency boundary, but it at least surfaces gross staleness instead of hiding it. Claude should treat a paginated result as approximate under concurrent modification and re-query from scratch for a guaranteed-consistent view. A range exceeding the four-year predicate limit is chunked transparently into ≤4-year windows and walked as one continuous cursor-driven stream.

**Calendars & events**
- `list_calendars` — writability flags (§9.3).
- `list_sources`
- `list_events` / `search_events` — **require** a bounded date range (chunked automatically past four years, §9.4); paginated.
- `get_event`
- `create_event` — **[v4]** requires an explicit target calendar; no implicit default. A duplicate display name across calendars returns `ambiguous_target` with candidates.
- `update_event`, `delete_event` — require `recurrence_scope` on a recurring item and `if_match` (§9.4); high-impact mutations follow §8.3's per-context policy.
- Participation status is read-only data on `get_event` (§8.4). No `respond_to_event`.

**Reminders — an independent query contract from events [v4, corrected — "same contract as events" was wrong: many reminders have no due date, and a mandatory date range would make "all incomplete reminders" inexpressible.]**
- `list_reminder_lists`
- `list_reminders` / `search_reminders` — filters: list/calendar locator; completion state + completion-date range; an *optional* start/due component range that explicitly includes undated items when not specified; priority; text. Stable, documented ordering across floating/date-only/timed/undated items together. Same page-size/cursor contract as events, minus the mandatory range.
- `get_reminder`
- `create_reminder` — same explicit-target/`ambiguous_target` rule as `create_event`.
- `update_reminder` — `if_match` required.
- `complete_reminder` — kept distinct from a generic `update_reminder` because completing sets `isCompleted` and `completionDate` together as one semantic action, matching EventKit's own model, and returns the newly-exposed next occurrence when resolvable (§9.2).
- `delete_reminder` — `if_match` required.
- `create_reminder_list`, `update_reminder_list`, `delete_reminder_list` — restricted to reminder-only calendars (§9.3); deletion previews affected-item count before staging.

**Diagnostics**
- `get_system_status` — MCP-facing equivalent of `rcc doctor`/`status`.
- `list_pending_actions` — read-only; visible from `rcc serve`.

**Automation**
- `create_automation`, `list_automations`, `update_automation`, `delete_automation` — subject to the rule DSL constraints in §11.4.
- **[v4]** No `approve_action`/`reject_action` MCP tools exist, in any context (§8.3/§6.4). Approval is `rcc automations approve/reject` at the CLI, always.

### 10.1 Wire contract & error taxonomy

- Strict JSON Schema inputs, `additionalProperties: false`.
- Versioned `outputSchema` + `structuredContent`, wrapped in a common envelope: `schema_version`, `as_of`, `data`, `warnings`, pagination fields, capability metadata. `rcc serve` targets **MCP spec revision `2026-07-28`**; given how fast that spec has moved (three revisions in about a year), the server negotiates its protocol/capability version at connection per the spec's own version-negotiation mechanism rather than assuming any fixed revision is current, and documents the oldest revision it accepts from the shipping Claude Desktop client at implementation time.
- Domain/business-logic failures are returned inside a successful tool result with `isError: true`; malformed protocol-level requests use JSON-RPC errors. `stdout` is reserved exclusively for JSON-RPC; diagnostics go to `stderr`/unified logging.
- Stable error codes: `permission_not_determined`, `permission_denied`, `permission_restricted`, `read_only`, `unsupported` (an attempted RSVP write; `create_event`/`create_reminder` against a calendar whose `allowedEntityTypes` doesn't match), `not_found`, `ambiguous_target`, `conflict`, `invalid_datetime`, `approval_required`, `approval_stale`, `timeout`, `partial_failure`, `internal`, and **[v4, added]** `cursor_stale`, `outcome_unknown`, `needs_reconciliation`, `keychain_locked`, `notification_unavailable`, and a transient `provider_unavailable` for temporary source/account failures. Each includes `retryable`, remediation text, a correlation ID, and **[v4, added]** a `native_error` field carrying the underlying EventKit error domain/code where safe to expose — essential for diagnosing provider-specific failures rather than collapsing everything into one generic code.
- Multi-item operations are best-effort with per-item results (§9.6), not atomic across accounts/sources.
- A successful write is followed by a re-fetch of the canonical local object — this promises local EventKit persistence, not that remote account sync has finished.
- Heuristic filters are labeled as such: **[v4, added]** "no location or video-conferencing link" is a heuristic over URL/location/structured-location (and optionally notes) presence, with a provenance/confidence signal on the result — EventKit has no universal "meeting has a conference link" field, so this is pattern-matching, not ground truth.

## 11. Unattended Automation

### 11.1 Why not build on Anthropic's own scheduling

Researched directly, as of August 2026 — **[v4, reworded]** Anthropic's specific product names and scheduling surfaces (currently including Cowork scheduled tasks) are a moving target and this section should be re-read as a dated snapshot, not a permanent conclusion. The durable reasoning, independent of which product name is current: locally-added MCP servers are not reliably reachable from Anthropic-hosted scheduling surfaces, and even where a Desktop-local scheduling surface exists, it requires the Desktop app open and the machine awake. **Decision: automation is our own mechanism**, justified on durable properties — deterministic local execution, no dependency on Claude being open, zero token cost for Tier 0, independent failure handling — not on today's specific feature gaps, which may close.

### 11.2 Tiered execution model

**Tier 0 — deterministic rules, no LLM.** A versioned, **allowlisted declarative rule DSL** — **[v4, new constraint]** bounded predicates and actions only; explicitly **no** shell, AppleScript, SQL, arbitrary expressions, or executable templates. Each rule declares: timezone, schedule, `misfire_policy` (`skip` | `run_once` | bounded catch-up), `max_lateness`, a maximum fan-out, a destination allowlist, and a `schema_version`. Non-destructive single-item creates from a Tier 0 rule execute directly — the action was fixed by the user at rule-authoring time, not derived from untrusted content at trigger time.

**Tier 1 — LLM-in-the-loop judgment.** Calls the Claude Messages API directly with a fixed system prompt and the same CRUD tools available anywhere else. **[v4, every proposed write stages — no carve-out.]** Unlike Tier 0, **every** Tier 1-proposed write is staged for human approval regardless of impact level, because its proposals are derived from untrusted calendar text at trigger time — the prompt-injection surface a fixed Tier 0 rule simply doesn't have. `approve_action`/`reject_action` remain absent from its tool schema and from the MCP surface entirely (§8.3/§6.4).

Additional Tier 1 bounds **[v4, new]:**
- The API key is provisioned only via explicit `rcc setup --enable-tier1`; core setup never requires one.
- Keychain access is tested from the actual `launchd`-spawned LaunchAgent identity specifically — with the login keychain locked, after binary replacement, and after a signing-certificate change — since "provisioned during an interactive GUI session" does not by itself guarantee later noninteractive access holds.
- Each rule stores a pinned model policy, token ceiling, timeout, and retry ceiling, and a maximum input field projection — no automatic escalation to a costlier model unless the rule explicitly permits it.
- Every run records the actual model ID, token usage, and cost — a dollar-only ceiling isn't sufficient on its own since pricing changes independent of this spec.
- Notification authorization and delivery are verified from the final signed headless artifact specifically; a notification remains advisory output, never itself an approval mechanism.

### 11.3 Trigger mechanism & scheduling

`EKEventStoreChanged` is in-process only — it can't wake a stopped process the way `launchd WatchPaths` can. Genuine reactivity would need a resident LaunchAgent with a standing memory baseline; given the resource-efficiency goal and no sub-minute latency requirement, **v1 polls** with zero resident cost between firings.

**Single scheduling strategy:** one base `launchd` LaunchAgent on a fixed cadence (default 15–30 min, configurable) invokes `rcc automations run` with no arguments; `rcc` reads each rule's persisted `next_due_at` from SQLite and executes whichever are due — not a generated LaunchAgent per rule.

Runtime edge cases, made explicit: a LaunchAgent runs only within the user's login session, not while logged out. Missed firings (sleep through a slot) are coalesced by `StartCalendarInterval` into one run on wake, not stacked. **[v4, added]** DST gaps/repeats, timezone changes, and clock rollback are handled per-rule via the stored timezone and `misfire_policy` above — a rule due during a DST-skipped hour follows its declared `misfire_policy` rather than an undefined default. Double-firing is guarded by a per-rule lease (TTL + heartbeat + owner identity, with defined stale-lease recovery — **[v4, added]**); a rule already running is skipped, not run concurrently with itself. Retries follow a documented count/backoff-with-jitter policy and only for failures classified as `retryable`. Every journal transition (§9.6), not just a week-long happy-path soak, is a fault-injection test target (§15).

Headless EventKit calls fast-fail on an unrenderable TCC prompt (§8.1) rather than hanging a scheduled run indefinitely.

### 11.4 Defining automations

The user describes an automation in normal conversation; Claude calls `create_automation`, which writes a structured, versioned rule (constrained by §11.2's DSL) to the SQLite store. `rcc automations run --dry-run --rule <id>` previews a rule without staging or executing.

Digest-style output (a morning summary, a "flagged meetings" result) isn't a mutation, so it doesn't stage — it's written to a dated automation-log entry (§14) and delivered via a macOS User Notification, advisory only; if notifications are denied, the automation still runs and logs.

### 11.5 Concrete automations (design targets, not exhaustive)

**Tier 0:** nightly cleanup of completed reminders older than N days (staged — deletion); flag meetings with no location and no video-conferencing link (a heuristic, §10.1); flag back-to-back meetings with zero buffer; detect duplicate events; auto-tag/move events by title keyword.

**Tier 1 (every write staged, §11.2):** morning digest with real agenda-gap flagging; night-before-trip packing-list reminder inferred from travel context; flag (not auto-decline) invites conflicting with protected time; periodic review of stale, untouched reminders.

## 12. iOS Parity Matrix

**Methodology:** distinguish documented Claude-iOS behavior, independently observed (third-party) behavior, public EventKit capability/limitation, and this project's own planned behavior — don't read every row as equally authoritative.

| Capability | Claude for iOS | This project | Basis |
|---|---|---|---|
| Read calendar events | Yes | Yes | Documented |
| Create calendar events (incl. recurring) | Yes | Yes | Documented |
| Edit calendar events | Only if user owns/organized, per Anthropic's docs | Match the **documented ownership limitation** (**[v4, reworded]** — Anthropic doesn't document its internal implementation as literally identical to our EventKit constraint, only the observable behavior) | Documented |
| Delete calendar events | **[v4, reworded]** Anthropic's guide mentions edit/delete capability without detailing the exact flow — documented-but-unverified, not "not documented" | Yes (Desktop-confirmation-gated) | Documented (ambiguous) + Planned |
| Respond to invitations | Not documented | **Not supported — public EventKit cannot do this at all** (§8.4) | EventKit-constrained |
| Read reminders | Yes | Yes | Documented |
| Create/update/delete reminder items | Yes | Yes | Documented |
| Reminder due dates & recurrence | Yes | Yes | Documented |
| Reminder priority | Claimed in Anthropic's docs, not observed in independent testing | Yes (EventKit exposes it natively) | Documented (disputed) + EventKit-confirmed |
| Create/edit reminder **lists** | **No** | Yes — exceeds iOS | Planned |
| Tags / subtasks / rich links | **[v4, reworded]** Not documented (not proven absent) for iOS | Tags via hashtag convention; subtasks **confirmed absent from public EventKit entirely** | Documented (uncertain) + EventKit-constrained |
| Unattended automation | **[v4, reworded]** The native Calendar/Reminders integration itself has no unattended mode; separately, Claude's App Intents can participate in user-triggered Shortcuts automations — a different mechanism from this project's unattended EventKit automation | Yes — exceeds iOS's native integration | Documented + Planned |
| Per-action permission granularity | **[v4, reworded]** Official docs describe contextual "Allow once / Always allow / Don't allow" prompts, not a proven granular per-CRUD-action matrix | Handled via §8.3's tiering | Documented (narrower than previously stated) |

A dated parity test corpus — default calendar/list selection, duplicate destination names, date-only reminders and all-day events, timezones/DST, recurring creates and scoped edits/deletes, owned-vs-invited events, read-only calendars/lists, confirmation behavior — run against a recorded Claude-iOS app version/OS version/plan, is worth building before claiming parity in practice; Anthropic's mobile behavior is also actively changing.

## 13. Privacy & Threat Model

**[v4, corrected — the previous claim overreached.]** The accurate framing:

> `rcc` emits no independent product telemetry of its own. Local state and logs remain on this Mac. Data returned to Claude Desktop through the local MCP transport is processed according to the user's Claude plan and settings — that's the tool's entire purpose, not a leak. A Tier 1 automation rule additionally sends only its previewed, user-enabled field projection to the configured Claude API endpoint directly.

A short data-flow table belongs here at implementation time: EventKit → `rcc` (local only) → MCP transport → Claude Desktop/model processing (governed by the user's Claude plan, not this spec) → optionally, Tier 1's separate direct API call (governed by §11.2's per-rule opt-in and field allowlist) → notifications/Keychain/local logs (this Mac only, with retention and controls as described in §14).

Other elements, unchanged in substance from v3: calendar/reminder text is untrusted data, never instructions, regardless of how directive it reads; returned URLs are never dereferenced by the server; list tools default to compact fields, with notes/attendee URLs/precise locations requiring explicit inclusion; local transport is stdio-only, no listening socket; local state is mode `0700`, files `0600`; logs redact user content/secrets by default (§14). **[v4]** The confused-deputy question is addressed directly in §6.4 rather than left open. **[v4]** Tier 1's enforcement is no longer just a stated intent — §11.2's "every write staged, regardless of impact" is the actual mechanism that keeps prompt-injected calendar text from becoming an unattended write with nobody checking it; §8.3 records the same constraint as a locked decision, not just a threat-model aspiration.

## 14. Observability & Audit

- Structured logs to `~/Library/Logs/reminder-calendar-control/`, per-run for automation, with secrets/user-content redaction by default. **[v4, added]** Log/notification/preview text is truncated and control-character-sanitized before display or storage.
- An audit log (in SQLite) of every write operation — execution context (`live`/`tier0`/`tier1`/`cli`), target identifiers, an operation hash, the approval handle if involved, and outcome. **[v4, corrected — "append-only" describes an application-level invariant (the app never issues UPDATE/DELETE against this table), not tamper-evidence; that would need a hash chain or external integrity boundary, not planned for v1.]**
- **[v4, corrected — resolves a direct self-contradiction in v3.]** This audit log deliberately does **not** store full note/content text, by design (§13's minimization stance) — which means it does **not**, by itself, support restoring a deleted item's content. A prior draft claimed both minimization and restore-capability from the same log, which can't both be true. A genuine "restore last N deletes" feature, if ever built, requires a **separate, explicitly opt-in, short-retention deletion-tombstone store** with its own access controls, size limits, and purge behavior — not implied by the audit log, and not committed for v1.
- `rcc automations log` surfaces history at the CLI; `get_system_status` surfaces a summary to Claude.
- Log rotation and retention are defined at implementation time, separate from the audit log's own retention.

## 15. Testing Strategy

- **[v4, added]** EventKit has no first-party in-memory store, but the application defines its own **EventKit-repository protocol with an in-memory fake** behind it — real EventKit is reserved for adapter/integration tests only. This makes tool schemas, date/recurrence decisions, locators, the operation journal, rule evaluation, prompt-injection policy, audit redaction, and crash recovery all deterministically unit-testable without touching a real calendar.
- `rcc setup --dev` provisions a dedicated, uniquely-named, tool-owned test calendar and reminder list; tests refuse to delete anything not owned by that fixture and offer explicit cleanup. Destructive TCC/provider tests run on a disposable macOS account or VM snapshot, not the primary account.
- CI is explicitly deferred for anything touching live EventKit/TCC (the headless-TCC-hang failure mode is its own unsolved problem upstream); non-EventKit logic is unit-tested normally against the repository fake above.
- Test suites, expanded **[v4]**: fresh/denied/restricted/revoked TCC, missing private symbol, exactly-one-reexec (§6.2), binary replacement, reinstall, reboot, OS update; concurrent MCP + automation writes, `EKEventStoreChanged`, stale `if_match`, stale approvals, stale cursors, ambiguous destinations; crash injection at every operation-journal transition, including an EventKit-success/SQLite-failure fault specifically; date-only/floating/all-day/DST/recurring-scope/recurring-reminder-completion/provider-field-loss cases; large datasets, cancellation, timeouts, pagination, post-filtering, stdout purity, partial-batch failures; sleep/wake, logged-out state, Keychain lock, notification denial, API timeout/rate limit, clock changes; malicious titles/notes/attendee fields/locations/URLs attempting exfiltration, cross-tool invocation, mutation, or approval; log/notification truncation and control-character sanitization; upgrade, downgrade refusal, migration rollback, uninstall with preserved/deleted state.

## 16. Operability

- `rcc doctor [--json]` / `rcc status` — diagnostics and health snapshot, including which exact binary path/version/signature is serving MCP vs. what the LaunchAgent runs (§6.1), so a split-version install is immediately visible.
- `rcc automations run [--dry-run] [--rule <id>]`.
- LaunchAgent install/status/uninstall are idempotent operations.
- SQLite schema migrations are versioned; `rcc setup --uninstall` offers backup/export before removing state and asks explicitly whether to preserve or delete it.
- Stable CLI exit codes distinct per failure category (permission, network/API, validation, internal).

## 17. Open Risks / Unknowns

- Whether Claude Desktop specifically honors `_meta["anthropic/requiresUserInteraction"]` is unconfirmed (documented for Claude Code, not Desktop) — verify at Milestone 4; the accepted fallback (Desktop's ordinary confirmation UI, explicitly not guaranteed, §8.3) already covers this either way.
- The Google-surfaces-as-`.calDAV` mapping (§8.2) is a reasonable inference, not documented — confirm against a real account early.
- MCP client support for elicitation and forced-confirmation mechanisms is inconsistently documented across clients as of this research pass — don't assume today's behavior is stable.
- **[v4]** The self-disclaim mechanism's behavior specifically under the final Hardened Runtime/notarized artifact is unverified until Milestone 1 exercises that exact artifact, not a dev build (§6.2) — treat the whole permission story as unproven until that gate passes.
- **[v4]** Best-effort pagination (§10) is a deliberate v1 trade-off, not a solved problem — a future version could adopt a stable keyset + store-generation model with a real `cursor_stale` boundary instead of the lighter-weight staleness signal specified here, if concurrent-modification-during-pagination turns out to matter more in practice than expected for a single-user tool.
- EventKit has reported regressions on recent OS point releases for specific write operations (moving an event between calendars, detaching a recurring instance) with no published fix at time of research — the error taxonomy (§10.1) and operation journal (§9.6) matter more than assuming success.
- Anthropic's own scheduling surfaces and product names are moving quickly (§11.1) — revisit periodically.
- Long-uptime memory growth in EventKit-holding processes has been reported anecdotally; §7.3's soak test is how this gets confirmed or ruled out here specifically.

## 18. Milestones

Each has a one-line acceptance criterion. **[v4 — Milestone 1 now includes packaging/topology decisions and the mutation journal moved into Milestone 2, per review; Milestone 4's acceptance criterion no longer asserts forced confirmation was "achieved," since that's not what's being built for live chat.]**

1. **Platform & packaging proof** — self-disclaim mechanism with its one-time guard (§6.2), signing/entitlement profile (§6.3), one authoritative install/update path (§6.1), TCC grant working from all real launch contexts, against the dedicated dev calendar/list. *Done when: a fresh install can read and write the dev calendar/list from Terminal, manual config, and a LaunchAgent, with `rcc doctor` reporting healthy and exactly one re-exec observed in each context — using the final signed, notarized, Hardened-Runtime artifact, not a dev build.*
2. **Core model & mutation journal** — `EKEventStore` actor, DTO conversion, opaque server-issued locators, `version`/`if_match`, recurrence-scope handling, the operation journal (§9.6), versioned schemas, error taxonomy, idempotency keys. *Done when: the identifier/recurrence/crash-recovery fixtures in §15 pass without needing MCP or Claude Desktop involved at all, including a simulated EventKit-success/journal-failure fault.*
3. **Read path** — `list_calendars`, `list_sources`, `list_events`, `get_event`, `list_reminder_lists`, `list_reminders` (its own query contract, §10), `get_reminder`, pagination with `cursor_stale`, bounded/chunked event ranges, over `rcc serve`. *Done when: a real Claude Desktop conversation gets a correctly-paginated, freshly-fetched answer about events and reminders, and the pagination contract's best-effort behavior has been exercised under a deliberate concurrent edit, not just the happy path.*
4. **Safe write path** — full event + reminder CRUD (minus RSVP), reminder list management (reminder-only-calendar guard, §9.3), the impact matrix and staging flow, `if_match` enforcement, and the `requiresUserInteraction` empirical check against Claude Desktop. *Done when: creating, editing, and deleting real events/reminders works end-to-end in live chat, and Claude Desktop's actual confirmation behavior for a destructive call has been directly observed and documented — not assumed to be forced confirmation if it turns out not to be.*
5. **Release proof** — install-script-plus-setup-command flow (§6.1, explicitly not a `.mcpb` one-click claim for v1), update/uninstall, the provider/source test matrix, the iOS parity corpus, the resource benchmark matrix (§7.3). *Done when: install-then-`rcc setup` reliably produces a working tool, uninstall cleanly removes or preserves state on request, and measured resource use is reported against every §7.3 target — not just claimed.*
6. **Automation Tier 0** — normative rule DSL, SQLite-backed scheduling with leases and `misfire_policy`, staged-approval flow (CLI-only, §8.3), audit log. *Done when: a nightly cleanup rule and a "flag meetings with no location" rule both run unattended for a week without double-firing, silent failure, or an unstaged destructive action — and a crash injected at each journal transition recovers correctly, not just the happy-path week.*
7. **Automation Tier 1 (separately opt-in)** — `rcc setup --enable-tier1`, every proposed write staged regardless of impact, per-rule model/token/cost policy, Keychain access verified from the actual LaunchAgent identity. *Done when: a morning-digest rule runs unattended within the §7.3 cost ceiling, produces zero unstaged writes even under adversarial calendar-text input, and enabling/disabling Tier 1 for one rule doesn't touch any other rule's behavior.*
