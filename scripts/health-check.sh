#!/usr/bin/env bash
# health-check.sh — Structured health monitoring for Clawdbot
# Runs via system cron every 5 minutes. Alerts via Slack DM when issues detected.
# Does NOT depend on Clawdbot gateway (avoids circular dependency).

set -euo pipefail

# --- Temp file cleanup ---
_TMPFILES=()
cleanup_tmp() { rm -f "${_TMPFILES[@]}" 2>/dev/null; }
trap cleanup_tmp EXIT

# --- Load secrets from .env (safe parse, no source) ---
_env_file="${CLAWDBOT_HOME:-$HOME/.clawdbot}/.env"
if [[ -f "$_env_file" ]]; then
    # Verify .env is owned by current user and not world-readable
    _env_owner=$(stat -f %u "$_env_file" 2>/dev/null || stat -c %u "$_env_file" 2>/dev/null)
    _env_perms=$(stat -f %Lp "$_env_file" 2>/dev/null || stat -c %a "$_env_file" 2>/dev/null)
    if [[ "$_env_owner" != "$(id -u)" ]]; then
        echo "WARNING: .env file not owned by current user, skipping" >&2
    elif [[ "${_env_perms: -1}" != "0" ]]; then
        echo "WARNING: .env file is world-readable (mode ${_env_perms}), skipping. Run: chmod 600 $_env_file" >&2
    else
        # Safe parse: only read KEY=VALUE lines, skip comments and commands
        while IFS='=' read -r key value; do
            [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
            key=$(echo "$key" | tr -d '[:space:]')
            value="${value%\"}"
            value="${value#\"}"
            value="${value%\'}"
            value="${value#\'}"
            export "$key=$value"
        done < "$_env_file"
    fi
fi

# --- Configuration ---
GATEWAY_URL="http://127.0.0.1:18789"
GATEWAY_TOKEN="${CLAWDBOT_GATEWAY_TOKEN:-${GATEWAY_AUTH_TOKEN:-}}"
SLACK_TOKEN="${CLAWDBOT_ALERT_SLACK_TOKEN:-${SLACK_BOT_TOKEN:-}}"
ALERT_CHANNEL="${CLAWDBOT_ALERT_CHANNEL:-}"
ALERT_STATE_DIR="${CLAWDBOT_HOME:-$HOME/.clawdbot}/health"
ALERT_COOLDOWN_MINUTES="${CLAWDBOT_ALERT_COOLDOWN:-30}"
DISK_THRESHOLD_PERCENT="${CLAWDBOT_DISK_THRESHOLD:-90}"
MEMORY_THRESHOLD_PERCENT="${CLAWDBOT_MEMORY_THRESHOLD:-85}"
DEFAULT_WORKSPACE="${CLAWDBOT_DEFAULT_WORKSPACE:-$HOME/clawd}"

# --- Setup ---
mkdir -p "$ALERT_STATE_DIR"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S %Z')
ISSUES=()

# --- Helper: Check alert cooldown ---
should_alert() {
    local alert_key="$1"
    local state_file="$ALERT_STATE_DIR/${alert_key}.last"

    if [[ ! -f "$state_file" ]]; then
        return 0  # No previous alert, should alert
    fi

    local last_alert
    last_alert=$(cat "$state_file" 2>/dev/null || echo "0")
    local now
    now=$(date +%s)
    local diff=$(( now - last_alert ))
    local cooldown=$(( ALERT_COOLDOWN_MINUTES * 60 ))

    if [[ $diff -ge $cooldown ]]; then
        return 0  # Cooldown expired
    fi
    return 1  # Still in cooldown
}

mark_alerted() {
    local alert_key="$1"
    local state_file="$ALERT_STATE_DIR/${alert_key}.last"
    date +%s > "$state_file"
}

clear_alert() {
    local alert_key="$1"
    local state_file="$ALERT_STATE_DIR/${alert_key}.last"
    rm -f "$state_file"
}

# --- Check 1: Gateway reachable ---
check_gateway() {
    local http_code
    # Write auth header to temp file to avoid token exposure in process table
    local _gw_cfg
    _gw_cfg=$(mktemp)
    _TMPFILES+=("$_gw_cfg")
    chmod 600 "$_gw_cfg"
    printf 'header = "Authorization: Bearer %s"\n' "$GATEWAY_TOKEN" > "$_gw_cfg"
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout 5 --max-time 10 \
        -K "$_gw_cfg" \
        "${GATEWAY_URL}/api/health" 2>/dev/null || echo "000")
    rm -f "$_gw_cfg"

    if [[ "$http_code" == "000" ]]; then
        ISSUES+=("🔴 GATEWAY DOWN — Cannot reach ${GATEWAY_URL} (connection refused/timeout)")
    elif [[ "$http_code" != "200" && "$http_code" != "204" ]]; then
        ISSUES+=("🟡 GATEWAY UNHEALTHY — HTTP ${http_code} from health endpoint")
    else
        clear_alert "gateway_down"
    fi
}

# --- Check 2: Gateway process running ---
check_process() {
    if ! pgrep -f "clawdbot.*gateway" > /dev/null 2>&1; then
        # Double check with a broader pattern
        if ! pgrep -f "clawdbot" > /dev/null 2>&1; then
            ISSUES+=("🔴 GATEWAY PROCESS NOT FOUND — No clawdbot process running")
        fi
    fi
}

