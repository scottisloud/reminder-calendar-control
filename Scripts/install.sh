#!/usr/bin/env bash
#
# install.sh — build and atomically install rcc at its one authoritative path.
#
# Usage: Scripts/install.sh [--skip-build]
#
# Installs to ~/Library/Application Support/reminder-calendar-control/bin/rcc by writing a
# temp file in the same directory and rename()ing over the previous binary, so the path is
# never observed half-written (SPEC §6.1).
#
# This does NOT run `rcc setup`. Setup must be run from the installed path, by a human, so
# macOS records the Calendar/Reminders grant against the binary that everything else runs.
set -euo pipefail

readonly PROG="${0##*/}"
log() { printf '[%s] %s\n' "$PROG" "$*" >&2; }
die() { printf '[%s] ERROR: %s\n' "$PROG" "$*" >&2; exit 1; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DEST_DIR="$HOME/Library/Application Support/reminder-calendar-control/bin"
DEST="$DEST_DIR/rcc"

if [ "${1:-}" = "--skip-build" ]; then
  BIN_PATH="$(swift build -c release --show-bin-path)/rcc"
  [ -f "$BIN_PATH" ] || die "no release build at $BIN_PATH; drop --skip-build"
else
  BIN_PATH="$("$ROOT/Scripts/build-release.sh" | tail -n 1)"
fi
[ -f "$BIN_PATH" ] || die "no binary at $BIN_PATH"

mkdir -p "$DEST_DIR"
chmod 700 "$DEST_DIR"

PREVIOUS_CDHASH="$(codesign -dvvv "$DEST" 2>&1 | sed -n 's/^CDHash=//p' || true)"

# Temp file in the SAME directory, so the move below is a real rename(2) and therefore
# atomic. A temp file in /tmp could land on another filesystem and degrade to a copy, which
# leaves a window where the path is a truncated file.
TMP="$(mktemp "$DEST_DIR/.rcc.XXXXXX")"
trap 'rm -f "$TMP"' EXIT
cat "$BIN_PATH" > "$TMP"
chmod 755 "$TMP"
mv -f "$TMP" "$DEST"
trap - EXIT

NEW_CDHASH="$(codesign -dvvv "$DEST" 2>&1 | sed -n 's/^CDHash=//p' || true)"
log "installed: $DEST"
log "cdhash:    ${NEW_CDHASH:-unknown}"

if [ -n "$PREVIOUS_CDHASH" ] && [ "$PREVIOUS_CDHASH" != "$NEW_CDHASH" ]; then
  cat >&2 <<BANNER

The installed binary's code hash changed ($PREVIOUS_CDHASH -> $NEW_CDHASH).

Under an ad-hoc signature the designated requirement is the code hash itself, so macOS has
just invalidated the Calendar and Reminders grants. You will be re-prompted. This is
expected for an unsigned local build, not a bug — see docs/milestone-1.md.
BANNER
fi

cat >&2 <<BANNER

Next:
    "$DEST" setup --dev
    "$DEST" doctor

Then quit Claude Desktop fully (Cmd-Q) and relaunch; it does not reload its config file.
BANNER
