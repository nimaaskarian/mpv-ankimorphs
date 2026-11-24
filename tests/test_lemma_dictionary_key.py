from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def test_lemma_dictionary_key_has_default_and_is_configured_in_script_opts():
    lua = (ROOT / "ankimorphs-dict" / "main.lua").read_text()
    config = (ROOT / "script-opts" / "ankimorphs-dict.conf").read_text()

    assert 'show_lemma_dictionary_key = "ctrl+alt+l"' in lua
    assert "show_lemma_dictionary_key=ctrl+alt+l" in config
    assert 'mp.add_key_binding(o.show_lemma_dictionary_key, "ankimorphs-dict-show-lemma-dictionary", show_lemma_dictionary)' in lua


def test_lemma_dictionary_lookup_uses_only_spacy_lemma():
    lua = (ROOT / "ankimorphs-dict" / "main.lua").read_text()

    assert 'dict_lookup(lemma, "", function(result)' in lua
    assert 'mp.register_script_message("show-lemma-dictionary", show_lemma_dictionary)' in lua


def test_next_unknown_morph_keybinding_and_message():
    lua = (ROOT / "ankimorphs-dict" / "main.lua").read_text()
    config = (ROOT / "script-opts" / "ankimorphs-dict.conf").read_text()
    assert 'select_next_unknown_key = "ctrl+alt+u"' in lua
    assert 'select_next_unknown_key=ctrl+alt+u' in config
    assert 'mp.add_key_binding(o.select_next_unknown_key, "ankimorphs-dict-select-next-unknown", select_next_unknown)' in lua
    assert 'mp.register_script_message("select-next-unknown", select_next_unknown)' in lua
    assert 'local function is_unknown_navigation_target(target)' in lua
    assert 'return status == "unknown"' in lua
