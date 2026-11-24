#!/usr/bin/env python3
"""Persistent spaCy/SQLite backend for the mpv AnkiMorphs highlighter.

The Lua front-end starts this process detached and sends one JSON request per
subtitle event through a private Unix-domain socket.  This keeps spaCy loaded
between subtitle lines without blocking mpv's event loop.
"""
from __future__ import annotations

import argparse
import hashlib
import html
import json
import os
import sqlite3
import stat
import re
import socket
import sys
import time
import traceback
import threading
import queue
from collections import OrderedDict
from html.parser import HTMLParser
from pathlib import Path
from typing import Any

DEFAULTS: dict[str, Any] = {
    "evaluate_morph_inflection": True,
    "interval_for_known_morphs": 21,
    "preprocess_ignore_bracket_contents": False,
    "preprocess_ignore_round_bracket_contents": False,
    "preprocess_ignore_slim_round_bracket_contents": False,
    "preprocess_ignore_names_morphemizer": False,
    "preprocess_ignore_names_textfile": False,
    "preprocess_ignore_numbers": False,
    "preprocess_ignore_custom_characters": False,
    "preprocess_custom_characters_to_ignore": "",
}

# Kept in step with AnkiMorphs' spacy_wrapper.LANGUAGE_PIPE_CONFIGS.
LANGUAGE_PIPE_CONFIGS: dict[str, set[str]] = {
    "ca": {"tok2vec", "morphologizer", "lemmatizer"},
    "zh": {"tok2vec", "tagger", "attribute_ruler"},
    "hr": {"tok2vec", "lemmatizer", "morphologizer"},
    "da": {"tok2vec", "morphologizer", "lemmatizer"},
    "nl": {"tok2vec", "lemmatizer", "morphologizer"},
    "en": {"tok2vec", "tagger", "attribute_ruler", "lemmatizer", "morphologizer"},
    "fi": {"tok2vec", "lemmatizer", "morphologizer"},
    "fr": {"tok2vec", "lemmatizer", "morphologizer"},
    "de": {"tok2vec", "lemmatizer", "morphologizer"},
    "el": {"tok2vec", "lemmatizer", "morphologizer"},
    "it": {"tok2vec", "lemmatizer", "morphologizer"},
    "ja": {""},
    "ko": {"tok2vec", "morphologizer", "lemmatizer"},
    "lt": {"tok2vec", "lemmatizer", "morphologizer"},
    "mk": {"tok2vec", "lemmatizer", "morphologizer"},
    "nb": {"tok2vec", "attribute_ruler", "lemmatizer", "morphologizer", "ner"},
    "pl": {"tok2vec", "lemmatizer", "morphologizer"},
    "pt": {"tok2vec", "lemmatizer", "morphologizer"},
    "ro": {"tok2vec", "tagger", "morphologizer", "lemmatizer", "attribute_ruler"},
    "ru": {"tok2vec", "morphologizer", "lemmatizer"},
    "sl": {"tok2vec", "lemmatizer", "morphologizer"},
    "es": {"tok2vec", "lemmatizer", "morphologizer"},
    "sv": {"tok2vec", "lemmatizer", "morphologizer"},
    "uk": {"tok2vec", "morphologizer", "lemmatizer"},
}

EXCLUDED_POS = {"X", "SPACE", "SYM", "PUNCT"}
PUNCTUATION_ONLY = re.compile(r"^[\W_]+$", re.UNICODE)
REGISTERED_CUSTOM_COMPONENTS: set[str] = set()
BRACKET_CONTENTS = re.compile(r"\[[^]]*]")
ROUND_BRACKET_CONTENTS = re.compile(r"（[^）]*）")
SLIM_ROUND_BRACKET_CONTENTS = re.compile(r"\([^)]*\)")


