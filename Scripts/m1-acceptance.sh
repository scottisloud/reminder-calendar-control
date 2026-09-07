#!/usr/bin/env bash
#
# m1-acceptance.sh — run SPEC §18 Milestone 1's acceptance matrix.
#
# Usage: Scripts/m1-acceptance.sh [--results-dir <dir>]
#
# Milestone 1 is done when "a fresh install can read and write the dev calendar/list from
# Terminal, manual config, and a LaunchAgent, with `rcc doctor` reporting healthy and
# exactly one re-exec observed in each context".
#
# This script exercises all three launch contexts against the *installed* binary and
# asserts, per context:
#
#   * exactly one re-exec  (generation == 1, and no second one)
#   * the process is TCC-responsible for itself (responsible_pid == pid)
#   * an event and a reminder were written to the dev fixtures, read back, and deleted
#
# It does NOT cover the Developer ID / notarization half of the gate; that needs a signing
# certificate this machine does not have. See docs/milestone-1.md for the M1a / M1b split.
#
# Prerequisites: Scripts/install.sh, then `<installed rcc> setup --dev`.
set -uo pipefail

readonly PROG="${0##*/}"
log()  { printf '\n[%s] %s\n' "$PROG" "$*"; }
pass() { printf '  PASS  %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; FAILURES=$((FAILURES + 1)); }
info() { printf '        %s\n' "$*"; }

FAILURES=0
RCC="$HOME/Library/Application Support/reminder-calendar-control/bin/rcc"
RESULTS_DIR="${TMPDIR:-/tmp}/rcc-m1-acceptance.$$"
if [ "${1:-}" = "--results-dir" ]; then
  [ $# -ge 2 ] || { printf '[%s] ERROR: --results-dir needs a value\n' "$PROG" >&2; exit 2; }
  RESULTS_DIR="$2"
  shift 2
fi
# Absolute: context 3 runs under launchd, whose cwd is `/`, so a relative path would put the
# LaunchAgent's output somewhere the harness never looks.
mkdir -p "$RESULTS_DIR" || { printf '[%s] ERROR: cannot create %s\n' "$PROG" "$RESULTS_DIR" >&2; exit 2; }
RESULTS_DIR="$(cd "$RESULTS_DIR" && pwd -P)"
# Clear prior artifacts: the launchd wait loop below breaks as soon as a result file is
# non-empty, so a reused directory would make it assert against the PREVIOUS run.
rm -f "$RESULTS_DIR"/*.json "$RESULTS_DIR"/*.log "$RESULTS_DIR"/*.stdout "$RESULTS_DIR"/*.stderr 2>/dev/null || true

if [ ! -x "$RCC" ]; then
  printf '[%s] ERROR: no installed binary at %s\n' "$PROG" "$RCC" >&2
  printf '        Run Scripts/install.sh, then "%s" setup --dev\n' "$RCC" >&2
  exit 7
fi

UID_NUM="$(id -u)"
LABEL_PREFIX="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' /dev/stdin \
  <<<"$(otool -P "$RCC" | awk '/<\?xml/{f=1} f{print} /<\/plist>/{if(f) exit}')" 2>/dev/null \
  || echo com.scottlougheed.reminder-calendar-control)"
PROBE_LABEL="${LABEL_PREFIX}.m1probe"
PROBE_PLIST="$RESULTS_DIR/$PROBE_LABEL.plist"

printf 'rcc Milestone 1 acceptance matrix\n'
printf 'binary:  %s\n' "$RCC"
printf 'results: %s\n' "$RESULTS_DIR"

# ---------------------------------------------------------------------------
# Assertion helper. Reads a selftest JSON result and checks every invariant.
# ---------------------------------------------------------------------------
assert_result() {
  local context="$1" file="$2"
  if [ ! -s "$file" ]; then
    fail "$context: no result written to $file"
    return
  fi
  # When the run failed before it could measure anything, the payload carries an `error`
  # instead of the full result. Report that first: "generation is -1" is true but useless
  # next to "Calendar access was not granted".
  local why
  why="$(/usr/bin/plutil -extract error raw -o - "$file" 2>/dev/null)" || why=""
  if [ -n "$why" ]; then
    fail "$context: $why"
    return
  fi

  local passed disclaim gen pid responsible trips
  passed="$(/usr/bin/plutil -extract passed raw -o - "$file" 2>/dev/null || echo false)"
  disclaim="$(/usr/bin/plutil -extract disclaim.outcome raw -o - "$file" 2>/dev/null || echo '?')"
  gen="$(/usr/bin/plutil -extract disclaim.generation raw -o - "$file" 2>/dev/null || echo -1)"
  pid="$(/usr/bin/plutil -extract disclaim.pid raw -o - "$file" 2>/dev/null || echo -1)"
  responsible="$(/usr/bin/plutil -extract disclaim.responsible_pid raw -o - "$file" 2>/dev/null || echo -2)"
  trips="$(/usr/bin/plutil -extract round_trips raw -o - "$file" 2>/dev/null | head -n 1 || echo 0)"

  [ "$gen" = "1" ] \
    && pass "$context: exactly one re-exec (generation 1)" \
    || fail "$context: generation is $gen, expected 1"

  [ "$disclaim" = "disclaimed" ] \
    && pass "$context: disclaim outcome is 'disclaimed'" \
    || fail "$context: disclaim outcome is '$disclaim'"

  [ "$pid" = "$responsible" ] \
    && pass "$context: TCC holds rcc responsible for itself (pid $pid)" \
    || fail "$context: responsible pid is $responsible but our pid is $pid"

  [ "$trips" = "2" ] \
    && pass "$context: both entity types round-tripped" \
    || fail "$context: $trips round trips, expected 2"

  [ "$passed" = "true" ] \
    && pass "$context: selftest reports PASS" \
    || fail "$context: selftest reports FAIL"
}

# `RCC_DISCLAIM event=reexec` appears exactly once per launch. More than one means the
# one-time guard leaked; zero means the mechanism never engaged.
assert_single_reexec() {
  local context="$1" stderr_file="$2"
  local count
  # `grep -c` prints 0 *and* exits 1 when there are no matches, so a `|| echo 0` fallback
  # would make $count the two-line string "0\n0". Suppress the exit status instead.
  count="$(grep -c 'RCC_DISCLAIM event=reexec' "$stderr_file" 2>/dev/null)" || true
  [ -n "$count" ] || count=0
  [ "$count" = "1" ] \
    && pass "$context: exactly one 'reexec' line on stderr" \
    || fail "$context: $count 'reexec' lines on stderr, expected 1"
}

# ---------------------------------------------------------------------------
# Context 1 — Terminal
# ---------------------------------------------------------------------------
log 'Context 1/3: Terminal'
"$RCC" selftest --context terminal --json --out "$RESULTS_DIR/terminal.json" \
  >"$RESULTS_DIR/terminal.stdout" 2>"$RESULTS_DIR/terminal.stderr"
info "exit $?"
assert_result terminal "$RESULTS_DIR/terminal.json"
assert_single_reexec terminal "$RESULTS_DIR/terminal.stderr"

# ---------------------------------------------------------------------------
# Context 2 — spawned as a child over stdio, the way Claude Desktop runs `rcc serve`
# ---------------------------------------------------------------------------
log 'Context 2/3: MCP child process over stdio (as Claude Desktop spawns it)'
{
  printf '%s\n' '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"m1-acceptance","version":"1"}}}'
  printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
  printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"run_platform_selftest","arguments":{}}}'
} | "$RCC" serve >"$RESULTS_DIR/mcp.stdout" 2>"$RESULTS_DIR/mcp.stderr"
info "exit $?"

/usr/bin/python3 - "$RESULTS_DIR/mcp.stdout" "$RESULTS_DIR/mcp.json" <<'PY'
import json, sys
frames = []
for line in open(sys.argv[1]):
    line = line.strip()
    if line:
        frames.append(json.loads(line))
# The notification must not be answered: exactly three responses for four inputs.
print(f"        {len(frames)} response frames for 4 requests (one is a notification)")
by_id = {f.get("id"): f for f in frames if "id" in f}
tools = by_id.get(1, {}).get("result", {}).get("tools", [])
print(f"        tools/list advertised: {[t['name'] for t in tools]}")
call = by_id.get(2, {}).get("result", {})
structured = call.get("structuredContent", {})
json.dump(structured, open(sys.argv[2], "w"), indent=2)
PY

RESPONSES="$(grep -c . "$RESULTS_DIR/mcp.stdout" 2>/dev/null || echo 0)"
[ "$RESPONSES" = "3" ] \
  && pass "mcp: 3 responses for 4 frames (the notification was correctly not answered)" \
  || fail "mcp: $RESPONSES responses, expected 3"
if /usr/bin/python3 -c '
import json, sys
for n, line in enumerate(open(sys.argv[1]), 1):
    line = line.strip()
    if not line:
        continue
    try:
        json.loads(line)
    except Exception as exc:
        print(f"        line {n} is not JSON: {line[:80]!r} ({exc})")
        sys.exit(1)
sys.exit(0)
' "$RESULTS_DIR/mcp.stdout"; then
  pass "mcp: every stdout line parses as JSON"
else
  fail "mcp: stdout is not pure JSON — something leaked past the quarantine"
fi
assert_result mcp "$RESULTS_DIR/mcp.json"
assert_single_reexec mcp "$RESULTS_DIR/mcp.stderr"

# ---------------------------------------------------------------------------
# Context 3 — LaunchAgent
# ---------------------------------------------------------------------------
log 'Context 3/3: launchd LaunchAgent'
cat > "$PROBE_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$PROBE_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$RCC</string>
        <string>selftest</string>
        <string>--context</string><string>launchagent</string>
        <string>--json</string>
        <string>--out</string><string>$RESULTS_DIR/launchagent.json</string>
    </array>
    <key>RunAtLoad</key><false/>
    <key>StandardOutPath</key><string>$RESULTS_DIR/launchagent.stdout</string>
    <key>StandardErrorPath</key><string>$RESULTS_DIR/launchagent.stderr</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key><string>$HOME</string>
        <key>PATH</key><string>/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
</dict>
</plist>
PLIST
# launchd refuses a group- or world-writable plist, and reports it as the same generic
# "Input/output error" as every other bootstrap failure.
chmod 644 "$PROBE_PLIST"

cleanup_probe() { launchctl bootout "gui/$UID_NUM/$PROBE_LABEL" >/dev/null 2>&1 || true; }
trap cleanup_probe EXIT
cleanup_probe
# `enable` before `bootstrap`: a stale disable record is persistent, root-owned, survives
# bootout, and makes bootstrap fail outright.
launchctl enable "gui/$UID_NUM/$PROBE_LABEL" >/dev/null 2>&1 || true

# bootstrap/bootout, never load/unload — the legacy verbs always exit 0, even on failure.
if launchctl bootstrap "gui/$UID_NUM" "$PROBE_PLIST"; then
  pass "launchagent: bootstrapped $PROBE_LABEL"
  launchctl kickstart -kp "gui/$UID_NUM/$PROBE_LABEL" >/dev/null 2>&1 || true
  for _ in $(seq 1 60); do
    [ -s "$RESULTS_DIR/launchagent.json" ] && break
    /bin/sleep 0.5
  done
  assert_result launchagent "$RESULTS_DIR/launchagent.json"
  assert_single_reexec launchagent "$RESULTS_DIR/launchagent.stderr"
  info "last exit code: $(launchctl print "gui/$UID_NUM/$PROBE_LABEL" 2>/dev/null | sed -n 's/.*last exit code = //p' | head -n 1)"
else
  fail "launchagent: bootstrap failed"
fi
cleanup_probe
trap - EXIT

# ---------------------------------------------------------------------------
# Whole-install health
# ---------------------------------------------------------------------------
log 'rcc doctor'
"$RCC" doctor --json >"$RESULTS_DIR/doctor.json" 2>"$RESULTS_DIR/doctor.stderr"
DOCTOR_EXIT=$?
OVERALL="$(/usr/bin/plutil -extract overall raw -o - "$RESULTS_DIR/doctor.json" 2>/dev/null || echo '?')"
info "overall: $OVERALL (exit $DOCTOR_EXIT)"
[ "$DOCTOR_EXIT" = "0" ] \
  && pass "doctor: no failing checks" \
  || fail "doctor: $(/usr/bin/python3 -c '
import json,sys
r=json.load(open(sys.argv[1]))
print(", ".join(c["id"] for c in r["checks"] if c["status"]=="fail"))' "$RESULTS_DIR/doctor.json" 2>/dev/null)"

# ---------------------------------------------------------------------------
# Exit codes (SPEC §16)
# ---------------------------------------------------------------------------
log 'Exit-code contract'
check_exit() {
  local label="$1" expected="$2"; shift 2
  "$@" >/dev/null 2>&1
  local actual=$?
  [ "$actual" = "$expected" ] \
    && pass "$label exits $expected" \
    || fail "$label exits $actual, expected $expected"
}
check_exit "--version"      0 "$RCC" --version
check_exit "--help"         0 "$RCC" --help
check_exit "an unknown flag" 2 "$RCC" --no-such-flag
check_exit "an unknown subcommand" 2 "$RCC" no-such-subcommand

# ---------------------------------------------------------------------------
log 'Summary'
if [ "$FAILURES" -eq 0 ]; then
  printf '  Milestone 1 PASSED — all three launch contexts read and wrote the dev fixtures,\n'
  printf '  and rcc doctor is healthy. Run against a Developer-ID-signed, entitled, notarized\n'
  printf '  build for the full M1b gate; see docs/milestone-1b-findings.md.\n'
  printf '  Results: %s\n' "$RESULTS_DIR"
  exit 0
fi
printf '  %d assertion(s) failed. Results: %s\n' "$FAILURES" "$RESULTS_DIR"
exit 1
