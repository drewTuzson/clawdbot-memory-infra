#!/usr/bin/env bash
# regenerate-all-indexes.sh — Regenerate INDEX.md for all agent workspaces
# Runs generate-memory-index.sh for each workspace with a memory/ directory
# Intended to be called by launchd every 6 hours

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INDEX_SCRIPT="$SCRIPT_DIR/generate-memory-index.sh"
CONFIG="${CLAWDBOT_HOME:-$HOME/.clawdbot}/clawdbot.json"
MEMORY_SIZE_THRESHOLD="${MEMORY_SIZE_THRESHOLD:-50}"
LOG_PREFIX="[index-regen] $(date -u +%Y-%m-%dT%H:%M:%SZ)"

if [ ! -f "$INDEX_SCRIPT" ]; then
  echo "$LOG_PREFIX ERROR: generate-memory-index.sh not found at $INDEX_SCRIPT"
  exit 1
fi

if [ ! -f "$CONFIG" ]; then
  echo "$LOG_PREFIX ERROR: clawdbot.json not found"
  exit 1
fi

# Extract workspace paths from config using python3 (available on macOS)
WORKSPACES=$(python3 -c "
import json, sys, os
cfg = json.load(open(sys.argv[1]))
seen = set()
# Defaults workspace
dw = cfg.get('agents',{}).get('defaults',{}).get('workspace','')
if dw:
    dw = dw.replace('~', os.path.expanduser('~'))
    seen.add(dw)
    print(dw)
# Per-agent workspaces
for a in cfg.get('agents',{}).get('list',[]):
    w = a.get('workspace','')
    if w:
        w = w.replace('~', os.path.expanduser('~'))
        if w not in seen:
            seen.add(w)
            print(w)
" "$CONFIG" 2>/dev/null)

TOTAL=0
GENERATED=0

while IFS= read -r ws; do
  [ -z "$ws" ] && continue
  TOTAL=$((TOTAL + 1))
  MEMDIR="$ws/memory"
  if [ ! -d "$MEMDIR" ]; then
    continue
  fi

  # Only regenerate for workspaces with memory exceeding the threshold
  MEMSIZE=$(du -sk "$MEMDIR" 2>/dev/null | cut -f1)
  if [ "${MEMSIZE:-0}" -lt "$MEMORY_SIZE_THRESHOLD" ]; then
    continue
  fi

  echo "$LOG_PREFIX Regenerating INDEX for $ws (${MEMSIZE}KB)"
  bash "$INDEX_SCRIPT" "$ws" 2>&1
  GENERATED=$((GENERATED + 1))
done <<< "$WORKSPACES"

echo "$LOG_PREFIX Done. Generated $GENERATED/$TOTAL indexes."
