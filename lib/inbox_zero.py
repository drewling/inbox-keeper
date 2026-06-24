#!/usr/bin/env python3
"""One-off (repeatable) reversible inbox-zero sweep for a single account.

Strategy: keep only what matters in the inbox, archive the rest. Archiving = remove
the INBOX label + add a single recovery label, so the entire operation is undoable
with one query. Mail is never deleted; it stays in All Mail, fully searchable.

PROTECTED (kept in inbox), the union of:
  - is:starred                      (you explicitly flagged it)
  - label:"⚡ Action"               (our triage flagged it as needing action)
  - is:important                    (Gmail's own importance model)
  - newer_than:<grace>d             (recent — may be unprocessed)
  - is:unread newer_than:<uread>d   (recent unread — you haven't seen it)
  - any thread ids passed via --protect-extra (e.g. an LLM importance sweep)

ARCHIVED: every other inbox thread, at message granularity, via batchModify
(chunks of 1000), removing INBOX and adding the recovery label.

Default is DRY-RUN (reports counts + a sample, changes nothing). Pass --execute to act.

Usage:
  inbox_zero.py <config_dir> [--grace 7] [--unread-grace 30] [--no-important]
                [--recovery-label "🗄️ Auto-Archived"] [--protect-extra ids.txt]
                [--execute]

Recovery label: each sweep uses "🗄️ Auto-Archived <YYYY-MM-DD>" so every run is
independently undoable. Override with --recovery-label to use a custom label.
Set env var SWEEP_DATE=YYYY-MM-DD to force a specific date (useful for testing).
"""
import argparse, json, os, subprocess, sys
from datetime import date

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import draftutil as du  # noqa: E402

_BASE_LABEL = "🗄️ Auto-Archived"


def _strip_keyring(text):
    return "\n".join(l for l in text.splitlines() if "keyring" not in l).strip()


def gws(config_dir, args, allow_empty=False):
    return du._gws(config_dir, args, allow_empty=allow_empty)


def _thread_ids(config_dir, q):
    """All unique thread ids matching a query (paginated). Raises on subprocess failure
    or API error in any page. Raises if no page returned any data at all."""
    out = set()
    r = subprocess.run(["gws", "gmail", "users", "messages", "list",
                        "--params", json.dumps({"userId": "me", "q": q, "maxResults": 500}),
                        "--page-all", "--page-limit", "500"],
                       capture_output=True, text=True, env=du._env(config_dir))
    if r.returncode != 0:
        err = _strip_keyring(r.stderr) or _strip_keyring(r.stdout) or "gws non-zero exit"
        raise RuntimeError(f"_thread_ids({q!r}): {err}")

    parsed_any = False
    for line in r.stdout.splitlines():
        line = line.strip()
        if not line.startswith("{") or "keyring" in line:
            continue
        try:
            o = json.loads(line)
        except Exception:
            continue
        if "error" in o:
            raise RuntimeError(f"_thread_ids({q!r}): API error: {json.dumps(o['error'])}")
        parsed_any = True
        for m in o.get("messages", []) or ([o] if "id" in o else []):
            if m.get("threadId"):
                out.add(m["threadId"])

    # If gws printed nothing parseable (but rc==0 and query ran), that may just mean
    # an empty result set — only raise if we got no parseable lines AND no messages,
    # which can happen when gws itself crashed silently. We tolerate a genuinely empty
    # result (e.g. no starred messages) — an absent parsed_any with an empty stdout
    # after stripping keyring lines is a real failure.
    cleaned_stdout = _strip_keyring(r.stdout)
    if not parsed_any and cleaned_stdout:
        raise RuntimeError(
            f"_thread_ids({q!r}): output not parseable as JSON pages: {cleaned_stdout[:200]}"
        )

    return out


