#!/usr/bin/env python3
"""benchmark.py — measure rcc against SPEC §7.3's resource budget.

Usage:
    Scripts/benchmark.py [--iterations N] [--json out.json]

Runs the *installed* binary (the TCC grant is keyed to its path) through Claude Desktop's
own `disclaimer` helper, exactly the way Desktop spawns `rcc serve`, so the numbers are
for the real launch context. Read-only: it never writes to Calendar or Reminders.

Measures:
  - `serve` startup (spawn → initialize answered), idle CPU (mean/p95 of per-second
    samples over 60 s), RSS and physical footprint after warm-up;
  - read latency p50/p95 and response size for representative queries over the real
    data on this Mac, including the largest windows it holds;
  - `automations run` (the LaunchAgent's no-op firing) cold start: wall, CPU, max RSS;
  - memory under sustained load: footprint after every 5 of 25 back-to-back ten-year
    `list_events` queries (stands in for a long-uptime soak, which was dropped at M5).
"""
import argparse, datetime, json, os, re, statistics, subprocess, sys, time

RCC = os.path.expanduser("~/Library/Application Support/reminder-calendar-control/bin/rcc")
DISCLAIMER = "/Applications/Claude.app/Contents/Helpers/disclaimer"


class Server:
    def __init__(self):
        t0 = time.perf_counter()
        self.proc = subprocess.Popen([DISCLAIMER, "--pgroup", "--", RCC, "serve"],
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.DEVNULL, text=True, bufsize=1)
        self.next_id = 1
        self.call_raw("initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
                                     "clientInfo": {"name": "benchmark", "version": "1"}})
        self.startup_s = time.perf_counter() - t0
        self.notify("notifications/initialized")
        self.pid = self._find_pid()

    def _find_pid(self):
        # rcc re-execs itself once (the self-disclaim); the serving process is the newest
        # `rcc serve` in this process group.
        out = subprocess.run(["pgrep", "-n", "-f", re.escape(RCC) + " serve"],
                             capture_output=True, text=True).stdout.strip()
        return int(out) if out else None

    def notify(self, method):
        self.proc.stdin.write(json.dumps({"jsonrpc": "2.0", "method": method}) + "\n")
        self.proc.stdin.flush()

    def call_raw(self, method, params):
        msg = {"jsonrpc": "2.0", "id": self.next_id, "method": method, "params": params}
        self.next_id += 1
        self.proc.stdin.write(json.dumps(msg) + "\n")
        self.proc.stdin.flush()
        while True:
            line = self.proc.stdout.readline()
            if not line:
                raise SystemExit("rcc serve exited")
            reply = json.loads(line)
            if reply.get("id") == msg["id"]:
                return reply, len(line.encode())

    def tool(self, name, args):
        t0 = time.perf_counter()
        reply, size = self.call_raw("tools/call", {"name": name, "arguments": args})
        elapsed = time.perf_counter() - t0
        result = reply.get("result", {})
        if result.get("isError"):
            raise SystemExit(f"{name} failed: {result.get('structuredContent')}")
        return elapsed, size, result.get("structuredContent", {})

    def close(self):
        self.proc.stdin.close()
        self.proc.wait(timeout=10)


