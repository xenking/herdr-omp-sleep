// draft-keeper — an unsent message must survive the pane going to sleep.
//
// The idle reaper SIGTERMs omp while the pane keeps living in a frozen view.
// Anything typed but not sent lives only in the TUI's editor buffer, so without
// this it dies with the process.
//
// Two halves, and the split is deliberate:
//
//   1. This file mirrors the composer into ~/.omp/agent/frozen/<pane>.draft.
//      `omp-reap-idle` refuses to sleep a pane whose file is non-empty. That is
//      the only thing that saves an ATTACHMENT: `getEditorText()` hands back a
//      `[Image #1, 1024x768]` marker, never the image, so a pasted picture
//      cannot be restored from text by anyone (verified 2026-08-06).
//   2. Whatever still gets caught mid-compose — you quit omp yourself, or you
//      typed in the second between the guard reading the file and the SIGTERM —
//      comes back into the composer on the next start.
//
// Polling beats hooking keystrokes here: it sees text that arrived by paste, by
// another extension, or by any input path added later, and it cannot fall out
// of sync. Five seconds is far inside the reaper's 15-minute window.
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@oh-my-pi/pi-coding-agent";

// No pane means no reaper: nothing kills this session behind your back.
const PANE = process.env.HERDR_PANE_ID;
const DIR = join(
  process.env.PI_CODING_AGENT_DIR ?? join(process.env.HOME ?? ".", ".omp", "agent"),
  "frozen",
);
const POLL_MS = 5000;

export default function draftKeeper(pi: ExtensionAPI) {
  if (!PANE) return;

  const file = join(DIR, `${PANE}.draft`);
  let last = "";
  let polling = false;

  const sync = (ctx: ExtensionContext) => {
    let text: string;
    try {
      text = ctx.ui.getEditorText();
    } catch {
      return; // headless surface — no editor to mirror
    }
    if (text === last) return;
    last = text;
    if (text.trim()) {
      mkdirSync(DIR, { recursive: true });
      writeFileSync(file, text);
    } else {
      rmSync(file, { force: true });
    }
  };

  pi.on("session_start", (_event, ctx) => {
    // Never overwrite something already in the composer: a restored draft is
    // worth less than what you are typing right now.
    if (existsSync(file)) {
      const saved = readFileSync(file, "utf8");
      last = saved;
      try {
        if (saved.trim() && !ctx.ui.getEditorText().trim()) ctx.ui.setEditorText(saved);
      } catch {
        // no editor on this surface; the file stays for the next real session
      }
    }
    if (polling) return;
    polling = true;
    // unref: a mirror of the input box must never be the reason omp stays up.
    setInterval(() => sync(ctx), POLL_MS).unref?.();
  });

  pi.on("session_shutdown", (_event, ctx) => sync(ctx));
}