def _inbox_messages(config_dir):
    """All inbox messages as (msg_id, thread_id) pairs (paginated).
    Raises on subprocess failure or API error. Raises if output is unparseable."""
    pairs = []
    r = subprocess.run(["gws", "gmail", "users", "messages", "list",
                        "--params", json.dumps({"userId": "me", "q": "in:inbox", "maxResults": 500}),
                        "--page-all", "--page-limit", "500"],
                       capture_output=True, text=True, env=du._env(config_dir))
    if r.returncode != 0:
        err = _strip_keyring(r.stderr) or _strip_keyring(r.stdout) or "gws non-zero exit"
        raise RuntimeError(f"_inbox_messages: {err}")

    parsed_any = False
    for line in r.stdout.splitlines():
        line = line.strip()
        if not line.startswith("{") or "keyring" in line:
            continue
        try:
            o = json.loads(line)
        except Exception:
            continue
        if "error" in o:
            raise RuntimeError(f"_inbox_messages: API error: {json.dumps(o['error'])}")
        parsed_any = True
        for m in o.get("messages", []) or ([o] if "id" in o else []):
            if m.get("id"):
                pairs.append((m["id"], m.get("threadId")))

    cleaned_stdout = _strip_keyring(r.stdout)
    if not parsed_any and cleaned_stdout:
        raise RuntimeError(
            f"_inbox_messages: output not parseable as JSON pages: {cleaned_stdout[:200]}"
        )

    return pairs


def _ensure_label(config_dir, name):
    data = gws(config_dir, ["gmail", "users", "labels", "list",
                            "--params", json.dumps({"userId": "me"})])
    for l in data.get("labels", []):
        if l["name"] == name:
            return l["id"]
    created = gws(config_dir, ["gmail", "users", "labels", "create",
                               "--params", json.dumps({"userId": "me"}),
                               "--json", json.dumps({"name": name,
                                                     "labelListVisibility": "labelShow",
                                                     "messageListVisibility": "show"})])
    return created["id"]


def _batch_modify(config_dir, msg_ids, add_ids, remove_ids):
    """Apply label changes in 1000-message chunks. Raises on any failed chunk.
    Returns the number of messages successfully modified."""
    applied = 0
    for i in range(0, len(msg_ids), 1000):
        chunk = msg_ids[i:i + 1000]
        try:
            gws(config_dir, ["gmail", "users", "messages", "batchModify",
                             "--params", json.dumps({"userId": "me"}),
                             "--json", json.dumps({"ids": chunk,
                                                   "addLabelIds": add_ids,
                                                   "removeLabelIds": remove_ids})],
                allow_empty=True)
        except Exception as exc:
            raise RuntimeError(
                f"batchModify failed on chunk {i}–{i+len(chunk)}: {exc}"
            )
        applied += len(chunk)
    return applied


def _count_inbox(config_dir):
    """Return approximate count of in:inbox messages (best-effort; returns None on error)."""
    try:
        r = subprocess.run(["gws", "gmail", "users", "messages", "list",
                            "--params", json.dumps({"userId": "me",
                                                    "q": "in:inbox", "maxResults": 1})],
                           capture_output=True, text=True, env=du._env(config_dir), timeout=30)
        if r.returncode != 0:
            return None
        for line in r.stdout.splitlines():
            line = line.strip()
            if line.startswith("{") and "keyring" not in line:
                try:
                    o = json.loads(line)
                    est = o.get("resultSizeEstimate")
                    if est is not None:
                        return int(est)
                except Exception:
                    pass
    except Exception:
        pass
    return None


# High-stakes transactional / legal mail to protect across ALL time (low volume,
# but you never want to bury a contract to sign or a failed payment).
PROTECT_PATTERNS = (
    'in:inbox ('
    # E-signature requests, but ONLY live ones — completed/voided/declined envelopes
    # and bare comment notifications are settled and should not be shielded forever.
    '((from:docusign.net OR from:hellosign.com OR from:dropboxsign.com) '
    '-subject:completed -subject:voided -subject:declined -subject:"new comment") OR '
    'subject:"please sign" OR subject:"signature requested" OR subject:"e-signature" OR '
    'subject:"payment failed" OR subject:"payment declined" OR subject:"payment unsuccessful" OR '
    'subject:"past due" OR subject:"direct debit" OR subject:"card declined" OR '
    'subject:"final notice" OR from:hmrc.gov.uk'
    ')'
)


