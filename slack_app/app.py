"""
app.py — Slack Bolt / Socket Mode app for reviewing AI-drafted email replies.

Usage:
    python app.py               # Start the Socket Mode listener (always-on daemon)
    python app.py post          # Post any pending, un-posted drafts then exit
    python app.py brief         # Post the morning briefing card then exit
    python app.py post-missed <missed_json_file>
                                # Post one card per missed item then exit

Environment variables (load via config.env or export before running):
    SLACK_BOT_TOKEN       xoxb- bot token
    SLACK_APP_TOKEN       xapp- app-level token (Socket Mode)
    SLACK_REVIEW_CHANNEL  channel ID (C…) or DM user ID (U…)
"""

import base64
import json
import logging
import os
import subprocess
import sys
from datetime import datetime, timezone

from slack_bolt import App
from slack_bolt.adapter.socket_mode import SocketModeHandler
from slack_sdk import WebClient
from slack_sdk.errors import SlackApiError

import review_queue as q
import snooze_store as sn

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
log = logging.getLogger("mail_triage")

# ---------------------------------------------------------------------------
# Helper paths — resolved via config.py (repo-relative, not hardcoded)
# ---------------------------------------------------------------------------

_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = os.path.dirname(_HERE)
sys.path.insert(0, _ROOT)
import config as _cfg  # noqa: E402

LIB_DIR = _cfg.LIB_DIR
SEND_SCRIPT             = os.path.join(LIB_DIR, "send_draft.sh")
DISCARD_SCRIPT          = os.path.join(LIB_DIR, "discard_draft.sh")
UPDATE_AND_SEND_SCRIPT  = os.path.join(LIB_DIR, "update_and_send_draft.sh")
DRAFT_ONE_SCRIPT        = os.path.join(LIB_DIR, "draft_one.py")
APPLY_SH                = os.path.join(LIB_DIR, "apply.sh")

PYTHON = sys.executable  # Use the same interpreter we're running under.

# ---------------------------------------------------------------------------
# Slack App initialisation
# ---------------------------------------------------------------------------

app = App(token=os.environ["SLACK_BOT_TOKEN"])


def _target_channel() -> str:
    """Return the channel / IM conversation to post into.

    If SLACK_REVIEW_CHANNEL starts with 'U', it's a user ID — open (or reuse)
    a DM conversation and return its channel ID.
    """
    raw = os.environ["SLACK_REVIEW_CHANNEL"]
    if raw.startswith("U"):
        client: WebClient = app.client
        resp = client.conversations_open(users=[raw])
        return resp["channel"]["id"]
    return raw


# ---------------------------------------------------------------------------
# Block Kit builders — draft cards
# ---------------------------------------------------------------------------

def _build_draft_blocks(item: dict) -> list[dict]:
    """Build the Block Kit message for a pending draft card."""
    snippet  = item.get("original_snippet", "").strip()
    reply    = item.get("reply_body", "").strip()
    item_id  = item["id"]
    why      = item.get("why", "").strip()
    account  = item.get("account_label", "")
    known    = "known contact" if item.get("has_history") else "no prior history"

    context_bits = [f"*To:* {item.get('to', '—')}  ·  *Re:* {item.get('subject', '—')}"]
    meta_bits = []
    if account:
        meta_bits.append(f"📥 {account}")
    meta_bits.append(known)
    if why:
        meta_bits.append(f"_why:_ {why}")

    return [
        {
            "type": "header",
            "text": {"type": "plain_text", "text": "✉️ Draft reply", "emoji": True},
        },
        {
            "type": "context",
            "elements": [
                {"type": "mrkdwn", "text": context_bits[0]},
                {"type": "mrkdwn", "text": "  ·  ".join(meta_bits)},
            ],
        },
        {"type": "divider"},
        {
            "type": "section",
            "text": {
                "type": "mrkdwn",
                "text": f"*Original message:*\n>{snippet.replace(chr(10), chr(10) + '>')}",
            },
        },
        {
            "type": "section",
            "text": {
                "type": "mrkdwn",
                "text": f"*Proposed reply:*\n```{reply}```",
            },
        },
        {
            "type": "actions",
            "elements": [
                {
                    "type": "button",
                    "text": {"type": "plain_text", "text": "✅ Send", "emoji": True},
                    "style": "primary",
                    "action_id": "send_draft",
                    "value": item_id,
                },
                {
                    "type": "button",
                    "text": {"type": "plain_text", "text": "✏️ Edit", "emoji": True},
                    "action_id": "edit_draft",
                    "value": item_id,
                },
                {
                    "type": "button",
                    "text": {"type": "plain_text", "text": "\U0001f5d1 Discard", "emoji": True},
                    "style": "danger",
                    "action_id": "discard_draft",
                    "value": item_id,
                },
                {
                    "type": "button",
                    "text": {"type": "plain_text", "text": "🔄 Regenerate", "emoji": True},
                    "action_id": "regenerate_draft",
                    "value": item_id,
                },
                {
                    "type": "button",
                    "text": {"type": "plain_text", "text": "⏰ Snooze", "emoji": True},
                    "action_id": "snooze_draft",
                    "value": item_id,
                },
            ],
        },
    ]


