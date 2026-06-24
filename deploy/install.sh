#!/usr/bin/env bash
# deploy/install.sh — Install (or reload) the launchd agents for mail-triage.
#
# This creates ~/Library/LaunchAgents/com.drewl.mailtriage.plist and
# com.drewl.maildraftreview.plist from the templates in this directory,
# substituting the real MAIL_TRIAGE_DIR and HOME paths.
#
# Run once after cloning and completing setup.sh:
#   bash deploy/install.sh
#
# To reload after changes:
#   bash deploy/install.sh --reload
#
# To unload (stop the agents without removing plists):
#   bash deploy/install.sh --unload
set -euo pipefail

# ---------------------------------------------------------------------------
# LEGACY (Slack pipeline). This installs the old run.sh daily job and the
# always-on Slack draft-review daemon. For the current product, use the keeper's
# own scheduler instead:  ./bin/zero schedule
# This script is kept only for the opt-in Slack/draft flow.
# ---------------------------------------------------------------------------
echo "NOTE: deploy/install.sh sets up the LEGACY Slack pipeline + run.sh daily job."
echo "      For the zero app, use: ./bin/zero schedule"
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../config.sh
source "$SCRIPT_DIR/../config.sh"

LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
mkdir -p "$LAUNCH_AGENTS_DIR"

TRIAGE_PLIST="$LAUNCH_AGENTS_DIR/com.drewl.mailtriage.plist"
SLACK_PLIST="$LAUNCH_AGENTS_DIR/com.drewl.maildraftreview.plist"

CMD="${1:-install}"

if [ "$CMD" = "--unload" ]; then
  echo "Unloading agents..."
  launchctl unload "$TRIAGE_PLIST" 2>/dev/null && echo "  unloaded triage" || echo "  triage was not loaded"
  launchctl unload "$SLACK_PLIST"  2>/dev/null && echo "  unloaded slack"  || echo "  slack was not loaded"
  exit 0
fi

# Generate the plists from templates.
echo "Installing launchd agents..."
echo "  MAIL_TRIAGE_DIR = $MAIL_TRIAGE_DIR"
echo "  HOME            = $HOME"

for template in "$SCRIPT_DIR"/*.plist.template; do
  name="$(basename "$template" .template)"
  dest="$LAUNCH_AGENTS_DIR/$name"

  sed \
    -e "s|__MAIL_TRIAGE_DIR__|$MAIL_TRIAGE_DIR|g" \
    -e "s|__HOME__|$HOME|g" \
    "$template" > "$dest"

  echo "  Written: $dest"
done

# Unload first if reloading.
if [ "$CMD" = "--reload" ]; then
  echo "Reloading..."
  launchctl unload "$TRIAGE_PLIST" 2>/dev/null || true
  launchctl unload "$SLACK_PLIST"  2>/dev/null || true
fi

# Load the agents.
launchctl load -w "$TRIAGE_PLIST" && echo "  Loaded: com.drewl.mailtriage"
launchctl load -w "$SLACK_PLIST"  && echo "  Loaded: com.drewl.maildraftreview"

echo ""
echo "Done. The triage job runs daily at 07:00. The Slack listener starts now."
echo "Logs will appear in: $MAIL_TRIAGE_DIR/logs/"
