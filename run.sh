#!/usr/bin/env bash
# Daily morning mail triage runner. Invokes a headless Claude orchestrator that
# fans out one Haiku subagent per authenticated account.
set -uo pipefail

# Load the repo config (resolves MAIL_TRIAGE_DIR, MAIL_TRIAGE_PYTHON, etc.)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"

# cron/launchd give a minimal PATH; set everything the pipeline needs.
# Adjust this line if your tools live elsewhere (check `which gws`, `which claude`).
export PATH="/Users/light/.local/bin:/Users/light/.nvm/versions/node/v22.16.0/bin:/opt/homebrew/bin:/opt/homebrew/anaconda3/bin:/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin"
# Do NOT export HOME here — let the launchd plist / shell environment supply it.
export GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file

mkdir -p "$MAIL_TRIAGE_LOGS"
TS="$(date +%Y%m%d-%H%M%S)"
LOG="$MAIL_TRIAGE_LOGS/run-$TS.log"

# Track whether any step failed; launchd will see the exit code.
rc=0

cd "$MAIL_TRIAGE_DIR"

# Derive primary account config dir from accounts.json (no hardcoded path).
PRIMARY_CONFIG="$(/opt/homebrew/bin/python3 -c "
import json, sys
a = json.load(open('$MAIL_TRIAGE_ACCOUNTS'))
accts = a if isinstance(a, list) else a.get('accounts', [])
print(accts[0]['config_dir'])
")"
PRIMARY_EMAIL="$(/opt/homebrew/bin/python3 -c "
import json, sys
a = json.load(open('$MAIL_TRIAGE_ACCOUNTS'))
accts = a if isinstance(a, list) else a.get('accounts', [])
print(accts[0]['email'])
")"

# Derive the gws config parent directory from the primary account config_dir.
GWS_CONFIG_DIR="$(dirname "$PRIMARY_CONFIG")"

{
  echo "=== mail-triage run $TS ==="
  claude -p "$(cat "$MAIL_TRIAGE_DIR/TRIAGE.md")" \
    --model sonnet \
    --permission-mode bypassPermissions \
    --add-dir "$MAIL_TRIAGE_DIR" \
    --add-dir "$GWS_CONFIG_DIR" \
    || { echo "claude triage failed"; rc=1; }
  echo "=== triage done $(date +%H:%M:%S) ==="

  # --- Missed-items catch-up sweep (all accounts, in parallel) ---
  echo "--- missed-items catch-up sweep (14d, all accounts) ---"
  "$MAIL_TRIAGE_PYTHON" "$MAIL_TRIAGE_LIB/missed_sweep.py" 14 \
    || { echo "missed_sweep failed"; rc=1; }
  echo "=== catch-up done $(date +%H:%M:%S) ==="

  # --- Draft replies for primary account action items, then queue for Slack review ---
  echo "--- generating reply drafts ($PRIMARY_EMAIL) ---"
  "$MAIL_TRIAGE_PYTHON" "$MAIL_TRIAGE_LIB/gen_drafts.py" \
    "$PRIMARY_CONFIG" "$PRIMARY_EMAIL" 1d \
    || { echo "gen_drafts failed"; rc=1; }

  # --- Slack: morning briefing + draft cards + actionable missed-item cards ---
  SLACK_CONFIG="$MAIL_TRIAGE_DIR/slack_app/config.env"
  if [ -f "$SLACK_CONFIG" ] && grep -q '^SLACK_BOT_TOKEN=xoxb-' "$SLACK_CONFIG"; then
    echo "--- building briefing + posting to Slack ---"
    "$MAIL_TRIAGE_PYTHON" "$MAIL_TRIAGE_LIB/build_briefing.py" \
      || { echo "briefing build failed"; rc=1; }
    ( set -a; . "$SLACK_CONFIG"; set +a
      cd "$MAIL_TRIAGE_DIR/slack_app"
      ./venv/bin/python app.py brief      || { echo "slack brief failed"; rc=1; }
      ./venv/bin/python app.py post       || { echo "slack post failed"; rc=1; }
      ./venv/bin/python app.py post-missed "$MAIL_TRIAGE_DRAFTS/missed_today.json" \
        || { echo "slack post-missed failed"; rc=1; }
    )
  else
    echo "--- slack not configured yet; drafts queued only ---"
  fi
  echo "=== done $(date +%H:%M:%S) ==="
} >"$LOG" 2>&1

# keep a stable "latest" pointer
ln -sf "$LOG" "$MAIL_TRIAGE_LOGS/latest.log"

exit $rc
