#!/usr/bin/env bash
# setup.sh — First-time setup for mail-triage.
#
# Checks dependencies and scaffolds config files.
# Safe to run multiple times (idempotent).
#
# After running this script:
#   1. Edit accounts.json with your Gmail accounts and gws config dirs.
#   2. Authenticate each account: GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file gws auth login
#   3. Run: ./bin/zero app
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
  warn "gws not found."
  info "  brew install node && npm install -g @googleworkspace/cli"
fi

if command -v claude >/dev/null 2>&1; then
  good "claude CLI found: $(command -v claude)"
else
  warn "claude CLI not found."
  info "  npm install -g @anthropic-ai/claude-code && claude"
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
# 2. Scaffold config files
# ---------------------------------------------------------------------------
echo "Checking config files..."

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
# 3. Create required directories
# ---------------------------------------------------------------------------
echo "Creating required directories..."
mkdir -p "$MAIL_TRIAGE_DIR/logs" && good "logs/"
mkdir -p "$MAIL_TRIAGE_DIR/drafts" && good "drafts/"

echo ""

# ---------------------------------------------------------------------------
# 4. Summary
# ---------------------------------------------------------------------------
if [ "$ok" -eq 1 ]; then
  echo "=== All checks passed. ==="
else
  echo "=== Some checks failed (see warnings above). Fix them before running. ==="
fi

echo ""
echo "Next steps:"
echo "  1. Edit accounts.json with your account slugs, emails, and gws config dirs."
echo "  2. Authenticate each account:"
echo "     GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file gws auth login"
echo "  3. Open the app:  ./bin/zero app"
echo "  4. Schedule daily triage:  ./bin/zero schedule"
echo ""
