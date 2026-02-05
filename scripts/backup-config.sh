#!/bin/bash
# Clawdbot Config Backup — Run before every config change
# Keeps last MAX_BACKUPS backups with timestamps
# Usage: backup-config.sh

CONFIG="${CLAWDBOT_HOME:-$HOME/.clawdbot}/clawdbot.json"
BACKUP_DIR="${CLAWDBOT_HOME:-$HOME/.clawdbot}/backups"
MAX_BACKUPS="${CLAWDBOT_MAX_BACKUPS:-10}"

mkdir -p -m 700 "$BACKUP_DIR"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_FILE="$BACKUP_DIR/clawdbot-${TIMESTAMP}.json"

cp "$CONFIG" "$BACKUP_FILE"
chmod 600 "$BACKUP_FILE"
echo "✅ Config backed up to: $BACKUP_FILE"

# Prune old backups, keep last MAX_BACKUPS
BACKUP_COUNT=$(ls -1 "$BACKUP_DIR"/clawdbot-*.json 2>/dev/null | wc -l | tr -d ' ')
if [ "$BACKUP_COUNT" -gt "$MAX_BACKUPS" ]; then
  PRUNE_COUNT=$((BACKUP_COUNT - MAX_BACKUPS))
  ls -1t "$BACKUP_DIR"/clawdbot-*.json | tail -n "$PRUNE_COUNT" | xargs rm -f
  echo "🗑  Pruned $PRUNE_COUNT old backup(s), keeping last $MAX_BACKUPS"
fi

echo "📁 Backups: $BACKUP_COUNT → $(ls -1 "$BACKUP_DIR"/clawdbot-*.json 2>/dev/null | wc -l | tr -d ' ')"
