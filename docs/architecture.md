# Architecture: Defense in Depth for Agent Memory

## Overview

Agent memory persistence is a deceptively hard problem. A single solution is never enough because there are multiple independent failure modes:

- **Compaction can break.** The `safeguard` mode bug produces empty summaries, turning every compaction into total context loss. Even with the fix applied (`default` mode), compaction is a lossy process -- summaries are shorter than the original content, and the LLM decides what to keep.
- **LLM instruction compliance is unreliable.** You can tell an agent "flush your working state to memory files before the session ends," but LLMs skip steps, produce incomplete summaries, or simply ignore the instruction under cognitive load. Memory persistence that depends on the LLM remembering to save is not persistence at all.
- **Memory pools grow unbounded.** Without active management, agents accumulate hundreds of kilobytes of memory files. Loading all of them at bootstrap wastes half the context window before the agent does any actual work, accelerating the very compaction problem you are trying to avoid.
- **Sessions run too long.** A session that stays open for hours accumulates enough token history to trigger compaction. Even with working compaction, the summary cannot capture everything from a 200K-token conversation.

This project addresses each failure mode with an independent mechanism. The layers are designed to be redundant -- if any single layer fails, the others still protect the agent's working state.

## Layer 1 -- Session Rotation

**Component:** `scripts/session-rotation-monitor.js`
**Schedule:** Every 30 minutes via LaunchD
**Gateway API:** `sessions.list`, `sessions.reset`

### What It Does

The session rotation monitor queries the Clawdbot gateway for all active sessions and their token counts. Any session exceeding the configurable threshold (default: 150,000 tokens) is rotated -- the current session is closed and a fresh one is opened.

The threshold of 150K is deliberately set well below the typical 200K compaction trigger. This gap ensures rotation happens *before* compaction fires, making compaction a fallback rather than the primary recovery mechanism.

### What It Skips

Not all sessions should be auto-rotated. The monitor skips:

- **Cron sessions** (`agent:*:cron:*`) -- These are ephemeral single-task sessions that clean themselves up.
- **Sub-agent sessions** (`agent:*:subagent:*`) -- These are managed by a parent agent and should not be interrupted.

### Recovery Path

When a session is rotated, the agent receives a fresh context window on its next interaction. The `memory-index-inject` hook (Layer 4) fires at bootstrap, providing the agent with its `INDEX.md` and `ACTIVE_CONTEXT.md`. The `ACTIVE_CONTEXT.md` file, maintained by the checkpoint system (Layer 2), contains the agent's recent working state. Together, these give the rotated agent enough context to resume work without re-reading its entire history.

## Layer 2 -- Memory Checkpointing

**Component:** `scripts/memory-checkpoint.js`
**Schedule:** Every 20 minutes via LaunchD
**Data source:** JSONL session files on disk (no gateway or LLM dependency)

### What It Does

The checkpoint script iterates over all configured agents and, for each one:

1. Finds the most recently modified `.jsonl` session file in `~/.clawdbot/agents/{agentId}/sessions/`.
2. Reads the last 60 lines from the file. For files over 512KB, only the tail chunk is read to avoid loading multi-megabyte transcripts into memory.
3. Extracts text content from user and assistant messages, skipping thinking blocks, tool calls, heartbeats, and slash commands.
4. Writes a structured `ACTIVE_CONTEXT.md` to the agent's workspace `memory/` directory, containing recent requests, recent work output, and referenced file paths.
5. Appends a timestamped entry to the daily log (`memory/YYYY-MM-DD.md`).

### Why It Matters

This is the only layer that is **completely independent of LLM behavior**. It does not ask the agent to summarize itself. It does not rely on the gateway being responsive. It reads raw session data from disk and produces a structured checkpoint mechanically. If every other layer fails -- if compaction breaks, if the agent ignores its flush instructions, if the gateway is down -- the checkpoint script still runs and preserves context.

### Staleness Handling

Sessions not modified within the staleness window (default: 4 hours, matching the context pruning TTL) are skipped. Sessions smaller than 1KB are also skipped. This avoids writing checkpoints for idle or empty sessions.

### Deduplication

The daily log includes a deduplication check: if a checkpoint entry already exists for the current time window (matching the hour-minute prefix), the script skips the append. This prevents duplicate entries when the script runs more frequently than content changes.

## Layer 3 -- Compaction Fix

**Component:** Configuration change (no script)
**Setting:** `compaction.mode: "default"` in `clawdbot.json`

### What It Does

This is not a script but a configuration fix. Clawdbot's `safeguard` compaction mode has a bug where `ExtensionRunner.initialize()` is never called, causing every compaction to produce an empty summary. Switching to `default` mode bypasses the broken `ExtensionRunner` code path and uses the session's already-initialized model client for summarization.

See [Compaction Bug](compaction-bug.md) for the full root cause analysis.

### Why It Is a Separate Layer

Even with session rotation preventing *most* compaction events, compaction can still fire in edge cases -- a session that receives a burst of large messages between rotation checks, or a rotation monitor failure. When compaction does fire, it must produce a real summary. The config fix ensures that the safety net actually works.

## Layer 4 -- Progressive Memory Loading

