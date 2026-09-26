# herdr-fm-title — design

Status: draft for review, 2026-09-26.

## Goal

A herdr plugin that gives each coding-agent session in a herdr pane one short, readable name, generated on-device by Apple's Foundation Models from the first real prompt. The name becomes the pane's metadata title, which [auto-title](https://github.com/kryptamine/herdr-auto-title) shows as the tab label. Where the agent allows it, the same name also becomes the agent's own session name.

Example: the prompt "need some ideation of a plugin for herdr. when I start a fresh session…" should give the tab "Herdr Tab Naming", not "need some ideation of a plugin for herdr. when I s".

herdr is the source and owner of everything. The plugin is installed with `herdr plugin install`. It connects itself to the agents through its own actions, and no agent ever installs it as one of its own plugins.

| Agent | Tab title | Agent's own session name | Rename reaches the tab |
|---|---|---|---|
| Claude Code ≥ 2.1.283 | yes | yes, `sessionTitle` | yes, `/rename`, on the next prompt |
| OpenCode V2 ≥ 2.0.8 | yes | yes, the `title` hook | yes, `session.renamed` |
| Codex ≥ 0.157 | yes | no, Codex keeps its own title | no |

## Requirements

- **macOS with Apple Intelligence enabled.** The title comes from either:
  - the `fm` CLI (macOS 27 and later; accept its terms once with `sudo fm license`), or
  - Xcode Command Line Tools, which provide `swiftc` for the Swift fallback (macOS 26 and later).
- **herdr ≥ 0.9.1,** plus `jq`.
- **[herdr-auto-title](https://github.com/kryptamine/herdr-auto-title) for the tab label.** herdr itself labels tabs by position. Without auto-title, the title appears only where herdr shows pane metadata titles, such as the navigator.

## Verified facts this design rests on

Checked on 2026-09-26 against Claude Code 2.1.283, Codex 0.157.0, OpenCode 2.0.8, herdr 0.9.1 and herdr-auto-title 0.9.0.

| Fact | Evidence |
|---|---|
| auto-title ranks `PaneInfo.title` above every other source (confidence 90), and `herdr pane report-metadata --title` sets it. | auto-title `internal/state/tab.go:117`, herdr socket API docs. Live test: the tab switched within 2.5 s. |
| A metadata title doesn't make auto-title treat the tab as manually named. Clearing it restores the previous label. With several metadata sources, the latest report wins, and clearing one falls back to another. | Live tests. |
| herdr's agent labels are `claude`, `codex` and `opencode`. An agent in a herdr pane inherits `HERDR_ENV`, `HERDR_PANE_ID` and `HERDR_BIN_PATH`. | herdr source and integrations docs. |
| Without a terminal title and an `ai-title` (for example when `CLAUDE_CODE_DISABLE_TERMINAL_TITLE` is set), auto-title names a Claude tab after the raw first prompt. | auto-title title-resolution docs, Claude changelog. |
| Claude: a `UserPromptSubmit` hook gets `prompt` and may return `hookSpecificOutput.sessionTitle`. That writes a `custom-title` record and `<transcript dir>/<session_id>/custom-title.json` = `{"customTitle": …}`. `SessionStart` input carries `session_title` when the session already has one. | Claude hooks docs, `claude -p` test. |
| Codex: `UserPromptSubmit` stdin has `prompt` and `session_id`. The output schema rejects unknown fields, and plain stdout is added to the model's context. The hook inherits the pane environment and honours `"async": true`. Hooks in `~/.codex/hooks.json` need `[features] hooks = true` and a one-time trust approval in `/hooks`. | Codex `rust-v0.157.0` source, herdr's Codex integration docs. |
| OpenCode V2: a plugin folder under the config `plugins/` directory, with `index.js` (server) and `tui.js` (TUI), is loaded automatically. The server half registers `ctx.session.hook("title", ev => …)`. `ev.messages` holds the first user message. Setting `ev.result` skips OpenCode's title model, and leaving it unset falls back to that model. `/rename <text>` doesn't fire the hook. Renames publish `session.renamed {sessionID, title}`. Only the pane-local TUI half knows `HERDR_PANE_ID`, because one OpenCode service can serve several panes. | `@opencode/plugin@2.0.8` typings, binary strings, herdr's OpenCode V2 assets. |
| `fm respond` answers in 0.4–0.6 s warm and 2.3 s cold. A compiled FoundationModels binary is about the same. The `swift` interpreter costs about 4 s per call. | Probe on 12 real first prompts. |

## Architecture

The plugin has two parts, and herdr owns both.

1. **The herdr plugin** (`herdr-plugin.toml` + `scripts/`). It owns the lifecycle: it deploys the runtime to a stable directory, registers it with each agent, keeps registrations current, reports status and removes everything again.
2. **The runtime** (`runtime/`). It runs inside agent hooks and plugins, and has an agent-agnostic core plus one thin adapter per agent.

```
herdr plugin install ──▶ herdr: bonkey.fm-title
                            │  install / uninstall / status actions, startup sync
                            ▼
              ${XDG_DATA_HOME:-~/.local/share}/herdr-fm-title/   (deployed runtime)
                            │  registered with
         ┌──────────────────┼────────────────────┐
         ▼                  ▼                    ▼
   Claude settings.json  Codex hooks.json   OpenCode plugins/herdr-fm-title → runtime/opencode
         └──────────────────┼────────────────────┘
                            ▼
   first prompt ─▶ bin/fm-title ─▶ bin/herdr-title ─▶ pane metadata title ─▶ auto-title ─▶ tab
                       └──▶ agent's own session name, where an API exists
```

Agents run a copy of the runtime at a stable path rather than herdr's managed plugin checkout, for three reasons:

- herdr's checkout layout is internal;
- agents keep a working copy while herdr updates the plugin;
- a hook left behind by an incomplete uninstall still works instead of failing on every prompt.

## The herdr plugin

### Manifest

```toml
id = "bonkey.fm-title"
name = "Agent session titles"
version = "0.1.0"
min_herdr_version = "0.9.1"
description = "Names each agent session from its first prompt with Apple's on-device model; the title reaches the tab via auto-title and, where supported, the agent's own session name."
platforms = ["macos"]

[[startup]]
command = ["sh", "scripts/install.sh", "--sync"]

[[actions]]
id = "install"
title = "Connect agents (Claude Code, Codex, OpenCode)"
contexts = ["workspace"]
command = ["sh", "scripts/install.sh"]

[[actions]]
id = "uninstall"
title = "Disconnect agents"
contexts = ["workspace"]
command = ["sh", "scripts/uninstall.sh"]

[[actions]]
id = "status"
title = "Show agent connections and model backend"
contexts = ["workspace"]
command = ["sh", "scripts/status.sh"]
```

### `install` action

1. **Deploy** `runtime/` to the data directory. It copies into a temporary sibling directory, then renames that into place, so a hook never sees a half-written runtime.
2. **Pick the agents** to connect. By default these are the supported agents whose config directory exists:
   - `${CLAUDE_CONFIG_DIR:-~/.claude}`
   - `${CODEX_HOME:-~/.codex}`
   - `${XDG_CONFIG_HOME:-~/.config}/opencode`

   The optional `agents = [...]` in `$HERDR_PLUGIN_CONFIG_DIR/config.toml` restricts the list.
3. **Register each agent.** Registration is idempotent. Entries are found and replaced by the substring `herdr-fm-title/bin/hook`, and entries from other tools are preserved.
   - **Claude:** in `settings.json`, add a `SessionStart` entry and a `UserPromptSubmit` entry (`timeout: 10`), both running `sh '<data>/bin/hook' claude`.
   - **Codex:** in `hooks.json`, add a `UserPromptSubmit` entry and a `SessionStart` entry (matcher `resume`), both `"async": true` and both running `sh '<data>/bin/hook' codex`. Also make sure `config.toml` has `[features] hooks = true`: if a `[features]` table exists, add the key there, otherwise append the table.
   - **OpenCode:** create the symlink `plugins/herdr-fm-title` → `<data>/opencode`.
4. **Write safely.**
   - Each JSON or TOML file is written atomically (temporary file, then `mv`).
   - Before the first change to a file, it is backed up to `<file>.bak-herdr-fm-title`.
   - A file that doesn't parse is left untouched and reported as an error.
5. **Record** the connected agents in `$HERDR_PLUGIN_STATE_DIR/agents`.
6. **Report** with `herdr notification show` and on stdout, which lands in the plugin log. The report includes the reminder to approve the Codex hooks once in `/hooks`.

### Startup sync (`install.sh --sync`)

This runs on every herdr server start. It redeploys the runtime and refreshes registrations, but only for the agents recorded in `agents`, so it never connects a new agent on its own. Until the next server start, agents keep the previous runtime copy, which keeps working.

### `uninstall` action

- Removes exactly the entries that `install` added, by the same substring. Empty event arrays are dropped, and a Codex `[features] hooks` setting is left alone.
- Removes the OpenCode symlink, the deployed runtime and the `agents` record.
- Leaves in place the backups, and the cache and state directories, which hold the Swift binary and the markers.
- Reports what it removed.

### `status` action

For each supported agent, it shows:

- whether the agent's config directory exists;
- whether the agent is connected;
- whether the registration matches the deployed runtime.

For the model, it shows one of:

- `fm` ready;
- Swift binary ready;
- Swift build pending, when `swiftc` exists but the binary is missing or outdated;
- none, when titles are off.

## Runtime core

### `bin/fm-title`

Contract: the raw prompt comes in on stdin, and one title line goes out on stdout with exit 0. Exit 1 means no title: the text is too short, no backend is available, or the model failed. It never prints anything else to stdout.

1. **Prepare the text:**
   - remove `<pasted_content …>` … `</pasted_content …>` blocks;
   - for a slash command, keep only its arguments. A slash command is a prompt that starts with `/<name>` followed by a space or the end, where `<name>` contains no `/`. So `/code-review spec.md` is a command and `/Users/…` is not. A bare command counts as no text;
   - collapse whitespace and cut to 1500 characters;
   - fewer than 3 words → exit 1.
2. **Pick the backend**, using the first that works:
   1. **`fm`**, when `command -v fm` succeeds and `fm available` exits 0: `fm respond -i "$INSTR" --no-stream -g`, with the text on stdin.
   2. **`${XDG_CACHE_HOME:-~/.cache}/herdr-fm-title/bin/title`**, compiled from `title.swift`. It uses the same interface: `-i INSTR`, text on stdin, reply on stdout, exit 2 when the model is unavailable.
   3. **None** → exit 1.

   `HERDR_FM_TITLE_BACKEND` overrides the backend command. It exists for tests.
3. **Swift build.** This step runs when all of these hold:
   - `fm` is unusable;
   - `swiftc` exists;
   - the binary is missing or older than `title.swift`.

   It starts a detached background build and exits 1 for this call, so the next prompt uses the binary. The build command is `swiftc -O -o title.$$ title.swift && mv -f title.$$ title`. A lock directory prevents parallel builds, and a lock older than 10 minutes counts as stale. The `swift` interpreter is never used.
4. **Clean** the reply, in this order:
   1. keep the first non-empty line;
   2. strip quotes, backticks and colons;
   3. drop words containing `/` or `@`;
   4. keep the first 4 words and at most 40 characters;
   5. trim trailing punctuation.

   If nothing is left, exit 1.

`INSTR`, the best of the probed variants, with neutral example titles:

> Write a short title for the software task below, like a good issue title. 2 to 4 words, Title Case. Name the concrete thing being changed (a command, file, feature, tool or product named in the task) and what happens to it. Keep names spelled exactly as in the task. Examples: "Login Crash Fix", "Git-lfs Fetch Flag", "Cache Status Output", "Onboarding Video Captions". Reply with the title only, one line, no quotes, no punctuation.

Implementation re-runs the probe prompts with this exact wording before it is fixed in `fm-title`.

### `bin/herdr-title <agent> <title>`

This does nothing unless `HERDR_ENV=1` and `HERDR_PANE_ID` is set. When both hold, it runs:

```sh
"${HERDR_BIN_PATH:-herdr}" pane report-metadata "$HERDR_PANE_ID" --source plugin:bonkey.fm-title --agent "$agent" --title "$title" >/dev/null 2>&1
```

It always exits 0.

`--agent` limits the title to the pane while that agent runs. When the agent exits, auto-title names the pane from what runs next.

### State and logs

- **Markers:** `${XDG_STATE_HOME:-~/.local/state}/herdr-fm-title/named/<agent>-<session_id>`, one file per named session, containing its title.
  - A marker means "never generate again for this session", and it lets the title come back when a session is resumed.
  - `bin/hook` deletes markers older than 30 days, at most once a day.
- **Log:** runtime failures append one line to `…/herdr-fm-title/runtime.log`. The log is capped at 100 KB, and the older half is dropped when it's full.

## Adapters

### Claude Code: `bin/hook claude`

The event name comes from `hook_event_name`.

**`SessionStart`.** If `session_title` is non-empty:
- write the marker with it;
- run `herdr-title claude "$session_title"`.

This covers `claude --name …` and resumed sessions.

**`UserPromptSubmit`:**

1. **Marker exists:**
   - read `customTitle` from `${transcript_path%.jsonl}/custom-title.json`;
   - if it is non-empty, update the marker and run `herdr-title claude` with it. This carries `/rename` to the tab on the next prompt;
   - print nothing.
2. **The sidecar has a title but there is no marker:** the session got a name some other way. Write the marker, report the title, print nothing.
3. **Otherwise:**
   - pipe `prompt` to `fm-title`. On exit 1, print nothing; the next prompt retries;
   - write the marker;
   - run `herdr-title claude "$title"`;
   - print `{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","sessionTitle":"<title>"}}`.

The marker is what prevents a second generation. If Claude changes its sidecar format, the worst case is that `/rename` stops reaching the tab. It can never overwrite a user's name.

### Codex: `bin/hook codex`

Both events run async, and the hook never prints to stdout.

**`UserPromptSubmit`:**
1. If the marker exists, stop.
2. Otherwise pipe `prompt` to `fm-title`.
3. On success, write the marker and run `herdr-title codex "$title"`.

**`SessionStart`** (resume): if a marker exists, run `herdr-title codex` with its content.

Codex's session list keeps Codex's own title, and a Codex `/rename` doesn't reach the tab. Both are accepted limits, because Codex offers no hook output for a title.

### OpenCode V2: `opencode/index.js` + `opencode/tui.js`

The server half, `index.js`, registers `ctx.session.hook("title", …)`. The hook:

1. joins the text parts of the user messages in `ev.messages`;
2. passes them to `fm-title` through `node:child_process` `execFile`, with a 10 s timeout. The path is absolute, resolved from the real path of `import.meta.url`, which is the deployed runtime;
3. on success, sets `ev.result`.

Every error is caught. When no title is set, OpenCode falls back to its own title model.

The TUI half, `tui.js`:

- runs only when `HERDR_ENV=1` and `HERDR_PANE_ID` is set;
- follows the routed root session the way herdr's TUI plugin does (`api.ui.router.current()`, polling every 100 ms);
- reports the root session's title when the route changes, and on every `session.renamed` for that root, through `herdr-title opencode`;
- ignores default titles (`New session - …`, `Child session - …`) and skips repeat reports.

OpenCode V1 is not supported.

## Adding an agent

An agent qualifies when it can run code on prompt submit with access to the prompt text. Supporting one takes two changes.

1. **Runtime adapter.** Hook-based agents with Claude-style JSON hooks add a `case` in `bin/hook`. Plugin-based agents get a folder next to `opencode/`. An adapter:
   1. Detects the first real prompt of a session, using a marker keyed on `<agent>-<session_id>` unless the agent tells it directly (like OpenCode's `title` hook).
   2. Pipes the prompt to `bin/fm-title`, and treats exit 1 as "try again on the next prompt".
   3. Calls `bin/herdr-title <agent> <title>` with herdr's label for that agent.
   4. Optionally sets the agent's own session name, and forwards later renames.
   5. Never adds output to the model's context, and never blocks the agent for longer than a first-prompt title takes.
2. **Registration.** Add the agent to `scripts/lib.sh`: how to detect its config directory, and how to register and unregister it idempotently. `install`, `uninstall`, `status` and startup sync pick it up from there.

Research notes for the next candidates, checked 2026-09-26:

- **Pi 0.87:** the extension `input` event carries the prompt. `pi.setSessionName()` names the session, and `session_info_changed` reports renames. Handlers are awaited, so the adapter must not await the subprocess. It registers as a file in `~/.pi/agent/extensions/`.
- **Gemini CLI 0.61:** the `BeforeAgent` hook carries the prompt. There's no session-name API, so it would be tab only. Hooks are awaited, so the adapter must detach its work with stdio closed. It registers in `~/.gemini/settings.json`.

## Layout

```
herdr-fm-title/
  herdr-plugin.toml
  scripts/lib.sh             # paths, agent table, idempotent JSON/TOML/symlink edits
  scripts/install.sh         # action "install" and startup "--sync"
  scripts/uninstall.sh       # action "uninstall"
  scripts/status.sh          # action "status"
  runtime/bin/fm-title       # core: prompt → title
  runtime/bin/herdr-title    # core: title → herdr
  runtime/bin/hook           # hook adapter: claude | codex
  runtime/title.swift        # Swift fallback backend
  runtime/opencode/index.js  # OpenCode server half
  runtime/opencode/tui.js    # OpenCode TUI half
  tests/run.sh               # shell tests: runtime + plugin scripts
  tests/opencode.test.mjs    # node --test: both OpenCode halves with fake ctx/api
  README.md
  LICENSE                    # MIT
```

Dependencies are POSIX sh, `jq`, and `fm` or Swift. The OpenCode half runs inside OpenCode's own runtime.

## Testing

`tests/run.sh` runs offline, with:

- a stub backend (`HERDR_FM_TITLE_BACKEND`);
- `herdr` and `fm` shims on PATH that record their arguments;
- temporary `HOME` and XDG directories.

Cases:

**Runtime:**

1. **`fm-title` text preparation:**
   - pasted blocks removed;
   - slash command with arguments → the arguments;
   - bare command → exit 1;
   - `/Users/…` is not a command;
   - under 3 words → exit 1.
2. **`fm-title` cleaning:** a quoted reply, a path word, 6 words and a trailing period each produce a clean title.
3. **`fm-title` backend order:**
   - `fm` preferred;
   - Swift binary used when `fm` is missing;
   - neither → exit 1;
   - a stale binary starts one background build and never runs the interpreter.
4. **`herdr-title`:**
   - calls the shim with `--source plugin:bonkey.fm-title --agent <agent> --title <title>`;
   - is a no-op outside herdr.
5. **`hook claude UserPromptSubmit`:**
   - first prompt → `sessionTitle`, herdr call, marker;
   - marker plus sidecar "X" → reports "X", prints nothing;
   - sidecar title without a marker → marker written, no generation;
   - backend fails → no output, no marker.
6. **`hook claude SessionStart`:**
   - `session_title` → marker plus report;
   - no `session_title` → nothing.
7. **`hook codex`:**
   - first prompt → herdr call plus marker, empty stdout;
   - marker present → nothing;
   - `SessionStart` resume with a marker → report.

**Plugin scripts:**

8. **`install` with Claude:**
   - other hooks in `settings.json` are preserved;
   - a second run changes nothing;
   - a backup is written once;
   - an unparseable `settings.json` is left untouched and reported.
9. **`install` with Codex:**
   - `hooks.json` entries are added;
   - `[features] hooks = true` is added to an existing `[features]` table, or appended as a new table;
   - an existing `hooks = true` is left as is.
10. **`install` with OpenCode:** the symlink is created and points to the deployed runtime.
11. **Agent selection:**
    - only agents with a config directory are connected;
    - `agents = ["claude"]` in `config.toml` restricts the list.
12. **`install --sync`:**
    - redeploys the runtime;
    - refreshes only the agents recorded in `agents`;
    - never adds an agent.
13. **`uninstall`:**
    - removes only our entries and the symlink;
    - keeps other tools' hooks and the backups.
14. **`status`:** each backend state (`fm` ready, Swift ready, build pending, none) and each connection state is reported correctly.

**OpenCode:** `tests/opencode.test.mjs`, under `node --test`, with fake `ctx` and `api` objects and a stub `fm-title`.

- The title hook:
  - sets `ev.result` from the stub;
  - leaves it unset when the stub fails or times out;
  - never throws.
- The TUI half:
  - reports on route change and on `session.renamed` for the root session;
  - ignores other sessions and default titles;
  - deduplicates reports;
  - is a no-op outside herdr.

**Manual end-to-end check in herdr with auto-title,** before release:

1. **Setup:** `herdr plugin link .`, then the `install` action, then approve the Codex hooks in `/hooks`.
2. **Claude:**
   - a fresh session's first prompt names the tab and `/resume` within a second;
   - `/rename foo` reaches the tab after the next prompt;
   - a resumed session shows its name on start.
3. **Codex:**
   - the first prompt names the tab, and Codex doesn't wait;
   - a resumed session shows the name on start.
4. **OpenCode:**
   - the first prompt gives an `fm` title in the session list and the tab;
   - `/rename foo` reaches the tab immediately.
5. **Swift fallback:** with `fm` hidden from PATH, one agent's second prompt uses the compiled Swift binary.
6. **Lifecycle:**
   - after a herdr server restart, `--sync` keeps all three working;
   - `uninstall` leaves the agents' config files as they were before `install`, apart from the backups and a Codex `[features] hooks` setting.

## Release

1. The manual end-to-end check passes, and `tests/run.sh` and `node --test` are green.
2. The README covers:
   - what it does, with a screenshot of tabs;
   - the requirements;
   - `herdr plugin install bonkey/herdr-fm-title`, then `herdr plugin action invoke bonkey.fm-title.install`;
   - the Codex `/hooks` approval;
   - what each agent gets;
   - that other plugins reporting a pane metadata title compete with this one (the latest report wins);
   - how to uninstall.
3. MIT `LICENSE`.
4. The GitHub topic `herdr-plugin`, for [herdr.dev/plugins](https://herdr.dev/plugins/).
5. The tag `v0.1.0`.

## Out of scope

- Re-titling as the conversation drifts.
- Renaming the tab directly when auto-title isn't installed.
- Model backends other than Apple's Foundation Models, and Linux.
- OpenCode V1, Pi, Gemini CLI and other agents, which are covered by the seam above.
- Pre-seeding Codex hook trust.
