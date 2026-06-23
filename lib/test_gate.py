#!/usr/bin/env python3
"""Ad-hoc gate tester: judge specific threads. Usage: test_gate.py <config_dir> <thread_id> [thread_id...]"""
import json, sys, os
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import draftutil as du
import context as ctx
import gen_drafts as gd

config_dir = sys.argv[1]
try:
    profile_email = du._profile_email(config_dir)
except Exception:
    profile_email = ""

for tid in sys.argv[2:]:
  try:
    thread = du._gws(config_dir, ["gmail", "users", "threads", "get", "--params",
                                  json.dumps({"userId": "me", "id": tid, "format": "full"})])
    msgs = thread.get("messages", []) or []
    if not msgs:
        print("=" * 70); print(f"{tid}: NO MESSAGES"); continue
    last = msgs[-1]
    headers = {h["name"].lower(): h["value"] for h in last.get("payload", {}).get("headers", [])}
    sender = headers.get("from", "")
    subject = headers.get("subject", "(no subject)")
    context = ctx.gather(config_dir, msgs, sender, tid, profile_email)
    verdict = gd.judge_and_draft(sender, subject, context)
    print("=" * 70)
    print(f"FROM: {sender}\nSUBJECT: {subject}\nprior_history={context['has_prior_history']}")
    print(f"VERDICT: {json.dumps(verdict, ensure_ascii=False, indent=2) if verdict else 'PARSE FAILED'}")
  except Exception as e:
    print("=" * 70); print(f"{tid}: ERROR {e}")
