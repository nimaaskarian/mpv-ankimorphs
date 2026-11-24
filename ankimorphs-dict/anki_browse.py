#!/usr/bin/env python3
"""Open Anki's Browser for a phrase and its AnkiMorphs unknown morph.

Invocation contract from the mpv companion:
    anki_browse.py WORD PHRASE

Configuration:
    ANKIMORPHS_BROWSE_DECK  Deck to restrict the search to (default: deutsch)
    ANKICONNECT_URL         AnkiConnect URL (default: http://127.0.0.1:8765)
    ANKICONNECT_KEY         Optional AnkiConnect authentication key
"""
from __future__ import annotations

import json
import os
import sys
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

DEFAULT_DECK = "deutsch"
DEFAULT_URL = "http://127.0.0.1:8765"
API_VERSION = 6


def _escape_term(value: str, *, escape_colons: bool = True) -> str:
    """Escape literal text for Anki's quoted search syntax."""
    value = value.replace("\\", "\\\\")
    value = value.replace('"', '\\"')
    value = value.replace("*", "\\*").replace("_", "\\_")
    if escape_colons:
        value = value.replace(":", "\\:")
    # Anki's search parser treats these as HTML unless entity-escaped.
    value = value.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    return value


def _quoted(value: str, *, escape_colons: bool = True) -> str:
    return '"' + _escape_term(value, escape_colons=escape_colons) + '"'


def build_query(args) -> str:
    """Build a deck-scoped AnkiMorphs unknown-morph + exact-phrase query."""
    deck = args.deck.strip()

    if not deck:
        raise ValueError("ANKIMORPHS_BROWSE_DECK is empty")
    deck_term = "deck:" + _quoted(deck, escape_colons=False)

    terms = [deck_term]
    if args.word:
        word = args.word.strip()
        morph_term = '"' + _escape_term(word) + '"'
        terms.append(morph_term)

    if args.phrase is not None:
        args.phrase = " ".join(args.phrase.split())
        if args.phrase:
            terms.append(_quoted(args.phrase))

    return " ".join(terms)


def invoke_gui_browse(query: str, *, endpoint: str, api_key: str = "") -> list[int]:
    payload: dict[str, Any] = {
        "action": "guiBrowse",
        "version": API_VERSION,
        "params": {"query": query},
    }
    if api_key:
        payload["key"] = api_key

    body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    request = Request(
        endpoint,
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urlopen(request, timeout=4) as response:
            result = json.loads(response.read().decode("utf-8"))
    except HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"AnkiConnect HTTP {exc.code}: {detail or exc.reason}") from exc
    except URLError as exc:
        raise RuntimeError(
            f"Could not reach AnkiConnect at {endpoint}: {exc.reason}. "
            "Make sure Anki is running and AnkiConnect is installed."
        ) from exc
    except TimeoutError as exc:
        raise RuntimeError(f"AnkiConnect request timed out at {endpoint}") from exc

    if not isinstance(result, dict):
        raise RuntimeError(f"Unexpected AnkiConnect response: {result!r}")
    if result.get("error"):
        raise RuntimeError(f"AnkiConnect error: {result['error']}")
    cards = result.get("result")
    if not isinstance(cards, list):
        raise RuntimeError(f"Unexpected guiBrowse result: {cards!r}")
    return cards


def main(argv: list[str] | None = None) -> int:
    from argparse import ArgumentParser
    if argv is None:
        argv = sys.argv[1:]
    parser = ArgumentParser(
        prog='anki_browse',
        description='browse anki using anki connect with a phrase and/or a word',
    )
    parser.add_argument('-p', '--phrase', default=None)
    parser.add_argument('-w', '--word', default=None)
    parser.add_argument('-d', '--deck', default=os.environ.get("ANKIMORPHS_BROWSE_DECK", DEFAULT_DECK))
    parser.add_argument('-a', '--api-key', default=os.environ.get("ANKICONNECT_KEY", ""))
    parser.add_argument('-e', '--endpoint', default=os.environ.get("ANKICONNECT_URL", DEFAULT_URL))
    args = parser.parse_args(argv)
    if args.phrase is None and args.word is None:
        parser.print_help()

    try:
        query = build_query(args)
        cards = invoke_gui_browse(query, endpoint=args.endpoint, api_key=args.api_key)
    except (ValueError, RuntimeError) as exc:
        print(f"AnkiMorphs Browser search: {exc}", file=sys.stderr)
        return 1

    print(f"Opened Anki Browser: {len(cards)} matching card(s)")
    print(f"Search: {query}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
