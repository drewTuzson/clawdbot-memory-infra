#!/bin/bash
set -euo pipefail
# Clawdbot Session Transcript Cleanup
# - Compresses transcripts older than COMPRESS_AFTER_DAYS days
# - Deletes compressed transcripts older than DELETE_AFTER_DAYS days
# - Reports on storage before/after
# Usage: cleanup-sessions.sh [--dry-run]

DRY_RUN=false
if [ "${1:-}" = "--dry-run" ]; then
  DRY_RUN=true
  echo "🔍 DRY RUN — no files will be modified"
fi

AGENTS_DIR="${CLAWDBOT_HOME:-$HOME/.clawdbot}/agents"
COMPRESS_AFTER_DAYS="${CLAWDBOT_COMPRESS_DAYS:-7}"
DELETE_AFTER_DAYS="${CLAWDBOT_DELETE_DAYS:-30}"

# Validate numeric values
if ! [[ "$COMPRESS_AFTER_DAYS" =~ ^[0-9]+$ ]]; then
  echo "ERROR: CLAWDBOT_COMPRESS_DAYS must be numeric, got: $COMPRESS_AFTER_DAYS"
  exit 1
fi
if ! [[ "$DELETE_AFTER_DAYS" =~ ^[0-9]+$ ]]; then
  echo "ERROR: CLAWDBOT_DELETE_DAYS must be numeric, got: $DELETE_AFTER_DAYS"
  exit 1
fi

TOTAL_FREED=0
TOTAL_COMPRESSED=0
TOTAL_DELETED=0

echo "🧹 Session Transcript Cleanup — $(date)"
echo "---"

for agent_dir in "$AGENTS_DIR"/*/sessions; do
  [ -d "$agent_dir" ] || continue
  agent=$(echo "$agent_dir" | sed 's|.*/agents/||;s|/sessions||')

  # Count and size
  count=$(ls -1 "$agent_dir"/*.jsonl 2>/dev/null | wc -l | tr -d ' ')
  gz_count=$(ls -1 "$agent_dir"/*.jsonl.gz 2>/dev/null | wc -l | tr -d ' ')
  size=$(du -sh "$agent_dir" 2>/dev/null | cut -f1)

  echo "📁 $agent: $count transcripts + $gz_count compressed ($size)"

  # Compress files older than COMPRESS_AFTER_DAYS days (that aren't already compressed)
  while IFS= read -r file; do
    [ -z "$file" ] && continue
    orig_size=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null)

    if [ "$DRY_RUN" = true ]; then
      echo "   Would compress: $(basename "$file") ($(echo "$orig_size" | awk '{printf "%.1fKB", $1/1024}'))"
    else
      gzip "$file"
      new_size=$(stat -f%z "${file}.gz" 2>/dev/null || stat -c%s "${file}.gz" 2>/dev/null)
      saved=$((orig_size - new_size))
      TOTAL_FREED=$((TOTAL_FREED + saved))
      echo "   Compressed: $(basename "$file") ($(echo "$saved" | awk '{printf "%.1fKB", $1/1024}') saved)"
    fi
    TOTAL_COMPRESSED=$((TOTAL_COMPRESSED + 1))
  done < <(find "$agent_dir" -name "*.jsonl" -mtime +${COMPRESS_AFTER_DAYS} 2>/dev/null)

  # Delete compressed files older than DELETE_AFTER_DAYS days
  while IFS= read -r file; do
    [ -z "$file" ] && continue
    if [ "$DRY_RUN" = true ]; then
      echo "   Would delete: $(basename "$file")"
    else
      rm -f "$file"
      echo "   Deleted: $(basename "$file")"
    fi
    TOTAL_DELETED=$((TOTAL_DELETED + 1))
  done < <(find "$agent_dir" -name "*.jsonl.gz" -mtime +${DELETE_AFTER_DAYS} 2>/dev/null)
done

echo "---"
echo "📊 Sessions: $TOTAL_COMPRESSED compressed, $TOTAL_DELETED deleted"
if [ "$DRY_RUN" = false ] && [ $TOTAL_FREED -gt 0 ]; then
  echo "💾 Space freed: $(echo "$TOTAL_FREED" | awk '{printf "%.1fMB", $1/1048576}')"
fi

# --- Log rotation ---
# Rotate launchd stdout/stderr logs and health logs to prevent unbounded growth
CLAWDBOT_HOME_DIR="${CLAWDBOT_HOME:-$HOME/.clawdbot}"
LOG_MAX_SIZE="${CLAWDBOT_LOG_MAX_BYTES:-5242880}" # 5MB default
LOG_KEEP="${CLAWDBOT_LOG_KEEP:-3}" # Keep 3 rotated copies
LOGS_ROTATED=0

rotate_log() {
  local logfile="$1"
  [ -f "$logfile" ] || return
  local logsize
  logsize=$(stat -f%z "$logfile" 2>/dev/null || stat -c%s "$logfile" 2>/dev/null || echo "0")
  if [ "$logsize" -ge "$LOG_MAX_SIZE" ]; then
    if [ "$DRY_RUN" = true ]; then
      echo "   Would rotate: $logfile ($(echo "$logsize" | awk '{printf "%.1fMB", $1/1048576}'))"
    else
      # Shift existing rotated logs
      local i="$LOG_KEEP"
      while [ "$i" -gt 1 ]; do
        local prev=$((i - 1))
        [ -f "${logfile}.${prev}" ] && mv -f "${logfile}.${prev}" "${logfile}.${i}"
        i=$((i - 1))
      done
      mv -f "$logfile" "${logfile}.1"
      touch "$logfile"
      chmod 600 "$logfile"
      echo "   Rotated: $(basename "$logfile")"
    fi
    LOGS_ROTATED=$((LOGS_ROTATED + 1))
  fi
}

echo ""
echo "🔄 Log Rotation"
echo "---"

# Rotate launchd logs
for logfile in "$CLAWDBOT_HOME_DIR"/logs/*.log "$CLAWDBOT_HOME_DIR"/logs/*.err.log; do
  rotate_log "$logfile"
done

# Rotate health logs
for logfile in "$CLAWDBOT_HOME_DIR"/health/cron.log "$CLAWDBOT_HOME_DIR"/health/cron-error.log "$CLAWDBOT_HOME_DIR"/health/alert_log.txt; do
  rotate_log "$logfile"
done

echo "📊 Logs: $LOGS_ROTATED rotated (max ${LOG_MAX_SIZE} bytes, keep ${LOG_KEEP} copies)"
