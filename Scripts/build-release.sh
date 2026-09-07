#!/usr/bin/env bash
#
# build-release.sh — produce the signed release artifact.
#
# Usage: Scripts/build-release.sh [--notarize]
#
# Generates the embedded Info.plist with build metadata, forces a relink, builds Release,
# verifies the section landed, and signs.
set -euo pipefail

readonly PROG="${0##*/}"
log() { printf '[%s] %s\n' "$PROG" "$*" >&2; }
die() { printf '[%s] ERROR: %s\n' "$PROG" "$*" >&2; exit 1; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Expanded below as ${NOTARIZE_ARGS[@]+"${NOTARIZE_ARGS[@]}"}: on bash 3.2 — the /bin/bash
# every stock Mac still ships — "${empty_array[@]}" under `set -u` is a fatal
# "unbound variable", so the +alternate form is required, not stylistic.
NOTARIZE_ARGS=()
[ "${1:-}" = "--notarize" ] && NOTARIZE_ARGS=(--notarize)

# Version is single-sourced from Sources/RCCCore/BuildInfo.swift.
VERSION="$(sed -n 's/^ *public static let version = "\(.*\)"$/\1/p' Sources/RCCCore/BuildInfo.swift)"
[ -n "$VERSION" ] || die "could not read the version from Sources/RCCCore/BuildInfo.swift"
GIT_REVISION="$(git rev-parse --short HEAD 2>/dev/null || echo '')"
# `git diff --quiet HEAD` only sees tracked modifications, but SwiftPM globs the target
# directories and compiles untracked .swift files too — so an untracked source file would
# otherwise be attributed to a clean revision.
if [ -n "$GIT_REVISION" ]; then
  if ! git diff --quiet HEAD 2>/dev/null || [ -n "$(git ls-files --others --exclude-standard Sources Package.swift Resources 2>/dev/null)" ]; then
    GIT_REVISION="${GIT_REVISION}-dirty"
  fi
fi
log "version $VERSION${GIT_REVISION:+ +$GIT_REVISION}"

# Generate the plist that gets linked in. It is *sealed* by the code signature, so it has to
# be correct before linking — patching a signed binary yields "invalid Info.plist" and the
# kernel SIGKILLs the process.
GENERATED_PLIST="$ROOT/.build/rcc-Info.generated.plist"
mkdir -p "$(dirname "$GENERATED_PLIST")"
cp Resources/rcc-Info.plist "$GENERATED_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$GENERATED_PLIST"
if [ -n "$GIT_REVISION" ]; then
  /usr/libexec/PlistBuddy -c "Add :RCC_GIT_REVISION string $GIT_REVISION" "$GENERATED_PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :RCC_GIT_REVISION $GIT_REVISION" "$GENERATED_PLIST"
fi
plutil -lint "$GENERATED_PLIST" >/dev/null || die "generated plist is malformed"

export RCC_INFO_PLIST="$GENERATED_PLIST"

BIN_PATH="$(swift build -c release --show-bin-path)/rcc"
# SwiftPM does not track the plist as a link input: editing it alone reports "Build
# complete!" in a tenth of a second and leaves the old section embedded, and touching a
# source file is not enough either because llbuild content-hashes the object. Deleting the
# product is the only reliable way to force the relink.
rm -f "$BIN_PATH"
log "building release"
swift build -c release

[ -f "$BIN_PATH" ] || die "expected a binary at $BIN_PATH"

log "verifying the embedded Info.plist"
EMBEDDED="$(otool -P "$BIN_PATH" | awk '/<\?xml/{f=1} f{print} /<\/plist>/{if(f) exit}')"
[ -n "$EMBEDDED" ] || die "no __TEXT,__info_plist section in the built binary"
printf '%s\n' "$EMBEDDED" | plutil -lint - >/dev/null || die "embedded plist is malformed"
for key in CFBundleIdentifier NSCalendarsFullAccessUsageDescription NSRemindersFullAccessUsageDescription; do
  printf '%s\n' "$EMBEDDED" | plutil -extract "$key" raw -o - - >/dev/null 2>&1 \
    || die "embedded plist is missing $key"
done
# The macOS 26 floor means the pre-14 keys must not be present (SPEC §6.3).
for key in NSCalendarsUsageDescription NSRemindersUsageDescription; do
  if printf '%s\n' "$EMBEDDED" | plutil -extract "$key" raw -o - - >/dev/null 2>&1; then
    die "embedded plist carries the legacy key $key"
  fi
done
EMBEDDED_VERSION="$(printf '%s\n' "$EMBEDDED" | plutil -extract CFBundleShortVersionString raw -o - -)"
[ "$EMBEDDED_VERSION" = "$VERSION" ] \
  || die "embedded CFBundleShortVersionString is $EMBEDDED_VERSION but the source says $VERSION (stale relink?)"

"$ROOT/Scripts/sign.sh" --allow-adhoc ${NOTARIZE_ARGS[@]+"${NOTARIZE_ARGS[@]}"} "$BIN_PATH"

log "artifact: $BIN_PATH"
printf '%s\n' "$BIN_PATH"
