# iOS parity corpus (SPEC §12)

A fixed set of requests, each run against **Claude for iOS** (its native Calendar/Reminders
integration) and **Claude Desktop + `rcc`**, with what each did recorded. The point is a
dated, reproducible comparison rather than a claim: Anthropic's mobile behaviour changes,
so every iOS column carries the app version and date it was observed on.

Run each request in a fresh chat, with the stated precondition. Record exactly what
happened — including "asked a clarifying question" — not what should have happened.
Clean up anything created afterwards.

**Basis tags** (SPEC §12's methodology): **D** documented by Anthropic, **O** observed here,
**E** an EventKit capability or limit, **P** this project's own design choice.

## Run record

| Side | Version | OS | Date | Who |
|---|---|---|---|---|
| rcc | 0.1.0+4519f2d (notarized) | macOS 27.0.1 (26A434) | 2026-10-03 | Claude, via `Scripts/parity.py` against the installed binary — **18/18 as expected** |
| Claude for iOS | — | — | — | **Skipped by direction (2026-10-03).** The corpus stays here to run later if wanted. |

## Corpus

| # | Request (precondition) | What to look for | rcc (observed 2026-10-03) | Claude for iOS | Basis |
|---|---|---|---|---|---|
| 1 | "Remind me to buy milk." (no list named) | Which list it lands in; whether it asks | No implicit default by design (§10). Lists report `is_default` (observed: **Personal**); instructions tell Claude to use it and say so | | P / O |
| 2 | "Add 'Lunch' to my Personal calendar." (two event calendars named Personal: iCloud and Fastmail) | Picks one silently, asks, or errors | `ambiguous_target` with both candidates (id, title, account) — Claude must ask | | P / O |
| 3 | "Remind me to renew my passport on November 14." | Due is a *day*, not midnight | `due` = `2026-11-14`, granularity `date`, no alert added | | O |
| 4 | "Remind me at 4pm tomorrow to take the bins out." | Due has a time; an alert fires | granularity `datetime` in America/Vancouver, absolute alert at 16:00 | | O |
| 5 | "Put 'Cabin weekend' on my calendar Oct 9–11, all day." | All-day, spans 3 days inclusive | `all_day: true`, `start_date 2026-10-09`, `end_date 2026-10-11` | | O |
| 6 | "Book 'Dentist' at 9am on November 2." (day after DST ends) | Lands at 09:00 local, not 08:00/10:00 | `2026-11-02T17:00:00Z` = 09:00 PST | | O |
| 7 | "Every other Tuesday at 10, 'Planning', until June." | Biweekly rule with an end date | `weekly`, interval 2, Tuesday, ends 2027-06-30 23:59:59 local (inclusive) | | O |
| 8 | "Move just next week's Planning to 11." (series from #7) | Only that occurrence changes | `this_occurrence` via that occurrence's locator: Oct 20 moved to 11:00, every other occurrence still 10:00 | | O |
| 9 | "Cancel Planning from the 3rd occurrence on." | Series ends there | `this_and_future` from Nov 3: 4 occurrences in the window → 2 | | O |
| 10 | "Mark 'take the bins out' done." (repeating weekly reminder) | Completed; next one appears | EventKit records the occurrence as a separate completed reminder and advances the series (Oct 5 → Oct 12); the result's `note` says so | | O / E |
| 11 | "Change the title of <an event someone else invited me to>." | Refuses, edits, or edits locally only | Refused (`unsupported`) on a real invitation: rcc does not edit/delete events you did not organise, since that can send the organiser a reply | Anthropic docs: edit only if you organised it | D / P / O |
| 12 | "Add 'Lunch' to my Birthdays calendar." | Refuses read-only | `read_only`, naming "Birthdays" | | O / E |
| 13 | "Accept the invite from Pat for Thursday." | RSVP | Not supported (public EventKit cannot write participation status, §8.4) | Not documented | E |
| 14 | "Make a new list called Garden." | List creation | Created in iCloud (where the other lists live), no `source_id` needed | Not supported (documented) | D / O |
| 15 | "Set 'renew passport' to high priority." | Priority write | `priority: 1` (`high`) | Claimed in docs; not observed independently | D / O |
| 16 | "What's overdue or due today?" | Day-only reminders due today are *not* overdue | `due_window: overdue_or_today`; day-only today counted as today, not overdue | | O |
| 17 | "Complete these: A, B, C." | One confirmation or three | One `complete_reminders` call → one Desktop confirmation | | O |
| 18 | "Delete 'Dentist'." | Confirmation before a destructive write | Desktop prompts for `destructiveHint` tools, with an "Always allow" option (§17, observed M4) | Docs: contextual Allow once / Always / Don't allow | D / O |

## Findings so far (rcc side)

- All 18 cases run on the rcc side through Claude Desktop's own launch path
  (`Scripts/parity.py`), writing only to rcc's dev calendar and list and cleaning up.
  Rerun it after any change to the tool surface.
- Two parity gaps closed during M5 because of this corpus: lists and calendars now report
  `is_default` (case 1), and edits/deletes of invitations are refused (case 11).
- The iOS column is for Scott to fill in on the phone; until then, no parity claim is made
  beyond the rcc column itself.