def _sent_blocks(label: str = "Sent") -> list[dict]:
    """Replacement blocks shown after a draft is sent."""
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    return [
        {
            "type": "context",
            "elements": [
                {"type": "mrkdwn", "text": f"✅ *{label}* — {ts}"}
            ],
        }
    ]


def _discarded_blocks() -> list[dict]:
    """Replacement blocks shown after a draft is discarded."""
    return [
        {
            "type": "context",
            "elements": [
                {"type": "mrkdwn", "text": "\U0001f5d1 *Discarded*"}
            ],
        }
    ]


def _snoozed_blocks() -> list[dict]:
    """Replacement blocks shown after a draft or missed item is snoozed."""
    return [
        {
            "type": "context",
            "elements": [{"type": "mrkdwn", "text": "⏰ *Snoozed* — will re-surface next run"}],
        }
    ]


def _failed_blocks(original_blocks: list[dict], error_msg: str) -> list[dict]:
    """Prepend an error notice to the original card blocks."""
    return [
        {
            "type": "section",
            "text": {"type": "mrkdwn", "text": f"⚠️ *Send failed:* {error_msg}"},
        },
        *original_blocks,
    ]


# ---------------------------------------------------------------------------
# Block Kit builders — missed-item cards
# ---------------------------------------------------------------------------

def _build_missed_blocks(item: dict) -> list[dict]:
    """Build the Block Kit card for a single missed item."""
    frm      = item.get("from", "—")
    subject  = item.get("subject", "(no subject)")
    age      = item.get("age_days")
    why      = item.get("why", "")
    thread_id  = item.get("thread_id", "")
    config_dir = item.get("account_config_dir", "")
    acct_label = item.get("account_label", config_dir)

    age_str = f"{age}d ago" if age is not None else ""
    meta_parts = [f"📥 {acct_label}"] if acct_label else []
    if age_str:
        meta_parts.append(age_str)
    if why:
        meta_parts.append(f"_why:_ {why}")

    # Encode thread_id + config_dir into the button value (pipe-delimited).
    encoded_value = _encode_missed_value(config_dir, thread_id, acct_label)

    gmail_url = f"https://mail.google.com/mail/u/0/#all/{thread_id}"

    blocks: list[dict] = [
        {
            "type": "header",
            "text": {"type": "plain_text", "text": "⏰ You may have missed", "emoji": True},
        },
        {
            "type": "section",
            "text": {
                "type": "mrkdwn",
                "text": f"*From:* {frm}\n*Re:* {subject}",
            },
        },
    ]

    if meta_parts:
        blocks.append(
            {
                "type": "context",
                "elements": [{"type": "mrkdwn", "text": "  ·  ".join(meta_parts)}],
            }
        )

    blocks.append({"type": "divider"})
    blocks.append(
        {
            "type": "actions",
            "elements": [
                {
                    "type": "button",
                    "text": {"type": "plain_text", "text": "✍️ Draft reply", "emoji": True},
                    "style": "primary",
                    "action_id": "draft_for_missed",
                    "value": encoded_value,
                },
                {
                    "type": "button",
                    "text": {"type": "plain_text", "text": "📥 Archive", "emoji": True},
                    "action_id": "archive_item",
                    "value": encoded_value,
                },
                {
                    "type": "button",
                    "text": {"type": "plain_text", "text": "⏰ Snooze 1 day", "emoji": True},
                    "action_id": "snooze_item",
                    "value": encoded_value,
                },
                {
                    "type": "button",
                    "text": {"type": "plain_text", "text": "✓ Keep in inbox", "emoji": True},
                    "action_id": "keep_item",
                    "value": encoded_value,
                },
                {
                    "type": "button",
                    "text": {"type": "plain_text", "text": "📬 Open in Gmail", "emoji": True},
                    "url": gmail_url,
                    "action_id": "open_gmail_missed",
                },
            ],
        }
    )

    return blocks


