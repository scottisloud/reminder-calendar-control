#!/usr/bin/env bash
#
# sign.sh — sign (and optionally notarize) the bare Mach-O `rcc`.
#
# Usage:
#   Scripts/sign.sh [options] <path-to-binary>
#
# Options:
#   --identifier <id>       Signing identifier. Default: CFBundleIdentifier from the
#                           embedded __TEXT,__info_plist, else the filename.
#   --entitlements <path>   Entitlements plist to seal in. Default: RCC_ENTITLEMENTS, else
#                           Resources/rcc-Entitlements.plist beside this repo. Pass "none"
#                           to sign with no entitlements.
#   --notarize              Submit to Apple's notary service and attempt to staple.
#   --allow-adhoc           Permit ad-hoc (`-s -`) signing. Never notarizable.
#   --keychain-profile <p>  notarytool keychain profile. Default: $RCC_NOTARY_PROFILE.
#   -h, --help              Show this help.
#
# Environment:
#   RCC_SIGN_IDENTITY   Signing identity. If unset, a unique "Developer ID Application"
#                       identity is auto-detected.
#   RCC_NOTARY_PROFILE  Default notarytool keychain profile name.
#   RCC_ENTITLEMENTS    Default entitlements plist path.
#
# Entitlements: rcc ships `com.apple.security.personal-information.{calendars,reminders}`.
# macOS 26.5 will not present a Calendar/Reminders TCC prompt for a Hardened-Runtime binary
# that lacks them (see docs/milestone-1b-findings.md). They are unrestricted keys — no
# provisioning profile, no App Sandbox. Do NOT add `com.apple.security.app-sandbox`: true
# kills a bare CLI with SIGTRAP before main(); false is a cdhash-churning no-op.
set -euo pipefail

readonly PROG="${0##*/}"
log()  { printf '[%s] %s\n' "$PROG" "$*" >&2; }
warn() { printf '[%s] WARNING: %s\n' "$PROG" "$*" >&2; }
die()  { printf '[%s] ERROR: %s\n' "$PROG" "$*" >&2; exit 1; }
# Print the comment block at the top of this file, stopping at the first non-comment line,
# so `--help` can never leak code (it used to end with `set -euo pipefail`).
usage() { awk 'NR>1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

BINARY=""
IDENTIFIER=""
NOTARIZE=0
ALLOW_ADHOC=0
KEYCHAIN_PROFILE="${RCC_NOTARY_PROFILE:-}"
ENTITLEMENTS="${RCC_ENTITLEMENTS:-$SCRIPT_DIR/../Resources/rcc-Entitlements.plist}"

while [ $# -gt 0 ]; do
  case "$1" in
    --identifier)       [ $# -ge 2 ] || die "--identifier needs a value";       IDENTIFIER="$2";       shift 2 ;;
    --entitlements)     [ $# -ge 2 ] || die "--entitlements needs a value";      ENTITLEMENTS="$2";     shift 2 ;;
    --keychain-profile) [ $# -ge 2 ] || die "--keychain-profile needs a value"; KEYCHAIN_PROFILE="$2"; shift 2 ;;
    --notarize)    NOTARIZE=1;    shift ;;
    --allow-adhoc) ALLOW_ADHOC=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    --)            shift; break ;;
    -*)            die "unknown option: $1" ;;
    *)             [ -z "$BINARY" ] || die "only one binary may be given"; BINARY="$1"; shift ;;
  esac
done
[ -n "${1:-}" ] && [ -z "$BINARY" ] && BINARY="$1"
[ -n "$BINARY" ] || { usage; exit 2; }
[ -f "$BINARY" ] || die "not a regular file: $BINARY"
file -b "$BINARY" | grep -q 'Mach-O' || die "not a Mach-O executable: $BINARY"

# codesign treats a directory that contains an Info.plist as a *bundle*: it would report
# Format=bundle, create _CodeSignature/CodeResources, and seal every sibling file into the
# signature. Refuse that layout rather than produce a silently wrong artifact.
BIN_DIR="$(cd "$(dirname "$BINARY")" && pwd)"
[ -e "$BIN_DIR/Info.plist" ] && die "$BIN_DIR contains Info.plist; codesign would treat it as a bundle. Move the binary to a clean directory."

