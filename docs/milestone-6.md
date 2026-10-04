# Milestone 6 — Tier 0 automation

Date: 2026-10-03. macOS 27.0.1, rcc 0.1.0 (schema v3).

**Acceptance (SPEC §18 M6).** *A nightly cleanup rule and a "flag meetings with no
location" rule both run unattended for a week without double-firing, silent failure, or
an unstaged destructive action — and a crash injected at each journal transition recovers
correctly.* Met as follows:

- **The week** is proven in a deterministic simulation (`simulatedWeek`): launchd's
  30-minute cadence for seven days, every tick invoked twice concurrently, the Mac asleep
  for 15 hours mid-week. Exactly 7 cleanup runs and 5 weekday flag runs, one per slot, none
  stuck or failed, and nothing deleted unattended. Repeated 25× clean. A calendar-time week
  was dropped by direction; the simulation is the evidence.
- **Crash recovery**: every deletion an approval executes goes through `MutationExecutor`
  and the §9.6 journal, whose fault injection at every transition is M2's (unchanged).
  New here: an approval interrupted part-way resumes without repeating finished items
  (`resumeAfterCrash`), and an abandoned run row is closed out as failed.

## What exists

| Piece | Where |
|---|---|
| Rule DSL v1 (allowlisted, versioned, unknown keys refused) | `Sources/RCCAutomation/Rule.swift` |
| Schedule (daily / weekly / every N≥15 min, rule's own zone) | `Schedule.swift` |
| Triggers: `completed_reminders`, `events_without_location` (heuristic), `back_to_back_events` | `Evaluator.swift` |
| Runner: leases, misfire policy, fan-out cap, staging, notifications, retry with backoff | `Runner.swift` |
| Approval: re-resolve + `if_match`, one-use, expiry, resumable | `Approval.swift` |
| Rule catalog (names → ids at save time) | `RuleCatalog.swift` |
| Schema v3: rules, runs, staged actions, audit log | `Sources/RCCCore/AutomationStore.swift` |
| CLI: `rcc automations run/list/show/add/enable/disable/remove/pending/approve/reject/log` | `Sources/rcc/AutomationsCommand.swift` |
| MCP: `list/create/update/delete/preview_automation`, `list_pending_actions` | `Sources/RCCMCP/AutomationTools.swift` |
| Doctor: rules, failures, pending approvals | `automation` check |

Actions are `flag` (notify + log; never mutates) and `delete` (only with
`completed_reminders`, only over explicitly named lists, **always staged**). A
non-destructive Tier 0 create action (§8.3's "executes directly" carve-out) is not in DSL
v1; the DSL is versioned so it can be added.

## The approval boundary

Staged actions execute only through `rcc automations approve <id>`, which requires stdin to
be a TTY and the id typed back. Verified live: run from Claude Code's shell it refuses
("Approval needs a person at an interactive terminal"). There is no MCP approve/reject tool
— a test fails if one is ever added (`noApprovalTool`). `list_pending_actions` gives Claude
the exact command to hand the user. Execution re-checks every item against its staged
`version`: changed items are reported `changed_since_staged` and left alone, already-gone
items `already_deleted`. Each deletion is journalled and audited under the approval id.

## Bugs found building this

1. **Double-fire under overlapping runs.** Holding the lease was not enough: a run that read
   the rule as due, then won the lease *after* an overlapping run had already served the
   slot and released it, ran the slot again. The simulated week caught it (6 weekday runs,
   not 5). Fixed by re-reading the rule under the lease and proceeding only if its
   `next_due_at` is unchanged.
2. **Replaying a failed idempotency key reported success.** `MutationExecutor` returned the
   recorded row as a normal outcome regardless of its state, so a retry of a refused write
   (live or automated) looked like it had worked. A replay now re-surfaces the original
   failure, or `outcome_unknown` if the first attempt never finished.
3. **Not a bug, but worth recording:** America/Vancouver has had **no DST since March 2026**
   (permanent UTC−7 in the tz database on this Mac). Schedules are computed in the rule's
   own zone, so this is handled; the DST gap/repeat tests use America/Los_Angeles.

## Live verification (real data, 2026-10-03)

- Migration of the live state database v2 → v3: clean.
- `create_automation` ×2 over MCP, the way Claude would; a `delete` rule on events refused.
- Flag rule: found 1 meeting with no place in the next 7 days; notification posted.
- Cleanup rule (Personal, > 30 days): **446 matches, over its `max_fan_out` of 200** — the
  run stopped, changed nothing, notified, and `rcc doctor` warned. Nothing was staged or
  deleted.
- Both rules were test fixtures for the above and were removed afterwards; no rules are
  configured.
- `rcc automations approve` from a non-TTY shell: refused.

## Not done

- The calendar-time week, dropped by direction (as was M5's soak).
- Tier 1 (LLM-in-the-loop) is Milestone 7.
