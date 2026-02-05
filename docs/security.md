# Security Considerations

This project handles credentials, session transcripts, and agent memory files. The following hardening measures are implemented and should be understood before deployment.

## Threat Model

The primary attack surface is the local filesystem. These scripts run on the same machine as the Clawdbot gateway and have access to:

- **Gateway authentication tokens** (WebSocket API, Slack bot tokens)
- **Session transcripts** (JSONL files containing full conversation history)
- **Memory files** (Markdown files with agent knowledge, decisions, and project context)
- **Configuration files** (`clawdbot.json` with agent definitions, channel bindings, credentials)

The threat model assumes a trusted local user on a single-user workstation. The hardening measures protect against:

1. **Accidental credential leakage** (process table exposure, git commits, log files)
2. **Unsafe file permissions** (world-readable secrets or memory files)
3. **Command injection** via config file contents or environment variables
4. **Unintended data exposure** in the public repository

## Credential Handling

### .env File Parsing

`health-check.sh` loads credentials from `$CLAWDBOT_HOME/.env`. Instead of `source`-ing the file (which would execute arbitrary shell commands), it uses safe key=value parsing:

```bash
# Verify ownership and permissions before reading
_env_owner=$(stat -f %u "$_env_file" 2>/dev/null || stat -c %u "$_env_file" 2>/dev/null)
_env_perms=$(stat -f %Lp "$_env_file" 2>/dev/null || stat -c %a "$_env_file" 2>/dev/null)

if [[ "$_env_owner" != "$(id -u)" ]]; then
    echo "WARNING: .env file not owned by current user, skipping" >&2
elif [[ "${_env_perms: -1}" != "0" ]]; then
    echo "WARNING: .env file is world-readable, skipping" >&2
else
    while IFS='=' read -r key value; do
        [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
        key=$(echo "$key" | tr -d '[:space:]')
        value="${value%\"}" ; value="${value#\"}"
        export "$key=$value"
    done < "$_env_file"
fi
```

This prevents:
- Execution of embedded shell commands (`$(cmd)`, backticks)
- Reading files owned by another user
- Reading files with world-readable permissions

### Token Exposure Prevention

API tokens passed to `curl` via `-H "Authorization: Bearer $TOKEN"` are visible in the process table (`ps aux`). All curl calls in `health-check.sh` now use temporary config files:

```bash
_gw_cfg=$(mktemp)
_TMPFILES+=("$_gw_cfg")
chmod 600 "$_gw_cfg"
printf 'header = "Authorization: Bearer %s"\n' "$GATEWAY_TOKEN" > "$_gw_cfg"
curl -s -K "$_gw_cfg" "${GATEWAY_URL}/api/health"
rm -f "$_gw_cfg"
```

Temp files are cleaned up via an `EXIT` trap that removes all files in the `_TMPFILES` array, even if the script exits abnormally.

### Slack API JSON Construction

`health-check.sh` sends alert payloads to the Slack API. Instead of constructing JSON via string interpolation (which is fragile with special characters, backslashes, and quotes), payloads are built safely:

```bash
# Primary: use python3 json.dumps for correct escaping
_alert_text=$(printf '%s' "$ALERT" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))")

# Fallback: basic sed escaping if python3 unavailable
_alert_text="\"$(printf '%s' "$ALERT" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g' | tr '\n' ' ')\""

# Payload written to temp file, passed to curl via -d @file
printf '{"channel":"%s","text":%s,"unfurl_links":false}\n' "$ALERT_CHANNEL" "$_alert_text" > "$_json_payload"
```

This prevents JSON syntax errors from causing silent alert delivery failures.

### Python Inline Scripts

`validate-config.sh` and `regenerate-all-indexes.sh` use inline Python to parse `clawdbot.json`. Config file paths are passed as `sys.argv[1]` rather than interpolated into the Python source:

```bash
# Safe: path passed as argument
python3 -c "import json, sys; json.load(open(sys.argv[1]))" "$CONFIG"

# Unsafe (was): path interpolated into code
# python3 -c "import json; json.load(open('$CONFIG'))"
```

The unsafe pattern allows a crafted config path to inject arbitrary Python code. While unlikely in practice (the path comes from a local env var), the fix eliminates the vector entirely.

## File Permissions

### Scripts

All scripts are installed with `chmod 700` (owner read/write/execute only). This prevents other users on a shared system from reading scripts that may contain operational details about the deployment.

### Hooks

Hook files are installed with `chmod 600` (owner read/write only). The Clawdbot hook loader reads them via the Node.js process running as the same user.

### LaunchD Plists

Plist files are installed with `chmod 600`. They contain paths to scripts and log files that could reveal system layout.

### Output Files

Scripts that write files set restrictive permissions on creation:

| Script | Output | Permissions |
|--------|--------|-------------|
| `memory-checkpoint.js` | `ACTIVE_CONTEXT.md` | `0o600` |
| `memory-checkpoint.js` | Daily log files | `0o600` |
| `memory-checkpoint.js` | Memory directories | `0o700` |
| `session-summary/handler.js` | Session summaries | `0o600` |
| `session-summary/handler.js` | Memory directories | `0o700` |
| `backup-config.sh` | Config backups | `600` |
| `cleanup-sessions.sh` | Rotated log files | `600` |
| `install.sh` | Log directories | `700` |
| `install.sh` | Health directories | `700` |

### .env File

The `.env` file at `$CLAWDBOT_HOME/.env` should be `chmod 600` and owned by the user running the gateway:

```bash
chmod 600 ~/.clawdbot/.env
```

## Repository Safety

### .gitignore

The repository includes a `.gitignore` that prevents accidental commits of sensitive files:

```
.env, .env.*          # Credentials
clawdbot.json         # Config with potential secrets
memory/               # Agent memory (may contain PII)
*.log, *.err.log      # Log files
backups/              # Config backups
health/               # Health state files
*.jsonl, *.jsonl.gz   # Session transcripts
```

### What the Repo Contains

The repository contains only scripts, hooks, plist templates, and documentation. It does **not** contain:

- API keys or tokens
- Agent names or channel IDs specific to any deployment
- Session transcripts or memory content
- `clawdbot.json` configuration
- Log files or health state

All deployment-specific values are configured via environment variables.

## Input Validation

### Environment Variables

Scripts that accept numeric environment variables validate them before use:

```bash
# cleanup-sessions.sh
if ! [[ "$COMPRESS_AFTER_DAYS" =~ ^[0-9]+$ ]]; then
    echo "ERROR: COMPRESS_AFTER_DAYS must be a positive integer" >&2
    exit 1
fi
```

### Config File Paths

The `validate-config.sh` script checks that the config file exists and is valid JSON before processing. Python blocks receive the path as a command-line argument rather than an interpolated string.

## Deployment Recommendations

1. **Run as a dedicated user.** If possible, run the Clawdbot gateway and all infrastructure scripts under a dedicated user account rather than your primary login.

2. **Set `.env` permissions immediately.** After creating `~/.clawdbot/.env`, run `chmod 600 ~/.clawdbot/.env`.

3. **Audit before installing.** Run `./install.sh --dry-run` to see exactly what will be installed and where. Review the script source before running with real changes.

4. **Keep the gateway token scoped.** The `CLAWDBOT_GATEWAY_TOKEN` should only have the permissions needed by the health check (read-only access to the health endpoint and session list).

5. **Review memory files periodically.** Memory files may accumulate PII from conversations. Consider implementing a retention policy for memory files in workspaces.

6. **Back up before updating.** Run `backup-config.sh` before applying config changes. The installer prompts before overwriting existing files unless `--force` is used.
