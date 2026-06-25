# Changelog

All notable changes to zero are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.6.1] - 2026-06-25

### Fixed

- **The selected tab now renders cleanly.** The active segmented-nav tab (e.g. "Accounts") was drawing as a washed-out, half-rendered glass pill with dimmed text, because it stacked a fill plus a glass surface inside a glass container that no longer had a sibling glass layer. It is now a crisp raised pill (subtle fill, hairline rim, soft shadow) on a gently sunken track, sliding between tabs, with the active label at full brightness.

### Changed

- **Clearer documentation.** The README now names the fourth tab correctly (Settings, which holds Rules, categories, the daily schedule, and the AI engine), uses the current `zero/undo/` recovery-label example, and lists what lives under Settings. SECURITY.md opens with a plain-language privacy summary.

## [1.6.0] - 2026-06-25

A depth release: the learning loop actually closes, labeling reaches your archive, the engine is provider-agnostic, the panel seam is gone, and the whole surface is more consistently glassy. The product landing page is rebuilt and live.

### Added

- **Works with the AI engine you already use.** The engine is now a data-driven provider abstraction: Claude runs today, and Codex, Hermes, or any other agent CLI is used automatically if it's installed and selected. Adding a new engine is a single data entry, not a code change. Unavailable engines are clearly shown as "Not detected" and can't be selected into a broken state.
- **Labeling now reaches your archive.** A new "also label archived mail from the last N days" setting (`label_archived_days`, default 30) sorts recently-archived mail into your categories too, so there's always plenty labelled, not just the inbox. Off, 7, 30, 90, or 365 days. Idempotent: already-labelled threads are skipped.
- **Beautiful API documentation.** The local engine's JSON API is now documented with a Scalar reference site (`docs/api/`), framed clearly as a local, private, contributor-facing API. Added `docs/MAINTENANCE.md` so the docs, settings, and release process stay in sync across future work.

### Changed

