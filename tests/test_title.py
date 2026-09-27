"""python3 -m unittest discover -s tests: tables for the runtime's pure functions."""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "runtime"))
from herdr_fm_title import title


class Slugify(unittest.TestCase):
    def test_slugs(self):
        for given, want in [
            ("Login Crash Fix", "login-crash-fix"),
            ("Add Captions to Video", "add-captions-video"),
            ("Session Duration Cost Display", "session-duration-cost"),
            ("Zażółć Gęślą Jaźń", "zazolc-gesla-jazn"),
            ("Straße Øresund Þing", "strasse-oresund-thing"),
            ("Don’t Crash UTF-8 Parser", "dont-crash-utf-8"),
            ("spec.md Updated", "spec-md-updated"),
            ("Supercalifragilistic Internationalizatio", "supercalifragilistic"),
            ("Supercalifragilisticexpialidocious Fix", "supercalifragilisticexpi"),
            ("For The", ""),
        ]:
            with self.subTest(given=given):
                self.assertEqual(title.slugify(given), want)


if __name__ == "__main__":
    unittest.main()
