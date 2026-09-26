// herdr-fm-title, OpenCode V2 TUI half: mirrors the routed root session's title to the herdr
// pane. Only this pane-local half knows HERDR_PANE_ID; one OpenCode service can serve many panes.
// The route has no change event, so it is polled like herdr's own OpenCode plugin does.
import { execFile } from "node:child_process";
import { realpathSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const herdrTitle = join(dirname(realpathSync(fileURLToPath(import.meta.url))), "..", "bin", "herdr-title");
const DEFAULT_TITLE = /^(New|Child) session - /;

function setup(api) {
  if (process.env.HERDR_ENV !== "1" || !process.env.HERDR_PANE_ID) return;
  let selected;
  let last;

  const root = (id) => {
    const seen = new Set();
    while (typeof id === "string" && !seen.has(id)) {
      seen.add(id);
      const session = api.data.session.get(id);
      if (!session) return;
      if (!session.parentID) return id;
      id = session.parentID;
    }
  };

  const report = (title) => {
    if (typeof title !== "string" || !title || DEFAULT_TITLE.test(title) || title === last) return;
    last = title;
    execFile(herdrTitle, ["opencode", title], () => {});
  };

  const sync = () => {
    const route = api.ui.router.current();
    const id = route?.type === "session" ? root(route.sessionID) : undefined;
    if (id === selected) return;
    selected = id;
    last = undefined;
    if (id) report(api.data.session.get(id)?.title);
  };

  const unsubscribe = api.data.listen(({ details: event }) => {
    if (event?.type !== "session.renamed") return;
    sync();
    if (event.data?.sessionID === selected) report(event.data.title);
  });
  sync();
  const poll = setInterval(sync, 100);
  return () => {
    clearInterval(poll);
    unsubscribe();
  };
}

export default { id: "herdr-fm-title.tui", setup };