def _dismissed_missed_blocks(reason: str) -> list[dict]:
    """Compact replacement for a dismissed / actioned missed card."""
    return [
        {
            "type": "context",
            "elements": [{"type": "mrkdwn", "text": reason}],
        }
    ]


# ---------------------------------------------------------------------------
# Missed-item value encoding helpers
# ---------------------------------------------------------------------------
# We need to pass config_dir + thread_id + account_label through a single
# button value string.  We JSON-encode a small dict and base64 it.

def _encode_missed_value(config_dir: str, thread_id: str, account_label: str) -> str:
    payload = {"c": config_dir, "t": thread_id, "l": account_label}
    return base64.b64encode(json.dumps(payload).encode()).decode()


def _decode_missed_value(value: str) -> tuple[str, str, str]:
    """Return (config_dir, thread_id, account_label)."""
    payload = json.loads(base64.b64decode(value).decode())
    return payload["c"], payload["t"], payload.get("l", "")


# ---------------------------------------------------------------------------
# Queue posting
# ---------------------------------------------------------------------------

def post_pending() -> None:
    """Post every pending, un-posted draft to Slack and record the ts.

    Safe to call multiple times — already-posted items are skipped.
    """
    channel = _target_channel()
    client: WebClient = app.client

    items = q.pending_unposted()
    if not items:
        log.info("No pending un-posted drafts.")
        return

    for item in items:
        blocks = _build_draft_blocks(item)
        try:
            resp = client.chat_postMessage(
                channel=channel,
                text=f"Draft reply: {item.get('subject', '(no subject)')}",
                blocks=blocks,
            )
            ts = resp["ts"]
            q.update_item(item["id"], slack_ts=ts, slack_channel=channel)
            log.info("Posted item %s → ts=%s", item["id"], ts)
        except SlackApiError as exc:
            log.error("Failed to post item %s: %s", item["id"], exc.response["error"])


# ---------------------------------------------------------------------------
# Missed-items posting (subcommand: post-missed <json_file>)
# ---------------------------------------------------------------------------

def post_missed(missed_json_path: str) -> None:
    """Post one Slack card per missed item in the JSON file.

    The JSON file must contain a list of objects with at least:
      account_config_dir, account_label, thread_id, from, subject, age_days, why

    Already-snoozed items are silently skipped.  Cards are not deduplicated
    across runs — the orchestrator is responsible for not calling this twice with
    the same file.
    """
    try:
        with open(missed_json_path, encoding="utf-8") as fh:
            items: list[dict] = json.load(fh)
    except Exception as exc:
        log.error("post-missed: could not read %s: %s", missed_json_path, exc)
        return

    if not isinstance(items, list):
        log.error("post-missed: expected a JSON array in %s", missed_json_path)
        return

    channel = _target_channel()
    client: WebClient = app.client

    for item in items:
        thread_id  = item.get("thread_id", "")
        config_dir = item.get("account_config_dir", "")

        if not thread_id or not config_dir:
            log.warning("post-missed: skipping item missing thread_id or account_config_dir: %s", item)
            continue

        if sn.is_snoozed(thread_id, config_dir):
            log.info("post-missed: skipping snoozed thread %s", thread_id)
            continue

        blocks = _build_missed_blocks(item)
        try:
            resp = client.chat_postMessage(
                channel=channel,
                text=f"Missed: {item.get('subject', '(no subject)')} from {item.get('from', '?')}",
                blocks=blocks,
            )
            log.info("Posted missed card for thread %s → ts=%s", thread_id, resp["ts"])
        except SlackApiError as exc:
            log.error("Failed to post missed item %s: %s", thread_id, exc.response["error"])


