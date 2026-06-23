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
MAIL_TRIAGE_SLACK_APP="$MAIL_TRIAGE_DIR/slack_app"
MAIL_TRIAGE_DRAFTS="$MAIL_TRIAGE_DIR/drafts"
MAIL_TRIAGE_LOGS="$MAIL_TRIAGE_DIR/logs"
MAIL_TRIAGE_KNOWLEDGE="$MAIL_TRIAGE_DIR/knowledge"
MAIL_TRIAGE_QUEUE="$MAIL_TRIAGE_DRAFTS/queue.json"
MAIL_TRIAGE_ACCOUNTS="$MAIL_TRIAGE_DIR/accounts.json"

export MAIL_TRIAGE_LIB MAIL_TRIAGE_SLACK_APP MAIL_TRIAGE_DRAFTS
export MAIL_TRIAGE_LOGS MAIL_TRIAGE_KNOWLEDGE MAIL_TRIAGE_QUEUE MAIL_TRIAGE_ACCOUNTS
