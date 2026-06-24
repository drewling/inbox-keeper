#!/usr/bin/env bash
# install.sh — Set up inbox-keeper on a new machine.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== inbox-keeper install ==="
echo ""

# ---------------------------------------------------------------------------
# 1. Dependency checks
# ---------------------------------------------------------------------------
echo "Checking dependencies..."

check_tool() {
  local name="$1"
  local cmd="$2"
  local required="$3"
  local note="${4:-}"

  if command -v "$cmd" >/dev/null 2>&1; then
    echo "  OK        $name"
  else
    if [ "$required" = "required" ]; then
      echo "  MISSING   $name  (required)${note:+  — $note}"
    else
      echo "  MISSING   $name  (${required})${note:+  — $note}"
    fi
  fi
}

check_tool "python3"  "python3"  "required"
check_tool "gws"      "gws"      "required"     "install: npm i -g @googleworkspace/cli"
check_tool "node"     "node"     "recommended"
check_tool "swift"    "swiftc"   "optional — needed only for the menu-bar app"

echo ""

# ---------------------------------------------------------------------------
# 2. accounts.json
# ---------------------------------------------------------------------------
if [ ! -f "$REPO_DIR/accounts.json" ]; then
  cp "$REPO_DIR/accounts.json.example" "$REPO_DIR/accounts.json"
  echo "Created accounts.json from accounts.json.example."
  echo "  --> Edit $REPO_DIR/accounts.json with your real account config_dir paths."
else
  echo "accounts.json already exists — leaving it unchanged."
fi

echo ""

# ---------------------------------------------------------------------------
# 3. Build the menu-bar app (only if swift is available)
# ---------------------------------------------------------------------------
if command -v swiftc >/dev/null 2>&1; then
  echo "swift found — building inbox-keeper.app..."
  bash "$REPO_DIR/macapp/build.sh"
else
  echo "swiftc not found — skipping menu-bar app build (run macapp/build.sh when Xcode CLT is installed)."
fi

echo ""

# ---------------------------------------------------------------------------
# 4. Make the CLI executable
# ---------------------------------------------------------------------------
chmod +x "$REPO_DIR/bin/inbox-keeper"
echo "bin/inbox-keeper is now executable."

echo ""

# ---------------------------------------------------------------------------
# 5. Next steps
# ---------------------------------------------------------------------------
cat <<'NEXT'
=== Next steps ===

1. Edit accounts.json with your real gws config_dir paths (if you haven't already).

2. Launch the web panel:
     ./bin/inbox-keeper dashboard

   Or open the native menu-bar app (requires the build step above):
     ./bin/inbox-keeper app

3. Run the keeper across all accounts now:
     ./bin/inbox-keeper run

4. Have it run automatically every morning (07:00):
     ./bin/inbox-keeper schedule

(The Slack draft-review pipeline is optional and legacy; see docs/SETUP.md and
deploy/install.sh only if you specifically want it.)

NEXT