# ---------------------------------------------------------------------------
# Action handlers — existing draft card actions (unchanged behaviour)
# ---------------------------------------------------------------------------

@app.action("send_draft")
def handle_send_draft(ack, body, client: WebClient):
    """Send the Gmail draft via the shell helper. Uses claim_for_send to prevent
    double-send on double-click."""
    ack()
    item_id = body["actions"][0]["value"]

    # Claim the item atomically; bail if it's already been claimed / sent.
    item = q.claim_for_send(item_id)
    if item is None:
        log.warning("send_draft: item %s already claimed or not pending — ignoring duplicate", item_id)
        return

    channel = body["container"]["channel_id"]
    ts      = body["container"]["message_ts"]

    result = subprocess.run(
        [SEND_SCRIPT, item["account_config_dir"], item["draft_id"]],
        capture_output=True, text=True, timeout=60,
    )

    if result.returncode == 0:
        q.update_item(item_id, status="sent")
        try:
            client.chat_update(channel=channel, ts=ts, text="✅ Draft sent",
                               blocks=_sent_blocks("Sent"))
        except SlackApiError as exc:
            log.error("chat_update after send failed: %s", exc.response["error"])
    else:
        # Send failed — reset to pending so the user can retry.
        q.update_item(item_id, status="pending")
        err = (result.stderr or result.stdout or "unknown error").strip()
        log.error("send_draft script failed for %s: %s", item_id, err)
        refreshed = q.get_item(item_id) or item
        try:
            client.chat_update(channel=channel, ts=ts, text="⚠️ Send failed",
                               blocks=_failed_blocks(_build_draft_blocks(refreshed), err))
        except SlackApiError as exc:
            log.error("chat_update after send failure: %s", exc.response["error"])


@app.action("edit_draft")
def handle_edit_draft(ack, body, client: WebClient):
    """Open a modal pre-filled with the current reply body for editing."""
    ack()
    item_id = body["actions"][0]["value"]
    item = q.get_item(item_id)
    if item is None:
        log.warning("edit_draft: unknown item %s", item_id)
        return

    trigger_id = body["trigger_id"]
    reply_body = item.get("reply_body", "")

    try:
        client.views_open(
            trigger_id=trigger_id,
            view={
                "type": "modal",
                "callback_id": "edit_modal",
                "private_metadata": item_id,
                "title": {"type": "plain_text", "text": "Edit reply"},
                "submit": {"type": "plain_text", "text": "Save & Send"},
                "close": {"type": "plain_text", "text": "Cancel"},
                "blocks": [
                    {
                        "type": "input",
                        "block_id": "edit_block",
                        "label": {"type": "plain_text", "text": "Reply body"},
                        "element": {
                            "type": "plain_text_input",
                            "action_id": "edit_input",
                            "multiline": True,
                            "initial_value": reply_body,
                        },
                    }
                ],
            },
        )
    except SlackApiError as exc:
        log.error("views_open failed: %s", exc.response["error"])


@app.action("discard_draft")
def handle_discard_draft(ack, body, client: WebClient):
    """Discard the Gmail draft via the shell helper."""
    ack()
    item_id = body["actions"][0]["value"]
    item = q.get_item(item_id)
    if item is None:
        log.warning("discard_draft: unknown item %s", item_id)
        return

    channel = body["container"]["channel_id"]
    ts      = body["container"]["message_ts"]

    result = subprocess.run(
        [DISCARD_SCRIPT, item["account_config_dir"], item["draft_id"]],
        capture_output=True, text=True, timeout=60,
    )

    if result.returncode == 0:
        q.update_item(item_id, status="discarded")
        try:
            client.chat_update(channel=channel, ts=ts, text="\U0001f5d1 Draft discarded",
                               blocks=_discarded_blocks())
        except SlackApiError as exc:
            log.error("chat_update after discard: %s", exc.response["error"])
    else:
        err = (result.stderr or result.stdout or "unknown error").strip()
        log.error("discard_draft script failed for %s: %s", item_id, err)
        # Keep the card fully actionable so the user can retry.
        refreshed = q.get_item(item_id) or item
        try:
            client.chat_update(channel=channel, ts=ts, text="⚠️ Discard failed",
                               blocks=_failed_blocks(_build_draft_blocks(refreshed), err))
        except SlackApiError as exc:
            log.error("chat_update after discard failure: %s", exc.response["error"])


