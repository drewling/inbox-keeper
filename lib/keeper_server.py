#!/usr/bin/env python3
"""Local HTTP server behind the zero menu-bar panel.

Stdlib only (no dependencies) so the open-source install stays trivial. Binds to
127.0.0.1 and exposes a small JSON API:

  GET  /api/state        -> app/state.json (instant; built by dashboard_state.py)
  POST /api/refresh      -> rebuild state in the background, returns {job}
  POST /api/run          -> run the keeper (open-loop sweep), then rebuild state
  POST /api/undo         -> restore a dated recovery label, then rebuild state
  GET  /api/job          -> status of the single background job slot
  GET  /api/policy       -> keep-policy.md text
  PUT  /api/policy       -> overwrite keep-policy.md

Only one background job runs at a time (keeper operations touch Gmail and should
not overlap). The panel polls /api/job while one is active.
"""
import json, os, re, signal, subprocess, sys, threading, time
from concurrent.futures import ThreadPoolExecutor, as_completed
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
STATE_PATH = os.path.join(ROOT, "app", "state.json")
POLICY_PATH = os.path.join(ROOT, "keep-policy.md")
ACCOUNTS_PATH = os.path.join(ROOT, "accounts.json")
CATEGORIES_PATH = os.path.join(ROOT, "categories.json")
SETTINGS_PATH = os.path.join(ROOT, "app", "settings.json")
# A run drops a one-shot notification here; the app pops it and posts a native
# notification (so it carries the app icon and opens the panel on click).
PENDING_NOTIFICATION_PATH = os.path.join(ROOT, "app", "pending_notification.json")
_notif_lock = threading.Lock()
_DATE_RE = re.compile(r"^\d{4}/\d{2}/\d{2}$")
PYTHON = sys.executable or "python3"
# ponytail: CLAUDE_BIN lookup moved to lib/llm.py; removed module-level constant

# gws reads per-account credentials from its keyring/config dir; this app never uses
# a pre-obtained global token. A stray GOOGLE_WORKSPACE_CLI_TOKEN in the environment
# (e.g. exported from a shell profile) is treated by gws as the access token and, if
# malformed, breaks every call with "failed to parse header value". Drop it so the
# server and every gws subprocess it spawns are immune, however the server was launched.
os.environ.pop("GOOGLE_WORKSPACE_CLI_TOKEN", None)

# Default category appearance — single source of truth; used in _DEFAULT_CATEGORIES
# and the PUT /api/categories handler.
DEFAULT_CATEGORY_COLOR = "#5C6BC0"
DEFAULT_CATEGORY_EMOJI = "🏷️"

# --- single background job slot -------------------------------------------------
_job_lock = threading.Lock()
_job = {"id": 0, "kind": None, "state": "idle", "started": 0, "finished": 0,
        "message": "", "error": None, "auth_url": None}

# --- non-blocking boot state ----------------------------------------------------
# _building is True while the background boot rebuild is running so /api/state
# can report it immediately instead of blocking the HTTP server. Guarded by _boot_lock.
_boot_lock = threading.Lock()
_building = False

# --- auth subprocess tracking (for cancel support) ------------------------------
_auth_lock = threading.Lock()
_auth_proc = None        # Popen object of the live gws auth login process (or None)
_auth_pgid = None        # process-group id of that process
_cancel_requested = False


def _gws_env():
    e = dict(os.environ)
    e["GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND"] = "file"
    return e


_state_lock = threading.Lock()


def _drop_loop(slug, tid):
    """Surgically remove one loop from the cached state (used by dismiss + send)."""
    def _m(st):
        for a in st.get("accounts", []):
            if a.get("slug") != slug:
                continue
            before = len(a.get("loops", []))
            a["loops"] = [l for l in a.get("loops", []) if l.get("thread_id") != tid]
            if len(a["loops"]) < before:
                a["inbox_threads"] = max(0, a.get("inbox_threads", 1) - 1)
    _patch_state(_m)


def _find_label(cfg, name):
    """The Gmail label id for a name, or None."""
    import draftutil as du  # noqa: E402
    labels = du._gws(cfg, ["gmail", "users", "labels", "list",
                           "--params", json.dumps({"userId": "me"})]).get("labels", [])
    lab = next((l for l in labels if l.get("name") == name), None)
    return lab["id"] if lab else None


def _patch_state(mutate):
    """Apply a surgical change to the cached state.json (under a lock) so a single
    dismiss/undo stays consistent without a full ~9s rebuild."""
    if not os.path.isfile(STATE_PATH):
        return
    with _state_lock:
        try:
            with open(STATE_PATH) as f:
                st = json.load(f)
        except Exception:
            return
        mutate(st)
        st["total_loops"] = sum(a.get("inbox_threads", 0)
                                for a in st.get("accounts", []) if a.get("ok", True))
        tmp = STATE_PATH + ".tmp"
        with open(tmp, "w") as f:
            json.dump(st, f, ensure_ascii=False, indent=2)
        os.replace(tmp, STATE_PATH)


def _bump_undo_point(slug, label, delta):
    """Reflect a per-loop set-aside (+1) or its undo (-1) in the cached undo points
    so the Undo tab's day count moves immediately, without a full rebuild. Matches
    dashboard_state's {label, date, count} shape and sort exactly. The thread carries
    the same dated recovery label as the daily run, so restoring that day brings these
    set-aside threads back too."""
    import re
    m = re.search(r"\d{4}-\d{2}-\d{2}", label or "")
    date = m.group(0) if m else "earlier"

    def _m(st):
        for a in st.get("accounts", []):
            if a.get("slug") != slug:
                continue
            pts = a.setdefault("undo_points", [])
            pt = next((p for p in pts if p.get("date") == date), None)
            if pt is None:
                if delta > 0:
                    pts.append({"label": label, "date": date, "count": delta})
            else:
                pt["count"] = max(0, pt.get("count", 0) + delta)
                if pt["count"] <= 0:
                    pts.remove(pt)
                elif label and label > pt.get("label", ""):
                    pt["label"] = label   # keep the most recent label as restore target
            pts.sort(key=lambda p: ("0" if p.get("date") == "earlier" else p.get("date", "")),
                     reverse=True)
    _patch_state(_m)


def _state_is_stale():
    """Return True if state.json is missing, unparseable, or reports any failure.

    Called on boot so a stale FAILED state (all accounts ok=False) is rebuilt
    rather than served indefinitely. Never throws.
    """
    try:
        if not os.path.isfile(STATE_PATH):
            return True
        with open(STATE_PATH) as f:
            data = json.load(f)
        accounts = data.get("accounts", [])
        # Fresh install with no accounts yet: the empty state is correct, not a
        # failure — don't force a blocking rebuild on every boot.
        if not accounts:
            return False
        # Top-level ok=False means the last build itself failed.
        if not data.get("ok", False):
            return True
        # Any account ok=False means at least one account is broken.
        if any(not a.get("ok", True) for a in accounts):
            return True
        return False
    except Exception:
        return True  # unparseable = stale


def _build_state_blocking():
    r = subprocess.run([PYTHON, os.path.join(HERE, "dashboard_state.py")],
                       env=_gws_env(), capture_output=True, text=True, timeout=180)
    if r.returncode != 0:
        raise RuntimeError(f"state rebuild failed (exit {r.returncode}): "
                           f"{(r.stderr or r.stdout or '')[-500:]}")


def _load_accounts():
    if not os.path.isfile(ACCOUNTS_PATH):
        return []
    with open(ACCOUNTS_PATH) as f:
        data = json.load(f)
    return data if isinstance(data, list) else data.get("accounts", [])


def _run_keeper(payload):
    """Run the open-loop sweep across all accounts at the daily grace, then rebuild."""
    # Grace = protect mail newer than N days. The user's persisted setting is the
    # source of truth (default 0 = review the whole inbox and trust the keep-bar);
    # a payload value overrides it. Everything is reversible via Undo.
    settings = _read_settings()
    grace = int(payload.get("grace_days", settings["grace_days"]))
    accts = _load_accounts()
    failures, set_aside, kept = [], 0, 0
    for i, acct in enumerate(accts, 1):
        # Per-account enable toggle (default: enabled). Lets the UI add a toggle later.
        if acct.get("enabled", True) is False:
            continue
        cfg = acct["config_dir"]
        email = acct.get("email", acct.get("slug", cfg))
        _set_job_message(f"Reviewing {email} ({i}/{len(accts)})…")
        r = subprocess.run([PYTHON, os.path.join(HERE, "review_open_loops.py"),
                            cfg, email, "--grace-days", str(grace), "--execute"],
                           env=_gws_env(), capture_output=True, text=True, timeout=600)
        if r.returncode != 0:
            failures.append(f"{email}: {(r.stderr or r.stdout or '').strip()[-200:]}")
        else:
            line = [l for l in r.stdout.splitlines() if l.strip().startswith("{")]
            if line:
                try:
                    d = json.loads(line[-1])
                    set_aside += d.get("to_archive_threads", 0) or 0
                    kept += d.get("to_keep_threads", 0) or 0
                except Exception:
                    pass
        _set_job_message(f"Set aside {set_aside} so far · {kept} still need you…")
    # Update what we've learned from recent actions (best-effort; gated on signals).
    subprocess.run([PYTHON, os.path.join(HERE, "learn.py")],
                   env=_gws_env(), capture_output=True, text=True, timeout=180)
    summary_msg = f"Set aside {set_aside}, {kept} still need you"
    _set_job_message(summary_msg)
    _build_state_blocking()
    # Hand the summary to the app, which posts a native notification (carries the
    # app icon, and tapping it opens the panel on Open loops). Gating lives in the writer.
    _queue_run_notification(set_aside, kept)
    if failures:
        raise RuntimeError("Some accounts failed: " + " | ".join(failures))


