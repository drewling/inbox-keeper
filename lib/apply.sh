#!/usr/bin/env bash
# Apply / remove labels on a thread.
# Usage: apply.sh <config_dir> <thread_id> <addLabelIds_csv> <removeLabelIds_csv>
# Either csv may be empty. Marks done via gws threads.modify.
set -euo pipefail

CONFIG_DIR="${1:?config_dir required}"
THREAD_ID="${2:?thread_id required}"
ADD_CSV="${3:-}"
REMOVE_CSV="${4:-}"
export GOOGLE_WORKSPACE_CLI_CONFIG_DIR="$CONFIG_DIR"
export GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file
GWS="${GWS_BIN:-gws}"

python3 - "$THREAD_ID" "$ADD_CSV" "$REMOVE_CSV" <<'PY'
import sys, json, os, subprocess
tid, add_csv, rem_csv = sys.argv[1], sys.argv[2], sys.argv[3]
add = [x for x in add_csv.split(",") if x]
rem = [x for x in rem_csv.split(",") if x]
env = dict(os.environ)
gws = os.environ.get("GWS_BIN","gws")
body = json.dumps({"addLabelIds":add,"removeLabelIds":rem})
r = subprocess.run([gws,"gmail","users","threads","modify",
                    "--params", json.dumps({"userId":"me","id":tid}),
                    "--json", body], capture_output=True, text=True, env=env)
line = "\n".join(l for l in r.stdout.splitlines() if "keyring" not in l)
ok = '"id"' in line and '"error"' not in line and r.returncode == 0
print(json.dumps({"threadId":tid,"ok":ok}))
if not ok:
    sys.exit(1)
PY