# --- Check 3: Disk space ---
check_disk() {
    local usage
    usage=$(df -h / | awk 'NR==2 {gsub(/%/,""); print $5}')

    if [[ "$usage" -ge "$DISK_THRESHOLD_PERCENT" ]]; then
        ISSUES+=("🟡 DISK SPACE LOW — ${usage}% used (threshold: ${DISK_THRESHOLD_PERCENT}%)")
    else
        clear_alert "disk_space"
    fi
}

# --- Check 4: Session transcript size ---
check_transcripts() {
    local sessions_dir="${CLAWDBOT_HOME:-$HOME/.clawdbot}/sessions"
    if [[ -d "$sessions_dir" ]]; then
        local total_size
        total_size=$(du -sm "$sessions_dir" 2>/dev/null | awk '{print $1}')

        if [[ "$total_size" -ge 500 ]]; then
            ISSUES+=("🟡 SESSION TRANSCRIPTS LARGE — ${total_size}MB in ${sessions_dir}")
        else
            clear_alert "transcript_size"
        fi
    fi
}

# --- Check 5: Memory files health ---
check_memory_files() {
    local memory_dir="$DEFAULT_WORKSPACE/memory"
    if [[ -d "$memory_dir" ]]; then
        # Check for any memory file > 50KB (getting too large for effective search)
        local large_files
        large_files=$(find "$memory_dir" -name "*.md" -not -path "*/archive/*" -size +50k 2>/dev/null | head -5)

        if [[ -n "$large_files" ]]; then
            local count
            count=$(echo "$large_files" | wc -l | tr -d ' ')
            ISSUES+=("🟡 MEMORY FILES OVERSIZED — ${count} file(s) over 50KB in memory/")
        fi
    fi
}

# --- Check 6: Cron health (check last run status) ---
check_cron_health() {
    local cron_dir="${CLAWDBOT_HOME:-$HOME/.clawdbot}/cron/runs"
    if [[ -d "$cron_dir" ]]; then
        # Check for recent error runs (last hour)
        local recent_errors=0
        local now
        now=$(date +%s)
        local one_hour_ago=$(( now - 3600 ))

        for run_file in "$cron_dir"/*.jsonl; do
            [[ -f "$run_file" ]] || continue
            # Check if file was modified in the last hour
            local mod_time
            mod_time=$(stat -f %m "$run_file" 2>/dev/null || stat -c %Y "$run_file" 2>/dev/null || echo "0")
            if [[ "$mod_time" -ge "$one_hour_ago" ]]; then
                if tail -1 "$run_file" 2>/dev/null | grep -q '"status":"error"'; then
                    recent_errors=$(( recent_errors + 1 ))
                fi
            fi
        done

        if [[ "$recent_errors" -ge 3 ]]; then
            ISSUES+=("🟡 CRON ERRORS — ${recent_errors} cron run errors in the last hour")
        else
            clear_alert "cron_errors"
        fi
    fi
}

# --- Run all checks ---
check_gateway
check_process
check_disk
check_transcripts
check_memory_files
check_cron_health

# --- Report ---
if [[ ${#ISSUES[@]} -eq 0 ]]; then
    # All clear — write healthy status for reference
    echo "${TIMESTAMP} — All checks passed" > "$ALERT_STATE_DIR/last_status.txt"
    exit 0
fi

# Build alert message
ALERT="⚠️ *Clawdbot Health Alert* — ${TIMESTAMP}\n\n"
for issue in "${ISSUES[@]}"; do
    ALERT+="${issue}\n"
done
ALERT+="\n_Auto-alert from health-check.sh (cooldown: ${ALERT_COOLDOWN_MINUTES}min)_"

# Check cooldown for the overall alert
ALERT_KEY="health_alert"
if should_alert "$ALERT_KEY"; then
    # Send Slack alert only if channel is configured
    if [[ -n "$ALERT_CHANNEL" && -n "$SLACK_TOKEN" ]]; then
        # Write auth header to temp file to avoid token in process table
        _curl_cfg=$(mktemp)
        _TMPFILES+=("$_curl_cfg")
        chmod 600 "$_curl_cfg"
        printf 'header = "Authorization: Bearer %s"\n' "$SLACK_TOKEN" > "$_curl_cfg"
        curl -s -X POST "https://slack.com/api/chat.postMessage" \
            -K "$_curl_cfg" \
            -H "Content-Type: application/json" \
            -d "{
                \"channel\": \"${ALERT_CHANNEL}\",
                \"text\": \"$(echo -e "$ALERT" | sed 's/"/\\"/g')\",
                \"unfurl_links\": false
            }" > /dev/null 2>&1
        rm -f "$_curl_cfg"
    fi

    mark_alerted "$ALERT_KEY"
    echo "${TIMESTAMP} — ALERT SENT: ${#ISSUES[@]} issue(s)" >> "$ALERT_STATE_DIR/alert_log.txt"
else
    echo "${TIMESTAMP} — Issues found but in cooldown: ${#ISSUES[@]} issue(s)" >> "$ALERT_STATE_DIR/alert_log.txt"
fi

# Write current status
echo "${TIMESTAMP} — ${#ISSUES[@]} issue(s) found" > "$ALERT_STATE_DIR/last_status.txt"
for issue in "${ISSUES[@]}"; do
    echo "  ${issue}" >> "$ALERT_STATE_DIR/last_status.txt"
done

exit 1
