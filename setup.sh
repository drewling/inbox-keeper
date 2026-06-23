#!/usr/bin/env bash
# setup.sh — First-time setup for mail-triage.
#
# Checks dependencies, creates the Slack app venv, and scaffolds config files.
# Safe to run multiple times (idempotent).
#
# After running this script:
#   1. Edit accounts.json with your Gmail accounts and gws config dirs.
#   2. Edit slack_app/config.env with your Slack tokens.
#   3. Run: bash deploy/install.sh     (to register the launchd agents)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"

ok=1
warn() { echo "  [WARN] $*"; ok=0; }
good() { echo "  [OK]   $*"; }
info() { echo "         $*"; }

echo ""
echo "=== mail-triage setup ==="
echo "Repo root: $MAIL_TRIAGE_DIR"
echo ""

# ---------------------------------------------------------------------------
# 1. Check dependencies
# ---------------------------------------------------------------------------
echo "Checking dependencies..."

if command -v gws >/dev/null 2>&1; then
  good "gws found: $(command -v gws)"
else
  warn "gws not found. Install from https://github.com/nicholasgasior/gws-cli or via npm."
  info "  brew install node && npm install -g @nicholasgasior/gws-cli"
fi

if command -v claude >/dev/null 2>&1; then
  good "claude CLI found: $(command -v claude)"
else
  warn "claude CLI not found. Install from https://github.com/anthropics/claude-code"
  info "  npm install -g @anthropic-ai/claude-code"
fi

if command -v python3 >/dev/null 2>&1; then
  good "python3 found: $(command -v python3) ($(python3 --version))"
else
  warn "python3 not found. Install via brew: brew install python3"
fi

if command -v jq >/dev/null 2>&1; then
  good "jq found: $(command -v jq)"
else
  warn "jq not found (optional but useful for debugging). brew install jq"
fi

echo ""

# ---------------------------------------------------------------------------
# 2. Create slack_app venv
# ---------------------------------------------------------------------------
echo "Setting up Slack app Python venv..."

VENV_DIR="$MAIL_TRIAGE_DIR/slack_app/venv"
if [ -d "$VENV_DIR" ]; then
  good "venv already exists: $VENV_DIR"
else
  python3 -m venv "$VENV_DIR"
  good "Created venv: $VENV_DIR"
fi

REQS="$MAIL_TRIAGE_DIR/slack_app/requirements.txt"
if [ -f "$REQS" ]; then
  "$VENV_DIR/bin/pip" install --quiet -r "$REQS"
  good "Installed Slack app requirements"
else
  warn "slack_app/requirements.txt not found — skipping pip install"
fi

echo ""

# ---------------------------------------------------------------------------
# 3. Scaffold config files
# ---------------------------------------------------------------------------
echo "Checking config files..."

SLACK_ENV="$MAIL_TRIAGE_DIR/slack_app/config.env"
SLACK_ENV_EXAMPLE="$MAIL_TRIAGE_DIR/slack_app/config.env.example"
if [ -f "$SLACK_ENV" ]; then
  good "slack_app/config.env already exists"
else
  if [ -f "$SLACK_ENV_EXAMPLE" ]; then
    cp "$SLACK_ENV_EXAMPLE" "$SLACK_ENV"
    good "Copied config.env.example → config.env"
    info "  Edit slack_app/config.env and fill in your Slack tokens."
  else
    warn "slack_app/config.env.example not found"
  fi
fi

ACCOUNTS_FILE="$MAIL_TRIAGE_DIR/accounts.json"
if [ -f "$ACCOUNTS_FILE" ]; then
  ACCT_COUNT="$(python3 -c "import json; d=json.load(open('$ACCOUNTS_FILE')); a=d if isinstance(d,list) else d.get('accounts',[]); print(len(a))")"
  good "accounts.json found ($ACCT_COUNT account(s))"
  info "  Edit accounts.json to add/remove Gmail accounts and set gws config dirs."
else
  warn "accounts.json not found. Create it — see docs/SETUP.md for format."
fi

echo ""

# ---------------------------------------------------------------------------
# 4. Create required directories
# ---------------------------------------------------------------------------
echo "Creating required directories..."
mkdir -p "$MAIL_TRIAGE_DIR/logs" && good "logs/"
mkdir -p "$MAIL_TRIAGE_DIR/drafts" && good "drafts/"

echo ""

# ---------------------------------------------------------------------------
# 5. Summary
# ---------------------------------------------------------------------------
if [ "$ok" -eq 1 ]; then
  echo "=== All checks passed. ==="
else
  echo "=== Some checks failed (see warnings above). Fix them before running. ==="
fi

echo ""
echo "Next steps:"
echo "  1. Authenticate each account with gws (see docs/SETUP.md)."
echo "  2. Edit accounts.json with your account slugs, emails, and gws config dirs."
echo "  3. Edit slack_app/config.env with your Slack bot/app tokens."
echo "  4. Run: bash deploy/install.sh     (installs and starts launchd agents)"
echo ""