- **Auto-learned preferences actually close the loop.** zero now also learns "archive more like this" from the senders you repeatedly dismiss (recurring senders only, so one-offs don't become noise), and voice learning refreshes right after you send an edited draft instead of waiting for the next run. Learned preferences feed both the keep/archive judgement and the draft voice.
- **Settings redesigned for calm.** The "Learned from your actions" section breathes properly (optically aligned rows, comfortable empty state, clean multi-group headings); Daily routine is now cohesive cards instead of card-plus-loose-rows; the category emoji/colour token reads as two clear taps; the Intelligence engine rows are balanced and the "connected" note is grouped.
- **Label cleanup is reassurance-first.** The cleanup sheet leads with "only labels are removed, your mail is never deleted", distinguishes zero-created labels from your own, and reports partial results ("Removed N, M couldn't be removed") instead of a blanket success.
- **More consistently glassy.** Removed a double-glass layer in the segmented nav, moved the emoji/colour popovers and the "sent" confirmation onto real material, and introduced a named corner-radius system (`Radius`) for concentric, inset-rounded corners throughout.
- **Landing page rebuilt and published.** A sharper "Three questions it asks for you" how-it-works (the questions the agent answers on your behalf), a before/after inbox visual, a heavyweight standalone trust section, and tighter copy. It is live and auto-deploys.

### Fixed

- **The panel pointer seam is gone.** The little arrow at the top of the panel now shares the header's exact graphite material, with no seam or tint break where it meets the body. (It was rendering with a different, lighter glass than the header.)
- **Fewer transient inbox errors.** Calls to the Google Workspace CLI now retry rate-limit, 5xx, and network blips with exponential backoff, so a momentary hiccup no longer surfaces as "HTTP request failed". Category labeling now counts and reports failures instead of swallowing them silently.

### Maintenance

- Claude is no longer added as a git co-author (set globally).
- Genericized a leftover personal email address in a design mock.

## [1.5.1] - 2026-06-25

Polish and connect-flow fixes from hands-on testing of 1.5.0.

### Fixed

- **Connecting a Gmail account now actually opens your browser.** With no terminal, the `gws` sign-in helper printed the Google consent URL and waited instead of launching a browser, so "Opening your browser to sign in…" hung forever. zero now reads that URL, opens it for you, and shows a fallback "Open the sign-in page" link. (Verified end to end: a real consent tab opens.)
- **The action bar no longer repeats itself.** During a run, the live progress message showed both in the button and in the status line beside it. The button now shows a short "Working…" and the live detail appears once, in the status line (which has more room as a result).
- **Daily-routine layout.** "Run at" no longer collapses into vertical letters; the section is now three clean rows: the run time, the day-of-week pills, and the "Weekdays" / "Every day" presets. The preset pills no longer wrap.
- **Colour picker sliders.** The Hue/Saturation/Brightness thumbs are vertically centered and track the cursor across the full width without clipping the track ends.
- **Top-bar menu.** The three-dot overflow menu no longer shows a stray focus ring when the panel opens, nor an accent-filled highlight while open.

### Changed

- Updated the README screenshots to the current 1.5.x panel.

## [1.5.0] - 2026-06-25

### Added

- **Configurable daily routine.** Settings now lets you choose when the keeper runs (hour and minute), which days of the week, and whether macOS notifies you when a run finishes. Changing the schedule regenerates the launch agent automatically, with no terminal.
- **AI engine settings.** A new "Intelligence" section shows which agent SDK zero is connected to (Claude, with its version), backed by a provider abstraction (`lib/llm.py`) so judgement and drafting both route through one place. Codex and Hermes are listed on the roadmap and shown as not-yet-available until wired.
- **Quit from inside the app.** An overflow menu in the panel's top bar (showing the version) and a right-click menu on the menu-bar icon both offer "Quit zero". Left-click still toggles the panel.
- **Replies use your Gmail signature.** Drafts now append your account's default Gmail `sendAs` signature to the HTML part. If you have none, drafts are unchanged.
- **Witty drafting messages.** While a reply is being written, the composer cycles through short, changing loading lines instead of a static one.
- **10 new moments of delight** during normal use: a calm "inbox at zero" arrival, rolling counts, a satisfying archive dissolve, the run button morphing into live progress, refined row hover, the composer rising into place, a "sent" confirmation, spatial tab transitions, a refresh sheen, and a first-paint cascade. All respect Reduce Motion.
- **Resilient first run and sign-in.** The panel now shows a calm "Starting…" state while the local engine boots (it no longer blocks or looks like onboarding), and the local server starts listening immediately instead of waiting on a state rebuild. Connecting a Gmail account opens your browser automatically, offers a fallback "Open the sign-in page" link, can be cancelled at any time, and times out instead of hanging.

### Changed

- **The "What to keep" box is now "Rules"** and is always pre-filled with sensible starter rules on a fresh install.
- **Categories editor redesigned.** Each category is a unified emoji + colour token; the colour picker is a curated palette plus an in-app hue/saturation/brightness control. The macOS system colour picker is never opened.
- **New app icon:** a Google-blue squircle with a bold check, in the native macOS style.
- **Landing page re-laid-out** for balance: a two-column hero with a larger app mock, varied section rhythm, an asymmetric trust section, and richer per-account chips.
- **Setup is documented end-to-end.** The README now has one numbered install-and-first-run path with the correct `@googleworkspace/cli` package and the required `gws auth login` (with `GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file`) and Claude CLI steps. The architecture doc was rewritten to describe the current app and local service.

### Fixed

- **Undo (Cmd-Z) works in the reply editor** and no longer reverts your manual edits when you adjust or regenerate a draft.
- **"Couldn't check your inboxes / HTTP request failed" clears itself.** The local service rebuilds a stale failed state on launch instead of serving it indefinitely, so a transient error no longer sticks across restarts. (`GOOGLE_WORKSPACE_CLI_TOKEN` is still stripped defensively in every path.)
- **Sign-in no longer hangs.** Connecting an account could get stuck on "Opening your browser to sign in…" forever: the sign-in helper, with no terminal, printed its consent URL instead of launching a browser, and timed-out attempts leaked stray processes. zero now reads that URL and opens the browser itself, kills the whole process group on cancel or timeout, and reports accurate errors (it only shows the OAuth-setup guidance when credentials are genuinely missing).
- **UI polish:** the colour picker's H/S/B sliders are vertically aligned and track the cursor; the schedule preset pills ("Weekdays" / "Every day") no longer wrap; and the top-bar overflow menu no longer shows a stray focus ring when the panel opens.

### Removed

- The legacy Slack review pipeline (`slack_app/`, the deploy installer and daemon plist) and its shell wrappers, plus unused modules (`build_briefing.py`, `draft_one.py`, `undo_inbox_zero.py`, `gate_audit.py`, `test_gate.py`, `verify_archive.py`) and orphaned bytecode.
- The legacy `claude -p TRIAGE.md` step from the daily run (and `TRIAGE.md`, `fetch_inbox.sh`, `ensure_labels.sh`). The scheduled run now uses the same keeper engine as the app.
- An internal org name from a source identifier (`drewl_profile` is now `user_profile`).

## [1.4.1] - 2026-06-24

### Fixed

- zero now strips a stray `GOOGLE_WORKSPACE_CLI_TOKEN` from the environment before invoking `gws`, in the server, the spawned gws environment, and `bin/zero`. If that variable was set (for example exported from a shell profile), gws treated its value as a pre-obtained access token; a malformed value broke every account with `HTTP request failed: builder error: failed to parse header value`. zero uses per-account keyring credentials and never a global token, so it drops the variable defensively.

## [1.4.0] - 2026-06-24

### Changed

- **Renamed to `zero`.** The app, bundle identifier (`com.drewling.zero`), CLI (`bin/zero`), and repository are now `zero`. On first launch the app migrates your existing `~/Library/Application Support/inbox-keeper` data — accounts, policy, learning, and state — to the new location, so nothing is lost across the rename.
- Converted the remaining flat-fill surfaces to real macOS 26 Liquid Glass: the top and action bars, the segmented-nav track, list-row and icon-button hovers, the composer strips, and error banners now use the native `.glassEffect` material, with a soft scroll-edge effect on the loops list. The deliberate legibility floor and the branded buttons are unchanged.

### Added

- **Time-windowed controls:** label-only backfill that sorts recent mail into categories, a reversible "clear the backlog before a date" sweep, and a first-run backlog step.
- **In-app Google setup.** A new user can paste their Google OAuth client (`client_secret.json`) directly in onboarding instead of hand-placing a file; the browser sign-in follows. This removes the biggest first-run hurdle to using zero on a fresh Mac. (New `POST /api/set-credentials` and `GET /api/credentials-status` endpoints.)

## [1.3.0] - 2026-06-24

### Changed

- Major legibility pass for text over the glass: raised the glass surfaces' dark-tint floor so text keeps contrast even when something bright shows through, brightened the dim secondary/tertiary text tiers, and switched progress lines, links, counts, and hover icons from the dark blue accent (which never cleared WCAG 4.5:1 as text) to the lighter `accentSoft`. Text sitting directly on the panel vibrancy now carries a faint dark halo so it stays readable on any backdrop.
- The reply composer and label-cleanup sheet now use real Liquid Glass (tinted dark enough to stay legible) instead of a flat opaque panel.

### Fixed

- The reply composer's draft text was a dark ink left over from the old light-background web editor, rendering nearly invisible on the dark composer. It's now light ink, and links use the legible `accentSoft`.

### Removed

- The legacy browser web panel (`app/panel/`) and its `bin/zero dashboard` command. The native macOS app is now the sole front-end; `keeper_server.py` remains as its JSON API backend. Also removed two unused review scripts and de-duplicated the category defaults shared by the server and dashboard state.

## [1.2.0] - 2026-06-24

### Added

- Cute emoji picker and colour picker for categories in Settings: tap a category's emoji to choose from a curated grid (or type your own), and tap its colour swatch to pick from a soft palette (system picker still available for off-palette colours).

### Changed

- The "Tidying your inboxes" state no longer takes over the whole panel: it's now a slim progress banner pinned atop the loops list, so the inbox stays visible and scrollable while the keeper runs.

### Fixed

- Smoothed the menu-bar panel's pointer arrow: removed a thin white seam where the arrow met the body (opposite path windings were cancelling), and reshaped it as a gentle raised-cosine bump that flows out of the panel edge.

## [1.1.0] - 2026-06-24

### Added

- Per-account label cleanup: review an account's labels in a checklist (app-created ones pre-selected) and bulk-delete the ones you don't want. Mail is never deleted — labels only.
- Real Gmail profile photos displayed as circular avatars throughout the panel.
- Editable categories applied as Gmail labels and surfaced as loop tags in the panel.
- Categories editor in Settings for managing per-account category sets.
- 10 Liquid-Glass delight moments: ambient animations, spring transitions, and haptic cues.

### Changed

- Settings tab redesigned with cleaner layout and a redesigned "Learned from your actions" section.
- App now runs from `~/Library/Application Support` (TCC-safe, location-independent); no longer requires a source checkout to be present.
- De-personalized internal identifiers to remove hard-coded personal references.

### Fixed

- `photo_url` decoding fix: avatars now load reliably for accounts with encoded profile URLs.
- Orphaned-label-on-rename fix: renaming a category no longer leaves stale Gmail labels behind.

## [1.0.0] - 2026-06-24

Initial public release.

- Reversible multi-account Gmail triage: archive and label, never delete.
- Agent-judged open loops: Claude (Haiku) reads each thread against your keep policy and decides what still needs you.
- Reply in your voice: draft replies from the panel using optional voice-grounding files.
- Native macOS 26 Liquid Glass menu-bar app with a popover panel.
- `.dmg` installer with guided onboarding for first-time setup.

[Unreleased]: https://github.com/drewling/zero/compare/v1.6.1...HEAD
[1.6.1]: https://github.com/drewling/zero/compare/v1.6.0...v1.6.1
[1.6.0]: https://github.com/drewling/zero/compare/v1.5.1...v1.6.0
[1.5.1]: https://github.com/drewling/zero/compare/v1.5.0...v1.5.1
[1.5.0]: https://github.com/drewling/zero/compare/v1.4.1...v1.5.0
[1.1.0]: https://github.com/drewling/zero/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/drewling/zero/releases/tag/v1.0.0
