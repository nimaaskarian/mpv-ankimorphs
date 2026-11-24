from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def test_main_toggle_binding_is_configurable_and_defaults_to_previous_key():
    lua = (ROOT / "ankimorphs.lua").read_text()
    config = (ROOT / "script-opts" / "ankimorphs.conf").read_text()

    assert 'toggle_highlighting_key = "ctrl+alt+h"' in lua
    assert "toggle_highlighting_key=ctrl+alt+h" in config
    assert 'mp.add_key_binding(o.toggle_highlighting_key ~= "" and o.toggle_highlighting_key or nil,' in lua


def test_main_toggle_script_binding_remains_available_without_physical_key():
    lua = (ROOT / "ankimorphs.lua").read_text()

    assert 'mp.register_script_message("ankimorphs-toggle", toggle_highlighting)' in lua
    assert 'o.toggle_highlighting_key ~= "" and o.toggle_highlighting_key or nil' in lua
