import { strict as assert } from "node:assert";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir, homedir } from "node:os";
import { join } from "node:path";
import sleepState from "../extensions/sleep-state";
import type { ExtensionAPI, ExtensionContext, ExtensionCommandContext, SessionManager as Manager } from "@oh-my-pi/pi-coding-agent";

const source = process.env.OMP_SRC ?? join(homedir(), ".bun/install/global/node_modules/@oh-my-pi/pi-coding-agent/src");
// The installed OMP source is selected at runtime, just like omp-render.
const { SessionManager } = await import(join(source, "session/session-manager.ts"));
const dir = mkdtempSync(join(tmpdir(), "sleep-state-test-"));
const saved = { pane: process.env.HERDR_PANE_ID, agent: process.env.PI_CODING_AGENT_DIR,
  session: process.env.OMP_SLEEP_RESUME_SESSION, leaf: process.env.OMP_SLEEP_RESUME_LEAF };
process.env.HERDR_PANE_ID = "test-pane";
process.env.PI_CODING_AGENT_DIR = dir;
delete process.env.OMP_SLEEP_RESUME_SESSION;
delete process.env.OMP_SLEEP_RESUME_LEAF;
mkdirSync(join(dir, "frozen"));
const managers: Manager[] = [];
function extension(manager: Manager, hasUI = true, askDialog?: ExtensionCommandContext["ui"]["askDialog"]) {
  const events = new Map<string, (event: Record<string, never>, ctx: ExtensionContext) => unknown>();
  const commands = new Map<string, Parameters<ExtensionAPI["registerCommand"]>[1]>();
  let stopped = false;
  const blocked: unknown[] = [];
  // This in-process double implements only the command surface exercised here.
  const ctx = {
    isIdle: () => true,
    hasUI, sessionManager: manager, setInterval() {},
    ui: { notify() {}, askDialog }, shutdown() { stopped = true; },
    async waitForIdle() {},
    async navigateTree(id: string) { manager.branch(id); return { cancelled: false }; },
  } as unknown as ExtensionCommandContext;
  // Registration capture stands in for OMP; SessionManager below is the real implementation.
  const api = { on: (name: string, fn: (event: Record<string, never>, ctx: ExtensionContext) => unknown) => events.set(name, fn),
    registerCommand: (name: string, command: Parameters<ExtensionAPI["registerCommand"]>[1]) => commands.set(name, command),
    appendEntry: (kind: string, data: unknown) => manager.appendCustomEntry(kind, data),
    events: { emit: (name: string, data: unknown) => {
      if (name === "herdr:blocked" && data && typeof data === "object" && "active" in data) blocked.push(data.active);
    } },
  } as unknown as ExtensionAPI;
  sleepState(api);
  return { events, commands, ctx, blocked, stopped: () => stopped };
}

