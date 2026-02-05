#!/usr/bin/env node
/**
 * memory-checkpoint.js — Programmatic memory checkpointing for Clawdbot agents
 *
 * Runs periodically (via launchd) to extract structured context from active
 * sessions and persist it to agent memory files. Does NOT rely on LLM
 * instruction compliance — purely programmatic extraction.
 *
 * What it does:
 *   1. For each agent, finds the most recently modified session file
 *   2. Reads the last N messages from that session
 *   3. Extracts text content (skipping thinking blocks, tool calls, etc.)
 *   4. Writes a structured ACTIVE_CONTEXT.md checkpoint
 *   5. Appends a timestamped entry to memory/YYYY-MM-DD.md
 *
 * Usage: node memory-checkpoint.js [--dry-run] [--verbose]
 */

import fs from "node:fs/promises";
import path from "node:path";
import os from "node:os";

const CLAWDBOT_HOME = process.env.CLAWDBOT_HOME || path.join(os.homedir(), ".clawdbot");
const CONFIG_PATH = path.join(CLAWDBOT_HOME, "clawdbot.json");

// How many JSONL lines to read from the end of the session file
const MAX_LINES = 60;
// Only checkpoint sessions modified within this window (ms)
const STALENESS_THRESHOLD_MS = (parseInt(process.env.SESSION_STALE_HOURS, 10) || 4) * 60 * 60 * 1000;
// Minimum session size to bother checkpointing
const MIN_SESSION_BYTES = 1024;

const DRY_RUN = process.argv.includes("--dry-run");
const VERBOSE = process.argv.includes("--verbose");

function log(...args) {
  console.log(`[memory-checkpoint] ${new Date().toISOString()}`, ...args);
}

function verbose(...args) {
  if (VERBOSE) log(...args);
}

/**
 * Load Clawdbot config to discover agents and their workspaces.
 */
async function loadConfig() {
  const raw = await fs.readFile(CONFIG_PATH, "utf-8");
  return JSON.parse(raw);
}

/**
 * Resolve workspace directory for an agent from config.
 */
function resolveWorkspace(cfg, agentId) {
  const agents = cfg?.agents?.list || [];
  const agentConfig = agents.find(
    (a) => a.id === agentId || a.name?.toLowerCase() === agentId
  );
  if (agentConfig?.workspace) {
    return agentConfig.workspace.replace(/^~/, os.homedir());
  }
  const defaults = cfg?.agents?.defaults?.workspace;
  if (agentId === "main" && defaults) {
    return defaults.replace(/^~/, os.homedir());
  }
  return path.join(os.homedir(), agentId === "main" ? "clawd" : `clawd-${agentId}`);
}

/**
 * Find the most recently modified .jsonl session file for an agent.
 */
async function findActiveSession(agentId) {
  const sessionsDir = path.join(CLAWDBOT_HOME, "agents", agentId, "sessions");

  let entries;
  try {
    entries = await fs.readdir(sessionsDir);
  } catch {
    return null;
  }

  const jsonlFiles = entries.filter(
    (f) => f.endsWith(".jsonl") && !f.includes(".deleted") && !f.includes(".lock")
  );

  if (jsonlFiles.length === 0) return null;

  // Find most recently modified
  let newest = null;
  let newestMtime = 0;

  for (const f of jsonlFiles) {
    const fp = path.join(sessionsDir, f);
    try {
      const stat = await fs.stat(fp);
      if (stat.mtimeMs > newestMtime) {
        newestMtime = stat.mtimeMs;
        newest = { path: fp, mtimeMs: stat.mtimeMs, size: stat.size };
      }
    } catch {
      // skip
    }
  }

  if (!newest) return null;

  // Check staleness
  const age = Date.now() - newest.mtimeMs;
  if (age > STALENESS_THRESHOLD_MS) {
    verbose(`${agentId}: newest session is ${Math.round(age / 60000)}m old, skipping`);
    return null;
  }

  if (newest.size < MIN_SESSION_BYTES) {
    verbose(`${agentId}: session too small (${newest.size}B), skipping`);
    return null;
  }

  return newest;
}

/**
 * Read the last N lines from a file efficiently (reads from end).
 */
