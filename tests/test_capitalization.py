#!/usr/bin/env python3
"""Regression tests for sentence-initial capitalization in AnkiMorphs spans."""
from __future__ import annotations

import importlib.util
import sqlite3
import tempfile
import unittest
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1] / "ankimorphs" / "backend.py"
spec = importlib.util.spec_from_file_location("ankimorphs_backend", BACKEND)
assert spec and spec.loader
backend = importlib.util.module_from_spec(spec)
spec.loader.exec_module(backend)


class Token:
    def __init__(self, text: str, lemma: str, pos: str):
        self.text = text
        self.lemma_ = lemma
        self.pos_ = pos


class FakeNLP:
    lang = "en"

    def __call__(self, _text: str):
        # Some spaCy pipelines return a capitalized lemma for a sentence-initial
        # token. The AnkiMorphs database may contain the same morph in lowercase.
        return [Token("Was", "Was", "PRON")]


class CapitalizationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.db_path = Path(self.temp.name) / "ankimorphs.db"
        with sqlite3.connect(self.db_path) as db:
            db.execute(
                "CREATE TABLE Morphs (lemma TEXT, inflection TEXT, "
                "highest_lemma_learning_interval INTEGER, "
                "highest_inflection_learning_interval INTEGER, "
                "PRIMARY KEY (lemma, inflection))"
            )
            db.execute("INSERT INTO Morphs VALUES (?, ?, ?, ?)", ("was", "was", 50, 50))

        self.engine = object.__new__(backend.AnkiMorphsEngine)
        self.engine.db_path = self.db_path
        self.engine.config = dict(backend.DEFAULTS)
        self.engine.names = set()
        fake_nlp = FakeNLP()
        self.engine._get_nlp = lambda _model: fake_nlp

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_sentence_initial_capitalization_reuses_casefolded_lemma_and_inflection(self) -> None:
        result = self.engine._analyze_uncached("Was", "fake-model")
        self.assertEqual(result["segments"], [
            {"text": "Was", "status": "known", "lemma": "Was"}
        ])

    def test_unknown_morph_remains_unknown_without_casefold_match(self) -> None:
        with sqlite3.connect(self.db_path) as db:
            db.execute("DELETE FROM Morphs")
        result = self.engine._analyze_uncached("Was", "fake-model")
        self.assertEqual(result["segments"][0]["status"], "unknown")

    def test_casefolded_lemma_is_used_only_after_exact_lookup_misses(self) -> None:
        intervals = self.engine._intervals_for([("Was", "Was")])
        self.assertEqual(intervals[("Was", "Was")], 50)

    def test_exact_inflection_match_is_preferred(self) -> None:
        with sqlite3.connect(self.db_path) as db:
            db.execute("INSERT INTO Morphs VALUES (?, ?, ?, ?)", ("was", "Was", 1, 1))
        intervals = self.engine._intervals_for([("was", "Was")])
        self.assertEqual(intervals[("was", "Was")], 1)

    def test_exact_lemma_and_inflection_are_preferred_over_casefolded_rows(self) -> None:
        with sqlite3.connect(self.db_path) as db:
            db.execute("INSERT INTO Morphs VALUES (?, ?, ?, ?)", ("Was", "Was", 1, 1))
        intervals = self.engine._intervals_for([("Was", "Was")])
        self.assertEqual(intervals[("Was", "Was")], 1)

    def test_lemma_only_evaluation_has_casefolded_fallback(self) -> None:
        self.engine.config["evaluate_morph_inflection"] = False
        intervals = self.engine._intervals_for([("WAS", "WAS")])
        self.assertEqual(intervals[("WAS", "WAS")], 50)

    def test_casefold_fallback_handles_german_umlauts(self) -> None:
        with sqlite3.connect(self.db_path) as db:
            db.execute("DELETE FROM Morphs")
            db.execute("INSERT INTO Morphs VALUES (?, ?, ?, ?)", ("ärger", "ärger", 33, 33))
        intervals = self.engine._intervals_for([("Ärger", "Ärger")])
        self.assertEqual(intervals[("Ärger", "Ärger")], 33)


if __name__ == "__main__":
    unittest.main()
