"""config.py — Single source of truth for mail-triage Python configuration.

Import this at the top of any lib/ or slack_app/ module that needs paths:

    import sys, os
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    import config

Or from a module already on the Python path:

    import config

Environment variable overrides:
    MAIL_TRIAGE_DIR    — override the repo root (default: directory of this file)
    MAIL_TRIAGE_PYTHON — override the python binary (default: sys.executable)
    QUEUE_PATH         — override the queue.json path directly
    BRIEFING_PATH      — override the briefing.json path directly
"""
import json
import os
import sys

# ---------------------------------------------------------------------------
# Repo root
# ---------------------------------------------------------------------------

# Allow an explicit override (useful when running from a different cwd).
ROOT = os.environ.get(
    "MAIL_TRIAGE_DIR",
    os.path.dirname(os.path.abspath(__file__)),
)

# ---------------------------------------------------------------------------
# Derived directories (all relative to ROOT)
# ---------------------------------------------------------------------------

LIB_DIR      = os.path.join(ROOT, "lib")
SLACK_APP_DIR = os.path.join(ROOT, "slack_app")
DRAFTS_DIR   = os.path.join(ROOT, "drafts")
LOGS_DIR     = os.path.join(ROOT, "logs")
KNOWLEDGE_DIR = os.path.join(ROOT, "knowledge")

# ---------------------------------------------------------------------------
# Key file paths
# ---------------------------------------------------------------------------

ACCOUNTS_FILE  = os.path.join(ROOT, "accounts.json")
QUEUE_PATH     = os.environ.get("QUEUE_PATH", os.path.join(DRAFTS_DIR, "queue.json"))
BRIEFING_PATH  = os.environ.get("BRIEFING_PATH", os.path.join(DRAFTS_DIR, "briefing.json"))
MISSED_PATH    = os.path.join(DRAFTS_DIR, "missed_today.json")
SNOOZES_PATH   = os.path.join(SLACK_APP_DIR, "snoozes.json")
PROFILE_PATH   = os.path.join(KNOWLEDGE_DIR, "drewl.md")

# ---------------------------------------------------------------------------
# Python binary
# ---------------------------------------------------------------------------

# sys.executable is correct for venv-aware callers.
# Allow an override for the rare case where a subprocess must use a specific binary.
PYTHON_BIN = os.environ.get("MAIL_TRIAGE_PYTHON", sys.executable)

# ---------------------------------------------------------------------------
# Accounts helper
# ---------------------------------------------------------------------------

def load_accounts() -> list[dict]:
    """Return the list of account dicts from accounts.json."""
    with open(ACCOUNTS_FILE, encoding="utf-8") as fh:
        data = json.load(fh)
    if isinstance(data, list):
        return data
    return data.get("accounts", [])


def primary_account() -> dict:
    """Return the first account (primary/digest sender)."""
    accounts = load_accounts()
    if not accounts:
        raise RuntimeError("accounts.json is empty")
    return accounts[0]
