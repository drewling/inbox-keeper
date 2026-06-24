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
    { "slug", "email", "short", "color", "photo_url": <string|null>,
      "ok", "error",
      "inbox_threads", "unread",
      "loops": [ { "thread_id", "sender", "sender_email", "subject",
                   "snippet", "epoch", "account_slug",
                   "category": <string|null> } ],
      "undo_points": [ { "label", "date", "count" } ] }
  ],
  "policy": <markdown string>,
  "categories": [ { "name", "description", "color", "emoji" } ]
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

# Path to the categories config file (root of the repo).
_CATEGORIES_PATH = os.path.join(ROOT, "categories.json")

# Google-style multicolor avatar palette (white initials sit on each). No orange.
# Indexed by slug: blue, red, green, purple, teal, indigo.
_PALETTE = ["#4285F4", "#DB4437", "#0F9D58", "#AB47BC", "#00838F", "#5C6BC0"]


def _short(email, slug):
    local = (email or slug or "?").split("@")[0]
    parts = [p for p in local.replace(".", " ").replace("_", " ").split() if p]
    if len(parts) >= 2:
        return (parts[0][0] + parts[1][0]).upper()
    return local[:2].upper()


def _color(slug):
    h = int(hashlib.sha1((slug or "").encode()).hexdigest(), 16)
    return _PALETTE[h % len(_PALETTE)]


_DEFAULT_CATEGORIES = [
    {"name": "Needs reply",      "description": "Someone is waiting on a direct response from me.", "color": "#4285F4", "emoji": "✉️"},
    {"name": "Waiting on others","description": "I'm blocked on someone else; tracking, no action yet.", "color": "#AB47BC", "emoji": "⏳"},
    {"name": "To schedule",      "description": "Needs a meeting, call, or calendar action.",       "color": "#0F9D58", "emoji": "📅"},
    {"name": "Read later",       "description": "Worth reading but not urgent or action-bearing.",  "color": "#00838F", "emoji": "🔖"},
    {"name": "Action required",  "description": "A task or deadline I personally need to handle.",  "color": "#DB4437", "emoji": "⚡"},
]


def _load_categories():
    """Return the categories list from categories.json, or the built-in defaults."""
    try:
        if os.path.exists(_CATEGORIES_PATH):
            with open(_CATEGORIES_PATH) as f:
                data = json.load(f)
            cats = data.get("categories", [])
            if cats:
                return cats
    except Exception:
        pass
    return _DEFAULT_CATEGORIES


def _category_label_name(cat):
    """Compose the Gmail label name for a category: '<emoji> <name>'."""
    return f"{cat['emoji']} {cat['name']}"


def _build_category_label_map(categories):
    """Return a dict mapping Gmail label name -> category name for our categories."""
    return {_category_label_name(c): c["name"] for c in categories}


def _photo_url(cfg):
    """Fetch the account's Google profile photo URL via the People API.

    Returns a URL string, or None if unavailable (non-fatal).
    """
    try:
        d = du._gws(cfg, ["people", "people", "get",
                          "--params", json.dumps({"resourceName": "people/me",
                                                  "personFields": "photos"})])
        photos = d.get("photos") or []
        # Prefer the primary photo; fall back to first.
        primary = next((p for p in photos if p.get("metadata", {}).get("primary")), None)
        chosen = primary or (photos[0] if photos else None)
        return chosen["url"] if chosen else None
    except Exception:
        return None


def _inbox_counts(cfg):
    d = du._gws(cfg, ["gmail", "users", "labels", "get",
                      "--params", json.dumps({"userId": "me", "id": "INBOX"})])
    return int(d.get("threadsTotal", 0) or 0), int(d.get("threadsUnread", 0) or 0)


def _inbox_thread_ids(cfg, limit):
    d = du._gws(cfg, ["gmail", "users", "threads", "list",
                      "--params", json.dumps({"userId": "me", "q": "in:inbox",
                                              "maxResults": limit})])
    return [t["id"] for t in d.get("threads", []) or []][:limit]


