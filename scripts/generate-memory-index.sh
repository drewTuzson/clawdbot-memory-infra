#!/usr/bin/env bash
# generate-memory-index.sh — Generates a compact INDEX.md for progressive memory disclosure
# Scans all memory/*.md files, categorizes them, computes sizes and observation counts
# Output: memory/INDEX.md (~800-1500 tokens)

set -euo pipefail

WORKSPACE="${1:-$HOME/clawd}"
MEMORY_DIR="$WORKSPACE/memory"
INDEX_FILE="$MEMORY_DIR/INDEX.md"

if [ ! -d "$MEMORY_DIR" ]; then
  echo "Error: Memory directory not found: $MEMORY_DIR"
  exit 1
fi

# Temp files for categorization
CORE_FILES=$(mktemp)
UQUAL_FILES=$(mktemp)
RESEARCH_FILES=$(mktemp)
SESSION_FILES=$(mktemp)
CONFIG_FILES=$(mktemp)
PROJECT_FILES=$(mktemp)
PLAN_FILES=$(mktemp)
OTHER_FILES=$(mktemp)
trap "rm -f $CORE_FILES $UQUAL_FILES $RESEARCH_FILES $SESSION_FILES $CONFIG_FILES $PROJECT_FILES $PLAN_FILES $OTHER_FILES" EXIT

TOTAL_SIZE=0
TOTAL_FILES=0
TOTAL_DECISIONS=0
TOTAL_GOTCHAS=0
TOTAL_SOLUTIONS=0
TOTAL_PATTERNS=0
TOTAL_TODOS=0

# Function to estimate tokens (~4 chars per token for English text)
estimate_tokens() {
  local bytes=$1
  echo $(( bytes / 4 ))
}

# Function to format file size
format_size() {
  local bytes=$1
  if [ "$bytes" -ge 1048576 ]; then
    echo "$(( bytes / 1048576 ))MB"
  elif [ "$bytes" -ge 1024 ]; then
    echo "$(( bytes / 1024 ))KB"
  else
    echo "${bytes}B"
  fi
}

# Function to count observation markers in a file
# count_observations sets OBS_STR and updates TOTAL_* globals
# MUST be called directly (not in a subshell) to preserve global state
count_observations() {
  local file=$1
  local decisions; decisions=$(grep -c '\[DECISION\]' "$file" 2>/dev/null) || true; decisions=${decisions:-0}
  local gotchas; gotchas=$(grep -c '\[GOTCHA\]' "$file" 2>/dev/null) || true; gotchas=${gotchas:-0}
  local solutions; solutions=$(grep -c '\[SOLUTION\]' "$file" 2>/dev/null) || true; solutions=${solutions:-0}
  local patterns; patterns=$(grep -c '\[PATTERN\]' "$file" 2>/dev/null) || true; patterns=${patterns:-0}
  local tradeoffs; tradeoffs=$(grep -c '\[TRADEOFF\]' "$file" 2>/dev/null) || true; tradeoffs=${tradeoffs:-0}
  local facts; facts=$(grep -c '\[FACT\]' "$file" 2>/dev/null) || true; facts=${facts:-0}
  local prefs; prefs=$(grep -c '\[PREFERENCE\]' "$file" 2>/dev/null) || true; prefs=${prefs:-0}
  local todos; todos=$(grep -c '\[TODO\]' "$file" 2>/dev/null) || true; todos=${todos:-0}

  TOTAL_DECISIONS=$(( TOTAL_DECISIONS + decisions ))
  TOTAL_GOTCHAS=$(( TOTAL_GOTCHAS + gotchas ))
  TOTAL_SOLUTIONS=$(( TOTAL_SOLUTIONS + solutions ))
  TOTAL_PATTERNS=$(( TOTAL_PATTERNS + patterns ))
  TOTAL_TODOS=$(( TOTAL_TODOS + todos ))

  OBS_STR=""
  [ "$decisions" -gt 0 ] && OBS_STR="${OBS_STR}${decisions}🟤 "
  [ "$gotchas" -gt 0 ] && OBS_STR="${OBS_STR}${gotchas}🔴 "
  [ "$solutions" -gt 0 ] && OBS_STR="${OBS_STR}${solutions}🟡 "
  [ "$patterns" -gt 0 ] && OBS_STR="${OBS_STR}${patterns}🔵 "
  [ "$tradeoffs" -gt 0 ] && OBS_STR="${OBS_STR}${tradeoffs}⚖️ "
  [ "$facts" -gt 0 ] && OBS_STR="${OBS_STR}${facts}🟢 "
  [ "$prefs" -gt 0 ] && OBS_STR="${OBS_STR}${prefs}🟣 "
  [ "$todos" -gt 0 ] && OBS_STR="${OBS_STR}${todos}⚪ "

  OBS_STR="${OBS_STR:-—}"
}

# Function to get first heading or filename
get_title() {
  local file=$1
  local heading=$(grep -m1 '^#' "$file" 2>/dev/null | sed 's/^#* *//')
  if [ -n "$heading" ]; then
    # Truncate to 60 chars
    echo "${heading:0:60}"
  else
    basename "$file" .md
  fi
}

