# mail-triage

A personal automation for multi-account Gmail triage, AI-drafted replies in your
own voice, and interactive Slack review — with a reversible inbox-zero sweep.

## What it does

Every morning at **07:00**, a launchd job runs `run.sh`, which:

1. **Triages** each authenticated account's last-day unread inbox. A headless Claude
   (Sonnet) orchestrator fans out **one Haiku subagent per account** in parallel.
   Each thread is classified with a unified label taxonomy; noise is archived.

2. **Emails a combined digest** to your primary account — every ⚡ Action item across
   all accounts in one place, so nothing is missed.

3. **Runs a 14-day catch-up sweep** across all accounts, finds threads you never
   replied to, asks Haiku to filter for genuinely important ones, and posts them to
   Slack.

4. **Drafts replies** for primary-account ⚡ Action items (Haiku), saves them as real
   Gmail drafts, and **posts interactive Slack cards** for review.

An **always-on Slack listener** (Socket Mode, no public URL) handles the review cards:

| Button | Action |
|--------|--------|
| ✅ Send | Sends the Gmail draft |
| ✏️ Edit | Opens a modal to edit the reply, then sends |
| 🗑 Discard | Deletes the draft |
| 🔄 Regenerate | Re-drafts with optional steer ("make it shorter") |
| ⏰ Snooze | Collapses the card for 24 hours |

Missed-item cards offer: **Draft reply / Archive / Snooze / Keep in inbox / Open in Gmail**.

---

## Architecture at a glance

```
launchd (07:00)
  └─ run.sh
       ├─ claude (Sonnet) → TRIAGE.md → Haiku ×N  (classify + label)
       ├─ missed_sweep.py → catchup.py ×N          (14-day catch-up)
       ├─ gen_drafts.py                             (draft replies)
       ├─ build_briefing.py                         (briefing data)
       └─ app.py brief / post / post-missed         (Slack cards)

launchd (KeepAlive)
  └─ slack_app/daemon.sh
       └─ app.py (Socket Mode listener — handles button clicks)
```

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full data flow.

---

## Label taxonomy

Applied identically across every account.

**Priority** (exactly one per thread):
- **⚡ Action** — real person awaiting your reply, decision, or scheduling. Kept in inbox.
- **📬 FYI** — worth seeing, no action needed. Kept in inbox.
- **🔻 Low** — noise: newsletters, cold outreach, marketing. Archived automatically.

**Category** (zero or more):
- **💰 Finance** · **🤝 Clients** · **📅 Meetings** · **🔔 Services**

---

## Prerequisites

| Tool | Install |
|------|---------|
| macOS | Any recent version |
| `gws` | `npm install -g @google-workspace/cli` |
| `claude` CLI | `npm install -g @anthropic-ai/claude-code` |
| `python3` | `brew install python3` |
| `jq` | `brew install jq` (optional, useful for debugging) |
| A Slack app | Create via `slack_app/manifest.yml` (Socket Mode) |

Each Gmail account must be authenticated with `gws` using OAuth (headless-safe via
the file keyring backend). See [docs/SETUP.md](docs/SETUP.md) for step-by-step auth.

---

## Quick start

```bash
# 1. Clone
git clone https://github.com/YOUR_ORG/mail-triage.git ~/mail-triage
cd ~/mail-triage

# 2. Check deps + create venv + scaffold config files
bash setup.sh

# 3. Authenticate each account with gws (see docs/SETUP.md)

# 4. Edit accounts.json with your accounts
# 5. Edit slack_app/config.env with your Slack tokens

# 6. Install launchd agents (daily triage + always-on Slack listener)
bash deploy/install.sh

# 7. Test immediately (optional)
bash run.sh && tail -f logs/latest.log
```

See [docs/SETUP.md](docs/SETUP.md) for the full step-by-step.

---

## Configuration

### accounts.json

```json
[
  { "slug": "work",     "email": "me@company.com",   "config_dir": "~/.config/gws" },
  { "slug": "personal", "email": "me@gmail.com",     "config_dir": "~/.config/gws/accounts/personal" }
]
```

The **first entry is the primary account** — digests are sent from/to it and drafts
are generated for it.

### slack_app/config.env

```bash
SLACK_BOT_TOKEN=xoxb-...          # from api.slack.com → OAuth & Permissions
SLACK_APP_TOKEN=xapp-...          # from Basic Information → App-Level Tokens
SLACK_REVIEW_CHANNEL=U01234567    # your Slack user ID (for DMs) or channel ID
```

### Environment variable overrides