def _thread_row(cfg, tid, slug, category_label_map=None):
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

    # Determine category from Gmail labels already on this thread.
    # category_label_map: label_name -> category_name (our labels only).
    # id_to_name: label_id -> label_name (fetched once per account, passed in).
    category = None
    if category_label_map:
        thread_label_ids = set()
        for m in msgs:
            thread_label_ids.update(m.get("labelIds") or [])
        if thread_label_ids and category_label_map.get("_id_to_name"):
            id_to_name = category_label_map["_id_to_name"]
            for lid in thread_label_ids:
                lname = id_to_name.get(lid, "")
                if lname in category_label_map:
                    category = category_label_map[lname]
                    break

    return {
        "thread_id": tid,
        "sender": (name or addr or "Unknown").strip(),
        "sender_email": (addr or "").strip(),
        "subject": (headers.get("subject", "") or "(no subject)").strip(),
        "snippet": (last.get("snippet", "") or "")[:140],
        "epoch": epoch,
        "account_slug": slug,
        "category": category,
    }


def _parse_label_date(name):
    """Extract YYYY-MM-DD from a recovery label name, or return 'earlier'."""
    import re
    suffix = name[len(iz._BASE_LABEL):].strip()
    m = re.search(r"\d{4}-\d{2}-\d{2}", suffix)
    return m.group(0) if m else "earlier"


def _undo_points(cfg):
    """Dated recovery labels written by the archive passes, with thread counts.

    Deduped: multiple labels sharing the same date are merged into one point
    (counts summed). Labels with no parseable date are merged under 'earlier'.
    """
    data = du._gws(cfg, ["gmail", "users", "labels", "list",
                         "--params", json.dumps({"userId": "me"})])
    # Collect counts per date bucket; track one representative label per bucket.
    buckets = {}  # date -> {"label": str, "count": int}
    for lab in data.get("labels", []) or []:
        name = lab.get("name", "")
        if not name.startswith(iz._BASE_LABEL):
            continue
        detail = du._gws(cfg, ["gmail", "users", "labels", "get",
                               "--params", json.dumps({"userId": "me", "id": lab["id"]})])
        date = _parse_label_date(name)
        count = int(detail.get("threadsTotal", 0) or 0)
        if date not in buckets:
            buckets[date] = {"label": name, "date": date, "count": count}
        else:
            buckets[date]["count"] += count
            # Keep the most recent label name for this bucket as the restore target.
            if name > buckets[date]["label"]:
                buckets[date]["label"] = name
    points = list(buckets.values())
    # Sort: real dates descending, 'earlier' always last.
    points.sort(key=lambda p: ("0" if p["date"] == "earlier" else p["date"]), reverse=True)
    return points


def _account_state(acct, max_loops, categories):
    slug = acct.get("slug") or acct.get("email", "?")
    email = acct.get("email", slug)
    state = {"slug": slug, "email": email, "short": _short(email, slug),
             "color": _color(slug), "photo_url": None, "ok": True, "error": None,
             "inbox_threads": 0, "unread": 0, "loops": [], "undo_points": [],
             "partial": 0}
    try:
        cfg = acct.get("config_dir")
        if not cfg:
            raise ValueError("account is missing 'config_dir'")

        # Feature 1: real profile photo (best-effort; never blocks the account build).
        state["photo_url"] = _photo_url(cfg)

        state["inbox_threads"], state["unread"] = _inbox_counts(cfg)
        ids = _inbox_thread_ids(cfg, max_loops)

        # Build a label-id -> label-name map once per account so _thread_row can
        # resolve category labels cheaply without N extra API calls.
        cat_label_map = _build_category_label_map(categories)
        try:
            label_data = du._gws(cfg, ["gmail", "users", "labels", "list",
                                       "--params", json.dumps({"userId": "me"})])
            id_to_name = {l["id"]: l["name"] for l in label_data.get("labels", []) or []}
        except Exception:
            id_to_name = {}
        cat_label_map["_id_to_name"] = id_to_name  # piggyback; key never conflicts

        rows, failed = [], 0
        with ThreadPoolExecutor(max_workers=8) as ex:
            futs = {ex.submit(_thread_row, cfg, tid, slug, cat_label_map): tid for tid in ids}
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
    categories = _load_categories()
    # Accounts are independent; build them concurrently but keep input order.
    with ThreadPoolExecutor(max_workers=max(1, len(accounts))) as ex:
        states = list(ex.map(lambda a: _account_state(a, max_loops, categories), accounts))
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
        "categories": categories,
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
