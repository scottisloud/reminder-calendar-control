# Milestone 1 — Platform & packaging proof

SPEC §18, Milestone 1:

> **Platform & packaging proof** — self-disclaim mechanism with its one-time guard (§6.2),
> signing/entitlement profile (§6.3), one authoritative install/update path (§6.1), TCC
> grant working from all real launch contexts, against the dedicated dev calendar/list.
> *Done when: a fresh install can read and write the dev calendar/list from Terminal,
> manual config, and a LaunchAgent, with `rcc doctor` reporting healthy and exactly one
> re-exec observed in each context — using the final signed, notarized, Hardened-Runtime
> artifact, not a dev build.*

Everything below was verified empirically on macOS 26.6.2 (build 25G83), arm64, Xcode 26
toolchain, Swift 6.2.3, SDK 26.2.

---

## 1. The blocker, stated plainly

Two blockers, both traced back to the same missing thing. The second was found by running
the acceptance flow on the real machine, and it invalidates a decision SPEC §4 lists as
already locked.

### 1.0 The self-disclaim mechanism prevents the TCC grant it exists to enable

**This is the headline finding, and it is reproducible.** With the disclaim active, EventKit
returns `granted = false` with a `nil` error, *instantly and with no dialog*. With the
disclaim skipped, the identical binary run from the identical Terminal prompts normally and
is granted.

Two runs, same Terminal window, seconds apart, two freshly built binaries with distinct
bundle identifiers so both started at `notDetermined`:

```
A: bare executable, DISCLAIMED
   pid=83318 responsible=83318 bundleID=com.scottlougheed.rcc-probe-bareA disclaimed=true
   before: event=0 reminder=0
   completion fired=true granted=false error=nil          <- no dialog ever appeared
   after:  event=0 reminder=0

B: bare executable, NOT DISCLAIMED
   pid=83395 responsible=79759 bundleID=com.scottlougheed.rcc-probe-bareB disclaimed=false
   before: event=0 reminder=0
   completion fired=true granted=true error=nil           <- dialog appeared, Allow clicked
   after:  event=3 reminder=0                             <- 3 = fullAccess
```

The same `granted=false, error=nil` result was reproduced for `rcc` itself and for
standalone probes across **three** launch contexts — a shell spawned by Claude Code, a
`launchctl`-kickstarted LaunchAgent, and a real Terminal window — and for both a bare
Mach-O and a headless `.app` bundle. Two `open`-launched variants did briefly succeed, and
two others failed with `EKCADErrorDomain Code=1015 "XPC error communicating with
calaccessd"`; that inconsistency is itself part of the picture.

**Best explanation, strongly supported but not proven:** tccd will not record a grant
against a responsible process whose designated requirement is a bare `cdhash`. Disclaiming
makes `rcc` its own responsible process; ad-hoc signing gives it a cdhash-only requirement;
so there is nothing durable for tccd to key a grant to, and it denies immediately rather
than showing a dialog nobody could honour. Not disclaiming hands responsibility to
Terminal.app — Developer-ID-signed, stable identity — and everything works. This also
explains the intermittent `calaccessd` XPC failures, and it is consistent with the prior
art in SPEC §5 all being signed and notarized.

Proving it requires a Developer ID certificate, which is the same thing §1.1 is blocked on.
**Until one exists, both halves of Milestone 1's acceptance criterion are gated on the same
purchase.** Nothing else in the implementation is blocked.

If the explanation turns out to be wrong — if a Developer-ID-signed `rcc` still cannot get a
grant while disclaimed — then SPEC §4's locked "Language/runtime: native Swift, headless
CLI" plus §6.2's disclaim are incompatible on macOS 26, and the packaging decision in §6.1
has to be reopened. That is worth knowing before Milestone 2 rather than after Milestone 5.

### 1.1 No code-signing identity, so no notarized artifact


**This machine has no code-signing identity**, so the artifact the acceptance criterion
names cannot be built here:

```
$ security find-identity -v -p codesigning
     0 valid identities found
```

