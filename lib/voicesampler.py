#!/usr/bin/env python3
"""Fetch and cache a handful of the owner's own SENT messages as voice exemplars.

The exemplars are the single biggest lever for getting drafts that sound like the
owner: concrete samples beat any description. We strip quoted history, forwarded
blocks, and signatures so the model sees only what the owner actually typed.

Cache: learning/voice_<slug>.json — refreshed when missing or older than TTL_DAYS.
All Gmail access is READ-ONLY (list + get, no mutations).
"""
import base64, html as _html_mod, json, os, re, time
from email.utils import parseaddr

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
LEARN_DIR = os.path.join(ROOT, "learning")

TTL_DAYS = 7
TTL_SECS = TTL_DAYS * 86400
FETCH_COUNT = 25   # candidates to fetch from sent; filtered down to MAX_KEEP
MAX_KEEP   = 6     # exemplars written to cache / used in prompt


def _env(config_dir):
    e = dict(os.environ)
    e["GOOGLE_WORKSPACE_CLI_CONFIG_DIR"] = config_dir
    e["GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND"] = "file"
    return e


def _gws(config_dir, args):
    """Thin wrapper — identical pattern to draftutil._gws but local to avoid
    circular imports (draftutil imports nothing from this module)."""
    import subprocess
    GWS = os.environ.get("GWS_BIN", "gws")
    # Bounded: a hung gws (OAuth refresh stall, network hang) must not block the
    # draft path. TimeoutExpired is an Exception, so callers' try/except degrade it.
    r = subprocess.run([GWS] + args, capture_output=True, text=True,
                       env=_env(config_dir), timeout=20)
    if r.returncode != 0:
        raise RuntimeError(f"gws exited {r.returncode}")
    line = "\n".join(l for l in r.stdout.splitlines() if "keyring" not in l)
    if not line.strip():
        return {}
    return json.loads(line)


def _decode_part(part):
    """Recursively extract plain-text from a MIME payload part."""
    mime = part.get("mimeType", "")
    body_data = (part.get("body") or {}).get("data", "")
    if mime == "text/plain" and body_data:
        return base64.urlsafe_b64decode(body_data).decode("utf-8", "replace")
    if mime == "text/html" and body_data:
        raw = base64.urlsafe_b64decode(body_data).decode("utf-8", "replace")
        return _html_mod.unescape(re.sub("<[^>]+>", " ", raw))
    for sub in part.get("parts") or []:
        t = _decode_part(sub)
        if t:
            return t
    return ""


# Patterns that mark the start of quoted/forwarded content we want to drop.
_QUOTE_CUT = re.compile(
    r"\n(?:"
    r"On .{10,120} wrote:\s*\n"     # "On Mon Jan 1… wrote:"
    r"|>[ \t]"                       # inline quote prefix
    r"|_{5,}"                        # horizontal rule
    r"|[-]{5,}"                      # dashes rule
    r"|From:\s"                      # forwarded "From:" header block
    r"|Sent:\s"                      # forwarded "Sent:" header
    r")",
    re.IGNORECASE,
)

# Signature boundary: "-- " alone on a line, or common sign-off patterns.
_SIG_CUT = re.compile(
    r"\n(?:--[ \t]*\n|(?:Regards|Best|Thanks|Cheers|Sent from my)[^\n]{0,60}\n)",
    re.IGNORECASE,
)


def _strip_boilerplate(text):
    """Keep only what the owner typed: strip quoted history, sigs, forwarded blocks."""
    # Cut at the first quote / forward marker.
    m = _QUOTE_CUT.search(text)
    if m:
        text = text[: m.start()]
    # Cut at signature boundary.
    m = _SIG_CUT.search(text)
    if m:
        text = text[: m.start()]
    # Collapse excess blank lines.
    text = re.sub(r"\n{3,}", "\n\n", text).strip()
    return text


# Subjects that indicate automated / bot-generated outbound mail to skip.
_AUTO_SUBJECT = re.compile(
    r"mail (digest|triage)|morning digest|catch-up sweep|system.?test|"
    r"auto.?reply|out of office|unsubscribe",
    re.IGNORECASE,
)

# Recipients that are clearly bots / list addresses — skip those messages.
_AUTO_TO = re.compile(
    r"@(slack\.com|noreply|no-reply|notifications?\.|mailer\.|bounce\.|"
    r"mail\.anthropic|sendgrid|mailgun|postmark)",
    re.IGNORECASE,
)