try {
  const file = join(dir, "branches.jsonl");
  const stamp = "2026-01-01T00:00:00.000Z";
  const entries = [
    { type: "session", version: 3, id: "test-session", cwd: dir, timestamp: stamp },
    { type: "message", id: "root", parentId: null, timestamp: stamp, message: { role: "user", content: "COMMON", timestamp: 1 } },
    { type: "message", id: "a", parentId: "root", timestamp: stamp, message: { role: "user", content: "A_ONLY", timestamp: 2 } },
    { type: "message", id: "b", parentId: "root", timestamp: stamp, message: { role: "user", content: "B_ONLY", timestamp: 3 } },
  ];
  writeFileSync(file, entries.map(e => JSON.stringify(e)).join("\n") + "\n");
  const manager = await SessionManager.open(file, undefined, undefined, { suppressBreadcrumb: true });
  managers.push(manager);
  manager.branch("a");
  const owner = extension(manager);
  owner.events.get("session_start")!({}, owner.ctx);
  const live = join(dir, "frozen", `test-pane.live.${process.pid}.json`);
  assert.equal(JSON.parse(readFileSync(live, "utf8")).leafId, "a");

  const headless = extension(manager, false);
  manager.branch("b");
  headless.events.get("session_start")!({}, headless.ctx);
  assert.equal(JSON.parse(readFileSync(live, "utf8")).leafId, "a", "child cannot steal pane snapshot");
  manager.branch("a");

  const cursor = join(dir, "frozen/test-pane.cursor.json");
  writeFileSync(cursor, JSON.stringify({ ...JSON.parse(readFileSync(live, "utf8")), checkpointed: false }));
  writeFileSync(join(dir, "frozen/test-pane.session"), file);
  const fork = await manager.fork();
  assert.ok(fork && manager.getSessionFile() !== file);
  owner.events.get("session_switch")!({}, owner.ctx);
  owner.events.get("session_shutdown")!({}, owner.ctx);
  await manager.close();
  const checkpoint = JSON.parse(readFileSync(cursor, "utf8"));
  assert.equal(checkpoint.checkpointed, true);
  assert.equal(checkpoint.sessionFile, fork.newSessionFile, "fork target replaces startup path");
  assert.equal(readFileSync(join(dir, "frozen/test-pane.session"), "utf8"), fork.newSessionFile);
  assert.equal(manager.getEntry(checkpoint.leafId).parentId, "a", "anchor preserves a user-message leaf");

  // A later sibling append must not own the cursor chosen by the sleeping pane.
  const sibling = await SessionManager.open(checkpoint.sessionFile, undefined, undefined, { suppressBreadcrumb: true });
  managers.push(sibling);
  sibling.branch("b");
  sibling.appendCustomEntry("sibling-after-sleep", {});
  await sibling.close();
  const resumed = await SessionManager.open(checkpoint.sessionFile, undefined, undefined, { suppressBreadcrumb: true });
  managers.push(resumed);
  assert.notEqual(resumed.getLeafId(), checkpoint.leafId);
  process.env.OMP_SLEEP_RESUME_SESSION = checkpoint.sessionId;
  process.env.OMP_SLEEP_RESUME_LEAF = checkpoint.leafId;
  const restore = extension(resumed);
  await restore.commands.get("omp-sleep-resume").handler("", restore.ctx);
  assert.equal(restore.stopped(), false);
  const branch = JSON.stringify(resumed.getBranch());
  assert.ok(branch.includes("A_ONLY") && !branch.includes("B_ONLY"));
  assert.equal(resumed.getLeafId(), checkpoint.leafId);

  process.env.OMP_SLEEP_RESUME_SESSION = "wrong-session";
  process.env.OMP_SLEEP_RESUME_LEAF = checkpoint.leafId;
  const wrong = extension(resumed);
  await wrong.commands.get("omp-sleep-resume").handler("", wrong.ctx);
  assert.equal(wrong.stopped(), true, "identity mismatch shuts down instead of continuing");

  let resolveAsk: (value: undefined) => void = () => {};
  const pendingAsk = new Promise<undefined>(resolve => { resolveAsk = resolve; });
  const ask = extension(resumed, true, () => pendingAsk);
  ask.events.get("session_start")!({}, ask.ctx);
  const answer = ask.ctx.ui.askDialog!([]);
  assert.deepEqual(ask.blocked, [true], "dialog is blocked while unresolved without tool execution events");
  resolveAsk(undefined);
  await answer;
  assert.deepEqual(ask.blocked, [true, false]);
  const rejected = extension(resumed, true, async () => { throw new Error("cancelled"); });
  rejected.events.get("session_start")!({}, rejected.ctx);
  await assert.rejects(rejected.ctx.ui.askDialog!([]), /cancelled/);
  assert.deepEqual(rejected.blocked, [true, false], "rejection cannot leave the pane blocked");
  console.log("sleep-state: fork checkpoint, branch isolation, child guard, invalid identity: ok");
} finally {
  for (const manager of managers) await manager.close();
  for (const [key, value] of Object.entries({ HERDR_PANE_ID: saved.pane, PI_CODING_AGENT_DIR: saved.agent,
    OMP_SLEEP_RESUME_SESSION: saved.session, OMP_SLEEP_RESUME_LEAF: saved.leaf })) {
    if (value === undefined) delete process.env[key]; else process.env[key] = value;
  }
  rmSync(dir, { recursive: true, force: true });
}
