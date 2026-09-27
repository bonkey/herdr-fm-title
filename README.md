# herdr-fm-title

[Herdr](https://herdr.dev) plugin: every coding-agent session gets a short, readable name from its
first prompt, written on-device by Apple's Foundation Models. The name becomes the tab label and,
where the agent supports it, the agent's own session name.

    before:  need some ideation of a plugin for herdr. when I s
    after:   Herdr Plugin Tab Name

| Agent | Tab title | Agent's own session name | Rename reaches the tab |
|---|---|---|---|
| Claude Code ≥ 2.1.283 | yes | yes (`/resume`, prompt border) | `/rename`, on the next prompt |
| OpenCode V2 ≥ 2.0.8 | yes | yes (replaces its title model) | `/rename`, immediately |
| Codex ≥ 0.157 | yes | no, Codex keeps its own title | no |

The prompt never leaves the machine. Prompts under 3 words wait for the next one.

## Requirements

- macOS with Apple Intelligence enabled, and one of:
  - the `fm` CLI (macOS 27+); accept its terms once with `sudo fm license`;
  - Xcode Command Line Tools (macOS 26+): a small Swift fallback is compiled in the background
    the first time it is needed.
- herdr ≥ 0.9.1 and Python ≥ 3.9, which the Xcode Command Line Tools provide.
- [herdr-auto-title](https://github.com/kryptamine/herdr-auto-title) for the tab label. herdr
  itself labels tabs by position; without auto-title the name shows only where herdr shows pane
  titles, such as the navigator.

## Install

    herdr plugin install bonkey/herdr-fm-title
    herdr plugin action invoke bonkey.fm-title.install

The `install` action connects every supported agent whose config directory exists. New sessions
pick it up; running ones keep their current hooks. **Codex** asks you once to approve the new
hook: open Codex and run `/hooks`.

What `install` changes, each file backed up once as `<file>.bak-herdr-fm-title`:

- Claude Code: two hook entries in `~/.claude/settings.json` (`CLAUDE_CONFIG_DIR` honoured).
- Codex: one hook entry in `~/.codex/hooks.json`, and `[features] hooks = true` in
  `config.toml` when it has no `hooks` setting (`CODEX_HOME` honoured).
- OpenCode: a symlink `~/.config/opencode/plugins/herdr-fm-title`.

The agents run a copy of the plugin's runtime in `~/.local/share/herdr-fm-title`, refreshed on
every herdr server start for the agents already connected.

To connect only some agents, put this in `$(herdr plugin config-dir bonkey.fm-title)/config.toml`
and run `install` again:

    agents = ["claude", "opencode"]

## Actions

- `bonkey.fm-title.install` — connect agents (again, e.g. after changing `agents`).
- `bonkey.fm-title.status` — each agent's connection and the model backend.
- `bonkey.fm-title.uninstall` — remove exactly what `install` added, and the runtime copy.

## Notes

- Another plugin that also reports a pane metadata title competes with this one; the latest
  report wins, so keep only one of them.
- A session named with `claude --name`, `/rename` or a resumed name is never renamed.
- Failures are logged to `~/.local/state/herdr-fm-title/runtime.log`.

## Uninstall

    herdr plugin action invoke bonkey.fm-title.uninstall
    herdr plugin uninstall bonkey.fm-title

## Development

    git clone https://github.com/bonkey/herdr-fm-title
    herdr plugin link "$PWD/herdr-fm-title"
    sh tests/run.sh && node --test tests/    # the tests need jq

The design is in [docs/superpowers/specs](docs/superpowers/specs/).

## License

MIT
