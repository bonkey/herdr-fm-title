"""Entry point of the bin/ trampolines: main.py <command> [args…].

A command returns its exit code. Any failure ends with the command's no-op code instead, and
never with Python's exit 2, which Claude reads as "block this prompt".
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))

NOOP = {"fm-title": 1}


def run(argv):
    command = argv[1] if len(argv) > 1 else ""
    try:
        if command == "fm-title":
            from herdr_fm_title import title
            return title.main(argv[2:])
    except BaseException as e:
        try:
            from herdr_fm_title import common
            common.log(command, "failed: %r" % e)
        except BaseException:
            pass
    return NOOP.get(command, 0)


if __name__ == "__main__":
    sys.exit(run(sys.argv))
