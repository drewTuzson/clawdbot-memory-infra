---
name: memory-index-inject
description: "Progressive disclosure: injects memory INDEX.md at bootstrap instead of full memory dump"
metadata: {"clawdbot":{"emoji":"🧠","events":["agent:bootstrap"]}}
---

# Memory Index Inject Hook

Implements progressive memory disclosure for agents with large memory pools.

## What It Does

On `agent:bootstrap`, this hook:
1. Checks if `memory/INDEX.md` exists in the agent's workspace
2. If the agent's total memory pool exceeds a threshold (~50KB), injects INDEX.md as a bootstrap file
3. Adds an instruction telling the agent to use `memory_search` + `memory_get` for on-demand loading
4. For small-memory agents, does nothing (full load is fine)

## Why

Agents like Max (~847KB / ~214K tokens) and Reggie (~150KB) waste massive attention budget loading irrelevant memory files at startup. Progressive disclosure gives them a compact index (~1-2K tokens) and lets them pull specific files on demand.

## Configuration

No configuration needed. Automatically discovers INDEX.md in the agent workspace.

## Requirements

- `generate-memory-index.sh` must have run at least once to create INDEX.md
- Works with any agent that has a `memory/` directory in its workspace