**Components:**
- `hooks/memory-index-inject` (Clawdbot hook, fires on `agent:bootstrap`)
- `scripts/generate-memory-index.sh` (INDEX.md generator)
- `scripts/regenerate-all-indexes.sh` (batch regenerator, every 6 hours)
- `hooks/session-summary` (Clawdbot hook, fires on `command:new`)

### What It Does

Instead of loading an agent's entire memory pool at bootstrap (which can be 200K+ tokens for a mature agent), the `memory-index-inject` hook provides a compact `INDEX.md` (~1-2K tokens) that catalogs all available memory files with their sizes, categories, and observation marker counts.

The agent is instructed to load files on demand using `memory_search` and `memory_get` rather than reading everything upfront. `ACTIVE_CONTEXT.md` (the checkpoint from Layer 2) is always loaded alongside the index since it contains the agent's current working state.

### INDEX.md Structure

The `generate-memory-index.sh` script scans all `memory/*.md` files and produces a categorized index:

- **Core State** -- `ACTIVE_CONTEXT.md`, mission control config, overnight run state
- **Domain Files** -- Business-specific context organized by project
- **Plans and Procedures** -- Implementation plans, deployment checklists
- **Config and Credentials** -- Integration configurations
- **Research Reports** -- Deep research output from sub-agents
- **Session Logs** -- Daily session notes and decision records

Each file entry includes its size, estimated token count, modification date, and observation marker counts.

### Observation Markers

The `session-summary` hook fires on `/new` (session rotation) and writes structured summaries tagged with observation types:

- `[DECISION]` -- Architectural or strategic choices and their rationale
- `[GOTCHA]` -- Traps, footguns, unexpected behavior discovered
- `[SOLUTION]` -- Problems encountered and how they were solved
- `[PATTERN]` -- Reusable approaches or workflows identified
- `[TODO]` -- Outstanding action items
- `[FACT]` -- Verified reference data
- `[PREFERENCE]` -- User preferences
- `[TRADEOFF]` -- Evaluated options with pros and cons

These markers are searchable across the entire memory corpus and are counted in the INDEX.md, helping agents find high-value context without loading everything.

### Size Threshold

Progressive disclosure only activates for agents whose total memory pool exceeds 50KB. For agents with small memory pools, the full memory load is fine and the index would add unnecessary indirection.

## Supporting Infrastructure

### Health Monitoring

`scripts/health-check.sh` runs every 5 minutes and checks:

- Gateway reachability (HTTP health endpoint)
- Gateway process existence (pgrep)
- Disk space usage
- Session transcript total size (scans all `agents/*/sessions/` directories)
- Individual memory file sizes (flags files over 50KB)
- Recent cron job error rates

Alerts are sent via Slack with a configurable cooldown to prevent alert fatigue. Slack API payloads are constructed using `python3 json.dumps` for proper JSON escaping (with a sed-based fallback). The health check does not depend on the Clawdbot gateway for alerting (it calls the Slack API directly), avoiding a circular dependency.

### Log Rotation

`scripts/cleanup-sessions.sh` includes log rotation for all launchd output logs and health monitoring logs. Files exceeding a configurable threshold (default: 5MB) are rotated with numbered suffixes (`.1`, `.2`, `.3`), preventing unbounded log growth on long-running deployments.

## Data Flow

```
Agent Session (ongoing conversation)
    |
    |--- [Every 20 min] memory-checkpoint.js reads JSONL
    |         |
    |         +--> ACTIVE_CONTEXT.md (overwritten each run)
    |         +--> YYYY-MM-DD.md (appended each run)
    |
    |--- [Every 30 min] session-rotation-monitor.js checks tokens
    |         |
    |         +--> sessions.reset (if > 150K tokens)
    |                  |
    |                  +--> agent:bootstrap fires
    |                  |       |
    |                  |       +--> memory-index-inject hook
    |                  |               |
    |                  |               +--> INDEX.md injected
    |                  |               +--> ACTIVE_CONTEXT.md injected
    |                  |
    |                  +--> command:new fires (previous session)
    |                          |
    |                          +--> session-summary hook
    |                                  |
    |                                  +--> YYYY-MM-DD-<slug>.md written
    |
    |--- [If token limit reached] compaction fires
              |
              +--> default mode: real summary via session.model
              +--> (safeguard mode: broken -- empty summary)
```

## Design Principles

1. **No single point of failure.** Each layer operates independently. The checkpoint script does not need the gateway. The health check does not need Clawdbot. The hooks do not need the scripts.

2. **No LLM dependency for persistence.** The checkpoint system reads raw JSONL files. It does not ask the LLM to summarize itself. LLM-generated summaries (from the session-summary hook and compaction) are a bonus, not the foundation.

3. **Prevent, then mitigate.** Session rotation prevents compaction from firing. Memory checkpointing preserves context regardless. The compaction fix ensures the safety net works. Progressive loading reduces the token pressure that causes compaction in the first place.

4. **Observable.** The health check provides external monitoring. Each script logs structured output with timestamps. Alert cooldowns prevent noise without hiding problems.

## Related

- [Compaction Bug](compaction-bug.md) -- Root cause analysis of the `safeguard` mode bug
- [Recommended Configuration](config-recommendations.md) -- Full tuning guide
