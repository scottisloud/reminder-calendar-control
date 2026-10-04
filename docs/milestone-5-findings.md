# Milestone 5 — release proof: findings

Date: 2026-10-03. Host: MacBook Pro, Apple M1 Pro, 32 GB, macOS 27.0.1 (26A434).
Artifact: `rcc 0.1.0+4519f2d (release)` — Developer ID, Hardened Runtime, notarized
(notary profile `rcc-notary`), installed at the stable path. Every measurement below is
against that artifact, launched through Claude Desktop's own
`Contents/Helpers/disclaimer` shim — the real launch context, not a dev build.

**Acceptance (SPEC §18 M5): met.** Install-then-`rcc setup` produces a working tool;
uninstall removes or preserves `rcc`'s own state on request and never touches Calendar or
Reminders; resource use is measured against every §7.3 item below. Two §7.3/§18 items
were changed by explicit direction rather than met as written — see *Scope changes*.

## 1. Install, update, uninstall

Run live, in this order, with a data fingerprint (calendar ids/titles + every reminder's
`version`) and counts taken before and after every step:

| Step | Result |
|---|---|
| Update: `install.sh` over the running copy, then `setup --verify` | Doctor all OK against the new binary; `--verify` records the new version (the install record had been stuck at `8c8b040-dirty` since September) |
| `setup --uninstall --keep-state` | LaunchAgent unloaded and plist removed; Desktop entry removed; state kept; Calendar & Reminders untouched |
| `setup` (reinstall) | Re-registered; grant still held — no prompt |
| `setup --uninstall --purge-state --remove-binary` | Product directory, logs, plist, Desktop entry all gone; dev calendars left in place and named |
| Fresh `install.sh` + `setup --dev` | **TCC grant survived the binary being deleted** (keyed to path + designated requirement); existing dev calendars **adopted**, not duplicated; doctor OK; selftest PASS |
| Data fingerprint, all steps | Identical: 24 calendars/lists, 1,111 reminders, 4,046 events in 2026–27 |

Changes made for this:

- **Uninstall never changes Calendar or Reminders data** (by direction). Previously
  `--purge-state` deleted the `--dev` fixture calendars from the user's accounts. They are
  now left alone and listed. `--purge-state` also removes logs; `--remove-binary` removes
  the binary and `RCC.app`, leaving nothing installed.
- **No backup step** on uninstall (by direction).
- `setup --dev` **adopts** an existing `RCC Dev …` calendar of the right type before
  creating one, so purge-and-reinstall strands nothing.
- **Doctor's dev-fixture check was lying.** It read only the state database, so it reported
  "both provisioned" for months after the reminder fixture list had disappeared from
  EventKit. It now resolves each recorded fixture against EventKit and warns with the fix.

## 2. Provider / source matrix

Eight `EKSource`s on this Mac. **Google surfaces as `calDAV`** (raw 2) — the §8.2 open
question is answered: there is no Google-specific source type, and nothing in rcc needed
special-casing.

| Account | Source type | Calendars (writable) | Read | Write round trip | Refusals |
|---|---|---|---|---|---|
| iCloud (events) | calDAV | Personal, Household, Meals, RCC Dev events (W); 2 subscribed (R/O) | ✓ | ✓ full | subscribed → `read_only` |
| iCloud (reminders) | calDAV | 6 lists + RCC Dev reminders (W) | ✓ | ✓ full (M4a + M5) | event calendar as list → `not_found` w/ valid lists |
| Google | calDAV | scott@…, Sketch Us If You Can (W); Holidays in Canada (R/O) | ✓ | ✓ full | Holidays → `read_only` |
| Google delegate (hisketchus@gmail.com) | calDAV, delegate | — | ✓ | not tested (shared) | |
| Fastmail | calDAV | Fastmail, Personal, Household, Meals, AgileBits (W); calendar@agilebits.com (R/O) | ✓ | ✓ full | R/O → `read_only` |
| Subscribed Calendars | subscribed | Canadian Holidays (R/O) | ✓ | n/a | `read_only` |
| Other | birthdays | Birthdays (R/O) | ✓ | n/a | `read_only` |
| On My Mac (local) | — | not present on this Mac | — | — | — |

