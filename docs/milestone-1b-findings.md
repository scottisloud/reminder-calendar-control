# Milestone 1b — signing, notarization & the TCC dead end

Follows `docs/milestone-1.md`. Everything here was measured on this machine
(macOS 26.6.2, arm64) with an Apple Developer Program membership now available
(Team `T879Q2BE7Q`), so the artifacts M1a could not build now exist.

## TL;DR

1. A real Developer ID signature — and full notarization on top of it — **does not**
   fix the disclaimed-process TCC failure from `docs/milestone-1.md` §1.0. All three
   hypotheses in that section are disproven.
2. **Claude Desktop already disclaims every MCP server it spawns**, using its own
   `Claude.app/Contents/Helpers/disclaimer` helper (Anthropic PBC, Team `Q6L2SF6YDW`).
   `rcc`'s own self-disclaim (SPEC §6.2) is therefore redundant, and SPEC §8.1's premise
   — that Desktop attributes the request to *its own* identity — is outdated: Desktop
   makes the server self-responsible, which is the opposite problem.
3. The only working Calendar/Reminders grant on this machine belongs to **Ghostty**, the
   terminal. `rcc` run from Ghostty non-disclaimed inherits it. `rcc` has no grant of its
   own, and there is no "rcc" entry in System Settings › Privacy.
4. Any disclaimed `rcc` — by its own mechanism *or* by Desktop's helper — is
   self-responsible, matches no grant, cannot prompt, and returns `notDetermined`
   forever.

Net: the headless-bare-Mach-O design cannot obtain a TCC identity of its own on
macOS 26. SPEC §4 / §6.1 / §6.2 / §8.1 must be reopened.

## What was built and verified

| Artifact | Status |
|---|---|
| Developer ID Application cert (`T879Q2BE7Q`) | in login keychain |
| `rcc` signed Developer ID + Hardened Runtime | `codesign --verify --strict` passes; stable DR `identifier "…" and anchor apple generic and … subject.OU = T879Q2BE7Q` |
| Notarization | submission `5534f800-…` **Accepted**; `codesign --verify -R=notarized` satisfied |
| Stapling | not possible for a bare Mach-O (`stapler` Error 73) — expected, ticket lives server-side |

## The test matrix (TCC state reset between runs where possible)

| # | Disclaim | Signature | Launched by | Calendar/Reminders result |
|---|---|---|---|---|
| 1 | rcc self | ad-hoc | Ghostty | `notDetermined`, no prompt |
| 2 | rcc self | Developer ID + HR | Ghostty | `notDetermined`, no prompt |
| 3 | rcc self | Developer ID + HR + **notarized** | shell | `notDetermined`, no prompt |
| 4 | **none** (`RCC_DISCLAIM=0`) | Developer ID + HR | **Ghostty** | **`fullAccess` — full CRUD round-trip on the dev fixtures** |
| 5 | none (`RCC_DISCLAIM=0`) | Developer ID + HR | Claude Code Bash tool | `notDetermined` |
| 6 | none (`RCC_DISCLAIM=0`) | Developer ID + HR | `Claude.app/Contents/Helpers/disclaimer --pgroup --` | `notDetermined` |
| 7 | rcc self | Developer ID + HR | `Claude.app/Contents/Helpers/disclaimer --pgroup --` | `notDetermined` |

Rows 4 vs 5/6: identical binary, identical flags — the difference is **who is the
responsible process**. Ghostty holds a Calendar/Reminders grant; the Claude Code helper
and a disclaimed context do not. The grant is Ghostty's, inherited, not rcc's.

Rows 6 and 7 replicate exactly how Claude Desktop launches `rcc serve`
(`disclaimer --pgroup -- …/rcc serve`). Both `notDetermined`. Whether `rcc` runs its own
disclaim is irrelevant once Desktop's helper has already disclaimed it.

## Claude Desktop's `disclaimer` helper

```
$ pgrep -fl 'rcc serve'
16322 /Applications/Claude.app/Contents/Helpers/disclaimer --pgroup -- …/rcc serve
16323 …/rcc serve

$ strings Claude.app/Contents/Helpers/disclaimer | grep -i disclaim
Usage: disclaimer [--pgroup | --ports-only] [--] <command> [args...]
Failed to set disclaim attribute: %s
```

It calls `responsibility_spawnattrs_setdisclaim` — the same private SPI `rcc` uses. So:

- `rcc`'s `Sources/RCCBootstrap/Disclaim.swift` + `Sources/CDisclaim/` duplicate work
  Desktop already does. The self-disclaim can very likely be **deleted**, removing the
  private-SPI single point of failure SPEC §6.2 calls an accepted risk.
- The MCP wire protocol itself is fine: a direct `initialize` + `tools/list` against
  `rcc serve` negotiates `2025-11-25` and returns both tools correctly.

## What the SPEC got wrong

- **§8.1** "macOS's TCC subsystem attributes the permission request to Claude Desktop's
  own identity" — no longer true. Desktop disclaims the server; it is self-responsible.
- **§6.2** the self-disclaim is redundant with Desktop's helper for the `serve` path, and
  is *harmful* for the `setup` path (it prevents the interactive grant from being recorded
  against anything usable).
- **§4 / §6.1** "native Swift, headless CLI, single bare binary" is incompatible with
  obtaining a TCC identity on macOS 26. A disclaimed bare Mach-O cannot prompt, and a
  non-disclaimed one only borrows the terminal's grant.

