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
import json, os, re, subprocess, sys, threading, time
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
_DATE_RE = re.compile(r"^\d{4}/\d{2}/\d{2}$")
PYTHON = sys.executable or "python3"
CLAUDE = os.environ.get("CLAUDE_BIN", "claude")

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
        "message": "", "error": None}


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
    grace = int(payload.get("grace_days", _read_settings()["grace_days"]))
    accts = _load_accounts()
    failures, set_aside, kept = [], 0, 0
    for i, acct in enumerate(accts, 1):
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
    _set_job_message(f"Set aside {set_aside}, {kept} still need you")
    _build_state_blocking()
    if failures:
        raise RuntimeError("Some accounts failed: " + " | ".join(failures))


def _run_populate(payload):
    """Label-only backfill: sort the last N days of inbox mail into category labels.
    One account (slug) or all. Never archives — purely additive labeling."""
    window = max(1, min(int(payload.get("window_days", 30)), 365))
    slug = payload.get("slug")
    accts = [_acct(slug)] if slug else _load_accounts()
    failures, labeled = [], 0
    for i, acct in enumerate(accts, 1):
        cfg = acct["config_dir"]
        email = acct.get("email", acct.get("slug", cfg))
        _set_job_message(f"Sorting {email} ({i}/{len(accts)})…")
        r = subprocess.run([PYTHON, os.path.join(HERE, "review_open_loops.py"),
                            cfg, email, "--label-only", "--window-days", str(window)],
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
    if failures:
        raise RuntimeError("Some accounts failed: " + " | ".join(failures))


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
    if failures:
        raise RuntimeError("Some accounts failed: " + " | ".join(failures))


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

# Legacy unified-taxonomy labels created by earlier zero versions
# (before per-user categories were introduced). Source: TRIAGE.md + demote_automated.py.
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

    # Filter to user-created labels only (exclude type=="system").
    user_labels = [l for l in (data.get("labels") or [])
                   if l.get("type") != "system"
                   and l.get("id") not in _GMAIL_SYSTEM_IDS]

    # Fetch threadsTotal in parallel (cap 8 workers, matching dashboard_state).
    results = []
    with ThreadPoolExecutor(max_workers=8) as ex:
        futs = {ex.submit(_fetch_label_detail, cfg, lab): lab for lab in user_labels}
        for f in as_completed(futs):
            try:
                lab, threads = f.result()
                ours = _is_ours(lab.get("name", ""), category_label_names, label_history)
                results.append({
                    "id": lab["id"],
                    "name": lab.get("name", ""),
                    "threads": threads,
                    "ours": ours,
                })
            except Exception:
                pass

    # Sort: ours-first, then name A→Z.
    results.sort(key=lambda r: (not r["ours"], r["name"]))
    return {"labels": results}


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
    owner_name = (acct.get("name") or _name_from_email(acct.get("email", ""))).strip()
    owner_first = owner_name.split()[0] if owner_name else ""
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
        f"{prof_block}{exemplar_block}{voice_block}"
        + (f"\nADJUSTMENT requested: {steer}\n" if steer else "")
        + f"\nSubject: {subject}\nThread (oldest to newest):\n" + "\n".join(convo[-8:])
        + "\n\nOutput ONLY the reply body text, no preamble, no subject line."
    )
    try:
        r = subprocess.run([CLAUDE, "-p", prompt, "--model", "haiku"],
                           capture_output=True, text=True, timeout=120)
    except subprocess.TimeoutExpired:
        raise RuntimeError("drafting timed out")
    if r.returncode != 0:
        raise RuntimeError("drafting failed")
    body = r.stdout.strip()
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
    _drop_loop(slug, tid)  # replying resolves the loop
    return {"ok": True, "sent": tid}


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
        _seed = _existing_client_secret()
        if _seed:
            shutil.copyfile(_seed, os.path.join(pending, "client_secret.json"))
        env = _gws_env()
        env["GOOGLE_WORKSPACE_CLI_CONFIG_DIR"] = pending
        _set_job_message("Opening your browser to sign in...")
        r = subprocess.run(["gws", "auth", "login"], env=env,
                           capture_output=True, text=True, timeout=300)
        if r.returncode != 0:
            raw = (r.stderr or r.stdout or "").strip()
            # Detect the missing-OAuth-client failure before surfacing a truncated message.
            _cred_hints = ("client_id", "client_secret", "GOOGLE_WORKSPACE_CLI_CLIENT",
                           "client_secret.json", "Cloud Console")
            if any(h.lower() in raw.lower() for h in _cred_hints) or not raw:
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
            raise RuntimeError("sign-in didn't complete: " + raw[-400:])
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
from dashboard_state import _DEFAULT_CATEGORIES  # noqa: E402 — canonical definition lives there


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


