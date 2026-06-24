#!/usr/bin/env bash
# config.sh — Single source of truth for mail-triage shell configuration.
#
# Source this file from any shell script in the repo:
#   source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.sh"
#
# Environment variable overrides:
#   MAIL_TRIAGE_DIR   — override the repo root (default: directory of this file)
#   MAIL_TRIAGE_PYTHON — override the python binary (default: python3 from PATH)

# Resolve the repo root: use override if set, otherwise the directory this file lives in.
if [ -z "${MAIL_TRIAGE_DIR:-}" ]; then
  MAIL_TRIAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
export MAIL_TRIAGE_DIR

# Python binary: use override if set, otherwise python3 from PATH.
if [ -z "${MAIL_TRIAGE_PYTHON:-}" ]; then
  MAIL_TRIAGE_PYTHON="$(command -v python3 || echo python3)"
fi
export MAIL_TRIAGE_PYTHON

# Derived paths (all relative to MAIL_TRIAGE_DIR)
MAIL_TRIAGE_LIB="$MAIL_TRIAGE_DIR/lib"
MAIL_TRIAGE_LOGS="$MAIL_TRIAGE_DIR/logs"
MAIL_TRIAGE_KNOWLEDGE="$MAIL_TRIAGE_DIR/knowledge"
MAIL_TRIAGE_ACCOUNTS="$MAIL_TRIAGE_DIR/accounts.json"
# Legacy (opt-in Slack/draft pipeline only; not used by the keeper or the app):
MAIL_TRIAGE_SLACK_APP="$MAIL_TRIAGE_DIR/slack_app"
MAIL_TRIAGE_DRAFTS="$MAIL_TRIAGE_DIR/drafts"
MAIL_TRIAGE_QUEUE="$MAIL_TRIAGE_DRAFTS/queue.json"

export MAIL_TRIAGE_LIB MAIL_TRIAGE_SLACK_APP MAIL_TRIAGE_DRAFTS
export MAIL_TRIAGE_LOGS MAIL_TRIAGE_KNOWLEDGE MAIL_TRIAGE_QUEUE MAIL_TRIAGE_ACCOUNTS

# --- PATH for CLI tools (gws, claude, node, python3) ---
# launchd starts daemons with a minimal PATH (/usr/bin:/bin:/usr/sbin:/sbin), so the
# always-on Slack daemon and its subprocesses can't find gws/claude without this.
# Prepend common install locations that exist on this machine.
_mt_prepend() {
  case ":$PATH:" in
    *":$1:"*) ;;                       # already present
    *) [ -d "$1" ] && PATH="$1:$PATH" ;;
  esac
}
_mt_prepend "/opt/homebrew/bin"
_mt_prepend "/opt/homebrew/anaconda3/bin"
_mt_prepend "/usr/local/bin"
_mt_prepend "$HOME/.local/bin"          # claude
# nvm-managed node/gws: add every installed node bin dir (newest wins via prepend order)
if [ -d "$HOME/.nvm/versions/node" ]; then
  for _d in "$HOME"/.nvm/versions/node/*/bin; do
    [ -d "$_d" ] && _mt_prepend "$_d"
  done
fi
unset _d
export PATH