## The remaining candidate: a notarized `.app` bundle

LaunchServices-registered app bundles have a TCC identity keyed to bundle id +
designated requirement, independent of the responsible process. Hypothesis to test:

1. Build `RCC.app` (LSUIElement, headless — `Scripts/make-app-bundle.sh` already does
   this), signed **and notarized**.
2. Launch it once directly (`open RCC.app`) so LaunchServices assigns it its own identity
   and `requestFullAccessToEvents` produces a prompt naming *RCC*, not Ghostty. Grant
   recorded against `com.scottlougheed.reminder-calendar-control`.
3. Point Claude Desktop at `RCC.app/Contents/MacOS/rcc serve`. Desktop's `disclaimer`
   helper still disclaims it, but the client identity (DR / bundle id) is unchanged, so
   the grant from step 2 should match.

`docs/milestone-1.md` §1.0 noted "two `open`-launched variants did briefly succeed" —
that is the thread to pull. If step 3 works, the architecture becomes: ship a notarized
`RCC.app`, grant once by launching it, and drop the self-disclaim entirely.

If step 3 also fails, EventKit access from a Desktop-spawned MCP server is not currently
possible on macOS 26 and the project needs a different transport (e.g. a resident
LaunchAgent app that `rcc serve` talks to over a local socket).

## Resolution — no bundle needed

The `.app` bundle was not required. Two changes, matching what `che-ical-mcp` does,
closed the gap:

1. **`Resources/rcc-Entitlements.plist`** — `com.apple.security.personal-information.calendars`
   + `.reminders`, sealed into the signature by `Scripts/sign.sh`. macOS 26.5's prompting
   policy refuses to present a Calendar/Reminders dialog for a Hardened-Runtime binary
   without them.
2. **`Sources/RCCCalendar/InteractiveGrant.swift`** — `rcc setup` now issues the access
   request from inside a foreground `NSApplication` run loop (`.accessory` policy). A bare
   CLI async request is denied with no dialog on macOS 14+.

Verified with a Developer-ID-signed, entitled, **notarized** binary, granting from
`rcc setup` run through Claude Desktop's own `disclaimer` helper (so `setup` executes
self-responsible, exactly like `serve`):

```
$ disclaimer --pgroup -- rcc setup --dev      # from Ghostty
  Calendar and Reminders access: requesting — approve the macOS dialog(s)…
  Calendar access: granted
  Reminders access: granted

$ disclaimer --pgroup -- rcc serve   # get_system_status + run_platform_selftest
  get_system_status      -> isError:false, all checks ok
  run_platform_selftest  -> passed:true; event + reminder created/read/deleted;
                            authorization {event: fullAccess, reminder: fullAccess}
```

The grant is recorded against `rcc`'s own designated requirement, so any disclaimed
`rcc serve` — whether disclaimed by Claude Desktop's helper or by rcc's own §6.2
mechanism — matches it.

### Consequences for the SPEC

- **§6.3** — "ship no entitlements" reverses: the two `personal-information` keys are now
  mandatory on the macOS 26 floor.
- **§6.2 / §8.1** — the self-disclaim is redundant with Claude Desktop's `disclaimer`
  helper (harmless: re-execs once, lands self-responsible either way). §8.1's "Desktop
  attributes the request to its own identity" is simply not how current Desktop behaves.
  Candidate follow-up: delete `Sources/RCCBootstrap/Disclaim.swift` + `Sources/CDisclaim/`
  and the private-SPI dependency entirely.
- **`rcc setup`** now hard-depends on an interactive (foreground GUI-capable) session for
  a first grant. A non-interactive invocation reports what is missing and exits non-zero
  rather than blocking.

### Diagnostic toggle retained

`RCC_DISCLAIM=0` (skips rcc's own disclaim; `Outcome.bypassed`; `doctor` shows `[warn]`)
is kept as a documented escape hatch until the §6.2 removal decision is made.

### Cosmetic follow-up

`rcc doctor`'s "Gatekeeper / notarization" check uses `spctl --assess --type exec`, which
always rejects a bare CLI as "not an app" even when it is notarized. Switch it to
`codesign --verify -R=notarized` (or a stapled-ticket probe).

## Diagnostic scaffolding added on this branch (not for keeps)

- `RCC_DISCLAIM=0` env var → `Disclaim.ensure()` skips the disclaim and records
  `Outcome.bypassed`; `rcc doctor` shows a `[warn]` row. Purely to run the matrix above.
  Remove or redesign once the architecture is settled.

## Script bugs found along the way

- `Scripts/sign.sh` runs `stapler staple` on the bare Mach-O; it fails Error 73
  (harmless to the binary, confirmed) but noisily.
- `Scripts/sign.sh` and `Scripts/install.sh` both use `codesign -dvvv 2>&1 | grep -q
  '^Info.plist entries='` as a seal check; under load (concurrent notarization, rapid
  rebuilds) this intermittently reports a false negative and aborts a correctly signed
  build. Capture `codesign -d --verbose=4` output once into a variable, then grep that.
- `Scripts/install.sh --skip-build` derives `BIN_PATH` from
  `swift build -c release --show-bin-path` without `RCC_INFO_PLIST` set; captured build
  chatter / a re-plan corrupts the path and it dies with a misleading "no Info.plist
  sealed" message. A manual atomic copy is the current workaround.
- `Scripts/install.sh`'s "ad-hoc signature … code hash changed" warning fires for
  Developer ID builds too (cdhash still changes per build, but the text is wrong).
