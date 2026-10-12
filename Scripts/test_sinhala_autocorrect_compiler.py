#!/usr/bin/env python3
"""Regression for verified joined words being dropped by the compiler."""
import tempfile
import unittest
from pathlib import Path
from build_sinhala_autocorrect_index import verified_words


class VerifiedSpellingsTest(unittest.TestCase):
    def test_joiners_and_trust_filters(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "sinhala-spelling.tsv"
            rows = [
                ("විද්‍යාව", "accepted", "0.9", "verified"),
                ("ක්‍රියා", "accepted", "1", "verified,attested"),
                ("කර්‍මය", "accepted", "0.8", "verified"),
                ("අක්‍ෂර", "accepted", "1", "verified"),
                ("අක්‌ෂර", "accepted", "1", "verified"),
                ("ගෙදර", "accepted", "1", "verified"),
                ("සැකය", "attested", "1", "verified"),
                ("අඩු", "accepted", "0.79", "verified"),
                ("වැරදි", "accepted", "1", "attested"),
                ("\\u200d", "accepted", "1", "verified"),
                ("\u200d", "accepted", "1", "verified"),
                ("abc", "accepted", "1", "verified"),
            ]
            path.write_text("lemma\tstatus\tconfidence\ttags\n" +
                "".join("\t".join(row) + "\n" for row in rows), encoding="utf-8")
            self.assertEqual(set(verified_words(path)), {row[0] for row in rows[:6]})


if __name__ == "__main__":
    unittest.main()
