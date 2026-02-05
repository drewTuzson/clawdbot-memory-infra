# clawdbot-memory-infra

Defense-in-depth memory persistence for Clawdbot multi-agent deployments.

## The Problem

Multi-agent orchestration platforms like Clawdbot suffer from a fundamental weakness: **context window exhaustion**. As agents accumulate conversation history, memory files, and tool outputs over a session, they approach the token limit. When compaction fires to reclaim space, it produces a summary of the discarded context and continues. In theory, this preserves the important bits. In practice, the agent experiences a "lobotomy" -- it forgets key decisions, repeats work it already completed, and ships bugs because it lost the context that informed earlier choices.

This problem is compounded by two additional failure modes. First, the compaction mechanism itself can be broken. Clawdbot's `safeguard` compaction mode contains a bug where `ExtensionRunner.initialize()` is never called, causing every compaction to produce a "Summary unavailable" placeholder instead of an actual context summary. Every agent running `safeguard` mode loses *everything* on compaction, not just the less-important context. Second, the standard approach to memory persistence -- instructing the LLM to flush its working state to files before compaction -- relies on LLM instruction compliance. LLMs skip the flush, do it partially, or produce summaries that omit critical details. You cannot build reliable infrastructure on "please remember to save."

This project implements a layered defense strategy. No single mechanism is sufficient, so we deploy four independent layers that each address a different failure mode. If one layer fails, the others catch it.

## Architecture

```
+---------------------------------------------------------------+
|  Layer 1: Session Rotation Monitor                            |
|  Rotate sessions at 150K tokens before the 200K compaction    |
|  threshold. Prevents compaction from being the primary path.  |
+---------------------------------------------------------------+
                            |
                            v
+---------------------------------------------------------------+
|  Layer 2: Memory Checkpointing                                |
|  Every 20 min, programmatically extract context from JSONL    |
|  session files. No LLM dependency. Writes ACTIVE_CONTEXT.md   |
|  and daily logs.                                              |
+---------------------------------------------------------------+
                            |
                            v
+---------------------------------------------------------------+
|  Layer 3: Fixed Compaction                                    |
|  Config fix: compaction.mode "default" instead of "safeguard" |
|  When compaction does fire, it produces real summaries.       |
+---------------------------------------------------------------+
                            |
                            v
+---------------------------------------------------------------+
|  Layer 4: Progressive Memory Loading                          |
|  INDEX.md injected at bootstrap instead of full memory dump.  |
|  Agents load ~1-2K tokens instead of 200K+. Load on demand.  |
+---------------------------------------------------------------+
```

## Components

### Scripts

| Script | Description | Schedule |
|--------|-------------|----------|
| `scripts/session-rotation-monitor.js` | Monitors session token counts via gateway API; rotates sessions exceeding the threshold before compaction fires | Every 30 min |
| `scripts/memory-checkpoint.js` | Reads JSONL session files directly; extracts recent messages; writes `ACTIVE_CONTEXT.md` and daily logs | Every 20 min |
| `scripts/generate-memory-index.sh` | Scans `memory/*.md` files, categorizes them, computes sizes and observation counts, produces a compact `INDEX.md` | On demand |
| `scripts/regenerate-all-indexes.sh` | Runs `generate-memory-index.sh` for every agent workspace exceeding the memory size threshold | Every 6 hours |
| `scripts/health-check.sh` | Monitors gateway health, disk space, transcript sizes, memory file sizes, and cron job status; alerts via Slack | Every 5 min |
| `scripts/validate-config.sh` | Pre-flight config validation: catches type errors, orphaned bindings, and ordering bugs before they crash the gateway | Before config changes |
| `scripts/cleanup-sessions.sh` | Compresses old session transcripts, deletes sessions past retention threshold, and rotates log files | On demand / cron |
| `scripts/backup-config.sh` | Creates timestamped `clawdbot.json` snapshots; retains the most recent N backups | Before config changes |

### Hooks

| Hook | Event | Description |
|------|-------|-------------|
| `hooks/memory-index-inject` | `agent:bootstrap` | Injects `INDEX.md` + `ACTIVE_CONTEXT.md` at agent startup for agents with large memory pools (>50KB). Replaces full memory dump with progressive disclosure. |
| `hooks/session-summary` | `command:new` | Generates structured session summaries with typed observation markers (`[DECISION]`, `[GOTCHA]`, `[SOLUTION]`, `[PATTERN]`, `[TODO]`) on session rotation. |

### LaunchD Templates

| Template | Interval | Purpose |
|----------|----------|---------|
| `launchd/com.clawdbot.session-rotation.plist.template` | 1800s (30 min) | Session rotation monitor |
| `launchd/com.clawdbot.memory-checkpoint.plist.template` | 1200s (20 min) | Memory checkpointing |
| `launchd/com.clawdbot.index-regen.plist.template` | 21600s (6 hours) | INDEX.md regeneration |
| `launchd/com.clawdbot.healthcheck.plist.template` | 300s (5 min) | Health monitoring |

## Quick Start

