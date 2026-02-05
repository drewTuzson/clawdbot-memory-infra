/**
 * Session Summary Hook
 *
 * Generates structured session summaries with observation markers.
 * Fires on: command:new
 *
 * Produces a categorized summary with [DECISION], [GOTCHA], [SOLUTION], etc.
 * markers that are searchable across the memory corpus.
 */

import fs from "node:fs/promises";
import path from "node:path";
import os from "node:os";

/**
 * Inline: extract agent ID from a session key like "agent:desmond:slack:dm:..."
 */
function resolveAgentIdFromSessionKey(sessionKey) {
  if (!sessionKey) return "main";
  const parts = sessionKey.split(":");
  // session keys are "agent:{agentId}:..."
  if (parts[0] === "agent" && parts.length >= 2 && parts[1]) {
    return parts[1].toLowerCase();
  }
  return "main";
}

/**
 * Inline: resolve workspace directory for an agent from config
 */
function resolveAgentWorkspaceDir(cfg, agentId) {
  const id = (agentId || "main").trim().toLowerCase();

  // Check agent-specific config
  const agents = cfg?.agents?.list || [];
  const agentConfig = agents.find((a) => a.id === id || a.name?.toLowerCase() === id);
  if (agentConfig?.workspace) {
    return agentConfig.workspace.replace(/^~/, os.homedir());
  }

  // Check defaults
  if (id === "main") {
    const fallback = cfg?.agents?.defaults?.workspace;
    if (fallback) return fallback.replace(/^~/, os.homedir());
    return path.join(os.homedir(), "clawd");
  }

  return path.join(os.homedir(), `clawd-${id}`);
}

/**
 * Read recent messages from session file
 */
async function getSessionContent(sessionFilePath, maxLines = 50) {
  try {
    const content = await fs.readFile(sessionFilePath, "utf-8");
    const lines = content.trim().split("\n");
    const recentLines = lines.slice(-maxLines);

    const messages = [];
    for (const line of recentLines) {
      try {
        const entry = JSON.parse(line);
        if (entry.type === "message" && entry.message) {
          const msg = entry.message;
          const role = msg.role;
          if ((role === "user" || role === "assistant") && msg.content) {
            const text = Array.isArray(msg.content)
              ? msg.content.find((c) => c.type === "text")?.text
              : msg.content;
            if (text && !text.startsWith("/")) {
              messages.push(`${role}: ${text.slice(0, 500)}`);
            }
          }
        }
      } catch {
        // Skip invalid JSON lines
      }
    }
    return messages.join("\n\n");
  } catch {
    return null;
  }
}

/**
 * Generate structured summary via LLM (slug generation)
 */
async function generateStructuredSummary({ sessionContent, cfg }) {
  try {
    const clawdbotRoot = path.resolve(
      path.dirname(import.meta.url.replace("file://", "")),
      "../.."
    );
    const slugGenPath = path.join(clawdbotRoot, "llm-slug-generator.js");
    const { generateSlugViaLLM } = await import(slugGenPath);

    const slug = await generateSlugViaLLM({ sessionContent, cfg });
    return slug || null;
  } catch (err) {
    console.error("[session-summary] LLM slug generation failed:", err);
    return null;
  }
}

/**
 * Build a structured template from session content.
 * Extracts what it can and leaves observation markers for manual refinement.
 */
function buildStructuredTemplate(sessionContent) {
  const todoMatches = sessionContent.match(/- \[ \].+/g) || [];
  const completedMatches = sessionContent.match(/- \[x\].+/gi) || [];

  const parts = [
    "## Session Conversation",
    "",
    sessionContent,
    "",
    "---",
    "",
    "## Observations",
    "_Tag key observations from this session below:_",
    "",
  ];

  if (completedMatches.length > 0) {
    parts.push("### Completed");
    completedMatches.forEach((m) => parts.push(m));
    parts.push("");
  }

  if (todoMatches.length > 0) {
    parts.push("### Pending");
    todoMatches.forEach((m) =>
      parts.push(`⚪ [TODO] ${m.replace(/^- \[ \] /, "")}`)
    );
    parts.push("");
  }

  parts.push(
    "<!-- Add observations as you review:",
    "🟤 [DECISION] ...",
    "🔴 [GOTCHA] ...",
    "🟡 [SOLUTION] ...",
    "🔵 [PATTERN] ...",
    "🟢 [FACT] ...",
    "-->"
  );

  return parts.join("\n");
}

const sessionSummaryHandler = async (event) => {
  if (event.type !== "command" || event.action !== "new") {
    return;
  }

  try {
    console.log("[session-summary] Hook triggered for /new command");

    const context = event.context || {};
    const cfg = context.cfg;
    const agentId = resolveAgentIdFromSessionKey(event.sessionKey);
    const workspaceDir = cfg
      ? resolveAgentWorkspaceDir(cfg, agentId)
      : path.join(os.homedir(), "clawd");

    const memoryDir = path.join(workspaceDir, "memory");
    await fs.mkdir(memoryDir, { recursive: true });
    await fs.chmod(memoryDir, 0o700);

    // Get session content
    const sessionEntry = (context.previousSessionEntry ||
      context.sessionEntry ||
      {});
    const sessionFile = sessionEntry.sessionFile;

    if (!sessionFile) {
      console.log("[session-summary] No session file available, skipping");
      return;
    }

    const sessionContent = await getSessionContent(sessionFile, 80);
    if (!sessionContent || sessionContent.length < 50) {
      console.log("[session-summary] Session content too short, skipping");
      return;
    }

    // Generate date and slug
    const now = new Date(event.timestamp);
    const dateStr = now.toISOString().split("T")[0];

    let slug = null;
    if (cfg) {
      slug = await generateStructuredSummary({ sessionContent, cfg });
    }

    if (!slug) {
      const timeSlug = now
        .toISOString()
        .split("T")[1]
        .split(".")[0]
        .replace(/:/g, "");
      slug = timeSlug.slice(0, 4);
    }

    // Build the structured summary template
    const filename = `${dateStr}-${slug}.md`;
    const memoryFilePath = path.join(memoryDir, filename);

    // Check if file already exists (session-memory hook may have created it)
    try {
      await fs.access(memoryFilePath);
      console.log(
        "[session-summary] File already exists (from session-memory hook), appending structure"
      );

      const existing = await fs.readFile(memoryFilePath, "utf-8");
      const structured = buildStructuredTemplate(sessionContent);
      await fs.writeFile(
        memoryFilePath,
        existing + "\n\n" + structured,
        "utf-8"
      );
      await fs.chmod(memoryFilePath, 0o600);
    } catch {
      // File doesn't exist, create full structured summary
      const timeStr = now.toISOString().split("T")[1].split(".")[0];
      const header = [
        `# Session: ${dateStr} ${timeStr} UTC — ${slug.replace(/-/g, " ")}`,
        "",
        `- **Session Key**: ${event.sessionKey}`,
        `- **Agent**: ${agentId}`,
        `- **Source**: ${context.commandSource || "unknown"}`,
        "",
      ].join("\n");

      const structured = buildStructuredTemplate(sessionContent);
      await fs.writeFile(memoryFilePath, header + structured, "utf-8");
      await fs.chmod(memoryFilePath, 0o600);
    }

    console.log(`[session-summary] Structured summary written: ${filename}`);
  } catch (err) {
    console.error(
      "[session-summary] Error:",
      err instanceof Error ? err.message : String(err)
    );
  }
};

export default sessionSummaryHandler;
