#!/usr/bin/env python3
"""Generate context-aware reply drafts for ⚡ Action emails, gated on reply-worthiness.

For the given account, finds recent ⚡ Action threads. For each, gathers context
(full thread, prior correspondence with the sender, Drewl profile) and asks Haiku
to BOTH decide whether the account owner genuinely needs to reply AND draft the reply in one
structured call. Cold sales, financing pitches, vendor invites, and automated mail
are rejected (no draft). Only genuine, reply-worthy threads produce a Gmail draft
and a queue entry for Slack review.

Usage: gen_drafts.py <config_dir> [account_label] [newer_than]
Skips threads already present in the queue (by thread id).
"""
import base64, json, os, subprocess, sys, time, fcntl

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
sys.path.insert(0, ROOT)
import draftutil as du  # noqa: E402
import context as ctx  # noqa: E402
import config  # noqa: E402

QUEUE = config.QUEUE_PATH
CLAUDE = os.environ.get("CLAUDE_BIN", "claude")


def gws(config_dir, args):
    return du._gws(config_dir, args)


def label_id(config_dir, name):
    data = gws(config_dir, ["gmail", "users", "labels", "list",
                            "--params", json.dumps({"userId": "me"})])
    for l in data.get("labels", []):
        if l["name"] == name:
            return l["id"]
    return None


def load_queue():
    if not os.path.exists(QUEUE):
        return []
    with open(QUEUE) as f:
        try:
            return json.load(f)
        except Exception:
            return []


def append_queue(item):
    os.makedirs(os.path.dirname(QUEUE), exist_ok=True)
    with open(QUEUE, "a+") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        f.seek(0)
        try:
            data = json.load(f)
        except Exception:
            data = []
        data.append(item)
        f.seek(0); f.truncate()
        json.dump(data, f, ensure_ascii=False, indent=2)
        fcntl.flock(f, fcntl.LOCK_UN)


def _extract_json(text):
    """Pull the first balanced {...} JSON object out of model output."""
    start = text.find("{")
    if start < 0:
        return None
    depth, in_str, esc = 0, False, False
    for i in range(start, len(text)):
        c = text[i]
        if in_str:
            if esc:
                esc = False
            elif c == "\\":
                esc = True
            elif c == '"':
                in_str = False
        else:
            if c == '"':
                in_str = True
            elif c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0:
                    try:
                        return json.loads(text[start:i + 1])
                    except Exception:
                        return None
    return None


def judge_and_draft(sender, subject, context):
    """One structured Haiku call: decide reply-worthiness AND draft. Returns dict
    {needs_reply: bool, reason: str, reply: str} or None on failure."""
    from email.utils import parseaddr
    to_name = parseaddr(sender)[0] or parseaddr(sender)[1] or sender
    to_email = parseaddr(sender)[1] or sender
    hist_block = (
        f"PRIOR CORRESPONDENCE with this sender (most recent first):\n{context['history_summary']}"
        if context["history_summary"]
        else "PRIOR CORRESPONDENCE with this sender: NONE found — no two-way history."
    )
    prompt = f"""You decide whether the account owner genuinely needs to send a written reply to an email thread, and if so, you draft that reply in their voice. Be strict about signal vs noise.

=== OWNER / DREWL PROFILE & REPLY BOUNDARIES ===
{context['profile']}

=== PRIOR RELATIONSHIP ===
has_prior_two_way_history: {context['has_prior_history']}
{hist_block}

=== THE THREAD (oldest to newest) ===
Subject: {subject}

{context['thread_text']}

=== WHO YOU ARE REPLYING TO ===
The reply will be sent to **{to_name}** ({to_email}) — the person who sent the most
recent message. Address THIS person by their first name. A thread may mention other
people (other recipients, people quoted in earlier messages) — do NOT address or
greet them; they are not the recipient. The owner is the sender of your reply, never the
addressee.

=== YOUR TASK ===
1. Decide needs_reply. Set needs_reply=false (NO draft) when the message is cold sales,
   an outbound pitch, financing/lending/investment, a vendor event/webinar invite from a
   company the owner doesn't already work with, recruiting/link-building/guest-post outreach,
   an automated notification, or anything where there is no prior two-way history AND they
   want the owner to buy/book/invest/"hop on a call". Follow the REPLY BOUNDARIES above exactly.
   Set needs_reply=true only when a real person the owner knows or an active client/prospect is
   genuinely awaiting their response, decision, scheduling, or acknowledgement.
   IMPORTANT recall rule: if has_prior_two_way_history is TRUE and the latest message
   contains a direct question, request, proposal, or scheduling ask aimed at the owner, default
   to needs_reply=true — this is genuine relationship mail, not cold outreach. (A pure FYI
   notification with no ask, e.g. just sharing a meeting link, can still be needs_reply=false.)
2. If needs_reply=true, write the reply: British English, first person, warm and concise,
   2-6 sentences, mirror the counterparty's formality, reference real thread context, never
   invent facts/figures/dates — use placeholders like [day]/[time]/[amount] where needed.
   Sign off with the owner's first name.

Output ONLY a JSON object, nothing else:
{{"needs_reply": true|false, "reason": "<one short phrase>", "reply": "<reply text, or empty string if needs_reply is false>"}}"""
    try:
        r = subprocess.run([CLAUDE, "-p", prompt, "--model", "haiku"],
                           capture_output=True, text=True, timeout=120)
    except subprocess.TimeoutExpired:
        return None  # treat as non-reply / failure
    if r.returncode != 0:
        return None
    return _extract_json(r.stdout.strip())


