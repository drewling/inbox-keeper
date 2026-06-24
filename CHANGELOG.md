# Changelog

All notable changes to inbox-keeper are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.3.0] - 2026-06-24

### Changed

- Major legibility pass for text over the glass: raised the glass surfaces' dark-tint floor so text keeps contrast even when something bright shows through, brightened the dim secondary/tertiary text tiers, and switched progress lines, links, counts, and hover icons from the dark blue accent (which never cleared WCAG 4.5:1 as text) to the lighter `accentSoft`. Text sitting directly on the panel vibrancy now carries a faint dark halo so it stays readable on any backdrop.
- The reply composer and label-cleanup sheet now use real Liquid Glass (tinted dark enough to stay legible) instead of a flat opaque panel.

### Fixed

- The reply composer's draft text was a dark ink left over from the old light-background web editor, rendering nearly invisible on the dark composer. It's now light ink, and links use the legible `accentSoft`.

### Removed

- The legacy browser web panel (`app/panel/`) and its `bin/inbox-keeper dashboard` command. The native macOS app is now the sole front-end; `keeper_server.py` remains as its JSON API backend. Also removed two unused review scripts and de-duplicated the category defaults shared by the server and dashboard state.

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

[Unreleased]: https://github.com/drewling/inbox-keeper/compare/v1.0.0...HEAD
[1.1.0]: https://github.com/drewling/inbox-keeper/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/drewling/inbox-keeper/releases/tag/v1.0.0
