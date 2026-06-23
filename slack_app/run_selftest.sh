#!/usr/bin/env bash
# Run the Slack app self-test in the SAME environment the launchd daemon uses:
# config.sh sets PATH (so gws/claude resolve), config.env provides Slack tokens.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.sh"
cd "$SCRIPT_DIR"
set -a; . ./config.env; set +a
exec ./venv/bin/python selftest.py
