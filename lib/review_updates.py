#!/usr/bin/env python3
"""Token-light LLM review of the 'updates' pile, archiving only true noise.

Deterministic category rules can't safely thin Gmail's 'updates' bucket — it mixes
newsletters with bills, flight changes, deliveries and security alerts in many
languages. So we do a CHEAP review: feed Haiku only sender + subject (no bodies)
for each candidate and let it decide keep vs archive. Reversible (dated recovery
label); dry-run by default.

A message is archived ONLY if Haiku marks it pure noise (content newsletter,
social/digest, marketing blast, survey, non-actionable app notification). Anything
transactional, financial, travel, delivery, security, account, legal, or that
might need a human response is KEPT.

Usage: review_updates.py <config_dir> <account_label> [--execute] [--chunk 60]
"""
import argparse, json, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import inbox_zero as iz  # noqa: E402
import thin_protected as tp  # noqa: E402  (reuse the 'updates' query)

CLAUDE = os.environ.get("CLAUDE_BIN", "claude")

PROMPT_HEAD = """You are triaging automated "Updates" emails for Tayo. For EACH numbered email below (you only see sender + subject), decide:
- "archive" — pure noise that never needs review: content newsletters, blog/news digests, social-network notifications, marketing blasts, surveys, non-actionable app/product announcements.
- "keep" — ANYTHING that could matter: bills, payments, receipts, orders, deliveries/shipping, travel/flight/booking changes, security/account/login alerts, legal, anything addressed personally or that might need a response. When unsure, KEEP.

Output ONLY a JSON object mapping each number to "archive" or "keep", e.g. {"0":"archive","1":"keep"}. No prose.

EMAILS:
"""


def _candidates(config_dir):
    q = tp.BUCKETS["updates"]
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
    out = []
    for mid in ids:
        m = iz.gws(config_dir, ["gmail", "users", "messages", "get", "--params",
                                json.dumps({"userId": "me", "id": mid, "format": "metadata",
                                            "metadataHeaders": ["From", "Subject"]})])
        h = {x["name"].lower(): x["value"] for x in m.get("payload", {}).get("headers", [])}
        out.append({"id": mid, "from": h.get("from", ""), "subject": h.get("subject", "")})
    return out


def _classify(chunk):
    lines = [f'{i}. from: {c["from"]} | subject: {c["subject"]}' for i, c in enumerate(chunk)]
    prompt = PROMPT_HEAD + "\n".join(lines)
    try:
        r = subprocess.run([CLAUDE, "-p", prompt, "--model", "haiku"],
                           capture_output=True, text=True, timeout=120)
    except subprocess.TimeoutExpired:
        return {}
    if r.returncode != 0:
        return {}
    txt = r.stdout
    s = txt.find("{")
    e = txt.rfind("}")
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
    archive_ids, kept, archived_samples = [], 0, []
    for i in range(0, len(cands), a.chunk):
        chunk = cands[i:i + a.chunk]
        verdict = _classify(chunk)
        for j, c in enumerate(chunk):
            v = verdict.get(str(j), "keep")  # default KEEP on any ambiguity
            if v == "archive":
                archive_ids.append(c["id"])
                if len(archived_samples) < 12:
                    archived_samples.append({"from": c["from"], "subject": c["subject"]})
            else:
                kept += 1

    result = {"account": a.account_label, "candidates": len(cands),
              "to_archive": len(archive_ids), "to_keep": kept,
              "mode": "execute" if a.execute else "dry-run",
              "archive_sample": archived_samples}

    if a.execute and archive_ids:
        recovery_label = iz._dated_label(iz._BASE_LABEL)
        label_id = iz._ensure_label(a.config_dir, recovery_label)
        result["archived"] = iz._batch_modify(a.config_dir, archive_ids,
                                               add_ids=[label_id], remove_ids=["INBOX"])
        result["recovery_label"] = recovery_label

    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main()