```bash
# Clone the repository
git clone https://github.com/drewTuzson/clawdbot-memory-infra.git
cd clawdbot-memory-infra

# Preview what will be installed
./install.sh --dry-run

# Install everything (scripts, hooks, launchd agents)
./install.sh

# Or install selectively
./install.sh --no-launchd    # Skip launchd (use cron or systemd instead)
./install.sh --no-hooks      # Skip hook installation

# Generate initial INDEX.md for your workspace
bash ~/.clawdbot/scripts/generate-memory-index.sh ~/your-workspace

# Apply the compaction fix (see docs/compaction-bug.md)
# Edit ~/.clawdbot/clawdbot.json:
#   "compaction": { "mode": "default" }

# Restart the gateway for hook changes to take effect
launchctl stop com.clawdbot.gateway && launchctl start com.clawdbot.gateway
```

To uninstall:

```bash
./uninstall.sh           # Remove all installed components
./uninstall.sh --dry-run # Preview what would be removed
```

## Configuration

All configuration is via environment variables. Defaults are sensible for most deployments.

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAWDBOT_HOME` | `~/.clawdbot` | Root directory for Clawdbot configuration and data |
| `CLAWDBOT_DIST` | *(auto-detected)* | Path to the Clawdbot `dist/` directory. Set this if Clawdbot is installed in a non-standard location. |
| `ROTATION_THRESHOLD` | `150000` | Token count at which session rotation triggers. Should be well below the compaction threshold (typically 200K). |
| `SESSION_STALE_HOURS` | `4` | Sessions not modified within this window are skipped by the checkpoint script. |
| `MEMORY_SIZE_THRESHOLD` | `50` | Minimum memory directory size (KB) for INDEX.md regeneration. Workspaces below this threshold are skipped. |
| `CLAWDBOT_GATEWAY_TOKEN` | *(from .env)* | Authentication token for the Clawdbot gateway WebSocket API. Used by health-check.sh. |
| `CLAWDBOT_ALERT_CHANNEL` | *(none)* | Slack channel ID for health alerts. If unset, alerts are logged but not sent. |
| `CLAWDBOT_ALERT_SLACK_TOKEN` | *(from .env)* | Slack bot token for sending alert messages. |
| `CLAWDBOT_ALERT_COOLDOWN` | `30` | Minimum minutes between repeated alerts for the same issue. Prevents alert fatigue. |
| `CLAWDBOT_DISK_THRESHOLD` | `90` | Disk usage percentage that triggers a health alert. |
| `CLAWDBOT_COMPRESS_DAYS` | *(none)* | Days after which old session files are compressed. Used by session cleanup scripts. |
| `CLAWDBOT_DELETE_DAYS` | *(none)* | Days after which compressed session files are deleted. Used by session cleanup scripts. |
| `CLAWDBOT_MAX_BACKUPS` | *(none)* | Maximum number of config backup files to retain. |
| `CLAWDBOT_LOG_MAX_BYTES` | `5242880` | Maximum log file size (bytes) before rotation. Used by cleanup-sessions.sh. |
| `CLAWDBOT_LOG_KEEP` | `3` | Number of rotated log copies to retain. |

## Requirements

- **macOS** -- LaunchD plist templates are macOS-specific. Linux users can adapt them to systemd timers or cron.
- **Node.js 18+** -- Required for ESM `import()` syntax used by the scripts and hooks.
- **Python 3** -- Used by `regenerate-all-indexes.sh` to parse `clawdbot.json` for workspace discovery.
- **Clawdbot** -- The gateway must be installed and running. Scripts communicate via the gateway WebSocket API (`ws://127.0.0.1:18789`).

## Security

Credentials, session transcripts, and memory files are sensitive. This project implements several hardening measures:

- **Safe credential loading** -- `.env` files are parsed as key=value text, not `source`d. Ownership and permission checks are enforced before reading.
- **No token exposure in process table** -- API tokens are passed to `curl` via temporary config files (`-K`), not command-line arguments.
- **Safe JSON construction** -- Slack API payloads are built using `python3 json.dumps` for proper escaping, with a sed-based fallback.
- **No command injection** -- Python inline scripts receive file paths as `sys.argv[1]`, not interpolated into source code.
- **Restrictive file permissions** -- Scripts `700`, hooks `600`, output files `600`, directories `700`.
- **Repository safety** -- `.gitignore` prevents accidental commits of `.env`, `clawdbot.json`, memory files, session transcripts, and logs.

See [docs/security.md](docs/security.md) for the full threat model and deployment recommendations.

## Documentation

- [Architecture: Defense in Depth](docs/architecture.md) -- Detailed explanation of each layer and how they interact
- [Compaction Bug](docs/compaction-bug.md) -- Root cause analysis of the `safeguard` mode empty summary bug
- [Recommended Configuration](docs/config-recommendations.md) -- Tuning guide for Clawdbot settings that affect memory persistence
- [Security](docs/security.md) -- Threat model, credential handling, file permissions, and deployment recommendations

## License

MIT -- see [LICENSE](LICENSE).
