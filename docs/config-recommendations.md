# Recommended Clawdbot Configuration

This document covers Clawdbot configuration settings that directly affect memory persistence. Each recommendation is based on observed failure modes in production multi-agent deployments.

## Configuration Reference

### compaction.mode

| | |
|---|---|
| **Recommended** | `"default"` |
| **Default** | `"safeguard"` |
| **Location** | `~/.clawdbot/clawdbot.json` |

```json
{
  "compaction": {
    "mode": "default"
  }
}
```

**What it does:** Controls how Clawdbot summarizes discarded context when the token limit is reached. In `safeguard` mode, compaction creates an `ExtensionRunner` to sandbox the LLM summarization call. In `default` mode, compaction uses the session's already-initialized model client (`session.model`) directly.

**Why `"default"`:** The `safeguard` mode has a bug where `ExtensionRunner.initialize()` is never called, leaving `ctx.model` undefined. Every compaction in `safeguard` mode produces an empty summary ("Summary unavailable"), causing total context loss. The `default` mode bypasses this broken code path entirely.

**Risk of the default:** None observed. The `default` mode performs the same summarization operation using a model client that is already authenticated and configured. It simply skips the `ExtensionRunner` wrapper that `safeguard` mode uses (and fails to initialize).

See [Compaction Bug](compaction-bug.md) for the full root cause analysis.

---

### contextPruning.ttl

| | |
|---|---|
| **Recommended** | `"4h"` |
| **Default** | `"1h"` |
| **Location** | `~/.clawdbot/clawdbot.json` |

```json
{
  "contextPruning": {
    "ttl": "4h"
  }
}
```

**What it does:** Controls how long inactive context entries (tool results, old messages, injected files) are kept in the context window before being silently pruned. After the TTL expires, the entry is eligible for removal when the system needs to reclaim space.

**Why `"4h"`:** The default of 1 hour is too aggressive for agents working on multi-step tasks. A common pattern is: the agent reads a file, works on something else for 90 minutes, then needs to reference the file contents. With a 1-hour TTL, that file content has already been pruned. The agent has to re-read the file, wasting a tool call and context space, or worse, it hallucinates the file contents from a vague recollection.

Four hours provides enough runway for multi-step tasks, overnight work loops (which typically cycle every 30 minutes), and debugging sessions that require jumping between files. It also aligns with the staleness threshold used by the memory checkpoint script, creating a consistent window across the system.

**Tradeoff:** A longer TTL means the context window fills up faster with retained entries. This increases the likelihood of hitting the compaction threshold. However, this is mitigated by the session rotation monitor (Layer 1), which rotates sessions at 150K tokens -- well before the compaction threshold.

---

### softThresholdTokens

| | |
|---|---|
| **Recommended** | `25000` |
| **Default** | `10000` |
| **Location** | `~/.clawdbot/clawdbot.json` |

```json
{
  "softThresholdTokens": 25000
}
```

**What it does:** Defines a "soft" token threshold that triggers pre-compaction behaviors before the hard compaction limit is reached. When the session's token count passes this threshold below the maximum, Clawdbot begins taking preparatory actions -- flushing memory, running pre-compaction hooks, and notifying the agent that compaction is imminent.

In concrete terms, if the context window maximum is 200K tokens and `softThresholdTokens` is 25K, then pre-compaction actions begin at 175K tokens.

**Why `25000`:** The default of 10,000 tokens provides a very narrow window between "compaction is imminent" and "compaction fires." In that 10K-token window, the agent needs to:

1. Receive the pre-compaction signal
2. Generate a memory flush (which itself consumes tokens for the LLM response)
3. Execute any write operations
4. Complete the flush before compaction cuts off context

At typical response lengths (500-2000 tokens per assistant turn), 10K tokens is only 5-10 exchanges. If the agent is in the middle of a complex operation, it may not complete the flush in time.

Raising the threshold to 25K tokens provides approximately 12-25 exchanges of runway. This is enough time for the agent to finish its current task, flush working state to memory, and prepare for compaction -- even if it takes a few turns to wind down.

**Tradeoff:** A higher `softThresholdTokens` means pre-compaction behaviors kick in earlier, which slightly reduces the usable context window. The effective reduction is 15K tokens (25K minus the 10K default), or about 7.5% of a 200K context window. In practice, this is a worthwhile trade because the alternative -- losing all context because the flush did not complete -- is far more expensive.

---

## Complete Recommended Configuration Block

For convenience, here is the complete set of memory-related settings to add to `~/.clawdbot/clawdbot.json`:

```json
{
  "compaction": {
    "mode": "default"
  },
  "contextPruning": {
    "ttl": "4h"
  },
  "softThresholdTokens": 25000
}
```

Merge these into your existing configuration. Do not replace the entire file -- these settings coexist with your agent definitions, hook configurations, and other Clawdbot settings.

After applying changes, restart the gateway:

```bash
launchctl stop com.clawdbot.gateway && launchctl start com.clawdbot.gateway
```

## Environment Variables for Deployed Scripts

The scripts in this project use environment variables for configuration. These are separate from the `clawdbot.json` settings above.

| Variable | Default | Notes |
|----------|---------|-------|
| `ROTATION_THRESHOLD` | `150000` | Should be 70-80% of the context window maximum. If your model supports 128K, use `100000`. If 200K, use `150000`. |
| `SESSION_STALE_HOURS` | `4` | Should match `contextPruning.ttl` for consistency. |
| `MEMORY_SIZE_THRESHOLD` | `50` | In KB. Agents with less memory than this get full memory loading instead of progressive disclosure. Adjust based on your agents' memory sizes. |
| `CLAWDBOT_ALERT_COOLDOWN` | `30` | In minutes. Lower values mean more alerts; higher values mean slower notification of new issues. 30 minutes is a reasonable balance. |

## Related

- [Architecture: Defense in Depth](architecture.md) -- How these settings fit into the overall memory persistence strategy
- [Compaction Bug](compaction-bug.md) -- Detailed analysis of why `safeguard` mode is broken
