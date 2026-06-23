#!/usr/bin/env bash
# Ensure the unified triage label taxonomy exists in one account.
# Usage: ensure_labels.sh <config_dir>
# Prints a JSON object mapping label name -> label id (for all taxonomy labels).
set -euo pipefail

CONFIG_DIR="${1:?config_dir required}"
GWS="${GWS_BIN:-gws}"
export GOOGLE_WORKSPACE_CLI_CONFIG_DIR="$CONFIG_DIR"
export GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file

# The unified taxonomy. Priority labels (exactly one applied per thread) +
# category labels (zero or more). Same names in every account.
LABELS=(
  "⚡ Action"
  "📬 FYI"
  "🔻 Low"
  "💰 Finance"
  "🤝 Clients"
  "📅 Meetings"
  "🔔 Services"
)

gws_q() { "$GWS" "$@" 2>/dev/null | grep -v 'keyring'; }

existing="$(gws_q gmail users labels list --params '{"userId":"me"}')"

# Build name->id map of existing labels
# Use a temp file to avoid stdin redirection issues with heredoc
tmpfile=$(mktemp)
trap "rm -f $tmpfile" EXIT

cat > "$tmpfile" <<'PY'
import sys, json, subprocess, os
existing_raw = sys.argv[1]
config_dir = sys.argv[2]
wanted = sys.argv[3:]
data = json.loads(existing_raw) if existing_raw.strip() else {}
have = { l["name"]: l["id"] for l in data.get("labels", []) }

env = dict(os.environ)
env["GOOGLE_WORKSPACE_CLI_CONFIG_DIR"] = config_dir
env["GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND"] = "file"
gws = os.environ.get("GWS_BIN", "gws")

out = {}
for name in wanted:
    if name in have:
        out[name] = have[name]
        continue
    body = json.dumps({
        "name": name,
        "labelListVisibility": "labelShow",
        "messageListVisibility": "show",
    })
    r = subprocess.run(
        [gws, "gmail", "users", "labels", "create", "--params", '{"userId":"me"}', "--json", body],
        capture_output=True, text=True, env=env,
    )
    line = "\n".join(l for l in r.stdout.splitlines() if "keyring" not in l)
    try:
        created = json.loads(line)
        out[name] = created["id"]
    except Exception:
        out[name] = None
print(json.dumps(out, ensure_ascii=False))
PY

python3 "$tmpfile" "$existing" "$CONFIG_DIR" "${LABELS[@]}"