| Variable | Default | Purpose |
|----------|---------|---------|
| `MAIL_TRIAGE_DIR` | repo root (computed) | Override the repo root |
| `MAIL_TRIAGE_PYTHON` | `python3` from PATH | Override the Python binary |
| `QUEUE_PATH` | `$MAIL_TRIAGE_DIR/drafts/queue.json` | Override queue file |
| `BRIEFING_PATH` | `$MAIL_TRIAGE_DIR/drafts/briefing.json` | Override briefing file |
| `CLAUDE_BIN` | `claude` | Override Claude CLI binary |
| `GWS_BIN` | `gws` | Override gws binary |

---

## Tuning the AI

### knowledge/drewl.md

This file is the AI's context: who you are, what your business does, which senders
are genuine contacts vs cold outreach, and how to draft replies in your voice.
**Edit this file** before first run — the quality of triage and drafts depends on it.

### TRIAGE.md

The Claude orchestrator prompt. Contains the label classification rules (what counts
as ⚡ Action vs 📬 FYI vs 🔻 Low). Edit the rules here to tune classification.

---

## Scheduling

| Agent | When | What |
|-------|------|------|
| `com.drewl.mailtriage.plist` | Daily 07:00 | Full morning pipeline |
| `com.drewl.maildraftreview.plist` | Always-on (KeepAlive) | Slack listener |

Install/reload via `bash deploy/install.sh`. The templates in `deploy/` work for any
clone location — `__MAIL_TRIAGE_DIR__` is substituted at install time.

---

## Inbox-zero tools

```bash
# Dry-run (reports what would be archived, changes nothing)
python3 lib/inbox_zero.py ~/.config/gws

# Execute (archives noise, adds 🗄️ Auto-Archived recovery label)
python3 lib/inbox_zero.py ~/.config/gws --execute

# Undo (restores everything tagged with the recovery label)
python3 lib/undo_inbox_zero.py ~/.config/gws --execute
```

**Nothing is ever deleted.** Archived mail stays in All Mail, fully searchable.

---

## Safety notes

- **Nothing is ever deleted.** Archiving only removes the INBOX label.
- **No email is sent without you.** Drafts are created in Gmail but only sent when
  you click Send in Slack.
- **Fully reversible.** `undo_inbox_zero.py` restores everything with one command.
- **Tokens stay on your machine.** `config.env` is gitignored. gws OAuth tokens are
  stored in `~/.config/gws/`, outside this repo.

---

## Layout

```
config.sh             Shell config (repo root, python bin, derived paths)
config.py             Python config (same, used by lib/ and slack_app/)
run.sh                Morning runner (launchd-triggered)
setup.sh              First-time setup script
TRIAGE.md             Claude orchestrator prompt + classification rules
accounts.json         Account registry (email + gws config dir per account)
knowledge/drewl.md    AI context: who you are + reply boundaries
lib/
  config.py → config  (imported via ROOT-relative path)
  ensure_labels.sh    Idempotent taxonomy creation per account
  fetch_inbox.sh      Compact JSON of recent unread inbox threads
  apply.sh            Apply/remove labels on a thread
  gen_drafts.py       Draft replies for ⚡ Action items → Gmail drafts → queue
  draft_one.py        Draft a reply for a single thread (used by Slack button)
  draftutil.py        Create / send / discard / update-send Gmail reply drafts
  context.py          Context gathering for AI drafts (thread + history + profile)
  catchup.py          Per-account missed-items finder
  missed_sweep.py     Parallel missed-sweep orchestrator + digest emailer
  build_briefing.py   Build drafts/briefing.json for the Slack morning card
  inbox_zero.py       Reversible bulk-archive sweep
  undo_inbox_zero.py  Undo inbox_zero (restore from recovery label)
  verify_archive.py   AI safety check before inbox_zero --execute
  test_gate.py        Ad-hoc draft gate tester
  send_draft.sh       Thin wrapper: draftutil send
  discard_draft.sh    Thin wrapper: draftutil discard
  update_and_send_draft.sh  Thin wrapper: draftutil update-send
slack_app/
  app.py              Slack Bolt (Socket Mode) review app
  briefing.py         Morning briefing card builder
  review_queue.py     Concurrency-safe queue.json helpers
  snooze_store.py     fcntl-locked snooze store
  _regen_worker.py    Draft regeneration subprocess worker
  manifest.yml        Slack app manifest (create the app from this)
  daemon.sh           Sources config.env, starts the listener
  set_tokens.sh       Helper: save Slack tokens into config.env
  config.env.example  Template — copy to config.env and fill in tokens
deploy/
  com.drewl.mailtriage.plist.template      launchd plist template (daily triage)
  com.drewl.maildraftreview.plist.template launchd plist template (Slack listener)
  install.sh          Fills templates and loads agents into ~/Library/LaunchAgents
docs/
  SETUP.md            Step-by-step setup guide
  ARCHITECTURE.md     Component diagram + data flow
drafts/               Runtime state (gitignored)
logs/                 Run logs (gitignored)
```