# ---------------------------------------------------------------------------
# Action handlers — new draft card actions
# ---------------------------------------------------------------------------

@app.action("regenerate_draft")
def handle_regenerate_draft(ack, body, client: WebClient):
    """Open a modal for optional steer, then regenerate the draft."""
    ack()
    item_id    = body["actions"][0]["value"]
    item       = q.get_item(item_id)
    if item is None:
        log.warning("regenerate_draft: unknown item %s", item_id)
        return

    trigger_id = body["trigger_id"]
    try:
        client.views_open(
            trigger_id=trigger_id,
            view={
                "type": "modal",
                "callback_id": "regenerate_modal",
                "private_metadata": item_id,
                "title": {"type": "plain_text", "text": "Regenerate draft"},
                "submit": {"type": "plain_text", "text": "Regenerate"},
                "close": {"type": "plain_text", "text": "Cancel"},
                "blocks": [
                    {
                        "type": "input",
                        "block_id": "steer_block",
                        "optional": True,
                        "label": {
                            "type": "plain_text",
                            "text": "Optional steer (leave blank to regenerate as-is)",
                        },
                        "hint": {
                            "type": "plain_text",
                            "text": "e.g. make it warmer / shorter / decline politely",
                        },
                        "element": {
                            "type": "plain_text_input",
                            "action_id": "steer_input",
                            "multiline": False,
                            "placeholder": {
                                "type": "plain_text",
                                "text": "make it shorter / decline politely / …",
                            },
                        },
                    }
                ],
            },
        )
    except SlackApiError as exc:
        log.error("views_open (regenerate) failed: %s", exc.response["error"])


@app.action("snooze_draft")
def handle_snooze_draft(ack, body, client: WebClient):
    """Snooze a draft card for 24 hours — collapse the card, record the snooze."""
    ack()
    item_id = body["actions"][0]["value"]
    item    = q.get_item(item_id)
    if item is None:
        log.warning("snooze_draft: unknown item %s", item_id)
        return

    channel = body["container"]["channel_id"]
    ts      = body["container"]["message_ts"]

    sn.add_snooze(
        thread_id=item.get("thread_id", ""),
        account=item.get("account_config_dir", ""),
        account_label=item.get("account_label", ""),
        hours=24,
        kind="draft",
        item_id=item_id,
        slack_ts=ts,
        slack_channel=channel,
    )
    # Mark the queue item so post_pending skips it.
    q.update_item(item_id, status="snoozed")

    try:
        client.chat_update(channel=channel, ts=ts, text="⏰ Snoozed",
                           blocks=_snoozed_blocks())
    except SlackApiError as exc:
        log.error("chat_update after snooze_draft: %s", exc.response["error"])


# ---------------------------------------------------------------------------
# Action handlers — missed-item card actions
# ---------------------------------------------------------------------------

