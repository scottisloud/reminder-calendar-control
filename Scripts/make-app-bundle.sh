#!/usr/bin/env bash
#
# make-app-bundle.sh — wrap the built `rcc` in a headless RCC.app.
#
# Usage: Scripts/make-app-bundle.sh [--output <dir>]
#
# Produces <dir>/RCC.app containing the same binary the bare install uses, plus the app
# icon. The bundle is LSBackgroundOnly and LSUIElement: no dock tile, no menu bar item, no
# windows. It is a *packaging* shape, not a GUI — SPEC §3's "not a GUI app" still holds.
#
# Why a bundle exists at all, given SPEC §6.1 installs a bare binary:
#
#   * macOS reads an app icon from Contents/Resources/<CFBundleIconFile>.icns. There is no
#     linker section for icon data, so a bare Mach-O cannot carry one. The TCC dialog and
#     the System Settings > Privacy entry both render that icon.
#   * UserNotifications is unreachable from a bundle-less executable (docs/milestone-1.md
#     §5.10a), so the notification story in SPEC §6.1 needs this shape eventually.
#
# What it does NOT do: fix the TCC blocker. Measured directly — a headless .app, disclaimed,
# exec'd directly, still gets `granted=false` with no dialog (docs/milestone-1.md §1.0).
# This is packaging, not a workaround.
#
# The bare binary remains the default install. Bundle install has a brief window where the
# path does not exist (see install.sh), whereas the bare install is a true atomic rename.
set -euo pipefail

readonly PROG="${0##*/}"
log() { printf '[%s] %s\n' "$PROG" "$*" >&2; }
die() { printf '[%s] ERROR: %s\n' "$PROG" "$*" >&2; exit 1; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

OUTPUT_DIR="$ROOT/.build"
if [ "${1:-}" = "--output" ]; then
  [ $# -ge 2 ] || die "--output needs a value"
  OUTPUT_DIR="$2"
fi
mkdir -p "$OUTPUT_DIR"

BIN_PATH="$("$ROOT/Scripts/build-release.sh" | tail -n 1)"
[ -f "$BIN_PATH" ] || die "no binary at $BIN_PATH"

PLIST="$ROOT/Resources/rcc-Info.plist"
read_key() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null || true; }
BUNDLE_ID="$(read_key CFBundleIdentifier)"
SHORT_VERSION="$(read_key CFBundleShortVersionString)"
BUILD_VERSION="$(read_key CFBundleVersion)"
CALENDARS_USAGE="$(read_key NSCalendarsFullAccessUsageDescription)"
REMINDERS_USAGE="$(read_key NSRemindersFullAccessUsageDescription)"
[ -n "$BUNDLE_ID" ] || die "no CFBundleIdentifier in $PLIST"
[ -n "$CALENDARS_USAGE" ] && [ -n "$REMINDERS_USAGE" ] || die "usage descriptions missing from $PLIST"

APP="$OUTPUT_DIR/RCC.app"
STAGE="$OUTPUT_DIR/.RCC.app.staging.$$"
rm -rf "$STAGE"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"

# The inner executable keeps its own embedded __TEXT,__info_plist. Because it *is* the
# CFBundleExecutable, Bundle.main resolves to the .app and the two plists must agree on
# CFBundleIdentifier — otherwise `rcc doctor`'s self-report and whatever TCC keyed on would
# silently disagree. Both are generated from the same source values above.
cp "$BIN_PATH" "$STAGE/Contents/MacOS/rcc"
chmod 755 "$STAGE/Contents/MacOS/rcc"
cp "$ROOT/Resources/AppIcon.icns" "$STAGE/Contents/Resources/AppIcon.icns"

cat > "$STAGE/Contents/Info.plist" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>${BUNDLE_ID}</string>
	<key>CFBundleName</key>
	<string>rcc</string>
	<key>CFBundleDisplayName</key>
	<string>Reminders &amp; Calendar Control</string>
	<key>CFBundleExecutable</key>
	<string>rcc</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleShortVersionString</key>
	<string>${SHORT_VERSION}</string>
	<key>CFBundleVersion</key>
	<string>${BUILD_VERSION}</string>
	<key>LSMinimumSystemVersion</key>
	<string>26.0</string>
	<key>LSBackgroundOnly</key>
	<true/>
	<key>LSUIElement</key>
	<true/>
	<key>NSCalendarsFullAccessUsageDescription</key>
	<string>${CALENDARS_USAGE}</string>
	<key>NSRemindersFullAccessUsageDescription</key>
	<string>${REMINDERS_USAGE}</string>
</dict>
</plist>
PLIST_EOF
plutil -lint "$STAGE/Contents/Info.plist" >/dev/null || die "generated bundle Info.plist is malformed"

# Sign the bundle as a whole. codesign derives the identifier from Contents/Info.plist and
# seals Contents/Resources, so the icon is covered by the signature.
codesign --sign "${RCC_SIGN_IDENTITY:--}" --force --options runtime \
  --identifier "$BUNDLE_ID" \
  $([ -n "${RCC_SIGN_IDENTITY:-}" ] && printf '%s' "--timestamp" || printf '%s' "--timestamp=none") \
  "$STAGE"
codesign --verify --strict --verbose=2 "$STAGE"

rm -rf "$APP"
mv "$STAGE" "$APP"
trap - EXIT

log "bundle:     $APP"
log "identifier: $(codesign -dvvv "$APP" 2>&1 | sed -n 's/^Identifier=//p')"
log "icon:       $(du -h "$APP/Contents/Resources/AppIcon.icns" | cut -f1)"
printf '%s\n' "$APP"
