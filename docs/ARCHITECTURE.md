# Architecture

> **Legacy.** Describes the original Slack-based triage runtime. The current product
> is the zero menu-bar app (Swift shell + local `lib/keeper_server.py` + web
> panel); see the README and PRODUCT.md. This document covers the opt-in Slack pipeline.

## Overview

mail-triage is a personal automation that runs on macOS. It uses three runtimes:
1. A shell script (`run.sh`) orchestrated by launchd
2. Headless Claude (Sonnet as orchestrator, Haiku as subagents)
3. A long-running Slack Bolt Python app in Socket Mode

---

## Component diagram

```
┌──────────────────────────────────────────────────────────────────┐
│  macOS launchd (~/Library/LaunchAgents/)                         │
│                                                                   │
│  ┌─────────────────────┐    ┌─────────────────────────────────┐  │
│  │ com.drewl.mailtriage│    │ com.drewl.maildraftreview       │  │
│  │ Daily @ 07:00       │    │ KeepAlive (always-on)           │  │
│  │ → run.sh            │    │ → slack_app/daemon.sh           │  │
│  └──────────┬──────────┘    └──────────────┬────────────────── ┘  │
└─────────────┼─────────────────────────────┼────────────────────── ┘
              │                             │
              ▼                             ▼
┌─────────────────────────┐    ┌────────────────────────────────┐
│         run.sh          │    │    slack_app/app.py             │
│  (morning pipeline)     │    │    (Slack Bolt Socket Mode)     │
│                         │    │                                 │
│  1. claude (Sonnet)     │    │  Listens for button clicks:     │
│     → TRIAGE.md prompt  │    │  • Send draft                   │
│     → fans out Haiku    │    │  • Edit draft (modal)           │
│       subagents per     │    │  • Discard draft                │
│       account           │    │  • Regenerate draft             │
│                         │    │  • Snooze card                  │
│  2. missed_sweep.py     │    │  • Draft reply for missed item  │
│     → catchup.py ×N     │    │  • Archive missed item          │
│       (parallel)        │    │                                 │
│                         │    │  Reads:  queue.json             │
│  3. gen_drafts.py       │    │          snoozes.json           │
│     (primary account)   │    │  Writes: queue.json (status)   │
│                         │    └────────────────────────────────┘
│  4. build_briefing.py   │
│                         │
│  5. app.py brief        │
│     app.py post         │
│     app.py post-missed  │
└────────────┬────────────┘
             │
             ▼
     ┌───────────────┐
     │  Gmail (gws)  │
     │               │
     │  • list labels│
     │  • list msgs  │
     │  • modify     │
     │  • create     │
     │    drafts     │
     │  • send email │
     └───────────────┘
```

---

## Data flow

### 1. Morning triage (claude + Haiku subagents)

```
run.sh
  → claude -p TRIAGE.md (Sonnet orchestrator)
      → Task(haiku) for each account in parallel:
          → ensure_labels.sh <config_dir>      # idempotent label creation
          → fetch_inbox.sh <config_dir>         # last 1d unread, compact JSON
          → classify each thread (Haiku)
          → apply.sh <config_dir> <thread_id>  # add/remove label ids
      → compile JSON from all workers
      → gws gmail +send (digest email to primary account)
```

### 2. Missed-items sweep

```
run.sh
  → missed_sweep.py 14
      → catchup.py <config_dir> in parallel (one per account):
          → query inbox: older_than:1d newer_than:14d, no Action label
          → filter: last msg not from user, user never replied
          → Haiku: keep only genuinely important items
          → returns JSON list
      → aggregate all results → drafts/missed_today.json
      → send "⏰ You may have missed" digest email
```

### 3. Draft generation

```
run.sh
  → gen_drafts.py <primary config_dir> <email> 1d
      → for each ⚡ Action thread (last 1d):
          → context.py: gather thread + sender history + drewl profile
          → Haiku: judge_and_draft → {needs_reply, reason, reply}
          → if needs_reply:
              → draftutil.py create → Gmail draft id
              → append to drafts/queue.json (status=pending)
```

### 4. Slack posting

```
run.sh
  → app.py brief        → post morning briefing card (from briefing.json)
  → app.py post         → post each pending unposted draft card
  → app.py post-missed  → post each missed-item card

User interaction (always-on daemon):
  Button click → handle_* action handler
    → subprocess: send_draft.sh / discard_draft.sh / update_and_send_draft.sh
    → draftutil.py (send/discard/update-send)
    → queue.json updated (status = sent/discarded/snoozed)
    → Slack card updated (chat.update)
```

---

## Key files

| File | Purpose |
|------|---------|
| `config.sh` | Shell config: MAIL_TRIAGE_DIR, MAIL_TRIAGE_PYTHON, derived paths |
| `config.py` | Python config: ROOT, LIB_DIR, QUEUE_PATH, etc. |
| `accounts.json` | Account registry: slug, email, gws config_dir per account |
| `TRIAGE.md` | Claude orchestrator prompt (triage rules and instructions) |
| `knowledge/drewl.md` | AI context: who you are, signal-vs-noise boundaries |
| `drafts/queue.json` | Pending/sent/discarded draft queue (gitignored) |
| `drafts/briefing.json` | Morning briefing data (gitignored) |
| `drafts/missed_today.json` | Missed items for current run (gitignored) |
| `slack_app/snoozes.json` | Active snooze records (gitignored) |
| `slack_app/config.env` | Slack tokens (gitignored — never commit) |

---

## Config contract

| Env var | Default | Purpose |
|---------|---------|---------|
| `MAIL_TRIAGE_DIR` | directory of config.sh / config.py | Override the repo root |
| `MAIL_TRIAGE_PYTHON` | `python3` from PATH (shell) / `sys.executable` (Python) | Override the Python binary |
| `QUEUE_PATH` | `$MAIL_TRIAGE_DIR/drafts/queue.json` | Override the queue file path |
| `BRIEFING_PATH` | `$MAIL_TRIAGE_DIR/drafts/briefing.json` | Override the briefing file path |
| `CLAUDE_BIN` | `claude` | Override the Claude CLI binary |
| `GWS_BIN` | `gws` | Override the gws binary |

---

## Security model

- **Nothing is ever deleted.** Archiving = remove INBOX label + add recovery label.
  Undo via `undo_inbox_zero.py`.
- **No email is sent without human action.** Drafts are created in Gmail but only
  sent when you click "Send" in Slack.
- **Tokens never leave the machine.** Slack tokens are in `config.env` (gitignored).
  gws OAuth tokens are in `~/.config/gws/` (not in this repo).
- **Socket Mode.** The Slack app uses Socket Mode — no public endpoint, no webhook
  URL, no firewall rules needed.
