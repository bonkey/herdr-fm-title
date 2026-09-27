"""install.py [--sync]: action "install". Deploys the runtime and connects every supported agent
whose config directory exists (limited by `agents = [...]` in config.toml when set).

--sync is the startup hook: it redeploys and refreshes only the agents already connected, so it
never connects an agent on its own and stays quiet (output goes to the plugin log).
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import lib


def main(args):
    sync = args[:1] == ["--sync"]
    if sync:
        try:
            agents = lib.read_text(lib.AGENTS_FILE).split()
        except OSError:
            agents = []
        if not agents:
            return 0
    else:
        agents = lib.selected_agents()
        if not agents:
            lib.notify("No supported agent found (Claude Code, Codex, OpenCode).")
            return 0

    if not lib.deploy_runtime():
        lib.notify("Could not deploy the runtime to %s." % lib.DATA_DIR)
        return 1

    connected, failed = [], []
    for agent in agents:
        register = lib.REGISTER.get(agent)
        (connected if register and register() else failed).append(agent)

    if sync:
        print("synced:%s%s" % (lib.words(connected) or " none", "; failed:" + lib.words(failed) if failed else ""))
        return 0

    os.makedirs(lib.STATE_DIR, exist_ok=True)
    with open(lib.AGENTS_FILE, "w", encoding="utf-8") as f:
        f.write("\n".join(connected) + "\n")
    msg = "Connected:%s." % (lib.words(connected) or " none")
    if failed:
        msg += " Failed:%s (see the plugin log)." % lib.words(failed)
    if "codex" in connected:
        msg += " Approve the new hooks once in Codex with /hooks."
    if "claude" in connected or "codex" in connected:
        msg += " New sessions pick it up; running ones keep their hooks."
    lib.notify("%s Model: %s." % (msg, lib.backend_state()))
    return 1 if failed else 0


sys.exit(main(sys.argv[1:]))
