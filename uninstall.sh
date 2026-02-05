#!/bin/bash
set -euo pipefail

# uninstall.sh — Remove clawdbot-memory-infra components
# Usage: ./uninstall.sh [--dry-run]
#
# Removes scripts, hooks, and launchd agents installed by this package.
# Does NOT touch config, memory files, or session data.

DRY_RUN=false
CLAWDBOT_HOME="${CLAWDBOT_HOME:-$HOME/.clawdbot}"

# Counters
LAUNCHD_REMOVED=0
SCRIPTS_REMOVED=0
HOOKS_REMOVED=0
WARNINGS=()

# Parse args
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    -h|--help)
      echo "Usage: ./uninstall.sh [--dry-run]"
      echo ""
      echo "Removes scripts, hooks, and launchd agents installed by clawdbot-memory-infra."
      echo "Does NOT touch config, memory files, or session data."
      echo ""
      echo "Options:"
      echo "  --dry-run  Print what would happen without making changes"
      exit 0
      ;;
    *) echo "Unknown option: $arg"; exit 1 ;;
  esac
done

# Colors (only if terminal supports them)
if [ -t 1 ]; then
  GREEN='\033[0;32m'
  YELLOW='\033[0;33m'
  RED='\033[0;31m'
  BLUE='\033[0;34m'
  BOLD='\033[1m'
  NC='\033[0m'
else
  GREEN='' YELLOW='' RED='' BLUE='' BOLD='' NC=''
fi

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; WARNINGS+=("$*"); }
error()   { echo -e "${RED}[ERR]${NC}  $*"; }
dry()     { echo -e "${YELLOW}[DRY]${NC}  $*"; }

header() {
  echo ""
  echo -e "${BOLD}=== $* ===${NC}"
  echo ""
}

# ---------------------------------------------------------------------------
# Manifest: exactly the components this package installs
# ---------------------------------------------------------------------------

# LaunchD labels and their plist filenames
LAUNCHD_LABELS=(
  "com.clawdbot.memory-checkpoint"
  "com.clawdbot.session-rotation"
  "com.clawdbot.index-regen"
  "com.clawdbot.healthcheck"
)

# Scripts installed by this package (basename only)
PACKAGE_SCRIPTS=(
  "memory-checkpoint.js"
  "session-rotation-monitor.js"
  "generate-memory-index.sh"
  "regenerate-all-indexes.sh"
  "backup-config.sh"
  "cleanup-sessions.sh"
  "health-check.sh"
  "validate-config.sh"
)

# Hooks installed by this package (directory names)
PACKAGE_HOOKS=(
  "memory-index-inject"
  "session-summary"
)

# ---------------------------------------------------------------------------
# Step 1: Unload and remove LaunchD plists
# ---------------------------------------------------------------------------
header "Removing LaunchD Agents"

if [ "$(uname)" != "Darwin" ]; then
  info "Not macOS — skipping launchd removal"
else
  LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"

  for label in "${LAUNCHD_LABELS[@]}"; do
    plist_path="$LAUNCH_AGENTS_DIR/${label}.plist"

    if [ ! -f "$plist_path" ]; then
      info "$label — not installed, skipping"
      continue
    fi

    if $DRY_RUN; then
      # Check if loaded
      if launchctl list 2>/dev/null | grep -q "$label"; then
        dry "Would unload: $label"
      fi
      dry "Would remove: $plist_path"
      LAUNCHD_REMOVED=$((LAUNCHD_REMOVED + 1))
    else
      # Unload if currently loaded
      if launchctl list 2>/dev/null | grep -q "$label"; then
        info "Unloading: $label"
        launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || \
          launchctl unload "$plist_path" 2>/dev/null || true
      fi

      # Remove plist file
      rm -f "$plist_path"
      success "Removed: $label"
      LAUNCHD_REMOVED=$((LAUNCHD_REMOVED + 1))
    fi
  done
fi

# ---------------------------------------------------------------------------
# Step 2: Remove installed scripts from $CLAWDBOT_HOME/scripts/
# ---------------------------------------------------------------------------
header "Removing Scripts"

SCRIPTS_DIR="$CLAWDBOT_HOME/scripts"

for script_name in "${PACKAGE_SCRIPTS[@]}"; do
  target="$SCRIPTS_DIR/$script_name"

  if [ ! -f "$target" ]; then
    info "$script_name — not installed, skipping"
    continue
  fi

  if $DRY_RUN; then
    dry "Would remove: $target"
    SCRIPTS_REMOVED=$((SCRIPTS_REMOVED + 1))
  else
    rm -f "$target"
    success "Removed: $script_name"
    SCRIPTS_REMOVED=$((SCRIPTS_REMOVED + 1))
  fi
done

# ---------------------------------------------------------------------------
# Step 3: Remove installed hooks from $CLAWDBOT_HOME/hooks/
# ---------------------------------------------------------------------------
header "Removing Hooks"

HOOKS_DIR="$CLAWDBOT_HOME/hooks"

for hook_name in "${PACKAGE_HOOKS[@]}"; do
  target_dir="$HOOKS_DIR/$hook_name"

  if [ ! -d "$target_dir" ]; then
    info "$hook_name — not installed, skipping"
    continue
  fi

  if $DRY_RUN; then
    dry "Would remove directory: $target_dir"
    HOOKS_REMOVED=$((HOOKS_REMOVED + 1))
  else
    rm -rf "$target_dir"
    success "Removed: $hook_name/"
    HOOKS_REMOVED=$((HOOKS_REMOVED + 1))
  fi
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
header "Uninstall Summary"

MODE_LABEL=""
if $DRY_RUN; then
  MODE_LABEL=" (DRY RUN — no changes made)"
fi

echo -e "${BOLD}clawdbot-memory-infra${NC}${MODE_LABEL}"
echo ""
echo "  LaunchD agents: $LAUNCHD_REMOVED removed"
echo "  Scripts:        $SCRIPTS_REMOVED removed"
echo "  Hooks:          $HOOKS_REMOVED removed"
echo ""

TOTAL=$((LAUNCHD_REMOVED + SCRIPTS_REMOVED + HOOKS_REMOVED))
if [ "$TOTAL" -eq 0 ]; then
  info "Nothing to remove — clawdbot-memory-infra does not appear to be installed."
fi

echo "Preserved (not touched):"
echo "  - $CLAWDBOT_HOME/clawdbot.json (config)"
echo "  - $CLAWDBOT_HOME/agents/*/sessions/ (session data)"
echo "  - All workspace memory/ directories"
echo "  - $CLAWDBOT_HOME/logs/ (log files)"
echo ""

if [ ${#WARNINGS[@]} -gt 0 ]; then
  echo -e "${YELLOW}Warnings:${NC}"
  for w in "${WARNINGS[@]}"; do
    echo "  - $w"
  done
  echo ""
fi

if ! $DRY_RUN && [ "$TOTAL" -gt 0 ]; then
  echo "To reinstall:"
  echo "  $(cd "$(dirname "$0")" && pwd)/install.sh"
fi
