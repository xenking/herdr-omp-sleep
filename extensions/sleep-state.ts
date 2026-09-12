import { mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { isAbsolute, join } from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@oh-my-pi/pi-coding-agent";

interface Position {
  version: 1;
  pid: number;
  sessionFile: string;
  sessionId: string;
  leafId: string | null;
  hasMessages: boolean;
  updatedAt: number;
  checkpointed?: boolean;
  runtime: {
    kind: "omp" | "omp-exp";
    command: string[];
    env: Record<string, string>;
  };
}

export default function sleepState(pi: ExtensionAPI) {
  const pane = process.env.HERDR_PANE_ID;
  if (!pane || !/^[A-Za-z0-9:_-]+$/.test(pane)) return;
  const dir = join(process.env.PI_CODING_AGENT_DIR ?? join(process.env.HOME ?? ".", ".omp", "agent"), "frozen");
  const live = join(dir, `${pane}.live.${process.pid}.json`);
  const cursor = join(dir, `${pane}.cursor.json`);
  const hint = join(dir, `${pane}.session`);
  const resumeSession = process.env.OMP_SLEEP_RESUME_SESSION;
  const resumeLeaf = process.env.OMP_SLEEP_RESUME_LEAF;
  let restoring = Boolean(resumeSession || resumeLeaf);
  let active: ExtensionContext | undefined;
  let polling = false;
  let hasMessages = false;
  const askUIs = new WeakSet<object>();
  const runtime: Position["runtime"] = {
    kind: process.env.OMP_EXP_LAUNCHER ? "omp-exp" : "omp",
    command: [process.execPath, ...process.execArgv, process.argv[1]],
    env: {},
  };
  for (const key of ["PATH", "PI_CONFIG_FILES", "PI_CODING_AGENT_DIR", "PI_CODING_AGENT_SESSION_DIR", "OMP_EXP_LAUNCHER"]) {
    const value = process.env[key];
    if (value !== undefined) runtime.env[key] = value;
  }

  const atomicWrite = (file: string, text: string) => {
    mkdirSync(dir, { recursive: true });
    const temp = `${file}.${process.pid}.tmp`;
    writeFileSync(temp, text, { mode: 0o600 });
    renameSync(temp, file);
  };
  const position = (ctx: ExtensionContext): Position | undefined => {
    if (!ctx.hasUI) return;
    const sessionFile = ctx.sessionManager.getSessionFile();
    const sessionId = ctx.sessionManager.getSessionId();
    if (!sessionFile || !isAbsolute(sessionFile) || !sessionId) return;
    return { version: 1, pid: process.pid, sessionFile, sessionId, leafId: ctx.sessionManager.getLeafId(), hasMessages, updatedAt: Date.now(), runtime };
  };
  let openAsks = 0;
  const acknowledge = (ctx: ExtensionContext) => {
    if (!ctx.isIdle() || openAsks > 0) return;
    let request: Position;
    try { request = JSON.parse(readFileSync(cursor, "utf8")); } catch { return; }
    if (request?.version !== 1 || request.pid !== process.pid || request.checkpointed !== false) return;
    try { if (!readFileSync(hint, "utf8").trim()) return; } catch { return; }
    const current = position(ctx);
    if (!current) return;
    // Native tree navigation rewinds user messages, so checkpoint a non-message anchor.
    pi.appendEntry("omp-sleep-anchor", { sessionId: current.sessionId });
    const anchor = ctx.sessionManager.getLeafEntry();
    if (anchor?.type !== "custom" || anchor.customType !== "omp-sleep-anchor") {
      throw new Error("Sleep checkpoint was not appended; refusing to acknowledge sleep");
    }
    atomicWrite(cursor, JSON.stringify({ ...current, leafId: anchor.id, updatedAt: Date.now(), checkpointed: true }));
    atomicWrite(hint, current.sessionFile);
  };
  const sync = (ctx: ExtensionContext, refreshBranch = false) => {
    if (!ctx.hasUI) return;
    active = ctx;
    if (restoring) return;
    if (refreshBranch) hasMessages = ctx.sessionManager.getBranch().some(entry => entry.type === "message");
    acknowledge(ctx);
    const current = position(ctx);
    if (current) atomicWrite(live, JSON.stringify(current));
    else rmSync(live, { force: true });
  };

  pi.on("session_start", (_event, ctx) => {
    if (!ctx.hasUI) return;
    const ui = ctx.ui;
    if (ui.askDialog && !askUIs.has(ui)) {
      const ask = ui.askDialog;
      // Dialog lifetime covers direct, eval and native-helper asks alike.
      // Counting tool_call/tool_result would leak on pre-execution rejection.
      ui.askDialog = async (...args) => {
        openAsks++;
        pi.events.emit("herdr:blocked", { active: true, label: "Waiting for answer" });
        try {
          return await ask.apply(ui, args);
        } finally {
          openAsks--;
          pi.events.emit("herdr:blocked", { active: false });
        }
      };
      askUIs.add(ui);
    }
    sync(ctx, true);
    if (!polling) {
      polling = true;
      ctx.setInterval(() => { if (active) sync(active); }, 5000);
    }
  });
  pi.on("session_switch", (_event, ctx) => sync(ctx, true));
  pi.on("session_branch", (_event, ctx) => sync(ctx, true));
  pi.on("session_tree", (_event, ctx) => sync(ctx, true));
  pi.on("session_compact", (_event, ctx) => sync(ctx, true));
  pi.on("agent_end", (_event, ctx) => sync(ctx));
  pi.on("message_end", (_event, ctx) => {
    if (!ctx.hasUI) return;
    hasMessages = true;
    sync(ctx);
  });

  pi.on("session_shutdown", () => {
    if (active) rmSync(live, { force: true });
  });

  pi.registerCommand("omp-sleep-resume", {
    description: "Restore the exact checkpoint selected by omp-pane before sleeping",
    handler: async (_args, ctx) => {
      try {
        if (!ctx.hasUI || !restoring || !resumeSession || !resumeLeaf) throw new Error("No pending sleep checkpoint");
        if (ctx.sessionManager.getSessionId() !== resumeSession) throw new Error("Sleep session identity mismatch");
        const anchor = ctx.sessionManager.getEntry(resumeLeaf);
        if (anchor?.type !== "custom" || anchor.customType !== "omp-sleep-anchor") throw new Error("Sleep branch checkpoint is missing");
        await ctx.waitForIdle();
        const result = await ctx.navigateTree(resumeLeaf, { summarize: false });
        if (result.cancelled || ctx.sessionManager.getLeafId() !== resumeLeaf) throw new Error("Sleep branch restoration did not complete");
        restoring = false;
        delete process.env.OMP_SLEEP_RESUME_SESSION;
        delete process.env.OMP_SLEEP_RESUME_LEAF;
        sync(ctx, true);
        ctx.ui.notify(`Restored sleeping branch ${resumeLeaf}`, "info");
      } catch (error) {
        ctx.ui.notify(`Cannot restore sleeping branch: ${error instanceof Error ? error.message : String(error)}`, "error");
        ctx.shutdown();
      }
    },
  });

  pi.on("input", (_event, ctx) => {
    if (!ctx.hasUI || !restoring) return;
    ctx.ui.notify("Sleep checkpoint has not been restored; refusing to continue on another branch", "error");
    ctx.shutdown();
    return { action: "handled" };
  });
}