| Requirement | Status | Why |
|---|---|---|
| Hardened Runtime | **done** | `codesign -s - -o runtime` → `flags=0x10002(adhoc,runtime)` |
| Embedded `Info.plist` sealed into the signature | **done** | `Info.plist entries=8`, signing identifier derived from `CFBundleIdentifier` |
| Self-disclaim under Hardened Runtime | **done** | verified identical behaviour ad-hoc + `-o runtime`, and inside a signed `.app` |
| Developer ID signature | **blocked** | no certificate |
| Notarization | **blocked** | needs a Developer ID; `notarytool` also refuses a bare Mach-O — it wants a `.zip`, `.pkg`, or `.dmg` |
| Stapled ticket | **blocked** | `stapler` cannot staple a flat Mach-O at all; it needs a bundle, `.pkg`, or `.dmg` |

So Milestone 1 is split:

* **M1a — delivered here.** Everything a certificate is not required for: the disclaim
  mechanism and its guard, the install topology, `rcc doctor`, the dev fixtures, the
  EventKit adapter, the MCP server, and the acceptance harness itself, all against an
  **ad-hoc-signed, Hardened-Runtime** artifact at the authoritative install path.
* **M1b — outstanding, gated on an Apple Developer ID.** Obtain the grant, then run the
  three-context acceptance matrix against a Developer-ID-signed, notarized artifact.
  `Scripts/sign.sh --notarize` is written and ready; it refuses to notarize an ad-hoc
  signature rather than pretending.

**The acceptance matrix has been written but not passed**, because §1.0 blocks the grant
it depends on. `Scripts/m1-acceptance.sh` runs end to end and reports the failure honestly;
it has not been given a green run and this document does not claim one.

**M1b is a prerequisite for shipping, not for starting Milestone 2.** The permission story
should not be called proven until it passes.

### Consequence you have to live with until then

An ad-hoc signature's designated requirement is a bare content hash:

```
$ codesign -d -r- ~/Library/Application\ Support/reminder-calendar-control/bin/rcc
# designated => cdhash H"…"
```

TCC re-validates the running binary against the requirement recorded at grant time, so
**every rebuild invalidates the Calendar and Reminders grants** and macOS re-prompts. Same
for the Keychain ACL that Tier 1 will need in Milestone 7. Under a Developer ID the
requirement becomes `identifier "…" and anchor apple generic and … subject.OU = <TEAM>`,
which survives rebuilds.

`Scripts/install.sh` prints a warning when the installed code hash changes, and
`rcc doctor` says so on every run, so this reads as expected rather than as a bug.

---

## 2. What was built

| Area | Where |
|---|---|
| Self-disclaim + one-time guard | [`Sources/RCCBootstrap/Disclaim.swift`](../Sources/RCCBootstrap/Disclaim.swift), [`Sources/CDisclaim/`](../Sources/CDisclaim/) |
| Embedded `Info.plist` | [`Resources/rcc-Info.plist`](../Resources/rcc-Info.plist), linker flags in [`Package.swift`](../Package.swift) |
| Install topology | [`Scripts/install.sh`](../Scripts/install.sh), [`Sources/RCCCore/Paths.swift`](../Sources/RCCCore/Paths.swift) |
| Signing / notarization | [`Scripts/sign.sh`](../Scripts/sign.sh), [`Scripts/build-release.sh`](../Scripts/build-release.sh) |
| `rcc doctor` | [`Sources/RCCDiagnostics/Doctor.swift`](../Sources/RCCDiagnostics/Doctor.swift) |
| Dev calendar & list | [`Sources/RCCCalendar/DevFixture.swift`](../Sources/RCCCalendar/DevFixture.swift) |
| EventKit adapter + in-memory fake | [`Sources/RCCCalendar/`](../Sources/RCCCalendar/) |
| MCP stdio server | [`Sources/RCCMCP/`](../Sources/RCCMCP/) |
| LaunchAgent, Claude Desktop config, Keychain, notifications | [`Sources/RCCPlatform/`](../Sources/RCCPlatform/) |
| Acceptance matrix | [`Scripts/m1-acceptance.sh`](../Scripts/m1-acceptance.sh) |

