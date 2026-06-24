"""
briefing.py — Build and post the morning briefing Block Kit message.

Reads /Users/user/mail-triage/drafts/briefing.json (written by run.sh before
this is called) and the draft queue (for pending-draft count) to produce a
single rich summary card posted to the review channel.

briefing.json schema
--------------------
{
  "generated_at": "<ISO-8601 UTC>",          # when run.sh wrote this file
  "accounts": [
    {
      "label": "you@example.com",            # human-readable label
      "inbox_count": 12,                     # total inbox messages (optional)
      "action_count": 3,                     # ⚡ Action label count (optional)
      "missed_count": 2                      # missed items surfaced this run (optional)
    }
  ],
  "missed_total": 4,                         # sum across all accounts (optional)
  "drafts_generated": 2                      # how many new drafts gen_drafts produced (optional)
}

All fields are optional — the briefing degrades gracefully if the file is
missing, empty, or partially populated.
"""

import json
import logging
import os
import sys
from datetime import datetime, timezone

import review_queue as q

log = logging.getLogger("mail_triage")

# Resolve config.py from repo root (one level up from slack_app/).
_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = os.path.dirname(_HERE)
sys.path.insert(0, _ROOT)
import config as _cfg  # noqa: E402

BRIEFING_PATH = os.environ.get("BRIEFING_PATH", _cfg.BRIEFING_PATH)


def _load_briefing() -> dict:
    """Load briefing.json; return empty dict on any error."""
    if not os.path.exists(BRIEFING_PATH):
        return {}
    try:
        with open(BRIEFING_PATH, encoding="utf-8") as fh:
            raw = fh.read().strip()
        return json.loads(raw) if raw else {}
    except Exception as exc:
        log.warning("Could not load briefing.json: %s", exc)
        return {}


def _weekday_label() -> str:
    """Return e.g. 'Monday 23 Jun'."""
    now = datetime.now(timezone.utc)
    return now.strftime("%A %-d %b")


def build_briefing_blocks() -> list[dict]:
    """Return Block Kit blocks for the morning briefing card."""
    data = _load_briefing()
    accounts: list[dict] = data.get("accounts", [])
    missed_total: int = data.get("missed_total", 0)
    drafts_generated: int = data.get("drafts_generated", 0)

    # Count pending drafts from the live queue (most accurate source of truth).
    all_items = q.load_queue()
    pending_drafts = sum(1 for it in all_items if it.get("status") == "pending")

    # Summary line numbers.
    action_total = sum(a.get("action_count", 0) for a in accounts)
    # Fallback: if no action_count in briefing, use drafts_generated as proxy.
    if action_total == 0 and drafts_generated:
        action_total = drafts_generated

    blocks: list[dict] = [
        {
            "type": "header",
            "text": {
                "type": "plain_text",
                "text": f"🌅 Good morning, Tayo — {_weekday_label()}",
                "emoji": True,
            },
        },
        {
            "type": "section",
            "text": {
                "type": "mrkdwn",
                "text": (
                    f"⚡ *{action_total}* need action  ·  "
                    f"✍️ *{pending_drafts}* draft{'s' if pending_drafts != 1 else ''} ready  ·  "
                    f"⏰ *{missed_total}* you may have missed"
                ),
            },
        },
    ]

    # Per-account detail rows (only when we have data).
    if accounts:
        account_lines = []
        for acct in accounts:
            label = acct.get("label", "unknown")
            parts = []
            if "inbox_count" in acct:
                parts.append(f"{acct['inbox_count']} inbox")
            if "action_count" in acct:
                parts.append(f"{acct['action_count']} ⚡")
            if "missed_count" in acct and acct["missed_count"]:
                parts.append(f"{acct['missed_count']} missed")
            detail = "  ·  ".join(parts) if parts else "no data"
            account_lines.append(f"📥 *{label}* — {detail}")

        blocks.append({"type": "divider"})
        blocks.append(
            {
                "type": "section",
                "text": {
                    "type": "mrkdwn",
                    "text": "\n".join(account_lines),
                },
            }
        )

    # Timestamp footer.
    ts_label = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    blocks.append(
        {
            "type": "context",
            "elements": [
                {"type": "mrkdwn", "text": f"Generated {ts_label}"}
            ],
        }
    )

    return blocks


def post_briefing(client, channel: str) -> str | None:
    """Post the morning briefing to *channel*. Returns the message ts, or None on error."""
    from slack_sdk.errors import SlackApiError

    blocks = build_briefing_blocks()
    try:
        resp = client.chat_postMessage(
            channel=channel,
            text="🌅 Good morning — daily mail briefing",
            blocks=blocks,
            icon_url=_cfg.BOT_ICON_URL,
            username=_cfg.BOT_USERNAME,
        )
        ts = resp["ts"]
        log.info("Posted morning briefing → ts=%s", ts)
        return ts
    except SlackApiError as exc:
        log.error("Failed to post briefing: %s", exc.response["error"])
        return None
