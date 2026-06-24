# Contributing to zero

Thanks for your interest. zero is a focused tool with a clear scope:
keep your inbox at "only what still needs you" and never lose anything. The best
contributions stay true to that one job.

## License note

zero is published under the [PolyForm Noncommercial 1.0.0](LICENSE)
license. By contributing, you agree that your changes will be distributed under
the same terms. This means the project -- and your contribution -- may not be used
commercially or resold. If that is a concern, please raise it before putting in
the work.

## How to build

### Prerequisites

- macOS 26+ (Apple Silicon)
- Xcode command-line tools: `xcode-select --install`
- Python 3
- `gws` CLI authenticated for at least one Gmail account
- `claude` CLI configured

### Build the menu-bar app

```bash
cd macapp
./build.sh          # compiles zero.app into macapp/build/
```

To produce a distributable disk image:

```bash
./make-dmg.sh       # produces zero.dmg in macapp/
```

### Run the server standalone (faster dev loop)

You do not need the macOS app running to work on the Python layer. Start the
server directly:

```bash
python3 lib/keeper_server.py
```

The server binds to 127.0.0.1 and serves the JSON API the native app uses.
Use `./bin/zero run` to trigger a sweep from the command line, or `POST
/api/run` to the server.

For Gmail operations you need `accounts.json` configured (see the
`accounts.json.example` template) and `gws auth login` run for each account.

### Dry-run the judgment logic

`review_open_loops.py` runs dry by default (no changes applied):

```bash
python3 lib/review_open_loops.py <gws_config_dir> <account_label>
```

Pass `--execute` to apply label changes. Use this to iterate on the judgment
logic and the `keep-policy.md` prompt without touching production mail.

## Repo layout

```
lib/                   Python server and scripts (the core)
  keeper_server.py     Local HTTP server (stdlib only, no deps)
  review_open_loops.py Per-thread keep/archive judgment (calls claude CLI)
  dashboard_state.py   Builds app/state.json from Gmail + learning store
  inbox_zero.py        gws wrapper and thread operations
  learning.py          Keeps-rule learning and inference
  ...

macapp/                SwiftUI menu-bar app (thin shell)
  Sources/             Swift source files
  build.sh             Build script (produces .app)
  make-dmg.sh          DMG packaging

app/
  state.json           Cached state (gitignored, written at runtime by dashboard_state.py)

keep-policy.md         The plain-English keep policy (the only user config)
accounts.json          Per-account registry (gitignored, from accounts.json.example)
knowledge/             Optional voice-grounding files (gitignored)
docs/                  Architecture and pipeline docs
```

The judgment pipeline is: Swift app starts `keeper_server.py`, which spawns
`review_open_loops.py` per account, which calls the `claude` CLI (Haiku) with the
thread contents and `keep-policy.md`, then applies reversible label changes via the
`gws` CLI.

## Coding conventions

**Match the style of the file you are editing.** The codebase has a consistent
voice; do not introduce a different style in the same file.

**Python (lib/):**

- Stdlib only for `keeper_server.py` and the core server path. No third-party
  dependencies in the hot path.
- Use subprocess calls to `gws` and `claude` CLIs the same way existing code does.
  Do not add SDK imports that are not already there.
- Keep functions short and named after what they do, not how they do it.

**Swift (macapp/):**

- The Swift shell is deliberately thin. If something can be done in Python (where
  the logic already lives), do it there. Only put things in Swift that genuinely
  need native macOS integration.
- Match the SwiftUI patterns already in `Sources/`.

**General:**

- Make surgical changes. One logical change per PR; do not refactor adjacent
  code in the same diff unless you have a specific reason.
- Dry-run first. For any Gmail operation, verify behavior with `--execute` off
  before turning it on.
- The keep policy is the product. Changes that blur the reversibility guarantee
  or that add irreversible side effects need a very strong justification.

## Proposing changes

1. Open an issue first for anything beyond a clear bug fix or small improvement.
   Describe the problem you are solving, not the solution. This avoids duplicate
   work and lets us align on scope before you write code.
2. Keep PRs focused. One fix or feature per PR.
3. Include a brief test plan in the PR description: how you verified the change
   works and does not break anything. A dry-run log, a before/after inbox count,
   or a screenshot of the panel is usually enough.
4. The core invariant is that nothing is ever deleted and every archive is
   reversible. Any PR that risks that property will not be merged.

## Releasing

> This section is for maintainers.

1. Bump the version in any relevant source files (Swift `CFBundleShortVersionString`, etc.).
2. Add a `## [X.Y.Z] - YYYY-MM-DD` section to `CHANGELOG.md` (following Keep a Changelog 1.1.0).
   Move items out of `## [Unreleased]` into the new section.
3. Commit those changes to `master` and push.
4. Run the release script:
   ```bash
   bin/release X.Y.Z
   ```
   The script will verify the working tree is clean, confirm the changelog section exists, build the
   `.app` and `.dmg`, create and push the git tag, then publish a GitHub release with the extracted
   changelog notes and the `.dmg` attached.

**Known caveat — unsigned/un-notarized binary.** The `.dmg` is not signed or notarized. Users who
download it must right-click the app and choose "Open" on first launch to bypass Gatekeeper.

## Reporting bugs

Open an issue with:
- macOS version
- What you did
- What you expected
- What happened (include any log output from `logs/` if relevant)

For security issues, see [SECURITY.md](SECURITY.md).
