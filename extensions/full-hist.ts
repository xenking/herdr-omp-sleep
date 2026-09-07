// /full-hist — this session's whole conversation, in a split pane.
//
// omp's scrollback is rebuilt from the model's context, so a compaction takes
// your own words with it. The .jsonl on disk keeps everything. `omp-hist`
// renders it with omp's own transcript components; run with stdout captured
// (which is what an extension gets) it splits the herdr pane and pages there,
// so tens of thousands of rows never enter the agent's context.
//
// The command supplies the live file and leaf; Herdr's file-only report cannot
// distinguish two panes on different branches of one journal.
import type { ExtensionAPI, ExtensionCommandContext } from "@oh-my-pi/pi-coding-agent";

export default function fullHist(pi: ExtensionAPI) {
	pi.registerCommand("full-hist", {
		description: "Open this session's full history (pre-compaction) in a split pane",
		handler: async (_args: string, ctx: ExtensionCommandContext) => {
			if (!process.env.HERDR_PANE_ID) {
				ctx.ui.notify("full-hist: not in a herdr pane — run `omp-hist` in a terminal", "error");
				return;
			}
			const file = ctx.sessionManager.getSessionFile();
			const leaf = ctx.sessionManager.getLeafId();
			if (!file || !leaf) {
				ctx.ui.notify("full-hist: no selected conversation history", "info");
				return;
			}
			const proc = Bun.spawn(["omp-hist", file, leaf], { stdout: "pipe", stderr: "pipe" });
			const [code, err] = await Promise.all([proc.exited, new Response(proc.stderr).text()]);
			if (code !== 0) {
				ctx.ui.notify(`full-hist: ${err.trim() || `omp-hist exited ${code}`}`, "error");
			}
		},
	});
}
