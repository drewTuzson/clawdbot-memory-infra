---
name: session-summary
description: "Generates structured session summaries with observation markers on /new"
metadata: {"clawdbot":{"emoji":"📝","events":["command:new"]}}
---

# Session Summary Hook

Enhanced session memory that generates structured summaries with typed observation markers.

## What It Does

On `/new` command, this hook:
1. Reads the current session transcript
2. Uses LLM to generate a structured summary with observation types
3. Saves to `memory/YYYY-MM-DD-<slug>.md` with categorized sections

## Summary Structure

```markdown
# Session: 2026-02-03 — <descriptive title>

## Request
What was asked for or triggered

## Completed
- [x] Task 1
- [x] Task 2

## Observations
🟤 [DECISION] Any decisions made and why
🔴 [GOTCHA] Any traps or unexpected behaviors discovered
🟡 [SOLUTION] Problems encountered and how they were solved
🔵 [PATTERN] Reusable approaches identified

## Files Touched
- `path/to/file` (created/modified/deleted)

## Next Steps
⚪ [TODO] Outstanding items
```

## Configuration

No configuration needed. Uses the existing LLM slug generator pattern from session-memory.

## Notes

- This hook supplements (does not replace) the built-in session-memory hook
- If session-memory is also enabled, both will fire — session-summary produces the structured version
- The structured format makes observations searchable across the entire memory corpus
