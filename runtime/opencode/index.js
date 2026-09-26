// herdr-fm-title, OpenCode V2 server half: supplies session titles from the on-device model.
// OpenCode runs the `title` hook only while a root session still has its default title, and
// uses its own title model when this leaves `ev.result` unset (fm-title failed or timed out).
import { execFile } from "node:child_process";
import { realpathSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

// The OpenCode service's PATH belongs to whichever process started it, so fm-title is addressed
// through this file's real location in the deployed runtime.
const fmTitle = join(dirname(realpathSync(fileURLToPath(import.meta.url))), "..", "bin", "fm-title");

function titleFor(text) {
  return new Promise((resolve) => {
    const child = execFile(fmTitle, { timeout: 10000 }, (error, stdout) => {
      resolve(error ? undefined : stdout.trim().split("\n")[0] || undefined);
    });
    child.stdin.on("error", () => {});
    child.stdin.end(text);
  });
}

async function onTitle(ev) {
  try {
    const text = (ev.messages ?? [])
      .filter((m) => m.role === "user")
      .flatMap((m) => (Array.isArray(m.content) ? m.content : []))
      .filter((p) => p.type === "text" && typeof p.text === "string")
      .map((p) => p.text)
      .join("\n");
    const title = text && (await titleFor(text));
    if (title) ev.result = title;
  } catch {}
}

export default {
  id: "herdr-fm-title",
  async setup(ctx) {
    await ctx.session.hook("title", onTitle);
  },
};