resolve_identity() {
  if [ -n "${RCC_SIGN_IDENTITY:-}" ]; then printf '%s' "$RCC_SIGN_IDENTITY"; return 0; fi
  local found count
  found="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p')"
  [ -z "$found" ] && return 1
  count="$(printf '%s\n' "$found" | grep -c .)"
  if [ "$count" -gt 1 ]; then
    warn "multiple Developer ID Application identities found:"
    printf '%s\n' "$found" | sed 's/^/    /' >&2
    die "set RCC_SIGN_IDENTITY to disambiguate"
  fi
  printf '%s' "$found"
}

# Called once. Running it twice — the second time with stderr discarded — meant the
# multi-identity `die` lost its message *and* terminated the script from inside a discarded
# subshell, so the operator saw nothing at all.
IDENTITY=""
if identity_output="$(resolve_identity)"; then IDENTITY="$identity_output"; fi

ADHOC=0
if [ -z "$IDENTITY" ] || [ "$IDENTITY" = "-" ]; then
  [ "$ALLOW_ADHOC" -eq 1 ] || die "no 'Developer ID Application' identity found and --allow-adhoc was not given.
      Set RCC_SIGN_IDENTITY, or re-run with --allow-adhoc for a local-only build."
  IDENTITY="-"
  ADHOC=1
fi

if [ "$ADHOC" -eq 1 ]; then
  cat >&2 <<'BANNER'
################################################################################
#                        !!  AD-HOC SIGNATURE  !!                              #
#  The designated requirement is `cdhash H"..."` — pinned to THESE exact bytes.#
#  Any rebuild produces a new cdhash, invalidating the Calendar/Reminders TCC   #
#  grant and any Keychain ACL, so macOS re-prompts after every reinstall.       #
#  Cannot be notarized. Does NOT satisfy SPEC §18 Milestone 1's release gate.   #
#  See docs/milestone-1.md for the M1a / M1b split.                             #
################################################################################
BANNER
fi

# Read CFBundleIdentifier back out of the embedded section. `otool -P` prints it as text;
# `otool -s` prints byte-swapped words and is useless here. Stop at the first </plist>
# because a universal binary prints one copy per slice.
if [ -z "$IDENTIFIER" ]; then
  plist="$(otool -P "$BINARY" 2>/dev/null | awk '/<\?xml/{f=1} f{print} /<\/plist>/{if(f) exit}')"
  if [ -n "$plist" ]; then
    IDENTIFIER="$(printf '%s\n' "$plist" | plutil -extract CFBundleIdentifier raw -o - - 2>/dev/null || true)"
  fi
fi
if [ -z "$IDENTIFIER" ]; then
  IDENTIFIER="$(basename "$BINARY")"
  warn "no CFBundleIdentifier in an embedded __TEXT,__info_plist; falling back to '$IDENTIFIER'."
  warn "TCC keys Calendar/Reminders on the signing identifier — the plist must be embedded."
fi

# Pin the identifier explicitly. codesign derives it from the embedded plist anyway, but the
# two identities are independent and can silently diverge; pinning removes the possibility.
sign_args=(--sign "$IDENTITY" --force --options runtime --identifier "$IDENTIFIER")

# Seal in the entitlements unless the caller opted out with `--entitlements none`.
WANT_ENTITLEMENTS=1
case "$ENTITLEMENTS" in
  none|"") WANT_ENTITLEMENTS=0 ;;
  *)
    [ -f "$ENTITLEMENTS" ] || die "entitlements file not found: $ENTITLEMENTS (pass --entitlements none to sign without)"
    plutil -lint "$ENTITLEMENTS" >/dev/null || die "entitlements plist is malformed: $ENTITLEMENTS"
    sign_args+=(--entitlements "$ENTITLEMENTS")
    ;;
esac

# `--timestamp` is silently accepted with `-s -` and produces no timestamp at all.
if [ "$ADHOC" -eq 1 ]; then sign_args+=(--timestamp=none); else sign_args+=(--timestamp); fi

log "signing $BINARY as '$IDENTIFIER' with identity: $IDENTITY"
[ "$WANT_ENTITLEMENTS" -eq 1 ] && log "entitlements: $ENTITLEMENTS"
codesign "${sign_args[@]}" "$BINARY"

log "verifying"
codesign --verify --strict --verbose=2 "$BINARY"
codesign --display --requirements - "$BINARY" 2>&1 | sed 's/^/    /' >&2

