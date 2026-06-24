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
    return {"ok": True, "label": label, "thread_id": tid}


_JOB_KINDS = {"refresh": lambda p: _build_state_blocking(),
              "run": _run_keeper, "undo": _run_undo}


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
        # Dismiss is fast (one thread) and runs synchronously, not via the job slot.
        if p == "/api/dismiss":
            try:
                return self._send(200, _dismiss(payload))
            except Exception as exc:
                return self._send(500, {"error": str(exc)})
        kind = {"/api/refresh": "refresh", "/api/run": "run",
                "/api/undo": "undo"}.get(p)
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
