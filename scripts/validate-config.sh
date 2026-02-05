#!/bin/bash
# Clawdbot Config Validator — Pre-flight checks before config.patch
# Prevents the type errors that have crashed the gateway 3 times
# Usage: validate-config.sh [path-to-config.json]

CONFIG="${1:-${CLAWDBOT_HOME:-$HOME/.clawdbot}/clawdbot.json}"
ERRORS=0
WARNINGS=0

echo "🔍 Validating Clawdbot config: $CONFIG"
echo "---"

if [ ! -f "$CONFIG" ]; then
  echo "❌ FATAL: Config file not found: $CONFIG"
  exit 1
fi

# Validate JSON syntax
if ! python3 -c "import json; json.load(open('$CONFIG'))" 2>/dev/null; then
  echo "❌ FATAL: Invalid JSON syntax"
  exit 1
fi
echo "✅ JSON syntax valid"

# === CRITICAL CHECK: allowFrom.slack must be array, never boolean ===
# This is THE bug that crashed us 3 times
BOOL_SLACK=$(python3 -c "
import json
config = json.load(open('$CONFIG'))
agents = config.get('agents', {}).get('list', [])
issues = []
for agent in agents:
    tools = agent.get('tools', {})
    elevated = tools.get('elevated', {})
    allow_from = elevated.get('allowFrom', {})
    slack_val = allow_from.get('slack')
    if slack_val is not None and not isinstance(slack_val, list):
        issues.append(f\"Agent '{agent['id']}': allowFrom.slack is {type(slack_val).__name__} ({slack_val}), MUST be array\")
for issue in issues:
    print(issue)
" 2>/dev/null)

if [ -n "$BOOL_SLACK" ]; then
  echo "❌ CRITICAL: $BOOL_SLACK"
  ERRORS=$((ERRORS + 1))
else
  echo "✅ allowFrom.slack types correct (all arrays)"
fi

# === Check bindings order: main catch-all must be LAST ===
BINDING_ORDER=$(python3 -c "
import json
config = json.load(open('$CONFIG'))
bindings = config.get('bindings', [])
main_catchall_idx = -1
last_specific_idx = -1
for i, b in enumerate(bindings):
    match = b.get('match', {})
    if b.get('agentId') == 'main' and 'peer' not in match and 'accountId' not in match:
        main_catchall_idx = i
    elif 'peer' in match or 'accountId' in match:
        last_specific_idx = i
if main_catchall_idx >= 0 and last_specific_idx >= 0 and main_catchall_idx < last_specific_idx:
    print(f'Main catch-all at index {main_catchall_idx} but specific binding at {last_specific_idx} — catch-all must be LAST')
elif main_catchall_idx == -1:
    print('WARNING: No main catch-all binding found')
" 2>/dev/null)

if echo "$BINDING_ORDER" | grep -q "must be LAST"; then
  echo "❌ CRITICAL: $BINDING_ORDER"
  ERRORS=$((ERRORS + 1))
elif echo "$BINDING_ORDER" | grep -q "WARNING"; then
  echo "⚠️  $BINDING_ORDER"
  WARNINGS=$((WARNINGS + 1))
else
  echo "✅ Binding order correct (main catch-all is last)"
fi

# === Check all binding agentIds exist in agents.list ===
ORPHAN_BINDINGS=$(python3 -c "
import json
config = json.load(open('$CONFIG'))
agent_ids = {a['id'] for a in config.get('agents', {}).get('list', [])}
bindings = config.get('bindings', [])
for i, b in enumerate(bindings):
    aid = b.get('agentId', '')
    if aid not in agent_ids:
        print(f'Binding {i}: agentId \"{aid}\" not found in agents.list')
" 2>/dev/null)

if [ -n "$ORPHAN_BINDINGS" ]; then
  echo "❌ CRITICAL: Orphaned bindings found:"
  echo "   $ORPHAN_BINDINGS"
  ERRORS=$((ERRORS + 1))
else
  echo "✅ All binding agentIds exist in agents.list"
fi

# === Check all binding accountIds exist in slack accounts ===
ORPHAN_ACCOUNTS=$(python3 -c "
import json
config = json.load(open('$CONFIG'))
accounts = set(config.get('channels', {}).get('slack', {}).get('accounts', {}).keys())
bindings = config.get('bindings', [])
for i, b in enumerate(bindings):
    match = b.get('match', {})
    acc = match.get('accountId')
    if acc and acc not in accounts:
        print(f'Binding {i}: accountId \"{acc}\" not found in slack.accounts')
" 2>/dev/null)

if [ -n "$ORPHAN_ACCOUNTS" ]; then
  echo "❌ CRITICAL: $ORPHAN_ACCOUNTS"
  ERRORS=$((ERRORS + 1))
else
  echo "✅ All binding accountIds exist in slack.accounts"
fi

# === Check all bound channel IDs are in the channels allowlist ===
MISSING_CHANNELS=$(python3 -c "
import json
config = json.load(open('$CONFIG'))
allowed = set(config.get('channels', {}).get('slack', {}).get('channels', {}).keys())
bindings = config.get('bindings', [])
for i, b in enumerate(bindings):
    match = b.get('match', {})
    peer = match.get('peer', {})
    if peer.get('kind') == 'channel':
        cid = peer.get('id', '')
        if cid and cid not in allowed:
            print(f'Binding {i}: channel {cid} not in channels allowlist')
" 2>/dev/null)

if [ -n "$MISSING_CHANNELS" ]; then
  echo "❌ CRITICAL: $MISSING_CHANNELS"
  ERRORS=$((ERRORS + 1))
else
  echo "✅ All bound channels in allowlist"
fi

# === Check for duplicate bindings ===
DUPES=$(python3 -c "
import json
config = json.load(open('$CONFIG'))
bindings = config.get('bindings', [])
seen = set()
for i, b in enumerate(bindings):
    key = json.dumps(b.get('match', {}), sort_keys=True)
    if key in seen:
        print(f'Binding {i}: duplicate match pattern')
    seen.add(key)
" 2>/dev/null)

if [ -n "$DUPES" ]; then
  echo "⚠️  Duplicate bindings: $DUPES"
  WARNINGS=$((WARNINGS + 1))
else
  echo "✅ No duplicate bindings"
fi

# === Check agent IDs are lowercase ===
CASE_ISSUES=$(python3 -c "
import json
config = json.load(open('$CONFIG'))
for a in config.get('agents', {}).get('list', []):
    aid = a.get('id', '')
    if aid != aid.lower():
        print(f'Agent ID \"{aid}\" contains uppercase — should be \"{aid.lower()}\"')
" 2>/dev/null)

if [ -n "$CASE_ISSUES" ]; then
  echo "⚠️  $CASE_ISSUES"
  WARNINGS=$((WARNINGS + 1))
else
  echo "✅ All agent IDs lowercase"
fi

# === Check subagents.allowAgents references ===
MISSING_SUBAGENTS=$(python3 -c "
import json
config = json.load(open('$CONFIG'))
agent_ids = {a['id'] for a in config.get('agents', {}).get('list', [])}
for a in config.get('agents', {}).get('list', []):
    allowed = a.get('subagents', {}).get('allowAgents', [])
    for sub in allowed:
        if sub not in agent_ids:
            print(f'Agent \"{a[\"id\"]}\": allowAgents references \"{sub}\" which is not in agents.list')
" 2>/dev/null)

if [ -n "$MISSING_SUBAGENTS" ]; then
  echo "⚠️  $MISSING_SUBAGENTS"
  WARNINGS=$((WARNINGS + 1))
else
  echo "✅ All subagent references valid"
fi

# === Summary ===
echo "---"
if [ $ERRORS -gt 0 ]; then
  echo "❌ FAILED: $ERRORS critical error(s), $WARNINGS warning(s)"
  echo "   DO NOT apply this config."
  exit 1
elif [ $WARNINGS -gt 0 ]; then
  echo "⚠️  PASSED with $WARNINGS warning(s)"
  exit 0
else
  echo "✅ ALL CHECKS PASSED"
  exit 0
fi