Out of scope for Milestone 1 and deliberately absent: the event/reminder CRUD tool surface
(§10, Milestones 3–4), the operation journal and opaque locators (§9.6, Milestone 2), and
automation (§11, Milestones 6–7). `rcc automations run` exists only because the LaunchAgent
installed by `rcc setup` points at it, and it is a logged no-op.

### The optional app bundle

`Scripts/make-app-bundle.sh` produces `RCC.app` — the same binary, wrapped, with the app
icon in `Contents/Resources`. It is `LSBackgroundOnly` and `LSUIElement`: no dock tile, no
menu bar item, no windows. SPEC §3's "not a GUI app" still holds; this is a packaging shape,
not an interface.

Two reasons it exists:

* **A bare Mach-O cannot carry an icon.** macOS reads it from
  `Contents/Resources/<CFBundleIconFile>.icns`; there is no linker section for icon data.
  The TCC dialog and the System Settings › Privacy entry both render that icon, so once the
  grant works, this is the difference between a recognisable entry and a generic one.
* **UserNotifications is unreachable without a bundle** (§5.10a), so the notification
  responsibility SPEC §6.1 assigns to `rcc setup` needs this shape eventually.

**It does not fix the TCC blocker, and was measured not to.** Probe C in §1.0 was exactly
this: a headless `.app`, disclaimed, exec'd directly — `granted=false`, no dialog. Do not
reach for the bundle expecting it to unblock the milestone.

The bare binary stays the default install for a concrete reason: replacing a single file is
a true atomic `rename()`, so the path is never observed half-written (SPEC §6.1). A
directory cannot be renamed over a non-empty directory, so `install.sh --bundle` moves the
old bundle aside first — leaving a brief window where the path does not exist. That is worse
than the bare install, and worth keeping as the non-default until there is a reason to
prefer the bundle.

`rcc doctor` gains an `install_shape` check that reports which shape is present, whether the
icon is there, and — importantly — warns when *both* are installed, since that is exactly
the split install §6.1 exists to make visible.

---

## 3. The disclaim mechanism, and a bug in the spec's version of it

SPEC §6.2 specifies a boolean sentinel: set `__RCC_DISCLAIMED=1`, and skip the disclaim if
it is present. **That is exploitable, and it fails silently.** Verified:

```
$ env __RCC_DISCLAIMED=1 ./probe
second image, pid=88462, generation=1
[after] responsibility_get_pid_responsible_for_pid(getpid()=88462) -> 39252
```

The process skipped the disclaim, ran fully misattributed to its ancestor, and reported
success. Any parent — including a compromised one — can set that variable.

What is implemented instead:

1. The sentinel is `__RCC_DISCLAIM_GEN=<pid>:<generation>`. `POSIX_SPAWN_SETEXEC` preserves
   the pid, so a value whose pid field is not ours is provably foreign and ignored.
2. It is `unsetenv`'d immediately, so it never leaks into child processes.
3. The authoritative check is not the sentinel at all — it is
   `responsibility_get_pid_responsible_for_pid(getpid()) == getpid()`. That is what catches
   a forged sentinel *and* the case where a future OS keeps the symbol but makes it a no-op.
4. Failure is closed, at **every** entry point. `mechanismUnavailable`,
   `mechanismRejected`, `notDisclaimed`, `spawnFailed`, `pathUnresolved`, and
   `guardViolated` all block TCC-touching work through a single `DisclaimGate`, which
   `rcc setup`, `rcc selftest`, and the MCP `run_platform_selftest` tool all pass through.
   There is no fallback that runs undisclaimed. `rcc serve` deliberately still *starts* in
   that state — a server that exits immediately gives Claude Desktop nothing to show —
   but every EventKit-touching tool refuses, and `get_system_status` reports why.