async function readLastLines(filePath, maxLines) {
  const content = await fs.readFile(filePath, "utf-8");
  const lines = content.trim().split("\n");
  return lines.slice(-maxLines);
}

/**
 * Extract structured message data from JSONL lines.
 */
function extractMessages(lines) {
  const messages = [];

  for (const line of lines) {
    try {
      const entry = JSON.parse(line);
      if (entry.type !== "message" || !entry.message) continue;

      const msg = entry.message;
      const role = msg.role;
      if (role !== "user" && role !== "assistant") continue;

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

      if (!text || text.length < 5) continue;
      // Skip internal control messages
      if (text === "HEARTBEAT_OK" || text === "NO_REPLY") continue;
      if (text.startsWith("/")) continue;

      messages.push({
        role,
        text: text.slice(0, 1000), // Cap per-message length
        timestamp: entry.timestamp || null,
        model: msg.model || null,
      });
    } catch {
      // Skip malformed lines
    }
  }

  return messages;
}

/**
 * Build ACTIVE_CONTEXT.md content from extracted messages.
 */
function buildActiveContext(agentId, messages, sessionPath) {
  const now = new Date();
  const timestamp = now.toISOString();
  const sessionId = path.basename(sessionPath, ".jsonl");

  const sections = [
    `# Active Context — ${agentId}`,
    `> Auto-generated by memory-checkpoint at ${timestamp}`,
    `> Session: ${sessionId}`,
    `> Messages captured: ${messages.length}`,
    "",
  ];

  // Extract what the agent is working on (last few assistant messages)
  const recentAssistant = messages
    .filter((m) => m.role === "assistant")
    .slice(-5);
  const recentUser = messages.filter((m) => m.role === "user").slice(-5);

  if (recentUser.length > 0) {
    sections.push("## Recent Requests");
    for (const msg of recentUser) {
      const ts = msg.timestamp
        ? new Date(msg.timestamp).toLocaleTimeString("en-US", {
            hour: "2-digit",
            minute: "2-digit",
            hour12: false,
          })
        : "??:??";
      sections.push(`- **[${ts}]** ${msg.text.slice(0, 300)}`);
    }
    sections.push("");
  }

  if (recentAssistant.length > 0) {
    sections.push("## Recent Work");
    for (const msg of recentAssistant) {
      const ts = msg.timestamp
        ? new Date(msg.timestamp).toLocaleTimeString("en-US", {
            hour: "2-digit",
            minute: "2-digit",
            hour12: false,
          })
        : "??:??";
      // Take first 400 chars of assistant message as summary
      sections.push(`- **[${ts}]** ${msg.text.slice(0, 400)}`);
    }
    sections.push("");
  }

  // Extract file references
  const allText = messages.map((m) => m.text).join("\n");
  const fileRefs = new Set();
  const filePatterns = allText.matchAll(
    /(?:^|\s)((?:[\w./-]+\/)+[\w.-]+\.\w{1,10})(?:\s|$|[,;:)\]])/gm
  );
  for (const match of filePatterns) {
    const ref = match[1];
    if (
      ref.length > 5 &&
      !ref.startsWith("http") &&
      !ref.includes("node_modules")
    ) {
      fileRefs.add(ref);
    }
  }
  if (fileRefs.size > 0) {
    sections.push("## Files Referenced");
    for (const ref of [...fileRefs].slice(0, 20)) {
      sections.push(`- \`${ref}\``);
    }
    sections.push("");
  }

  return sections.join("\n");
}

/**
 * Build a daily log entry from extracted messages.
 */
function buildDailyEntry(agentId, messages) {
  const now = new Date();
  const timeStr = now.toLocaleTimeString("en-US", {
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  });

  const lines = [
    `### Checkpoint ${timeStr} (auto)`,
    "",
  ];

  // Summarize: count of messages, most recent topics
  const userMsgs = messages.filter((m) => m.role === "user");
  const assistantMsgs = messages.filter((m) => m.role === "assistant");

  lines.push(
    `- ${messages.length} messages (${userMsgs.length} user, ${assistantMsgs.length} assistant)`
  );

  // Last user request as topic indicator
  if (userMsgs.length > 0) {
    const lastUser = userMsgs[userMsgs.length - 1];
    lines.push(`- Last request: ${lastUser.text.slice(0, 200)}`);
  }

  // Last assistant output as status indicator
  if (assistantMsgs.length > 0) {
    const lastAssistant = assistantMsgs[assistantMsgs.length - 1];
    lines.push(`- Last output: ${lastAssistant.text.slice(0, 200)}`);
  }

  lines.push("");
  return lines.join("\n");
}