def main():
    config_dir = sys.argv[1]
    account_label = sys.argv[2] if len(sys.argv) > 2 else config_dir
    newer = sys.argv[3] if len(sys.argv) > 3 else "1d"

    lid = label_id(config_dir, "⚡ Action")
    if not lid:
        print(json.dumps({"drafted": 0, "note": "no Action label"}))
        return

    try:
        profile_email = du._profile_email(config_dir)
    except Exception:
        profile_email = account_label

    existing_threads = {i["thread_id"] for i in load_queue()}
    lst = gws(config_dir, ["gmail", "users", "messages", "list", "--params",
                           json.dumps({"userId": "me",
                                       "q": f'label:"⚡ Action" in:inbox newer_than:{newer}',
                                       "maxResults": 25})])
    drafted = 0
    rejected = 0
    seen = set()
    for m in lst.get("messages", []) or []:
        tid = m["threadId"]
        if tid in seen or tid in existing_threads:
            continue
        seen.add(tid)
        thread = gws(config_dir, ["gmail", "users", "threads", "get", "--params",
                                  json.dumps({"userId": "me", "id": tid, "format": "full"})])
        msgs = thread.get("messages", []) or []
        if not msgs:
            continue
        last = msgs[-1]
        headers = {h["name"].lower(): h["value"] for h in last.get("payload", {}).get("headers", [])}
        sender = headers.get("from", "")
        subject = headers.get("subject", "(no subject)")
        snippet = (last.get("snippet", "") or "")[:240]

        # Don't draft if the last message in the thread is from the owner (ball's in their court).
        if profile_email and profile_email.lower() in sender.lower():
            continue

        context = ctx.gather(config_dir, msgs, sender, tid, profile_email)
        verdict = judge_and_draft(sender, subject, context)
        if not verdict or not verdict.get("needs_reply"):
            rejected += 1
            continue
        reply = (verdict.get("reply") or "").strip()
        if not reply:
            rejected += 1
            continue

        # Prefer Reply-To over From when deciding where to send the reply.
        reply_to = headers.get("reply-to", "")
        to_addr = du.parseaddr(reply_to)[1] if reply_to else ""
        if not to_addr:
            to_addr = du.parseaddr(sender)[1] or sender
        try:
            draft_id = subprocess.run(
                [config.PYTHON_BIN, os.path.join(HERE, "draftutil.py"),
                 "create", "--config-dir", config_dir, "--thread-id", tid,
                 "--to", to_addr,
                 "--subject-b64", base64.b64encode(subject.encode()).decode(),
                 "--body-b64", base64.b64encode(reply.encode()).decode()],
                capture_output=True, text=True, env=du._env(config_dir),
            ).stdout.strip()
        except Exception as e:
            print(f"draft create failed for {tid}: {e}", file=sys.stderr)
            continue
        if not draft_id:
            continue

        append_queue({
            "id": f"{int(time.time())}-{tid[:8]}",
            "account_config_dir": config_dir,
            "account_label": account_label,
            "draft_id": draft_id,
            "thread_id": tid,
            "to": to_addr,
            "subject": subject if subject.lower().startswith("re:") else f"Re: {subject}",
            "original_from": sender,
            "original_snippet": snippet,
            "reply_body": reply,
            "why": verdict.get("reason", ""),
            "has_history": context["has_prior_history"],
            "status": "pending",
            "slack_ts": None,
        })
        drafted += 1

    print(json.dumps({"drafted": drafted, "rejected": rejected}))


if __name__ == "__main__":
    main()
