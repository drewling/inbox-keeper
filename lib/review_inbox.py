#!/usr/bin/env python3
"""Aggressive-but-safe whole-inbox review: keep genuine contacts + must-act, archive the rest.

For every reviewable inbox message (excluding starred, Action, last 2 days, and
high-stakes PROTECT_PATTERNS), feed Haiku sender + subject + replied_before and
decide keep vs archive. The replied_before signal (has the owner EVER emailed this
address) is the key tell for cold outreach: SmartLead/Apollo/Lemlist-style sales
mail comes from real-looking human names but the owner never replied to them.

Reversible (dated recovery label). Dry-run by default.

Usage: review_inbox.py <config_dir> <account_label> [--execute] [--chunk 60]
"""
import argparse, json, os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import inbox_zero as iz       # noqa: E402
import thin_protected as tp   # noqa: E402
from email.utils import parseaddr  # noqa: E402

CLAUDE = os.environ.get("CLAUDE_BIN", "claude")

CANDIDATE_Q = f"in:inbox {tp.KEEP} {tp.NOT_PROTECTED}"

PROMPT_HEAD = (
    "You are AGGRESSIVELY cleaning the user's inbox to near-zero. For EACH numbered email you see "
    "sender + subject + replied_before (whether the user has EVER sent mail to this address). Decide "
    '"keep" or "archive". Archive the great majority; only a small genuine core survives.\n\n'
    "The single most important signal is replied_before:\n"
    "- replied_before=YES: the user has a real two-way relationship. If it's an individual person, KEEP.\n"
    "- replied_before=NO: the user has NEVER written to them. This is almost always COLD OUTREACH even "
    "when the sender is a real-looking human name and the subject looks 1:1. Cold-email tools "
    "(SmartLead, Apollo, Lemlist, Instantly) deliberately fake this. Telltale cadence subjects: "
    '"checking in", "Re: Check-In & Catch Up", "following up", "circling back", "bump", "should I '
    'close the loop?", "quick question", "worth 15 minutes?", "hop on a call", '
    '"partnership", "introduction", "requests", "did you see". ARCHIVE all of these.\n\n'
    "KEEP only:\n"
    "1. An individual person the user HAS replied to before (replied_before=YES).\n"
    "2. Personal or family mail (e.g. surname Onabule, clearly personal), regardless of replied_before.\n"
    "3. An active payment PROBLEM: failed/declined/overdue/can't process/problem with your payment/past-due.\n"
    "4. A legal matter or dispute: courts/justice.gov.uk, debt collection, tenancy deposit, PCN/penalty, adjudication.\n"
    "5. An explicit deadline/consequence needing the user to act/sign/attend.\n\n"
    "ARCHIVE everything else, including:\n"
    "- ANY cold outreach/sales/pitch/'let's chat'/vendor prospecting, even from a named person, when "
    "replied_before=NO and it's not clearly personal/family.\n"
    "- receipts, invoices, order confirmations, payment sent/received; bill-ready/statements (not problems)\n"
    "- one-time login/verification codes, verify-your-device, past security alerts\n"
    "- routine automated app/service notifications, reminders, meeting-summary emails\n"
    "- newsletters, digests, marketing, promotions, social notifications, surveys, announcements, company event invites\n\n"
    "When unsure: KEEP only if replied_before=YES or it's clearly personal/family/legal/payment-problem; otherwise ARCHIVE.\n\n"
    'Output ONLY a JSON object mapping each number to "keep" or "archive", e.g. {"0":"archive","1":"keep"}. No prose.\n\n'
    "EMAILS:\n"
)


def _candidates(config_dir):
    ids, tok = [], None
    while True:
        params = {"userId": "me", "q": CANDIDATE_Q, "maxResults": 500}
        if tok:
            params["pageToken"] = tok
        d = iz.gws(config_dir, ["gmail", "users", "messages", "list",
                                "--params", json.dumps(params)])
        ids += [m["id"] for m in d.get("messages", []) or []]
        tok = d.get("nextPageToken")
        if not tok:
            break
    out = []
    for mid in ids:
        m = iz.gws(config_dir, ["gmail", "users", "messages", "get", "--params",
                                json.dumps({"userId": "me", "id": mid, "format": "metadata",
                                            "metadataHeaders": ["From", "Subject"]})])
        h = {x["name"].lower(): x["value"] for x in m.get("payload", {}).get("headers", [])}
        out.append({"id": mid, "from": h.get("from", ""), "subject": h.get("subject", "")})
    return out


_REPLIED_CACHE = {}


def _replied_before(config_dir, sender):
    """True if the owner has ever SENT mail to this sender's address (two-way history)."""
    email = (parseaddr(sender)[1] or "").lower()
    if not email:
        return False
    if email in _REPLIED_CACHE:
        return _REPLIED_CACHE[email]
    try:
        d = iz.gws(config_dir, ["gmail", "users", "messages", "list", "--params",
                                json.dumps({"userId": "me", "q": f"from:me to:{email}",
                                            "maxResults": 1})])
        val = bool(d.get("messages"))
    except Exception:
        val = True  # fail safe: assume relationship, keep
    _REPLIED_CACHE[email] = val
    return val


def _classify(chunk):
    lines = []
    for i, c in enumerate(chunk):
        rb = "YES" if c["replied_before"] else "NO"
        lines.append(f'{i}. from: {c["from"]} | subject: {c["subject"]} | replied_before: {rb}')
    try:
        r = subprocess.run([CLAUDE, "-p", PROMPT_HEAD + "\n".join(lines), "--model", "haiku"],
                           capture_output=True, text=True, timeout=150)
    except subprocess.TimeoutExpired:
        return {}
    if r.returncode != 0:
        return {}
    txt = r.stdout
    s, e = txt.find("{"), txt.rfind("}")
    if s < 0 or e < 0:
        return {}
    try:
        return json.loads(txt[s:e + 1])
    except Exception:
        return {}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("config_dir")
    ap.add_argument("account_label")
    ap.add_argument("--execute", action="store_true")
    ap.add_argument("--chunk", type=int, default=60)
    a = ap.parse_args()

    cands = _candidates(a.config_dir)
    for c in cands:
        c["replied_before"] = _replied_before(a.config_dir, c["from"])

    archive_ids, kept, arch_s, keep_s = [], 0, [], []
    for i in range(0, len(cands), a.chunk):
        chunk = cands[i:i + a.chunk]
        verdict = _classify(chunk)
        for j, c in enumerate(chunk):
            if verdict.get(str(j), "keep") == "archive":   # default KEEP
                archive_ids.append(c["id"])
                if len(arch_s) < 18:
                    arch_s.append({"from": c["from"], "subject": c["subject"],
                                   "replied": c["replied_before"]})
            else:
                kept += 1
                if len(keep_s) < 18:
                    keep_s.append({"from": c["from"], "subject": c["subject"],
                                   "replied": c["replied_before"]})

    result = {"account": a.account_label, "candidates": len(cands),
              "to_archive": len(archive_ids), "to_keep": kept,
              "mode": "execute" if a.execute else "dry-run",
              "archive_sample": arch_s, "keep_sample": keep_s}

    if a.execute and archive_ids:
        recovery_label = iz._dated_label(iz._BASE_LABEL)
        label_id = iz._ensure_label(a.config_dir, recovery_label)
        result["archived"] = iz._batch_modify(a.config_dir, archive_ids,
                                               add_ids=[label_id], remove_ids=["INBOX"])
        result["recovery_label"] = recovery_label

    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main()
