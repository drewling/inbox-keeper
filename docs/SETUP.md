# Detailed Setup Guide

This guide walks through setting up mail-triage from scratch on a new macOS machine.

## Prerequisites

- macOS (tested on macOS 14+)
- Homebrew: https://brew.sh
- A Slack workspace where you can create an app

---

## 1. Install dependencies

```bash
# Node.js (needed for gws and claude CLI)
brew install node

# Google Workspace CLI (gws)
npm install -g @google-workspace/cli
# Verify:
gws --version

# Claude Code CLI
npm install -g @anthropic-ai/claude-code
# Verify:
claude --version

# Python 3 (usually already on macOS via Homebrew)
brew install python3

# Optional but useful for debugging
brew install jq
```

---

## 2. Clone the repo

```bash
git clone https://github.com/YOUR_ORG/mail-triage.git ~/mail-triage
cd ~/mail-triage
```

The repo root is the only path that matters. Everything else is relative.

---

## 3. Run setup.sh

```bash
bash setup.sh
```

This will:
- Check that all dependencies are installed
- Create `slack_app/venv/` with Python dependencies
- Copy `slack_app/config.env.example` → `slack_app/config.env`
- Create `logs/` and `drafts/` directories

---

## 4. Configure your Gmail accounts

Edit `accounts.json`:

```json
[
  {
    "slug":       "my-work",
    "email":      "me@mycompany.com",
    "config_dir": "~/.config/gws"
  },
  {
    "slug":       "personal",
    "email":      "me@gmail.com",
    "config_dir": "~/.config/gws/accounts/personal"
  }
]
```

- `slug` — short identifier (used in logs, no spaces)
- `email` — the Gmail address for this account
- `config_dir` — where `gws` stores OAuth tokens for this account

The **first entry is the primary account** — triage digests and missed-item emails
are sent from and to this address.

### Authenticate each account with gws

For the primary account:
```bash
GOOGLE_WORKSPACE_CLI_CONFIG_DIR=~/.config/gws \
  GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file \
  gws auth login --scope gmail
```

For additional accounts, point to their config dirs:
```bash
mkdir -p ~/.config/gws/accounts/personal
GOOGLE_WORKSPACE_CLI_CONFIG_DIR=~/.config/gws/accounts/personal \
  GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file \
  gws auth login --scope gmail
```

Verify each account is authenticated:
```bash
GOOGLE_WORKSPACE_CLI_CONFIG_DIR=~/.config/gws \
  GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file \
  gws gmail users getProfile --params '{"userId":"me"}' 2>/dev/null | grep emailAddress
```

---

## 5. Tune the knowledge file

`knowledge/drewl.md` tells the AI who you are, what your business does, and what
counts as genuine mail vs noise. **Edit this file** with your name, role, and
signal-vs-noise boundaries before running triage.

You can also edit `TRIAGE.md` to adjust classification rules.

---

## 6. Set up the Slack app

### Create the Slack app

1. Go to https://api.slack.com/apps → Create New App → From a manifest
2. Use the manifest in `slack_app/manifest.yml` (paste it in YAML mode)
3. Install the app to your workspace

### Get the tokens

- **Bot Token** (`xoxb-...`): Settings → OAuth & Permissions → Bot User OAuth Token
- **App-Level Token** (`xapp-...`): Settings → Basic Information → App-Level Tokens → Generate (scope: `connections:write`)

### Set the target channel

Either a channel ID (starts with `C`) or your user ID (starts with `U`) for DMs.
To get your user ID: in Slack, click your name → View Profile → three-dot menu → Copy member ID.

### Edit config.env

```bash
# slack_app/config.env
SLACK_BOT_TOKEN=xoxb-...
SLACK_APP_TOKEN=xapp-...
SLACK_REVIEW_CHANNEL=U01234567  # your user ID for DMs, or C01234567 for a channel
```

---

## 7. Run setup.sh again to verify

```bash
bash setup.sh
```

All checks should pass (no warnings).

---

## 8. Install launchd agents

```bash
bash deploy/install.sh
```

This creates two agents in `~/Library/LaunchAgents/`:
- `com.drewl.mailtriage.plist` — runs `run.sh` daily at 07:00
- `com.drewl.maildraftreview.plist` — runs the Slack listener (always-on)

To reload after config changes:
```bash
bash deploy/install.sh --reload
```

---

## 9. Test manually

Run a triage immediately (without waiting for 07:00):
```bash
bash run.sh
tail -f logs/latest.log
```

Test the Slack listener:
```bash
cd slack_app
source config.env
./venv/bin/python app.py brief   # post morning briefing
./venv/bin/python app.py post    # post any pending draft cards
```

---

## Troubleshooting

### gws returns empty or auth errors
- Make sure `GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file` is exported
- Re-run `gws auth login` for the affected account
- Check the config_dir path in accounts.json is correct

### launchd job not running
- Check: `launchctl list | grep drewl`
- View logs: `cat logs/launchd-triage.log`
- Verify `run.sh` is executable: `chmod +x run.sh`

### Slack app not receiving events
- Make sure Socket Mode is enabled in the Slack app settings
- Verify `SLACK_APP_TOKEN` starts with `xapp-`
- Check: `logs/launchd-slack.log`

### PATH issues in launchd
`run.sh` exports a full PATH at the top. Edit that PATH line to match your tool
installation paths (e.g. if you use pyenv instead of anaconda, swap the path).
