#!/usr/bin/env node
/**
 * session-rotation-monitor.js — Proactive session rotation for Clawdbot agents
 *
 * Monitors active session token counts and triggers rotation (sessions.reset)
 * when a session exceeds a configurable threshold. This prevents compaction
 * from being the primary recovery path — sessions rotate cleanly and agents
 * read ACTIVE_CONTEXT.md on fresh start.
 *
 * Uses Clawdbot's callGateway() to communicate with the gateway WebSocket API.
 *
 * Usage: node session-rotation-monitor.js [--dry-run] [--verbose] [--threshold N]
 */

import path from "node:path";
import os from "node:os";

// Resolve callGateway from Clawdbot distribution
const CLAWDBOT_DIST = process.env.CLAWDBOT_DIST || "";
let callGateway;
try {
  if (CLAWDBOT_DIST) {
    ({ callGateway } = await import(path.join(CLAWDBOT_DIST, "gateway", "call.js")));
  } else {
    // Try common install locations
    const candidates = [
      path.join(os.homedir(), ".npm-global/lib/node_modules/clawdbot/dist/gateway/call.js"),
      "/usr/local/lib/node_modules/clawdbot/dist/gateway/call.js",
      "/usr/lib/node_modules/clawdbot/dist/gateway/call.js",
    ];
    for (const candidate of candidates) {
      try {
        ({ callGateway } = await import(candidate));
        break;
      } catch { continue; }
    }
  }
  if (!callGateway) throw new Error("Could not locate callGateway");
} catch (err) {
  console.error("[session-rotation] Cannot import callGateway:", err.message);
  console.error("Set CLAWDBOT_DIST to the clawdbot dist/ directory path");
  process.exit(1);
}

// Default rotation threshold: 150K tokens (~75% of typical 200K context window)
// Leaves room for the post-rotation bootstrap + memory loading
const DEFAULT_THRESHOLD = parseInt(process.env.ROTATION_THRESHOLD, 10) || 150000;

// Sessions matching these patterns should never be auto-rotated
// (cron sessions are ephemeral and will be cleaned up naturally)
const SKIP_PATTERNS = [
  /^agent:.*:cron:/,     // Cron job sessions (ephemeral)
  /^agent:.*:subagent:/, // Sub-agent sessions (managed by parent)
];

// Parse args
const DRY_RUN = process.argv.includes("--dry-run");
const VERBOSE = process.argv.includes("--verbose");
const thresholdIdx = process.argv.indexOf("--threshold");
const THRESHOLD = thresholdIdx >= 0 && process.argv[thresholdIdx + 1]
  ? parseInt(process.argv[thresholdIdx + 1], 10)
  : DEFAULT_THRESHOLD;

function log(...args) {
  console.log(`[session-rotation] ${new Date().toISOString()}`, ...args);
}

function verbose(...args) {
  if (VERBOSE) log(...args);
}

async function main() {
  log(`Starting rotation check (threshold: ${THRESHOLD} tokens)${DRY_RUN ? " [DRY RUN]" : ""}`);

  // 1. List all sessions
  let sessions;
  try {
    const result = await callGateway({
      method: "sessions.list",
      params: {},
      timeoutMs: 10000,
    });
    sessions = result?.sessions || [];
  } catch (err) {
    log("Failed to list sessions:", err.message);
    process.exit(1);
  }

  verbose(`Found ${sessions.length} total sessions`);

  // 2. Find sessions exceeding threshold
  const candidates = sessions.filter((s) => {
    if (!s.totalTokens || s.totalTokens < THRESHOLD) return false;
    if (!s.key) return false;
    // Skip patterns
    for (const pattern of SKIP_PATTERNS) {
      if (pattern.test(s.key)) return false;
    }
    return true;
  });

  if (candidates.length === 0) {
    log("No sessions exceed threshold. Done.");
    process.exit(0);
  }

  log(`Found ${candidates.length} session(s) exceeding ${THRESHOLD} tokens:`);
  for (const s of candidates) {
    log(`  ${s.key} — ${s.totalTokens} tokens (session: ${s.sessionId?.slice(0, 8)})`);
  }

  // 3. Rotate each candidate
  let rotated = 0;
  for (const s of candidates) {
    if (DRY_RUN) {
      log(`  [DRY RUN] Would rotate: ${s.key} (${s.totalTokens} tokens)`);
      rotated++;
      continue;
    }

    try {
      const result = await callGateway({
        method: "sessions.reset",
        params: { key: s.key },
        timeoutMs: 10000,
      });

      if (result?.ok || result?.entry) {
        const newId = result.entry?.sessionId?.slice(0, 8) || "unknown";
        log(`  Rotated: ${s.key} — ${s.totalTokens} tokens → new session ${newId}`);
        rotated++;
      } else {
        log(`  Failed to rotate ${s.key}: unexpected response`, JSON.stringify(result).slice(0, 200));
      }
    } catch (err) {
      log(`  Error rotating ${s.key}:`, err.message);
    }
  }

  log(`Done. Rotated ${rotated}/${candidates.length} sessions.`);
}

main().catch((err) => {
  log("Fatal error:", err.message);
  process.exit(1);
});
