#!/bin/bash
#
# Install rcc — Calendar and Reminders for Claude Desktop.
#
#   curl -fsSL https://raw.githubusercontent.com/scottisloud/homebrew-tap/main/install.sh | bash
#
# Uses Homebrew when it is installed (so `brew upgrade` keeps rcc current); otherwise
# downloads the latest notarized release, verifies its checksum, Developer ID signature
# and notarization, and installs it directly. Either way it then runs `rcc setup`, which
# asks macOS for Calendar and Reminders access — in this terminal if there is one, or in a
# new Terminal window if not (an AI agent running this has no screen to show prompts on).
#
# Options:
#   --no-brew    Install directly even if Homebrew is present.
#   --no-setup   Install only; run `rcc setup` yourself later.
#
# Never changes Calendar or Reminders data.
set -euo pipefail

TAP="scottisloud/tap"
REPO="scottisloud/homebrew-tap"
TEAM_ID="T879Q2BE7Q"
STABLE="$HOME/Library/Application Support/reminder-calendar-control/bin/rcc"

if [ -t 1 ]; then BOLD=$'\033[1m' RESET=$'\033[0m'; else BOLD="" RESET=""; fi
say() { printf '%s==>%s %s\n' "$BOLD" "$RESET" "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

USE_BREW=1
RUN_SETUP=1
for arg in "$@"; do
  case "$arg" in
    --no-brew)  USE_BREW=0 ;;
    --no-setup) RUN_SETUP=0 ;;
    *) die "unknown option: $arg" ;;
  esac
done

[ "$(uname -s)" = "Darwin" ] || die "rcc runs on macOS only."
[ "$(uname -m)" = "arm64" ] || die "rcc is built for Apple silicon (arm64) only."
MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
[ "$MAJOR" -ge 26 ] || die "rcc needs macOS 26 or later (this is $(sw_vers -productVersion))."

if [ "$USE_BREW" -eq 1 ] && command -v brew >/dev/null 2>&1; then
  say "Installing with Homebrew"
  brew install --cask "$TAP/rcc"
else
  WORK="$(mktemp -d)"
  trap 'rm -rf "$WORK"' EXIT
  # RCC_RELEASE_BASE_URL exists only to rehearse this script against a local file:// copy.
  BASE="${RCC_RELEASE_BASE_URL:-https://github.com/$REPO/releases/latest/download}"

  say "Downloading the latest release"
  curl -fsSL "$BASE/rcc.zip" -o "$WORK/rcc.zip"
  curl -fsSL "$BASE/rcc.zip.sha256" -o "$WORK/rcc.zip.sha256"

  EXPECTED="$(awk '{print $1}' "$WORK/rcc.zip.sha256")"
  ACTUAL="$(shasum -a 256 "$WORK/rcc.zip" | awk '{print $1}')"
  [ -n "$EXPECTED" ] && [ "$EXPECTED" = "$ACTUAL" ] || die "checksum mismatch (expected $EXPECTED, got $ACTUAL)."

  /usr/bin/ditto -x -k "$WORK/rcc.zip" "$WORK/x"
  BIN="$WORK/x/rcc"
  [ -f "$BIN" ] || die "the release archive has no rcc binary."

  say "Verifying signature and notarization"
  codesign --verify --strict "$BIN" || die "signature verification failed."
  SIG="$(codesign -dvv "$BIN" 2>&1 || true)"
  printf '%s\n' "$SIG" | grep -qx "TeamIdentifier=$TEAM_ID" || die "not signed by the expected team ($TEAM_ID)."
  codesign --verify -R=notarized "$BIN" 2>/dev/null || die "the binary is not notarized."

  LINK_DIR="/opt/homebrew/bin"
  [ -d "$LINK_DIR" ] && [ -w "$LINK_DIR" ] || LINK_DIR="$HOME/.local/bin"
  "$BIN" install --link "$LINK_DIR"
  case ":$PATH:" in
    *":$LINK_DIR:"*) ;;
    *) say "Note: $LINK_DIR is not on your PATH; add it, or run rcc as \"$STABLE\"." ;;
  esac
fi

[ "$RUN_SETUP" -eq 1 ] || { say "Installed. Run \`rcc setup\` in Terminal to finish."; exit 0; }

# A person at a terminal: run setup right here (reading answers from the terminal, since
# this script's stdin is the curl pipe). No terminal — an agent, or a script: open setup in
# a new Terminal window, where the permission dialogs have someone to answer them.
if (exec </dev/tty) 2>/dev/null; then
  say "Running rcc setup"
  exec "$STABLE" setup </dev/tty
fi

COMMAND_FILE="$(mktemp -d)/rcc-setup.command"
cat >"$COMMAND_FILE" <<EOF
#!/bin/bash
clear
"$STABLE" setup
echo
read -r -n 1 -p "Press any key to close this window."
EOF
chmod +x "$COMMAND_FILE"
open "$COMMAND_FILE"
say "rcc is installed. A Terminal window has opened running \`rcc setup\`:"
say "approve the Calendar and Reminders prompts there to finish."
