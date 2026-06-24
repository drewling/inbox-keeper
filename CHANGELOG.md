# Changelog

All notable changes to zero are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/drewling/zero/compare/v1.0.0...HEAD
[1.1.0]: https://github.com/drewling/zero/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/drewling/zero/releases/tag/v1.0.0
