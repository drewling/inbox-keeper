# Mail Draft Review — Slack App

A lightweight Slack bot that surfaces AI-drafted Gmail replies for human review.
Each draft appears as a card with **Send**, **Edit**, and **Discard** buttons.
Everything runs locally on your Mac via Socket Mode — no public URL required.

---

## How it works

1. A separate producer writes draft metadata to `~/mail-triage/drafts/queue.json`.
2. Run `python app.py post` (or trigger it from a cron/launchd job) to post any
   new pending drafts to Slack as interactive cards.
3. The always-on `python app.py` process handles button clicks and modal submissions
   over the persistent Socket Mode WebSocket connection.
4. Shell helpers in `~/mail-triage/lib/` do the actual Gmail work:
   - `send_draft.sh <account_config_dir> <draft_id>`
   - `discard_draft.sh <account_config_dir> <draft_id>`
   - `update_and_send_draft.sh <account_config_dir> <draft_id> <thread_id> <to> <subject_b64> <body_b64>`
     (subject and body are base64-encoded to avoid shell-quoting issues)

---

## Create the Slack App

1. Go to <https://api.slack.com/apps?new_app=1> and choose **From a manifest**.
2. Select your workspace and paste (or upload) the contents of `manifest.yml`.
3. Click **Create**, then **Install to Workspace** and approve the requested scopes.
4. Copy the **Bot User OAuth Token** (`xoxb-…`) from *OAuth & Permissions*.
5. Under *Basic Information → App-Level Tokens*, click **Generate Token and Scopes**,
   add the `connections:write` scope, and copy the token (`xapp-…`).

---

## Configuration

```bash
cp config.env.example config.env
# Edit config.env and fill in SLACK_BOT_TOKEN, SLACK_APP_TOKEN, SLACK_REVIEW_CHANNEL
```

`SLACK_REVIEW_CHANNEL` accepts:
- A channel ID (`C…`) — the bot must be invited to the channel first (`/invite @Mail Draft Review`).
- A user ID (`U…`) — the bot will open a DM with that user.

---

## Installation

```bash
cd ~/mail-triage/slack_app
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

---

## Running

**Start the listener (keeps buttons alive):**
```bash
source config.env
python app.py
```

**Post pending drafts (run from cron or whenever new drafts arrive):**
```bash
source config.env
python app.py post
```

---

## launchd (recommended for always-on Mac daemon)

Create `~/Library/LaunchAgents/com.mailtriage.slackapp.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.mailtriage.slackapp</string>
  <key>ProgramArguments</key>
  <array>
    <string>/Users/YOUR_USERNAME/zero/slack_app/.venv/bin/python</string>
    <string>/Users/YOUR_USERNAME/zero/slack_app/app.py</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>SLACK_BOT_TOKEN</key>
    <string>xoxb-YOUR-TOKEN</string>
    <key>SLACK_APP_TOKEN</key>
    <string>xapp-YOUR-TOKEN</string>
    <key>SLACK_REVIEW_CHANNEL</key>
    <string>C0123456789</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/tmp/mail-triage-slack.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/mail-triage-slack.err</string>
</dict>
</plist>
```

```bash
launchctl load ~/Library/LaunchAgents/com.mailtriage.slackapp.plist
```

---

## File layout

```
slack_app/
├── app.py            # Bolt app — all handlers + post_pending()
├── queue.py          # Concurrency-safe queue.json helpers (fcntl locking)
├── requirements.txt  # slack_bolt, slack_sdk
├── config.env.example
├── manifest.yml      # Paste into api.slack.com to create the Slack app
└── README.md
```
