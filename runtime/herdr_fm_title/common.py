"""Environment, paths, the runtime log and detached processes, shared by the runtime commands."""
import os
import subprocess
import time

NAME = "herdr-fm-title"


def env(name, default=""):
    """Like ${name:-default}: an unset or empty variable gives the default."""
    return os.environ.get(name) or default


def home():
    return os.environ.get("HOME", "")


def cache_dir():
    return os.path.join(env("XDG_CACHE_HOME", home() + "/.cache"), NAME)


def state_dir():
    return os.path.join(env("XDG_STATE_HOME", home() + "/.local/state"), NAME)


def log(source, message):
    """Appends one line to runtime.log, which keeps its last 50 KB once it passes 100 KB."""
    try:
        os.makedirs(state_dir(), exist_ok=True)
        path = os.path.join(state_dir(), "runtime.log")
        with open(path, "a", encoding="utf-8") as f:
            f.write("%s %s: %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%S"), source, message))
        if os.path.getsize(path) > 102400:
            with open(path, "rb") as f:
                f.seek(-51200, os.SEEK_END)
                tail = f.read()
            with open(path + ".tmp", "wb") as f:
                f.write(tail)
            os.replace(path + ".tmp", path)
    except OSError:
        pass


def detach(args):
    """Starts args in a session of its own with no stdio, so no hook or agent waits for it."""
    subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL, start_new_session=True)