# Capture the display block ONCE. Re-running `codesign -dvvv 2>&1 | grep` per check races
# under load (concurrent notarization, rapid rebuilds) and intermittently reports a false
# negative on a correctly signed binary.
DISPLAY_INFO="$(codesign --display --verbose=4 "$BINARY" 2>&1)"
printf '%s\n' "$DISPLAY_INFO" | sed 's/^/    /' >&2

# Guard against shipping SwiftPM's raw output, which is linker-signed with
# flags=0x20002(adhoc,linker-signed), Identifier=<filename>, and Info.plist=not bound.
printf '%s\n' "$DISPLAY_INFO" | grep -q 'linker-signed' \
  && die "still linker-signed — the codesign call above did not take effect"
printf '%s\n' "$DISPLAY_INFO" | grep -q '^Info.plist entries=' \
  || die "Info.plist is not sealed into the signature"

# The whole reason this file exists (docs/milestone-1b-findings.md): without these keys,
# macOS 26.5 will not present a Calendar/Reminders prompt for a Hardened-Runtime binary.
if [ "$WANT_ENTITLEMENTS" -eq 1 ]; then
  ENT_DUMP="$(codesign --display --entitlements - --xml "$BINARY" 2>/dev/null | plutil -convert xml1 -o - - 2>/dev/null || true)"
  for key in com.apple.security.personal-information.calendars com.apple.security.personal-information.reminders; do
    printf '%s\n' "$ENT_DUMP" | grep -q "$key" \
      || die "signed binary is missing the entitlement $key — the seal did not take"
  done
  log "entitlements sealed: personal-information.calendars + .reminders"
fi

if [ "$ADHOC" -eq 0 ]; then
  codesign --verify -R='anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists' \
    "$BINARY" || die "signature is not a Developer ID Application signature"
fi

if [ "$NOTARIZE" -eq 0 ]; then
  log "done (not notarizing; pass --notarize to submit)"
  if [ "$ADHOC" -eq 0 ]; then
    spctl --assess -vv --type exec "$BINARY" 2>&1 | sed 's/^/    /' >&2 \
      || warn "spctl rejects this binary — expected until notarized"
  fi
  exit 0
fi

[ "$ADHOC" -eq 0 ] || die "refusing to notarize an ad-hoc signature: the notary service requires a Developer ID certificate"
[ -n "$KEYCHAIN_PROFILE" ] || die "--keychain-profile (or RCC_NOTARY_PROFILE) is required for --notarize.
      Create one with:
        xcrun notarytool store-credentials <name> --apple-id <id> --team-id <team> --password <app-specific-password>"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/rcc-notarize.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT
ZIP="$WORKDIR/$(basename "$BINARY").zip"
log "packaging for notarization: $ZIP"
# notarytool refuses a bare Mach-O; it needs a .zip, .pkg, or .dmg. No --keepParent, which
# for a single file would embed the parent directory name in the archive.
/usr/bin/ditto -c -k "$BINARY" "$ZIP"

log "submitting to the notary service (this can take several minutes)"
if ! xcrun notarytool submit "$ZIP" --keychain-profile "$KEYCHAIN_PROFILE" --wait --timeout 30m; then
  warn "notarization failed; fetching the log for the most recent submission"
  submission_id="$(xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE" --output-format json 2>/dev/null \
                    | plutil -extract history.0.id raw -o - - 2>/dev/null || true)"
  [ -n "$submission_id" ] && { xcrun notarytool log "$submission_id" --keychain-profile "$KEYCHAIN_PROFILE" >&2 || true; }
  die "notarization failed"
fi

# stapler cannot staple a flat Mach-O, and does not say so: it parses the binary, queries
# CloudKit by cdhash, and fails with "Record not found" / Error 65, which reads like a
# notarization failure. Do not chase that.
log "attempting to staple (expected to fail for a bare executable)"
if xcrun stapler staple "$BINARY" 2>/dev/null; then
  log "ticket stapled"
else
  warn "could not staple a bare Mach-O — expected, not fatal.
      The ticket lives on Apple's servers and Gatekeeper fetches it online on first
      quarantined run. For an offline-capable artifact, wrap the binary in a .pkg or .dmg
      and notarize and staple that instead."
fi

spctl --assess -vv --type exec "$BINARY" 2>&1 | sed 's/^/    /' >&2 || warn "spctl assessment did not pass"
codesign --verify -R='notarized' --verbose=2 "$BINARY" 2>&1 | sed 's/^/    /' >&2 \
  || warn "does not yet satisfy 'notarized' (the ticket may not have propagated)"
log "done"
