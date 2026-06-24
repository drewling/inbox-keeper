<div align="center">

# zero

**Keep your inbox at "only what still needs you," across every account, and never lose anything.**

A quiet macOS menu-bar app that reads each Gmail thread, sets aside everything that
isn't waiting on you, and keeps the rest one tap away. Nothing is ever deleted.

<img src="design/screenshots/panel-loops.png" width="320" alt="zero open loops panel">

[![Platform: macOS](https://img.shields.io/badge/platform-macOS%2026%2B-black?logo=apple)](https://github.com/drewling/zero/releases)
[![License: PolyForm-NC](https://img.shields.io/badge/license-PolyForm--NC-blue)](LICENSE)

</div>

---

## What it is

Most "inbox zero" tools make you do the sorting. zero does the one part
you'd never finish by hand: continuously deciding what in your inbox is still an
**open loop** (something genuinely awaiting your action) and quietly setting
everything else aside.

It lives in the menu bar. You glance at it between meetings and see, across all
your accounts, the few things that actually need you. Everything else is archived
reversibly, so the inbox stops being a swamp without anything going missing.

**What it refuses to be:**

- An auto-replier. Replies are drafted in your voice on demand; you review, edit,
  and decide when (or whether) to send. It never sends on your behalf.
- A unified mail client. Your Gmail stays exactly as it is.
- A rule engine. There is no DSL, no regex, no filter list to maintain.
- A real-time tool. It runs once a morning.

## The panel

Four views, one icon in the menu bar:

| Open loops | Accounts | Undo | Policy |
|:---:|:---:|:---:|:---:|
| ![Open loops](design/screenshots/panel-loops.png) | ![Accounts](design/screenshots/panel-accounts.png) | ![Undo](design/screenshots/panel-undo.png) | ![Policy](design/screenshots/panel-policy.png) |
| What still needs you, across all accounts | Per-account inbox and archive counts | Restore any day's archived mail in one tap | The one thing you configure, in plain English |

The panel is a dark "Raycast"-style liquid-glass overlay. Tap any thread to open
it in Gmail, hover it to **Reply** (drafts in your voice, stays local until you
tap Send) or **Set aside** (archived reversibly, immediately restorable).

## How it works

```
menu-bar app (SwiftUI)  -->  local server (keeper_server.py, 127.0.0.1)
                                 |  reads
                             app/state.json  <--  dashboard_state.py
                                 ^                (per-account status, open loops, undo points)
                                 |  Run / Undo
                             review_open_loops.py  (Claude Haiku + keep-policy.md)
                                 |
                             gws CLI  -->  Gmail (reversible label swaps only)
```

The Swift shell is deliberately thin: it starts the local Python server and
renders a native SwiftUI panel against its JSON API. All judgment runs in Python
with Gmail reached via the `gws` CLI. The panel reads a cached state file so it
opens instantly; it never talks to Gmail directly.

## Why you can trust it

Three properties, in priority order:

1. **Reversible by construction.** "Archive" means remove the INBOX label and add
   a dated recovery label (e.g. `keeper/undo/2026-06-24`). Mail stays in All Mail,
   fully searchable. Any day's sweep restores in one tap from the **Undo** view.
   Nothing is ever deleted.
2. **Ambient.** No new app to live in. Your Gmail and Apple Mail stay exactly as
   they are. zero works quietly behind them, once a morning.
3. **The judgment is an agent, not a rule list.** What counts as "needs you" is
   written in plain English (see [keep-policy.md](keep-policy.md)) and enforced by
   Claude Haiku reading each thread in full. Cold outreach with a real person's
   name gets archived; a real person actually awaiting your reply is kept. A filter
   rule cannot tell those two apart.

## How "needs you" is decided

You edit one plain-language file, [keep-policy.md](keep-policy.md), or the
**Policy** tab in the panel. No regex, no DSL. The default:

> Keep a thread only if a real person is awaiting your reply or decision, there is
> an unanswered direct question or request addressed to you, a payment has actually
> failed, it is a legal or contractual matter, or there is an explicit deadline with
> a real consequence. Archive everything else reversibly.

Two signals settle most cases automatically:

- **Last message from you:** you already responded, the ball is in their court.
  Archive it.
- **Never replied to this sender, plus cold/sales content:** not a real loop, even
  with a person's name on it. Archive it.

When unsure, the policy keeps the thread. Everything archived is one tap away.

---

## Install

### Option 1: Download the app (recommended)

1. Go to the [Releases page](https://github.com/drewling/zero/releases)
   and download the latest `zero.dmg`.
2. Open the .dmg and drag **zero** to your Applications folder.
3. **First launch:** because zero is source-available and not notarized
   with a paid Apple Developer ID, macOS will block the first open. Right-click
   the app icon and choose **Open**, then confirm in the dialog. You only need to
   do this once.

   Alternatively, remove the quarantine flag from Terminal:
   ```bash
   xattr -dr com.apple.quarantine /Applications/zero.app
   ```
   This is a standard macOS gate for apps from outside the App Store. The source
   is here for you to read and verify.

### Option 2: Build from source

Requires: Xcode command-line tools (`xcode-select --install`), macOS 26 (Tahoe, Apple Silicon). The panel uses the native macOS 26 Liquid Glass API.

```bash
git clone https://github.com/drewling/zero.git
cd zero/macapp
./build.sh           # produces zero.app in macapp/build/
./make-dmg.sh        # optional: packages it as a .dmg
```

---

## First run

When you launch zero for the first time, the app walks you through:

1. **Connect a Gmail account.** An OAuth flow opens in your browser. The app never
   sees your password; it uses the `gws` CLI (which you have already authorized) to
   read and label threads.
2. **Review your keep policy.** Your plain-English policy is shown in the **Policy**
   tab. Edit it there or directly in [keep-policy.md](keep-policy.md).
3. **Run the keeper.** Hit **Run zero now** to tidy your inbox for the first time.

---

## Prerequisites

zero coordinates three CLI tools that must already be installed and
authenticated before the app can do anything:

| Requirement | Install | Notes |
|---|---|---|
| macOS 26 (Tahoe, Apple Silicon) | -- | Uses the native Liquid Glass API; Intel untested |
| Python 3 | `brew install python` or system Python | Used by the local server and all judgment logic |
| `gws` CLI | `npm i -g @googleworkspace/cli` | Authenticate each account with `gws auth login` |
| `claude` CLI | See [Claude Code docs](https://docs.anthropic.com/en/docs/claude-code) | Per-thread judgment and draft generation run through it |

The `gws` CLI is the official Google Workspace CLI. Each Gmail account you add
needs its own `gws auth login` in the appropriate config directory.

The `claude` CLI is Anthropic's Claude Code CLI. It is used to run per-thread
keep/archive judgments (Claude Haiku, for volume) and to draft replies in your
voice. You need a Claude account and the CLI configured on your machine.

---

## Configuration

**One file.** Edit [keep-policy.md](keep-policy.md) directly or via the **Policy**
tab in the panel. Write it in plain English. No syntax to learn.

**Optional voice grounding.** Copy `knowledge/profile.example.md` to
`knowledge/profile.md` and fill it in. The drafter uses it as background when
composing replies in your voice. You can also create per-account files at
`knowledge/<account-slug>.md`. These files are gitignored and stay on your machine.

There is nothing else to configure.

---

## Privacy and trust

- **No project-operated backend.** Everything runs on your Mac. The only data that
  leaves your machine is per-thread text sent to the Claude API through your own
  `claude` CLI (for the keep/archive judgment and draft generation). See
  [SECURITY.md](SECURITY.md).
- **The local server binds to `127.0.0.1` only.** Nothing is reachable from the
  network.
- **Nothing is ever deleted.** Archiving is a reversible label change. Mail stays
  in All Mail, fully searchable in Gmail.
- **Your data stays on your machine.** `accounts.json` and `knowledge/*.md` are
  gitignored and never committed.
- **Gmail access uses your own credentials.** The `gws` CLI authenticates with
  your Google account via OAuth; zero never handles your password or OAuth
  tokens directly.

---

## Beyond the keeper

This repo also contains the fuller morning pipeline that zero grew out of:
AI-drafted replies reviewed from Slack, a missed-items catch-up sweep, and a
combined daily digest. Those are optional and documented in
[docs/PIPELINE.md](docs/PIPELINE.md). The keeper and its panel are the core product;
the legacy pipeline is the engine room, available if you want it.

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[PolyForm Noncommercial 1.0.0](LICENSE). Free to use, fork, modify, and share for
noncommercial purposes. Commercial use and reselling are not permitted.
