#!/usr/bin/env python3
"""Deterministic guard: demote automated / no-reply mail out of ⚡ Action.

The LLM triage pass sometimes promotes automated notifications (Google security
alerts, billing notices, calendar invites from no-reply addresses) to ⚡ Action.
Those are never reply-worthy and inflate the "N need action" count. This pass
runs AFTER triage and deterministically moves any ⚡ Action message whose sender
matches a known automated pattern to 🔔 Services (falling back to 📬 FYI).

Read-only by default (dry-run); pass --execute to relabel.

Usage: demote_automated.py <config_dir> [account_label] [--execute]
Prints a JSON summary: {account, scanned, demoted, mode, items:[...]}
"""
import argparse, json, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE); sys.path.insert(0, ROOT)
import gen_drafts as gd  # noqa: E402  (gws + label_id helpers)
import draftutil as du   # noqa: E402  (_gws with allow_empty for batchModify)

# Sender patterns that can never warrant a personal reply. Matched
# case-insensitively against the full From header (name + address).
AUTOMATED_RE = re.compile(
    r"(no[-_.]?reply|do[-_.]?not[-_.]?reply|donotreply|mailer-daemon|postmaster|"
    r"bounce[s]?@|@accounts\.google\.com|notifications?@|alerts?@|"
    r"@.*\.o2\.co\.uk|automated@|noreply)",
    re.IGNORECASE,
)


def _is_automated(sender: str) -> bool:
    return bool(AUTOMATED_RE.search(sender or ""))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("config_dir")
    ap.add_argument("account_label", nargs="?", default=None)
    ap.add_argument("--execute", action="store_true", help="actually relabel (default: dry-run)")
    a = ap.parse_args()
    config_dir = a.config_dir
    account = a.account_label or config_dir

    action_id = gd.label_id(config_dir, "⚡ Action")
    services_id = gd.label_id(config_dir, "🔔 Services") or gd.label_id(config_dir, "📬 FYI")
    if not action_id:
        print(json.dumps({"account": account, "note": "no ⚡ Action label", "demoted": 0}))
        return

    # Page through all ⚡ Action inbox messages.
    msg_ids, page_token = [], None
    while True:
        params = {"userId": "me", "q": 'label:"⚡ Action" in:inbox', "maxResults": 500}
        if page_token:
            params["pageToken"] = page_token
        data = gd.gws(config_dir, ["gmail", "users", "messages", "list",
                                   "--params", json.dumps(params)])
        msg_ids += [m["id"] for m in data.get("messages", []) or []]
        page_token = data.get("nextPageToken")
        if not page_token:
            break

    scanned, to_demote, items = 0, [], []
    for mid in msg_ids:
        scanned += 1
        msg = gd.gws(config_dir, ["gmail", "users", "messages", "get", "--params",
                                  json.dumps({"userId": "me", "id": mid,
                                              "format": "metadata",
                                              "metadataHeaders": ["From", "Subject"]})])
        headers = {h["name"].lower(): h["value"]
                   for h in msg.get("payload", {}).get("headers", [])}
        sender = headers.get("from", "")
        if _is_automated(sender):
            to_demote.append(mid)
            items.append({"from": sender, "subject": headers.get("subject", "")})

    if a.execute and to_demote:
        body = {"ids": to_demote, "removeLabelIds": [action_id]}
        if services_id:
            body["addLabelIds"] = [services_id]
        # batchModify handles up to 1000 ids per call.
        for i in range(0, len(to_demote), 1000):
            chunk = dict(body, ids=to_demote[i:i + 1000])
            du._gws(config_dir, ["gmail", "users", "messages", "batchModify",
                                 "--params", json.dumps({"userId": "me"}),
                                 "--json", json.dumps(chunk)], allow_empty=True)

    print(json.dumps({"account": account, "scanned": scanned,
                      "demoted": len(to_demote),
                      "mode": "execute" if a.execute else "dry-run",
                      "items": items}, ensure_ascii=False))


if __name__ == "__main__":
    main()
