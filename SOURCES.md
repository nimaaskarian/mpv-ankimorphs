# Upstream references

Implementation behavior was checked against these files in `mortii/anki-morphs`:

- `ankimorphs/highlighting/highlight_just_in_time.py` — JIT highlighting path and database interval lookup.
- `ankimorphs/highlighting/text_highlighter.py` — longest-first, non-overlapping text spans.
- `ankimorphs/morpheme.py` — unknown / learning / known status thresholds.
- `ankimorphs/morphemizers/spacy_morphemizer.py` — spaCy token filtering and lemma/inflection extraction.
- `ankimorphs/morphemizers/spacy_wrapper.py` — language-specific pipeline configuration.
- `ankimorphs/text_preprocessing.py` and `ankimorphs/name_file_utils.py` — AnkiMorphs preprocessing and profile names file.
- `ankimorphs/ankimorphs_db.py` — `Morphs` schema and exact interval queries.
- `ankimorphs/config.json` and `ankimorphs/ankimorphs_config.py` — defaults and profile settings.

Repository: https://github.com/mortii/anki-morphs


Capitalization behavior was traced against:

- `ankimorphs/highlighting/highlight_just_in_time.py` — exact `Morpheme` interval lookup in the JIT path.
- `ankimorphs/highlighting/text_highlighter.py` — expression lowercasing and inflection-based span matching.
- `ankimorphs/morpheme.py` — status classification.

The companion dictionary uses mpv's Lua `mp.observe_property`, `mp.add_key_binding`, and asynchronous subprocess APIs, plus the system `dict` client.

The AnkiConnect Browser-search example was checked against:

- AnkiMorphs user guide, Reviewing Cards / Right-Clicking Highlighted Text — documents the `"am-study-morphs:{highlighted_text}"` Browser search.
- AnkiConnect API, Graphical Actions / `guiBrowse` — opens the Anki Browser with a supplied search query.
- Anki Manual, Searching — documents exact quoted phrase searches, deck scoping, and literal-character escaping.

References:
- https://mortii.github.io/anki-morphs/user_guide/usage/reviewing-cards.html
- https://github.com/ankiultimate/anki-connect#graphical-actions
- https://docs.ankiweb.net/searching.html
