#!/usr/bin/env bash
# Daily morning mail triage runner. Runs the same keeper engine the app uses
# (review_open_loops.py) across every authenticated account, then refreshes the
# panel's cached state and sweeps for missed items. Opt in via `zero schedule`.
set -uo pipefail

# Load the repo config (resolves MAIL_TRIAGE_DIR, MAIL_TRIAGE_PYTHON, etc.)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"

# cron/launchd give a minimal PATH; set everything the pipeline needs.
# Adjust this line if your tools live elsewhere (check `which gws`, `which claude`).
export PATH="/opt/homebrew/bin:/opt/homebrew/anaconda3/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
# Do NOT export HOME here — let the launchd plist / shell environment supply it.
export GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file
unset GOOGLE_WORKSPACE_CLI_TOKEN

mkdir -p "$MAIL_TRIAGE_LOGS"
TS="$(date +%Y%m%d-%H%M%S)"
LOG="$MAIL_TRIAGE_LOGS/run-$TS.log"

# Track whether any step failed; launchd will see the exit code.
rc=0

cd "$MAIL_TRIAGE_DIR"

{
  echo "=== zero run $TS ==="

  # --- Demote automated/no-reply mail out of ⚡ Action (deterministic guard) ---
  # The LLM triage occasionally promotes Google security alerts, billing notices,
  # etc. to ⚡ Action. This pass moves them to 🔔 Services so the action count stays real.
  echo "--- demoting automated mail out of Action (all accounts) ---"
  /opt/homebrew/bin/python3 -c "
import json
a = json.load(open('$MAIL_TRIAGE_ACCOUNTS'))
accts = a if isinstance(a, list) else a.get('accounts', [])
for acct in accts:
    print(acct['config_dir'] + '\t' + acct.get('email', acct['config_dir']))
" | while IFS=$'\t' read -r cfg email; do
    "$MAIL_TRIAGE_PYTHON" "$MAIL_TRIAGE_LIB/demote_automated.py" "$cfg" "$email" --execute \
      || { echo "demote_automated failed for $email"; rc=1; }
  done
  echo "=== demote done $(date +%H:%M:%S) ==="

  # --- Open-loop maintenance: archive threads already dealt with (reversible) ---
  # Keeps the inbox at "only what still needs you". grace 0 = review the whole
  # inbox and trust the keep-bar; genuine fresh mail is kept, noise is set aside.
  echo "--- open-loop sweep (all accounts, grace 0) ---"
  /opt/homebrew/bin/python3 -c "
import json
a = json.load(open('$MAIL_TRIAGE_ACCOUNTS'))
accts = a if isinstance(a, list) else a.get('accounts', [])
for acct in accts:
    print(acct['config_dir'] + '\t' + acct.get('email', acct['config_dir']))
" | while IFS=$'\t' read -r cfg email; do
    "$MAIL_TRIAGE_PYTHON" "$MAIL_TRIAGE_LIB/review_open_loops.py" "$cfg" "$email" --grace-days 0 --execute \
      || { echo "open-loop sweep failed for $email"; rc=1; }
  done
  echo "=== open-loop done $(date +%H:%M:%S) ==="

  # --- Learn from the user's recent actions, then refresh the panel's state ---
  echo "--- learning from recent actions + refreshing panel state ---"
  "$MAIL_TRIAGE_PYTHON" "$MAIL_TRIAGE_LIB/learn.py" || echo "learn step skipped"
  "$MAIL_TRIAGE_PYTHON" "$MAIL_TRIAGE_LIB/dashboard_state.py" \
    || { echo "dashboard_state refresh failed"; rc=1; }
  echo "=== panel state refreshed $(date +%H:%M:%S) ==="

  # --- Missed-items catch-up sweep (all accounts, in parallel) ---
  echo "--- missed-items catch-up sweep (14d, all accounts) ---"
  "$MAIL_TRIAGE_PYTHON" "$MAIL_TRIAGE_LIB/missed_sweep.py" 14 \
    || { echo "missed_sweep failed"; rc=1; }
  echo "=== catch-up done $(date +%H:%M:%S) ==="

  # Reply drafting happens on demand inside the app (tap Reply on a loop);
  # the daily run does not pre-generate drafts.
  echo "=== done $(date +%H:%M:%S) ==="
} >"$LOG" 2>&1

# keep a stable "latest" pointer
ln -sf "$LOG" "$MAIL_TRIAGE_LOGS/latest.log"

exit $rc