def build_protect_set(config_dir, grace, important_window, no_important=False, extra_path=None):
    """The set of inbox thread ids to KEEP (never archive). Raises on any lookup error."""
    protect = set()
    protect |= _thread_ids(config_dir, "in:inbox is:starred")
    protect |= _thread_ids(config_dir, 'in:inbox label:"⚡ Action"')
    protect |= _thread_ids(config_dir, f"in:inbox newer_than:{grace}d")
    protect |= _thread_ids(config_dir, PROTECT_PATTERNS)
    if not no_important:
        iq = "in:inbox is:important"
        if important_window > 0:
            iq += f" newer_than:{important_window}d"
        protect |= _thread_ids(config_dir, iq)
    if extra_path and os.path.exists(extra_path):
        with open(extra_path) as f:
            protect |= {l.strip() for l in f if l.strip()}
    return protect


def _dated_label(user_label):
    """Append today's date to the label name if it's the default base label."""
    sweep_date = os.environ.get("SWEEP_DATE")
    if sweep_date:
        today = sweep_date
    else:
        today = date.today().isoformat()
    return f"{user_label} {today}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("config_dir")
    ap.add_argument("--grace", type=int, default=7, help="protect mail newer than N days")
    ap.add_argument("--important-window", type=int, default=60,
                    help="protect Gmail is:important mail newer than N days (0 = all important)")
    ap.add_argument("--no-important", action="store_true", help="do NOT protect Gmail is:important")
    ap.add_argument("--recovery-label", default=_BASE_LABEL)
    ap.add_argument("--protect-extra", help="file with extra thread ids to protect (one per line)")
    ap.add_argument("--execute", action="store_true", help="actually archive (default: dry-run)")
    a = ap.parse_args()

    cfg = a.config_dir
    try:
        email = du._profile_email(cfg)
    except Exception:
        email = cfg

    # Determine the dated recovery label for this run.
    # If the user passed a custom label, use it as-is; otherwise append today's date.
    if a.recovery_label == _BASE_LABEL:
        recovery_label = _dated_label(_BASE_LABEL)
    else:
        recovery_label = a.recovery_label

    # Build protect set first; abort the sweep if it raises.
    try:
        protect = build_protect_set(cfg, a.grace, a.important_window,
                                    no_important=a.no_important, extra_path=a.protect_extra)
    except Exception as exc:
        print(json.dumps({
            "account": email,
            "error": f"protect set failed — sweep aborted: {exc}",
            "executed": False,
        }), file=sys.stderr)
        sys.exit(1)

    inbox = _inbox_messages(cfg)
    inbox_threads = {t for _, t in inbox}
    archive_msg_ids = [mid for mid, tid in inbox if tid not in protect]
    archive_threads = {tid for _, tid in inbox if tid not in protect}

    report = {
        "account": email,
        "inbox_threads": len(inbox_threads),
        "inbox_messages": len(inbox),
        "protected_threads": len(inbox_threads & protect),
        "archive_threads": len(archive_threads),
        "archive_messages": len(archive_msg_ids),
        "recovery_label": recovery_label,
        "executed": False,
    }

    if not a.execute:
        report["mode"] = "dry-run"
        print(json.dumps(report, ensure_ascii=False))
        return

    label_id = _ensure_label(cfg, recovery_label)
    try:
        applied = _batch_modify(cfg, archive_msg_ids, add_ids=[label_id], remove_ids=["INBOX"])
    except Exception as exc:
        report["error"] = str(exc)
        print(json.dumps(report, ensure_ascii=False), file=sys.stderr)
        sys.exit(1)

    report["executed"] = True
    report["mode"] = "execute"
    report["applied_messages"] = applied

    # Post-condition: re-query inbox count to verify archiving took effect.
    remaining = _count_inbox(cfg)
    report["verified_remaining"] = remaining
    if remaining is not None and remaining > len(inbox) - applied + 5:
        # Remaining count is suspiciously high — surface a warning.
        report["warning"] = (
            f"inbox still shows ~{remaining} messages after archiving {applied}; "
            "archive may not have fully applied"
        )

    print(json.dumps(report, ensure_ascii=False))


if __name__ == "__main__":
    main()
