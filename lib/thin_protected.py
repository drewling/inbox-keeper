#!/usr/bin/env python3
"""Token-light, reversible thinning of low-value inbox mail.

Uses Gmail's own category signals (no LLM tokens) to archive mail that never
needs human review — marketing, social notifications, and routine automated
updates — while always keeping starred, ⚡ Action, very recent (≤2d), and
high-stakes transactional/legal mail (the inbox_zero PROTECT_PATTERNS).

Like inbox_zero, this is fully reversible: it only removes INBOX and adds a
dated 🗄️ Auto-Archived recovery label. Nothing is deleted. Dry-run by default.

Buckets:
  promos-social : category:promotions OR category:social  (marketing + social)
  updates       : category:updates, minus PROTECT_PATTERNS (auto receipts/notifs)

Usage: thin_protected.py <config_dir> <account_label> <bucket> [--execute]
Prints a JSON summary.
"""
import argparse, json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import inbox_zero as iz  # noqa: E402  (reuse reversible archive helpers)

# Always-keep guard baked into every query (token-free). Note: we deliberately do
# NOT keep is:important here — the whole point is to thin the pile Gmail's
# is:important flag was holding. Category (promo/social/updates) overrides it.
KEEP = '-is:starred -label:"⚡ Action" -newer_than:2d'

# Negated PROTECT_PATTERNS: never thin high-stakes transactional/legal mail.
# Strip the leading 'in:inbox (' and trailing ')' and negate the whole group.
_PP = iz.PROTECT_PATTERNS.strip()
_inner = _PP[_PP.index("(") + 1: _PP.rindex(")")].strip()
NOT_PROTECTED = f"-({_inner})"

# Money / account / delivery terms: never thin an "update" that mentions any of
# these — bills, payment problems, receipts, security and shipping notices all
# deserve eyes even when automated. Kept as a query negation (token-free).
SENSITIVE = (
    '-(payment OR bill OR invoice OR receipt OR refund OR statement OR '
    'subscription OR renew OR renewal OR expire OR expiring OR suspend OR '
    'suspended OR overdue OR "past due" OR bank OR transaction OR charge OR '
    'charged OR balance OR deposit OR withdraw OR transfer OR security OR '
    'password OR "sign in" OR "log in" OR login OR verify OR verification OR '
    '"confirm your" OR delivery OR delivered OR shipped OR dispatch OR '
    'dispatched OR tracking OR order OR receipt OR booking OR reservation OR '
    'appointment OR "scheduled payment" OR "your account" OR fraud OR alert)'
)

# Positive allowlist of pure content/social-digest senders — editorial newsletters
# and social-network notifications that never need review. Conservative on purpose.
NOISE_SENDERS = (
    '(from:substack.com OR from:medium.com OR from:linkedin.com OR '
    'from:facebookmail.com OR from:reddit.com OR from:redditmail.com OR '
    'from:quora.com OR from:pinterest.com OR from:nextdoor.com OR '
    'from:x.com OR from:twitter.com OR from:meetup.com OR from:goodreads.com OR '
    'from:youtube.com OR from:notifications-noreply OR '
    'subject:"daily digest" OR subject:"weekly digest" OR subject:"recently posted" OR '
    'subject:newsletter OR subject:survey OR from:encuestas)'
)

BUCKETS = {
    "promos-social": f'in:inbox (category:promotions OR category:social) {KEEP}',
    "updates":       f'in:inbox category:updates {KEEP} {NOT_PROTECTED}',
    "updates-safe":  f'in:inbox category:updates {KEEP} {NOT_PROTECTED} {SENSITIVE}',
    "noise":         f'in:inbox {KEEP} {NOT_PROTECTED} {SENSITIVE} {NOISE_SENDERS}',
    # Aggressive: ALL bulk / mailing-list mail (has List-* headers) — newsletters,
    # marketing, automated notifications. Real person-to-person mail has no List
    # headers, so it's spared. Still keeps starred/Action/recent + financial/travel/security.
    "bulk":          f'in:inbox list:* {KEEP} {NOT_PROTECTED} {SENSITIVE}',
}


def _message_ids(config_dir, q):
    ids, tok = [], None
    while True:
        params = {"userId": "me", "q": q, "maxResults": 500}
        if tok:
            params["pageToken"] = tok
        d = iz.gws(config_dir, ["gmail", "users", "messages", "list",
                                "--params", json.dumps(params)])
        ids += [m["id"] for m in d.get("messages", []) or []]
        tok = d.get("nextPageToken")
        if not tok:
            break
    return ids


def _sample(config_dir, ids, n=8):
    out = []
    for mid in ids[:n]:
        m = iz.gws(config_dir, ["gmail", "users", "messages", "get", "--params",
                                json.dumps({"userId": "me", "id": mid, "format": "metadata",
                                            "metadataHeaders": ["From", "Subject"]})])
        h = {x["name"].lower(): x["value"] for x in m.get("payload", {}).get("headers", [])}
        out.append({"from": h.get("from", ""), "subject": h.get("subject", "")})
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("config_dir")
    ap.add_argument("account_label")
    ap.add_argument("bucket", choices=list(BUCKETS))
    ap.add_argument("--execute", action="store_true")
    a = ap.parse_args()

    q = BUCKETS[a.bucket]
    ids = _message_ids(a.config_dir, q)

    result = {"account": a.account_label, "bucket": a.bucket,
              "matched_messages": len(ids),
              "mode": "execute" if a.execute else "dry-run",
              "sample": _sample(a.config_dir, ids) if not a.execute else []}

    if a.execute and ids:
        recovery_label = iz._dated_label(iz._BASE_LABEL)
        label_id = iz._ensure_label(a.config_dir, recovery_label)
        applied = iz._batch_modify(a.config_dir, ids, add_ids=[label_id], remove_ids=["INBOX"])
        result["archived"] = applied
        result["recovery_label"] = recovery_label

    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main()
