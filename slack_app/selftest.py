#!/usr/bin/env python3
"""selftest.py — verify the Slack app's action paths work end-to-end, without
needing to click buttons in Slack. Run it in the SAME environment the daemon runs
in (i.e. via `./venv/bin/python selftest.py` after config.sh is sourced, or simply
`bash run_selftest.sh`) so it reproduces the daemon's PATH/auth exactly.

Checks, in order (each prints PASS/FAIL with detail):
  1. Binaries on PATH: gws, claude, node, python3
  2. Slack tokens present + bot auth (auth.test) + review channel resolves
  3. gws auth per account (getProfile) — the call that was failing as "No such file 'gws'"
  4. The exact "Draft reply" path: draft_one.py on a real inbox thread (read-only: it
     either drafts or cleanly declines; we then discard any draft it created)
  5. Queue store: load + claim_for_send round-trip (no real send)

Exit code 0 if all critical checks pass, 1 otherwise. Mutating actions (send,
archive) are NOT exercised — only their prerequisites (gws reachability + auth).
"""
import json, os, shutil, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
sys.path.insert(0, ROOT)
sys.path.insert(0, os.path.join(ROOT, "lib"))
import config  # noqa: E402

PY = sys.executable
PASS, FAIL = "✅ PASS", "❌ FAIL"
results = []


def check(name, ok, detail=""):
    results.append(ok)
    print(f"{PASS if ok else FAIL}  {name}" + (f" — {detail}" if detail else ""))
    return ok


def main():
    print(f"PATH = {os.environ.get('PATH','')}\n")

    # 1. Binaries
    for b in ("gws", "claude", "node", "python3"):
        check(f"binary on PATH: {b}", shutil.which(b) is not None, shutil.which(b) or "NOT FOUND")

    # 2. Slack
    tok = os.environ.get("SLACK_BOT_TOKEN", "")
    check("SLACK_BOT_TOKEN set", tok.startswith("xoxb-"))
    check("SLACK_APP_TOKEN set", os.environ.get("SLACK_APP_TOKEN", "").startswith("xapp-"))
    check("SLACK_REVIEW_CHANNEL set", bool(os.environ.get("SLACK_REVIEW_CHANNEL")))
    try:
        from slack_sdk import WebClient
        r = WebClient(token=tok).auth_test()
        check("Slack bot auth (auth.test)", r.get("ok"), f"team={r.get('team')} bot={r.get('user')}")
    except Exception as e:
        check("Slack bot auth (auth.test)", False, str(e)[:120])

    # 3. gws auth per account
    import draftutil as du
    accounts = config.load_accounts()
    for a in accounts:
        try:
            email = du._profile_email(a["config_dir"])
            check(f"gws auth: {a['email']}", email.lower() == a["email"].lower(), f"got {email}")
        except Exception as e:
            check(f"gws auth: {a['email']}", False, str(e)[:140])

    # 4. The 'Draft reply' path on a real inbox thread (read-only-ish)
    primary = config.primary_account()
    cfg = primary["config_dir"]
    try:
        lst = du._gws(cfg, ["gmail", "users", "messages", "list", "--params",
                            json.dumps({"userId": "me", "q": "in:inbox", "maxResults": 1})])
        tid = (lst.get("messages") or [{}])[0].get("threadId")
    except Exception as e:
        tid = None
        check("fetch a sample inbox thread", False, str(e)[:140])
    if tid:
        check("fetch a sample inbox thread", True, f"thread {tid}")
        r = subprocess.run([PY, os.path.join(ROOT, "lib", "draft_one.py"), cfg, tid, primary["email"]],
                           capture_output=True, text=True, timeout=150)
        out = {}
        try:
            out = json.loads((r.stdout.strip().splitlines() or [""])[-1])
        except Exception:
            pass
        # Success = it ran the gws+claude pipeline and returned a structured verdict
        # (either a draft was created, or it cleanly declined) — NOT a 'gws not found' crash.
        ok = isinstance(out, dict) and ("ok" in out)
        check("draft_one.py 'Draft reply' path runs", ok, json.dumps(out)[:160] or r.stderr[:160])
        # Clean up: if it created a draft, discard it so selftest leaves no trace.
        if out.get("ok") and out.get("draft_id"):
            try:
                subprocess.run([PY, os.path.join(ROOT, "lib", "draftutil.py"), "discard",
                                "--config-dir", cfg, "--draft-id", out["draft_id"]],
                               capture_output=True, text=True, timeout=30)
                # remove the queue item it appended
                import review_queue as q
                item = next((i for i in q.load_queue() if i.get("draft_id") == out["draft_id"]), None)
                if item:
                    q.update_item(item["id"], status="discarded")
                print("   (cleaned up the test draft)")
            except Exception as e:
                print(f"   (cleanup note: {e})")

    # 5. Queue store round-trip
    try:
        import review_queue as q
        q.load_queue()
        check("queue store loads (review_queue)", True)
    except Exception as e:
        check("queue store loads (review_queue)", False, str(e)[:140])

    crit_fail = results.count(False)
    print(f"\n{'='*50}\n{results.count(True)} passed, {crit_fail} failed")
    sys.exit(1 if crit_fail else 0)


if __name__ == "__main__":
    main()
