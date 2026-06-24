#!/usr/bin/env python3
"""Local HTTP server behind the inbox-keeper menu-bar panel.

Stdlib only (no dependencies) so the open-source install stays trivial. Binds to
127.0.0.1, serves the static panel, and exposes a small JSON API:

  GET  /                 -> panel/index.html
  GET  /<asset>          -> static panel assets (css/js)
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
import json, os, subprocess, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
PANEL_DIR = os.path.join(ROOT, "app", "panel")
STATE_PATH = os.path.join(ROOT, "app", "state.json")
POLICY_PATH = os.path.join(ROOT, "keep-policy.md")
ACCOUNTS_PATH = os.path.join(ROOT, "accounts.json")
PYTHON = sys.executable or "python3"
CLAUDE = os.environ.get("CLAUDE_BIN", "claude")

_ASSET_TYPES = {".html": "text/html; charset=utf-8", ".css": "text/css; charset=utf-8",
                ".js": "text/javascript; charset=utf-8", ".svg": "image/svg+xml",
                ".png": "image/png", ".woff2": "font/woff2", ".json": "application/json"}

# --- single background job slot -------------------------------------------------
_job_lock = threading.Lock()
_job = {"id": 0, "kind": None, "state": "idle", "started": 0, "finished": 0,
        "message": "", "error": None}


def _gws_env():
    e = dict(os.environ)
    e["GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND"] = "file"
    return e


_state_lock = threading.Lock()


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


def _build_state_blocking():
    r = subprocess.run([PYTHON, os.path.join(HERE, "dashboard_state.py")],
                       env=_gws_env(), capture_output=True, text=True, timeout=180)
    if r.returncode != 0:
        raise RuntimeError(f"state rebuild failed (exit {r.returncode}): "
                           f"{(r.stderr or r.stdout or '')[-500:]}")


def _load_accounts():
    with open(ACCOUNTS_PATH) as f:
        data = json.load(f)
    return data if isinstance(data, list) else data.get("accounts", [])


def _run_keeper(payload):
    """Run the open-loop sweep across all accounts at the daily grace, then rebuild."""
    grace = int(payload.get("grace_days", 2))
    accts = _load_accounts()
    failures = []
    for acct in accts:
        cfg = acct["config_dir"]
        email = acct.get("email", acct.get("slug", cfg))
        _set_job_message(f"Keeping {email}...")
        r = subprocess.run([PYTHON, os.path.join(HERE, "review_open_loops.py"),
                            cfg, email, "--grace-days", str(grace), "--execute"],
                           env=_gws_env(), capture_output=True, text=True, timeout=600)
        if r.returncode != 0:
            failures.append(f"{email}: {(r.stderr or r.stdout or '').strip()[-200:]}")
    # Update what we've learned from recent actions (best-effort; gated on signals).
    subprocess.run([PYTHON, os.path.join(HERE, "learn.py")],
                   env=_gws_env(), capture_output=True, text=True, timeout=180)
    _set_job_message("Refreshing...")
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
    acct = next((a for a in _load_accounts()
                 if (a.get("slug") or a.get("email")) == slug), None)
    if not acct:
        raise ValueError(f"unknown account {slug!r}")
    cfg = acct["config_dir"]
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
    acct = next((a for a in _load_accounts()
                 if (a.get("slug") or a.get("email")) == slug), None)
    if not acct:
        raise ValueError(f"unknown account {slug!r}")
    cfg = acct["config_dir"]

    # Undo a just-dismissed thread: put it back in the inbox and net out the signal.
    if payload.get("undo"):
        label = payload.get("label") or iz._dated_label(iz._BASE_LABEL)
        labels = du._gws(cfg, ["gmail", "users", "labels", "list",
                               "--params", json.dumps({"userId": "me"})]).get("labels", [])
        lab = next((l for l in labels if l.get("name") == label), None)
        remove = [lab["id"]] if lab else []
        du._gws(cfg, ["gmail", "users", "threads", "modify",
                      "--params", json.dumps({"userId": "me", "id": tid}),
                      "--json", json.dumps({"addLabelIds": ["INBOX"], "removeLabelIds": remove})],
                allow_empty=True)
        learning.record({"type": "keep_override_undo", "account": slug, "thread_id": tid})

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

    def _remove(st):
        for a in st.get("accounts", []):
            if a.get("slug") != slug:
                continue
            before = len(a.get("loops", []))
            a["loops"] = [l for l in a.get("loops", []) if l.get("thread_id") != tid]
            if len(a["loops"]) < before:
                a["inbox_threads"] = max(0, a.get("inbox_threads", 1) - 1)
    _patch_state(_remove)
    return {"ok": True, "label": label, "thread_id": tid}


def _acct(slug):
    a = next((a for a in _load_accounts()
              if (a.get("slug") or a.get("email")) == slug), None)
    if not a:
        raise ValueError(f"unknown account {slug!r}")
    return a


def _gen_draft(payload):
    """Draft a reply to a thread in the user's voice. The user already chose to
    reply (they tapped Reply), so there's no needs-reply gate here."""
    sys.path.insert(0, HERE)
    import draftutil as du       # noqa: E402
    import learning              # noqa: E402
    from email.utils import parseaddr
    slug, tid = payload.get("slug"), payload.get("thread_id")
    steer = (payload.get("steer") or "").strip()
    if not slug or not tid:
        raise ValueError("draft requires slug and thread_id")
    cfg = _acct(slug)["config_dir"]
    t = du._gws(cfg, ["gmail", "users", "threads", "get",
                      "--params", json.dumps({"userId": "me", "id": tid, "format": "metadata",
                                              "metadataHeaders": ["From", "Subject", "Date"]})])
    msgs = t.get("messages", []) or []
    if not msgs:
        raise ValueError("thread has no messages")
    convo = []
    subject = "(no subject)"
    last_from = ""
    for m in msgs:
        h = {x["name"].lower(): x["value"] for x in m.get("payload", {}).get("headers", [])}
        last_from = h.get("from", last_from)
        subject = h.get("subject", subject)
        convo.append(f"From {h.get('from','?')}: {m.get('snippet','')}")
    to_name = parseaddr(last_from)[0] or parseaddr(last_from)[1] or last_from
    to_email = parseaddr(last_from)[1] or ""
    voice = learning.learned_text()
    voice_block = f"\nVOICE NOTES learned from the user's past edits:\n{voice}\n" if voice.strip() else ""
    prompt = (
        "Draft a reply, in Tayo Onabule's voice, to the email thread below. British English, "
        "first person, warm and concise (2-6 sentences), mirror the sender's formality, reference "
        "real thread context, never invent facts or figures (use placeholders like [day]/[amount] "
        f"if needed), sign off as \"Tayo\". Reply to {to_name}.{voice_block}"
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
    return {"ok": True, "to_name": to_name, "to_email": to_email,
            "subject": subject, "body": r.stdout.strip()}


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
    final = payload.get("body") or ""
    original = payload.get("original") or ""
    if not (slug and tid and to and final.strip()):
        raise ValueError("send requires slug, thread_id, to, and body")
    cfg = _acct(slug)["config_dir"]
    raw = du._build_raw(cfg, tid, to, subject, final)
    d = du._gws(cfg, ["gmail", "users", "drafts", "create",
                      "--params", json.dumps({"userId": "me"}),
                      "--json", json.dumps({"message": {"raw": raw, "threadId": tid}})])
    du._gws(cfg, ["gmail", "users", "drafts", "send",
                  "--params", json.dumps({"userId": "me"}),
                  "--json", json.dumps({"id": d["id"]})])
    if original and original.strip() != final.strip():
        learning.record({"type": "draft_edit", "thread_id": tid,
                         "original_snippet": original[:200], "final": final[:400]})
    # Replying resolves the loop; drop it from the cached state.
    def _remove(st):
        for a in st.get("accounts", []):
            if a.get("slug") == slug:
                a["loops"] = [l for l in a.get("loops", []) if l.get("thread_id") != tid]
                a["inbox_threads"] = max(0, a.get("inbox_threads", 1) - 1)
    _patch_state(_remove)
    return {"ok": True, "sent": tid}


def _add_account(payload):
    """Authenticate a new Gmail account via gws (opens the user's browser) and add
    it to accounts.json. The OAuth consent happens in the browser; we never see
    credentials."""
    import time as _time
    home = os.path.expanduser("~")
    pending = os.path.join(home, ".config", "gws", "accounts", f"pending-{int(_time.time())}")
    os.makedirs(pending, exist_ok=True)
    env = _gws_env()
    env["GOOGLE_WORKSPACE_CLI_CONFIG_DIR"] = pending
    _set_job_message("Opening your browser to sign in...")
    r = subprocess.run(["gws", "auth", "login"], env=env,
                       capture_output=True, text=True, timeout=300)
    if r.returncode != 0:
        raise RuntimeError("sign-in didn't complete: " + (r.stderr or r.stdout or "")[-200:])
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
    slug = email.split("@")[0].replace(".", "-").lower()
    final_dir = os.path.join(home, ".config", "gws", "accounts", slug)
    accts = _load_accounts()
    if any(a.get("email") == email for a in accts):
        raise RuntimeError(f"{email} is already added")
    if os.path.exists(final_dir):
        final_dir = pending  # keep the pending dir if the nice name is taken
    else:
        os.rename(pending, final_dir)
    accts.append({"slug": slug, "email": email, "config_dir": final_dir})
    tmp = ACCOUNTS_PATH + ".tmp"
    with open(tmp, "w") as f:
        json.dump(accts, f, indent=2)
    os.replace(tmp, ACCOUNTS_PATH)
    _set_job_message("Adding account...")
    _build_state_blocking()


_JOB_KINDS = {"refresh": lambda p: _build_state_blocking(),
              "run": _run_keeper, "undo": _run_undo, "add_account": _add_account}


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
                _job.update(state="done", finished=int(time.time()),
                            message="Done")
        except Exception as exc:
            with _job_lock:
                _job.update(state="error", finished=int(time.time()),
                            error=str(exc), message="Failed")

    threading.Thread(target=worker, daemon=True).start()
    return jid


class Handler(BaseHTTPRequestHandler):
    server_version = "inbox-keeper/1.0"

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

    def _serve_static(self, path):
        rel = "index.html" if path in ("/", "") else path.lstrip("/")
        full = os.path.normpath(os.path.join(PANEL_DIR, rel))
        # Guard against sibling-prefix escapes (e.g. /../panelX): require the
        # resolved path to live strictly inside PANEL_DIR.
        if (full != PANEL_DIR and not full.startswith(PANEL_DIR + os.sep)) \
                or not os.path.isfile(full):
            return self._send(404, {"error": "not found"})
        ext = os.path.splitext(full)[1]
        with open(full, "rb") as f:
            data = f.read()
        self._send(200, data, _ASSET_TYPES.get(ext, "application/octet-stream"))

    def do_GET(self):
        p = urlparse(self.path).path
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
        return self._serve_static(p)

    def do_POST(self):
        if not self._is_local_request():
            return self._send(403, {"error": "cross-site request blocked"})
        p = urlparse(self.path).path
        payload = self._body_json()
        # Fast synchronous endpoints (one thread / one model call), not the job slot.
        _sync = {"/api/dismiss": _dismiss, "/api/draft": _gen_draft,
                 "/api/draft/send": _send_draft}
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
        if p != "/api/policy":
            return self._send(404, {"error": "not found"})
        payload = self._body_json()
        text = payload.get("policy", "")
        if not isinstance(text, str):
            return self._send(400, {"error": "policy must be a string"})
        tmp = POLICY_PATH + ".tmp"
        with open(tmp, "w") as f:
            f.write(text)
        os.replace(tmp, POLICY_PATH)
        return self._send(200, {"ok": True})


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
    print(f"inbox-keeper panel on http://{host}:{port}")
    sys.stdout.flush()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
