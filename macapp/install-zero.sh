#!/usr/bin/env bash
# install-zero.sh — one-command install for zero on a fresh Mac.
#
# Does everything a new user would otherwise do by hand:
#   1. Installs the prerequisites (Homebrew → Python 3 / Node → gws / claude CLIs)
#   2. Installs zero.app to /Applications
#   3. Removes the macOS quarantine flag and launches it
#
# WHY STEP 3 MATTERS: zero is signed ad-hoc, not notarized (no paid Apple
# Developer account). A *downloaded* app gets macOS's quarantine flag, and
# Gatekeeper rejects ad-hoc-signed quarantined apps — so double-clicking the DMG
# does nothing (a menu-bar app has no window, so the block looks like "nothing
# happened"). Stripping the quarantine flag is the standard, safe install path for
# un-notarized open-source Mac apps.
#
# Run it directly:
#     curl -fsSL https://raw.githubusercontent.com/drewling/zero/master/macapp/install-zero.sh | bash
#
# Or, if you already downloaded zero.dmg / zero.app, pass it:
#     bash install-zero.sh ~/Downloads/zero.dmg
#
# Re-running is safe: anything already installed is left alone.
set -uo pipefail   # NB: not -e — a single prereq failing must not abort the whole install.

DMG_URL="https://github.com/drewling/zero/releases/latest/download/zero.dmg"
APP_NAME="zero.app"
DEST="/Applications/$APP_NAME"
SRC="${1:-}"        # optional local .dmg or .app path

bold=$(tput bold 2>/dev/null || true); dim=$(tput dim 2>/dev/null || true); rst=$(tput sgr0 2>/dev/null || true)
step() { printf '\n%s==>%s %s%s\n' "$bold" "$rst" "$bold" "$* $rst"; }
ok()   { printf '    %sok%s  %s\n' "$dim" "$rst" "$*"; }
warn() { printf '    !!  %s\n' "$*" >&2; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

[ "$(uname)" = "Darwin" ] || die "zero is a macOS app."

# --- environment sanity (warn only; let the user proceed) ---
osver="$(sw_vers -productVersion 2>/dev/null || echo 0)"
[ "${osver%%.*}" -ge 26 ] 2>/dev/null || warn "zero needs macOS 26 (Tahoe); you're on $osver. It may not launch."
[ "$(uname -m)" = "arm64" ] || warn "zero is built for Apple Silicon; Intel is untested."

# Make a Homebrew install visible to this shell immediately after installing it.
load_brew() {
  for p in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    [ -x "$p" ] && eval "$("$p" shellenv)" && return 0
  done
  return 1
}

# ---------------------------------------------------------------------------
# 1. Prerequisites
# ---------------------------------------------------------------------------
step "Checking prerequisites"

have brew || load_brew || true
if ! have brew; then
  step "Installing Homebrew (the macOS package manager)"
  # NONINTERACTIVE so it runs unattended; it still uses sudo via /dev/tty for the
  # one-time Xcode command-line-tools step if those aren't present.
  NONINTERACTIVE=1 /bin/bash -c \
    "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
    </dev/tty 2>/dev/tty || warn "Homebrew install failed — install it from https://brew.sh, then re-run."
  load_brew || true
fi

ensure_brew_pkg() {        # ensure_brew_pkg <command> <formula> <label>
  local cmd="$1" formula="$2" label="$3"
  if have "$cmd"; then ok "$label already installed"; return; fi
  if have brew; then
    step "Installing $label"
    brew install "$formula" && ok "$label installed" || warn "couldn't install $label (brew install $formula)"
  else
    warn "$label missing and Homebrew unavailable — install $label manually."
  fi
}

ensure_npm_pkg() {         # ensure_npm_pkg <command> <package> <label>
  local cmd="$1" pkg="$2" label="$3"
  if have "$cmd"; then ok "$label already installed"; return; fi
  if ! have npm; then
    warn "$label missing and npm unavailable — install Node, then: npm install -g $pkg"
    return
  fi
  step "Installing $label"
  if npm install -g "$pkg" 2>/dev/null; then ok "$label installed"; return; fi
  # Stock Node installs make npm's global prefix (e.g. /usr/local) root-owned, so
  # -g fails with EACCES. Retry into ~/.local, which is already on the app's PATH
  # (augmentedPath in main.swift), so no sudo and the app still finds the binary.
  if npm install -g --prefix "$HOME/.local" "$pkg"; then
    ok "$label installed (to ~/.local/bin)"
  else
    warn "couldn't install $label (npm install -g $pkg)"
  fi
}

ensure_brew_pkg python3 python3 "Python 3"
ensure_brew_pkg node    node    "Node.js (for the CLIs below)"
ensure_npm_pkg  gws     @googleworkspace/cli      "Google Workspace CLI (gws)"
ensure_npm_pkg  claude  @anthropic-ai/claude-code "Claude Code CLI (claude)"

# ---------------------------------------------------------------------------
# 2. Locate the app (download the DMG unless a local source was given)
# ---------------------------------------------------------------------------
TMP=""; MNT=""
cleanup() {
  [ -n "$MNT" ] && hdiutil detach "$MNT" -quiet 2>/dev/null || true
  [ -n "$TMP" ] && rm -rf "$TMP" 2>/dev/null || true
}
trap cleanup EXIT

APP_SRC=""
if [ -n "$SRC" ] && [ -d "$SRC" ] && [[ "$SRC" == *.app ]]; then
  APP_SRC="$SRC"
else
  DMG="$SRC"
  if [ -z "$DMG" ]; then
    TMP="$(mktemp -d)"; DMG="$TMP/zero.dmg"
    step "Downloading the latest zero"
    curl -fL --progress-bar "$DMG_URL" -o "$DMG" || die "download failed ($DMG_URL)"
  fi
  [ -f "$DMG" ] || die "no such file: $DMG"
  step "Mounting $DMG"
  MNT="$(hdiutil attach "$DMG" -nobrowse -readonly -mountrandom /tmp | grep -Eo '/tmp/[^[:space:]]+' | tail -1)"
  { [ -n "$MNT" ] && [ -d "$MNT/$APP_NAME" ]; } || die "couldn't find $APP_NAME inside the DMG"
  APP_SRC="$MNT/$APP_NAME"
fi

# ---------------------------------------------------------------------------
# 3. Install + de-quarantine + launch
# ---------------------------------------------------------------------------
step "Installing to $DEST"
[ -e "$DEST" ] && { ok "replacing existing install"; rm -rf "$DEST"; }
cp -R "$APP_SRC" "$DEST" || die "couldn't copy to /Applications (permissions?)"

step "Removing the quarantine flag so Gatekeeper lets it run"
# Use the ABSOLUTE system xattr: a Python/Homebrew/Anaconda `xattr` earlier in PATH
# may not accept -r, which would make the strip silently fail and leave the app
# blocked (this is the exact trap that breaks the manual instructions).
/usr/bin/xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || \
  /usr/bin/xattr -cr "$DEST" 2>/dev/null || true
# Verify the flag is actually gone before claiming success.
if /usr/bin/xattr -lr "$DEST" 2>/dev/null | grep -q com.apple.quarantine; then
  warn "quarantine flag may still be present — if zero won't open, run: /usr/bin/xattr -cr '$DEST'"
else
  ok "quarantine cleared"
fi

codesign --verify "$DEST" 2>/dev/null && ok "signature valid" || ok "ad-hoc signature (expected)"

step "Launching zero"
open "$DEST"

printf '\n%sDone.%s zero is in your menu bar — the tray icon at the top-right. Click it to set up.\n' "$bold" "$rst"
