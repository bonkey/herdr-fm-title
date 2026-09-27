"""python3 -m unittest discover -s tests: URL and ticket tables for the pre-filter."""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "runtime"))
from herdr_fm_title import prefilter


class UrlTickets(unittest.TestCase):
    def test_tickets(self):
        for prompt, want in [
            ("see https://linear.app/acme/issue/ENG-42/probe-fails", "ENG-42"),
            ("see https://acme.atlassian.net/browse/PROJ-7.", "PROJ-7"),
            ("see https://acme.atlassian.net/jira/software/projects/PROJ/boards/1?selectedIssue=PROJ-8", "PROJ-8"),
            ("see https://youtrack.acme.com/issue/AB2-1234/Crash", "AB2-1234"),
            ("see https://github.com/bonkey/herdr-fm-title/pull/12 now", "herdr-fm-title#12"),
            ("see https://github.com/bonkey/herdr-fm-title/issues/3#issuecomment-1", "herdr-fm-title#3"),
            ("see (https://github.com/bonkey/herdr-fm-title/pull/12)", "herdr-fm-title#12"),
            ("see https://github.com/bonkey/herdr-fm-title and ENG-42", None),
            ("see https://en.wikipedia.org/wiki/SHA-256", None),
            ("see https://linear.app/acme/issue/eng-42/probe", None),
            ("see https://example.com/docs, then https://linear.app/a/issue/ENG-1/x and "
             "https://linear.app/a/issue/ENG-2/y", "ENG-1"),
            ("see github.com/bonkey/herdr-fm-title/pull/12", None),
        ]:
            with self.subTest(prompt=prompt):
                self.assertEqual(prefilter.prepare(prompt).ticket, want)

    def test_urls_are_removed(self):
        for prompt, want in [
            ("fix the crash, see https://linear.app/acme/issue/ENG-42/probe-fails.", "fix the crash, see ."),
            ("the [login doc](https://acme.dev/login) is wrong", "the [login doc] is wrong"),
            ("read <https://acme.dev/a?b=c> and http://x.y/z too", "read and too"),
            ("/review https://github.com/bonkey/herdr-fm-title/pull/12", ""),
        ]:
            with self.subTest(prompt=prompt):
                self.assertEqual(prefilter.prepare(prompt).text, want)


if __name__ == "__main__":
    unittest.main()
