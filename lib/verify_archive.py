#!/usr/bin/env python3
"""Safety check for inbox_zero: sample threads that WOULD be archived and ask Haiku
whether any look genuinely important / still-actionable. Surfaces false-archives
before we commit. Usage: verify_archive.py <config_dir> [sample_n] [grace] [imp_window]
"""
import json, os, subprocess, sys, hashlib
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import draftutil as du
import context as ctx
import inbox_zero as iz

CLAUDE = os.environ.get("CLAUDE_BIN", "claude")


def main():
    cfg = sys.argv[1]
    N = int(sys.argv[2]) if len(sys.argv) > 2 else 40
    grace = sys.argv[3] if len(sys.argv) > 3 else "7"
    impw = sys.argv[4] if len(sys.argv) > 4 else "60"

    protect = iz.build_protect_set(cfg, int(grace), int(impw))
    inbox = iz._inbox_messages(cfg)
    archive_threads = [t for _, t in inbox if t not in protect]

    # de-dup preserving order
    seen = set(); uniq = []
    for t in archive_threads:
        if t not in seen:
            seen.add(t); uniq.append(t)

    # deterministic pseudo-random sample (no Math.random): pick by hash order
    uniq.sort(key=lambda t: hashlib.md5(t.encode()).hexdigest())
    sample = uniq[:N]

    rows = []
    for i, tid in enumerate(sample):
        try:
            msg = du._gws(cfg, ["gmail", "users", "messages", "get", "--params",
                                json.dumps({"userId": "me", "id": tid, "format": "metadata",
                                            "metadataHeaders": ["From", "Subject", "Date"]})])
        except Exception:
            continue
        h = {x["name"].lower(): x["value"] for x in msg.get("payload", {}).get("headers", [])}
        rows.append((i, h.get("from", ""), h.get("subject", ""), (msg.get("snippet", "") or "")[:120]))

    listing = "\n".join(f'{i}. from={f} | subj={s} | {sn}' for i, f, s, sn in rows)
    prompt = f"""These inbox emails are about to be ARCHIVED as noise. Flag ONLY the ones that look genuinely important or still need Tayo's action (real person awaiting reply, payment/security/legal problem, client/deadline). Ignore newsletters, promos, notifications, receipts, social, cold outreach.

{ctx.drewl_profile()}

EMAILS:
{listing}

Output ONLY a JSON array of indices that should NOT be archived (important), e.g. [3,17]. If all are safe to archive, output []."""
    r = subprocess.run([CLAUDE, "-p", prompt, "--model", "haiku"], capture_output=True, text=True)
    txt = r.stdout.strip()
    a, b = txt.find("["), txt.rfind("]")
    flagged = []
    if a >= 0 and b >= 0:
        try:
            flagged = json.loads(txt[a:b + 1])
        except Exception:
            flagged = []
    flagged_rows = [(f, s) for i, f, s, _ in rows if i in flagged]
    print(json.dumps({"sampled": len(rows), "flagged_important": len(flagged),
                      "items": [{"from": f, "subject": s} for f, s in flagged_rows]},
                     ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
