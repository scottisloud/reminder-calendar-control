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

**This machine has no code-signing identity**, so the acceptance criterion as written
cannot be completed here:

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

* **M1a — delivered here.** Everything except the certificate: the disclaim mechanism and
  its guard, the install topology, `rcc doctor`, the dev fixtures, the MCP server, and the
  full three-context acceptance matrix, against an **ad-hoc-signed, Hardened-Runtime**
  artifact at the authoritative install path.
* **M1b — outstanding, gated on an Apple Developer ID.** Re-run the identical matrix
  against a Developer-ID-signed, notarized artifact. `Scripts/sign.sh --notarize` is
  written and ready; it refuses to notarize an ad-hoc signature rather than pretending.

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
4. Failure is closed. `mechanismUnavailable`, `notDisclaimed`, `spawnFailed`,
   `pathUnresolved`, and `guardViolated` all block TCC-touching work and are reported by
   `rcc doctor`. There is no fallback that runs undisclaimed.

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

The harness asserts, for each of Terminal, an MCP child process over stdio, and a launchd
LaunchAgent:

* exactly one `RCC_DISCLAIM event=reexec` line, and `generation == 1`
* `responsible_pid == pid`
* an event and a reminder written to the dev fixtures, read back, and deleted
* `rcc doctor` reporting no failing checks

It also asserts that `rcc serve` answers three frames for four inputs — a
`notifications/initialized` notification must never be answered — and that stdout carries
nothing but JSON.

---

## 5. Where the spec and reality disagree

Each of these is verified on this machine. They are recorded here rather than edited into
SPEC.md, so the spec's own revision history stays the user's to write.

### 5.1 §18 / §6.2 / §17 — the notarized artifact is unbuildable today
Covered in §1 above. One piece of *good* news the spec does not have: §17's risk
*"self-disclaim behaviour under Hardened Runtime is unverified"* is **retired**. Ad-hoc plus
`-o runtime` behaves identically to unsigned, including inside a signed `.app`. Only the
Developer ID / notarization half of that risk remains open.

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
