local observers, bindings, messages, events = {}, {}, {}, {}
local properties = {}
local overlays = {}
local pending_request
local timers = {}
local osd_width, osd_height = 800, 600
local analyze_requests = 0
local mp = {}

function mp.get_script_directory() return arg[2] end
function mp.create_osd_overlay()
  local overlay = { data = "" }
  function overlay:update() end
  overlays[#overlays + 1] = overlay
  return overlay
end
function mp.get_osd_size() return osd_width, osd_height, 1 end
function mp.get_time() return 10 end
function mp.get_property(name, default)
  if name == "sub-text" or name == "secondary-sub-text" or name == "path" then return "" end
  return default or ""
end
function mp.get_property_native(name)
  if name == "sub-visibility" or name == "secondary-sub-visibility" then return true end
  return properties[name]
end
function mp.set_property_native(name, value) properties[name] = value end
function mp.observe_property(name, _kind, callback) observers[name] = callback end
function mp.add_key_binding(key, name, callback) bindings[key] = callback; bindings[name] = callback end
function mp.register_script_message(name, callback) messages[name] = callback end
function mp.register_event(name, callback) events[name] = callback end
function mp.add_timeout(_, callback)
  local timer = { callback = callback }
  function timer:kill() self.killed = true end
  timers[#timers + 1] = timer
  return timer
end
function mp.osd_message() end
function mp.command_native(command)
  if command[1] == "escape-ass" then return command[2] end
  if command[1] == "expand-path" then return command[2] end
  return nil
end
function mp.command_native_async(request, callback)
  if request.args[3] == "request" then
    local response
    if pending_request.action == "list" then
      response = { ok = true, models = { "de_core_news_lg" }, priority_files = {},
        evaluation = "inflection", known_threshold_days = 21, disk_cache_enabled = false }
    elseif pending_request.action == "analyze" then
      analyze_requests = analyze_requests + 1
      response = { ok = true, segments = {
        { text = "Was", status = "known", lemma = "was" },
        { text = " ", status = "normal", lemma = "" },
        { text = "ist?", status = "normal", lemma = "sein" },
      } }
    else
      response = { ok = true }
    end
    callback(true, { status = 0, stdout = "encoded", stderr = "" }, nil)
    return
  end
  if callback then callback(true, { status = 0, stdout = "", stderr = "" }, nil) end
end

package.preload["mp"] = function() return mp end
package.preload["mp.msg"] = function() return { info=function() end, warn=function() end,
  error=function(value) error(value) end } end
package.preload["mp.utils"] = function()
  return {
    split_path = function(path) return path:match("^(.*)/[^/]+$") end,
    format_json = function(value) pending_request = value; return "encoded" end,
    parse_json = function() 
      if pending_request.action == "list" then
        return { ok = true, models = { "de_core_news_lg" }, priority_files = {},
          evaluation = "inflection", known_threshold_days = 21, disk_cache_enabled = false }
      end
      if pending_request.action == "analyze" then
        return { ok = true, segments = {
          { text = "Was", status = "known", lemma = "was" },
          { text = " ", status = "normal", lemma = "" },
          { text = "ist?", status = "normal", lemma = "sein" },
        } }
      end
      return { ok = true }
    end,
  }
end
package.preload["mp.options"] = function() return { read_options = function() end } end
package.preload["mp.input"] = function() return {} end

local chunk, err = loadfile(arg[1])
assert(chunk, err)
chunk()

-- The startup list request makes the backend ready; now feed a subtitle cue.
assert(observers["sub-text"], "main highlighter did not register sub-text observer")
observers["sub-text"]("sub-text", "Was ist?")
assert(#overlays == 1, "main highlighter should own one subtitle overlay")
local base = overlays[1].data
assert(base:find("Was", 1, true), "base highlighter did not render subtitle text")
local cue = properties["user-data/ankimorphs/current-cue"]
assert(cue and cue.active and cue.generation, "main highlighter did not publish current cue metadata")

observers["user-data/ankimorphs/selection"]("user-data/ankimorphs/selection", {
  active = true, generation = cue.generation, segment_index = 1,
  color = "&HFF0000&", outline_color = "&HFFFFFF&", outline = 3,
})
local selected = overlays[1].data
assert(selected:find("{\\1c&HFF0000&\\3c&HFFFFFF&\\bord3.00}Was", 1, true),
  "main overlay did not recolor the existing segment with selected style")
local _, occurrences = selected:gsub("Was", "")
assert(occurrences == 1, "selection must not render a duplicate word")
assert(#overlays == 1, "selection must reuse the main overlay")

observers["user-data/ankimorphs/selection"]("user-data/ankimorphs/selection", { active = false })
local restored = overlays[1].data
assert(restored:find("{\\1c&H008000&}Was", 1, true), "clearing selection should restore the AnkiMorphs status color")
assert(not restored:find("\\3c&HFFFFFF&\\bord3.00", 1, true), "selection outline should disappear when selection clears")
-- With no selection foreground supplied, preserve the segment's status color
-- and apply only the requested outline.
observers["user-data/ankimorphs/selection"]("user-data/ankimorphs/selection", {
  active = true, generation = cue.generation, segment_index = 1,
  outline_color = "&HFFFFFF&", outline = 3,
})
local outlined_only = overlays[1].data
assert(outlined_only:find("{\\1c&H008000&\\3c&HFFFFFF&\\bord3.00}Was", 1, true),
  "missing selection color should retain the original known-morph foreground")
assert(not outlined_only:find("\\1c&HFF0000&", 1, true),
  "missing selection color must not force the default blue foreground")
-- An explicit selection color must still override the morph's native status color.
observers["user-data/ankimorphs/selection"]("user-data/ankimorphs/selection", {
  active = true, generation = cue.generation, segment_index = 1,
  color = "&HFF0000&", outline_color = "&HFFFFFF&", outline = 3,
})
local explicitly_colored = overlays[1].data
assert(explicitly_colored:find("{\\1c&HFF0000&\\3c&HFFFFFF&\\bord3.00}Was", 1, true),
  "explicit selection color should override the original foreground")

-- A resize/fullscreen transition must redraw the existing cue at the new OSD
-- dimensions without re-running spaCy or dropping the in-place selection.
assert(observers["osd-dimensions"], "main highlighter must observe OSD dimensions")
local analyses_before_resize = analyze_requests
local generation_before_resize = cue.generation
osd_width, osd_height = 1280, 720
observers["osd-dimensions"]("osd-dimensions", {w = osd_width, h = osd_height, par = 1})
assert(#timers > 0, "resize observer should schedule a debounced redraw")
timers[#timers].callback()
assert(overlays[1].res_x == 1280 and overlays[1].res_y == 720,
  "main overlay resolution should follow the resized OSD")
assert(overlays[1].data:find("{\\1c&HFF0000&\\3c&HFFFFFF&\\bord3.00}Was", 1, true),
  "resize redraw should preserve selected-segment recoloring")
assert(analyze_requests == analyses_before_resize,
  "resize redraw must reuse the analyzed segments, not call spaCy again")
local resized_cue = properties["user-data/ankimorphs/current-cue"]
assert(resized_cue.generation == generation_before_resize,
  "resize redraw must preserve cue generation for companion selection")
assert(resized_cue.width == 1280 and resized_cue.height == 720,
  "companion must receive updated dimensions")

print("main highlighter in-place selection recoloring and restoration: OK")
