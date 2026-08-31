#!/usr/bin/env bash
#
# install.sh — build and atomically install rcc at its one authoritative path.
#
# Usage: Scripts/install.sh [--skip-build] [--bundle]
#
# Default: installs the bare binary to
# ~/Library/Application Support/reminder-calendar-control/bin/rcc by writing a temp file in
# the same directory and rename()ing over the previous one, so the path is never observed
# half-written (SPEC §6.1).
#
# --bundle: installs RCC.app to the same product root instead. The bundle carries the app
# icon, which a bare Mach-O cannot — but replacing a directory is not a single rename, so
# there is a brief window where the path does not exist rather than an atomic swap. That is
# why bare remains the default.
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

BUNDLE=0
SKIP_BUILD=0
for arg in "$@"; do
  case "$arg" in
    --bundle)     BUNDLE=1 ;;
    --skip-build) SKIP_BUILD=1 ;;
    *) die "unknown option: $arg" ;;
  esac
done

if [ "$BUNDLE" -eq 1 ]; then
  [ "$SKIP_BUILD" -eq 0 ] || die "--skip-build is not supported with --bundle"
  APP_SRC="$("$ROOT/Scripts/make-app-bundle.sh" | tail -n 1)"
  [ -d "$APP_SRC" ] || die "no bundle at $APP_SRC"

  PRODUCT_ROOT="$HOME/Library/Application Support/reminder-calendar-control"
  APP_DEST="$PRODUCT_ROOT/RCC.app"
  mkdir -p "$PRODUCT_ROOT"
  chmod 700 "$PRODUCT_ROOT"

  PREVIOUS_CDHASH="$(codesign -dvvv "$APP_DEST" 2>&1 | sed -n 's/^CDHash=//p' || true)"

  # Stage beside the destination so the final move is a rename within one filesystem. A
  # directory cannot be renamed *over* a non-empty directory, so the old one is moved aside
  # first: the path is briefly absent, which is worse than the bare install's atomic swap
  # and is stated plainly rather than papered over.
  STAGE="$PRODUCT_ROOT/.RCC.app.incoming.$$"
  rm -rf "$STAGE"
  /usr/bin/ditto "$APP_SRC" "$STAGE"
  rm -rf "$PRODUCT_ROOT/.RCC.app.previous"
  [ -d "$APP_DEST" ] && mv "$APP_DEST" "$PRODUCT_ROOT/.RCC.app.previous"
  mv "$STAGE" "$APP_DEST"
  rm -rf "$PRODUCT_ROOT/.RCC.app.previous"

  NEW_CDHASH="$(codesign -dvvv "$APP_DEST" 2>&1 | sed -n 's/^CDHash=//p' || true)"
  log "installed: $APP_DEST"
  log "binary:    $APP_DEST/Contents/MacOS/rcc"
  log "cdhash:    ${NEW_CDHASH:-unknown}"

  if [ -e "$PRODUCT_ROOT/bin/rcc" ]; then
    log "NOTE: a bare binary is still installed at $PRODUCT_ROOT/bin/rcc."
    log "      rcc resolves to the bundle, but remove the bare copy to avoid a split install."
  fi
  if [ -n "$PREVIOUS_CDHASH" ] && [ "$PREVIOUS_CDHASH" != "$NEW_CDHASH" ]; then
    printf '\nThe installed code hash changed (%s -> %s); the TCC grant is invalidated.\n' \
      "$PREVIOUS_CDHASH" "$NEW_CDHASH" >&2
  fi
  cat >&2 <<BANNER

Next:
    "$APP_DEST/Contents/MacOS/rcc" setup --dev
    "$APP_DEST/Contents/MacOS/rcc" doctor
BANNER
  exit 0
fi

if [ "$SKIP_BUILD" -eq 1 ]; then
  BIN_PATH="$(swift build -c release --show-bin-path)/rcc"
  [ -f "$BIN_PATH" ] || die "no release build at $BIN_PATH; drop --skip-build"
else
  BIN_PATH="$("$ROOT/Scripts/build-release.sh" | tail -n 1)"
fi
[ -f "$BIN_PATH" ] || die "no binary at $BIN_PATH"

# --skip-build takes SwiftPM's raw output, which is only linker-signed: Identifier is the
# filename and the embedded Info.plist is NOT bound into the signature, so the usage strings
# TCC needs are unsealed. Refuse to install that at the authoritative path.
if codesign -dvvv "$BIN_PATH" 2>&1 | grep -q 'linker-signed'; then
  die "$BIN_PATH is only linker-signed — its Info.plist is not sealed.
      Run Scripts/build-release.sh (or Scripts/sign.sh --allow-adhoc \"$BIN_PATH\") first."
fi
codesign --verify --strict "$BIN_PATH" || die "signature verification failed for $BIN_PATH"
codesign -dvvv "$BIN_PATH" 2>&1 | grep -q '^Info.plist entries=' \
  || die "$BIN_PATH has no Info.plist sealed into its signature; TCC would have no usage strings"

# 0700 on the product root as well as bin/: SPEC §13 says local state is 0700, and
# `mkdir -p` creates intermediates at the default umask (0755), not the leaf's mode.
mkdir -p "$DEST_DIR"
chmod 700 "$(dirname "$DEST_DIR")"
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