@app.action("draft_for_missed")
def handle_draft_for_missed(ack, body, client: WebClient):
    """Generate a draft for a missed thread and post it as a new card.

    Runs draft_one.py in a subprocess so it uses the lib/ interpreter and
    environment.  Updates the missed card to show the outcome.
    """
    ack()
    value = body["actions"][0]["value"]
    channel = body["container"]["channel_id"]
    ts      = body["container"]["message_ts"]

    try:
        config_dir, thread_id, account_label = _decode_missed_value(value)
    except Exception as exc:
        log.error("draft_for_missed: bad value: %s", exc)
        return

    # Update the card immediately to show work-in-progress.
    try:
        client.chat_update(
            channel=channel, ts=ts,
            text="✍️ Drafting…",
            blocks=[{"type": "context", "elements": [
                {"type": "mrkdwn", "text": "✍️ *Drafting reply…* please wait"}
            ]}],
        )
    except SlackApiError:
        pass

    try:
        result = subprocess.run(
            [PYTHON, DRAFT_ONE_SCRIPT, config_dir, thread_id, account_label],
            capture_output=True, text=True, timeout=120,
        )
    except subprocess.TimeoutExpired:
        log.error("draft_for_missed: draft_one.py timed out for thread %s", thread_id)
        try:
            client.chat_update(
                channel=channel, ts=ts,
                text="⚠️ Draft timed out",
                blocks=_dismissed_missed_blocks("⚠️ *Draft generation timed out* — try again"),
            )
        except SlackApiError:
            pass
        return

    # Parse the JSON result from draft_one.
    try:
        out = json.loads(result.stdout.strip().splitlines()[-1])
    except Exception:
        out = {"ok": False, "reason": result.stderr.strip() or "no output"}

    if result.returncode != 0 and out.get("ok"):
        # returncode takes precedence — treat non-zero as failure even if JSON says ok.
        out = {"ok": False, "reason": result.stderr.strip() or "non-zero exit"}

    if out.get("ok"):
        # Post the new draft card.
        item_id = out["item_id"]
        item    = q.get_item(item_id)
        if item:
            try:
                resp = client.chat_postMessage(
                    channel=channel,
                    text=f"Draft reply: {item.get('subject', '(no subject)')}",
                    blocks=_build_draft_blocks(item),
                )
                q.update_item(item_id, slack_ts=resp["ts"], slack_channel=channel)
            except SlackApiError as exc:
                log.error("draft_for_missed: post draft card failed: %s", exc.response["error"])

        # Collapse the missed card.
        try:
            client.chat_update(
                channel=channel, ts=ts,
                text="✍️ Draft created",
                blocks=_dismissed_missed_blocks("✍️ *Draft created* — see card below"),
            )
        except SlackApiError as exc:
            log.error("draft_for_missed: collapse missed card failed: %s", exc.response["error"])
    else:
        reason = out.get("reason", "unknown")
        log.info("draft_for_missed: gate said no for %s: %s", thread_id, reason)
        try:
            client.chat_update(
                channel=channel, ts=ts,
                text="No reply needed",
                blocks=_dismissed_missed_blocks(f"🚫 *No draft* — {reason}"),
            )
        except SlackApiError as exc:
            log.error("draft_for_missed: update no-reply card failed: %s", exc.response["error"])


@app.action("archive_item")
def handle_archive_item(ack, body, client: WebClient):
    """Remove INBOX label from the thread (archive it)."""
    ack()
    value   = body["actions"][0]["value"]
    channel = body["container"]["channel_id"]
    ts      = body["container"]["message_ts"]

    try:
        config_dir, thread_id, _ = _decode_missed_value(value)
    except Exception as exc:
        log.error("archive_item: bad value: %s", exc)
        return

    result = subprocess.run(
        [APPLY_SH, config_dir, thread_id, "", "INBOX"],
        capture_output=True, text=True, timeout=30,
    )

    if result.returncode == 0:
        log.info("archive_item: archived thread %s", thread_id)
        try:
            client.chat_update(
                channel=channel, ts=ts,
                text="📥 Archived",
                blocks=_dismissed_missed_blocks("📥 *Archived ✓*"),
            )
        except SlackApiError as exc:
            log.error("chat_update after archive: %s", exc.response["error"])
    else:
        err = (result.stderr or result.stdout or "unknown error").strip()
        log.error("archive_item: apply.sh failed for %s: %s", thread_id, err)
        try:
            client.chat_update(
                channel=channel, ts=ts,
                text="⚠️ Archive failed",
                blocks=_dismissed_missed_blocks(f"⚠️ *Archive failed:* {err}"),
            )
        except SlackApiError as exc:
            log.error("chat_update after archive failure: %s", exc.response["error"])