SPEC §6.2 also says open file descriptors "are inherited by construction; nothing needs
separate handling for those". Two corrections, both verified:

* `FD_CLOEXEC` / `O_CLOEXEC` descriptors are **closed** by the image replacement (`pread`
  → `EBADF`), and Swift's `FileHandle`, `URLSession`, and libdispatch sources all set it.
* Buffered stdio is **discarded** — an unflushed `printf` from the first image vanished
  entirely under redirection. Installed signal handlers reset to `SIG_DFL`.

Hence: `Disclaim.ensure()` is the first statement in `main.swift`, before any file is
opened, and it calls `fflush(nil)` before the spawn.

One more thing the spec does not mention, which is good news: after disclaiming, `rcc`
becomes the responsibility **root for its own children**, so anything it spawns is
attributed to `rcc` rather than to Claude Desktop.

### Observing "exactly one re-exec"

Three independent signals, all used by `Scripts/m1-acceptance.sh`:

1. **stderr**, unbuffered, one line per image:
   `RCC_DISCLAIM event=reexec …` then `RCC_DISCLAIM event=result gen=1 …`.
2. **Unified logging**, for contexts where stderr is not captured:
   ```bash
   log show --last 2m --style compact --predicate 'subsystem == "com.scottlougheed.reminder-calendar-control"'
   ```
3. **Exit code** — `rcc selftest --disclaim-only` exits 0 only when generation is 1 and the
   process is responsible for itself, and `8` (`disclaim_unavailable`) otherwise.

Do **not** use `EKEventStore.authorizationStatus(for:)` as the signal. Verified: it reads
`notDetermined` both before and after the disclaim, bare and inside a signed `.app`. It
discriminates nothing.

---

## 4. Running the acceptance matrix

```bash
./Scripts/install.sh
"$HOME/Library/Application Support/reminder-calendar-control/bin/rcc" setup --dev
./Scripts/m1-acceptance.sh
```

`setup` must run from the installed path. macOS records the grant against the binary that
asked for it, so granting from `.build/` grants it to a copy nothing else runs; `rcc setup`
refuses to run from anywhere else unless you pass `--allow-any-path`.

**As of this commit the harness does not pass**, because `rcc setup` cannot obtain the
Calendar grant (§1.0). It runs to completion and reports exactly which assertions failed;
that output is the current honest state of the milestone, not a green tick.

Per launch context — Terminal, an MCP child process over stdio, and a launchd LaunchAgent —
it asserts exactly one `RCC_DISCLAIM event=reexec` line, `generation == 1`,
`responsible_pid == pid`, and an event and a reminder written to the dev fixtures, read
back, and deleted. It then checks `rcc serve`'s wire behaviour (three responses for four
frames, since a `notifications/initialized` notification must never be answered; every
stdout line parsing as JSON), `rcc doctor` reporting no failing checks, and SPEC §16's
exit-code contract.

What currently passes, and what does not:

```
  FAIL  terminal:     Not authorized for Calendar: notDetermined (raw 0)
  PASS  terminal:     exactly one 'reexec' line on stderr
  PASS  mcp:          3 responses for 4 frames (the notification was correctly not answered)
  PASS  mcp:          every stdout line parses as JSON
  FAIL  mcp:          No event dev fixture exists, and this caller may not create one
  PASS  mcp:          exactly one 'reexec' line on stderr
  PASS  launchagent:  bootstrapped com.scottlougheed.reminder-calendar-control.m1probe
  FAIL  launchagent:  Not authorized for Calendar: notDetermined (raw 0)
  PASS  launchagent:  exactly one 'reexec' line on stderr
  FAIL  doctor:       authorization_event, authorization_reminder, mcp_registration, launch_agent
  PASS  --version exits 0 / --help exits 0 / unknown flag exits 2 / unknown subcommand exits 2
```

Every failure traces to the single blocker in §1.0. The disclaim half of the criterion —
*"exactly one re-exec observed in each context"* — **does** hold in all three contexts.

