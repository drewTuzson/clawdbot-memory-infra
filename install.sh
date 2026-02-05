#!/bin/bash
set -euo pipefail

# install.sh — Install clawdbot-memory-infra
# Usage: ./install.sh [--dry-run] [--no-launchd] [--no-hooks] [--force]
#
# Installs scripts, hooks, and launchd agents for the clawdbot memory
# infrastructure. Safe to re-run — prompts before overwriting unless --force.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DRY_RUN=false
NO_LAUNCHD=false
NO_HOOKS=false
FORCE=false
CLAWDBOT_HOME="${CLAWDBOT_HOME:-$HOME/.clawdbot}"

# Counters
SCRIPTS_INSTALLED=0
SCRIPTS_SKIPPED=0
HOOKS_INSTALLED=0
HOOKS_SKIPPED=0
LAUNCHD_INSTALLED=0
LAUNCHD_SKIPPED=0
WARNINGS=()

# Parse args
for arg in "$@"; do
  case "$arg" in
    --dry-run)    DRY_RUN=true ;;
    --no-launchd) NO_LAUNCHD=true ;;
    --no-hooks)   NO_HOOKS=true ;;
    --force)      FORCE=true ;;
    -h|--help)
      echo "Usage: ./install.sh [--dry-run] [--no-launchd] [--no-hooks] [--force]"
      echo ""
      echo "Options:"
      echo "  --dry-run     Print what would happen without making changes"
      echo "  --no-launchd  Skip launchd agent installation"
      echo "  --no-hooks    Skip hook installation"
      echo "  --force       Overwrite existing files without prompting"
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

# Prompt for overwrite. Returns 0 (yes) or 1 (no).
# In --force mode, always returns 0. In --dry-run mode, always returns 1.
confirm_overwrite() {
  local target="$1"
  if $FORCE; then
    return 0
  fi
  if $DRY_RUN; then
    dry "Would prompt: Overwrite $target? (skipping in dry-run)"
    return 1
  fi
  read -r -p "  Overwrite $(basename "$target")? [y/N] " response
  case "$response" in
    [yY][eE][sS]|[yY]) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Step 1: Pre-flight checks
# ---------------------------------------------------------------------------
header "Pre-flight Checks"

# Check clawdbot config
if [ -f "$CLAWDBOT_HOME/clawdbot.json" ]; then
  success "Clawdbot config: $CLAWDBOT_HOME/clawdbot.json"
else
  error "Clawdbot config not found at $CLAWDBOT_HOME/clawdbot.json"
  error "Is clawdbot installed? Set CLAWDBOT_HOME if using a custom location."
  exit 1
fi

# Check node
if command -v node &>/dev/null; then
  NODE_VERSION=$(node --version 2>/dev/null || echo "unknown")
  success "Node.js: $(command -v node) ($NODE_VERSION)"
else
  error "node not found in PATH"
  error "Node.js is required for memory-checkpoint.js and session-rotation-monitor.js"
  exit 1
fi

# Check python3 (used by some bash scripts)
if command -v python3 &>/dev/null; then
  PY_VERSION=$(python3 --version 2>/dev/null || echo "unknown")
  success "Python3: $(command -v python3) ($PY_VERSION)"
else
  warn "python3 not found — some scripts (generate-memory-index.sh) may not work"
fi

# Find clawdbot dist
CLAWDBOT_DIST=""
DIST_CANDIDATES=(
  "$HOME/.npm-global/lib/node_modules/clawdbot/dist"
  "/usr/local/lib/node_modules/clawdbot/dist"
  "/usr/lib/node_modules/clawdbot/dist"
)
for candidate in "${DIST_CANDIDATES[@]}"; do
  if [ -d "$candidate" ] && [ -f "$candidate/gateway/call.js" ]; then
    CLAWDBOT_DIST="$candidate"
    break
  fi
done

if [ -n "$CLAWDBOT_DIST" ]; then
  success "Clawdbot dist: $CLAWDBOT_DIST"
else
  warn "Clawdbot dist not found (checked: ${DIST_CANDIDATES[*]})"
  warn "session-rotation-monitor.js will try to locate it at runtime"
fi

# Check repo structure
if [ ! -d "$SCRIPT_DIR/scripts" ]; then
  error "No scripts/ directory found in $SCRIPT_DIR — is this the right repo?"
  exit 1
fi

# ---------------------------------------------------------------------------
# Step 2: Copy scripts to $CLAWDBOT_HOME/scripts/
# ---------------------------------------------------------------------------
header "Installing Scripts"

SCRIPTS_DIR="$CLAWDBOT_HOME/scripts"

if $DRY_RUN; then
  dry "Would create directory: $SCRIPTS_DIR"
else
  mkdir -p "$SCRIPTS_DIR"
