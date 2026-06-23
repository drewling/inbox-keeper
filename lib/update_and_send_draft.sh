#!/usr/bin/env bash
# update_and_send_draft.sh <config_dir> <draft_id> <thread_id> <to> <subject_b64> <body_b64>
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../config.sh
source "$SCRIPT_DIR/../config.sh"
exec "$MAIL_TRIAGE_PYTHON" "$SCRIPT_DIR/draftutil.py" update-send \
  --config-dir "$1" --draft-id "$2" --thread-id "$3" --to "$4" --subject-b64 "$5" --body-b64 "$6"