---

## 5. Where the spec and reality disagree

Each of these is verified on this machine. They are recorded here rather than edited into
SPEC.md, so the spec's own revision history stays the user's to write.

### 5.0 §6.2 / §4 — the disclaim mechanism currently blocks the grant
See §1.0. SPEC §4 lists the disclaim as load-bearing and §6.2 builds the whole permission
story on it, but as measured here it is the *reason* the grant fails: disclaimed →
`granted=false` with no dialog; not disclaimed → prompt and grant. The most likely cause is
that an ad-hoc responsible process has no stable designated requirement for tccd to key a
grant to, which would make this the same blocker as §5.1 — but that is an inference, and
§6.2 should not be treated as validated until a Developer-ID build proves it.

### 5.1 §18 / §6.2 / §17 — the notarized artifact is unbuildable today
Covered in §1.1 above. One narrower risk from §17 *is* retired: the disclaim's
*mechanical* behaviour under Hardened Runtime is confirmed — ad-hoc plus `-o runtime`
re-execs exactly once and flips the responsible pid to self, identically to unsigned, and
identically inside a signed `.app`. What §1.0 shows is that the mechanism working
mechanically is not the same as the permission story working, so the rest of §17's concern
stands.

### 5.2 §10.1 — "`rcc serve` targets MCP spec revision `2026-07-28`"
**Contradicted, and this one would silently break the product.** Revision 2026-07-28
abolished the `initialize` handshake and mandates `server/discover`. Claude Desktop
1.40609.0 verifiably still sends `initialize` and negotiates `2025-11-25`, and never probes
`server/discover` over stdio. A server built to 2026-07-28 would not connect to the client
this project exists to serve.

Implemented: the legacy `initialize` flow, negotiating `2025-11-25` and accepting
`2025-06-18`, `2025-03-26`, and `2024-11-05`. The dispatch table is data, so adding
`server/discover` later is additive. The spec's *instinct* — negotiate rather than assume a
fixed revision — is right; its chosen target is not.

### 5.3 §8.3 / §17 — `_meta["anthropic/requiresUserInteraction"]`
§17 lists "whether Claude Desktop honors it" as an open question. **It does not.** Claude
Desktop's local MCP bridge rebuilds a third-party server's tool descriptor from scratch,
keeping only `name`, `description`, `inputSchema.{properties,required}`, and
`readOnlyHint`; `_meta`, `title`, `outputSchema`, and every other annotation are discarded.

The spec's fallback position — Desktop's ordinary confirmation UI, explicitly not
guaranteed — is therefore the only position. Two consequences:

* `rcc` emits the key anyway (harmless, forward-compatible) but nothing is architected
  around it.
* **`readOnlyHint: true` is not a hint.** It exempts a tool from the approval policy — it is
  the auto-approval switch. Marking a mutating tool read-only would be a real security bug.
  There is a test asserting only the genuinely read-only tool claims it.

### 5.4 §10.1 — "Strict JSON Schema inputs, `additionalProperties: false`"
The bridge strips it. `rcc` still emits it, but every `tools/call` handler validates its
arguments server-side; client-side rejection of unknown arguments cannot be relied on.

### 5.5 §6.3 — App Sandbox and entitlements
The conclusion ("App Sandbox: disabled") is right and now confirmed: `app-sandbox: true`
kills a bare CLI with SIGTRAP before `main()`. But do **not** express "disabled" as
`com.apple.security.app-sandbox: false` in an entitlements file — it is a runtime no-op
that changes the cdhash and therefore costs a TCC re-prompt for nothing. `rcc` ships **no
entitlements file at all**; Hardened Runtime needs none, and neither does the
`posix_spawn` self-exec.

### 5.6 §6.3 — the deprecated unified access API
§6.3 says `requestAccess(to:completion:)` "does not prompt and throws an error" on a modern
SDK. It still exists in SDK 26.2, still compiles with only a deprecation warning, and on
macOS 14+ maps onto the full-access TCC classes. The spec's operative decision — never call
it — is correct and unaffected; only the stated reason is wrong.

