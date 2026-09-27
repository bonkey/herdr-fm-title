"""Shared by install.py, uninstall.py and status.py.

Agents run a copy of runtime/ at DATA_DIR, a stable path outside herdr's plugin checkout. Every
agent config edit is idempotent: our entries are found by MARK, others are preserved.
"""
import copy
import json
import os
import re
import shutil
import stat
import subprocess
import sys


def env(name, default=""):
    """Like ${name:-default}: an unset or empty variable gives the default."""
    return os.environ.get(name) or default


HOME = os.environ.get("HOME", "")
PLUGIN_ROOT = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
HERDR = env("HERDR_BIN_PATH", "herdr")
DATA_DIR = os.path.join(env("XDG_DATA_HOME", HOME + "/.local/share"), "herdr-fm-title")
CACHE_DIR = os.path.join(env("XDG_CACHE_HOME", HOME + "/.cache"), "herdr-fm-title")
STATE_DIR = env("HERDR_PLUGIN_STATE_DIR", os.path.join(env("XDG_STATE_HOME", HOME + "/.local/state"), "herdr-fm-title"))
AGENTS_FILE = os.path.join(STATE_DIR, "agents")
CONFIG_FILE = os.path.join(env("HERDR_PLUGIN_CONFIG_DIR", "/nonexistent"), "config.toml")
AGENT_DIRS = {
    "claude": env("CLAUDE_CONFIG_DIR", HOME + "/.claude"),
    "codex": env("CODEX_HOME", HOME + "/.codex"),
    "opencode": os.path.join(env("XDG_CONFIG_HOME", HOME + "/.config"), "opencode"),
}
SUPPORTED = ["claude", "codex", "opencode"]
MARK = "herdr-fm-title/bin/hook"
BACKUP = ".bak-herdr-fm-title"


