# The Lobotomy Problem: How We Fixed Memory Persistence in a 6-Agent AI Deployment

We run six AI agents on Slack through [Clawdbot](https://clawdbot.com), an open-source multi-agent gateway. Each agent has a specialized role -- an orchestrator, a financial domain lead, a library project manager, and so on. They maintain persistent memory across sessions: decisions they've made, code they've written, context about ongoing projects. The whole system depends on that memory being reliable.

For weeks, it wasn't.

## The Problem

We called it "the lobotomy." An agent would be deep into a multi-hour task -- debugging a build pipeline, drafting a project plan, coordinating with another agent -- and then suddenly forget everything. Not gradually. Completely. Mid-conversation context gone, decisions from an hour ago evaporated, files it had just edited treated as if they'd never existed.

The real-world cost was not theoretical. One agent submitted a build to Apple App Store review using an outdated configuration because it had lost the context where we'd changed the signing profile. Another agent repeated three hours of API integration research it had already completed and documented. Trust in the system eroded -- we started manually babysitting agents, which defeated the purpose of having them.

The pattern was unpredictable. Sometimes an agent would hold context for eight hours without trouble. Other times, it would lose everything twenty minutes into a session. The inconsistency made it harder to diagnose -- we couldn't reliably reproduce the failure. Restarting a session would appear to fix things (the agent would reload its memory files), but the underlying problem would surface again hours later.

We eventually traced it to four independent failures that were compounding into a single catastrophic symptom.

## Root Cause Analysis

### Failure 1: Compaction Producing Empty Summaries

Clawdbot uses context compaction to manage long sessions. When a session's token count exceeds a threshold (roughly 200K tokens), the system summarizes older messages and replaces them with the summary. This keeps the context window from overflowing while preserving important information.

The system has a `safeguard` compaction mode that creates an `ExtensionRunner` to call the LLM for summarization. The problem: `ExtensionRunner.initialize()` was never called before the summarization request. This meant `ctx.model` was always `undefined` when the compaction code tried to generate the summary. The LLM call silently failed, producing a placeholder string: "Summary unavailable."

The smoking gun was timing. A real API call to summarize 100K+ tokens of conversation takes 5-30 seconds. Our compaction events were completing in 15-20 milliseconds. That's not summarization -- that's a no-op with extra steps.

```
// What we expected to see in compaction logs:
// compaction completed in 12,400ms — summary: 6.2KB

// What we actually saw:
// compaction completed in 18ms — summary: "Summary unavailable"
```

The result: every time compaction fired, it replaced the agent's older context with an empty summary. The agent retained its most recent messages but lost everything before the compaction boundary.

### Failure 2: Memory Flush is Instruction-Dependent

Clawdbot has a `memoryFlush` prompt that instructs agents to write important context to their memory files before a session ends or compacts. The idea is sound: if the agent persists critical state to disk before compaction, the summary quality matters less.

But this is a prompt instruction, and LLM compliance with instructions is probabilistic, not guaranteed. Under cognitive load -- when an agent is managing a complex multi-step task, juggling tool calls, or handling a long conversation -- it is more likely to skip the flush. The exact situations where memory persistence matters most are the situations where the flush is least reliable.

We verified this by auditing memory file timestamps against session activity. Agents in long, complex sessions often went hours without writing to their memory files, even though the system prompt explicitly told them to persist state regularly.

### Failure 3: Hooks Silently Failing

We had built two custom hooks to address parts of this problem: a `session-summary` hook that generated structured summaries on session rotation, and a `memory-index-inject` hook that loaded a compact memory index at agent bootstrap.

Both hooks were written in TypeScript. Clawdbot's hook loader uses native `import()` to load handler files. On Node.js without a TypeScript compiler in the import chain, `.ts` files fail with `ERR_UNKNOWN_FILE_EXTENSION`. The hook loader's candidate resolution order is `handler.ts, handler.js, index.ts, index.js` -- it picks the first file that exists, not the first file that successfully imports.

Our `.ts` files existed, so the loader selected them. They failed to import. No error was surfaced to the user or logged in an obvious place. The hooks simply never fired.

```
// Hook loader candidate order:
// 1. handler.ts  <-- exists, selected, fails silently at runtime
// 2. handler.js  <-- never reached
// 3. index.ts
// 4. index.js
```

We only discovered this by adding explicit logging to the gateway startup sequence and watching for hook registration messages that never appeared.

### Failure 4: Context Pruning Too Aggressive

Clawdbot prunes old messages from sessions based on a configurable TTL. The default was 1 hour -- any message older than 60 minutes was eligible for pruning. Combined with the empty compaction summaries from Failure 1, this created a devastating interaction:

1. Messages older than 1 hour get pruned from the live session
2. Compaction fires to summarize what was pruned
3. The summary comes back empty
4. The agent now has neither the original messages nor a usable summary

With a longer TTL, the agent would at least retain the raw messages until compaction could (theoretically) summarize them. With a 1-hour TTL, the window was too short -- messages were gone before the agent could reference them, and the safety net of compaction was broken.

## The Fix: Defense in Depth

We didn't trust any single fix to solve this reliably. Instead, we built four independent layers, any one of which is sufficient to prevent total memory loss. If one layer fails, the others catch it.

```
                    +---------------------------+
                    |     Agent Session          |
                    |  (active conversation)     |
                    +------+------+------+------+
                           |      |      |
          +----------------+      |      +----------------+
          |                       |                       |
  +-------v--------+   +---------v--------+   +----------v---------+
  | Layer 1:        |   | Layer 2:          |   | Layer 3:            |
  | Session         |   | Memory            |   | Fixed               |
  | Rotation        |   | Checkpointing     |   | Compaction          |
  | (150K tokens)   |   | (every 20 min)    |   | (default mode)      |
  +-------+--------+   +---------+--------+   +----------+---------+
          |                       |                       |
          +-----------+-----------+-----------+-----------+
                      |
              +-------v--------+
              | Layer 4:        |
              | Progressive     |
              | Memory Loading  |
              | (INDEX.md)      |
              +----------------+
```

**Layer 1: Proactive Session Rotation.** A script runs every 30 minutes via `launchd`, querying active sessions through Clawdbot's gateway API. Any session exceeding 150K tokens gets rotated -- a clean reset that starts a new session. This fires well before the 200K compaction threshold, so compaction never needs to be the primary recovery path.

```javascript
const candidates = sessions.filter((s) => {
  if (!s.totalTokens || s.totalTokens < THRESHOLD) return false;
  if (!s.key) return false;
  // Skip ephemeral sessions (cron jobs, sub-agents)
  for (const pattern of SKIP_PATTERNS) {
    if (pattern.test(s.key)) return false;
  }
  return true;
});
```

The script calls `sessions.reset` through the gateway WebSocket API to trigger the rotation. It skips cron and sub-agent sessions, which are ephemeral by design.

**Layer 2: Programmatic Memory Checkpointing.** Every 20 minutes, a separate script reads each agent's active session JSONL file directly from disk, extracts the last 60 messages, and writes a structured `ACTIVE_CONTEXT.md` checkpoint plus an entry in a daily log. This is purely programmatic -- it parses JSON, extracts text content, and writes Markdown. No LLM call, no instruction compliance, no prompt.

```javascript
// Extract text content, skip thinking blocks and tool calls
let text = "";
if (typeof msg.content === "string") {
  text = msg.content;
} else if (Array.isArray(msg.content)) {
  const textParts = msg.content
    .filter((c) => c.type === "text" && c.text)
    .map((c) => c.text);
  text = textParts.join("\n");
}
```

When an agent starts a new session, it reads `ACTIVE_CONTEXT.md` and immediately has context about what it was doing 20 minutes ago. This layer alone would have prevented most of the lobotomy events we experienced.

**Layer 3: Fixed Compaction.** We switched from `safeguard` mode to `default` mode, which uses the session's own model for summarization instead of creating a separate `ExtensionRunner`. We also extended the context pruning TTL from 1 hour to 4 hours and raised the soft threshold from 10K to 25K tokens. Compaction summaries now take 5-15 seconds and produce 5-7KB of structured context instead of empty strings.

**Layer 4: Progressive Memory Loading.** Instead of dumping an agent's entire memory directory into its context at bootstrap (847KB / ~214K tokens for our most active agent), a hook injects a compact `INDEX.md` (~1-2K tokens) with a categorized file listing. The agent uses on-demand search and retrieval to pull only the memory files relevant to its current task. This was one of the hooks that had been silently failing due to the TypeScript import issue -- once compiled to JavaScript and redeployed, it worked immediately.

The index is regenerated every 6 hours by a shell script that categorizes memory files, counts observation markers, and computes token estimates:

```
# Memory Index
> Files: 47 | Size: 847KB | ~Tokens: 214,000
> Observations: 23 decisions | 11 gotchas | 18 solutions | 9 patterns

### Core State (always load ACTIVE_CONTEXT)
| File | Title | Size | Tokens | Observations | Modified |
|------|-------|------|--------|-------------|----------|
| ACTIVE_CONTEXT.md | Active Context - main | 4KB | ~1024 | -- | 2026-02-04 |
```

Each layer is independent. The session rotation monitor doesn't know about the checkpointing script. The checkpointing script doesn't depend on compaction working. The progressive memory hook doesn't care how the session started. If any single layer is running, agents retain enough context to function.

## Results

Since deploying this system, we have had zero lobotomy events across all six agents. The specific improvements:

**Session rotation** catches agents at 150-170K tokens, cleanly rotating them before they hit the compaction wall. We see 2-4 rotations per day across the fleet, each one a controlled transition rather than an emergency recovery.

**Memory checkpoints** persist agent state every 20 minutes regardless of what the LLM is doing. The `ACTIVE_CONTEXT.md` files average 3-5KB each -- enough to reconstruct what the agent was working on, what files it was touching, and what the user last asked for.

**Compaction summaries** are now verified: 5-7KB of structured context, taking 5-15 seconds to generate. The timing alone confirms the LLM is actually being called.

**Progressive memory loading** reduced bootstrap context from ~214K tokens to ~2K tokens for our heaviest agent. Agents load relevant memory on demand, which means they start faster and waste less of their context window on irrelevant history.

The agents now maintain multi-day context across session boundaries. An agent can pick up a task it was working on yesterday, reference a decision made three days ago, and avoid repeating research from last week. The total implementation is approximately 1,500 lines of code with zero external dependencies beyond Node.js and Clawdbot itself.

## The Code

The full implementation is open source:

[GitHub: clawdbot-memory-infra](https://github.com/drewTuzson/clawdbot-memory-infra)

The repository includes:

- **`scripts/session-rotation-monitor.js`** -- Proactive session rotation via gateway API
- **`scripts/memory-checkpoint.js`** -- Programmatic memory checkpointing from JSONL sessions
- **`scripts/generate-memory-index.sh`** -- Memory index generation with observation tracking
- **`scripts/regenerate-all-indexes.sh`** -- Scheduled multi-workspace index regeneration
- **`hooks/memory-index-inject/`** -- Progressive memory loading hook for agent bootstrap
- **`hooks/session-summary/`** -- Structured session summary generation on rotation
- **`launchd/`** -- macOS `launchd` plist templates for scheduled execution

To install, clone the repo, copy the hooks to `~/.clawdbot/hooks/`, copy the scripts to `~/.clawdbot/scripts/`, and load the launchd plists. Each component works independently -- you can adopt the pieces that match your setup.

Licensed under MIT.
