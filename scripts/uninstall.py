"""uninstall.py: action "uninstall". Removes exactly what install added from every supported
agent, then the deployed runtime. Config backups (*.bak-herdr-fm-title), the Swift binary cache,
session markers and a Codex `[features] hooks` setting stay.
"""
import os
import shutil
import sys

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import lib


def main():
    removed, failed = [], []
    for agent in lib.SUPPORTED:
        if lib.STATE[agent]() == "no":
            continue
        (removed if lib.UNREGISTER[agent]() else failed).append(agent)
    shutil.rmtree(lib.DATA_DIR, ignore_errors=True)
    try:
        os.remove(lib.AGENTS_FILE)
    except OSError:
        pass

    msg = "Disconnected:%s." % (lib.words(removed) or " none")
    if failed:
        msg += " Failed:%s (see the plugin log)." % lib.words(failed)
    lib.notify(msg)
    return 1 if failed else 0


sys.exit(main())