fi

for src_script in "$SCRIPT_DIR"/scripts/*; do
  [ -f "$src_script" ] || continue
  basename_script=$(basename "$src_script")
  target="$SCRIPTS_DIR/$basename_script"

  if [ -f "$target" ]; then
    # Check if content is identical
    if cmp -s "$src_script" "$target"; then
      info "$basename_script — already up to date, skipping"
      SCRIPTS_SKIPPED=$((SCRIPTS_SKIPPED + 1))
      continue
    fi

    info "$basename_script — target exists and differs"
    if ! confirm_overwrite "$target"; then
      info "$basename_script — skipped"
      SCRIPTS_SKIPPED=$((SCRIPTS_SKIPPED + 1))
      continue
    fi
  fi

  if $DRY_RUN; then
    dry "Would copy: $src_script -> $target"
    dry "Would chmod 700: $target"
    SCRIPTS_INSTALLED=$((SCRIPTS_INSTALLED + 1))
  else
    cp "$src_script" "$target"
    chmod 700 "$target"
    success "Installed: $basename_script"
    SCRIPTS_INSTALLED=$((SCRIPTS_INSTALLED + 1))
  fi
done

# ---------------------------------------------------------------------------
# Step 3: Copy hooks to $CLAWDBOT_HOME/hooks/ (unless --no-hooks)
# ---------------------------------------------------------------------------
if $NO_HOOKS; then
  header "Hooks (skipped — --no-hooks)"
else
  header "Installing Hooks"

  HOOKS_DIR="$CLAWDBOT_HOME/hooks"

  for hook_dir in "$SCRIPT_DIR"/hooks/*/; do
    [ -d "$hook_dir" ] || continue
    hook_name=$(basename "$hook_dir")
    target_hook_dir="$HOOKS_DIR/$hook_name"

    # Check if hook directory has any files to install
    hook_file_count=$(find "$hook_dir" -maxdepth 1 -type f | wc -l | tr -d ' ')
    if [ "$hook_file_count" -eq 0 ]; then
      info "$hook_name — no files in source directory, skipping"
      HOOKS_SKIPPED=$((HOOKS_SKIPPED + 1))
      continue
    fi

    if $DRY_RUN; then
      dry "Would create directory: $target_hook_dir"
    else
      mkdir -p "$target_hook_dir"
    fi

    hook_installed=false
    for hook_file in "$hook_dir"*; do
      [ -f "$hook_file" ] || continue
      basename_file=$(basename "$hook_file")
      target_file="$target_hook_dir/$basename_file"

      if [ -f "$target_file" ]; then
        if cmp -s "$hook_file" "$target_file"; then
          info "$hook_name/$basename_file — already up to date"
          continue
        fi

        info "$hook_name/$basename_file — target exists and differs"
        if ! confirm_overwrite "$target_file"; then
          info "$hook_name/$basename_file — skipped"
          continue
        fi
      fi

      if $DRY_RUN; then
        dry "Would copy: $hook_file -> $target_file"
        hook_installed=true
      else
        cp "$hook_file" "$target_file"
        chmod 600 "$target_file"
        success "Installed: $hook_name/$basename_file"
        hook_installed=true
      fi
    done

    if $hook_installed; then
      HOOKS_INSTALLED=$((HOOKS_INSTALLED + 1))
    else
      HOOKS_SKIPPED=$((HOOKS_SKIPPED + 1))
    fi
  done

  if [ $HOOKS_INSTALLED -eq 0 ] && [ $HOOKS_SKIPPED -eq 0 ]; then
    info "No hooks to install"
  fi
fi

# ---------------------------------------------------------------------------
# Step 4: Install LaunchD agents (unless --no-launchd, macOS only)
# ---------------------------------------------------------------------------
if $NO_LAUNCHD; then
  header "LaunchD Agents (skipped — --no-launchd)"
elif [ "$(uname)" != "Darwin" ]; then
  header "LaunchD Agents (skipped — not macOS)"
  warn "LaunchD agents are macOS-only. On Linux, use systemd or cron instead."