### 5.7 §7.4 — observing `EKEventStoreChanged`
The obvious macOS 26 API (`EKEventStore.EventStoreChanged` with
`NotificationCenter.addObserver(of:for:)`) **SIGTRAPs** when the notification is posted off
the main thread, which EventKit does not guarantee against. Use
`addObserver(forName: .EKEventStoreChanged, object: store, queue: .main)`.

Second, unbudgeted problem for Milestone 3: making that observer fire in a plain CLI needs
the main run loop pumped, and both `RunLoop.main.run(until:)` and `CFRunLoopRunInMode`
hung indefinitely once an `OperationQueue.main` observer was registered. Only a
`RunLoop.main.run(mode:before:)` + `usleep` loop worked.

### 5.8 §6.1 — `rcc setup --verify` after an update
Under ad-hoc signing, "the new binary's signature" is a *different* cdhash by construction,
so the grant is gone after every update and `--verify` will correctly report failure every
single time. The atomic-replace design is right; the verify-step expectation is only
satisfiable with a Developer ID.

### 5.9 §11.3 — `StartCalendarInterval`
Wrong tool for a 15–30 minute cadence: it needs three `<dict>` entries per hour, is
implemented as an XPC event stream, and fires with measurable jitter (`Minute=42` fired at
`12:42:05`). `StartInterval` is one key. The spec's design *consequence* — rules must be
idempotent and catch-up-capable from a persisted watermark — is unchanged and correct.

### 5.10 §13 — "local state is mode `0700`, files `0600`"
Achievable, but not by default. SQLite ignores `.posixPermissions` and has no mode
argument, so the database and its `-wal`/`-shm` sidecars are created `0666 & ~umask` — the
WAL sidecar would leak readable data even inside a `0700` directory. `Store` calls
`umask(0o077)` around `sqlite3_open_v2`, with a test asserting 0600 on all three files even
under a permissive umask.

### 5.10a §6.1 — "setup … requests notification permission"
Not done, deliberately. `UNUserNotificationCenter.current()` aborts the process — uncatchably
— for an executable with no bundle identifier, and even with an embedded plist a bundle-less
client's authorization stays `notDetermined` and `add()` fails. `rcc setup` reports the
capability instead of requesting anything, and notifications go through `osascript`,
attributed to Script Editor rather than to `rcc`. The real fix is the bundle shape §2 now
provides — `Scripts/make-app-bundle.sh` — but wiring UserNotifications to it is deferred
until the bundle is something more than an option. Notification delivery is advisory in any
case: SPEC §8.3 is explicit that it never gates whether an action was staged.

### 5.10b §7.1 — `rcc setup --rotate-key` is absent
`--enable-tier1` exists and fails with an explicit "not implemented until Milestone 7" usage
error. Its sibling `--rotate-key` from the same line does not exist at all, so it fails as an
unrecognised flag. Both belong to Tier 1 and land in Milestone 7. Also absent, and also
Milestone 6/7 scope: `rcc automations {add,list,remove,edit,review,approve,reject,log}`, and
SPEC §16's backup/export offer during uninstall.

### 5.10c §7.4 — `reset()` is not yet wired to `EKEventStoreChanged`
`CalendarRepository.reset()` exists and is called after an authorization change, but nothing
observes `.EKEventStoreChanged` yet, so a long-lived `rcc serve` holds one `EKEventStore`
for a whole Claude Desktop session. Harmless for Milestone 1, whose only reads are its own
just-written test items; it becomes load-bearing in Milestone 3, along with the run-loop
plumbing §5.7 describes.

### 5.11 §9.4 / §10 — the cursor's "store-generation marker"
Unverified, and probably unavailable. No public EventKit API exposes a monotonic store
generation; the only signal is the `EKEventStoreChanged` notification, which is a bare edge
with no payload — and only observable while the process was alive and pumping its run loop.
A cursor issued by a previous `rcc serve` process cannot be evaluated at all. Confirm before
designing the cursor format in Milestone 3.

