#!/usr/bin/env bash
# Paste your two Slack tokens; this writes them into config.env (kept private).
set -euo pipefail
cd "$(dirname "$0")"
echo "Paste the Bot token (starts with xoxb-) then press Enter:"
read -r BOT
echo "Paste the App-Level token (starts with xapp-) then press Enter:"
read -r APPT
CHAN="${1:?Slack channel or user ID required (e.g. U02KE6QGT99 or C...)}"
cat > config.env <<CFG
SLACK_BOT_TOKEN=$BOT
SLACK_APP_TOKEN=$APPT
SLACK_REVIEW_CHANNEL=$CHAN
CFG
chmod 600 config.env
# sanity check token prefixes
ok=1
case "$BOT" in xoxb-*) ;; *) echo "⚠️  Bot token doesn't start with xoxb-"; ok=0;; esac
case "$APPT" in xapp-*) ;; *) echo "⚠️  App token doesn't start with xapp-"; ok=0;; esac
[ "$ok" = 1 ] && echo "✅ Tokens saved to config.env (channel=$CHAN)."
