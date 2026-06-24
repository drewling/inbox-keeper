# PRODUCT.md

> The spec. What this is, what it refuses to be, and why anyone would trust it
> with their inbox. If a change doesn't serve the one sentence below, it doesn't
> ship.

## The one job

**Keep your inbox at "only what still needs you" — across every account — and
never lose anything.**

That's it. Not a mail client. Not a CRM. Not an assistant that does ten things.
It does the single thing you'd never finish by hand: continuously deciding what
in your inbox is still an *open loop* — something genuinely awaiting your action
— and quietly setting everything else aside, reversibly.

Granola makes the meeting notes you'd have taken. This keeps the inbox you'd
keep if you had an hour every morning and perfect memory of who's still waiting
on you.

## Why it's trustworthy enough to let near your email

Three properties, in priority order. The first is non-negotiable.

1. **Reversible by construction.** Nothing is ever deleted. "Archive" means
   *remove the INBOX label and add a dated recovery label* — so every run is
   undoable with a single search. Mail stays in All Mail, fully searchable. This
   is what makes it sane to let an agent touch your inbox at all. It is the
   product, not a feature footnote.

2. **Ambient.** No new app to live in, no inbox to check. Your Gmail and Apple
   Mail stay exactly as they are; this works quietly behind them, once a morning.
   The win condition is that you forget it's running and just notice your inbox
   stopped being a swamp.

3. **The judgment is an agent, not a rule list.** What counts as "needs you" is
   described in plain language and enforced by a model that reads each thread —
   not a brittle stack of filters. Cold outreach using a real human's name gets
   archived; a real person actually awaiting your reply gets kept. A filter rule
   can't tell those apart. This is the part nobody copies by adding a setting.

## What "needs you" means (the keep-bar)

A thread is **kept** only if there is an unresolved item that needs *you* to act:

- a real person awaiting your reply or decision,
- an unanswered direct question or request to you,
- a live payment **problem**, a legal/dispute matter,
- or an explicit deadline with a consequence.

Everything else is archived (reversibly): cold outreach and sales — even from
named senders you've never replied to; receipts, invoices, statements,
confirmations, notifications, digests, newsletters; and any thread where the
**last message was from you** (ball's in their court — already dealt with).

Two signals do most of the work and are worth stating plainly:

- **`last_from_me`** — if the most recent message in the thread is yours, you've
  already handled it. Archive.
- **`replied_before`** — have you *ever* written to this sender? Cold-email tools
  (SmartLead, Apollo, Lemlist) use real human names, so "is it a person?" is the
  wrong question. "Have I ever engaged with this person?" is the right one.

## What it deliberately is NOT

Saying no is the whole discipline. Out of scope, on purpose:

- **Not an auto-replier.** The app can draft a reply in your voice *on demand*
  when you tap Reply on a loop (review, edit, send, all in the panel), and it
  learns from your edits. It never drafts or sends on its own. The core job is
  still keeping the inbox honest; replying is a deliberate, in-app action. (The
  older Slack-based draft-review flow is retired from the default experience; it
  remains in the repo for anyone who wants it.)
- **Not a unified inbox / mail client.** Your existing apps are the UI.
- **Not labels-as-organization.** It maintains exactly one thing — what's an open
  loop — not an elaborate folder taxonomy you have to maintain back.
- **Not real-time.** Once a morning is the right cadence. Real-time would make it
  something you watch; the point is that you don't.

## Setup, the way it should feel

The bar is "Granola to set up," not "clone and configure five files."

```
$ npx inbox-keeper init        # opens browser, sign in, done
$ npx inbox-keeper add-account # one command per extra account
```

Configuration is one editable plain-language policy file describing your
keep-bar — not a config DSL, not regex. You write what "needs me" means in
sentences; the agent enforces it.

## Honest gap (current repo → this product)

What's in this repo today is a *personal* tool: specific accounts, owner's name
baked into prompts, a specific Slack workspace, scripts wired by `run.sh`. To
become the open-source thing, three things move from hardcoded to configured:

1. **Accounts** — mostly there already via `accounts.json`.
2. **The keep-bar** — from regex + inline prompt into one editable
   natural-language policy file (see `lib/review_open_loops.py` `PROMPT_HEAD` and
   `inbox_zero.py` `PROTECT_PATTERNS` — these are the things to externalize).
3. **Onboarding** — from "set up gws + edit configs" to one command + OAuth.

Until those land, this stays a personal tool that happens to be open source —
which is fine. This file exists so that if it grows, it grows toward the one
sentence at the top and nothing else.

## Tech, briefly

Multi-account Gmail via the `gws` CLI; per-thread judgment via the Claude Agent
SDK (Haiku for volume classification, escalating only where judgment is costly);
reversible archive via Gmail `batchModify` + dated recovery labels. The agent is
the product's brain; the scripts are just plumbing around it.
