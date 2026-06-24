#!/usr/bin/env python3
"""Context gathering for AI-drafted replies.

Pulls the three sources the draft pipeline grounds on:
  1. The full thread (all messages, who said what) — not just the last message.
  2. Prior correspondence with the sender — establishes relationship + the owner's tone
     with this person, and whether any two-way history exists at all (the key
     cold-outreach signal).
  3. The Drewl profile / reply boundaries (knowledge/drewl.md).

All Gmail access goes through gws via draftutil helpers, headless-safe.
"""
import base64, html, json, os, re
from email.utils import parseaddr

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
import sys
sys.path.insert(0, HERE)
sys.path.insert(0, ROOT)
import draftutil as du  # noqa: E402
import config  # noqa: E402

PROFILE_PATH = config.PROFILE_PATH


def drewl_profile():
    try:
        with open(PROFILE_PATH) as f:
            return f.read().strip()
    except OSError:
        return ""


def _plain_body(payload):
    if payload.get("mimeType", "").startswith("text/plain") and payload.get("body", {}).get("data"):
        return base64.urlsafe_b64decode(payload["body"]["data"]).decode("utf-8", "replace")
    for part in payload.get("parts", []) or []:
        r = _plain_body(part)
        if r:
            return r
    if payload.get("mimeType", "").startswith("text/html") and payload.get("body", {}).get("data"):
        raw = base64.urlsafe_b64decode(payload["body"]["data"]).decode("utf-8", "replace")
        return html.unescape(re.sub("<[^>]+>", " ", raw))
    return ""


def _hdr(msg, name):
    for h in msg.get("payload", {}).get("headers", []):
        if h["name"].lower() == name.lower():
            return h["value"]
    return ""


def render_thread(msgs, profile_email, max_chars=4000):
    """Render the whole thread compactly: each message as 'NAME (date): body'."""
    lines = []
    for m in msgs:
        frm = _hdr(m, "from")
        date = _hdr(m, "date")
        who = "Me" if profile_email and profile_email.lower() in frm.lower() else (parseaddr(frm)[0] or parseaddr(frm)[1] or frm)
        body = _plain_body(m.get("payload", {})).strip()
        # collapse quoted tails and signatures roughly
        body = re.split(r"\nOn .+ wrote:\n|\n-- \n|\n_{5,}", body)[0].strip()
        body = re.sub(r"\n{3,}", "\n\n", body)
        lines.append(f"### {who} — {date}\n{body[:1200]}")
    text = "\n\n".join(lines)
    return text[:max_chars]


def sender_history(config_dir, sender_email, current_thread_id, profile_email, max_msgs=6):
    """Return (has_history, summary_text) for prior correspondence with sender_email.

    has_history is True only if there's a genuine prior two-way exchange (the owner has
    sent to them OR there are multiple older messages) — the anti-cold-outreach signal.
    """
    addr = parseaddr(sender_email)[1] or sender_email
    if not addr or "@" not in addr:
        return False, ""
    try:
        lst = du._gws(config_dir, ["gmail", "users", "messages", "list", "--params",
                                   json.dumps({"userId": "me",
                                               "q": f"(from:{addr} OR to:{addr})",
                                               "maxResults": 25})])
    except Exception:
        return False, ""
    msgs = lst.get("messages", []) or []
    # Drop the current thread's own messages.
    ids = [m for m in msgs if m.get("threadId") != current_thread_id]
    owner_sent = False
    samples = []
    seen_threads = set()
    for m in ids[:max_msgs * 2]:
        if len(samples) >= max_msgs:
            break
        try:
            full = du._gws(config_dir, ["gmail", "users", "messages", "get", "--params",
                                        json.dumps({"userId": "me", "id": m["id"], "format": "metadata",
                                                    "metadataHeaders": ["From", "To", "Subject", "Date"]})])
        except Exception:
            continue
        frm = _hdr(full, "from")
        is_owner = bool(profile_email and profile_email.lower() in frm.lower())
        if is_owner:
            owner_sent = True
        snip = (full.get("snippet", "") or "")[:160]
        direction = "I wrote" if is_owner else "They wrote"
        samples.append(f"- [{_hdr(full,'date')[:16]}] {direction}: {snip}")
        seen_threads.add(full.get("threadId"))
    has_history = owner_sent or len(seen_threads) >= 1 and len(samples) >= 2
    summary = "\n".join(samples)
    return has_history, summary


def gather(config_dir, thread_msgs, sender_email, current_thread_id, profile_email):
    """Bundle everything the gate + drafter need."""
    has_hist, hist = sender_history(config_dir, sender_email, current_thread_id, profile_email)
    return {
        "profile": drewl_profile(),
        "thread_text": render_thread(thread_msgs, profile_email),
        "has_prior_history": has_hist,
        "history_summary": hist,
    }
