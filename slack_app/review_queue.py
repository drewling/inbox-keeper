"""
queue.py — Concurrency-safe helpers for reading and writing queue.json.

Uses fcntl advisory locking so multiple processes (e.g. the Bolt listener
and a separate `python app.py post` invocation) do not corrupt the file.

Writes are crash-safe: all mutations go through _atomic_save, which writes
to a temp file in the same directory and os.replace()-atomically swaps it.
"""

import fcntl
import json
import logging
import os
import sys
import tempfile
from contextlib import contextmanager
from typing import Any

# Resolve config.py from repo root (one level up from slack_app/).
_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = os.path.dirname(_HERE)
sys.path.insert(0, _ROOT)
import config as _cfg  # noqa: E402

QUEUE_PATH = os.environ.get("QUEUE_PATH", _cfg.QUEUE_PATH)

log = logging.getLogger("mail_triage.queue")

# We use a separate lock file so that reads (which don't write) can still
# take an exclusive lock without re-opening the data file for writing.
_LOCK_PATH = QUEUE_PATH + ".lock"


@contextmanager
def _lock():
    """Acquire an exclusive advisory lock, yield, then release."""
    os.makedirs(os.path.dirname(_LOCK_PATH), exist_ok=True)
    with open(_LOCK_PATH, "a", encoding="utf-8") as lf:
        fcntl.flock(lf, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(lf, fcntl.LOCK_UN)


def _load_raw() -> list[dict[str, Any]]:
    """Read queue.json without acquiring the lock (caller must hold it)."""
    if not os.path.exists(QUEUE_PATH):
        return []
    with open(QUEUE_PATH, "r", encoding="utf-8") as fh:
        raw = fh.read().strip()
    if not raw:
        return []
    try:
        return json.loads(raw)
    except json.JSONDecodeError as exc:
        log.error("queue.json is corrupt and cannot be parsed: %s", exc)
        raise


def _atomic_save(items: list[dict[str, Any]]) -> None:
    """Atomically write *items* to QUEUE_PATH via a temp file + os.replace().
    Caller must hold the lock."""
    queue_dir = os.path.dirname(QUEUE_PATH)
    os.makedirs(queue_dir, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(dir=queue_dir, suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(items, fh, indent=2, ensure_ascii=False)
            fh.write("\n")
        os.replace(tmp_path, QUEUE_PATH)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def load_queue() -> list[dict[str, Any]]:
    """Read and return the full queue as a list of dicts.

    Returns an empty list if the file does not exist yet.
    Raises on JSON corruption (do NOT silently return []).
    """
    with _lock():
        return _load_raw()


def update_item(item_id: str, **fields) -> dict[str, Any] | None:
    """Atomically update fields on the queue item matching *item_id*.

    Returns the updated item, or None if not found.
    """
    with _lock():
        items = _load_raw()
        target = None
        for item in items:
            if item.get("id") == item_id:
                item.update(fields)
                target = item
                break
        if target is not None:
            _atomic_save(items)
    return target


def claim_for_send(item_id: str) -> dict[str, Any] | None:
    """Atomically claim a pending item for sending.

    Under the lock: if the item's status is not "pending", returns None
    (prevents double-send on double-click or race between handlers).
    If status is "pending", sets it to "sending", saves, and returns the item.
    """
    with _lock():
        items = _load_raw()
        target = None
        for item in items:
            if item.get("id") == item_id:
                if item.get("status") != "pending":
                    return None
                item["status"] = "sending"
                target = item
                break
        if target is not None:
            _atomic_save(items)
    return target


def get_item(item_id: str) -> dict[str, Any] | None:
    """Return the queue item with *item_id*, or None if not found."""
    for item in load_queue():
        if item.get("id") == item_id:
            return item
    return None


def pending_unposted() -> list[dict[str, Any]]:
    """Return items that are pending and have not been posted to Slack yet."""
    return [
        item
        for item in load_queue()
        if item.get("status") == "pending" and not item.get("slack_ts")
    ]
