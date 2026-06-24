# Setup Guide

Step-by-step first-time setup on a fresh Mac.

---

## 1. Install dependencies

```bash
# Node.js (needed for gws and claude CLI)
brew install node

# Google Workspace CLI (gws) — the official Google CLI
npm install -g @googleworkspace/cli
gws --version

# Claude Code CLI
npm install -g @anthropic-ai/claude-code
claude    # completes login on first run

# Python 3
brew install python3

# Optional: useful for debugging log JSON
brew install jq
```

---

## 2. Clone and run setup

```bash
git clone https://github.com/drewling/zero.git ~/zero
cd ~/zero
bash setup.sh
```

`setup.sh` checks that all dependencies are present and creates `logs/` and `drafts/`.

---

## 3. Create a Google Cloud OAuth client

zero uses your own OAuth credentials — no shared app, no third-party access.

1. Go to [console.cloud.google.com](https://console.cloud.google.com/)
2. Select (or create) a project.
3. **APIs & Services → Enable APIs** → search for **Gmail API** → Enable it.
4. **APIs & Services → Credentials → Create Credentials → OAuth client ID**
   - Application type: **Desktop app**
   - Name: anything (e.g. "zero")
5. Download the JSON — this is your `client_secret.json`.

When you launch zero for the first time, the onboarding screen prompts you to paste this JSON. It stays on your Mac; it is never transmitted anywhere.

---

## 4. Configure accounts.json

```bash
cp accounts.json.example accounts.json
```

Edit `accounts.json`:

```json
[
  {
    "slug":       "work",
    "email":      "me@company.com",
    "config_dir": "~/.config/gws"
  },
  {
    "slug":       "personal",
    "email":      "me@gmail.com",
    "config_dir": "~/.config/gws/accounts/personal"
  }
]
```

- `slug` — short identifier (used in logs; no spaces)
- `email` — the Gmail address for this account
- `config_dir` — where `gws` stores OAuth tokens for this account

The **first entry is the primary account**.

---

## 5. Authenticate each account with gws

The `GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file` env var is required — without it gws
tries to use the system keychain and may fail in headless or launchd contexts.

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

Verify each account:
```bash
GOOGLE_WORKSPACE_CLI_CONFIG_DIR=~/.config/gws \
  GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file \
  gws gmail users getProfile --params '{"userId":"me"}' 2>/dev/null | grep emailAddress
```

---

## 6. Launch the app

```bash
./bin/zero app
```

On first launch, zero's onboarding walks you through pasting your OAuth client JSON
and connecting each Gmail account.

---

## 7. Optional: tune the knowledge file

`knowledge/profile.example.md` is the AI's context for drafting replies in your
voice. Copy and edit it:

```bash
cp knowledge/profile.example.md knowledge/profile.md
# edit knowledge/profile.md with your name, role, and tone
```

Per-account files at `knowledge/<slug>.md` are also supported. These files are
gitignored and stay on your machine.

---

## 8. Schedule daily triage

```bash
./bin/zero schedule
```

This registers a launchd agent that runs the keeper at 07:00 every morning.

---

## Troubleshooting

### gws returns empty or auth errors

- Make sure `GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file` is set — this is the most
  common cause of silent auth failures.
- Re-run `gws auth login` for the affected account.
- Check the `config_dir` path in `accounts.json` is correct.

### launchd job not running

```bash
launchctl list | grep drewl
cat logs/latest.log
```

Verify `run.sh` is executable: `chmod +x run.sh`

### PATH issues in launchd

`config.sh` prepends common Homebrew, nvm, and `~/.local/bin` paths. If your tools
live elsewhere, add them to the `_mt_prepend` block in `config.sh`.