"Full round trip" = create with location, URL, notes, a 15-minute alert, a weekly×2 rule,
and `availability: free`; read every field back; list both occurrences; edit one
occurrence via its locator (`this_occurrence`); delete the series (`this_and_future`);
confirm nothing remains. Identical results on iCloud, Google, and Fastmail (with the
user's permission for the two non-iCloud writes; no shared calendars were written).

Caveats: the round trip reads EventKit's local copy, so a field a server drops on a later
sync would not show here. Every writable CalDAV calendar here supports only
`busy`/`free`; `tentative` is refused as `unsupported` rather than silently ignored.

## 3. iOS parity corpus

`docs/parity-corpus.md`: 18 dated cases (default list, duplicate names, day-only vs timed,
all-day spans, DST, biweekly rules, single-occurrence edits, series truncation, recurring
completion, invitations, read-only calendars, RSVP, list creation, priority, due windows,
batch completion, destructive confirmation). **rcc side: 18/18 as expected**, run through
the real launch path by `Scripts/parity.py`. The Claude for iOS column is for the user
to fill in on the phone; no parity claim is made beyond the rcc column until then.

Two gaps closed because of it:

- **Default destination.** rcc deliberately has no implicit default (§10), but it never
  said which list *is* the default, so Claude had to guess. Lists and calendars now report
  `is_default`; the server instructions say to use it explicitly and say so.
- **Invitations are read-only.** rcc would edit or delete an event someone else organised.
  On CalDAV/Exchange that can send the organiser a decline or counter-proposal — a
  participation write by another route (§8.4). Now refused with `unsupported`, matching
  Anthropic's documented iOS line ("edit only if you organised it"). Verified on a real
  invitation, with a deliberately wrong `if_match` so nothing could have been written had
  the guard been missing (the guard runs before the version check).

## 4. Resource benchmarks (SPEC §7.3)

Raw data: `docs/benchmarks/2026-10-03-m5.json`, produced by `Scripts/benchmark.py`
(25 iterations per query, real data: 1,111 reminders, 8,672 event occurrences in the
3-year window, 27,745 in 10 years). The sustained-load figures were measured separately
on the same code with the harness that became `benchmark.py`'s sustained-load step; a
full re-run that would have included them was discarded because the Mac went into
clamshell sleep mid-run, which inflates every timing.

| §7.3 item | Measured |
|---|---|
| Idle CPU (60 s, mean / p95) | **0.0% / 0.0%** (below `ps` cputime's 10 ms resolution) |
| `serve` startup (spawn → `initialize` answered) | p50 **29 ms**, p95 57 ms |
| RSS / footprint after start | 25 MB / **7.6 MB** |
| Memory under sustained load | footprint bounded **~90–120 MB**; no ratchet across rounds (see §5) |
| `automations run` cold start (the LaunchAgent firing) | wall p50/p95 **20/20 ms**, CPU 10 ms, max RSS 13.6 MB |
| LaunchAgent cadence | 1,800 s → 48 launches/day ≈ **0.5 CPU-s/day**; no resident process between firings |
| `list_reminders` overdue/today, incomplete page | p50 **12–13 ms** |
| `list_events` next 7 days | p50 **17 ms**, p95 24 ms |
| `list_reminders` all 1,111, page 200 | p50 **394 ms**, p95 413 ms |
| `list_events` 3 years (8,672), page 200 | p50 **835 ms**, p95 917 ms |
| `list_events` 10 years (27,745, chunked) | p50 **4.5 s**, p95 4.7 s |
| Largest response (page 200, `include_details`) | **687 KB** (events), 304 KB (reminders) |
| Max items per page | 200 (hard clamp) |
| Tier 1 tokens/cost | n/a until Milestone 7 |

**Deadline / cancellation behaviour (stated, not built).** Requests are served one at a
time and EventKit's fetches are synchronous and uninterruptible, so rcc enforces no
per-request deadline and does not act on `notifications/cancelled`. The bound is the
work itself: the slowest realistic query on this Mac (ten years, every calendar) is
4.7 s p95, well inside Claude Desktop's own request timeout. A ranged event query is the
only unbounded-input path; list tools cap a page at 200 items.

## 5. Bugs found by measuring, and fixed

1. **Event listing was ~20× slower than necessary.** Every occurrence in the window was
   fully converted — alarms, recurrence rules, and attendees are lazily loaded relations,
   one `calaccessd` round trip each — only to compute a `version` for rows that were then
   paged away. Queries are now two-phase: filter, order, and page on cheap fields; fully
   convert only the returned page. 3-year listing **16.8 s → 0.83 s**; all reminders
   **1.24 s → 0.39 s**. `RCCID.hash` also formatted SHA-256 hex with `String(format:)` per
   byte (~17% of samples); replaced with a table, byte-identical output.
2. **`rcc serve` leaked ~27 MB per large query, forever.** EventKit objects are
   autoreleased, and Swift concurrency's executor threads do not drain an autorelease pool
   per job, so nothing was ever freed: 234 → 780 MB over 25 ten-year queries, and the
   first full benchmark run left the process at **1.6 GB** idle. This is the "long-uptime
   memory growth" §17 listed as anecdotal — it was real, and it was ours. Every EventKit
   fetch now runs inside `autoreleasepool`; the same 25 queries hold flat at ~92 MB, and
   repeated rounds of the whole query mix stay within 98–122 MB.
3. Doctor's dev-fixture check (above).
4. A pre-existing doctor path (state database open failure) reported `fail` with no
   remediation; it now has one. Surfaced because the doctor tests shared a sandbox
   database concurrently — that suite now runs serialized.

## Scope changes (by direction)

- **No 24–72 h soak.** Dropped at the user's direction. Long-uptime memory evidence is the
  sustained-load measurement instead (bounded, no ratchet), which is what found and then
  confirmed the fix for the leak above.
- **No uninstall backup step** (§16 amended).

## Environment notes

- macOS 27's SDK broke the swiftly-pinned Swift 6.3.3 (`Package.swift` itself failed to
  compile), and the Command Line Tools' Swift 6.4 loaded the `TestingMacros` plugin only
  intermittently. Fixed: swiftly 1.2.0 with Swift 6.4.0 pinned in `.swift-version`; plain
  `swift build` / `swift test` work, three consecutive clean test runs.
- The TCC grant is keyed to the binary's path (plus its designated requirement): a build
  directory copy is `notDetermined`, and so is anything run from Claude Code's own shell.
  Live tests therefore run the installed binary through the `disclaimer` shim.
- The `--dev` fixtures lived in **iCloud** because this Mac has no "On My Mac" account, so
  they synced to the user's other devices. Removed at the end of M5 with the new
  `rcc setup --remove-dev` (the only path that deletes them; it touches only the recorded
  fixtures, and treats one already deleted by hand as done). `rcc setup --dev` recreates
  them for `rcc selftest` / `Scripts/parity.py`.
- Doctor's overall status no longer reads SKIPPED when one check is merely not applicable
  (e.g. no dev fixtures); `skipped` checks are excluded from the overall verdict.