def cpu_seconds(pid):
    """Cumulative user+system CPU time of `pid`, in seconds (ps `time`: [d-]hh:mm:ss.cc)."""
    raw = subprocess.run(["ps", "-o", "time=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    if not raw:
        return None
    days = 0
    if "-" in raw:
        d, raw = raw.split("-", 1)
        days = int(d)
    parts = [float(p) for p in raw.split(":")]
    while len(parts) < 3:
        parts.insert(0, 0.0)
    h, m, s = parts
    return days * 86400 + h * 3600 + m * 60 + s


def memory(pid):
    """(RSS MB, physical footprint MB). Footprint is what Activity Monitor calls Memory."""
    rss_kb = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    rss = int(rss_kb) / 1024 if rss_kb else None
    fp = None
    out = subprocess.run(["footprint", "-p", str(pid)], capture_output=True, text=True).stdout
    m = re.search(r"Footprint:\s+([\d.]+)\s*(KB|MB|GB)", out) or re.search(r"phys_footprint:\s+([\d.]+)\s*(KB|MB|GB)", out)
    if m:
        value, unit = float(m.group(1)), m.group(2)
        fp = value / 1024 if unit == "KB" else value * 1024 if unit == "GB" else value
    return rss, fp


def pct(values, p):
    ordered = sorted(values)
    if not ordered:
        return None
    k = (len(ordered) - 1) * p / 100
    lo, hi = int(k), min(int(k) + 1, len(ordered) - 1)
    return ordered[lo] + (ordered[hi] - ordered[lo]) * (k - lo)


def iso(dt):
    return dt.astimezone().isoformat(timespec="seconds")


def queries():
    now = datetime.datetime.now().astimezone()
    week = now + datetime.timedelta(days=7)
    two_years_ago = now - datetime.timedelta(days=730)
    year_ahead = now + datetime.timedelta(days=365)
    return [
        ("list_reminders overdue_or_today", "list_reminders", {"due_window": "overdue_or_today"}),
        ("list_reminders incomplete (page 50)", "list_reminders", {"completion": "incomplete"}),
        ("list_reminders all, page 200", "list_reminders", {"completion": "any", "limit": 200}),
        ("list_reminders all, page 200, details", "list_reminders", {"completion": "any", "limit": 200, "include_details": True}),
        ("search_reminders text", "search_reminders", {"text": "the", "completion": "any"}),
        ("list_events next 7 days", "list_events", {"from": iso(now), "to": iso(week)}),
        ("list_events 3 years, page 200", "list_events", {"from": iso(two_years_ago), "to": iso(year_ahead), "limit": 200}),
        ("list_events 3 years, page 200, details", "list_events", {"from": iso(two_years_ago), "to": iso(year_ahead), "limit": 200, "include_details": True}),
        ("search_events 3 years", "search_events", {"from": iso(two_years_ago), "to": iso(year_ahead), "text": "the"}),
        ("list_events 10 years (chunked)", "list_events", {"from": iso(now - datetime.timedelta(days=3650)), "to": iso(now), "limit": 50}),
        ("list_calendars", "list_calendars", {}),
    ]


def benchmark(iterations):
    report = {"rcc": RCC, "measured_at": iso(datetime.datetime.now()),
              "host": {k: subprocess.run(c, capture_output=True, text=True).stdout.strip() for k, c in {
                  "macos": ["sw_vers", "-productVersion"], "build": ["sw_vers", "-buildVersion"],
                  "cpu": ["sysctl", "-n", "machdep.cpu.brand_string"],
                  "memory_bytes": ["sysctl", "-n", "hw.memsize"]}.items()}}

    starts = []
    for _ in range(5):
        s = Server(); starts.append(s.startup_s); s.close()
    report["serve_startup_s"] = {"p50": pct(starts, 50), "p95": pct(starts, 95), "n": len(starts)}

    server = Server()
    status = server.tool("get_system_status", {})[2]
    report["rcc_version"] = status.get("rcc_version")
    report["memory_after_start_mb"] = dict(zip(("rss", "footprint"), memory(server.pid)))

    latency = {}
    for label, name, args in queries():
        times, sizes, matched = [], [], None
        for _ in range(iterations):
            t, size, sc = server.tool(name, args)
            times.append(t); sizes.append(size)
            matched = (sc.get("pagination") or {}).get("total_matched", matched)
        latency[label] = {"p50_ms": round(pct(times, 50) * 1000, 1), "p95_ms": round(pct(times, 95) * 1000, 1),
                          "max_ms": round(max(times) * 1000, 1), "response_kb": round(max(sizes) / 1024, 1),
                          "total_matched": matched, "n": iterations}
        print(f"  {label:42s} p50 {latency[label]['p50_ms']:7.1f} ms  p95 {latency[label]['p95_ms']:7.1f} ms  "
              f"{latency[label]['response_kb']:7.1f} KB  matched {matched}", file=sys.stderr)
    report["read_latency"] = latency
    report["memory_after_queries_mb"] = dict(zip(("rss", "footprint"), memory(server.pid)))

    # Idle: per-second CPU over 60 s with no requests in flight.
    samples, prev = [], cpu_seconds(server.pid)
    for _ in range(60):
        time.sleep(1)
        cur = cpu_seconds(server.pid)
        samples.append((cur - prev) * 100); prev = cur
    report["idle_cpu_percent"] = {"mean": round(statistics.mean(samples), 3), "p95": round(pct(samples, 95), 3),
                                  "window_s": 60, "resolution": "ps cputime, 10 ms"}
    report["memory_idle_mb"] = dict(zip(("rss", "footprint"), memory(server.pid)))
    server.close()

    # Sustained load: does memory come back, or ratchet? (A leak here measured +27 MB per
    # large query before EventKit fetches were wrapped in autorelease pools.)
    server = Server()
    label, name, args = next(q for q in queries() if q[0].startswith("list_events 10 years"))
    footprints = []
    for i in range(25):
        server.tool(name, args)
        if i % 5 == 4:
            footprints.append(round(memory(server.pid)[1] or 0, 1))
    report["memory_sustained_load_mb"] = {"query": label, "footprint_after_every_5": footprints}
    server.close()

    # LaunchAgent firing: `automations run`, launched directly as launchd does.
    runs = []
    for _ in range(iterations):
        out = subprocess.run(["/usr/bin/time", "-l", RCC, "automations", "run"], capture_output=True, text=True).stderr
        real = float(re.search(r"([\d.]+) real", out).group(1))
        user = float(re.search(r"([\d.]+) user", out).group(1))
        sys_ = float(re.search(r"([\d.]+) sys", out).group(1))
        rss = int(re.search(r"(\d+)\s+maximum resident set size", out).group(1)) / 1024 / 1024
        runs.append((real, user + sys_, rss))
    report["automations_run_cold_start"] = {
        "wall_p50_ms": round(pct([r[0] for r in runs], 50) * 1000, 1),
        "wall_p95_ms": round(pct([r[0] for r in runs], 95) * 1000, 1),
        "cpu_p50_ms": round(pct([r[1] for r in runs], 50) * 1000, 1),
        "max_rss_mb": round(max(r[2] for r in runs), 1), "n": len(runs),
        "note": "/usr/bin/time real/user+sys have 10 ms resolution"}
    return report


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--iterations", type=int, default=25)
    ap.add_argument("--json")
    a = ap.parse_args()
    report = benchmark(a.iterations)
    text = json.dumps(report, indent=2)
    if a.json:
        open(a.json, "w").write(text + "\n")
    print(text)


if __name__ == "__main__":
    main()
