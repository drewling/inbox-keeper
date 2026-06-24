# Security

## Reporting a vulnerability

Please do not file public GitHub issues for security vulnerabilities.

**Preferred:** Open a [private security advisory](https://github.com/drewling/zero/security/advisories/new)
on GitHub. This keeps the details confidential until a fix is ready.

**Alternative:** Email [tayo@drewl.com](mailto:tayo@drewl.com) with "zero
security" in the subject line. Include a description of the issue, steps to
reproduce, and your assessment of impact.

We will acknowledge receipt within 48 hours and aim to release a fix within 14 days
for confirmed vulnerabilities. We will credit you in the release notes unless you
prefer otherwise.

## Scope

In scope:

- Local server (`keeper_server.py`) exposed on 127.0.0.1 -- request forgery,
  path traversal, or unintended exposure
- OAuth token handling or credential leakage
- Unintended writes to Gmail (anything that modifies mail in a way the user did
  not authorize or that is not reversible)
- Privilege escalation or sandbox escapes in the macOS app

Out of scope:

- Attacks that require physical access to the user's machine (zero has no
  network-facing surface)
- Issues in the `gws` CLI, `claude` CLI, or Gmail itself (report those upstream)
- Theoretical issues without a plausible attack path

## What zero does (and does not) do with your mail

**zero never deletes mail.** The only Gmail operations it performs are
label additions and removals via the `gws` CLI. "Archive" means removing the INBOX
label and adding a dated recovery label. Everything remains in All Mail, fully
searchable and fully restorable.

**Everything runs on your machine.** The local server binds to `127.0.0.1` only.
No mail content, OAuth tokens, or personal data is transmitted to any server
operated by the zero project or by Anthropic beyond what the `claude` CLI
normally does when you call it (per-thread text is sent to the Claude API for
classification; review Anthropic's privacy policy for details).

**Your credentials stay in your existing tools.** zero authenticates with
Gmail through the `gws` CLI, which manages your OAuth tokens. zero never
reads or stores your Google password or OAuth tokens directly.
