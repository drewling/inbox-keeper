#!/usr/bin/env python3
"""Build the dashboard state artifact the menu-bar panel reads.

The panel must open instantly, so it never talks to Gmail directly. This script
does the (slowish) Gmail reads once and writes a single JSON file the panel
loads in one fetch. The daily run, the "Run keeper now" action, and the panel's
refresh button all regenerate it.

State shape (app/state.json):
{
  "generated_at": <epoch seconds>,
  "ok": true,
  "total_loops": <int>,
  "accounts": [
    { "slug", "email", "short", "color", "ok", "error",
      "inbox_threads", "unread",
      "loops": [ { "thread_id", "sender", "sender_email", "subject",
                   "snippet", "epoch", "account_slug" } ],
      "undo_points": [ { "label", "date", "count" } ] }
  ],
  "policy": <markdown string>
}

Reversible by construction: nothing here deletes mail. Undo points are the dated
recovery labels written by the archive passes; restoring one is a label swap.

Usage: dashboard_state.py [--accounts PATH] [--out PATH] [--max-loops N]
"""
import argparse, hashlib, json, os, sys, time
from concurrent.futures import ThreadPoolExecutor, as_completed
from email.utils import parseaddr, parsedate_to_datetime

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import draftutil as du        # noqa: E402
import inbox_zero as iz       # noqa: E402
import learning               # noqa: E402

# Warm, restrained avatar palette (OKLCH-derived hex, muted). Indexed by slug.
_PALETTE = ["#B5654A", "#7C8B6F", "#9A7B4F", "#6F8499", "#8A6F99", "#A8845C"]


def _short(email, slug):
    local = (email or slug or "?").split("@")[0]
    parts = [p for p in local.replace(".", " ").replace("_", " ").split() if p]
    if len(parts) >= 2:
        return (parts[0][0] + parts[1][0]).upper()
    return local[:2].upper()


def _color(slug):
    h = int(hashlib.sha1((slug or "").encode()).hexdigest(), 16)
    return _PALETTE[h % len(_PALETTE)]


def _inbox_counts(cfg):
    d = du._gws(cfg, ["gmail", "users", "labels", "get",
                      "--params", json.dumps({"userId": "me", "id": "INBOX"})])
    return int(d.get("threadsTotal", 0) or 0), int(d.get("threadsUnread", 0) or 0)


def _inbox_thread_ids(cfg, limit):
    d = du._gws(cfg, ["gmail", "users", "threads", "list",
                      "--params", json.dumps({"userId": "me", "q": "in:inbox",
                                              "maxResults": limit})])
    return [t["id"] for t in d.get("threads", []) or []][:limit]


def _thread_row(cfg, tid, slug):
    t = du._gws(cfg, ["gmail", "users", "threads", "get",
                      "--params", json.dumps({"userId": "me", "id": tid,
                                              "format": "metadata",
                                              "metadataHeaders": ["From", "Subject", "Date"]})])
    msgs = t.get("messages", []) or []
    if not msgs:
        return None
    last = msgs[-1]
    headers = {h["name"].lower(): h["value"] for h in last.get("payload", {}).get("headers", [])}
    raw_from = headers.get("from", "")
    name, addr = parseaddr(raw_from)
    epoch = 0
    try:
        epoch = int(last.get("internalDate", 0)) // 1000
    except (TypeError, ValueError):
        pass
    if not epoch and headers.get("date"):
        try:
            epoch = int(parsedate_to_datetime(headers["date"]).timestamp())
        except (TypeError, ValueError):
            epoch = 0
    return {
        "thread_id": tid,
        "sender": (name or addr or "Unknown").strip(),
        "sender_email": (addr or "").strip(),
        "subject": (headers.get("subject", "") or "(no subject)").strip(),
        "snippet": (last.get("snippet", "") or "")[:140],
        "epoch": epoch,
        "account_slug": slug,
    }


