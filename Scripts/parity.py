#!/usr/bin/env python3
"""parity.py — run the rcc side of docs/parity-corpus.md against the installed binary.

Usage: Scripts/parity.py

Launches `rcc serve` the way Claude Desktop does (through its `disclaimer` helper) and
drives each corpus case with the tool calls Claude would make. Writes go only to rcc's own
`--dev` fixture calendar and list (run `rcc setup --dev` first); everything created is
deleted before exit. Prints one line per case: number, PASS/FAIL, and what was observed.
"""
import datetime, json, os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from benchmark import Server  # noqa: E402

results = []


def case(number, ok, observed):
    results.append((number, ok, observed))
    print(f"{number:>3}  {'PASS' if ok else 'FAIL'}  {observed}", flush=True)


def call(server, name, args):
    """A tool call that may legitimately fail; returns (ok, structuredContent)."""
    reply, _ = server.call_raw("tools/call", {"name": name, "arguments": args})
    result = reply.get("result", {})
    return not result.get("isError"), result.get("structuredContent", {})


def main():
    s = Server()
    lists = call(s, "list_reminder_lists", {})[1]["data"]
    cals = call(s, "list_calendars", {"entity_type": "event"})[1]["data"]
    dev_list = next(c for c in lists if c["title"].startswith("RCC Dev reminders"))["id"]
    dev_cal = next(c for c in cals if c["title"].startswith("RCC Dev events"))["id"]
    made_reminders, made_events = [], []
    today = datetime.date.today()

    try:
        # 1 — default list is discoverable (rcc never falls back to it implicitly).
        defaults = [c["title"] for c in lists if c.get("is_default")]
        case(1, len(defaults) == 1, f"default reminder list reported: {defaults}")

        # 2 — duplicate destination name.
        dup = next((t for t in {c["title"] for c in cals} if sum(c["title"] == t for c in cals) > 1), None)
        if dup:
            ok, sc = call(s, "create_event", {"calendar": dup, "title": "parity 2", "start": "2026-12-01T10:00:00Z"})
            case(2, not ok and sc.get("code") == "ambiguous_target" and len(sc.get("candidates", [])) > 1,
                 f"'{dup}': {sc.get('code')} with {len(sc.get('candidates', []))} candidates")
        else:
            case(2, True, "no duplicate calendar names on this Mac to test against")

        # 3 — day-only due.
        ok, sc = call(s, "create_reminder", {"list": dev_list, "title": "parity 3 renew passport", "due": "2026-11-14"})
        r = sc["data"]["reminder"]; made_reminders.append(r["id"])
        case(3, r["due"]["granularity"] == "date" and "alarms" not in r, f"due {r['due']}, alarms {r.get('alarms')}")

        # 4 — timed due with an alert.
        ok, sc = call(s, "create_reminder", {"list": dev_list, "title": "parity 4 bins", "due": "2026-10-04T16:00:00-07:00"})
        r = sc["data"]["reminder"]; made_reminders.append(r["id"])
        case(4, r["due"]["granularity"] == "datetime" and r["due"]["hour"] == 16 and len(r.get("alarms", [])) == 1,
             f"due {r['due']['hour']}:{r['due']['minute']:02d} {r['due'].get('time_zone')}, alarms {[a.get('absolute_date') for a in r.get('alarms', [])]}")

        # 5 — multi-day all-day event.
        ok, sc = call(s, "create_event", {"calendar": dev_cal, "title": "parity 5 cabin", "all_day": True,
                                          "start": "2026-10-09", "end": "2026-10-11"})
        e = sc["data"]["event"]; made_events.append(e["id"])
        case(5, e["all_day"] and e["start_date"] == "2026-10-09" and e["end_date"] == "2026-10-11",
             f"all_day {e['all_day']}, {e['start_date']} → {e['end_date']}")

        # 6 — the day after DST ends.
        ok, sc = call(s, "create_event", {"calendar": dev_cal, "title": "parity 6 dentist", "start": "2026-11-02T09:00:00-08:00"})
        e = sc["data"]["event"]; made_events.append(e["id"])
        case(6, e["start"] == "2026-11-02T17:00:00.000Z", f"start {e['start']} (09:00 PST), tz {e.get('time_zone')}")

        # 7–9 — biweekly series, one-occurrence edit, truncate.
        ok, sc = call(s, "create_event", {"calendar": dev_cal, "title": "parity 7 planning",
                                          "start": "2026-10-06T10:00:00-07:00", "end": "2026-10-06T10:30:00-07:00",
                                          "recurrence": {"frequency": "weekly", "interval": 2, "days_of_week": ["tuesday"], "until": "2027-06-30"}})
        rule = sc["data"]["event"]["recurrence_rules"][0]; series = sc["data"]["event"]["id"]
        case(7, rule["interval"] == 2 and rule["days_of_week"][0]["weekday"] == 3 and rule["end"]["kind"] == "date",
             f"weekly ×{rule['interval']} on weekday {rule['days_of_week'][0]['weekday']}, end {rule['end']}")
        window = {"from": "2026-10-01T00:00:00Z", "to": "2026-12-01T00:00:00Z", "calendar_ids": [dev_cal], "text": "parity 7"}
        occ = call(s, "list_events", window)[1]["data"]
        ok, sc = call(s, "update_event", {"locator": occ[1]["locator"], "if_match": occ[1]["version"],
                                          "recurrence_scope": "this_occurrence",
                                          "patch": {"start": "2026-10-20T11:00:00-07:00", "end": "2026-10-20T11:30:00-07:00"}})
        after = call(s, "list_events", window)[1]["data"]
        moved = [o["start"] for o in after if o["start"].startswith("2026-10-20")]
        others = [o["start"][11:16] for o in after if not o["start"].startswith("2026-10-20")]
        case(8, ok and moved == ["2026-10-20T18:00:00.000Z"] and set(others) == {"17:00"},
             f"Oct 20 moved to {moved}, others still at {sorted(set(others))} UTC")
        third = [o for o in after if o["start"].startswith("2026-11-03")][0]
        ok, sc = call(s, "delete_event", {"locator": third["locator"], "if_match": third["version"], "recurrence_scope": "this_and_future"})
        left = call(s, "list_events", window)[1]["data"]
        case(9, ok and len(left) == 2, f"{len(after)} occurrences in window → {len(left)} after this_and_future from Nov 3")
        first = [o for o in left if o["start"].startswith("2026-10-06")][0]
        call(s, "delete_event", {"locator": first["locator"], "recurrence_scope": "this_and_future"})
        for o in call(s, "list_events", window)[1]["data"]:  # the detached Oct 20 occurrence
            call(s, "delete_event", {"locator": o["locator"]} if o.get("locator") else {"identifier": o["id"]})

        # 10 — complete a repeating reminder.
        ok, sc = call(s, "create_reminder", {"list": dev_list, "title": "parity 10 bins weekly", "due": "2026-10-05",
                                             "recurrence": {"frequency": "weekly"}})
        rid = sc["data"]["result_identifier"]; made_reminders.append(rid)
        ok, sc = call(s, "complete_reminder", {"identifier": rid})
        r = sc["data"]["reminder"]
        case(10, ok and not r["completed"] and r["due"]["day"] == 12 and "note" in sc["data"],
             f"series now due {r['due']['year']}-{r['due']['month']:02d}-{r['due']['day']:02d}; note: {sc['data'].get('note', '')[:60]}…")

        # 11 — an invitation from someone else (real data; the bogus if_match means nothing
        # can be written even if the refusal were missing).
        span = {"from": (today - datetime.timedelta(days=365)).isoformat() + "T00:00:00Z",
                "to": (today + datetime.timedelta(days=365)).isoformat() + "T00:00:00Z", "limit": 200, "include_details": True}
        invite = None
        cursor = None
        while invite is None:
            page = call(s, "list_events", {**span, **({"cursor": cursor} if cursor else {})})[1]
            invite = next((e for e in page["data"] if e.get("organizer") and not e["organizer"].get("is_current_user")
                           and any(p.get("is_current_user") for p in e.get("participants", []))), None)
            cursor = page["pagination"]["next_cursor"]
            if not cursor:
                break
        if invite:
            target = {"locator": invite["locator"]} if invite.get("locator") else {"identifier": invite["id"]}
            ok, sc = call(s, "update_event", {**target, "if_match": "deliberately-wrong", "recurrence_scope": "this_occurrence",
                                              "patch": {"title": "x"}})
            case(11, not ok and sc.get("code") == "unsupported", f"{sc.get('code')}: {sc.get('error', '')[:70]}…")
        else:
            case(11, True, "no invitation from someone else in the last/next year to test against")

        # 12 — read-only calendar.
        birthdays = next((c["id"] for c in cals if c.get("type", {}).get("name") == "birthday"), None)
        ok, sc = call(s, "create_event", {"calendar": birthdays, "title": "parity 12", "start": "2026-12-01T10:00:00Z"})
        case(12, not ok and sc.get("code") == "read_only", f"{sc.get('code')}: {sc.get('error')}")

        # 13 — RSVP has no tool.
        tools = [t["name"] for t in s.call_raw("tools/list", {})[0]["result"]["tools"]]
        case(13, not any("respond" in t or "rsvp" in t for t in tools), "no respond/RSVP tool is exposed")

        # 14 — create (and remove) a list.
        ok, sc = call(s, "create_reminder_list", {"title": "RCC parity Garden"})
        list_id = sc["data"]["result_identifier"]
        ok2, _ = call(s, "delete_reminder_list", {"list": list_id})
        case(14, ok and ok2, f"created in {sc['data']['list']['source_title']}, then removed")

        # 15 — priority.
        ok, sc = call(s, "update_reminder", {"identifier": made_reminders[0], "patch": {"priority": "high"}})
        case(15, ok and sc["data"]["reminder"]["priority"] == 1, f"priority {sc['data']['reminder']['priority']} ({sc['data']['reminder']['priority_bucket']})")

        # 16 — due window semantics: day-only today is due today, not overdue.
        ok, sc = call(s, "create_reminder", {"list": dev_list, "title": "parity 16 today", "due": today.isoformat()})
        made_reminders.append(sc["data"]["result_identifier"])
        titles = lambda w: [r["title"] for r in call(s, "list_reminders", {"due_window": w, "calendar_ids": [dev_list]})[1]["data"]]
        case(16, "parity 16 today" in titles("overdue_or_today") and "parity 16 today" not in titles("overdue"),
             f"overdue_or_today ∋ it, overdue ∌ it")

        # 17 — batch completion is one call.
        ok, sc = call(s, "complete_reminders", {"items": [{"identifier": i} for i in made_reminders[:2]]})
        case(17, ok and sc["data"]["succeeded"] == 2, f"1 call, {sc['data']['succeeded']} completed")

        # 18 — destructive tools are annotated so Desktop confirms them.
        listed = {t["name"]: t for t in s.call_raw("tools/list", {})[0]["result"]["tools"]}
        destructive = sorted(n for n, t in listed.items() if t.get("annotations", {}).get("destructiveHint"))
        case(18, destructive == ["delete_event", "delete_reminder", "delete_reminder_list"], f"destructiveHint: {destructive}")
    finally:
        # Completing a repeating reminder spawns a completed copy rcc did not create
        # directly, so sweep the dev list for anything this script titled.
        leftovers = call(s, "list_reminders", {"calendar_ids": [dev_list], "completion": "any",
                                               "text": "parity", "limit": 200})[1].get("data", [])
        for rid in set(made_reminders) | {r["id"] for r in leftovers}:
            call(s, "delete_reminder", {"identifier": rid})
        for eid in made_events:
            call(s, "delete_event", {"identifier": eid})
        s.close()

    failed = [n for n, ok, _ in results if not ok]
    print(f"\n{len(results) - len(failed)}/{len(results)} cases as expected" + (f"; FAILED: {failed}" if failed else ""))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
