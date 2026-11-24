local observers, bindings, messages = {}, {}, {}
local timers, commands = {}, {}
local mouse = {x = 400, y = 530, hover = true}
local overlay_count = 0
local overlays = {}
local properties = {}
local option_state = nil
local mp = {}
function mp.create_osd_overlay()
  overlay_count = overlay_count + 1
  local overlay = {data = ""}
  function overlay:update() end
  overlays[#overlays + 1] = overlay
  return overlay
end
function mp.get_osd_size() return 800, 600, 1 end
function mp.set_property_native(name, value) properties[name] = value end
function mp.get_property_native(name)
  if name == "mouse-pos" then return mouse end
  return nil
end
function mp.observe_property(name, _kind, callback) observers[name] = callback end
function mp.add_key_binding(key, name, callback) bindings[key] = callback; bindings[name] = callback end
function mp.register_script_message(name, callback) messages[name] = callback end
function mp.register_event() end
function mp.add_timeout(_, callback)
  local timer = {callback = callback}
  function timer:kill() self.killed = true end
  timers[#timers + 1] = timer
  return timer
end
function mp.osd_message() end
function mp.command_native_async(request, callback)
  commands[#commands + 1] = request
  if request.args[1] == "dict" then
    callback(true, {status = 0, stdout = "Was\n  interr. pronoun: what"}, nil)
  elseif request.args[1] == "/bin/sh" then
    callback(true, {status = 0, stdout = "", stderr = ""}, nil)
  else
    error("unexpected subprocess: " .. tostring(request.args[1]))
  end
end
package.preload["mp"] = function() return mp end
package.preload["mp.msg"] = function() return {info=function() end, warn=function() end, error=function(x) error(x) end} end
package.preload["mp.options"] = function()
  return {read_options=function(target)
    target.left_click_script = 'capture "$word" "$lemma" "$phrase"'
    target.right_click_script = 'capture-right "$word" "$lemma" "$phrase"'
    target.action_1_key = "ctrl+alt+a"
    target.action_1_script = 'capture-phrase "$phrase"'
    target.action_2_key = "ctrl+alt+b"
    target.action_2_script = 'capture-morph "$lemma"'
    -- Simulate user overrides in script-opts/ankimorphs-dict.conf.
    target.show_lemma_dictionary_key = "ctrl+alt+g"
    target.auto_dictionary_on_morph_navigation = true
    target.auto_dictionary_on_unknown_navigation = false
    option_state = target
  end}
end

local chunk, err = loadfile(arg[1])
assert(chunk, err)
chunk()
assert(option_state.include_learning_in_unknown_navigation == false,
  "learning morphs must be excluded from unknown navigation by default")
assert(option_state.auto_select_first_unknown_on_new_cue == false,
  "automatic first-unknown selection must be disabled by default")

local cue = {
  active = true, generation = 17, text = "Was ist?", width = 800, height = 600,
  font_size = 38, bottom_margin = 48, font_name = "Noto Sans",
  segments = {
    {text = "Was", status = "known", lemma = "was"},
    {text = " ", status = "normal", lemma = ""},
    {text = "ist", status = "learning", lemma = "sein"},
    {text = "?", status = "normal", lemma = ""},
  },
}
observers["user-data/ankimorphs/current-cue"]("user-data/ankimorphs/current-cue", cue)
observers["mouse-pos"]("mouse-pos", mouse)
assert(#timers > 0, "hover lookup should be delayed")
timers[#timers].callback()
assert(commands[1].args[1] == "dict", "dict client should be invoked")
assert(overlay_count == 1, "companion should create only the tooltip overlay, never a duplicate subtitle word")
assert(bindings["MBTN_LEFT"], "left-click binding missing")
assert(bindings["ctrl+alt+e"], "extension toggle key binding missing")
assert(bindings["ctrl+alt+LEFT"], "previous-word key binding missing")
assert(bindings["ctrl+alt+RIGHT"], "next-word key binding missing")
assert(bindings["ctrl+alt+u"], "next-unknown-morph key binding missing")
assert(bindings["ctrl+alt+shift+u"], "previous-unknown-morph key binding missing")
assert(messages["select-next-unknown"], "next-unknown-morph script message missing")
assert(messages["select-previous-unknown"], "previous-unknown-morph script message missing")
assert(bindings["ctrl+alt+d"], "dictionary key binding missing")
assert(bindings["ctrl+alt+g"], "configured lemma dictionary key binding missing")
assert(messages["show-lemma-dictionary"], "lemma dictionary script message missing")
assert(bindings["ctrl+alt+ENTER"], "keyboard activate-left binding missing")
assert(bindings["ctrl+alt+shift+ENTER"], "keyboard activate-right binding missing")
assert(bindings["ctrl+alt+a"], "phrase-only action binding missing")
assert(bindings["ctrl+alt+b"], "morph-dependent action binding missing")

-- A phrase-only action must run without a hovered or keyboard-selected morph.
-- With no morph under the pointer, it receives the full current subtitle cue.
mouse = {x = 20, y = 20, hover = true}
observers["mouse-pos"]("mouse-pos", mouse)
local before_phrase_action = #commands
bindings["ctrl+alt+a"]()
assert(#commands == before_phrase_action + 1, "phrase-only action should run without morph selection")
local phrase_action = commands[#commands]
assert(phrase_action.args[5] == "", "phrase-only action should receive an empty surface word")
assert(phrase_action.args[6] == "Was ist?", "phrase-only action should receive the active cue text")
assert(phrase_action.args[7] == "", "phrase-only action should receive an empty lemma")

-- An action that references $lemma must still require a selected/hovered morph.
local before_morph_action = #commands
bindings["ctrl+alt+b"]()
assert(#commands == before_morph_action, "lemma-dependent action must not run without a morph")

-- Keyboard selection cycles in reading order and publishes a style override
-- for the existing main-highlighter segment; no duplicate word is rendered.
bindings["ctrl+alt+RIGHT"]()
local selection = properties["user-data/ankimorphs/selection"]
assert(selection.active and selection.segment_index == 1, "first next should select the first highlighted morph")
assert(selection.color == nil and selection.outline_color == "&HFFFFFF&",
  "default selection should preserve the AnkiMorphs foreground and apply only its white outline")
assert(overlays[1].data ~= "", "auto-dictionary on general navigation should show the selected morph")
bindings["ctrl+alt+RIGHT"]()
bindings["ctrl+alt+LEFT"]()
selection = properties["user-data/ankimorphs/selection"]
assert(selection.active and selection.segment_index == 1, "previous should return to first highlighted morph")
bindings["ctrl+alt+RIGHT"]()
selection = properties["user-data/ankimorphs/selection"]
assert(selection.active and selection.segment_index == 3, "next key should select the second highlighted morph")
assert(selection.generation == cue.generation, "selection must be associated with the current cue generation")
option_state.selection_color = "&HFF0000&"
bindings["ctrl+alt+LEFT"]()
selection = properties["user-data/ankimorphs/selection"]
assert(selection.color == "&HFF0000&", "a configured selection_color should be sent as a foreground override")
option_state.selection_color = ""
bindings["ctrl+alt+RIGHT"]()
local before_selected_morph_action = #commands
bindings["ctrl+alt+b"]()
local morph_action = commands[before_selected_morph_action + 1]
assert(morph_action.args[5] == "ist", "lemma-dependent action should receive the selected surface word")
assert(morph_action.args[7] == "sein", "lemma-dependent action should receive the selected lemma")
bindings["ctrl+alt+d"]()
assert(overlays[1].data:find("Was", 1, true) or overlays[1].data:find("ist", 1, true), "dictionary shortcut should show a tooltip")
local commands_before_lemma_lookup = #commands
bindings["ctrl+alt+g"]()
local lemma_lookup = commands[commands_before_lemma_lookup + 1]
assert(lemma_lookup.args[1] == "dict", "lemma lookup should invoke dictd client")
assert(lemma_lookup.args[#lemma_lookup.args] == "sein", "lemma lookup must query only the selected morph's lemma")
assert(overlays[1].data:find("Lemma: sein", 1, true), "lemma lookup tooltip should identify the queried lemma")

bindings["ctrl+alt+ENTER"]()
local keyboard_action = commands[#commands]
assert(keyboard_action.args[1] == "/bin/sh", "keyboard action should run through /bin/sh")
assert(keyboard_action.args[5] == "ist", "keyboard action should pass the selected surface word")
assert(keyboard_action.args[6] == "Was ist?", "keyboard action should pass the containing phrase")
assert(keyboard_action.args[7] == "sein", "keyboard action should pass the spaCy lemma")
assert(keyboard_action.args[3]:find("word=$1", 1, true), "action wrapper should define $word")
assert(keyboard_action.args[3]:find("phrase=$2", 1, true), "action wrapper should define $phrase")
assert(keyboard_action.args[3]:find("lemma=$3", 1, true), "action wrapper should define $lemma")
assert(keyboard_action.args[3]:find("export word phrase lemma", 1, true), "named variables should be exported")

-- Mouse clicks still target the word under the pointer, independently of the
-- keyboard selection.
mouse = {x = 400, y = 530, hover = true}
observers["mouse-pos"]("mouse-pos", mouse)
bindings["MBTN_LEFT"]()
local action = commands[#commands]
assert(action.args[1] == "/bin/sh")
assert(action.args[4] == "ankimorphs-dict")
assert(action.args[5] == "Was")
assert(action.args[6] == "Was ist?")
assert(action.args[7] == "was")
-- Re-open the selected morph tooltip so the geometry-refresh assertion below
-- exercises the intended same-cue tooltip preservation path.
bindings["ctrl+alt+g"]()

-- A dimensions-only update for the same cue must preserve the selected word
-- and keep its already-open dictionary tooltip visible/repositioned.
local resized_cue = {
  active = true, generation = cue.generation, text = cue.text, width = 1280, height = 720,
  font_size = cue.font_size, bottom_margin = cue.bottom_margin, font_name = cue.font_name,
  segments = cue.segments,
}
observers["user-data/ankimorphs/current-cue"]("user-data/ankimorphs/current-cue", resized_cue)
local resized_selection = properties["user-data/ankimorphs/selection"]
assert(resized_selection.active and resized_selection.segment_index == 3,
  "same-generation geometry refresh must preserve the selected morph")
assert(overlays[1].data ~= "", "same-generation resize must preserve and reposition an open tooltip")

-- Unknown-only navigation skips known/learning statuses. When a boundary is
-- crossed, it clears selection; the following keypress starts at the opposite
-- end. The same rule applies to previous-unknown.
local unknown_cue = {
  active = true, generation = cue.generation, text = cue.text, width = resized_cue.width,
  height = resized_cue.height, font_size = cue.font_size,
  bottom_margin = cue.bottom_margin, font_name = cue.font_name,
  segments = {
    {text = "Was", status = "unknown", lemma = "was"},
    {text = " ", status = "normal", lemma = ""},
    {text = "ist", status = "learning", lemma = "sein"},
    {text = "?", status = "normal", lemma = ""},
  },
}
observers["user-data/ankimorphs/current-cue"]("user-data/ankimorphs/current-cue", unknown_cue)
assert(properties["user-data/ankimorphs/selection"].segment_index == 3,
  "same-cue status refresh should preserve the currently selected learning morph")
option_state.auto_dictionary_on_morph_navigation = false
bindings["ctrl+alt+u"]()
selection = properties["user-data/ankimorphs/selection"]
assert(selection.active == false,
  "next-unknown beyond the last unknown should clear selection instead of wrapping")
assert(overlays[1].data == "", "unknown navigation should not auto-open dict when its toggle is false")
option_state.auto_dictionary_on_unknown_navigation = true
bindings["ctrl+alt+u"]()
selection = properties["user-data/ankimorphs/selection"]
assert(selection.active and selection.segment_index == 1,
  "next-unknown after clearing should start at the first unknown morph")
assert(overlays[1].data ~= "", "auto-dictionary on unknown navigation should show the unknown morph")
bindings["ctrl+alt+u"]()
selection = properties["user-data/ankimorphs/selection"]
assert(selection.active == false,
  "next-unknown at the final unknown morph should clear selection")
bindings["ctrl+alt+u"]()
assert(properties["user-data/ankimorphs/selection"].segment_index == 1,
  "next-unknown after boundary clearing should restart at the first unknown")
bindings["ctrl+alt+shift+u"]()
selection = properties["user-data/ankimorphs/selection"]
assert(selection.active == false,
  "previous-unknown before the first unknown should clear selection")
bindings["ctrl+alt+shift+u"]()
selection = properties["user-data/ankimorphs/selection"]
assert(selection.active and selection.segment_index == 1,
  "previous-unknown after clearing should start at the last unknown morph")

-- A cue with no unknown morphs must not move or clear the current selection.
observers["user-data/ankimorphs/current-cue"]("user-data/ankimorphs/current-cue", resized_cue)
local selection_before_no_unknown = properties["user-data/ankimorphs/selection"].segment_index
bindings["ctrl+alt+u"]()
selection = properties["user-data/ankimorphs/selection"]
assert(selection.active and selection.segment_index == selection_before_no_unknown,
  "unknown navigation should preserve selection when the cue contains no unknown morphs")

-- General navigation also clears at either boundary and restarts on the next
-- press, rather than wrapping immediately.
bindings["ctrl+alt+RIGHT"]()
assert(properties["user-data/ankimorphs/selection"].segment_index == 3,
  "general next should move to the second highlighted morph")
bindings["ctrl+alt+RIGHT"]()
assert(properties["user-data/ankimorphs/selection"].active == false,
  "general next beyond the final morph should clear selection")
bindings["ctrl+alt+RIGHT"]()
assert(properties["user-data/ankimorphs/selection"].segment_index == 1,
  "general next after clearing should restart at the first morph")
bindings["ctrl+alt+LEFT"]()
assert(properties["user-data/ankimorphs/selection"].active == false,
  "general previous before the first morph should clear selection")
bindings["ctrl+alt+LEFT"]()
assert(properties["user-data/ankimorphs/selection"].segment_index == 3,
  "general previous after clearing should restart at the last morph")

-- A new cue should not auto-select anything by default. When enabled, it
-- selects the first item eligible for unknown navigation. The learning toggle
-- controls whether a leading fresh/learning morph is eligible too.
local mixed_cue = {
  active = true, generation = cue.generation + 1, text = "ist Was?", width = resized_cue.width,
  height = resized_cue.height, font_size = cue.font_size,
  bottom_margin = cue.bottom_margin, font_name = cue.font_name,
  segments = {
    {text = "ist", status = "learning", lemma = "sein"},
    {text = " ", status = "normal", lemma = ""},
    {text = "Was", status = "unknown", lemma = "was"},
    {text = "?", status = "normal", lemma = ""},
  },
}
local function next_cue_generation(source)
  local copy = {}
  for key, value in pairs(source) do copy[key] = value end
  copy.generation = source.generation + 1
  return copy
end
observers["user-data/ankimorphs/current-cue"]("user-data/ankimorphs/current-cue", mixed_cue)
assert(properties["user-data/ankimorphs/selection"].active == false,
  "new cues must not auto-select an unknown morph when the option is disabled")

option_state.auto_select_first_unknown_on_new_cue = true
option_state.include_learning_in_unknown_navigation = false
mixed_cue = next_cue_generation(mixed_cue)
observers["user-data/ankimorphs/current-cue"]("user-data/ankimorphs/current-cue", mixed_cue)
selection = properties["user-data/ankimorphs/selection"]
assert(selection.active and selection.segment_index == 3,
  "new-cue auto-selection should choose the first strict unknown morph")

-- Same-generation geometry refreshes must preserve that selection and must
-- not rerun the auto-selection path.
local mixed_resized = {
  active = true, generation = mixed_cue.generation, text = mixed_cue.text,
  width = 1280, height = 720, font_size = mixed_cue.font_size,
  bottom_margin = mixed_cue.bottom_margin, font_name = mixed_cue.font_name,
  segments = mixed_cue.segments,
}
observers["user-data/ankimorphs/current-cue"]("user-data/ankimorphs/current-cue", mixed_resized)
selection = properties["user-data/ankimorphs/selection"]
assert(selection.active and selection.segment_index == 3,
  "geometry-only updates must preserve the selected unknown morph")

option_state.include_learning_in_unknown_navigation = true
mixed_cue = next_cue_generation(mixed_cue)
observers["user-data/ankimorphs/current-cue"]("user-data/ankimorphs/current-cue", mixed_cue)
selection = properties["user-data/ankimorphs/selection"]
assert(selection.active and selection.segment_index == 1,
  "new-cue auto-selection should include the first learning morph when configured")

option_state.include_learning_in_unknown_navigation = false
mixed_cue = next_cue_generation(mixed_cue)
observers["user-data/ankimorphs/current-cue"]("user-data/ankimorphs/current-cue", mixed_cue)
selection = properties["user-data/ankimorphs/selection"]
assert(selection.active and selection.segment_index == 3,
  "new-cue auto-selection should return to strict unknown morphs when learning inclusion is disabled")

-- The companion toggle hides its tooltip and clears its in-place selection
-- without disabling the main AnkiMorphs highlighter.
bindings["ctrl+alt+e"]()
assert(overlays[1].data == "", "disabling should hide the dictionary tooltip")
assert(properties["user-data/ankimorphs/selection"].active == false, "disabling should clear main-overlay selection")
local commands_before_disabled_action = #commands
bindings["ctrl+alt+d"]()
bindings["MBTN_LEFT"]()
bindings["ctrl+alt+RIGHT"]()
assert(#commands == commands_before_disabled_action, "disabled companion must not run dictionary/actions")
assert(properties["user-data/ankimorphs/selection"].active == false, "disabled companion must ignore navigation")
bindings["ctrl+alt+e"]()
assert(bindings["ctrl+alt+RIGHT"], "navigation binding should remain registered after re-enable")
bindings["ctrl+alt+RIGHT"]()
assert(properties["user-data/ankimorphs/selection"].active == true, "re-enabled companion should publish selection again")
print("dictionary hover, all/unknown navigation, fresh-morph inclusion, new-cue auto-selection, auto dictionary options, selected styling, phrase-only actions, morph-dependent actions, and extension toggle: OK")
