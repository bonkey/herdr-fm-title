// node --test tests/ — both OpenCode halves with fake ctx/api objects. The server half runs the
// real fm-title against a stub backend; the TUI half runs the real herdr-title against a herdr shim.
import assert from "node:assert/strict";
import { chmodSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, test } from "node:test";

const dir = mkdtempSync(join(tmpdir(), "herdr-fm-title-oc-"));
const log = join(dir, "herdr.log");
const script = (name, body) => {
  const path = join(dir, name);
  writeFileSync(path, `#!/bin/sh\n${body}\n`);
  chmodSync(path, 0o755);
  return path;
};
const stubOk = script("stub-ok", 'cat >/dev/null; echo "Login Crash Fix"');
const stubFail = script("stub-fail", "cat >/dev/null; exit 1");
const herdrShim = script(
  "herdr",
  `[ "$1 $2" = "pane get" ] && { echo '{"result":{"pane":{"agent":"opencode"}}}'; exit; }\nprintf '%s\\n' "$*" >>"${log}"`,
);
const reports = () => (existsSync(log) ? readFileSync(log, "utf8").trim().split("\n") : []);
const waitFor = async (predicate) => {
  for (let i = 0; i < 100 && !predicate(); i++) await new Promise((r) => setTimeout(r, 20));
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

before(() => {
  Object.assign(process.env, {
    XDG_STATE_HOME: join(dir, "state"),
    XDG_CACHE_HOME: join(dir, "cache"),
    HERDR_BIN_PATH: herdrShim,
  });
});
after(() => rmSync(dir, { recursive: true, force: true }));

const server = (await import("../runtime/opencode/index.js")).default;
const tui = (await import("../runtime/opencode/tui.js")).default;

async function titleHook() {
  let hook;
  await server.setup({ session: { hook: async (name, fn) => name === "title" && (hook = fn) } });
  return hook;
}
const firstMessage = (text) => ({ messages: [{ role: "user", content: [{ type: "text", text }] }] });

test("title hook sets the title from fm-title", async () => {
  process.env.HERDR_FM_TITLE_BACKEND = stubOk;
  const ev = firstMessage("fix the login crash on the settings screen");
  await (await titleHook())(ev);
  assert.equal(ev.result, "Login Crash Fix");
});

test("title hook leaves the title to OpenCode when fm-title fails", async () => {
  process.env.HERDR_FM_TITLE_BACKEND = stubFail;
  const ev = firstMessage("fix the login crash on the settings screen");
  await (await titleHook())(ev);
  assert.equal(ev.result, undefined);
});

test("title hook never throws on odd events", async () => {
  process.env.HERDR_FM_TITLE_BACKEND = stubOk;
  const hook = await titleHook();
  for (const ev of [{}, { messages: null }, { messages: [{ role: "user", content: "text" }] }]) {
    await hook(ev);
    assert.equal(ev.result, undefined);
  }
});

function fakeApi(route, sessions) {
  const api = {
    listener: undefined,
    unsubscribed: false,
    ui: { router: { current: () => route.current } },
    data: {
      session: { get: (id) => sessions[id] },
      listen: (fn) => {
        api.listener = fn;
        return () => (api.unsubscribed = true);
      },
    },
    emit: (type, data) => api.listener({ details: { type, data } }),
  };
  return api;
}

test("TUI mirrors root session titles to herdr", async () => {
  rmSync(log, { force: true });
  Object.assign(process.env, { HERDR_ENV: "1", HERDR_PANE_ID: "p1" });
  const route = { current: { type: "session", sessionID: "child" } };
  const sessions = {
    root: { title: "New session - 2026-09-26T10:00:00Z" },
    child: { parentID: "root", title: "Child session - x" },
    other: { title: "Other Work" },
  };
  const api = fakeApi(route, sessions);
  const dispose = tui.setup(api);

  await sleep(150);
  assert.deepEqual(reports(), [], "default titles are not reported");

  api.emit("session.renamed", { sessionID: "root", title: "Login Crash Fix" });
  await waitFor(() => reports().length === 1);
  api.emit("session.renamed", { sessionID: "root", title: "Login Crash Fix" });
  api.emit("session.renamed", { sessionID: "other", title: "Not This Pane" });
  await sleep(150);
  assert.deepEqual(reports(), ["pane report-metadata p1 --source plugin:bonkey.fm-title --agent opencode --title Login Crash Fix"]);

  route.current = { type: "session", sessionID: "other" };
  await waitFor(() => reports().length === 2);
  assert.match(reports()[1], /--title Other Work$/);

  dispose();
  assert.equal(api.unsubscribed, true);
});

test("TUI does nothing outside herdr", () => {
  delete process.env.HERDR_ENV;
  const api = fakeApi({ current: { type: "home" } }, {});
  assert.equal(tui.setup(api), undefined);
  assert.equal(api.listener, undefined);
});
