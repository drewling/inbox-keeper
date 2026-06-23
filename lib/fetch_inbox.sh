#!/usr/bin/env bash
# Fetch recent unread INBOX threads for one account as compact JSON.
# Usage: fetch_inbox.sh <config_dir> [gmail_query] [max]
# Default query: unread inbox from the last 1 day. Output: JSON array of
#   {threadId, msgId, from, subject, snippet, date}
set -euo pipefail

CONFIG_DIR="${1:?config_dir required}"
QUERY="${2:-in:inbox is:unread newer_than:1d}"
MAX="${3:-60}"
export GOOGLE_WORKSPACE_CLI_CONFIG_DIR="$CONFIG_DIR"
export GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file
GWS="${GWS_BIN:-gws}"

python3 - "$CONFIG_DIR" "$QUERY" "$MAX" <<'PY'
import sys, json, os, subprocess
config_dir, query, max_n = sys.argv[1], sys.argv[2], int(sys.argv[3])
env = dict(os.environ)
env["GOOGLE_WORKSPACE_CLI_CONFIG_DIR"] = config_dir
env["GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND"] = "file"
gws = os.environ.get("GWS_BIN", "gws")

def run(args):
    r = subprocess.run([gws]+args, capture_output=True, text=True, env=env)
    line = "\n".join(l for l in r.stdout.splitlines() if "keyring" not in l)
    return json.loads(line) if line.strip() else {}

lst = run(["gmail","users","messages","list","--params",
           json.dumps({"userId":"me","q":query,"maxResults":max_n})])
msgs = lst.get("messages", []) or []

seen_threads = set()
out = []
for m in msgs:
    tid = m.get("threadId")
    if tid in seen_threads:
        continue
    seen_threads.add(tid)
    meta = run(["gmail","users","messages","get","--params",
                json.dumps({"userId":"me","id":m["id"],"format":"metadata",
                            "metadataHeaders":["From","Subject","Date"]})])
    headers = { h["name"]: h["value"] for h in (meta.get("payload",{}) or {}).get("headers",[]) }
    out.append({
        "threadId": tid,
        "msgId": m["id"],
        "from": headers.get("From",""),
        "subject": headers.get("Subject","(no subject)"),
        "snippet": (meta.get("snippet","") or "")[:240],
        "date": headers.get("Date",""),
    })
print(json.dumps(out, ensure_ascii=False))
PY
