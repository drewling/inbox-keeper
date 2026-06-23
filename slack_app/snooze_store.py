"""
snooze_store.py — fcntl-locked JSON store for snoozed items.

Snoozes apply to both draft cards and missed-item cards.  Each entry records
the thread_id, the account config_dir, and the ISO-8601 UTC datetime at which
the item should be re-surfaced.

Store path: slack_app/snoozes.json (next to this file).

Schema (list of objects):
[
  {
    "thread_id":     "<Gmail thread ID>",
    "account":       "<config_dir>",          # used to identify the account
    "account_label": "<human label>",
    "until_iso":     "2026-06-24T09:00:00+00:00",
    "kind":          "draft" | "missed",      # for future filtering
    "item_id":       "<queue item id>",       # present for draft snoozes
    "slack_ts":      "<original message ts>", # so we can update the card
    "slack_channel": "<channel id>"
  }
]
"""

import fcntl
import json
import os
from contextlib import contextmanager
from datetime import datetime, timezone, timedelta
from typing import Any

SNOOZE_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "snoozes.json")


@contextmanager
def _locked(mode: str):
    """Open snoozes.json with an exclusive advisory lock."""
    # Ensure the file exists before we try to open for reading.
    if not os.path.exists(SNOOZE_PATH):
        with open(SNOOZE_PATH, "w", encoding="utf-8") as fh:
            fh.write("[]\n")
    with open(SNOOZE_PATH, mode, encoding="utf-8") as fh:
        fcntl.flock(fh, fcntl.LOCK_EX)
        try:
            yield fh
        finally:
            fcntl.flock(fh, fcntl.LOCK_UN)


def load_snoozes() -> list[dict[str, Any]]:
    """Return all snooze entries (creates the file if absent)."""
    if not os.path.exists(SNOOZE_PATH):
        return []
    with _locked("r") as fh:
        raw = fh.read().strip()
    return json.loads(raw) if raw else []


def _save(entries: list[dict[str, Any]], fh) -> None:
    fh.seek(0)
    fh.truncate()
    json.dump(entries, fh, indent=2, ensure_ascii=False)
    fh.write("\n")


def add_snooze(
    thread_id: str,
    account: str,
    *,
    account_label: str = "",
    hours: int = 24,
    kind: str = "missed",
    item_id: str = "",
    slack_ts: str = "",
    slack_channel: str = "",
) -> dict[str, Any]:
    """Add (or overwrite) a snooze for *thread_id*.

    Returns the new snooze entry.
    """
    until = (datetime.now(timezone.utc) + timedelta(hours=hours)).isoformat()
    entry = {
        "thread_id": thread_id,
        "account": account,
        "account_label": account_label,
        "until_iso": until,
        "kind": kind,
        "item_id": item_id,
        "slack_ts": slack_ts,
        "slack_channel": slack_channel,
    }
    with _locked("r+") as fh:
        raw = fh.read().strip()
        entries: list[dict] = json.loads(raw) if raw else []
        # Remove any existing snooze for this thread+account to avoid dupes.
        entries = [e for e in entries if not (e["thread_id"] == thread_id and e["account"] == account)]
        entries.append(entry)
        _save(entries, fh)
    return entry


def is_snoozed(thread_id: str, account: str) -> bool:
    """Return True if *thread_id* has an active (not-yet-expired) snooze."""
    now = datetime.now(timezone.utc)
    for e in load_snoozes():
        if e["thread_id"] == thread_id and e["account"] == account:
            try:
                until = datetime.fromisoformat(e["until_iso"])
                if until > now:
                    return True
            except Exception:
                pass
    return False


def due_snoozes() -> list[dict[str, Any]]:
    """Return snooze entries whose until_iso has passed (ready to re-surface)."""
    now = datetime.now(timezone.utc)
    out = []
    for e in load_snoozes():
        try:
            until = datetime.fromisoformat(e["until_iso"])
            if until <= now:
                out.append(e)
        except Exception:
            pass
    return out


def remove_snooze(thread_id: str, account: str) -> None:
    """Delete the snooze entry for *thread_id* / *account* (if any)."""
    with _locked("r+") as fh:
        raw = fh.read().strip()
        entries: list[dict] = json.loads(raw) if raw else []
        entries = [e for e in entries if not (e["thread_id"] == thread_id and e["account"] == account)]
        _save(entries, fh)
