#!/usr/bin/env python3
"""Missed-important-items sweep — the "you may have missed this" catch-up.

Scans the inbox over a lookback window for threads where:
  - the last message is from someone else (not the account owner), and
  - the owner never replied (no message from the owner after theirs), and
  - it isn't obvious noise (cold sales, automated, newsletters).
Then asks Haiku to keep only genuinely important, still-actionable items and say why.

Outputs JSON: {"missed": [{"from","subject","date","thread_id","why","age_days"}]}

Usage: catchup.py <config_dir> [account_label] [lookback_days]
"""
import json, os, sys, subprocess
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime, parseaddr

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import draftutil as du  # noqa: E402
import context as ctx  # noqa: E402

CLAUDE = os.environ.get("CLAUDE_BIN", "claude")


def _hdr(msg, name):
    for h in msg.get("payload", {}).get("headers", []):
        if h["name"].lower() == name.lower():
            return h["value"]
    return ""


def _age_days(date_str):
    try:
        dt = parsedate_to_datetime(date_str)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return (datetime.now(timezone.utc) - dt).days
    except Exception:
        return None


def candidates(config_dir, profile_email, lookback_days):
    """Inbox threads older than 1d but within lookback, last msg not from the owner, no owner reply."""
    q = f"in:inbox -in:chats newer_than:{lookback_days}d older_than:1d -label:\"⚡ Action\""
    lst = du._gws(config_dir, ["gmail", "users", "messages", "list", "--params",
                               json.dumps({"userId": "me", "q": q, "maxResults": 60})])
    out = []
    seen = set()
    for m in lst.get("messages", []) or []:
        tid = m["threadId"]
        if tid in seen:
            continue
        seen.add(tid)
        try:
            thread = du._gws(config_dir, ["gmail", "users", "threads", "get", "--params",
                                          json.dumps({"userId": "me", "id": tid, "format": "metadata",
                                                      "metadataHeaders": ["From", "Subject", "Date"]})])
        except Exception:
            continue
        msgs = thread.get("messages", []) or []
        if not msgs:
            continue
        # Owner replied if any message is from the account owner.
        owner_replied = any(profile_email and profile_email.lower() in _hdr(x, "from").lower() for x in msgs)
        if owner_replied:
            continue
        last = msgs[-1]
        frm = _hdr(last, "from")
        if profile_email and profile_email.lower() in frm.lower():
            continue
        date = _hdr(last, "date")
        out.append({
            "thread_id": tid,
            "from": frm,
            "subject": _hdr(last, "subject") or "(no subject)",
            "date": date,
            "age_days": _age_days(date),
            "snippet": (last.get("snippet", "") or "")[:200],
        })
    return out


def filter_important(cands, profile):
    """Ask Haiku to keep only genuinely important, still-worth-surfacing items.

    Returns a list of important candidates, or None if the claude call failed
    (timeout, non-zero exit, or unparseable output).  Callers should treat None
    as "could not evaluate" rather than "nothing important".
    """
    if not cands:
        return []
    listing = "\n".join(
        f'{i}. from={c["from"]} | subject={c["subject"]} | {c["age_days"]}d ago | {c["snippet"]}'
        for i, c in enumerate(cands)
    )
    prompt = f"""From this list of un-replied inbox emails the user may have missed, return ONLY the ones that are genuinely important and still worth their attention. EXCLUDE: cold sales/outbound pitches, financing offers, vendor/webinar invites, recruiters, newsletters, marketing, receipts, social notifications, and calendar "Accepted:"/"Declined:"/"Invitation:" auto-confirmations (these need no action), subscription alerts (property/job/price alerts). KEEP things that need action or a human response: payment/billing failures, real two-way threads awaiting the user, time-sensitive deadlines, client/partner asks, account/security problems, tax/legal compliance.

{profile}

EMAILS:
{listing}

Output ONLY a JSON array of objects for the important ones:
[{{"index": <number>, "why": "<short reason it matters>"}}]
If none are important, output []."""
    try:
        r = subprocess.run([CLAUDE, "-p", prompt, "--model", "haiku"],
                           capture_output=True, text=True, timeout=120)
    except subprocess.TimeoutExpired:
        return None  # classification timed out
    if r.returncode != 0:
        return None  # claude subprocess failed
    txt = r.stdout.strip()
    start, end = txt.find("["), txt.rfind("]")
    if start < 0 or end < 0:
        return None  # unparseable output
    try:
        keep = json.loads(txt[start:end + 1])
    except Exception:
        return None
    result = []
    for k in keep:
        idx = k.get("index")
        if isinstance(idx, int) and 0 <= idx < len(cands):
            c = dict(cands[idx])
            c["why"] = k.get("why", "")
            c.pop("snippet", None)
            result.append(c)
    return result


def main():
    config_dir = sys.argv[1]
    account_label = sys.argv[2] if len(sys.argv) > 2 else config_dir
    lookback = sys.argv[3] if len(sys.argv) > 3 else "14"
    try:
        profile_email = du._profile_email(config_dir)
    except Exception:
        profile_email = account_label
    cands = candidates(config_dir, profile_email, lookback)
    missed = filter_important(cands, ctx.drewl_profile())
    if missed is None:
        # Classification failed — surface as an error so the caller can distinguish
        # "nothing important" from "could not evaluate".
        print(json.dumps({
            "account": account_label,
            "scanned": len(cands),
            "missed": [],
            "error": "classification failed",
        }, ensure_ascii=False))
    else:
        print(json.dumps({"account": account_label, "scanned": len(cands), "missed": missed},
                         ensure_ascii=False))


if __name__ == "__main__":
    main()
