/**
 * Memory Index Inject Hook
 *
 * Progressive disclosure: injects a compact INDEX.md at agent bootstrap
 * instead of letting agents load their entire memory pool.
 *
 * Fires on: agent:bootstrap
 * Effect: Adds INDEX.md content as a bootstrap file with load-on-demand instructions
 */

import fs from "node:fs/promises";
import path from "node:path";

// Minimum total memory size (bytes) to trigger index injection
const MEMORY_THRESHOLD_BYTES = 50 * 1024; // 50KB

const memoryIndexInject = async (event) => {
  // Only fire on agent:bootstrap
  if (event.type !== "agent" || event.action !== "bootstrap") {
    return;
  }

  const context = event.context;
  if (!context?.workspaceDir || !Array.isArray(context.bootstrapFiles)) {
    return;
  }

  const workspaceDir = context.workspaceDir;
  const memoryDir = path.join(workspaceDir, "memory");
  const indexPath = path.join(memoryDir, "INDEX.md");

  // Check if INDEX.md exists
  try {
    await fs.access(indexPath);
  } catch {
    // No INDEX.md — skip (generate-memory-index.sh hasn't run yet)
    console.log("[memory-index-inject] No INDEX.md found, skipping");
    return;
  }

  // Check total memory size to decide if progressive disclosure is worthwhile
  let totalMemoryBytes = 0;
  try {
    const files = await fs.readdir(memoryDir);
    for (const f of files) {
      if (f.endsWith(".md") && f !== "INDEX.md") {
        const stat = await fs.stat(path.join(memoryDir, f));
        totalMemoryBytes += stat.size;
      }
    }
  } catch {
    return;
  }

  if (totalMemoryBytes < MEMORY_THRESHOLD_BYTES) {
    console.log(
      `[memory-index-inject] Memory pool ${totalMemoryBytes}B < ${MEMORY_THRESHOLD_BYTES}B threshold, skipping`
    );
    return;
  }

  // Read INDEX.md
  let indexContent;
  try {
    indexContent = await fs.readFile(indexPath, "utf-8");
  } catch {
    console.error("[memory-index-inject] Failed to read INDEX.md");
    return;
  }

  // Read ACTIVE_CONTEXT.md (always inject alongside index)
  let activeContextContent = null;
  const activeContextPath = path.join(memoryDir, "ACTIVE_CONTEXT.md");
  try {
    activeContextContent = await fs.readFile(activeContextPath, "utf-8");
  } catch {
    // ACTIVE_CONTEXT.md is optional
  }

  // Build the progressive disclosure instruction
  const instruction = `## Progressive Memory Disclosure

Your memory pool contains ${Math.round(totalMemoryBytes / 1024)}KB (~${Math.round(totalMemoryBytes / 4)} tokens) across multiple files.
To avoid wasting context on irrelevant memory, you've been given a compact INDEX instead of the full contents.

**How to use:**
1. ACTIVE_CONTEXT.md is loaded below — it contains your current working state
2. The INDEX shows all available memory files with categories, sizes, and observation markers
3. Use \`memory_search\` to find relevant files by topic
4. Use \`memory_get\` to load specific sections of specific files
5. **Don't load everything** — only pull what's relevant to the current task

**Observation markers in memory files:**
- 🔴 [GOTCHA] — Traps, footguns, unexpected behavior
- 🟤 [DECISION] — Architectural/strategic choices
- ⚖️ [TRADEOFF] — Evaluated options with pros/cons
- 🟡 [SOLUTION] — Problem + how it was solved
- 🔵 [PATTERN] — Reusable approach or workflow
- 🟢 [FACT] — Verified reference data
- 🟣 [PREFERENCE] — User preference
- ⚪ [TODO] — Action items
`;

  // Inject as bootstrap files
  const combinedContent = [instruction, "---", "", indexContent].join("\n");

  context.bootstrapFiles.push({
    name: "MEMORY_INDEX.md",
    content: combinedContent,
  });

  if (activeContextContent) {
    context.bootstrapFiles.push({
      name: "ACTIVE_CONTEXT.md",
      content: activeContextContent,
    });
  }

  console.log(
    `[memory-index-inject] Injected INDEX (${indexContent.length} chars) + ACTIVE_CONTEXT for ${workspaceDir}`
  );
};

export default memoryIndexInject;
