"""Turns a raw prompt into the text the model summarizes."""
import re

PASTED_START = re.compile(r"<pasted_content[ >]")
PASTED_END = re.compile(r"</pasted_content[ >]")
SPACE = re.compile(r"\s+", re.ASCII)
# A leading slash command keeps only its arguments; `/Users/…` is a path, not a command.
SLASH_COMMAND = re.compile(r"^/[^/ ]+(?: |$)")
MAX_CHARS = 1500


def drop_pasted(text):
    """Removes pasted blocks, which run from a `<pasted_content …>` line to a
    `</pasted_content …>` line."""
    kept, skip = [], False
    for line in text.split("\n"):
        if PASTED_START.match(line):
            skip = True
        elif PASTED_END.match(line):
            skip = False
        elif not skip:
            kept.append(line)
    return "\n".join(kept)


def prepare(raw):
    text = SPACE.sub(" ", drop_pasted(raw)).strip(" ")
    return SLASH_COMMAND.sub("", text, count=1)[:MAX_CHARS]