def _run_populate(payload):
    """Label-only backfill: sort the last N days of inbox mail into category labels.
    One account (slug) or all. Never archives — purely additive labeling.
    Also labels recently-archived mail if label_archived_days > 0."""
    settings = _read_settings()
    window = max(1, min(int(payload.get("window_days", 30)), 365))
    archive_days = int(payload.get("archive_days", settings.get("label_archived_days", 30)))
    archive_days = max(0, min(archive_days, 365))
    slug = payload.get("slug")
    accts = [_acct(slug)] if slug else _load_accounts()
    failures, labeled = [], 0
    for i, acct in enumerate(accts, 1):
        cfg = acct["config_dir"]
        email = acct.get("email", acct.get("slug", cfg))
        _set_job_message(f"Sorting {email} ({i}/{len(accts)})…")
        r = subprocess.run([PYTHON, os.path.join(HERE, "review_open_loops.py"),
                            cfg, email, "--label-only",
                            "--window-days", str(window),
                            "--archive-days", str(archive_days)],
                           env=_gws_env(), capture_output=True, text=True, timeout=900)
        if r.returncode != 0:
            failures.append(f"{email}: {(r.stderr or r.stdout or '').strip()[-200:]}")
            continue
        line = [l for l in r.stdout.splitlines() if l.strip().startswith("{")]
        if line:
            try:
                labeled += int(json.loads(line[-1]).get("labeled", 0) or 0)
            except Exception:
                pass
        _set_job_message(f"Labeled {labeled} so far…")
    _set_job_message(f"Labeled {labeled} recent thread{'' if labeled == 1 else 's'}")
    _build_state_blocking()
    # Partial success is success: report what got labeled and how many accounts
    # couldn't be reached, rather than discarding the whole run. Only a total
    # failure (nothing labeled) is a hard error.
    if failures and labeled == 0:
        raise RuntimeError(failures[0][:200])
    if failures:
        n = len(failures)
        _set_job_message(
            f"Labeled {labeled} recent thread{'' if labeled == 1 else 's'} · "
            f"{n} account{'' if n == 1 else 's'} couldn't be reached")


def _run_archive_before(payload):
    """Reversibly archive every inbox thread before a date (YYYY/MM/DD), except
    high-stakes mail. One account (slug) or all. Recovery label shows in Undo."""
    sys.path.insert(0, HERE)
    import inbox_zero as iz  # noqa: E402
    before = payload.get("before")
    slug = payload.get("slug")
    accts = [_acct(slug)] if slug else _load_accounts()
    failures, archived = [], 0
    for i, acct in enumerate(accts, 1):
        cfg = acct["config_dir"]
        email = acct.get("email", acct.get("slug", cfg))
        _set_job_message(f"Clearing {email} ({i}/{len(accts)})…")
        try:
            archived += int(iz.archive_before(cfg, before).get("archived", 0) or 0)
        except Exception as exc:
            failures.append(f"{email}: {exc}")
        _set_job_message(f"Archived {archived} so far…")
    _set_job_message(f"Archived {archived} older thread{'' if archived == 1 else 's'}")
    _build_state_blocking()
    # Partial success is success (see _run_populate): only a total failure raises.
    if failures and archived == 0:
        raise RuntimeError(failures[0][:200])
    if failures:
        n = len(failures)
        _set_job_message(
            f"Archived {archived} older thread{'' if archived == 1 else 's'} · "
            f"{n} account{'' if n == 1 else 's'} couldn't be reached")


def _run_undo(payload):
    """Restore one dated recovery label: move its threads back to the inbox."""
    sys.path.insert(0, HERE)
    import draftutil as du  # noqa: E402
    slug = payload.get("slug")
    label_name = payload.get("label")
    if not slug or not label_name:
        raise ValueError("undo requires slug and label")
    cfg = _acct(slug)["config_dir"]
    labels = du._gws(cfg, ["gmail", "users", "labels", "list",
                           "--params", json.dumps({"userId": "me"})]).get("labels", [])
    lab = next((l for l in labels if l.get("name") == label_name), None)
    if not lab:
        raise ValueError(f"recovery label not found: {label_name!r}")
    # Collect all message ids carrying the label, then add INBOX + remove the label.
    msg_ids, tok = [], None
    while True:
        params = {"userId": "me", "labelIds": [lab["id"]], "maxResults": 500}
        if tok:
            params["pageToken"] = tok
        d = du._gws(cfg, ["gmail", "users", "messages", "list",
                          "--params", json.dumps(params)])
        msg_ids += [m["id"] for m in d.get("messages", []) or []]
        tok = d.get("nextPageToken")
        if not tok:
            break
    for i in range(0, len(msg_ids), 1000):
        chunk = msg_ids[i:i + 1000]
        du._gws(cfg, ["gmail", "users", "messages", "batchModify",
                      "--params", json.dumps({"userId": "me"}),
                      "--json", json.dumps({"ids": chunk,
                                            "addLabelIds": ["INBOX"],
                                            "removeLabelIds": [lab["id"]]})],
                allow_empty=True)
    import learning  # noqa: E402
    # Bulk restore = a strong "keep more of this batch" signal.
    learning.record({"type": "keep_override_undo", "account": slug,
                     "label": label_name, "message_count": len(msg_ids)})
    _set_job_message(f"Restored {len(msg_ids)} messages. Refreshing...")
    _build_state_blocking()


def _display_from(raw):
    """'Jane Doe <jane@x.com>' -> 'Jane Doe'; bare address -> the address."""
    raw = (raw or "").strip()
    if "<" in raw:
        name = raw.split("<", 1)[0].strip().strip('"')
        return name or raw.split("<", 1)[1].rstrip(">").strip()
    return raw