def notify(message):
    print(message, flush=True)
    try:
        subprocess.run([HERDR, "notification", "show", "Agent session titles", "--body", message],
                       stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
    except (OSError, subprocess.SubprocessError):
        pass


def words(items):
    """" a b" for [a, b], the way the messages list agents."""
    return "".join(" " + item for item in items)


def hook_cmd(agent):
    return "sh '%s/bin/hook' %s" % (DATA_DIR, agent)


def read_text(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read()


def selected_agents():
    """Supported agents whose config directory exists, limited by `agents = [...]` in config.toml."""
    wanted = []
    try:
        for line in read_text(CONFIG_FILE).splitlines():
            m = re.match(r"\s*agents\s*=\s*\[(.*)\]", line, re.ASCII)
            if m:
                wanted += [w for w in re.split(r"[,\s]+", re.sub("[\"' ]", "", m.group(1)), flags=re.ASCII) if w]
    except OSError:
        pass
    return [a for a in SUPPORTED if os.path.isdir(AGENT_DIRS[a]) and (not wanted or a in wanted)]


def deploy_runtime():
    """Copies runtime/ into place through a temporary sibling, so a hook never sees a half-written
    runtime. Mtimes are kept, so the Swift binary is rebuilt only for a new title.swift. The
    interpreter this runs on is pinned for the runtime in <data>/python."""
    tmp, old = "%s.new.%d" % (DATA_DIR, os.getpid()), DATA_DIR + ".old"
    try:
        os.makedirs(os.path.dirname(DATA_DIR), exist_ok=True)
        for path in (tmp, old):
            shutil.rmtree(path, ignore_errors=True)
        shutil.copytree(os.path.join(PLUGIN_ROOT, "runtime"), tmp, symlinks=True,
                        ignore=shutil.ignore_patterns("__pycache__"))
        for name in os.listdir(os.path.join(tmp, "bin")):
            path = os.path.join(tmp, "bin", name)
            os.chmod(path, os.stat(path).st_mode | 0o111)
        with open(os.path.join(tmp, "python"), "w", encoding="utf-8") as f:
            f.write(env("HERDR_FM_TITLE_PYTHON", sys.executable) + "\n")
        if os.path.lexists(DATA_DIR):
            os.rename(DATA_DIR, old)
        os.rename(tmp, DATA_DIR)
        shutil.rmtree(old, ignore_errors=True)
        return True
    except OSError as e:
        print("cannot deploy the runtime: %s" % e, file=sys.stderr)
        shutil.rmtree(tmp, ignore_errors=True)
        return False


def write_atomic(path, text):
    """Replaces the file (a symlink's target) through a temporary sibling, keeping its mode."""
    target = os.path.realpath(path)
    tmp = "%s.tmp.%d" % (target, os.getpid())
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(text)
        if os.path.exists(target):
            os.chmod(tmp, stat.S_IMODE(os.stat(target).st_mode))
        os.replace(tmp, target)
    except BaseException:
        if os.path.exists(tmp):
            os.remove(tmp)
        raise


def reject_constant(name):
    raise ValueError("%s is not JSON" % name)


def load_json(path):
    return json.loads(read_text(path), parse_constant=reject_constant)


def json_update(path, change, backup=True):
    """Applies change(object) to a JSON object file. A missing file starts as {}; a file that
    doesn't hold a JSON object is left untouched. The file is written only when the object
    changed, and an existing file is backed up before its first change (unless backup=False), so
    a backup always holds the file as it was before install."""
    exists = os.path.isfile(path)
    try:
        data = load_json(path) if exists else {}
        if not isinstance(data, dict):
            raise ValueError("not a JSON object")
    except (OSError, ValueError):
        print("cannot parse %s, left unchanged" % path, file=sys.stderr)
        return False
    try:
        new = change(copy.deepcopy(data))
        if exists and new == data:
            return True
        text = json.dumps(new, indent=2, ensure_ascii=False) + "\n"
        if exists and backup and not os.path.lexists(path + BACKUP):
            shutil.copy2(path, path + BACKUP)
        write_atomic(path, text)
        return True
    except (OSError, ValueError, UnicodeError) as e:
        print("cannot update %s: %s" % (path, e), file=sys.stderr)
        return False


def items(value):
    """What jq's `.[]?` yields: an array's items or an object's values; nothing otherwise."""
    if isinstance(value, dict):
        return list(value.values())
    return value if isinstance(value, list) else []


def command_text(hook):
    command = hook.get("command") if isinstance(hook, dict) else None
    if command is None or command is False:
        return ""
    return command if isinstance(command, str) else json.dumps(command, ensure_ascii=False)


def strip(groups):
    """An event's matcher groups without ours: a group goes when any of its commands has MARK."""
    if not isinstance(groups, list):
        return groups
    return [g for g in groups
            if not any(MARK in command_text(h) for h in items(g.get("hooks") if isinstance(g, dict) else None))]


def stripped_hooks(hooks):
    """The hooks object without our entries and without empty event arrays."""
    if not isinstance(hooks, dict):
        raise ValueError("hooks is not an object")
    return {event: groups for event, groups in ((e, strip(g)) for e, g in hooks.items()) if groups != []}


def hooks_register(path, entries):
    """Removes our entries from every event, then adds one per event in entries, so entries of an
    older version for other events go too."""
    def change(data):
        hooks = data.get("hooks")
        hooks = stripped_hooks({} if hooks is None or hooks is False else hooks)
        for event, group in entries.items():
            existing = hooks.get(event)
            existing = [] if existing is None or existing is False else existing
            if not isinstance(existing, list):
                raise ValueError("hooks.%s is not an array" % event)
            hooks[event] = existing + [group]
        data["hooks"] = hooks
        return data
    return json_update(path, change)


def has_mark(path):
    try:
        with open(path, "rb") as f:
            return MARK.encode() in f.read()
    except OSError:
        return False


def hooks_unregister(path):
    """Removes our entries; drops emptied events, an emptied `hooks`, and a file this plugin
    created (it has no backup) that ends up empty."""
    if not (os.path.isfile(path) and has_mark(path)):
        return True

    def change(data):
        hooks = data.get("hooks")
        if hooks is not None and hooks is not False:
            data["hooks"] = stripped_hooks(hooks)
        if data.get("hooks") == {}:
            del data["hooks"]
        return data
    if not json_update(path, change, backup=False):
        return False
    if not os.path.lexists(path + BACKUP) and load_json(path) == {}:
        os.remove(path)
    return True


def hooks_state(path, agent):
    """connected | outdated | no"""
    if not os.path.isfile(path):
        return "no"
    try:
        data = load_json(path)
    except (OSError, ValueError):
        data = None
    commands = [h.get("command") for event in items(data.get("hooks") if isinstance(data, dict) else None)
                for group in items(event)
                for h in items(group.get("hooks") if isinstance(group, dict) else None) if isinstance(h, dict)]
    if hook_cmd(agent) in commands:
        return "connected"
    return "outdated" if has_mark(path) else "no"


def register_claude():
    cmd = hook_cmd("claude")
    return hooks_register(os.path.join(AGENT_DIRS["claude"], "settings.json"), {
        "SessionStart": {"hooks": [{"type": "command", "command": cmd}]},
        "UserPromptSubmit": {"hooks": [{"type": "command", "command": cmd, "timeout": 10}]}})


def unregister_claude():
    return hooks_unregister(os.path.join(AGENT_DIRS["claude"], "settings.json"))


def state_claude():
    return hooks_state(os.path.join(AGENT_DIRS["claude"], "settings.json"), "claude")


FEATURES_HEADER = re.compile(r"\s*\[features\]\s*(#.*)?$", re.ASCII)


def codex_features_state():
    """The value of `hooks` under [features] in Codex's config.toml, or ""."""
    try:
        lines = read_text(os.path.join(AGENT_DIRS["codex"], "config.toml")).split("\n")
    except OSError:
        return ""
    in_features = False
    for line in lines:
        if re.match(r"\s*\[", line, re.ASCII):
            in_features = bool(FEATURES_HEADER.match(line))
        if in_features and re.match(r"\s*hooks\s*=", line, re.ASCII):
            value = re.sub(r"^[^=]*=\s*", "", line, count=1, flags=re.ASCII)
            return re.sub(r"\s*(#.*)?$", "", value, count=1, flags=re.ASCII)
    return ""


def codex_enable_hooks():
    """Codex runs hooks.json only with `[features] hooks = true`. A `hooks` key already under
    [features] is left as it is."""
    path = os.path.join(AGENT_DIRS["codex"], "config.toml")
    if codex_features_state():
        return True
    try:
        if not os.path.isfile(path):
            write_atomic(path, "[features]\nhooks = true\n")
            return True
        text = read_text(path)
        if not os.path.lexists(path + BACKUP):
            shutil.copy2(path, path + BACKUP)
        lines = text.split("\n")
        if lines[-1] == "":
            lines.pop()
        if any(FEATURES_HEADER.match(line) for line in lines):
            out, done = [], False
            for line in lines:
                out.append(line + "\n")
                if not done and FEATURES_HEADER.match(line):
                    out.append("hooks = true\n")
                    done = True
            text = "".join(out)
        else:
            text += "\n[features]\nhooks = true\n"
        write_atomic(path, text)
        return True
    except OSError as e:
        print("cannot update %s: %s" % (path, e), file=sys.stderr)
        return False


def register_codex():
    cmd = hook_cmd("codex")
    return hooks_register(os.path.join(AGENT_DIRS["codex"], "hooks.json"), {
        "UserPromptSubmit": {"hooks": [{"type": "command", "command": cmd, "async": True}]}}) and codex_enable_hooks()


def unregister_codex():
    return hooks_unregister(os.path.join(AGENT_DIRS["codex"], "hooks.json"))


def state_codex():
    return hooks_state(os.path.join(AGENT_DIRS["codex"], "hooks.json"), "codex")


OPENCODE_LINK = os.path.join(AGENT_DIRS["opencode"], "plugins", "herdr-fm-title")


def register_opencode():
    tmp = "%s.tmp.%d" % (OPENCODE_LINK, os.getpid())
    try:
        os.makedirs(os.path.dirname(OPENCODE_LINK), exist_ok=True)
        if os.path.lexists(tmp):
            os.remove(tmp)
        os.symlink(os.path.join(DATA_DIR, "opencode"), tmp)
        os.replace(tmp, OPENCODE_LINK)
        return True
    except OSError as e:
        print("cannot link %s: %s" % (OPENCODE_LINK, e), file=sys.stderr)
        return False


def unregister_opencode():
    try:
        if os.path.islink(OPENCODE_LINK):
            os.remove(OPENCODE_LINK)
        return True
    except OSError:
        return False


def state_opencode():
    if os.path.islink(OPENCODE_LINK) and os.readlink(OPENCODE_LINK) == os.path.join(DATA_DIR, "opencode") \
            and os.path.isdir(OPENCODE_LINK):
        return "connected"
    return "outdated" if os.path.islink(OPENCODE_LINK) else "no"


REGISTER = {"claude": register_claude, "codex": register_codex, "opencode": register_opencode}
UNREGISTER = {"claude": unregister_claude, "codex": unregister_codex, "opencode": unregister_opencode}
STATE = {"claude": state_claude, "codex": state_codex, "opencode": state_opencode}


def newer(a, b):
    """Like `[ a -nt b ]`."""
    try:
        a_time = os.stat(a).st_mtime_ns
    except OSError:
        return False
    try:
        return a_time > os.stat(b).st_mtime_ns
    except OSError:
        return True


def backend_state():
    fm_ok = False
    if shutil.which("fm"):
        try:
            fm_ok = subprocess.run(["fm", "available"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL, timeout=5).returncode == 0
        except (OSError, subprocess.SubprocessError):
            pass
    swift_bin = os.path.join(CACHE_DIR, "bin", "title")
    if fm_ok:
        return "fm"
    if os.access(swift_bin, os.X_OK) and not newer(os.path.join(DATA_DIR, "title.swift"), swift_bin):
        return "Swift binary"
    if shutil.which("swiftc"):
        return "Swift, built on the next prompt"
    return "none: titles are off (needs the fm CLI, or Xcode Command Line Tools)"
