from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "ankimorphs-dict" / "main.lua").read_text(encoding="utf-8")
config = (ROOT / "script-opts" / "ankimorphs-dict.conf").read_text(encoding="utf-8")

assert 'select_previous_unknown_key = "ctrl+alt+shift+u"' in source
assert 'auto_dictionary_on_morph_navigation = false' in source
assert 'auto_dictionary_on_unknown_navigation = false' in source
assert "select_previous_unknown_key=ctrl+alt+shift+u" in config
assert "auto_dictionary_on_morph_navigation=no" in config
assert "auto_dictionary_on_unknown_navigation=no" in config
assert 'include_learning_in_unknown_navigation = false' in source
assert 'auto_select_first_unknown_on_new_cue = false' in source
assert 'selection_color = ""' in source
assert 'include_learning_in_unknown_navigation=no' in config
assert 'auto_select_first_unknown_on_new_cue=no' in config
assert 'selection_color=\n' in config
assert 'status == "unknown"' in source
assert 'o.include_learning_in_unknown_navigation and status == "learning"' in source
assert 'mp.register_script_message("select-previous-unknown", select_previous_unknown)' in source
print("navigation defaults, fresh-morph inclusion, cue auto-selection, and auto-dictionary options: OK")