class PlainTextExtractor(HTMLParser):
    """Small equivalent of the HTML-stripping step used by Anki's field filter."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.parts: list[str] = []

    def handle_data(self, data: str) -> None:
        self.parts.append(data)

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag.lower() in {"br", "p", "div", "li"}:
            self.parts.append("\n")

    def handle_endtag(self, tag: str) -> None:
        if tag.lower() in {"p", "div", "li"}:
            self.parts.append("\n")


def strip_html(value: str) -> str:
    parser = PlainTextExtractor()
    try:
        parser.feed(value)
        parser.close()
        return "".join(parser.parts)
    except Exception:
        # Subtitles are normally already stripped by mpv; this is a defensive fallback.
        return re.sub(r"<[^>]*>", "", html.unescape(value))


class AnkiMorphsEngine:
    def __init__(self, profile_dir: Path, db_path: Path, priority_dir: Path, names_path: Path, cache_dir: Path | None = None):
        self.profile_dir = profile_dir
        self.db_path = db_path
        self.priority_dir = priority_dir
        self.names_path = names_path
        # Stable per-user location on tmpfs. This survives mpv restarts but is
        # automatically cleared when /tmp is cleaned or the machine reboots.
        self.cache_dir = cache_dir or (Path("/tmp") / f"mpv-ankimorphs-{os.getuid()}")
        self._disk_cache: sqlite3.Connection | None = None
        self._disk_cache_lock = threading.RLock()
        self._disk_cache_namespace = ""
        self._disk_cache_writes = 0
        self._disk_cache_hits = 0
        self._disk_cache_entries = 0
        self.config = dict(DEFAULTS)
        self.names: set[str] = set()
        self._nlp: Any = None
        self._model_name: str | None = None
        self._spacy: Any = None
        self._installed_models: list[str] = []
        self._analysis_lock = threading.RLock()
        self._cache_lock = threading.RLock()
        self._result_cache: OrderedDict[tuple[str, str], dict[str, Any]] = OrderedDict()
        self._cache_limit = 12000
        self._prefetch_queue: queue.Queue[tuple[int, str, str, str]] = queue.Queue()
        self._prefetch_lock = threading.RLock()
        self._prefetch_job_id = 0
        self._prefetch_job: dict[str, Any] | None = None
        self._prefetch_thread: threading.Thread | None = None
        self._prefetch_stop = threading.Event()
        self._foreground_waiting = threading.Event()
        self._load_profile_config()
        self._load_names()
        self._load_spacy()
        self._init_disk_cache()

    def _load_profile_config(self) -> None:
        config_path = self.profile_dir / "ankimorphs_profile_settings.json"
        try:
            with config_path.open("r", encoding="utf-8") as handle:
                saved = json.load(handle)
            if isinstance(saved, dict):
                for key in DEFAULTS:
                    if key in saved:
                        self.config[key] = saved[key]
        except FileNotFoundError:
            pass
        except (OSError, json.JSONDecodeError) as exc:
            self.log(f"Could not read {config_path}: {exc}")

    def _load_names(self) -> None:
        try:
            with self.names_path.open("r", encoding="utf-8") as handle:
                self.names = {line.strip().lower() for line in handle if line.strip()}
        except FileNotFoundError:
            self.names = set()
        except OSError as exc:
            self.log(f"Could not read names file {self.names_path}: {exc}")

    def _load_spacy(self) -> None:
        try:
            import spacy  # type: ignore[import-not-found]

            self._spacy = spacy
            self._installed_models = sorted(spacy.util.get_installed_models())
        except Exception as exc:
            raise RuntimeError(
                "Could not import spaCy from the configured AnkiMorphs virtualenv. "
                "Check the venv path and its Python version."
            ) from exc

    def log(self, message: str) -> None:
        print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {message}", file=sys.stderr, flush=True)

    def models(self) -> list[str]:
        assert self._spacy is not None
        # Refresh in case the user installed another model while mpv was running.
        self._installed_models = sorted(self._spacy.util.get_installed_models())
        return self._installed_models

    def priority_files(self) -> list[str]:
        try:
            return sorted(p.name for p in self.priority_dir.iterdir() if p.is_file() and p.suffix.lower() == ".csv")
        except FileNotFoundError:
            return []

    def _get_nlp(self, model_name: str) -> Any:
        if self._model_name == model_name and self._nlp is not None:
            return self._nlp
        if model_name not in self.models():
            raise ValueError(
                f"spaCy model '{model_name}' is not installed in the selected virtualenv. "
                "Choose one of the models reported by the backend."
            )

        assert self._spacy is not None
        nlp = self._spacy.load(model_name)
        allowed_pipes = LANGUAGE_PIPE_CONFIGS.get(nlp.lang, set())
        for pipe in list(nlp.component_names):
            if pipe not in allowed_pipes:
                nlp.disable_pipe(pipe)

        # Keep the same special lemma handling as AnkiMorphs for Chinese and Korean.
        if nlp.lang == "zh":
            if "lemma_adder_chinese" not in REGISTERED_CUSTOM_COMPONENTS:
                @self._spacy.language.Language.component("lemma_adder_chinese")
                def lemma_adder_chinese(doc: Any) -> Any:
                    for token in doc:
                        token.lemma_ = token.text
                    return doc
                REGISTERED_CUSTOM_COMPONENTS.add("lemma_adder_chinese")
            if "lemma_adder_chinese" not in nlp.pipe_names:
                nlp.add_pipe("lemma_adder_chinese", last=True)
        elif nlp.lang == "ko":
            if "lemma_stripper_korean" not in REGISTERED_CUSTOM_COMPONENTS:
                @self._spacy.language.Language.component("lemma_stripper_korean")
                def lemma_stripper_korean(doc: Any) -> Any:
                    for token in doc:
                        stem = token.lemma_.find("+")
                        if stem != -1:
                            token.lemma_ = token.lemma_[:stem]
                    return doc
                REGISTERED_CUSTOM_COMPONENTS.add("lemma_stripper_korean")
            if "lemma_stripper_korean" not in nlp.pipe_names:
                nlp.add_pipe("lemma_stripper_korean", last=True)

        self._nlp = nlp
        self._model_name = model_name
        self.log(f"Loaded spaCy model {model_name} ({nlp.lang})")
        return nlp

    def _preprocess_for_morphology(self, text: str) -> str:
        value = text
        if self.config["preprocess_ignore_bracket_contents"]:
            value = BRACKET_CONTENTS.sub("", value)
        if self.config["preprocess_ignore_round_bracket_contents"]:
            value = ROUND_BRACKET_CONTENTS.sub("", value)
        if self.config["preprocess_ignore_slim_round_bracket_contents"]:
            value = SLIM_ROUND_BRACKET_CONTENTS.sub("", value)
        if self.config["preprocess_ignore_numbers"]:
            value = re.sub(r"\d", "", value)
        if self.config["preprocess_ignore_custom_characters"]:
            value = value.translate(str.maketrans("", "", str(self.config["preprocess_custom_characters_to_ignore"])))
        return value

    def _intervals_for(self, morphs: list[tuple[str, str]]) -> dict[tuple[str, str], int]:
        """Read the exact Morphs-table interval fields used by am-highlight."""
        if not self.db_path.is_file():
            raise FileNotFoundError(f"AnkiMorphs database not found: {self.db_path}")
        uri = self.db_path.resolve().as_uri() + "?mode=ro"
        import sqlite3

        connection = sqlite3.connect(uri, uri=True, timeout=2.0)
        try:
            found: dict[tuple[str, str], int] = {}
            evaluate_inflection = bool(self.config["evaluate_morph_inflection"])
            # Cache each lemma's rows only when an exact-case inflection lookup
            # misses. This preserves AnkiMorphs' exact match semantics first,
            # while allowing sentence-initial capitalization ("Was" vs "was")
            # to reuse the same lexical inflection. The lemma remains exact so
            # German case-sensitive lexical distinctions are not merged.
            inflection_rows_by_lemma: dict[str, list[tuple[str, int | None]]] = {}
            for lemma, inflection in set(morphs):
                if evaluate_inflection:
                    row = connection.execute(
                        "SELECT highest_inflection_learning_interval FROM Morphs "
                        "WHERE lemma = ? AND inflection = ? LIMIT 1",
                        (lemma, inflection),
                    ).fetchone()
                    if row is None:
                        rows = inflection_rows_by_lemma.get(lemma)
                        if rows is None:
                            rows = connection.execute(
                                "SELECT inflection, highest_inflection_learning_interval "
                                "FROM Morphs WHERE lemma = ?",
                                (lemma,),
                            ).fetchall()
                            inflection_rows_by_lemma[lemma] = rows
                        folded_inflection = inflection.casefold()
                        matching_intervals = [
                            candidate_interval
                            for candidate_inflection, candidate_interval in rows
                            if str(candidate_inflection).casefold() == folded_inflection
                        ]
                        value = max(
                            (int(candidate) for candidate in matching_intervals if candidate is not None),
                            default=0,
                        )
                    else:
                        value = 0 if row[0] is None else int(row[0])
                else:
                    row = connection.execute(
                        "SELECT highest_lemma_learning_interval FROM Morphs "
                        "WHERE lemma = ? LIMIT 1",
                        (lemma,),
                    ).fetchone()
                    value = 0 if row is None or row[0] is None else int(row[0])
                found[(lemma, inflection)] = value
            return found
        finally:
            connection.close()

    @staticmethod
    def cache_key(text: str) -> str:
        return strip_html(text).replace("\r\n", "\n").replace("\r", "\n")

    @staticmethod
    def _path_fingerprint(path: Path) -> dict[str, Any]:
        try:
            info = path.stat()
            return {"path": str(path.resolve()), "mtime_ns": info.st_mtime_ns, "size": info.st_size}
        except OSError:
            return {"path": str(path), "missing": True}

    def _init_disk_cache(self) -> None:
        """Open a bounded SQLite result cache in a private directory under /tmp."""
        try:
            self.cache_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
            info = self.cache_dir.lstat()
            if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
                raise RuntimeError(f"cache path is not a real directory: {self.cache_dir}")
            if hasattr(os, "getuid") and info.st_uid != os.getuid():
                raise PermissionError(f"cache directory is not owned by this user: {self.cache_dir}")
            os.chmod(self.cache_dir, 0o700)

            # Cached colors depend on the AnkiMorphs DB, profile settings, names
            # list, selected spaCy model, and spaCy version. Any change creates a
            # new namespace, so old colors cannot survive a DB/config update.
            profile_settings = self.profile_dir / "ankimorphs_profile_settings.json"
            try:
                settings_payload = json.dumps(self.config, sort_keys=True, ensure_ascii=False)
            except (TypeError, ValueError):
                settings_payload = repr(self.config)
            spaCy_version = getattr(self._spacy, "__version__", "unknown")
            namespace_payload = {
                "cache_format": 3,
                "db": self._path_fingerprint(self.db_path),
                "settings_file": self._path_fingerprint(profile_settings),
                "names_file": self._path_fingerprint(self.names_path),
                "settings": settings_payload,
                "spacy": spaCy_version,
            }
            self._disk_cache_namespace = hashlib.sha256(
                json.dumps(namespace_payload, sort_keys=True, ensure_ascii=False).encode("utf-8")
            ).hexdigest()

            db_file = self.cache_dir / "highlights.sqlite3"
            self._disk_cache = sqlite3.connect(str(db_file), timeout=3.0, check_same_thread=False)
            with self._disk_cache_lock:
                self._disk_cache.execute("PRAGMA journal_mode=MEMORY")
                self._disk_cache.execute("PRAGMA synchronous=NORMAL")
                self._disk_cache.execute("PRAGMA busy_timeout=3000")
                self._disk_cache.execute(
                    "CREATE TABLE IF NOT EXISTS results ("
                    "cache_key TEXT PRIMARY KEY, namespace TEXT NOT NULL, "
                    "result_json TEXT NOT NULL, updated_at INTEGER NOT NULL)"
                )
                self._disk_cache.execute(
                    "CREATE INDEX IF NOT EXISTS results_namespace_updated "
                    "ON results(namespace, updated_at)"
                )
                # Retain only the active namespace. Old rows are useless after a
                # DB/config change and would otherwise consume tmpfs indefinitely.
                self._disk_cache.execute(
                    "DELETE FROM results WHERE namespace != ?", (self._disk_cache_namespace,)
                )
                self._disk_cache_entries = int(
                    self._disk_cache.execute("SELECT COUNT(*) FROM results").fetchone()[0]
                )
                self._disk_cache.commit()
            self.log(f"Tmpfs highlight cache: {db_file} ({self._disk_cache_entries} entries)")
        except Exception as exc:
            self._disk_cache = None
            self.log(f"Tmpfs cache unavailable; using in-memory cache only: {exc}")

    def close_disk_cache(self) -> None:
        with self._disk_cache_lock:
            if self._disk_cache is not None:
                try:
                    self._disk_cache.commit()
                    self._disk_cache.close()
                finally:
                    self._disk_cache = None

    def _disk_cache_key(self, model_name: str, text: str) -> str:
        payload = "\0".join((self._disk_cache_namespace, model_name, self.cache_key(text)))
        return hashlib.sha256(payload.encode("utf-8")).hexdigest()

    def _cache_get(self, model_name: str, text: str) -> dict[str, Any] | None:
        key = (model_name, self.cache_key(text))
        with self._cache_lock:
            result = self._result_cache.get(key)
            if result is not None:
                self._result_cache.move_to_end(key)
                return result

        if self._disk_cache is not None:
            disk_key = self._disk_cache_key(model_name, text)
            try:
                with self._disk_cache_lock:
                    row = self._disk_cache.execute(
                        "SELECT result_json FROM results WHERE cache_key = ? AND namespace = ?",
                        (disk_key, self._disk_cache_namespace),
                    ).fetchone()
                    if row is not None:
                        result = json.loads(row[0])
                        self._disk_cache_hits += 1
                        with self._cache_lock:
                            self._result_cache[key] = result
                            self._result_cache.move_to_end(key)
                            while len(self._result_cache) > self._cache_limit:
                                self._result_cache.popitem(last=False)
                        return result
            except (sqlite3.Error, json.JSONDecodeError, TypeError) as exc:
                self.log(f"Tmpfs cache read failed: {exc}")
        return None

    def _cache_put(self, model_name: str, text: str, result: dict[str, Any]) -> None:
        key = (model_name, self.cache_key(text))
        with self._cache_lock:
            self._result_cache[key] = result
            self._result_cache.move_to_end(key)
            while len(self._result_cache) > self._cache_limit:
                self._result_cache.popitem(last=False)

        if self._disk_cache is not None:
            disk_key = self._disk_cache_key(model_name, text)
            try:
                result_json = json.dumps(result, ensure_ascii=False, separators=(",", ":"))
                with self._disk_cache_lock:
                    existed = self._disk_cache.execute(
                        "SELECT 1 FROM results WHERE cache_key = ?", (disk_key,)
                    ).fetchone() is not None
                    self._disk_cache.execute(
                        "INSERT OR REPLACE INTO results(cache_key, namespace, result_json, updated_at) "
                        "VALUES (?, ?, ?, ?)",
                        (disk_key, self._disk_cache_namespace, result_json, time.time_ns()),
                    )
                    if not existed:
                        self._disk_cache_entries += 1
                    self._disk_cache_writes += 1
                    # Keep the tmpfs footprint bounded. A subtitle library can
                    # contain many tracks, and /tmp is not an infinite disk.
                    if self._disk_cache_writes >= 128:
                        self._disk_cache.execute(
                            "DELETE FROM results WHERE cache_key IN ("
                            "SELECT cache_key FROM results WHERE namespace = ? "
                            "ORDER BY updated_at DESC LIMIT -1 OFFSET 30000)",
                            (self._disk_cache_namespace,),
                        )
                        self._disk_cache.execute("PRAGMA optimize")
                        self._disk_cache_writes = 0
                        self._disk_cache_entries = int(
                            self._disk_cache.execute("SELECT COUNT(*) FROM results").fetchone()[0]
                        )
                    self._disk_cache.commit()
            except (sqlite3.Error, TypeError, ValueError) as exc:
                self.log(f"Tmpfs cache write failed: {exc}")

    def analyze(self, text: str, model_name: str) -> dict[str, Any]:
        cached = self._cache_get(model_name, text)
        if cached is not None:
            return cached
        # A prefetch worker analyzes one cue at a time. Foreground requests share
        # this lock and therefore wait for at most one cue, not an entire track.
        with self._analysis_lock:
            cached = self._cache_get(model_name, text)
            if cached is not None:
                return cached
            result = self._analyze_uncached(text, model_name)
            self._cache_put(model_name, text, result)
            return result

    def _analyze_uncached(self, text: str, model_name: str) -> dict[str, Any]:
        if not isinstance(text, str):
            raise TypeError("subtitle text must be a string")
        original = strip_html(text)
        if not original:
            return {"segments": [{"text": "", "status": "normal"}], "morph_count": 0}

        morphology_input = self._preprocess_for_morphology(original)
        if not morphology_input.strip():
            return {"segments": [{"text": original, "status": "normal"}], "morph_count": 0}

        nlp = self._get_nlp(model_name)
        doc = nlp(morphology_input)
        morphs: list[tuple[str, str]] = []
        ignore_proper_nouns = bool(self.config["preprocess_ignore_names_morphemizer"])
        ignore_numbers = bool(self.config["preprocess_ignore_numbers"])
        ignore_names_file = bool(self.config["preprocess_ignore_names_textfile"])

        for token in doc:
            if token.pos_ in EXCLUDED_POS:
                continue
            if ignore_proper_nouns and token.pos_ == "PROPN":
                continue
            if ignore_numbers and token.pos_ == "NUM":
                continue
            if PUNCTUATION_ONLY.fullmatch(token.text):
                continue
            if ignore_names_file and token.text.lower() in self.names:
                continue
            morphs.append((token.lemma_, token.text))

        if not morphs:
            return {"segments": [{"text": original, "status": "normal"}], "morph_count": 0}

        intervals = self._intervals_for(morphs)
        threshold = int(self.config["interval_for_known_morphs"])
        evaluate_inflection = bool(self.config["evaluate_morph_inflection"])

        # Port of AnkiMorphs TextHighlighter._tag_morphemes(): consume the longest
        # surface morphs first, blank matched ranges, then sort the retained ranges.
        search_text = original.lower()
        spans: list[tuple[int, int, str, str]] = []
        for lemma, inflection in sorted(morphs, key=lambda item: len(item[1]), reverse=True):
            key = (lemma, inflection)
            if not inflection:
                continue
            needle = inflection.lower()
            while True:
                start = search_text.find(needle)
                if start < 0:
                    break
                end = start + len(needle)
                interval = intervals.get(key, 0)
                if interval == 0:
                    status = "unknown"
                elif interval < threshold:
                    status = "learning"
                else:
                    status = "known"
                spans.append((start, end, status, lemma))
                search_text = search_text[:start] + (" " * (end - start)) + search_text[end:]

        spans.sort(key=lambda span: span[0])
        segments: list[dict[str, str]] = []
        cursor = 0
        for start, end, status, lemma in spans:
            if start > cursor:
                segments.append({"text": original[cursor:start], "status": "normal"})
            if end > cursor:
                segments.append({
                    "text": original[max(cursor, start):end],
                    "status": status,
                    "lemma": lemma,
                })
                cursor = end
        if cursor < len(original):
            segments.append({"text": original[cursor:], "status": "normal"})
        if not segments:
            segments = [{"text": original, "status": "normal"}]

        return {
            "segments": segments,
            "morph_count": len(morphs),
            "highlighted_count": len(spans),
            "evaluation": "inflection" if evaluate_inflection else "lemma",
            "known_threshold_days": threshold,
            "model": model_name,
        }

    @staticmethod
    def _decode_subtitle_bytes(data: bytes) -> str:
        for encoding in ("utf-8-sig", "utf-16", "cp1252"):
            try:
                return data.decode(encoding)
            except UnicodeDecodeError:
                continue
        return data.decode("utf-8", errors="replace")

    @staticmethod
    def _parse_timestamp(value: str) -> float | None:
        value = value.strip().replace(",", ".")
        match = re.fullmatch(r"(?:(\d+):)?(\d{1,2}):(\d{2})(?:\.(\d+))?", value)
        if not match:
            return None
        hours = int(match.group(1) or 0)
        minutes = int(match.group(2))
        seconds = int(match.group(3))
        fraction = float("0." + (match.group(4) or "0"))
        return hours * 3600 + minutes * 60 + seconds + fraction

    @classmethod
    def extract_cues(cls, content: str, suffix: str = "") -> list[str]:
        """Extract plain subtitle cue text from SRT, VTT, ASS/SSA or LRC-like text."""
        suffix = suffix.lower()
        cues: list[str] = []
        if suffix in {".ass", ".ssa"} or "[Events]" in content:
            fields: list[str] = []
            in_events = False
            for raw_line in content.splitlines():
                line = raw_line.strip("\ufeff \t")
                if line.startswith("[") and line.endswith("]"):
                    in_events = line.lower() == "[events]"
                    continue
                if not in_events:
                    continue
                if line.lower().startswith("format:"):
                    fields = [item.strip().lower() for item in line.split(":", 1)[1].split(",")]
                elif line.lower().startswith("dialogue:") and fields:
                    parts = line.split(":", 1)[1].lstrip().split(",", len(fields) - 1)
                    if len(parts) != len(fields):
                        continue
                    row = dict(zip(fields, parts))
                    cue_text = row.get("text", "")
                    cue_text = re.sub(r"\{[^}]*}", "", cue_text)
                    cue_text = cue_text.replace(r"\N", "\n").replace(r"\n", "\n").replace(r"\h", " ")
                    cue_text = re.sub(r"<[^>]*>", "", html.unescape(cue_text))
                    if cue_text.strip():
                        cues.append(cue_text)
            return cues

        # SRT and WebVTT use a timing line followed by one or more text lines.
        timestamp_line = re.compile(
            r"(?:^|\s)(\d{1,2}:)?\d{1,2}:\d{2}[,.]\d{1,3}\s*-->\s*(?:\d{1,2}:)?\d{1,2}:\d{2}[,.]\d{1,3}",
            re.MULTILINE,
        )
        lines = content.replace("\r\n", "\n").replace("\r", "\n").split("\n")
        current: list[str] = []
        after_timing = False
        for line in lines:
            if "-->" in line and timestamp_line.search(line):
                if current:
                    cues.append("\n".join(current).strip())
                current = []
                after_timing = True
                continue
            if after_timing:
                if not line.strip():
                    if current:
                        cues.append("\n".join(current).strip())
                    current = []
                    after_timing = False
                elif not line.startswith(("NOTE ", "STYLE", "REGION")):
                    current.append(line)
        if current:
            cues.append("\n".join(current).strip())

        # LRC has one timed line per lyric chunk.
        if not cues and suffix == ".lrc":
            for line in lines:
                match = re.match(r"^\s*\[[0-9:.]+](.*)$", line)
                if match and match.group(1).strip():
                    cues.append(match.group(1).strip())
        return [cue for cue in cues if cue.strip()]

    def start_prefetch_worker(self) -> None:
        if self._prefetch_thread and self._prefetch_thread.is_alive():
            return
        self._prefetch_stop.clear()
        self._prefetch_thread = threading.Thread(
            target=self._prefetch_worker, name="ankimorphs-prefetch", daemon=True
        )
        self._prefetch_thread.start()

    def _prefetch_worker(self) -> None:
        while not self._prefetch_stop.is_set():
            try:
                job_id, cache_key, cue_text, model_name = self._prefetch_queue.get(timeout=0.2)
            except queue.Empty:
                continue
            with self._prefetch_lock:
                job = self._prefetch_job
                if not job or job["id"] != job_id:
                    self._prefetch_queue.task_done()
                    continue
            # Let a just-arrived visible cue take the analysis lock first.
            while self._foreground_waiting.is_set() and not self._prefetch_stop.is_set():
                time.sleep(0.01)
            try:
                result = self.analyze(cue_text, model_name)
                error = None
            except Exception as exc:
                result = None
                error = str(exc)
                self.log(f"Prefetch cue failed: {exc}")
            with self._prefetch_lock:
                job = self._prefetch_job
                if job and job["id"] == job_id:
                    job["completed"] += 1
                    if error:
                        job["failed"] += 1
                    else:
                        job["results"].append({"text": cache_key, "result": result})
                    if job["completed"] >= job["total"]:
                        job["status"] = "done"
            self._prefetch_queue.task_done()
            # Small yield keeps foreground subtitle analysis responsive.
            time.sleep(0.002)

    def _begin_prefetch(self, cues: list[str], model_name: str, source: str) -> dict[str, Any]:
        unique: OrderedDict[str, str] = OrderedDict()
        for cue in cues:
            key = self.cache_key(cue)
            if key.strip() and key not in unique:
                unique[key] = cue
        with self._prefetch_lock:
            self._prefetch_job_id += 1
            job_id = self._prefetch_job_id
            job: dict[str, Any] = {
                "id": job_id,
                "source": source,
                "model": model_name,
                "total": len(unique),
                "completed": 0,
                "failed": 0,
                "status": "running" if unique else "done",
                "results": [],
            }
            self._prefetch_job = job
            for key, cue in unique.items():
                cached = self._cache_get(model_name, cue)
                if cached is not None:
                    job["completed"] += 1
                    job["results"].append({"text": key, "result": cached})
                else:
                    self._prefetch_queue.put((job_id, key, cue, model_name))
            if job["completed"] >= job["total"]:
                job["status"] = "done"
        return {
            "ok": True,
            "job_id": job_id,
            "total": job["total"],
            "completed": job["completed"],
            "status": job["status"],
            "source": source,
            "cache_hits": job["completed"],
        }

    def prefetch_file(self, path: str, model_name: str) -> dict[str, Any]:
        subtitle_path = Path(path).expanduser()
        if not subtitle_path.is_file():
            raise FileNotFoundError(f"Subtitle file does not exist: {subtitle_path}")
        data = subtitle_path.read_bytes()
        content = self._decode_subtitle_bytes(data)
        cues = self.extract_cues(content, subtitle_path.suffix)
        if not cues:
            raise ValueError(f"No subtitle cues found in {subtitle_path.name}")
        return self._begin_prefetch(cues, model_name, str(subtitle_path))

    def prefetch_text(self, content: str, model_name: str, source: str = "embedded subtitle") -> dict[str, Any]:
        if not isinstance(content, str) or not content.strip():
            raise ValueError("No subtitle text was extracted")
        cues = self.extract_cues(content, ".srt")
        if not cues:
            raise ValueError("Could not parse extracted subtitle cues")
        return self._begin_prefetch(cues, model_name, source)

    def prefetch_status(self, job_id: int, cursor: int = 0, limit: int = 80) -> dict[str, Any]:
        with self._prefetch_lock:
            job = self._prefetch_job
            if not job or int(job_id) != job["id"]:
                return {"ok": True, "status": "stale", "job_id": int(job_id), "results": [], "next_cursor": int(cursor)}
            start = max(0, int(cursor))
            batch_size = max(1, min(500, int(limit)))
            results = job["results"][start:start + batch_size]
            next_cursor = start + len(results)
            return {
                "ok": True,
                "job_id": job["id"],
                "status": job["status"],
                "total": job["total"],
                "completed": job["completed"],
                "failed": job["failed"],
                "results": results,
                "next_cursor": next_cursor,
                "result_count": len(job["results"]),
                "source": job["source"],
            }

    def handle(self, request: dict[str, Any]) -> dict[str, Any]:
        action = request.get("action", "analyze")
        if action == "list":
            return {
                "ok": True,
                "models": self.models(),
                "priority_files": self.priority_files(),
                "evaluation": "inflection" if self.config["evaluate_morph_inflection"] else "lemma",
                "known_threshold_days": int(self.config["interval_for_known_morphs"]),
                "cache_dir": str(self.cache_dir),
                "cache_entries": self._disk_cache_entries,
                "disk_cache_hits": self._disk_cache_hits,
                "disk_cache_enabled": self._disk_cache is not None,
            }
        if action == "quit":
            return {"ok": True, "quit": True}
        if action == "ping":
            return {"ok": True, "ready": True}
        if action == "prefetch_file":
            return self.prefetch_file(str(request.get("path", "")), str(request.get("model", "")))
        if action == "prefetch_text":
            return self.prefetch_text(str(request.get("text", "")), str(request.get("model", "")), str(request.get("source", "embedded subtitle")))
        if action == "prefetch_status":
            return self.prefetch_status(int(request.get("job_id", 0)), int(request.get("cursor", 0)), int(request.get("limit", 80)))
        if action == "analyze":
            self._foreground_waiting.set()
            try:
                result = self.analyze(request.get("text", ""), str(request.get("model", "")))
            finally:
                self._foreground_waiting.clear()
            result["ok"] = True
            return result
        raise ValueError(f"Unknown action: {action}")


def serve(args: argparse.Namespace) -> int:
    socket_path = Path(args.socket)
    socket_path.parent.mkdir(parents=True, exist_ok=True)
    log_path = Path(args.log) if args.log else None
    log_handle = None
    if log_path:
        log_path.parent.mkdir(parents=True, exist_ok=True)
        log_handle = log_path.open("a", encoding="utf-8")
        sys.stdout = log_handle
        sys.stderr = log_handle

    listener: socket.socket | None = None
    try:
        engine = AnkiMorphsEngine(
            profile_dir=Path(args.profile_dir).expanduser(),
            db_path=Path(args.db).expanduser(),
            priority_dir=Path(args.priority_dir).expanduser(),
            names_path=Path(args.names).expanduser(),
            cache_dir=Path(args.cache_dir).expanduser() if args.cache_dir else None,
        )
        engine.start_prefetch_worker()
        # Do not steal another live mpv instance's socket.
        if socket_path.exists():
            probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            try:
                probe.settimeout(0.25)
                probe.connect(str(socket_path))
                print("AnkiMorphs backend is already listening; exiting.", flush=True)
                return 0
            except OSError:
                socket_path.unlink(missing_ok=True)
            finally:
                probe.close()

        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(str(socket_path))
        os.chmod(socket_path, 0o600)
        listener.listen(8)
        listener.settimeout(1.0)
        print(f"Backend listening on {socket_path}", flush=True)

        running = True
        while running:
            try:
                connection, _ = listener.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            with connection:
                try:
                    connection.settimeout(10.0)
                    payload = connection.makefile("rb").readline(64 * 1024 * 1024)
                    request = json.loads(payload.decode("utf-8"))
                    response = engine.handle(request)
                    connection.sendall((json.dumps(response, ensure_ascii=False) + "\n").encode("utf-8"))
                    if response.get("quit"):
                        running = False
                except Exception as exc:
                    engine.log(f"Request failed: {exc}\n{traceback.format_exc()}")
                    try:
                        connection.sendall((json.dumps({"ok": False, "error": str(exc)}) + "\n").encode("utf-8"))
                    except OSError:
                        pass
    except Exception as exc:
        print(f"Backend startup failed: {exc}\n{traceback.format_exc()}", file=sys.stderr, flush=True)
        return 1
    finally:
        if "engine" in locals():
            engine._prefetch_stop.set()
            if engine._prefetch_thread:
                engine._prefetch_thread.join(timeout=1.0)
            engine.close_disk_cache()
        if listener is not None:
            listener.close()
        socket_path.unlink(missing_ok=True)
        if log_handle:
            log_handle.close()
    return 0


def request_server(args: argparse.Namespace) -> int:
    try:
        if args.action:
            request = {"action": args.action}
        else:
            raw = sys.stdin.read()
            request = json.loads(raw) if raw.strip() else {"action": "ping"}
        deadline = time.monotonic() + 60.0
        last_error: Exception | None = None
        while time.monotonic() < deadline:
            client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            try:
                client.settimeout(10.0)
                client.connect(args.socket)
                client.sendall((json.dumps(request, ensure_ascii=False) + "\n").encode("utf-8"))
                chunks = bytearray()
                while b"\n" not in chunks and len(chunks) < 8 * 1024 * 1024:
                    part = client.recv(65536)
                    if not part:
                        break
                    chunks.extend(part)
                if not chunks:
                    raise RuntimeError("backend closed the connection without a response")
                print(bytes(chunks).split(b"\n", 1)[0].decode("utf-8"))
                return 0
            except (OSError, RuntimeError) as exc:
                last_error = exc
                time.sleep(0.1)
            finally:
                client.close()
        raise RuntimeError(f"could not contact AnkiMorphs backend at {args.socket}: {last_error}")
    except Exception as exc:
        print(json.dumps({"ok": False, "error": str(exc)}))
        return 1


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="mode", required=True)
    daemon = sub.add_parser("daemon")
    daemon.add_argument("--socket", required=True)
    daemon.add_argument("--profile-dir", required=True)
    daemon.add_argument("--db", required=True)
    daemon.add_argument("--priority-dir", required=True)
    daemon.add_argument("--names", required=True)
    daemon.add_argument("--cache-dir", default="", help="tmpfs cache directory (default: /tmp/mpv-ankimorphs-UID)")
    daemon.add_argument("--log", default="")
    request = sub.add_parser("request")
    request.add_argument("--socket", required=True)
    request.add_argument("--action", default="")
    args = parser.parse_args()
    if args.mode == "daemon":
        return serve(args)
    return request_server(args)


if __name__ == "__main__":
    raise SystemExit(main())
