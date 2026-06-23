#!/usr/bin/env python3
"""_regen_worker.py — Internal helper: regenerate a draft reply for one item.

Called by app.py's regenerate_modal handler as a subprocess.  All inputs are
passed via environment variables (set by the parent) to avoid shell-quoting
issues.  Outputs a single JSON line on stdout:

  {"ok": true,  "reply_body": "<new body>", "draft_id": "<updated draft id>"}
  {"ok": false, "reason": "<why>"}

Environment variables consumed:
  REGEN_ITEM_ID     — queue item id
  REGEN_CONFIG_DIR  — account config_dir
  REGEN_THREAD_ID   — Gmail thread id
  REGEN_SUBJECT     — email subject
  REGEN_TO          — recipient address
  REGEN_DRAFT_ID    — existing Gmail draft id to update in place
  REGEN_ACCOUNT     — account label (for logging)
  REGEN_STEER       — optional steer string from the user
"""

import base64, json, os, subprocess, sys

# Resolve lib/ regardless of cwd.
HERE    = os.path.dirname(os.path.abspath(__file__))
LIB_DIR = os.path.join(os.path.dirname(HERE), "lib")
sys.path.insert(0, LIB_DIR)

import draftutil as du  # noqa: E402
import context as ctx   # noqa: E402
import gen_drafts as gd  # noqa: E402


def main():
    config_dir = os.environ.get("REGEN_CONFIG_DIR", "")
    thread_id  = os.environ.get("REGEN_THREAD_ID", "")
    subject    = os.environ.get("REGEN_SUBJECT", "")
    to_addr    = os.environ.get("REGEN_TO", "")
    draft_id   = os.environ.get("REGEN_DRAFT_ID", "")
    account    = os.environ.get("REGEN_ACCOUNT", config_dir)
    steer      = os.environ.get("REGEN_STEER", "").strip()

    if not config_dir or not thread_id:
        _fail("missing REGEN_CONFIG_DIR or REGEN_THREAD_ID")

    # Fetch full thread for fresh context.
    try:
        profile_email = du._profile_email(config_dir)
    except Exception:
        profile_email = account

    try:
        thread = du._gws(config_dir, [
            "gmail", "users", "threads", "get",
            "--params", json.dumps({"userId": "me", "id": thread_id, "format": "full"}),
        ])
    except Exception as exc:
        _fail(f"thread fetch failed: {exc}")

    msgs = thread.get("messages", []) or []
    if not msgs:
        _fail("empty thread")

    last    = msgs[-1]
    headers = {h["name"].lower(): h["value"]
               for h in last.get("payload", {}).get("headers", [])}
    sender  = headers.get("from", "")

    context = ctx.gather(config_dir, msgs, sender, thread_id, profile_email)

    # If there's a steer, apply it by monkey-patching judge_and_draft temporarily.
    if steer:
        original_fn = gd.judge_and_draft

        def judge_with_steer(s, subj, ctx_data):
            verdict = original_fn(s, subj, ctx_data)
            if not verdict or not verdict.get("needs_reply"):
                return verdict
            # Re-run with steer appended.
            import subprocess as sp, os as _os
            CLAUDE = _os.environ.get("CLAUDE_BIN", "claude")
            reply_steer_prompt = (
                f"Rewrite this email reply with the following direction: {steer}\n\n"
                f"ORIGINAL REPLY:\n{verdict.get('reply','')}\n\n"
                f"Output ONLY the new reply text, no JSON, no preamble."
            )
            try:
                r = sp.run([CLAUDE, "-p", reply_steer_prompt, "--model", "haiku"],
                           capture_output=True, text=True, timeout=60)
            except sp.TimeoutExpired:
                return None  # steer timed out; caller treats as failure
            if r.returncode != 0:
                return None  # steer subprocess failed
            new_reply = r.stdout.strip()
            if new_reply:
                verdict["reply"] = new_reply
            return verdict

        gd.judge_and_draft = judge_with_steer

    verdict = gd.judge_and_draft(sender, subject, context)

    if steer:
        gd.judge_and_draft = original_fn  # restore

    if not verdict or not verdict.get("needs_reply"):
        reason = (verdict or {}).get("reason", "gate says no reply needed")
        _fail(reason)

    new_reply = (verdict.get("reply") or "").strip()
    if not new_reply:
        _fail("empty reply from gate")

    # Update the existing Gmail draft in place (not send — just update).
    PY = sys.executable
    if draft_id:
        result = subprocess.run(
            [PY, os.path.join(LIB_DIR, "draftutil.py"),
             "update",
             "--config-dir",  config_dir,
             "--draft-id",    draft_id,
             "--thread-id",   thread_id,
             "--to",          to_addr,
             "--subject-b64", base64.b64encode(subject.encode()).decode(),
             "--body-b64",    base64.b64encode(new_reply.encode()).decode()],
            capture_output=True, text=True, env=du._env(config_dir), timeout=60,
        )
        updated_draft_id = result.stdout.strip()
        if result.returncode != 0 or not updated_draft_id:
            err = (result.stderr or "").strip()
            _fail(f"draftutil update failed: {err}")
        new_draft_id = updated_draft_id
    else:
        # No existing draft id — create a new one.
        result = subprocess.run(
            [PY, os.path.join(LIB_DIR, "draftutil.py"),
             "create",
             "--config-dir",  config_dir,
             "--thread-id",   thread_id,
             "--to",          to_addr,
             "--subject-b64", base64.b64encode(subject.encode()).decode(),
             "--body-b64",    base64.b64encode(new_reply.encode()).decode()],
            capture_output=True, text=True, env=du._env(config_dir), timeout=60,
        )
        new_draft_id = result.stdout.strip()
        if result.returncode != 0 or not new_draft_id:
            err = (result.stderr or "").strip()
            _fail(f"draftutil create failed: {err}")

    print(json.dumps({"ok": True, "reply_body": new_reply, "draft_id": new_draft_id}))


def _fail(reason: str):
    print(json.dumps({"ok": False, "reason": reason}))
    sys.exit(1)


if __name__ == "__main__":
    main()
