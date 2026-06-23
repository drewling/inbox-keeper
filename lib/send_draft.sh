#!/usr/bin/env bash
# send_draft.sh <config_dir> <draft_id>
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../config.sh
source "$SCRIPT_DIR/../config.sh"
exec "$MAIL_TRIAGE_PYTHON" "$SCRIPT_DIR/draftutil.py" send --config-dir "$1" --draft-id "$2"