_DEFAULT_SETTINGS = {"grace_days": 0}


def _read_settings():
    """User timing settings (grace_days). Defaults if file is missing/unreadable."""
    s = dict(_DEFAULT_SETTINGS)
    try:
        if os.path.isfile(SETTINGS_PATH):
            with open(SETTINGS_PATH) as f:
                s.update({k: v for k, v in json.load(f).items() if k in _DEFAULT_SETTINGS})
    except Exception:
        pass
    return s


def _write_settings(settings):
    """Persist the whitelisted settings keys. Returns the saved dict."""
    s = dict(_DEFAULT_SETTINGS)
    s.update({k: v for k, v in (settings or {}).items() if k in _DEFAULT_SETTINGS})
    os.makedirs(os.path.dirname(SETTINGS_PATH), exist_ok=True)
    tmp = SETTINGS_PATH + ".tmp"
    with open(tmp, "w") as f:
        json.dump(s, f, indent=2)
    os.replace(tmp, SETTINGS_PATH)
    return s


_JOB_KINDS = {"refresh": lambda p: _build_state_blocking(),
              "run": _run_keeper, "undo": _run_undo, "add_account": _add_account,
              "populate": _run_populate, "archive_before": _run_archive_before}


def _set_job_message(msg):
    with _job_lock:
        _job["message"] = msg


def _start_job(kind, payload):
    with _job_lock:
        if _job["state"] == "running":
            return None
        _job.update(id=_job["id"] + 1, kind=kind, state="running",
                    started=int(time.time()), finished=0, message="Starting...",
                    error=None)
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
            return origin in (f"http://127.0.0.1:{PORT}", f"http://localhost:{PORT}")
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
            if os.path.isfile(STATE_PATH):
                with open(STATE_PATH, "rb") as f:
                    return self._send(200, f.read(), "application/json")
            return self._send(200, {"ok": False, "accounts": [], "total_loops": 0,
                                    "needs_build": True})
        if p == "/api/job":
            with _job_lock:
                return self._send(200, dict(_job))
        if p == "/api/policy":
            text = ""
            if os.path.isfile(POLICY_PATH):
                with open(POLICY_PATH) as f:
                    text = f.read()
            return self._send(200, {"policy": text})
        if p == "/api/categories":
            return self._send(200, {"categories": _read_categories()})
        if p == "/api/settings":
            return self._send(200, _read_settings())
        if p == "/api/credentials-status":
            return self._send(200, _credentials_status())
        return self._send(404, {"error": "not found"})

    def do_POST(self):
        if not self._is_local_request():
            return self._send(403, {"error": "cross-site request blocked"})
        p = urlparse(self.path).path
        payload = self._body_json()
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
            try:
                return self._send(200, _delete_account_labels(slug, ids))
            except Exception as exc:
                return self._send(500, {"error": str(exc)})

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
            g = payload.get("grace_days")
            if not isinstance(g, int) or isinstance(g, bool) or not (0 <= g <= 90):
                return self._send(400, {"error": "grace_days must be an int 0–90"})
            try:
                return self._send(200, _write_settings({"grace_days": g}))
            except Exception as exc:
                return self._send(500, {"error": str(exc)})

        return self._send(404, {"error": "not found"})


def main():
    # gws needs the file keyring backend to work headlessly; ensure it's set even
    # when the server is started directly (the CLI / app set it, but be safe).
    os.environ.setdefault("GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND", "file")
    host = os.environ.get("KEEPER_HOST", "127.0.0.1")
    port = int(os.environ.get("KEEPER_PORT", "8765"))
    # Build state on boot if missing, so the first panel open is never empty.
    if not os.path.isfile(STATE_PATH):
        try:
            _build_state_blocking()
        except Exception as exc:
            # Don't crash the server, but don't hide it either — the panel shows
            # a skeleton until /api/refresh succeeds; make the cause visible in logs.
            print(f"warning: initial state build failed: {exc}", file=sys.stderr)
    httpd = ThreadingHTTPServer((host, port), Handler)
    print(f"zero API on http://{host}:{port}")
    sys.stdout.flush()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