# Categorize and process each file
for file in "$MEMORY_DIR"/*.md; do
  [ -f "$file" ] || continue

  fname=$(basename "$file")

  # Skip INDEX.md itself
  [ "$fname" = "INDEX.md" ] && continue

  fsize=$(wc -c < "$file" | tr -d ' ')
  TOTAL_SIZE=$(( TOTAL_SIZE + fsize ))
  TOTAL_FILES=$(( TOTAL_FILES + 1 ))

  tokens=$(estimate_tokens "$fsize")
  size_fmt=$(format_size "$fsize")
  title=$(get_title "$file")
  count_observations "$file"
  modified=$(stat -f "%Sm" -t "%Y-%m-%d" "$file" 2>/dev/null || date -r "$file" +"%Y-%m-%d" 2>/dev/null || echo "unknown")

  line="| ${fname} | ${title} | ${size_fmt} | ~${tokens} | ${OBS_STR} | ${modified} |"

  # Categorize
  case "$fname" in
    ACTIVE_CONTEXT.md|overnight-run-state.md|slack-mission-control.md)
      echo "$line" >> "$CORE_FILES"
      ;;
    uqual-*)
      echo "$line" >> "$UQUAL_FILES"
      ;;
    research-*)
      echo "$line" >> "$RESEARCH_FILES"
      ;;
    20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]*)
      echo "$line" >> "$SESSION_FILES"
      ;;
    *-config.md|credentials-*)
      echo "$line" >> "$CONFIG_FILES"
      ;;
    plan-*|procedure-*)
      echo "$line" >> "$PLAN_FILES"
      ;;
    *-setup*|*-checklist*)
      echo "$line" >> "$PROJECT_FILES"
      ;;
    *)
      echo "$line" >> "$OTHER_FILES"
      ;;
  esac
done

# Generate INDEX.md
TOTAL_SIZE_FMT=$(format_size "$TOTAL_SIZE")
TOTAL_TOKENS=$(estimate_tokens "$TOTAL_SIZE")
GENERATED=$(date '+%Y-%m-%d %H:%M %Z')

cat > "$INDEX_FILE" << HEADER
# Memory Index
> **Generated**: ${GENERATED} | **Files**: ${TOTAL_FILES} | **Size**: ${TOTAL_SIZE_FMT} | **~Tokens**: ${TOTAL_TOKENS}
> **Observations**: ${TOTAL_DECISIONS}🟤 decisions | ${TOTAL_GOTCHAS}🔴 gotchas | ${TOTAL_SOLUTIONS}🟡 solutions | ${TOTAL_PATTERNS}🔵 patterns | ${TOTAL_TODOS}⚪ todos

## How to Use This Index
- **Don't load everything.** Use \`memory_search\` to find relevant files, then \`memory_get\` to read specific sections.
- **Always load**: ACTIVE_CONTEXT.md (current working state)
- **Load on demand**: Everything else based on the task at hand
- Observation markers: 🔴 GOTCHA | 🟤 DECISION | ⚖️ TRADEOFF | 🟡 SOLUTION | 🔵 PATTERN | 🟢 FACT | 🟣 PREFERENCE | ⚪ TODO

HEADER

# Table header
TABLE_HEADER="| File | Title | Size | Tokens | Observations | Modified |
|------|-------|------|--------|-------------|----------|"

# Write each category
write_category() {
  local label=$1
  local file=$2
  local desc=$3

  if [ -s "$file" ]; then
    echo "" >> "$INDEX_FILE"
    echo "### ${label}" >> "$INDEX_FILE"
    [ -n "$desc" ] && echo "_${desc}_" >> "$INDEX_FILE"
    echo "" >> "$INDEX_FILE"
    echo "$TABLE_HEADER" >> "$INDEX_FILE"
    sort -t'|' -k6 -r "$file" >> "$INDEX_FILE"
  fi
}

write_category "🔑 Core State (always load ACTIVE_CONTEXT)" "$CORE_FILES" "Current working state, overnight run status, mission control config"
write_category "🏢 UQUAL Domain" "$UQUAL_FILES" "Business strategy, repos, credit/finance domain, marketing context"
write_category "📋 Plans & Procedures" "$PLAN_FILES" "Implementation plans, deployment procedures, checklists"
write_category "⚙️ Config & Credentials" "$CONFIG_FILES" "Integration configs, API keys, service connections"
write_category "🔬 Research Reports" "$RESEARCH_FILES" "Deep research output from sub-agents"
write_category "🏗️ Project Setup" "$PROJECT_FILES" "Agent setup checklists, project scaffolding"
write_category "📅 Session Logs" "$SESSION_FILES" "Daily session notes and decisions"
write_category "📁 Other" "$OTHER_FILES" "Uncategorized memory files"

echo ""
echo "Index generated: $INDEX_FILE"
echo "Files: $TOTAL_FILES | Size: $TOTAL_SIZE_FMT | ~Tokens: $TOTAL_TOKENS"