else
  header "Installing LaunchD Agents"

  LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
  LOGS_DIR="$CLAWDBOT_HOME/logs"
  HEALTH_DIR="$CLAWDBOT_HOME/health"

  if $DRY_RUN; then
    dry "Would create directories: $LAUNCH_AGENTS_DIR, $LOGS_DIR, $HEALTH_DIR"
  else
    mkdir -p "$LAUNCH_AGENTS_DIR"
    mkdir -p -m 700 "$LOGS_DIR"
    mkdir -p -m 700 "$HEALTH_DIR"
  fi

  for template in "$SCRIPT_DIR"/launchd/*.plist.template; do
    [ -f "$template" ] || continue
    template_name=$(basename "$template")
    # Strip .template suffix to get the plist name
    plist_name="${template_name%.template}"
    # Extract the label (e.g., com.clawdbot.memory-checkpoint)
    label="${plist_name%.plist}"
    target_plist="$LAUNCH_AGENTS_DIR/$plist_name"

    # Generate plist by replacing __HOME__ placeholder
    generated_content=$(sed "s|__HOME__|$HOME|g" "$template")

    if [ -f "$target_plist" ]; then
      # Check if content would be identical
      existing_content=$(cat "$target_plist")
      if [ "$generated_content" = "$existing_content" ]; then
        info "$plist_name — already up to date, skipping"
        LAUNCHD_SKIPPED=$((LAUNCHD_SKIPPED + 1))
        continue
      fi

      info "$plist_name — target exists and differs"
      if ! confirm_overwrite "$target_plist"; then
        info "$plist_name — skipped"
        LAUNCHD_SKIPPED=$((LAUNCHD_SKIPPED + 1))
        continue
      fi
    fi

    if $DRY_RUN; then
      dry "Would generate: $target_plist (from $template_name)"
      dry "Would replace __HOME__ with $HOME"

      # Check if currently loaded
      if launchctl list 2>/dev/null | grep -q "$label"; then
        dry "Would unload existing: $label"
      fi
      dry "Would load: $target_plist"
      LAUNCHD_INSTALLED=$((LAUNCHD_INSTALLED + 1))
    else
      # Unload if currently loaded
      if launchctl list 2>/dev/null | grep -q "$label"; then
        info "Unloading existing: $label"
        launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || \
          launchctl unload "$target_plist" 2>/dev/null || true
      fi

      # Write the generated plist
      echo "$generated_content" > "$target_plist"
      chmod 600 "$target_plist"

      # Load the new plist
      if launchctl bootstrap "gui/$(id -u)" "$target_plist" 2>/dev/null || \
         launchctl load "$target_plist" 2>/dev/null; then
        success "Installed and loaded: $plist_name ($label)"
        LAUNCHD_INSTALLED=$((LAUNCHD_INSTALLED + 1))
      else
        warn "Installed $plist_name but failed to load — try: launchctl load $target_plist"
        LAUNCHD_INSTALLED=$((LAUNCHD_INSTALLED + 1))
      fi
    fi
  done
fi

# ---------------------------------------------------------------------------
# Step 5: Run validate-config.sh (if available)
# ---------------------------------------------------------------------------
header "Config Validation"

VALIDATE_SCRIPT="$CLAWDBOT_HOME/scripts/validate-config.sh"
if [ -f "$VALIDATE_SCRIPT" ] && [ -x "$VALIDATE_SCRIPT" ]; then
  if $DRY_RUN; then
    dry "Would run: $VALIDATE_SCRIPT"
  else
    info "Running validate-config.sh..."
    if bash "$VALIDATE_SCRIPT"; then
      success "Config validation passed"
    else
      warn "Config validation reported issues (see above)"
    fi
  fi
else
  info "validate-config.sh not found at $VALIDATE_SCRIPT — skipping validation"
  info "(This is normal on first install; it may be provided by a different package)"
fi

# ---------------------------------------------------------------------------
# Step 6: Summary
# ---------------------------------------------------------------------------
header "Installation Summary"

MODE_LABEL=""
if $DRY_RUN; then
  MODE_LABEL=" (DRY RUN — no changes made)"
fi

echo -e "${BOLD}clawdbot-memory-infra${NC}${MODE_LABEL}"
echo ""
echo "  Scripts:       $SCRIPTS_INSTALLED installed, $SCRIPTS_SKIPPED skipped"
echo "  Hooks:         $HOOKS_INSTALLED installed, $HOOKS_SKIPPED skipped"
echo "  LaunchD:       $LAUNCHD_INSTALLED installed, $LAUNCHD_SKIPPED skipped"
echo ""
echo "  CLAWDBOT_HOME: $CLAWDBOT_HOME"
echo "  Scripts dir:   $CLAWDBOT_HOME/scripts/"
echo "  Hooks dir:     $CLAWDBOT_HOME/hooks/"
echo "  Logs dir:      $CLAWDBOT_HOME/logs/"
echo ""

if [ ${#WARNINGS[@]} -gt 0 ]; then
  echo -e "${YELLOW}Warnings:${NC}"
  for w in "${WARNINGS[@]}"; do
    echo "  - $w"
  done
  echo ""
fi

if ! $DRY_RUN; then
  echo "To verify launchd agents are running:"
  echo "  launchctl list | grep com.clawdbot"
  echo ""
  echo "To uninstall:"
  echo "  $SCRIPT_DIR/uninstall.sh"
fi
