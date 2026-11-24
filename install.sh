#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MPV_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/mpv"
SCRIPT_DIR="$MPV_CONFIG/scripts/ankimorphs"
DICT_SCRIPT_DIR="$MPV_CONFIG/scripts/ankimorphs-dict"

install_config_if_missing() {
    local source="$1"
    local destination="$2"
    install -d "$(dirname -- "$destination")"
    if [[ -e "$destination" ]]; then
        printf 'Preserving existing config: %s\n' "$destination"
    else
        install -m644 "$source" "$destination"
        printf 'Installed config: %s\n' "$destination"
    fi
}

# mpv treats every immediate subdirectory of scripts/ as a directory script.
# Keep the entry points inside separate directories with main.lua.
install -d "$SCRIPT_DIR" "$DICT_SCRIPT_DIR"
install -m644 "$ROOT/ankimorphs.lua" "$SCRIPT_DIR/main.lua"
install -m644 "$ROOT/ankimorphs/backend.py" "$SCRIPT_DIR/backend.py"
install -m644 "$ROOT/ankimorphs-dict/main.lua" "$DICT_SCRIPT_DIR/main.lua"
install -m755 "$ROOT/ankimorphs-dict/anki_browse.py" "$DICT_SCRIPT_DIR/anki_browse.py"

# Never overwrite an existing user config. Users can merge new options manually.
install_config_if_missing "$ROOT/script-opts/ankimorphs.conf" "$MPV_CONFIG/script-opts/ankimorphs.conf"
install_config_if_missing "$ROOT/script-opts/ankimorphs-dict.conf" "$MPV_CONFIG/script-opts/ankimorphs-dict.conf"

# Remove the obsolete flat entry point from earlier package versions.
rm -f "$MPV_CONFIG/scripts/ankimorphs.lua"

# Python bytecode caches are not mpv scripts; remove only stale generated files.
for cache_dir in "$MPV_CONFIG/scripts/__pycache__" "$SCRIPT_DIR/__pycache__"; do
    if [[ -d "$cache_dir" ]]; then
        find "$cache_dir" -type f -name '*.py[co]' -delete
        find "$cache_dir" -depth -type d -empty -delete
    fi
done

printf '\nInstalled AnkiMorphs highlighter: %s/main.lua\n' "$SCRIPT_DIR"
printf 'Installed dictionary companion: %s/main.lua\n' "$DICT_SCRIPT_DIR"
printf 'Configs (existing files preserved):\n  %s/script-opts/ankimorphs.conf\n  %s/script-opts/ankimorphs-dict.conf\n' "$MPV_CONFIG" "$MPV_CONFIG"
printf 'Review ankimorphs-dict.conf to set click/key scripts.\n'
printf 'Example AnkiConnect Browser action: %s/examples/ankimorphs-browse.conf\n' "$ROOT"
