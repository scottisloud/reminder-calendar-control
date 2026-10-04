#!/usr/bin/env bash
#
# release.sh — build, notarize and publish rcc to the public Homebrew tap.
#
# Usage: Scripts/release.sh [--dry-run] [--tap-dir DIR]
#
# The tap repo (scottisloud/homebrew-tap) holds only what users download: the cask, the
# curl installer, its README, and the notarized `rcc.zip` attached to a GitHub Release
# tagged `rcc-v<version>`. Source stays in this private repo. Signing needs this Mac's
# Developer ID, so releases are cut here rather than in CI.
#
# Steps: refuse a dirty tree or an existing tag → build-release.sh --notarize → confirm
# notarization → zip + sha256 → render the cask → sync distribution/homebrew-tap/ into the
# tap checkout → create the GitHub Release → commit and push the tap.
#
# --dry-run does everything up to (not including) the release and the push, leaving the
# rendered tap checkout for inspection.
#
# Environment: RCC_NOTARY_PROFILE (required; passed through to build-release.sh).
set -euo pipefail

readonly PROG="${0##*/}"
log() { printf '[%s] %s\n' "$PROG" "$*" >&2; }
die() { printf '[%s] ERROR: %s\n' "$PROG" "$*" >&2; exit 1; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TAP_REPO="scottisloud/homebrew-tap"
TAP_DIR="$ROOT/../homebrew-tap"
DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --tap-dir) TAP_DIR="$2"; shift 2 ;;
    *) die "unknown option: $1" ;;
  esac
done

[ -n "${RCC_NOTARY_PROFILE:-}" ] || die "set RCC_NOTARY_PROFILE to your notarytool keychain profile"
VERSION="$(sed -n 's/^ *public static let version = "\(.*\)"$/\1/p' Sources/RCCCore/BuildInfo.swift)"
[ -n "$VERSION" ] || die "could not read the version from Sources/RCCCore/BuildInfo.swift"
TAG="rcc-v$VERSION"

if [ "$DRY_RUN" -eq 0 ]; then
  git diff --quiet HEAD && [ -z "$(git ls-files --others --exclude-standard Sources Package.swift Resources)" ] \
    || die "the working tree is dirty; a release must be built from a commit"
fi
if gh release view "$TAG" --repo "$TAP_REPO" >/dev/null 2>&1; then
  die "$TAG already exists in $TAP_REPO; bump the version in Sources/RCCCore/BuildInfo.swift"
fi

# The tap checkout: clone it if absent, and never release over local edits.
if [ ! -d "$TAP_DIR/.git" ]; then
  log "cloning $TAP_REPO into $TAP_DIR"
  gh repo clone "$TAP_REPO" "$TAP_DIR"
fi
git -C "$TAP_DIR" diff --quiet HEAD 2>/dev/null || die "$TAP_DIR has uncommitted changes"
git -C "$TAP_DIR" pull --quiet --ff-only 2>/dev/null || true

log "building $VERSION"
BIN="$("$ROOT/Scripts/build-release.sh" --notarize | tail -n 1)"
[ -f "$BIN" ] || die "no artifact at $BIN"
codesign --verify --strict -R=notarized "$BIN" || die "$BIN is not notarized"

OUT="$ROOT/.build/release-artifacts/$TAG"
rm -rf "$OUT"
mkdir -p "$OUT/stage"
cp "$BIN" "$OUT/stage/rcc"
# ditto without --keepParent puts `rcc` at the archive root, mode and signature intact.
/usr/bin/ditto -c -k "$OUT/stage" "$OUT/rcc.zip"
SHA="$(shasum -a 256 "$OUT/rcc.zip" | awk '{print $1}')"
printf '%s  rcc.zip\n' "$SHA" > "$OUT/rcc.zip.sha256"
log "rcc.zip sha256 $SHA"

# Sync the tap's contents from distribution/, rendering the cask.
mkdir -p "$TAP_DIR/Casks"
cp distribution/homebrew-tap/README.md distribution/homebrew-tap/install.sh "$TAP_DIR/"
chmod 755 "$TAP_DIR/install.sh"
sed -e "s/@VERSION@/$VERSION/" -e "s/@SHA256@/$SHA/" \
  distribution/homebrew-tap/Casks/rcc.rb.template > "$TAP_DIR/Casks/rcc.rb"
ruby -c "$TAP_DIR/Casks/rcc.rb" >/dev/null || die "rendered cask does not parse"

if [ "$DRY_RUN" -eq 1 ]; then
  log "dry run: artifacts in $OUT; rendered tap in $TAP_DIR (not committed, not released)"
  git -C "$TAP_DIR" status --short
  exit 0
fi

REVISION="$(git rev-parse --short HEAD)"
log "creating release $TAG on $TAP_REPO"
gh release create "$TAG" "$OUT/rcc.zip" "$OUT/rcc.zip.sha256" \
  --repo "$TAP_REPO" --title "rcc $VERSION" --latest \
  --notes "rcc $VERSION (source revision $REVISION). Install: \`brew install --cask scottisloud/tap/rcc\`"

git -C "$TAP_DIR" add -A
git -C "$TAP_DIR" commit --quiet -m "rcc $VERSION"
git -C "$TAP_DIR" push --quiet
log "released rcc $VERSION"
