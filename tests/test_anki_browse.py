#!/usr/bin/env python3
"""Tests for the AnkiConnect / AnkiMorphs Browser action example."""
from __future__ import annotations

import importlib.util
import json
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "ankimorphs-dict" / "anki_browse.py"
spec = importlib.util.spec_from_file_location("anki_browse", SCRIPT)
assert spec and spec.loader
anki_browse = importlib.util.module_from_spec(spec)
spec.loader.exec_module(anki_browse)


class FakeResponse:
    def __init__(self, value):
        self.value = json.dumps(value).encode()

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False

    def read(self):
        return self.value


class AnkiBrowseTests(unittest.TestCase):
    def test_builds_deck_scoped_ankimorphs_and_phrase_query(self):
        query = anki_browse.build_query(
            "German::Vocabulary", "Was", "Was ist das?"
        )
        self.assertEqual(
            query,
            'deck:"German::Vocabulary" "am-study-morphs:Was" "Was ist das?"',
        )

    def test_literal_query_metacharacters_are_escaped(self):
        query = anki_browse.build_query(
            "German", 'foo_bar*"', 'Find 3:30 & <time>\\"now"'
        )
        self.assertIn('"am-study-morphs:foo\\_bar\\*\\\""', query)
        self.assertIn('3\\:30 &amp; &lt;time&gt;\\\\\\\"now\\\"', query)

    def test_gui_browse_uses_expected_ankiconnect_payload(self):
        captured = {}

        def fake_urlopen(request, timeout):
            captured["url"] = request.full_url
            captured["timeout"] = timeout
            captured["payload"] = json.loads(request.data.decode())
            return FakeResponse({"result": [101, 202], "error": None})

        with patch.object(anki_browse, "urlopen", fake_urlopen):
            result = anki_browse.invoke_gui_browse(
                'deck:"deutsch" "am-study-morphs:Was" "Was ist das?"',
                endpoint="http://127.0.0.1:8765",
                api_key="secret",
            )

        self.assertEqual(result, [101, 202])
        self.assertEqual(captured["url"], "http://127.0.0.1:8765")
        self.assertEqual(captured["timeout"], 4)
        self.assertEqual(captured["payload"]["action"], "guiBrowse")
        self.assertEqual(captured["payload"]["version"], 6)
        self.assertEqual(captured["payload"]["key"], "secret")
        self.assertIn("am-study-morphs:Was", captured["payload"]["params"]["query"])


if __name__ == "__main__":
    unittest.main()