def _undo_points(cfg):
    """Dated recovery labels written by the archive passes, with thread counts."""
    data = du._gws(cfg, ["gmail", "users", "labels", "list",
                         "--params", json.dumps({"userId": "me"})])
    points = []
    for lab in data.get("labels", []) or []:
        name = lab.get("name", "")
        if not name.startswith(iz._BASE_LABEL):
            continue
        detail = du._gws(cfg, ["gmail", "users", "labels", "get",
                               "--params", json.dumps({"userId": "me", "id": lab["id"]})])
        date = name[len(iz._BASE_LABEL):].strip() or "?"
        points.append({"label": name, "date": date,
                       "count": int(detail.get("threadsTotal", 0) or 0)})
    points.sort(key=lambda p: p["date"], reverse=True)
    return points


def _account_state(acct, max_loops):
    slug = acct.get("slug") or acct.get("email", "?")
    email = acct.get("email", slug)
    state = {"slug": slug, "email": email, "short": _short(email, slug),
             "color": _color(slug), "ok": True, "error": None,
             "inbox_threads": 0, "unread": 0, "loops": [], "undo_points": [],
             "partial": 0}
    try:
        cfg = acct.get("config_dir")
        if not cfg:
            raise ValueError("account is missing 'config_dir'")
        state["inbox_threads"], state["unread"] = _inbox_counts(cfg)
        ids = _inbox_thread_ids(cfg, max_loops)
        rows, failed = [], 0
        with ThreadPoolExecutor(max_workers=8) as ex:
            futs = {ex.submit(_thread_row, cfg, tid, slug): tid for tid in ids}
            for f in as_completed(futs):
                try:
                    r = f.result()
                    if r:
                        rows.append(r)
                except Exception:
                    failed += 1
        rows.sort(key=lambda r: r["epoch"], reverse=True)
        state["loops"] = rows
        state["partial"] = failed  # rows we couldn't load; UI warns if non-zero
        state["undo_points"] = _undo_points(cfg)
    except Exception as exc:
        state["ok"] = False
        state["error"] = str(exc)
    return state


def build(accounts_path, max_loops):
    with open(accounts_path) as f:
        data = json.load(f)
    accounts = data if isinstance(data, list) else data.get("accounts", [])
    states = []
    # Accounts are independent; build them concurrently but keep input order.
    with ThreadPoolExecutor(max_workers=max(1, len(accounts))) as ex:
        results = list(ex.map(lambda a: _account_state(a, max_loops), accounts))
    states = results
    policy = ""
    policy_path = os.path.join(ROOT, "keep-policy.md")
    if os.path.exists(policy_path):
        with open(policy_path) as f:
            policy = f.read()
    failed = [s["slug"] for s in states if not s["ok"]]
    return {
        "generated_at": int(time.time()),
        "ok": all(s["ok"] for s in states) if states else False,
        # Count loops only over accounts we could actually read. A failed account
        # must never silently lower the count and make the inbox look "clear".
        "total_loops": sum(s["inbox_threads"] for s in states if s["ok"]),
        "failed_accounts": failed,
        "accounts": states,
        "policy": policy,
        "learned": learning.learned_text(),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--accounts", default=os.path.join(ROOT, "accounts.json"))
    ap.add_argument("--out", default=os.path.join(ROOT, "app", "state.json"))
    ap.add_argument("--max-loops", type=int, default=60,
                    help="max inbox threads to detail per account")
    a = ap.parse_args()
    state = build(a.accounts, a.max_loops)
    os.makedirs(os.path.dirname(a.out), exist_ok=True)
    tmp = a.out + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f, ensure_ascii=False, indent=2)
    os.replace(tmp, a.out)
    print(json.dumps({"ok": state["ok"], "total_loops": state["total_loops"],
                      "accounts": len(state["accounts"]), "out": a.out}))


if __name__ == "__main__":
    main()
