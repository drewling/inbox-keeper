#!/usr/bin/env python3
"""Diagnostic: replay the draft-worthiness gate over every ⚡ Action item and
print each verdict + reason WITHOUT creating drafts. Read-only.

Usage: gate_audit.py <config_dir> <account_label> [newer_than]
Prints one JSON object per line (NDJSON): {account, subject, from, has_history, needs_reply, reason}
"""
import json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE); sys.path.insert(0, ROOT)
import draftutil as du            # noqa: E402
import context as ctx             # noqa: E402
import gen_drafts as gd           # noqa: E402


def main():
    config_dir = sys.argv[1]
    account_label = sys.argv[2] if len(sys.argv) > 2 else config_dir
    newer = sys.argv[3] if len(sys.argv) > 3 else "14d"

    try:
        profile_email = du._profile_email(config_dir)
    except Exception:
        profile_email = account_label

    lst = gd.gws(config_dir, ["gmail", "users", "messages", "list", "--params",
                              json.dumps({"userId": "me",
                                          "q": f'label:"⚡ Action" in:inbox newer_than:{newer}',
                                          "maxResults": 50})])
    seen = set()
    for m in lst.get("messages", []) or []:
        tid = m["threadId"]
        if tid in seen:
            continue
        seen.add(tid)
        thread = gd.gws(config_dir, ["gmail", "users", "threads", "get", "--params",
                                     json.dumps({"userId": "me", "id": tid, "format": "full"})])
        msgs = thread.get("messages", []) or []
        if not msgs:
            continue
        last = msgs[-1]
        headers = {h["name"].lower(): h["value"] for h in last.get("payload", {}).get("headers", [])}
        sender = headers.get("from", "")
        subject = headers.get("subject", "(no subject)")

        rec = {"account": account_label, "thread_id": tid,
               "from": sender, "subject": subject}

        if profile_email and profile_email.lower() in sender.lower():
            rec.update(needs_reply=False, reason="last message is from the account owner (ball in their court)",
                       has_history=None)
            print(json.dumps(rec, ensure_ascii=False)); continue

        context = ctx.gather(config_dir, msgs, sender, tid, profile_email)
        verdict = gd.judge_and_draft(sender, subject, context)
        rec["has_history"] = context["has_prior_history"]
        if not verdict:
            rec.update(needs_reply=None, reason="gate call failed/timeout")
        else:
            rec.update(needs_reply=verdict.get("needs_reply"),
                       reason=verdict.get("reason", ""))
        print(json.dumps(rec, ensure_ascii=False))


if __name__ == "__main__":
    main()
