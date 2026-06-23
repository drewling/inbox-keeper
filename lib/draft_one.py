#!/usr/bin/env python3
"""draft_one.py — Draft a reply for a single thread and append it to the queue.

Used by the Slack "✍️ Draft reply" button on missed-item cards.  Loads context
for the given thread, runs judge_and_draft, creates the Gmail draft, and
appends a queue entry (status=pending, no slack_ts) so post_pending() picks it
up on the next Slack post cycle.

Usage:
    python3 draft_one.py <config_dir> <thread_id> <account_label>

Outputs a single JSON line:
  {"ok": true,  "item_id": "<id>"}   — draft created and queued
  {"ok": false, "reason": "<why>"}   — gate said no-reply or error

Environment: inherits the caller's environment (gws auth is handled via
draftutil._env which sets GOOGLE_WORKSPACE_CLI_CONFIG_DIR on the subprocess).
"""
import base64, json, os, subprocess, sys, time, fcntl
from email.utils import parseaddr

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
sys.path.insert(0, ROOT)
import draftutil as du  # noqa: E402
import context as ctx   # noqa: E402
import gen_drafts as gd  # noqa: E402
import config  # noqa: E402

QUEUE = config.QUEUE_PATH
PY = sys.executable


def _load_queue() -> list[dict]:
    if not os.path.exists(QUEUE):
        return []
    with open(QUEUE) as f:
        try:
            return json.load(f)
        except Exception:
            return []


def _existing_thread_ids() -> set:
    return {i.get("thread_id") for i in _load_queue()}


def draft_one(config_dir: str, thread_id: str, account_label: str) -> dict:
    """Generate + queue a draft for *thread_id*.  Returns result dict."""
    # Guard: already queued?
    if thread_id in _existing_thread_ids():
        return {"ok": False, "reason": "already in queue"}

    # Fetch the full thread.
    try:
        profile_email = du._profile_email(config_dir)
    except Exception:
        profile_email = account_label

    try:
        thread = du._gws(config_dir, [
            "gmail", "users", "threads", "get",
            "--params", json.dumps({"userId": "me", "id": thread_id, "format": "full"}),
        ])
    except Exception as exc:
        return {"ok": False, "reason": f"thread fetch failed: {exc}"}

    msgs = thread.get("messages", []) or []
    if not msgs:
        return {"ok": False, "reason": "empty thread"}

    last = msgs[-1]
    headers = {h["name"].lower(): h["value"] for h in last.get("payload", {}).get("headers", [])}
    sender = headers.get("from", "")
    subject = headers.get("subject", "(no subject)")
    snippet = (last.get("snippet", "") or "")[:240]

    # Gather context and run the gate + drafter.
    context = ctx.gather(config_dir, msgs, sender, thread_id, profile_email)
    verdict = gd.judge_and_draft(sender, subject, context)

    if not verdict or not verdict.get("needs_reply"):
        reason = (verdict or {}).get("reason", "gate said no reply needed")
        return {"ok": False, "reason": reason}

    reply = (verdict.get("reply") or "").strip()
    if not reply:
        return {"ok": False, "reason": "empty reply from gate"}

    # Prefer Reply-To over From when deciding where to send the reply.
    reply_to = headers.get("reply-to", "")
    to_addr = parseaddr(reply_to)[1] if reply_to else ""
    if not to_addr:
        to_addr = parseaddr(sender)[1] or sender

    # Create the Gmail draft.
    try:
        result = subprocess.run(
            [PY, os.path.join(HERE, "draftutil.py"),
             "create",
             "--config-dir", config_dir,
             "--thread-id", thread_id,
             "--to", to_addr,
             "--subject-b64", base64.b64encode(subject.encode()).decode(),
             "--body-b64",    base64.b64encode(reply.encode()).decode()],
            capture_output=True, text=True, env=du._env(config_dir), timeout=60,
        )
        draft_id = result.stdout.strip()
    except Exception as exc:
        return {"ok": False, "reason": f"draft create error: {exc}"}

    if not draft_id or result.returncode != 0:
        err = (result.stderr or "").strip()
        return {"ok": False, "reason": f"draft create failed: {err}"}

    # Append to queue.
    item_id = f"{int(time.time())}-{thread_id[:8]}"
    item = {
        "id": item_id,
        "account_config_dir": config_dir,
        "account_label": account_label,
        "draft_id": draft_id,
        "thread_id": thread_id,
        "to": to_addr,
        "subject": subject if subject.lower().startswith("re:") else f"Re: {subject}",
        "original_from": sender,
        "original_snippet": snippet,
        "reply_body": reply,
        "why": verdict.get("reason", ""),
        "has_history": context["has_prior_history"],
        "status": "pending",
        "slack_ts": None,
        "slack_channel": None,
    }
    os.makedirs(os.path.dirname(QUEUE), exist_ok=True)
    with open(QUEUE, "a+") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        f.seek(0)
        try:
            data = json.load(f)
        except Exception:
            data = []
        data.append(item)
        f.seek(0); f.truncate()
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write("\n")
        fcntl.flock(f, fcntl.LOCK_UN)

    return {"ok": True, "item_id": item_id, "reply_body": reply}


def main():
    if len(sys.argv) < 3:
        print(json.dumps({"ok": False, "reason": "usage: draft_one.py <config_dir> <thread_id> [account_label]"}))
        sys.exit(1)
    config_dir = sys.argv[1]
    thread_id  = sys.argv[2]
    account_label = sys.argv[3] if len(sys.argv) > 3 else config_dir
    result = draft_one(config_dir, thread_id, account_label)
    print(json.dumps(result))
    sys.exit(0 if result.get("ok") else 1)


if __name__ == "__main__":
    main()