@app.action("snooze_item")
def handle_snooze_item(ack, body, client: WebClient):
    """Snooze a missed item for 24 hours."""
    ack()
    value   = body["actions"][0]["value"]
    channel = body["container"]["channel_id"]
    ts      = body["container"]["message_ts"]

    try:
        config_dir, thread_id, account_label = _decode_missed_value(value)
    except Exception as exc:
        log.error("snooze_item: bad value: %s", exc)
        return

    sn.add_snooze(
        thread_id=thread_id,
        account=config_dir,
        account_label=account_label,
        hours=24,
        kind="missed",
        slack_ts=ts,
        slack_channel=channel,
    )
    log.info("snooze_item: snoozed thread %s for 24h", thread_id)

    try:
        client.chat_update(
            channel=channel, ts=ts,
            text="⏰ Snoozed",
            blocks=_dismissed_missed_blocks("⏰ *Snoozed* — will re-surface next run"),
        )
    except SlackApiError as exc:
        log.error("chat_update after snooze_item: %s", exc.response["error"])


@app.action("keep_item")
def handle_keep_item(ack, body, client: WebClient):
    """Dismiss the missed-item card without touching the mail."""
    ack()
    channel = body["container"]["channel_id"]
    ts      = body["container"]["message_ts"]

    try:
        client.chat_update(
            channel=channel, ts=ts,
            text="✓ Kept in inbox",
            blocks=_dismissed_missed_blocks("✓ *Kept in inbox*"),
        )
    except SlackApiError as exc:
        log.error("chat_update after keep_item: %s", exc.response["error"])


@app.action("open_gmail_missed")
def handle_open_gmail_missed(ack, body, client: WebClient):
    """No-op ack for the 'Open in Gmail' link button (Slack requires an ack)."""
    ack()


# ---------------------------------------------------------------------------
# Modal submission handlers
# ---------------------------------------------------------------------------

@app.view("edit_modal")
def handle_edit_modal_submission(ack, body, client: WebClient):
    """Handle Save & Send from the edit modal.

    Passes the new body (base64-encoded) to the update_and_send helper,
    then updates queue.json and the original Slack card.
    """
    ack()

    item_id = body["view"]["private_metadata"]

    # Claim the item to prevent double-send.
    item = q.claim_for_send(item_id)
    if item is None:
        log.warning("edit_modal submission: item %s already claimed or not pending — ignoring", item_id)
        return

    new_body = (
        body["view"]["state"]["values"]["edit_block"]["edit_input"]["value"] or ""
    )

    subject_b64 = base64.b64encode(item.get("subject", "").encode()).decode()
    body_b64    = base64.b64encode(new_body.encode()).decode()

    result = subprocess.run(
        [
            UPDATE_AND_SEND_SCRIPT,
            item["account_config_dir"],
            item["draft_id"],
            item["thread_id"],
            item["to"],
            subject_b64,
            body_b64,
        ],
        capture_output=True, text=True, timeout=60,
    )

    channel = item.get("slack_channel")
    ts      = item.get("slack_ts")

    if result.returncode == 0:
        q.update_item(item_id, status="sent", reply_body=new_body)
        if channel and ts:
            try:
                client.chat_update(channel=channel, ts=ts,
                                   text="✅ Draft sent (edited)",
                                   blocks=_sent_blocks("Sent (edited)"))
            except SlackApiError as exc:
                log.error("chat_update after edit+send: %s", exc.response["error"])
    else:
        err = (result.stderr or result.stdout or "unknown error").strip()
        log.error("update_and_send script failed for %s: %s", item_id, err)
        # Reset to pending so the user can retry.
        q.update_item(item_id, status="pending", reply_body=new_body)
        if channel and ts:
            refreshed = q.get_item(item_id) or item
            try:
                client.chat_update(channel=channel, ts=ts,
                                   text="⚠️ Send failed after edit",
                                   blocks=_failed_blocks(_build_draft_blocks(refreshed), err))
            except SlackApiError as exc:
                log.error("chat_update after edit+send failure: %s", exc.response["error"])


