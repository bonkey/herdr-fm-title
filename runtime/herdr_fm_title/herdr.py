"""herdr-title <agent> <title>: sets the herdr pane metadata title, which auto-title shows as the
tab label. `--agent` keeps the title only while that agent runs in the pane. Outside herdr it does
nothing, and it never fails the caller.

herdr drops a guarded report until it has recognized the agent in the pane, which happens a few
seconds after the agent starts, so a SessionStart hook is too early. Then a detached copy
(--wait) reports once herdr shows the agent, for up to 15 s, and no hook is held up.
"""
import json
import os
import subprocess
import time

from . import common

SOURCE = "plugin:bonkey.fm-title"
BIN = os.path.join(os.path.dirname(os.path.dirname(os.path.realpath(__file__))), "bin", "herdr-title")


def pane():
    """The pane id inside herdr, else None."""
    if os.environ.get("HERDR_ENV") == "1" and common.env("HERDR_PANE_ID"):
        return os.environ["HERDR_PANE_ID"]
    return None


def herdr(*args, timeout):
    try:
        return subprocess.run([common.env("HERDR_BIN_PATH", "herdr"), *args], stdin=subprocess.DEVNULL,
                              stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=timeout).stdout
    except (OSError, subprocess.SubprocessError):
        return b""


def agent_in_pane(pane_id):
    try:
        agent = json.loads(herdr("pane", "get", pane_id, timeout=2))["result"]["pane"]["agent"]
    except (ValueError, TypeError, KeyError):
        return ""
    return agent if isinstance(agent, str) else ""


def report(pane_id, agent, title):
    herdr("pane", "report-metadata", pane_id, "--source", SOURCE, "--agent", agent, "--title", title, timeout=5)


def set_title(agent, title):
    pane_id = pane()
    if not (pane_id and agent and title):
        return
    if agent_in_pane(pane_id) == agent:
        report(pane_id, agent, title)
        return
    try:
        common.detach([BIN, "--wait", agent, title])
    except OSError:
        pass


def wait_and_report(agent, title):
    pane_id = pane()
    if not (pane_id and agent and title):
        return
    for _ in range(30):
        if agent_in_pane(pane_id) == agent:
            break
        time.sleep(0.5)
    report(pane_id, agent, title)


def main(args):
    wait = args[:1] == ["--wait"]
    agent, title = ((args[1:] if wait else args) + ["", ""])[:2]
    (wait_and_report if wait else set_title)(agent, title)
    return 0