### 5.12 §11.2 — Keychain from the LaunchAgent identity
"Keychain access verified from the actual LaunchAgent identity … after binary replacement"
is **unsatisfiable while ad-hoc**: replacement changes the cdhash, which is the entire ACL
partition, so the read returns `errSecAuthFailed` and the tool cannot even delete its own
item. Milestone 7 is gated on the same certificate M1b is. Flagged now rather than
discovered then.

### 5.13 §15 — which `EKSource` accepts the dev fixture
Not contradicted, but the riskiest unverified assumption in the plan. Whether a `.local`
("On My Mac") source exists **for reminders** on an iCloud-only Mac is unknown — it could
not be probed without triggering the TCC prompt. `EventKitRepository.preferredSource` walks
a fallback chain (local with calendars → any local → the default calendar's source → any
source that has calendars). If no local reminders source exists, the fixture lands in
iCloud and the "never syncs anywhere" property of a test fixture is lost. The first real
`rcc setup --dev` will settle it; `rcc doctor` reports the source each fixture landed in.

---

## 6. Build-time traps worth knowing

* **Editing `Resources/rcc-Info.plist` alone does not relink.** SwiftPM does not track it as
  a link input: `swift build -c release` reports "Build complete!" in a tenth of a second
  and leaves the old section embedded. `touch`ing a source file is not enough either
  (llbuild content-hashes the object). `Scripts/build-release.sh` deletes the product first,
  then asserts the embedded version matches the source.
* **SwiftPM's output is only linker-signed** — `Identifier=<filename>`, `Info.plist=not
  bound`. It must be re-signed for the usage strings to be sealed, and `Scripts/sign.sh`
  fails loudly if it finds `linker-signed` afterwards.
* **Never patch a signed binary.** The embedded plist is cryptographically sealed; a
  one-byte change yields `invalid Info.plist` and the kernel SIGKILLs the process.
* **`-Xlinker` must precede every `-sectcreate` token,** and the setting belongs on the
  executable target only — on a library target the section leaks into the test bundle's
  Mach-O, which already has a real `Info.plist`.
* **`launchctl load`/`unload` always exit 0, even on failure.** Only
  `bootstrap`/`bootout`/`kickstart` return real exit codes. A stale `launchctl disable`
  record is persistent, root-owned, survives `bootout`, and makes `bootstrap` fail
  outright — so install runs `enable` first.
* **launchd refuses a group- or world-writable plist,** reporting the same generic
  "Input/output error" as everything else.
* **Claude Desktop does not reload `claude_desktop_config.json`.** Quit fully (⌘Q) and
  relaunch. A malformed file produces a blocking error dialog for the *whole* file, which
  is why `rcc` refuses to rewrite one it cannot parse.

---

## 7. Why the MCP server is hand-rolled

The official Swift SDK (`modelcontextprotocol/swift-sdk`) exists, builds here, and supports
stdio. It was not adopted for Milestone 1 because it pulls swift-nio plus five other
packages to do what newline-delimited JSON over two file descriptors does in a couple of
hundred lines; it is pre-1.0 with breaking minor bumps and no commits since 2026-05-07; and
fewer third-party binaries inside a notarized artifact is strictly better.

Adopting it later is cheap: its `StdioTransport` takes an injectable output file descriptor,
which is exactly the quarantined descriptor `ProtocolIO` already owns. The seam is one
dispatch function and one transport.

---

## 8. Known gaps in the test story

`InMemoryCalendarRepository` is necessarily more permissive than the real adapter: the
guards that exist only in `EventKitRepository` — the exact `allowedEntityTypes` equality
before deleting a calendar, the `EKSource` fallback chain, EventKit's own error domain — are
by definition not exercised by tests that run against the fake. They are covered only by the
acceptance matrix, which is the one thing currently blocked. Worth remembering before
treating a green `swift test` as coverage of the EventKit layer.
