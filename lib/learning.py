#!/usr/bin/env python3
"""Append-only store of what the user teaches the keeper by their actions.

Two kinds of signal feed the system's judgment over time:
  - keep_override : the keeper kept a thread but the user set it aside without
                    replying (a "this isn't really a loop for me" signal).
  - draft_edit    : the user edited a draft the system wrote before sending
                    (a voice / preference signal).

Signals are raw events here; lib/learn.py rolls them into a human-readable
learning/learned.md that the keep-bar and draft prompts read. Nothing here
silently changes the user's policy: the rollup is visible and editable.
"""
import json, os, re, time
from contextlib import contextmanager

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
LEARN_DIR = os.path.join(ROOT, "learning")
SIGNALS = os.path.join(LEARN_DIR, "signals.jsonl")
LEARNED = os.path.join(LEARN_DIR, "learned.md")
REJECTED = os.path.join(LEARN_DIR, "rejected.jsonl")

try:
    import fcntl  # POSIX; this tool is macOS-only
    _HAVE_FCNTL = True
except ImportError:
    _HAVE_FCNTL = False


@contextmanager
def _locked(path, mode):
    os.makedirs(LEARN_DIR, exist_ok=True)
    f = open(path, mode)
    try:
        if _HAVE_FCNTL:
            fcntl.flock(f.fileno(), fcntl.LOCK_EX)
        yield f
    finally:
        if _HAVE_FCNTL:
            fcntl.flock(f.fileno(), fcntl.LOCK_UN)
        f.close()


def record(event):
    """Append one signal. `event` is a dict; a unix timestamp is added."""
    event = {"ts": int(time.time()), **event}
    with _locked(SIGNALS, "a") as f:
        f.write(json.dumps(event, ensure_ascii=False) + "\n")
    return event


def recent(n=400, kind=None):
    """Return up to the last n signals (optionally of one kind), newest last."""
    if not os.path.exists(SIGNALS):
        return []
    out = []
    with _locked(SIGNALS, "r") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except Exception:
                continue
            if kind and ev.get("type") != kind:
                continue
            out.append(ev)
    return out[-n:]


def learned_text():
    """The current rolled-up learning, or '' if none yet."""
    if os.path.exists(LEARNED):
        with open(LEARNED) as f:
            return f.read()
    return ""


def _norm(text):
    """Normalise a bullet for reject matching: strip markers, lowercase, collapse ws."""
    t = re.sub(r"^[\s\-\*•]+", "", text.strip())
    return re.sub(r"\s+", " ", t).lower().strip()


def reject_learning(text):
    """Permanently suppress a learned preference.

    Appends a record to rejected.jsonl and immediately removes any matching
    bullet from learned.md. Future rollups (learn.py) also filter the reject
    store, so the preference never comes back.
    """
    norm = _norm(text)
    if not norm:
        return
    os.makedirs(LEARN_DIR, exist_ok=True)
    # Append to reject store.
    record = json.dumps({"ts": int(time.time()), "norm": norm, "original": text.strip()},
                        ensure_ascii=False)
    with _locked(REJECTED, "a") as f:
        f.write(record + "\n")
    # Remove matching bullets from learned.md immediately.
    if not os.path.exists(LEARNED):
        return
    with open(LEARNED) as f:
        lines = f.readlines()
    kept = [l for l in lines if _norm(l) != norm]
    if len(kept) == len(lines):
        return  # nothing removed
    tmp = LEARNED + ".tmp"
    with open(tmp, "w") as f:
        f.writelines(kept)
    os.replace(tmp, LEARNED)