@app.view("regenerate_modal")
def handle_regenerate_modal_submission(ack, body, client: WebClient):
    """Regenerate the draft reply, optionally guided by a steer string.

    Calls judge_and_draft with the steer appended to the original prompt
    context, then updates the Gmail draft + queue + Slack card in place.
    """
    ack()

    item_id = body["view"]["private_metadata"]
    item    = q.get_item(item_id)
    if item is None:
        log.warning("regenerate_modal: unknown item %s", item_id)
        return

    steer = (
        (body["view"]["state"]["values"].get("steer_block", {})
         .get("steer_input", {}).get("value")) or ""
    ).strip()

    channel = item.get("slack_channel")
    ts      = item.get("slack_ts")

    # Update card to show progress.
    if channel and ts:
        try:
            client.chat_update(channel=channel, ts=ts,
                               text="🔄 Regenerating…",
                               blocks=[{"type": "context", "elements": [
                                   {"type": "mrkdwn", "text": "🔄 *Regenerating draft…* please wait"}
                               ]}])
        except SlackApiError:
            pass

    # Run regeneration in a subprocess so we can import gen_drafts freely.
    # We pass the steer via an env var to avoid shell quoting issues.
    regen_env = dict(os.environ)
    regen_env["REGEN_STEER"]       = steer
    regen_env["REGEN_ITEM_ID"]     = item_id
    regen_env["REGEN_CONFIG_DIR"]  = item.get("account_config_dir", "")
    regen_env["REGEN_THREAD_ID"]   = item.get("thread_id", "")
    regen_env["REGEN_SUBJECT"]     = item.get("subject", "")
    regen_env["REGEN_TO"]          = item.get("to", "")
    regen_env["REGEN_DRAFT_ID"]    = item.get("draft_id", "")
    regen_env["REGEN_ACCOUNT"]     = item.get("account_label", "")

    regen_script = os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "_regen_worker.py"
    )
    try:
        result = subprocess.run(
            [PYTHON, regen_script],
            capture_output=True, text=True, timeout=120, env=regen_env,
        )
    except subprocess.TimeoutExpired:
        log.error("regenerate: _regen_worker.py timed out for item %s", item_id)
        refreshed = q.get_item(item_id) or item
        if channel and ts:
            try:
                client.chat_update(channel=channel, ts=ts,
                                   text="⚠️ Regeneration timed out",
                                   blocks=_failed_blocks(_build_draft_blocks(refreshed),
                                                         "regeneration timed out — try again"))
            except SlackApiError as exc:
                log.error("chat_update after regen timeout: %s", exc.response["error"])
        return

    try:
        out = json.loads(result.stdout.strip().splitlines()[-1])
    except Exception:
        out = {"ok": False, "reason": result.stderr.strip() or "no output"}

    if result.returncode != 0 and out.get("ok"):
        out = {"ok": False, "reason": result.stderr.strip() or "non-zero exit"}

    if out.get("ok"):
        new_reply = out.get("reply_body", "")
        new_draft_id = out.get("draft_id", item.get("draft_id"))
        q.update_item(item_id, reply_body=new_reply, draft_id=new_draft_id)
        refreshed = q.get_item(item_id) or item
        if channel and ts:
            try:
                client.chat_update(channel=channel, ts=ts,
                                   text=f"🔄 Regenerated: {refreshed.get('subject', '')}",
                                   blocks=_build_draft_blocks(refreshed))
            except SlackApiError as exc:
                log.error("chat_update after regen: %s", exc.response["error"])
    else:
        reason = out.get("reason", "unknown")
        log.error("regenerate failed for %s: %s", item_id, reason)
        refreshed = q.get_item(item_id) or item
        if channel and ts:
            try:
                client.chat_update(channel=channel, ts=ts,
                                   text="⚠️ Regeneration failed",
                                   blocks=_failed_blocks(_build_draft_blocks(refreshed),
                                                         reason))
            except SlackApiError as exc:
                log.error("chat_update after regen failure: %s", exc.response["error"])


# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else None

    if cmd == "post":
        post_pending()

    elif cmd == "brief":
        from briefing import post_briefing
        post_briefing(app.client, _target_channel())

    elif cmd == "post-missed":
        if len(sys.argv) < 3:
            log.error("Usage: app.py post-missed <missed_json_file>")
            sys.exit(1)
        post_missed(sys.argv[2])

    else:
        log.info("Starting Socket Mode listener…")
        handler = SocketModeHandler(app, os.environ["SLACK_APP_TOKEN"])
        handler.start()