def _undo_threads(payload):
    """List the actual emails under one recovery label (newest first, capped) with
    enough metadata for the Undo tab to show them. Metadata is fetched concurrently
    so a batch loads in a couple of seconds even at the cap."""
    sys.path.insert(0, HERE)
    import draftutil as du  # noqa: E402
    slug = payload.get("slug")
    label_name = payload.get("label")
    if not slug or not label_name:
        raise ValueError("need slug and label")
    limit = max(1, min(int(payload.get("limit", 40)), 100))
    cfg = _acct(slug)["config_dir"]
    lid = _find_label(cfg, label_name)
    if not lid:
        return {"threads": []}
    d = du._gws(cfg, ["gmail", "users", "messages", "list",
                      "--params", json.dumps({"userId": "me", "labelIds": [lid],
                                              "maxResults": limit})])
    ids = [m["id"] for m in d.get("messages", []) or []]

    def _meta(mid):
        try:
            m = du._gws(cfg, ["gmail", "users", "messages", "get",
                              "--params", json.dumps({"userId": "me", "id": mid, "format": "metadata",
                                                      "metadataHeaders": ["From", "Subject"]})])
            h = {x.get("name", "").lower(): x.get("value", "")
                 for x in m.get("payload", {}).get("headers", [])}
            return {"id": mid, "thread_id": m.get("threadId", mid),
                    "subject": (h.get("subject", "") or "(no subject)"),
                    "sender": _display_from(h.get("from", "")),
                    "epoch": int(m.get("internalDate", "0") or 0) // 1000}
        except Exception:
            return None

    with ThreadPoolExecutor(max_workers=8) as ex:
        threads = [r for r in ex.map(_meta, ids) if r]
    threads.sort(key=lambda t: t["epoch"], reverse=True)
    return {"threads": threads}


def _undo_thread(payload):
    """Restore a single message from a recovery label back to the inbox (per-email
    undo). Fast + synchronous so the panel can drop the row immediately."""
    sys.path.insert(0, HERE)
    import draftutil as du  # noqa: E402
    import learning  # noqa: E402
    slug = payload.get("slug")
    label_name = payload.get("label")
    mid = payload.get("id")
    if not (slug and label_name and mid):
        raise ValueError("need slug, label, id")
    cfg = _acct(slug)["config_dir"]
    lid = _find_label(cfg, label_name)
    tid = payload.get("thread_id", mid)
    du._gws(cfg, ["gmail", "users", "messages", "modify",
                  "--params", json.dumps({"userId": "me", "id": mid}),
                  "--json", json.dumps({"addLabelIds": ["INBOX"],
                                        "removeLabelIds": [lid] if lid else []})],
            allow_empty=True)
    learning.record({"type": "keep_override_undo", "account": slug, "thread_id": tid})

    # Bring the thread back into Open loops + the inbox count so it persists across
    # reloads (the app shows it instantly via its own optimistic re-add). The undo
    # bucket count is tracked optimistically app-side, so we don't bump it here —
    # bumping too would double-count it on the next reload.
    def _readd(st):
        for a in st.get("accounts", []):
            if a.get("slug") == slug and not any(
                    l.get("thread_id") == tid for l in a.get("loops", [])):
                a.setdefault("loops", []).insert(0, {
                    "thread_id": tid, "sender": payload.get("sender", ""),
                    "subject": payload.get("subject", ""),
                    "snippet": payload.get("snippet", ""),
                    "epoch": payload.get("epoch", 0), "account_slug": slug})
                a["inbox_threads"] = a.get("inbox_threads", 0) + 1
    _patch_state(_readd)
    return {"ok": True}


def _b64(data):
    """Decode a Gmail base64url body part to text (lenient on padding + encoding)."""
    import base64  # noqa: E402
    return base64.urlsafe_b64decode(data + "===").decode("utf-8", "replace")


def _strip_html(s):
    """Crude HTML -> readable text for previews (drop tags, unescape entities)."""
    import html as _html  # noqa: E402
    s = re.sub(r"(?is)<(script|style|head)\b.*?</\1>", " ", s)
    s = re.sub(r"(?i)<br\s*/?>", "\n", s)
    s = re.sub(r"(?i)</(p|div|tr|li|h[1-6])>", "\n", s)
    s = re.sub(r"(?s)<[^>]+>", " ", s)
    s = _html.unescape(s)
    s = re.sub(r"[ \t]+", " ", s)
    s = re.sub(r"\n[ \t]+", "\n", s)
    return re.sub(r"\n{3,}", "\n\n", s).strip()


def _extract_body(payload):
    """Walk a Gmail message payload, preferring text/plain, else stripped text/html."""
    found = {}

    def walk(part):
        mime = part.get("mimeType", "")
        data = part.get("body", {}).get("data")
        if data and mime in ("text/plain", "text/html"):
            found.setdefault(mime, _b64(data))   # first of each wins
        for p in part.get("parts") or []:
            walk(p)

    walk(payload)
    if found.get("text/plain"):
        return found["text/plain"].strip()
    if found.get("text/html"):
        return _strip_html(found["text/html"])
    return ""


def _thread_preview(payload):
    """Latest message in a thread as plain text — enough to read the gist without
    leaving the app. Not a full client: one message, body only, capped. Synchronous."""
    sys.path.insert(0, HERE)
    import draftutil as du  # noqa: E402
    slug = payload.get("slug")
    tid = payload.get("thread_id")
    if not (slug and tid):
        raise ValueError("need slug and thread_id")
    cfg = _acct(slug)["config_dir"]
    t = du._gws(cfg, ["gmail", "users", "threads", "get",
                      "--params", json.dumps({"userId": "me", "id": tid, "format": "full"})])
    msgs = t.get("messages", []) or []
    if not msgs:
        return {"body": "", "sender": "", "subject": ""}
    m = msgs[-1]   # newest message in the thread
    h = {x.get("name", "").lower(): x.get("value", "")
         for x in m.get("payload", {}).get("headers", [])}
    body = _extract_body(m.get("payload", {})).replace("\r\n", "\n").replace("\r", "\n")
    body = re.sub(r"\n{3,}", "\n\n", body)[:6000].strip()
    return {"body": body,
            "sender": _display_from(h.get("from", "")),
            "subject": h.get("subject", "") or "(no subject)"}


def _dismiss(payload):
    """Set one loop aside: archive its whole thread reversibly and record that the
    user chose to archive rather than reply (a learning signal). Fast + synchronous
    so the panel can remove the row immediately."""
    sys.path.insert(0, HERE)
    import draftutil as du       # noqa: E402
    import inbox_zero as iz      # noqa: E402
    import learning              # noqa: E402
    slug = payload.get("slug")
    tid = payload.get("thread_id")
    if not slug or not tid:
        raise ValueError("dismiss requires slug and thread_id")
    cfg = _acct(slug)["config_dir"]

    # Undo a just-dismissed thread: put it back in the inbox and net out the signal.
    if payload.get("undo"):
        # Use the exact label from the dismiss response; never recompute "today"
        # (an undo just after midnight would otherwise target the wrong label).
        label = payload.get("label")
        if not label:
            raise ValueError("undo requires the recovery label from the dismiss")
        lid = _find_label(cfg, label)
        remove = [lid] if lid else []
        du._gws(cfg, ["gmail", "users", "threads", "modify",
                      "--params", json.dumps({"userId": "me", "id": tid}),
                      "--json", json.dumps({"addLabelIds": ["INBOX"], "removeLabelIds": remove})],
                allow_empty=True)
        learning.record({"type": "keep_override_undo", "account": slug, "thread_id": tid,
                         "sender": payload.get("sender", ""),
                         "sender_email": payload.get("sender_email", ""),
                         "subject": payload.get("subject", "")})

        def _readd(st):
            for a in st.get("accounts", []):
                if a.get("slug") == slug and not any(
                        l.get("thread_id") == tid for l in a.get("loops", [])):
                    a.setdefault("loops", []).insert(0, {
                        "thread_id": tid, "sender": payload.get("sender", ""),
                        "sender_email": payload.get("sender_email", ""),
                        "subject": payload.get("subject", ""),
                        "snippet": payload.get("snippet", ""),
                        "epoch": payload.get("epoch", 0), "account_slug": slug})
                    a["inbox_threads"] = a.get("inbox_threads", 0) + 1
        _patch_state(_readd)
        _bump_undo_point(slug, label, -1)   # came back out of that day's bucket
        return {"ok": True, "restored": tid}

    label = iz._dated_label(iz._BASE_LABEL)
    lid = iz._ensure_label(cfg, label)
    du._gws(cfg, ["gmail", "users", "threads", "modify",
                  "--params", json.dumps({"userId": "me", "id": tid}),
                  "--json", json.dumps({"addLabelIds": [lid], "removeLabelIds": ["INBOX"]})],
            allow_empty=True)
    learning.record({"type": "keep_override", "action": "archived_without_reply",
                     "account": slug, "thread_id": tid,
                     "sender": payload.get("sender", ""),
                     "sender_email": payload.get("sender_email", ""),
                     "subject": payload.get("subject", ""),
                     "snippet": payload.get("snippet", "")})
    _drop_loop(slug, tid)
    _bump_undo_point(slug, label, +1)   # show it in today's Undo bucket right away
    return {"ok": True, "label": label, "thread_id": tid}


def _acct(slug):
    a = next((a for a in _load_accounts()
              if (a.get("slug") or a.get("email")) == slug), None)
    if not a:
        raise ValueError(f"unknown account {slug!r}")
    return a


# ---------------------------------------------------------------------------
# Label clean-up helpers
# ---------------------------------------------------------------------------

# Gmail system label ids that must never be deleted. The type=="system" check
# covers all current ones, but we also enumerate known ids defensively.
_GMAIL_SYSTEM_IDS = frozenset({
    "INBOX", "SENT", "TRASH", "SPAM", "DRAFT", "DRAFTS", "CHAT",
    "STARRED", "IMPORTANT", "UNREAD",
    "CATEGORY_PERSONAL", "CATEGORY_SOCIAL", "CATEGORY_PROMOTIONS",
    "CATEGORY_UPDATES", "CATEGORY_FORUMS",
})

# Human-friendly display names for Gmail's own labels (the API returns raw ids like
# CATEGORY_PROMOTIONS); matches what Gmail itself shows in its sidebar.
_SYS_LABEL_NAMES = {
    "INBOX": "Inbox", "SENT": "Sent", "TRASH": "Trash", "SPAM": "Spam",
    "DRAFT": "Drafts", "DRAFTS": "Drafts", "CHAT": "Chat",
    "STARRED": "Starred", "IMPORTANT": "Important", "UNREAD": "Unread",
    "CATEGORY_PERSONAL": "Personal", "CATEGORY_SOCIAL": "Social",
    "CATEGORY_PROMOTIONS": "Promotions", "CATEGORY_UPDATES": "Updates",
    "CATEGORY_FORUMS": "Forums",
}

# Legacy unified-taxonomy labels created by earlier zero versions
# (before per-user categories were introduced); kept so cleanup can still find them.
_LEGACY_LABELS = frozenset({
    "⚡ Action",
    "📬 FYI",
    "🔻 Low",
    "💰 Finance",
    "🤝 Clients",
    "📅 Meetings",
    "🔔 Services",
})


def _is_ours(name, category_label_names, label_history):
    """Return True if a label was created by zero."""
    import inbox_zero as iz  # noqa: E402
    if name.startswith(iz._BASE_LABEL):
        return True
    if name in category_label_names:
        return True
    if name in label_history:
        return True
    if name in _LEGACY_LABELS:
        return True
    return False


def _fetch_label_detail(cfg, label):
    """Fetch threadsTotal for a single user label. Returns (label, threads_int)."""
    import draftutil as du  # noqa: E402
    try:
        detail = du._gws(cfg, ["gmail", "users", "labels", "get",
                               "--params", json.dumps({"userId": "me", "id": label["id"]})])
        threads = int(detail.get("threadsTotal", 0) or 0)
    except Exception:
        threads = 0
    return label, threads


def _list_account_labels(slug):
    """Return {"labels": [...]} or {"labels": [], "error": "..."} for one account."""
    sys.path.insert(0, HERE)
    import draftutil as du            # noqa: E402
    import review_open_loops as rol   # noqa: E402

    try:
        cfg = _acct(slug)["config_dir"]
    except ValueError as exc:
        return {"labels": [], "error": str(exc)}

    try:
        data = du._gws(cfg, ["gmail", "users", "labels", "list",
                              "--params", json.dumps({"userId": "me"})])
    except Exception as exc:
        return {"labels": [], "error": str(exc)}

    # Build the "ours" detection set from current categories + persisted history.
    try:
        cats = rol._categories()
        category_label_names = {rol._category_label_name(c) for c in cats}
    except Exception:
        category_label_names = set()

    try:
        label_history = rol._load_label_history()
    except Exception:
        label_history = set()

    all_labels = data.get("labels") or []

    def _is_system(l):
        return l.get("type") == "system" or l.get("id") in _GMAIL_SYSTEM_IDS

    # Only user-created labels carry a thread count + can be deleted; fetch those
    # counts in parallel. System (Gmail's own) labels are listed for reference only.
    deletable = [l for l in all_labels if not _is_system(l)]
    system = [l for l in all_labels if _is_system(l)]

    results = []
    with ThreadPoolExecutor(max_workers=8) as ex:
        futs = {ex.submit(_fetch_label_detail, cfg, lab): lab for lab in deletable}
        for f in as_completed(futs):
            try:
                lab, threads = f.result()
                ours = _is_ours(lab.get("name", ""), category_label_names, label_history)
                results.append({
                    "id": lab["id"], "name": lab.get("name", ""),
                    "threads": threads, "ours": ours,
                    "kind": "zero" if ours else "user",
                })
            except Exception:
                pass
    for lab in system:
        results.append({"id": lab["id"],
                        "name": _SYS_LABEL_NAMES.get(lab["id"], lab.get("name", "")),
                        "threads": 0, "ours": False, "kind": "system"})

    # Group order: zero's labels first, then yours, then Gmail's own; name A→Z within.
    _order = {"zero": 0, "user": 1, "system": 2}
    results.sort(key=lambda r: (_order.get(r["kind"], 3), r["name"].lower()))
    return {"labels": results}


def _run_cleanup(payload):
    """Remove the selected user labels as a job, so its status flows through the
    same bottom-bar pipeline as every other operation and survives the panel
    closing. Partial success is success (see _run_populate)."""
    slug = payload.get("slug")
    ids = payload.get("ids") or []
    _set_job_message(f"Removing {len(ids)} label{'' if len(ids) == 1 else 's'}…")
    r = _delete_account_labels(slug, ids)
    deleted, failed = r.get("deleted", 0), r.get("failed", [])
    _build_state_blocking()
    if failed and deleted == 0:
        raise RuntimeError((failed[0].get("error") or "couldn't remove labels")[:200])
    if failed:
        _set_job_message(f"Removed {deleted} label{'' if deleted == 1 else 's'} · "
                         f"{len(failed)} couldn't be removed")
    else:
        _set_job_message(f"Removed {deleted} label{'' if deleted == 1 else 's'}")


def _delete_account_labels(slug, ids):
    """Delete user labels by id. Returns {ok, deleted, failed}."""
    sys.path.insert(0, HERE)
    import draftutil as du  # noqa: E402

    cfg = _acct(slug)["config_dir"]

    # Re-fetch the live label list to verify each id is user-type (never system).
    try:
        data = du._gws(cfg, ["gmail", "users", "labels", "list",
                              "--params", json.dumps({"userId": "me"})])
    except Exception as exc:
        raise RuntimeError(f"could not list labels: {exc}")

    id_to_label = {l["id"]: l for l in (data.get("labels") or [])}

    deleted = 0
    failed = []
    for lid in ids:
        lab = id_to_label.get(lid)
        if lab is None:
            failed.append({"id": lid, "error": "label not found on this account"})
            continue
        # Refuse system labels — belt + braces: check both type and known id set.
        if lab.get("type") == "system" or lid in _GMAIL_SYSTEM_IDS:
            failed.append({"id": lid, "error": "refusing to delete Gmail system label"})
            continue
        try:
            du._gws(cfg, ["gmail", "users", "labels", "delete",
                          "--params", json.dumps({"userId": "me", "id": lid})],
                    allow_empty=True)
            deleted += 1
        except Exception as exc:
            failed.append({"id": lid, "error": str(exc)})

    return {"ok": True, "deleted": deleted, "failed": failed}


def _name_from_email(email):
    """Best-effort display name from an address local-part (e.g. jane.doe -> Jane Doe)."""
    import re
    local = (email or "").split("@")[0]
    parts = [re.sub(r"\d+$", "", p) for p in re.split(r"[._-]+", local)]
    return " ".join(p.capitalize() for p in parts if p)


def _gen_draft(payload):
    """Draft a reply to a thread in the user's voice. The user already chose to
    reply (they tapped Reply), so there's no needs-reply gate here."""
    sys.path.insert(0, HERE)
    import draftutil as du       # noqa: E402
    import learning              # noqa: E402
    import voicesampler as vs    # noqa: E402  — voice exemplar fetcher / cache
    from email.utils import parseaddr
    slug, tid = payload.get("slug"), payload.get("thread_id")
    steer = (payload.get("steer") or "").strip()
    if not slug or not tid:
        raise ValueError("draft requires slug and thread_id")
    acct = _acct(slug)
    cfg = acct["config_dir"]
    settings = _read_settings()
    # A user-set drafting name overrides the per-account derived name (blank = derive).
    owner_name = ((settings.get("draft_name") or "").strip()
                  or acct.get("name") or _name_from_email(acct.get("email", ""))).strip()
    owner_first = owner_name.split()[0] if owner_name else ""
    draft_guidance = (settings.get("draft_guidance") or "").strip()
    t = du._gws(cfg, ["gmail", "users", "threads", "get",
                      "--params", json.dumps({"userId": "me", "id": tid, "format": "metadata",
                                              "metadataHeaders": ["From", "Subject", "Date"]})])
    msgs = t.get("messages", []) or []
    if not msgs:
        raise ValueError("thread has no messages")
    try:
        owner = (du._profile_email(cfg) or "").lower()
    except Exception:
        owner = ""
    convo = []
    subject = "(no subject)"
    last_from = ""
    recipient_from = ""   # newest message NOT from the account owner
    for m in msgs:
        h = {x["name"].lower(): x["value"] for x in m.get("payload", {}).get("headers", [])}
        frm = h.get("from", "")
        last_from = frm or last_from
        subject = h.get("subject", subject)
        convo.append(f"From {frm or '?'}: {m.get('snippet','')}")
        if frm and parseaddr(frm)[1].lower() != owner:
            recipient_from = frm  # ends as the newest external sender
    chosen = recipient_from or last_from  # whole thread from owner -> reply to last
    to_name = parseaddr(chosen)[0] or parseaddr(chosen)[1] or chosen
    to_email = parseaddr(chosen)[1] or ""

    # --- Voice exemplars: owner's own sent messages as concrete style samples ----
    # Cached on disk per account (TTL 7 days) to keep per-draft latency low.
    general_exemplars = []
    try:
        general_exemplars = vs.get_voice_exemplars(cfg, slug)
    except Exception:
        pass  # non-fatal; draft continues without exemplars

    # --- Per-recipient exemplars + relationship tier ----------------------------
    # Run live (small result set, recipient-specific — not worth caching).
    rel_tier = "new"          # "new" | "known"
    recip_exemplars = []
    if to_email:
        try:
            rel_tier, recip_exemplars = vs.get_recipient_exemplars(
                cfg, to_email, owner, tid)
        except Exception:
            pass  # non-fatal

    # Build voice-exemplar block: recipient-specific samples take priority;
    # pad with general sent-mail samples up to ~6 total.
    all_exemplars = recip_exemplars + [
        e["body"] for e in general_exemplars
        if e["body"] not in recip_exemplars
    ]
    all_exemplars = all_exemplars[:6]

    exemplar_block = ""
    if all_exemplars:
        owner_label = owner_name or "the owner"
        samples_text = "\n\n---\n".join(all_exemplars)
        exemplar_block = (
            f"\nHERE IS HOW {owner_label.upper()} ACTUALLY WRITES"
            + (" (especially to this recipient)" if recip_exemplars else "")
            + " — imitate this style, not a generic professional tone:\n"
            + samples_text + "\n"
        )

    # Relationship tier influences formality instruction.
    if rel_tier == "known":
        tier_note = f" You have exchanged emails with {to_name} before — match the warmth and familiarity of those prior exchanges."
    else:
        tier_note = f" {to_name} appears to be a new or infrequent contact — be friendly but appropriately professional."

    # Voice notes from past user edits (rollup from learning/learned.md).
    voice = learning.learned_text()
    voice_block = f"\nVOICE NOTES learned from past edits:\n{voice}\n" if voice.strip() else ""

    # Optional profile context: knowledge/<slug>.md, then knowledge/profile.md.
    prof_block = ""
    for fn in (f"{slug}.md", "profile.md"):
        p = os.path.join(ROOT, "knowledge", fn)
        if os.path.exists(p):
            try:
                txt = open(p).read().strip()
            except Exception:
                txt = ""
            if txt:
                prof_block = "\nABOUT THE USER (background for voice/context, do not quote verbatim):\n" + txt[:1500] + "\n"
            break

    voice_desc = f"{owner_name}'s voice" if owner_name else "the user's voice"
    sign = f' Sign off as "{owner_first}".' if owner_first else ""
    # User's own house style takes priority over inferred tone.
    guidance_block = (f"\nHOUSE STYLE (the user's own preferences — follow these "
                      f"over any inferred tone):\n{draft_guidance}\n") if draft_guidance else ""

    prompt = (
        f"Draft a reply in {voice_desc} to the email thread below.\n"
        "Rules:\n"
        "- First person, concise (2–6 sentences unless the thread clearly calls for more)\n"
        "- Match the sender's language and level of formality\n"
        "- Reference real thread context; never invent facts, figures or dates "
        "(use placeholders like [day] / [amount] if needed)\n"
        "- " + (sign[1:].strip() if sign else "Sign off with the owner's first name.") + "\n"
        "- Infer what kind of email this is (scheduling, client update, cold reply, "
        "logistics, question/decision, thanks, intro, etc.) and write the way the "
        "owner typically handles that kind — see the exemplars below for cues\n"
        f"- Reply is addressed to: {to_name}.{tier_note}\n"
        f"{guidance_block}{prof_block}{exemplar_block}{voice_block}"
        + (f"\nADJUSTMENT requested: {steer}\n" if steer else "")
        + f"\nSubject: {subject}\nThread (oldest to newest):\n" + "\n".join(convo[-8:])
        + "\n\nOutput ONLY the reply body text, no preamble, no subject line."
    )
    sys.path.insert(0, HERE)
    import llm as _llm  # noqa: E402
    body_raw, ok = _llm.run_prompt(prompt, model="haiku", timeout=120)
    if not ok:
        raise RuntimeError("drafting timed out or failed")
    body = body_raw.strip()
    if not body:
        raise RuntimeError("the draft came back empty; try Regenerate")
    if not to_email:
        raise RuntimeError("couldn't determine who to reply to")
    return {"ok": True, "to_name": to_name, "to_email": to_email,
            "subject": subject, "body": body}


def _send_draft(payload):
    """Create + send a reply on the thread; capture an edit signal if the user
    changed the generated text."""
    sys.path.insert(0, HERE)
    import draftutil as du       # noqa: E402
    import learning              # noqa: E402
    slug = payload.get("slug")
    tid = payload.get("thread_id")
    to = payload.get("to_email") or payload.get("to") or ""
    subject = payload.get("subject") or ""
    final = payload.get("body") or ""          # plain-text part (and the fallback)
    html = payload.get("html") or ""           # rich formatting, optional
    original = payload.get("original") or ""
    if not (slug and tid and to and final.strip()):
        raise ValueError("send requires slug, thread_id, to, and body")
    cfg = _acct(slug)["config_dir"]
    raw = du._build_raw(cfg, tid, to, subject, final, html=html)
    d = du._gws(cfg, ["gmail", "users", "drafts", "create",
                      "--params", json.dumps({"userId": "me"}),
                      "--json", json.dumps({"message": {"raw": raw, "threadId": tid}})])
    try:
        du._gws(cfg, ["gmail", "users", "drafts", "send",
                      "--params", json.dumps({"userId": "me"}),
                      "--json", json.dumps({"id": d["id"]})])
    except Exception as exc:
        # The draft was created but didn't send; remove it so a retry can't
        # double-send or leave an orphan, and tell the user plainly.
        try:
            du._gws(cfg, ["gmail", "users", "drafts", "delete",
                          "--params", json.dumps({"userId": "me", "id": d["id"]})],
                    allow_empty=True)
        except Exception:
            pass
        raise RuntimeError(f"couldn't send the reply ({exc}); nothing was sent")
    if original and original.strip() != final.strip():
        learning.record({"type": "draft_edit", "thread_id": tid,
                         "original_snippet": original[:200], "final": final[:400]})
        # Trigger voice-learning rollup best-effort, off the request thread so the send
        # returns immediately. A daemon thread running subprocess.run() reaps the child
        # itself (the long-lived server installs no SIGCHLD handler, so a bare Popen would
        # leak a zombie per send); the thread is fire-and-forget and never blocks the send.
        def _learn_bg():
            try:
                subprocess.run([PYTHON, os.path.join(HERE, "learn.py")],
                               env=_gws_env(), stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL, timeout=180)
            except Exception:
                pass
        threading.Thread(target=_learn_bg, daemon=True).start()
    _drop_loop(slug, tid)  # replying resolves the loop
    return {"ok": True, "sent": tid}


def _kill_stray_auth():
    """Best-effort: kill any gws auth login processes left from a previous attempt.
    Uses 'pgrep -f' which is available on macOS. Defensive — never raises."""
    try:
        r = subprocess.run(["pgrep", "-f", "auth.login"],
                           capture_output=True, text=True, timeout=5)
        for pid_s in r.stdout.split():
            try:
                os.kill(int(pid_s), signal.SIGKILL)
            except Exception:
                pass
    except Exception:
        pass


def _cancel_auth():
    """Set the cancel flag and kill the auth process group if one is running.
    Safe to call even when no auth is in progress."""
    global _cancel_requested, _auth_proc, _auth_pgid
    with _auth_lock:
        _cancel_requested = True
        pgid = _auth_pgid
        proc = _auth_proc
    if pgid is not None:
        try:
            os.killpg(pgid, signal.SIGKILL)
        except Exception:
            pass
    if proc is not None:
        try:
            proc.kill()
        except Exception:
            pass


def _add_account(payload):
    """Authenticate a new Gmail account via gws (opens the user's browser) and add
    it to accounts.json. The OAuth consent happens in the browser; we never see
    credentials."""
    import time as _time
    import shutil
    import glob as _glob
    home = os.path.expanduser("~")
    gws_root = os.path.join(home, ".config", "gws")
    pending = os.path.join(gws_root, "accounts", f"pending-{int(_time.time())}")
    os.makedirs(pending, exist_ok=True)
    committed = False
    created_dir = None
    # Reuse the OAuth client the existing accounts already use, so adding another
    # account doesn't make the user create a brand-new Google Cloud client. We copy
    # only the client app credentials (client_secret.json), never any user tokens.
    # A first-ever account has none to copy and falls through to the setup guidance.
    def _existing_client_secret():
        prefer = os.path.join(gws_root, "client_secret.json")
        if os.path.isfile(prefer):
            return prefer
        for hit in _glob.glob(os.path.join(gws_root, "**", "client_secret.json"), recursive=True):
            if os.path.commonpath([hit, pending]) != pending:   # not the (empty) new dir
                return hit
        return None
    try:
        global _cancel_requested, _auth_proc, _auth_pgid
        # Kill any leftover gws auth login from a prior attempt so it can't interfere.
        _kill_stray_auth()

        _seed = _existing_client_secret()
        if _seed:
            shutil.copyfile(_seed, os.path.join(pending, "client_secret.json"))
        env = _gws_env()
        env["GOOGLE_WORKSPACE_CLI_CONFIG_DIR"] = pending

        # Reset cancel flag before launch.
        with _auth_lock:
            _cancel_requested = False

        _set_job_message("Starting sign-in…")
        # Launch in its own session (start_new_session=True) so we can killpg() the
        # entire process group — the gws grandchild included — on timeout or cancel.
        # stderr is merged into stdout so the consent URL + any error share one stream.
        p = subprocess.Popen(["gws", "auth", "login"], env=env,
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                             text=True, bufsize=1, start_new_session=True)
        pgid = os.getpgid(p.pid)
        with _auth_lock:
            _auth_proc = p
            _auth_pgid = pgid

        # gws has no TTY here, so instead of opening a browser it PRINTS the Google
        # consent URL and waits for the localhost redirect. Read its output in a
        # thread: when the URL appears, open it for the user (so the browser launches
        # automatically) and publish it on the job as a fallback link they can click.
        _out_buf = []
        _opened = threading.Event()
        def _pump():
            try:
                for line in p.stdout:
                    _out_buf.append(line)
                    if not _opened.is_set() and "accounts.google.com" in line and "http" in line:
                        url = line[line.find("http"):].strip()
                        _opened.set()
                        _set_job_auth_url(url)
                        _set_job_message("Opening your browser to sign in…")
                        try:
                            subprocess.run(["open", url], timeout=10)
                        except Exception:
                            pass
            except Exception:
                pass
        _reader = threading.Thread(target=_pump, daemon=True)
        _reader.start()

        _AUTH_TIMEOUT = 180  # seconds
        deadline = _time.time() + _AUTH_TIMEOUT
        told_waiting = False
        while True:
            rc = p.poll()
            if rc is not None:
                break
            with _auth_lock:
                cancelled = _cancel_requested
            if cancelled:
                try:
                    os.killpg(pgid, signal.SIGKILL)
                except Exception:
                    pass
                raise RuntimeError("Sign-in cancelled.")
            # Once the browser URL is out, nudge the status to "waiting on you".
            if _opened.is_set() and not told_waiting and _time.time() - (deadline - _AUTH_TIMEOUT) > 4:
                _set_job_message("Waiting for you to finish signing in…")
                told_waiting = True
            if _time.time() >= deadline:
                try:
                    os.killpg(pgid, signal.SIGKILL)
                except Exception:
                    pass
                raise RuntimeError(
                    "Sign-in timed out. The browser sign-in was not completed — "
                    "try Add account again.")
            _time.sleep(0.5)

        _reader.join(timeout=2)
        stdout_out = "".join(_out_buf)
        stderr_out = ""
        rc = p.returncode

        if rc != 0:
            stderr_text = (stderr_out or stdout_out or "").strip()
            # Only show the long OAuth-setup wall of text when credentials are genuinely
            # absent. If client_secret exists (or env vars set it), give a short message.
            cred_status = _credentials_status()
            _cred_hints = ("client_id", "client_secret", "GOOGLE_WORKSPACE_CLI_CLIENT",
                           "client_secret.json", "Cloud Console")
            missing_creds = (not cred_status["has_client"]
                             and (any(h.lower() in stderr_text.lower() for h in _cred_hints)
                                  or not stderr_text))
            if missing_creds:
                gws_cfg_dir = os.path.join(os.path.expanduser("~"), ".config", "gws")
                client_secret_path = os.path.join(gws_cfg_dir, "client_secret.json")
                raise RuntimeError(
                    "gws needs Google OAuth client credentials before it can sign you in. "
                    "To fix this, do ONE of the following:\n\n"
                    "Option A — client_secret.json (recommended):\n"
                    "  1. Open https://console.cloud.google.com/ and select your project "
                    "(or create one).\n"
                    "  2. Go to APIs & Services → Credentials → Create Credentials → "
                    "OAuth client ID.\n"
                    "  3. Choose 'Desktop app', name it anything, click Create.\n"
                    "  4. Download the JSON file and save it to:\n"
                    f"       {client_secret_path}\n"
                    "  5. Make sure the Gmail API is enabled for your project "
                    "(APIs & Services → Enable APIs → search 'Gmail API').\n"
                    "  6. Click 'Add account' again.\n\n"
                    "Option B — environment variables:\n"
                    "  Set GOOGLE_WORKSPACE_CLI_CLIENT_ID and "
                    "GOOGLE_WORKSPACE_CLI_CLIENT_SECRET in your environment, "
                    "then restart the app and try again."
                )
            # Credentials present but sign-in didn't complete — short message.
            tail = (" (" + stderr_text[-200:] + ")") if stderr_text else ""
            raise RuntimeError(
                "Sign-in didn't complete. Make sure you finished signing in in your "
                "browser, then try Add account again." + tail)

        prof = subprocess.run(["gws", "gmail", "users", "getProfile", "--params",
                               json.dumps({"userId": "me"})], env=env,
                              capture_output=True, text=True, timeout=60)
        email = ""
        for line in prof.stdout.splitlines():
            line = line.strip()
            if line.startswith("{") and "keyring" not in line:
                try:
                    email = json.loads(line).get("emailAddress", "")
                except Exception:
                    pass
        if not email:
            raise RuntimeError("signed in but couldn't read the account email")
        accts = _load_accounts()
        if any(a.get("email") == email for a in accts):
            raise RuntimeError(f"{email} is already added")
        # Derive a slug that is unique across existing accounts (two emails can
        # share a local-part), and use the SAME slug for the dir and the entry.
        base = email.split("@")[0].replace(".", "-").lower() or "account"
        existing = {a.get("slug") for a in accts}
        slug, n = base, 2
        while slug in existing:
            slug, n = f"{base}-{n}", n + 1
        final_dir = os.path.join(home, ".config", "gws", "accounts", slug)
        if os.path.exists(final_dir):
            use_dir = pending  # nice name taken; keep the pending dir as config
        else:
            os.rename(pending, final_dir)
            created_dir, use_dir = final_dir, final_dir
        accts.append({"slug": slug, "email": email, "config_dir": use_dir})
        tmp = ACCOUNTS_PATH + ".tmp"
        with open(tmp, "w") as f:
            json.dump(accts, f, indent=2)
        os.replace(tmp, ACCOUNTS_PATH)
        committed = True
        _set_job_message("Adding account...")
        _build_state_blocking()
    finally:
        # Always clear auth-proc tracking so cancel state is clean for next attempt.
        with _auth_lock:
            _auth_proc = None
            _auth_pgid = None
            _cancel_requested = False
        if not committed:
            shutil.rmtree(pending, ignore_errors=True)
            if created_dir:
                shutil.rmtree(created_dir, ignore_errors=True)


def _credentials_status():
    """Whether a Google OAuth client is already configured and whether any account
    is connected — lets onboarding skip the credential step when it isn't needed."""
    gws_root = os.path.join(os.path.expanduser("~"), ".config", "gws")
    has_client = os.path.isfile(os.path.join(gws_root, "client_secret.json"))
    if not has_client:  # gws also accepts the client from env vars instead of the file
        has_client = bool(os.environ.get("GOOGLE_WORKSPACE_CLI_CLIENT_ID")
                          and os.environ.get("GOOGLE_WORKSPACE_CLI_CLIENT_SECRET"))
    return {"has_client": has_client, "has_accounts": bool(_load_accounts())}


def _set_client_credentials(payload):
    """Write the user's Google OAuth *client* credentials to
    ~/.config/gws/client_secret.json so gws can run the browser sign-in without the
    user hand-placing a file. Accepts either the pasted Google JSON ({"json": "..."})
    or raw {client_id, client_secret}. This is the OAuth *app* identity (not truly
    secret for a Desktop client, and never a user password) — gws still does the
    consent in the browser."""
    gws_root = os.path.join(os.path.expanduser("~"), ".config", "gws")
    os.makedirs(gws_root, exist_ok=True)
    dst = os.path.join(gws_root, "client_secret.json")

    raw = payload.get("json")
    if isinstance(raw, str) and raw.strip():
        try:
            data = json.loads(raw)
        except Exception:
            raise RuntimeError("That doesn't look like valid JSON. Paste the whole "
                               "client_secret file you downloaded from Google.")
        inner = data.get("installed") or data.get("web") or {}
        cid = str(inner.get("client_id", "")).strip()
        csec = str(inner.get("client_secret", "")).strip()
        if not cid or not csec:
            raise RuntimeError("That JSON is missing client_id / client_secret — make "
                               "sure it's the OAuth client file for a Desktop app.")
        out = data  # preserve auth_uri/token_uri/redirect_uris exactly as Google gave them
    else:
        cid = str(payload.get("client_id", "")).strip()
        csec = str(payload.get("client_secret", "")).strip()
        if not cid or not csec:
            raise RuntimeError("Both Client ID and Client Secret are required.")
        out = {"installed": {
            "client_id": cid,
            "client_secret": csec,
            "auth_uri": "https://accounts.google.com/o/oauth2/auth",
            "token_uri": "https://oauth2.googleapis.com/token",
            "auth_provider_x509_cert_url": "https://www.googleapis.com/oauth2/v1/certs",
            "redirect_uris": ["http://localhost"],
        }}

    if ".apps.googleusercontent.com" not in cid:
        raise RuntimeError("That Client ID doesn't look right — it should end with "
                           "'.apps.googleusercontent.com'. Double-check the paste.")

    tmp = dst + ".tmp"
    # Create 0600 from the start — the file holds the OAuth client secret and must
    # never exist at the default umask (0644), even briefly.
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(out, f, indent=2)
    os.replace(tmp, dst)
    return {"ok": True, "path": dst}


sys.path.insert(0, HERE)
from dashboard_state import _DEFAULT_CATEGORIES, _DEFAULT_POLICY  # noqa: E402


def _read_categories():
    """Return categories list from categories.json, or defaults if file is missing."""
    try:
        if os.path.isfile(CATEGORIES_PATH):
            with open(CATEGORIES_PATH) as f:
                data = json.load(f)
            cats = data.get("categories", [])
            if cats:
                return cats
    except Exception:
        pass
    return _DEFAULT_CATEGORIES


_DEFAULT_SETTINGS = {
    "grace_days": 0,
    # Schedule
    "schedule_hour": 7,        # 0-23
    "schedule_minute": 0,      # 0-59
    "schedule_days": [1, 2, 3, 4, 5],  # 0=Sun .. 6=Sat; Mon-Fri by default
    # Notifications & automation
    "notify_on_run": True,
    "auto_draft": False,
    # Labeling window for archived (non-inbox) mail; 0 = off.
    "label_archived_days": 30,
    # LLM provider (see lib/llm.py)
    "provider": "claude",
    # Drafting preferences (used by the reply drafter, _gen_draft)
    "draft_name": "",        # how to sign drafts; blank = derive from the account
    "draft_guidance": "",    # free-form house style fed into every draft prompt
}


_LAUNCHD_LABEL = "com.drewl.zero.daily"
_PLIST_PATH = os.path.expanduser(f"~/Library/LaunchAgents/{_LAUNCHD_LABEL}.plist")


def _rewrite_schedule_plist(settings):
    """Rewrite ~/Library/LaunchAgents/com.drewl.zero.daily.plist from settings.

    Only called when the plist already exists (we don't auto-install a schedule
    the user never set up). Reloads via launchctl; errors are swallowed (non-fatal).
    """
    if not os.path.isfile(_PLIST_PATH):
        return
    hour = int(settings.get("schedule_hour", 7))
    minute = int(settings.get("schedule_minute", 0))
    days = settings.get("schedule_days", [1, 2, 3, 4, 5])
    # Build <array> of <dict> entries for StartCalendarInterval (one per weekday).
    # LaunchAgent weekday: 0=Sun..6=Sat (same as our settings convention).
    if days:
        interval_entries = "\n".join(
            f"    <dict>"
            f"<key>Weekday</key><integer>{d}</integer>"
            f"<key>Hour</key><integer>{hour}</integer>"
            f"<key>Minute</key><integer>{minute}</integer>"
            f"</dict>"
            for d in days
        )
        start_interval = f"  <key>StartCalendarInterval</key>\n  <array>\n{interval_entries}\n  </array>"
    else:
        # No days selected → daily at the specified time (omit Weekday).
        start_interval = (
            f"  <key>StartCalendarInterval</key>\n"
            f"  <dict><key>Hour</key><integer>{hour}</integer>"
            f"<key>Minute</key><integer>{minute}</integer></dict>"
        )

    # Find the zero binary from this script's own location.
    zero_bin = os.path.join(ROOT, "bin", "zero")
    plist_xml = f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>{_LAUNCHD_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>{zero_bin}</string>
    <string>run</string>
  </array>
{start_interval}
  <key>EnvironmentVariables</key>
  <dict><key>GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND</key><string>file</string></dict>
  <key>StandardOutPath</key><string>{os.path.join(ROOT, 'logs', 'daily.out.log')}</string>
  <key>StandardErrorPath</key><string>{os.path.join(ROOT, 'logs', 'daily.err.log')}</string>
</dict>
</plist>
"""
    try:
        tmp = _PLIST_PATH + ".tmp"
        with open(tmp, "w") as f:
            f.write(plist_xml)
        os.replace(tmp, _PLIST_PATH)
        subprocess.run(["launchctl", "unload", _PLIST_PATH],
                       capture_output=True, timeout=10)
        subprocess.run(["launchctl", "load", "-w", _PLIST_PATH],
                       capture_output=True, timeout=10)
    except Exception:
        pass  # plist reload failure is non-fatal


def _read_settings():
    """User timing settings. Defaults if file is missing/unreadable."""
    s = dict(_DEFAULT_SETTINGS)
    try:
        if os.path.isfile(SETTINGS_PATH):
            with open(SETTINGS_PATH) as f:
                s.update({k: v for k, v in json.load(f).items() if k in _DEFAULT_SETTINGS})
    except Exception:
        pass
    return s


def _queue_run_notification(set_aside, kept):
    """Drop a one-shot 'run complete' notification for the app to post natively.
    Gated by notify_on_run (default True), so the gate lives in exactly one place."""
    try:
        if not _read_settings().get("notify_on_run", True):
            return
        body = f"Set aside {set_aside}, {kept} still need you"
        os.makedirs(os.path.dirname(PENDING_NOTIFICATION_PATH), exist_ok=True)
        with _notif_lock:
            with open(PENDING_NOTIFICATION_PATH, "w") as f:
                json.dump({"title": "zero", "body": body, "ts": int(time.time())}, f)
    except Exception:
        pass


def _pop_pending_notification():
    """Atomically read-and-delete the pending notification, if any. Returns the
    dict or None. Under a lock so a timer-drain and a job-drain can't double-post."""
    with _notif_lock:
        try:
            with open(PENDING_NOTIFICATION_PATH) as f:
                data = json.load(f)
        except FileNotFoundError:
            return None
        except Exception:
            data = None
        try:
            os.remove(PENDING_NOTIFICATION_PATH)
        except Exception:
            pass
        return data


def _write_settings(settings):
    """Persist the whitelisted settings keys. Merges over the current file so a
    partial PUT (e.g. only grace_days) doesn't reset other keys to defaults."""
    s = _read_settings()   # start from current persisted values (already merged with defaults)
    s.update({k: v for k, v in (settings or {}).items() if k in _DEFAULT_SETTINGS})
    os.makedirs(os.path.dirname(SETTINGS_PATH), exist_ok=True)
    tmp = SETTINGS_PATH + ".tmp"
    with open(tmp, "w") as f:
        json.dump(s, f, indent=2)
    os.replace(tmp, SETTINGS_PATH)
    return s


_JOB_KINDS = {"refresh": lambda p: _build_state_blocking(),
              "run": _run_keeper, "undo": _run_undo, "add_account": _add_account,
              "populate": _run_populate, "archive_before": _run_archive_before,
              "cleanup": _run_cleanup}


def _set_job_message(msg):
    with _job_lock:
        _job["message"] = msg


def _set_job_auth_url(url):
    with _job_lock:
        _job["auth_url"] = url


def _start_job(kind, payload):
    with _job_lock:
        if _job["state"] == "running":
            return None
        _job.update(id=_job["id"] + 1, kind=kind, state="running",
                    started=int(time.time()), finished=0, message="Starting...",
                    error=None, auth_url=None)
        jid = _job["id"]

    def worker():
        try:
            _JOB_KINDS[kind](payload or {})
            with _job_lock:
                # Keep the last informative message (e.g. "Set aside 26, 30 still
                # need you") so the panel can show a real summary, not just "Done".
                _job.update(state="done", finished=int(time.time()))
        except Exception as exc:
            with _job_lock:
                _job.update(state="error", finished=int(time.time()),
                            error=str(exc), message="Failed")

    threading.Thread(target=worker, daemon=True).start()
    return jid


class Handler(BaseHTTPRequestHandler):
    server_version = "zero/1.0"

    def log_message(self, *args):
        pass  # quiet

    def _send(self, code, body, ctype="application/json"):
        if isinstance(body, (dict, list)):
            body = json.dumps(body, ensure_ascii=False).encode("utf-8")
        elif isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _is_local_request(self):
        # Block cross-site POST/PUT (a web page firing fetch at our localhost API).
        # The panel itself is same-origin; curl / the app webview send no Origin.
        sfs = self.headers.get("Sec-Fetch-Site")
        if sfs is not None:
            return sfs in ("same-origin", "none")
        origin = self.headers.get("Origin")
        if origin:
            port = self.server.server_address[1]
            return origin in (f"http://127.0.0.1:{port}", f"http://localhost:{port}")
        return True

    def _body_json(self):
        length = int(self.headers.get("Content-Length", 0) or 0)
        if not length:
            return {}
        try:
            return json.loads(self.rfile.read(length).decode("utf-8"))
        except Exception:
            return {}

    def do_GET(self):
        parsed = urlparse(self.path)
        p = parsed.path
        if p == "/api/labels":
            qs = parse_qs(parsed.query)
            slug = (qs.get("slug") or [None])[0]
            if not slug:
                return self._send(400, {"error": "slug is required"})
            try:
                return self._send(200, _list_account_labels(slug))
            except Exception as exc:
                return self._send(500, {"error": str(exc)})
        if p == "/api/state":
            with _boot_lock:
                building = _building
            if os.path.isfile(STATE_PATH):
                # Inject "building" into the cached state so the app knows a rebuild
                # is in progress without re-reading the full state file into Python.
                with open(STATE_PATH, "rb") as f:
                    raw = f.read()
                if building:
                    try:
                        st = json.loads(raw)
                        st["building"] = True
                        return self._send(200, st)
                    except Exception:
                        pass  # malformed state.json; fall through to raw bytes
                return self._send(200, raw, "application/json")
            # No state.json yet: return the needs_build sentinel + building flag.
            return self._send(200, {"ok": False, "accounts": [], "total_loops": 0,
                                    "needs_build": True, "building": building})
        if p == "/api/job":
            with _job_lock:
                return self._send(200, dict(_job))
        if p == "/api/policy":
            try:
                text = open(POLICY_PATH).read() if os.path.isfile(POLICY_PATH) else ""
            except Exception:
                text = ""
            return self._send(200, {"policy": text if text.strip() else _DEFAULT_POLICY})
        if p == "/api/categories":
            return self._send(200, {"categories": _read_categories()})
        if p == "/api/settings":
            return self._send(200, _read_settings())
        if p == "/api/credentials-status":
            return self._send(200, _credentials_status())
        if p == "/api/provider-status":
            sys.path.insert(0, HERE)
            import llm as _llm  # noqa: E402
            providers = _llm.detect_providers()
            active = next((pr["name"] for pr in providers if pr["active"]), "claude")
            return self._send(200, {"providers": providers, "active": active})
        if p == "/api/pending-notification":
            return self._send(200, {"notification": _pop_pending_notification()})
        return self._send(404, {"error": "not found"})

    def do_POST(self):
        if not self._is_local_request():
            return self._send(403, {"error": "cross-site request blocked"})
        p = urlparse(self.path).path
        payload = self._body_json()

        if p == "/api/job/cancel":
            # Idempotent: always returns ok. Sets the cancel flag and kills any live
            # auth process group so _add_account() unblocks without waiting for TIMEOUT.
            _cancel_auth()
            return self._send(200, {"ok": True})

        # Reject a learned preference: remove from learned.md + add to reject store.
        if p == "/api/learned/reject":
            text = payload.get("text", "").strip()
            if not text:
                return self._send(400, {"error": "text is required"})
            try:
                sys.path.insert(0, HERE)
                import learning  # noqa: E402
                learning.reject_learning(text)
            except Exception as exc:
                return self._send(500, {"error": str(exc)})
            return self._send(200, {"ok": True})

        if p == "/api/labels/delete":
            slug = payload.get("slug")
            ids = payload.get("ids")
            if not slug:
                return self._send(400, {"error": "slug is required"})
            if not isinstance(ids, list) or not ids:
                return self._send(400, {"error": "ids must be a non-empty list"})
            if not all(isinstance(i, str) for i in ids):
                return self._send(400, {"error": "ids must be a list of strings"})
            try:
                _acct(slug)  # validate slug maps to a known account
            except ValueError as exc:
                return self._send(400, {"error": str(exc)})
            # Runs through the shared job slot so its status shows in the bottom bar
            # and survives the panel closing, like every other operation.
            jid = _start_job("cleanup", payload)
            if jid is None:
                return self._send(409, {"error": "a job is already running"})
            return self._send(202, {"job": jid, "kind": "cleanup"})

        # Time-windowed jobs: validate, then start like any other job (202 + job id).
        if p in ("/api/labels/populate", "/api/archive-before"):
            slug = payload.get("slug")
            if slug is not None:
                try:
                    _acct(slug)
                except ValueError as exc:
                    return self._send(400, {"error": str(exc)})
            if p == "/api/labels/populate":
                w = payload.get("window_days", 30)
                if not isinstance(w, int) or not (1 <= w <= 365):
                    return self._send(400, {"error": "window_days must be 1–365"})
                kind = "populate"
            else:
                before = payload.get("before")
                if not isinstance(before, str) or not _DATE_RE.match(before):
                    return self._send(400, {"error": "before must be YYYY/MM/DD"})
                kind = "archive_before"
            jid = _start_job(kind, payload)
            if jid is None:
                return self._send(409, {"error": "a job is already running"})
            return self._send(202, {"job": jid, "kind": kind})

        # Fast synchronous endpoints (one thread / one model call), not the job slot.
        _sync = {"/api/dismiss": _dismiss, "/api/draft": _gen_draft,
                 "/api/draft/send": _send_draft,
                 "/api/undo/threads": _undo_threads,
                 "/api/undo/thread": _undo_thread,
                 "/api/thread/preview": _thread_preview,
                 "/api/set-credentials": _set_client_credentials}
        if p in _sync:
            try:
                return self._send(200, _sync[p](payload))
            except Exception as exc:
                return self._send(500, {"error": str(exc)})
        kind = {"/api/refresh": "refresh", "/api/run": "run",
                "/api/undo": "undo", "/api/add-account": "add_account"}.get(p)
        if not kind:
            return self._send(404, {"error": "not found"})
        jid = _start_job(kind, payload)
        if jid is None:
            return self._send(409, {"error": "a job is already running"})
        return self._send(202, {"job": jid, "kind": kind})

    def do_PUT(self):
        if not self._is_local_request():
            return self._send(403, {"error": "cross-site request blocked"})
        p = urlparse(self.path).path
        payload = self._body_json()

        if p == "/api/policy":
            text = payload.get("policy", "")
            if not isinstance(text, str):
                return self._send(400, {"error": "policy must be a string"})
            tmp = POLICY_PATH + ".tmp"
            with open(tmp, "w") as f:
                f.write(text)
            os.replace(tmp, POLICY_PATH)
            return self._send(200, {"ok": True})

        if p == "/api/categories":
            cats = payload.get("categories")
            if not isinstance(cats, list):
                return self._send(400, {"error": "categories must be a list"})
            validated = []
            for item in cats:
                if not isinstance(item, dict):
                    return self._send(400, {"error": "each category must be an object"})
                name = item.get("name")
                if not isinstance(name, str) or not name.strip():
                    return self._send(400, {"error": "each category must have a non-empty string 'name'"})
                validated.append({
                    "name": name.strip(),
                    "description": str(item.get("description", "")) if item.get("description") is not None else "",
                    "color": str(item.get("color", DEFAULT_CATEGORY_COLOR)) if item.get("color") else DEFAULT_CATEGORY_COLOR,
                    "emoji": str(item.get("emoji", DEFAULT_CATEGORY_EMOJI)) if item.get("emoji") else DEFAULT_CATEGORY_EMOJI,
                })
            # Union the outgoing label names into the history so that if the user
            # renames a category, the old Gmail labels are cleaned up on next apply.
            try:
                sys.path.insert(0, HERE)
                import review_open_loops as rol  # noqa: E402
                old_cats = _read_categories()
                old_names = {f"{c['emoji']} {c['name']}" for c in old_cats}
                rol._add_to_label_history(old_names)
            except Exception:
                pass
            tmp = CATEGORIES_PATH + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump({"categories": validated}, f, ensure_ascii=False, indent=2)
            os.replace(tmp, CATEGORIES_PATH)
            return self._send(200, {"ok": True})

        if p == "/api/settings":
            errors = []
            validated = {}
            # grace_days: required if present
            g = payload.get("grace_days")
            if g is not None:
                if not isinstance(g, int) or isinstance(g, bool) or not (0 <= g <= 90):
                    errors.append("grace_days must be an int 0–90")
                else:
                    validated["grace_days"] = g
            # schedule_hour
            sh = payload.get("schedule_hour")
            if sh is not None:
                if not isinstance(sh, int) or isinstance(sh, bool) or not (0 <= sh <= 23):
                    errors.append("schedule_hour must be an int 0–23")
                else:
                    validated["schedule_hour"] = sh
            # schedule_minute
            sm = payload.get("schedule_minute")
            if sm is not None:
                if not isinstance(sm, int) or isinstance(sm, bool) or not (0 <= sm <= 59):
                    errors.append("schedule_minute must be an int 0–59")
                else:
                    validated["schedule_minute"] = sm
            # schedule_days: list of ints 0-6
            sd = payload.get("schedule_days")
            if sd is not None:
                if (not isinstance(sd, list)
                        or not all(isinstance(d, int) and not isinstance(d, bool) and 0 <= d <= 6
                                   for d in sd)):
                    errors.append("schedule_days must be a list of ints 0–6")
                else:
                    validated["schedule_days"] = sd
            # notify_on_run
            nr = payload.get("notify_on_run")
            if nr is not None:
                if not isinstance(nr, bool):
                    errors.append("notify_on_run must be a bool")
                else:
                    validated["notify_on_run"] = nr
            # auto_draft
            ad = payload.get("auto_draft")
            if ad is not None:
                if not isinstance(ad, bool):
                    errors.append("auto_draft must be a bool")
                else:
                    validated["auto_draft"] = ad
            # label_archived_days: 0 (off) to 365
            lad = payload.get("label_archived_days")
            if lad is not None:
                if not isinstance(lad, int) or isinstance(lad, bool) or not (0 <= lad <= 365):
                    errors.append("label_archived_days must be an int 0–365")
                else:
                    validated["label_archived_days"] = lad
            # provider: must be a known provider name AND currently available
            prov = payload.get("provider")
            if prov is not None:
                sys.path.insert(0, HERE)
                import llm as _llm  # noqa: E402
                known = {pr["name"] for pr in _llm.KNOWN_PROVIDERS}
                if prov not in known:
                    errors.append(f"provider must be one of: {', '.join(sorted(known))}")
                else:
                    statuses = _llm.detect_providers()
                    prov_status = next((s for s in statuses if s["name"] == prov), None)
                    if not prov_status or not prov_status["available"]:
                        errors.append(f"provider '{prov}' is not available on this system")
                    else:
                        validated["provider"] = prov
            # draft_name: optional signing name override (blank = derive per account)
            dn = payload.get("draft_name")
            if dn is not None:
                if not isinstance(dn, str) or len(dn) > 80:
                    errors.append("draft_name must be a string up to 80 chars")
                else:
                    validated["draft_name"] = dn.strip()
            # draft_guidance: optional free-form house style
            dg = payload.get("draft_guidance")
            if dg is not None:
                if not isinstance(dg, str) or len(dg) > 600:
                    errors.append("draft_guidance must be a string up to 600 chars")
                else:
                    validated["draft_guidance"] = dg.strip()
            if errors:
                return self._send(400, {"error": "; ".join(errors)})
            if not validated:
                return self._send(400, {"error": "no valid settings keys provided"})
            try:
                saved = _write_settings(validated)
                # Reload the launchd schedule if any schedule key changed.
                if any(k in validated for k in ("schedule_hour", "schedule_minute", "schedule_days")):
                    _rewrite_schedule_plist(saved)
                return self._send(200, saved)
            except Exception as exc:
                return self._send(500, {"error": str(exc)})

        return self._send(404, {"error": "not found"})


def main():
    global _building
    # gws needs the file keyring backend to work headlessly; ensure it's set even
    # when the server is started directly (the CLI / app set it, but be safe).
    os.environ.setdefault("GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND", "file")
    host = os.environ.get("KEEPER_HOST", "127.0.0.1")
    port = int(os.environ.get("KEEPER_PORT", "8765"))

    # Start the HTTP server FIRST so /api/state is reachable immediately (returns
    # building:true while the rebuild runs), then kick off the rebuild in the background.
    # ponytail: blocking boot was the root cause of up-to-180s unreachability on stale state.
    httpd = ThreadingHTTPServer((host, port), Handler)
    print(f"zero API on http://{host}:{port}")
    sys.stdout.flush()

    if _state_is_stale():
        def _boot_rebuild():
            global _building
            with _boot_lock:
                _building = True
            try:
                _build_state_blocking()
            except Exception as exc:
                # Never crash the server — the panel can /api/refresh manually.
                print(f"warning: initial state build failed: {exc}", file=sys.stderr)
            finally:
                with _boot_lock:
                    _building = False
        t = threading.Thread(target=_boot_rebuild, daemon=True, name="boot-rebuild")
        t.start()

    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