/**
 * Process a single agent: find session, extract, write checkpoint.
 */
async function checkpointAgent(cfg, agentId) {
  const session = await findActiveSession(agentId);
  if (!session) {
    verbose(`${agentId}: no active session`);
    return false;
  }

  verbose(`${agentId}: reading ${session.path} (${session.size}B)`);

  const lines = await readLastLines(session.path, MAX_LINES);
  const messages = extractMessages(lines);

  if (messages.length < 3) {
    verbose(`${agentId}: too few messages (${messages.length}), skipping`);
    return false;
  }

  const workspace = resolveWorkspace(cfg, agentId);
  const memoryDir = path.join(workspace, "memory");

  // Ensure memory directory exists
  try {
    await fs.mkdir(memoryDir, { recursive: true });
  } catch {
    log(`${agentId}: failed to create memory dir ${memoryDir}`);
    return false;
  }

  // Build checkpoint content
  const activeContext = buildActiveContext(agentId, messages, session.path);
  const dailyEntry = buildDailyEntry(agentId, messages);

  const now = new Date();
  const dateStr = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, "0")}-${String(now.getDate()).padStart(2, "0")}`;
  const dailyFile = path.join(memoryDir, `${dateStr}.md`);
  const activeContextFile = path.join(memoryDir, "ACTIVE_CONTEXT.md");

  if (DRY_RUN) {
    log(`${agentId}: [DRY RUN] would write ACTIVE_CONTEXT.md (${activeContext.length} chars)`);
    log(`${agentId}: [DRY RUN] would append to ${dateStr}.md (${dailyEntry.length} chars)`);
    return true;
  }

  // Write ACTIVE_CONTEXT.md (overwrite — it's current state)
  try {
    await fs.writeFile(activeContextFile, activeContext, "utf-8");
    verbose(`${agentId}: wrote ACTIVE_CONTEXT.md (${activeContext.length} chars)`);
  } catch (err) {
    log(`${agentId}: failed to write ACTIVE_CONTEXT.md:`, err.message);
  }

  // Append to daily log
  try {
    let existing = "";
    try {
      existing = await fs.readFile(dailyFile, "utf-8");
    } catch {
      // File doesn't exist yet — create with header
      existing = `# ${agentId} — ${dateStr}\n\n`;
    }

    // Don't append if we already have a checkpoint within the last 15 minutes
    const recentCheckpoint = existing.includes(`Checkpoint ${now.toLocaleTimeString("en-US", { hour: "2-digit", minute: "2-digit", hour12: false }).slice(0, 4)}`);
    if (!recentCheckpoint) {
      await fs.writeFile(dailyFile, existing + dailyEntry, "utf-8");
      verbose(`${agentId}: appended to ${dateStr}.md`);
    } else {
      verbose(`${agentId}: skipped daily append (recent checkpoint exists)`);
    }
  } catch (err) {
    log(`${agentId}: failed to append daily log:`, err.message);
  }

  return true;
}

/**
 * Main: checkpoint all agents.
 */
async function main() {
  log("Starting checkpoint run" + (DRY_RUN ? " [DRY RUN]" : ""));

  let cfg;
  try {
    cfg = await loadConfig();
  } catch (err) {
    log("Failed to load config:", err.message);
    process.exit(1);
  }

  const agents = (cfg.agents?.list || []).map((a) => a.id);
  if (agents.length === 0) {
    log("No agents found in config");
    process.exit(0);
  }

  let checkpointed = 0;
  for (const agentId of agents) {
    try {
      const didCheckpoint = await checkpointAgent(cfg, agentId);
      if (didCheckpoint) checkpointed++;
    } catch (err) {
      log(`${agentId}: error:`, err.message);
    }
  }

  log(`Done. Checkpointed ${checkpointed}/${agents.length} agents.`);
}

main().catch((err) => {
  log("Fatal error:", err.message);
  process.exit(1);
});