def _fetch_sent(config_dir, count=FETCH_COUNT):
    """Return up to MAX_KEEP full message bodies from in:sent (newest first).

    Skips automated/bot outbound messages (digest emails, system tests, etc.)
    so exemplars reflect actual human-written correspondence.
    """
    try:
        lst = _gws(config_dir, ["gmail", "users", "messages", "list", "--params",
                                 json.dumps({"userId": "me", "q": "in:sent",
                                             "maxResults": count})])
    except Exception:
        return []
    ids = [m["id"] for m in (lst.get("messages") or [])]
    results = []
    for mid in ids:
        if len(results) >= MAX_KEEP:
            break
        try:
            msg = _gws(config_dir, ["gmail", "users", "messages", "get", "--params",
                                    json.dumps({"userId": "me", "id": mid,
                                                "format": "full"})])
        except Exception:
            continue
        headers = {h["name"].lower(): h["value"]
                   for h in (msg.get("payload") or {}).get("headers", [])}
        subject = headers.get("subject", "")
        to_addr = headers.get("to", "")
        # Skip automated/system messages by subject or recipient pattern.
        if _AUTO_SUBJECT.search(subject) or _AUTO_TO.search(to_addr):
            continue
        raw_body = _decode_part(msg.get("payload") or {})
        body = _strip_boilerplate(raw_body)
        if len(body) < 30:
            # Too short after stripping — likely an automated / empty message.
            continue
        results.append({"subject": subject, "body": body[:600]})
    return results


def _cache_path(slug):
    os.makedirs(LEARN_DIR, exist_ok=True)
    return os.path.join(LEARN_DIR, f"voice_{slug}.json")


def _load_cache(slug):
    p = _cache_path(slug)
    if not os.path.exists(p):
        return None
    try:
        with open(p) as f:
            data = json.load(f)
        if time.time() - data.get("ts", 0) < TTL_SECS:
            return data.get("exemplars", [])
    except Exception:
        pass
    return None


def _save_cache(slug, exemplars):
    p = _cache_path(slug)
    try:
        with open(p, "w") as f:
            json.dump({"ts": int(time.time()), "exemplars": exemplars}, f)
    except Exception:
        pass


def get_voice_exemplars(config_dir, slug):
    """Return a list of {"subject", "body"} dicts representing the owner's voice.

    Uses the on-disk cache (TTL_DAYS) so per-draft latency stays low; falls back
    to [] on any error so the draft path never hard-fails due to this module.
    """
    cached = _load_cache(slug)
    if cached is not None:
        return cached
    try:
        exemplars = _fetch_sent(config_dir)
    except Exception:
        exemplars = []
    if exemplars:
        _save_cache(slug, exemplars)
    return exemplars


def get_recipient_exemplars(config_dir, recipient_email, owner_email, current_thread_id,
                             max_fetch=8, max_keep=4):
    """Return (relationship_tier, list-of-body-strings) for prior messages the
    owner sent TO recipient_email.

    relationship_tier: "new"  — no prior outbound mail found
                       "known" — owner has sent to them before
    Runs live (not cached) — the result set is small and recipient-specific.
    """
    addr = parseaddr(recipient_email)[1] or recipient_email
    if not addr or "@" not in addr:
        return "new", []
    try:
        lst = _gws(config_dir, ["gmail", "users", "messages", "list", "--params",
                                 json.dumps({"userId": "me",
                                             "q": f"in:sent to:{addr}",
                                             "maxResults": max_fetch})])
    except Exception:
        return "new", []
    ids = [m["id"] for m in (lst.get("messages") or [])
           if m.get("threadId") != current_thread_id]
    bodies = []
    for mid in ids[:max_fetch]:
        if len(bodies) >= max_keep:
            break
        try:
            msg = _gws(config_dir, ["gmail", "users", "messages", "get", "--params",
                                    json.dumps({"userId": "me", "id": mid,
                                                "format": "full"})])
        except Exception:
            continue
        raw = _decode_part(msg.get("payload") or {})
        body = _strip_boilerplate(raw)
        if len(body) < 20:
            continue
        bodies.append(body[:400])
    tier = "known" if bodies else "new"
    return tier, bodies
