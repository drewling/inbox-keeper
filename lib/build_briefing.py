#!/usr/bin/env python3
"""Build drafts/briefing.json for the Slack morning briefing card.

Aggregates, per account: current inbox thread count, ⚡ Action count, and missed
count (from drafts/missed_today.json). Plus totals: drafts ready (pending queue
items) and missed total. Cheap — one labels.get per account. Tolerant of missing
files so it never blocks the run.
"""
import json, os, sys
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import draftutil as du  # noqa: E402

ACCOUNTS = os.path.join(ROOT, "accounts.json")
QUEUE = os.path.join(ROOT, "drafts", "queue.json")
MISSED = os.path.join(ROOT, "drafts", "missed_today.json")
OUT = os.path.join(ROOT, "drafts", "briefing.json")


def _load(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return default


def _inbox_count(cfg):
    try:
        d = du._gws(cfg, ["gmail", "users", "labels", "get",
                          "--params", json.dumps({"userId": "me", "id": "INBOX"})])
        return d.get("threadsTotal")
    except Exception:
        return None


def _action_count(cfg):
    try:
        d = du._gws(cfg, ["gmail", "users", "messages", "list", "--params",
                          json.dumps({"userId": "me", "q": 'in:inbox label:"⚡ Action"',
                                      "maxResults": 100})])
        return len({m["threadId"] for m in d.get("messages", []) or []})
    except Exception:
        return None


def main():
    accounts = _load(ACCOUNTS, [])
    if isinstance(accounts, dict):
        accounts = accounts.get("accounts", [])
    queue = _load(QUEUE, [])
    missed = _load(MISSED, [])

    drafts_ready = sum(1 for i in queue if i.get("status") == "pending")
    missed_by_acct = {}
    for m in missed:
        missed_by_acct[m.get("account_label", "")] = missed_by_acct.get(m.get("account_label", ""), 0) + 1

    acct_rows = []
    for a in accounts:
        cfg, label = a["config_dir"], a["email"]
        acct_rows.append({
            "label": label,
            "inbox_count": _inbox_count(cfg),
            "action_count": _action_count(cfg),
            "missed_count": missed_by_acct.get(label, 0),
        })

    out = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "accounts": acct_rows,
        "missed_total": len(missed),
        "drafts_generated": drafts_ready,
    }
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w") as f:
        json.dump(out, f, ensure_ascii=False, indent=2)
    print(json.dumps({"briefing_written": True, "accounts": len(acct_rows),
                      "drafts_ready": drafts_ready, "missed_total": len(missed)}))


if __name__ == "__main__":
    main()
