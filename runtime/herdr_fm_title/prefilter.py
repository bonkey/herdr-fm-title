"""Turns a raw prompt into the text the model summarizes, and the ticket it refers to."""
import collections
import re
import string
from urllib.parse import parse_qsl, urlsplit

PASTED_START = re.compile(r"<pasted_content[ >]")
PASTED_END = re.compile(r"</pasted_content[ >]")
SPACE = re.compile(r"\s+", re.ASCII)
# A leading slash command keeps only its arguments; `/Users/…` is a path, not a command.
SLASH_COMMAND = re.compile(r"^/[^/ ]+(?: |$)")
MAX_CHARS = 1500

MARKDOWN_LINK = re.compile(r"\[([^\]]*)\]\((https?://[^)\s]*)\)")
URL = re.compile(r"https?://[^\s<>\"'`\[\]]+", re.ASCII)
URL_TRAILER = ").,;:!?*"
KEY = re.compile(r"[A-Z][A-Z0-9]{1,9}-[0-9]+\Z")
BARE_KEY = re.compile(r"\b[A-Z][A-Z0-9]{1,9}-[0-9]+\b", re.ASCII)
# Prefixes of names that look like ticket keys: encodings, hashes, standards, specs, models. The
# model judges the rest, and missed JSR-310.
NOT_TICKETS = frozenset("UTF UCS SHA MD CRC ISO IEC IEEE RFC CVE CWE GPT AES RSA DES ECMA ES HTTP TLS "
                        "SSL COVID WCAG PEP JSR JEP BASE X86 ARM USB WPA SQL SOC FIPS NIST".split())
GITHUB_ISSUE = re.compile(r"/[^/]+/([^/]+)/(?:issues|pull)/([0-9]+)(?:/|\Z)")

# ticket: from a URL, or None. candidates: without one, the keys in the text, for the model to judge.
Prepared = collections.namedtuple("Prepared", "text ticket candidates")


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


def is_key(word):
    return bool(KEY.match(word)) and word.split("-")[0] not in NOT_TICKETS


def url_ticket(url):
    """`repo#12` for a GitHub issue or pull request, else the first path segment or query value
    that is a ticket key (Linear, Jira, YouTrack…), else None."""
    try:
        parts = urlsplit(url)
        host = parts.hostname
    except ValueError:
        return None
    if host in ("github.com", "www.github.com"):
        m = GITHUB_ISSUE.match(parts.path)
        return "%s#%s" % m.groups() if m else None
    return next((v for v in parts.path.split("/") + [v for _, v in parse_qsl(parts.query)] if is_key(v)), None)


def prepare(raw):
    """Pasted blocks and URLs go, whitespace collapses, a slash command keeps its arguments, and
    the text is cut to 1500 characters. A markdown link keeps its text, and a URL goes with the
    punctuation around it (`url`, <url>, url:). The ticket comes from the first URL that has one;
    without one, the keys left in the text are candidates."""
    text = SPACE.sub(" ", drop_pasted(raw)).strip(" ")
    text = MARKDOWN_LINK.sub(r"\1 \2", SLASH_COMMAND.sub("", text, count=1))
    tickets, kept = [], []
    for word in text.split(" "):
        tickets += [url_ticket(url.rstrip(URL_TRAILER)) for url in URL.findall(word)]
        rest = URL.sub("", word)
        if rest.strip(string.punctuation):
            kept.append(rest)
    text = SPACE.sub(" ", " ".join(kept)).strip(" ")[:MAX_CHARS]
    ticket = next((t for t in tickets if t), None)
    candidates = [] if ticket else [k for k in dict.fromkeys(BARE_KEY.findall(text)) if is_key(k)]
    return Prepared(text, ticket, candidates)
