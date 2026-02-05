# Compaction Bug: `safeguard` Mode Produces Empty Summaries

## Summary

Clawdbot's `safeguard` compaction mode contains an initialization bug that causes every compaction to produce an empty summary ("Summary unavailable") instead of preserving context. This silently lobotomizes agents, making them forget all prior context whenever the context window fills up.

## Symptom

After compaction fires, agents lose all awareness of previous conversation history. They repeat questions already answered, re-derive decisions already made, and forget which files they were working on. The agent behaves as if it started a brand-new session with no history.

Compaction events in the session JSONL files show two telltale signs:

1. **Completion time of ~20ms.** A real LLM summarization call takes 5-30 seconds depending on the volume of context being summarized. Completion in under 100ms means no API call was made.

2. **Empty or placeholder summary strings.** The compaction result contains "Summary unavailable" or an empty string where the context summary should be.

```
# Example: compaction entry in session JSONL
{"type":"compaction","timestamp":"...","summary":"Summary unavailable","tokensReclaimed":85000,"durationMs":18}
```

## Root Cause

In `safeguard` mode, Clawdbot's `compact.js` creates an `ExtensionRunner` instance to invoke the LLM for context summarization. The `ExtensionRunner` is designed to provide a sandboxed execution environment with access to a model client via `ctx.model`.

The bug: **`ExtensionRunner.initialize()` is never called** before the summarization request. This method is responsible for setting up `ctx.model` with the configured LLM client. Without initialization, `ctx.model` is `undefined`. When the summarization code tries to call the model, the call silently fails (no exception is thrown), and the fallback path produces a placeholder summary.

The call chain looks like this:

```
compact.js (safeguard mode)
  -> new ExtensionRunner(config)     // ExtensionRunner created
  // runner.initialize() is NEVER called
  -> runner.summarize(messages)      // ctx.model is undefined
    -> attempts LLM call             // silently fails
    -> returns fallback              // "Summary unavailable"
```

In `default` mode, compaction uses `session.model` directly -- the model client that is already initialized and authenticated as part of the active session. This bypasses the `ExtensionRunner` entirely, avoiding the initialization bug.

## Impact

**Every Clawdbot deployment using `safeguard` compaction mode is affected.** This is not an edge case or race condition -- it is a deterministic bug that fires on every compaction event.

The impact is especially severe in long-running sessions and multi-agent deployments:

- Agents that run overnight accumulate conversation history and eventually trigger compaction. After compaction, they lose their overnight run state, the task queue, and awareness of what they already completed.
- Agents working on multi-step tasks (code reviews, implementation plans, debugging sessions) lose the thread entirely after compaction. They may re-implement code they already wrote or re-investigate bugs they already diagnosed.
- In multi-agent setups, an orchestrator agent that loses context may re-dispatch work to sub-agents that already completed it, wasting tokens and potentially creating conflicts.

## Fix

Switch `compaction.mode` from `"safeguard"` to `"default"` in your Clawdbot configuration.

In `~/.clawdbot/clawdbot.json`:

```json
{
  "compaction": {
    "mode": "default"
  }
}
```

In `default` mode, compaction uses the session's already-initialized model client (`session.model`) to perform summarization. This produces real, substantive summaries that preserve the important context from the discarded portion of the conversation.

After changing the configuration, restart the gateway:

```bash
launchctl stop com.clawdbot.gateway && launchctl start com.clawdbot.gateway
```

## Verification

To verify the fix is working, wait for a compaction event to fire naturally (or trigger one by running a session close to the token limit). Check the session JSONL file for the compaction entry:

- **Duration should be 5-30 seconds** (indicating a real LLM call occurred).
- **Summary should contain substantive text** -- a real summary of the conversation, not "Summary unavailable" or an empty string.

```bash
# Find recent compaction events in session files
grep '"type":"compaction"' ~/.clawdbot/agents/*/sessions/*.jsonl | tail -5
```

## Why Not Just Fix ExtensionRunner?

The `ExtensionRunner.initialize()` omission is a bug in Clawdbot core. This project does not patch Clawdbot itself -- it works around the bug via configuration. The `default` mode is functionally equivalent for summarization purposes and avoids the broken code path entirely.

If the upstream bug is fixed in a future Clawdbot release, switching back to `safeguard` mode would be safe. Until then, `default` is the correct choice.

## Related

- [Architecture: Defense in Depth](architecture.md) -- How the compaction fix fits into the broader memory persistence strategy
- [Recommended Configuration](config-recommendations.md) -- Full configuration tuning guide
