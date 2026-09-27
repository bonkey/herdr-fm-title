"""hook <claude|codex>: agent hook entry point; the hook JSON arrives on stdin.

A marker file per session (<agent>-<session_id>, holding the title) means the session is named: no
title is ever generated for it again, which is what keeps a user's own name safe.
Claude: the first real prompt names the session (sessionTitle) and the tab; later prompts carry a
        /rename to the tab through Claude's custom-title.json sidecar.
Codex:  runs async and must print nothing (stdout would reach the model); tab only. Every prompt
        of a named session re-reports its title, which also covers a resumed session.
"""
import json
import os
import re
import sys
import time

from . import common, herdr, title

SESSION_ID = re.compile(r"[A-Za-z0-9_-]+\Z")
DAY = 86400


def strings(data):
    """The object's string fields, without trailing newlines."""
    if not isinstance(data, dict):
        return {}
    return {k: v.rstrip("\n") for k, v in data.items() if isinstance(v, str)}


def parse(raw):
    try:
        return json.loads(raw.decode("utf-8", "replace"))
    except ValueError:
        return None


def read_json(path):
    try:
        with open(path, "rb") as f:
            return parse(f.read())
    except OSError:
        return None


def prune(named):
    """Deletes markers 31 or more days old, at most once a day."""
    stamp = os.path.join(named, ".pruned")
    try:
        if time.time() - os.stat(stamp).st_mtime < DAY:
            return
    except OSError:
        pass
    now = time.time()
    for entry in os.scandir(named):
        try:
            if entry.is_file() and entry.name != ".pruned" and now - entry.stat().st_mtime >= 31 * DAY:
                os.remove(entry.path)
        except OSError:
            pass
    try:
        open(stamp, "w").close()
    except OSError:
        pass


def main(args):
    agent = args[0] if args else ""
    fields = strings(parse(sys.stdin.buffer.read()))
    event, sid = fields.get("hook_event_name", ""), fields.get("session_id", "")
    if not SESSION_ID.match(sid):
        return 0
    named = os.path.join(common.state_dir(), "named")
    try:
        os.makedirs(named, exist_ok=True)
    except OSError:
        return 0
    marker = os.path.join(named, "%s-%s" % (agent, sid))
    prune(named)

    def name(new_title):
        try:
            with open(marker, "w", encoding="utf-8") as f:
                f.write(new_title + "\n")
        except OSError:
            pass
        herdr.set_title(agent, new_title)

    if (agent, event) == ("claude", "SessionStart"):
        if fields.get("session_title"):
            name(fields["session_title"])
    elif (agent, event) == ("claude", "UserPromptSubmit"):
        transcript = fields.get("transcript_path", "")
        current = ""
        if transcript:
            sidecar = transcript[:-len(".jsonl")] if transcript.endswith(".jsonl") else transcript
            current = strings(read_json(os.path.join(sidecar, "custom-title.json"))).get("customTitle", "")
        if os.path.isfile(marker) or current:
            if current:
                name(current)
            return 0
        new_title = title.title_for(fields.get("prompt", ""))
        if new_title:
            name(new_title)
            out = {"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "sessionTitle": new_title}}
            sys.stdout.buffer.write((json.dumps(out, ensure_ascii=False, separators=(",", ":")) + "\n").encode())
    elif (agent, event) == ("codex", "UserPromptSubmit"):
        # Codex fires SessionStart for a resumed session only with its first new prompt, so the
        # prompt hook alone brings a stored title back.
        if os.path.isfile(marker):
            with open(marker, encoding="utf-8", errors="replace") as f:
                herdr.set_title("codex", f.read().rstrip("\n"))
            return 0
        new_title = title.title_for(fields.get("prompt", ""))
        if new_title:
            name(new_title)
    return 0
