"""status.py: action "status". Each agent's connection, the Python the runtime runs on, and the
model backend."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import lib

STATES = {"connected": "connected", "outdated": "connected to an old runtime path, run install"}


def main():
    line = ""
    for agent in lib.SUPPORTED:
        if not os.path.isdir(lib.AGENT_DIRS[agent]):
            state = "not installed"
        else:
            state = STATES.get(lib.STATE[agent](), "not connected")
            if agent == "codex" and state == "connected" and lib.codex_features_state() != "true":
                state += ", but hooks are off in config.toml [features]"
        line += "%s: %s; " % (agent, state)
    lib.notify("%spython: %s; model: %s" % (line, lib.env("HERDR_FM_TITLE_PYTHON", sys.executable), lib.backend_state()))
    return 0


sys.exit(main())
