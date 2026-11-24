-- Companion dictionary / interaction script for the AnkiMorphs mpv highlighter.
-- Reads the currently rendered cue from user-data/ankimorphs/current-cue.
-- Dictionary lookups use dict(1); configured actions receive the named shell
-- variables $word, $lemma, and $phrase without interpolating subtitle text into
-- the command source.

local mp = require 'mp'
local msg = require 'mp.msg'
local options = require 'mp.options'

local o = {
    dict_program = "dict",
    dict_database = "deu-eng",
    dict_host = "",
    dict_port = "",
    hover_tooltip = true,
    hover_delay = 0.12,
    tooltip_font_size = 21,
    tooltip_max_lines = 9,
    tooltip_max_chars = 440,
    hit_width_scale = 1.0,
    -- Toggle this companion extension without affecting AnkiMorphs highlighting.
    toggle_extension_key = "ctrl+alt+e",
    -- Keyboard-only navigation over the currently highlighted morphs.
    select_previous_key = "ctrl+alt+LEFT",
    select_next_key = "ctrl+alt+RIGHT",
    select_next_unknown_key = "ctrl+alt+u",
    select_previous_unknown_key = "ctrl+alt+shift+u",
    -- When enabled, unknown-only navigation also includes learning (fresh) morphs.
    include_learning_in_unknown_navigation = false,
    -- Select the first unknown-navigation morph whenever a genuinely new cue appears.
    auto_select_first_unknown_on_new_cue = false,
    -- Automatically open the dictd tooltip on navigation. Keep these off by default.
    auto_dictionary_on_morph_navigation = false,
    auto_dictionary_on_unknown_navigation = false,
    show_dictionary_key = "ctrl+alt+d",
    show_lemma_dictionary_key = "ctrl+alt+l",
    activate_left_key = "ctrl+alt+ENTER",
    activate_right_key = "ctrl+alt+shift+ENTER",
    selection_color = "",               -- Empty: keep the original AnkiMorphs status color
    selection_outline_color = "&HFFFFFF&",
    selection_outline = 3,
    left_click_key = "MBTN_LEFT",
    right_click_key = "MBTN_RIGHT",
    left_click_script = "",
    right_click_script = "",
    action_1_key = "",
    action_1_script = "",
    action_2_key = "",
    action_2_script = "",
    action_3_key = "",
    action_3_script = "",
    action_4_key = "",
    action_4_script = "",
    action_5_key = "",
    action_5_script = "",
    action_6_key = "",
    action_6_script = "",
}
options.read_options(o, "ankimorphs-dict")

local cue = nil
local hover = nil
local hover_timer = nil
local hover_serial = 0
local targets = {}
local selected_index = nil
local selected_target = nil
local extension_enabled = true
local dictionary_cache = {}
local dictionary_pending = {}
local tooltip_text = nil
local tooltip_anchor_segment_index = nil
local tooltip_overlay = mp.create_osd_overlay("ass-events")
local show_dictionary_for_target = nil

local function trim(value)
    return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function hide_tooltip()
    tooltip_text = nil
    tooltip_anchor_segment_index = nil
    tooltip_overlay.data = ""
    tooltip_overlay:update()
end

local function hide_selection()
    selected_index = nil
    selected_target = nil
    -- The main highlighter owns the subtitle overlay. Clear its in-place style
    -- override instead of managing a second text overlay here.
    pcall(mp.set_property_native, "user-data/ankimorphs/selection", { active = false })
end

local function ass_escape(value)
    value = tostring(value or "")
    value = value:gsub("\\", "\\\\")
    value = value:gsub("{", "\\{"):gsub("}", "\\}")
    value = value:gsub("\r\n", "\n"):gsub("\r", "\n")
    return value:gsub("\n", "\\N")
end

-- Approximate Noto Sans advances for mouse hit-testing. mpv/libass does not
-- expose glyph extents to Lua; this deliberately favors robust word selection
-- over pretending character count equals rendered width.
local function codepoints(value)
    local result = {}
    local i = 1
    while i <= #value do
        local b1 = value:byte(i)
        local length, cp
        if b1 < 0x80 then
            length, cp = 1, b1
        elseif b1 < 0xE0 then
            length = 2
            cp = (b1 - 0xC0) * 0x40 + ((value:byte(i + 1) or 0x80) - 0x80)
        elseif b1 < 0xF0 then
            length = 3
            cp = (b1 - 0xE0) * 0x1000
                + ((value:byte(i + 1) or 0x80) - 0x80) * 0x40
                + ((value:byte(i + 2) or 0x80) - 0x80)
        else
            length = 4
            cp = (b1 - 0xF0) * 0x40000
                + ((value:byte(i + 1) or 0x80) - 0x80) * 0x1000
                + ((value:byte(i + 2) or 0x80) - 0x80) * 0x40
                + ((value:byte(i + 3) or 0x80) - 0x80)
        end
        result[#result + 1] = { cp = cp, first = i, last = math.min(#value, i + length - 1) }
        i = i + length
    end
    return result
end

local narrow = {
    [string.byte("i")] = true, [string.byte("l")] = true,
    [string.byte("I")] = true, [string.byte("j")] = true,
    [string.byte("f")] = true, [string.byte("t")] = true,
    [string.byte("r")] = true, [string.byte("!")] = true,
    [string.byte("|")] = true, [string.byte(".")] = true,
    [string.byte(",")] = true, [string.byte(":")] = true,
    [string.byte(";")] = true, [string.byte("'")] = true,
    [string.byte("`")] = true,
}
local wide = {
    [string.byte("M")] = true, [string.byte("W")] = true,
    [string.byte("m")] = true, [string.byte("w")] = true,
    [string.byte("@")] = true,
}

local function glyph_factor(cp)
    if cp == 9 or cp == 32 then return 0.30 end
    if cp < 128 then
        if narrow[cp] then return 0.27 end
        if wide[cp] then return 0.86 end
        if cp >= 48 and cp <= 57 then return 0.56 end
        if cp >= 65 and cp <= 90 then return 0.65 end
        if cp >= 97 and cp <= 122 then return 0.53 end
        return 0.36
    end
    if (cp >= 0x0300 and cp <= 0x036F)
        or (cp >= 0x1AB0 and cp <= 0x1AFF)
        or (cp >= 0x1DC0 and cp <= 0x1DFF) then
        return 0
    end
    if cp >= 0x2E80 or (cp >= 0x1F000 and cp <= 0x1FAFF) then return 1.0 end
    return 0.58
end

local function text_width(value, font_size)
    local width = 0
    for _, item in ipairs(codepoints(value)) do
        width = width + glyph_factor(item.cp) * font_size
    end
    return width * (tonumber(o.hit_width_scale) or 1.0)
end

local function split_lines(text)
    local lines = {}
    local start_at = 1
    local i = 1
    while i <= #text do
        if text:sub(i, i) == "\n" then
            lines[#lines + 1] = { first = start_at, last = i - 1, text = text:sub(start_at, i - 1) }
            start_at = i + 1
        end
        i = i + 1
    end
    lines[#lines + 1] = { first = start_at, last = #text, text = text:sub(start_at) }
    return lines
end

local function sentence_for(text, word_first, word_last)
    local separators = { ".", "!", "?", "…", "。", "！", "？" }
    local sentence_first = 1
    local search_from = 1
    while true do
        local best_first, best_last
        for _, separator in ipairs(separators) do
            local a, b = text:find(separator, search_from, true)
            if a and (not best_first or a < best_first) then
                best_first, best_last = a, b
            end
        end
        if not best_first or best_first >= word_first then break end
        sentence_first = best_last + 1
        search_from = best_last + 1
    end
    local sentence_last = #text
    local best_first, best_last
    for _, separator in ipairs(separators) do
        local a, b = text:find(separator, word_last + 1, true)
        if a and (not best_first or a < best_first) then
            best_first, best_last = a, b
        end
    end
    if best_first then sentence_last = best_last end
    return trim(text:sub(sentence_first, sentence_last))
end

local function cue_geometry()
    if type(cue) ~= "table" or cue.active ~= true or type(cue.segments) ~= "table" then
        return nil
    end
    local text = tostring(cue.text or "")
    local width = tonumber(cue.width) or select(1, mp.get_osd_size()) or 0
    local height = tonumber(cue.height) or select(2, mp.get_osd_size()) or 0
    local font_size = tonumber(cue.font_size) or 38
    local bottom_margin = tonumber(cue.bottom_margin) or 48
    local line_height = font_size * 1.22
    if width <= 0 or height <= 0 or text == "" then return nil end

    local lines = split_lines(text)
    local line_by_byte = {}
    for index, line in ipairs(lines) do
        line.width = text_width(line.text, font_size)
        if line.width > width - 24 then
            -- mpv/libass may wrap this line automatically. Without libass glyph
            -- extents, don't guess at a word's position.
            return nil
        end
        for byte_index = line.first, line.last do
            line_by_byte[byte_index] = index
        end
    end
    return {
        text = text, width = width, height = height, font_size = font_size,
        bottom_margin = bottom_margin, line_height = line_height,
        lines = lines, line_by_byte = line_by_byte,
    }
end

local function build_targets()
    local geometry = cue_geometry()
    if not geometry then return {} end
    local result = {}
    local byte_offset = 1
    for segment_index, segment in ipairs(cue.segments) do
        local segment_text = tostring(segment.text or "")
        local segment_first = byte_offset
        local segment_last = segment_first + #segment_text - 1
        byte_offset = segment_last + 1

        if segment.status and segment.status ~= "normal" and segment_text ~= "" then
            local leading = #(segment_text:match("^%s*") or "")
            local surface = trim(segment_text)
            local first = segment_first + leading
            local last = first + #surface - 1
            local line_index = geometry.line_by_byte[first]
            if surface ~= "" and line_index and geometry.line_by_byte[last] == line_index then
                local line = geometry.lines[line_index]
                local line_top = geometry.height - geometry.bottom_margin
                    - (#geometry.lines - line_index + 1) * geometry.line_height
                local prefix = geometry.text:sub(line.first, first - 1)
                local left = geometry.width / 2 - line.width / 2
                    + text_width(prefix, geometry.font_size)
                local lemma = trim(segment.lemma or "")
                result[#result + 1] = {
                    word = surface,
                    lemma = lemma,
                    phrase = sentence_for(geometry.text, first, last),
                    status = segment.status,
                    segment_index = segment_index,
                    x = left,
                    y = line_top,
                    width = text_width(surface, geometry.font_size),
                    font_size = geometry.font_size,
                    start_byte = first,
                    end_byte = last,
                }
            end
        end
    end
    return result
end

local function hit_test(mouse)
    if not extension_enabled then return nil end
    if type(mouse) == "table" and mouse.hover == false then return nil end
    if type(mouse) ~= "table" or type(mouse.x) ~= "number" or type(mouse.y) ~= "number" then
        return nil
    end
    for _, target in ipairs(targets) do
        local line_height = target.font_size * 1.22
        if mouse.y >= target.y and mouse.y <= target.y + line_height
            and mouse.x >= target.x and mouse.x <= target.x + target.width then
            local result = {}
            for key, value in pairs(target) do result[key] = value end
            result.x, result.y = mouse.x, mouse.y
            return result
        end
    end
    return nil
end

local function render_selection()
    if not extension_enabled or not selected_target or type(cue) ~= "table" then
        pcall(mp.set_property_native, "user-data/ankimorphs/selection", { active = false })
        return
    end
    -- Recolor the existing AnkiMorphs segment in its main overlay. No duplicate
    -- word is rendered by the companion script.
    local selection = {
        active = true,
        generation = tonumber(cue.generation),
        segment_index = tonumber(selected_target.segment_index),
        outline_color = tostring(o.selection_outline_color),
        outline = math.max(0, tonumber(o.selection_outline) or 3),
    }
    -- An empty/omitted selection_color means "outline only": the main
    -- highlighter keeps the segment's original AnkiMorphs status foreground.
    local selection_color = trim(o.selection_color)
    if selection_color ~= "" then
        selection.color = selection_color
    end
    pcall(mp.set_property_native, "user-data/ankimorphs/selection", selection)
end

local function deselect_target(message)
    selected_index = nil
    selected_target = nil
    hover_serial = hover_serial + 1
    if hover_timer then hover_timer:kill(); hover_timer = nil end
    hide_tooltip()
    hide_selection()
    if message and message ~= "" then mp.osd_message(message, 0.9) end
end

local function select_target(index, navigation_kind, position, total)
    if not extension_enabled then return end
    if index < 1 or index > #targets or not targets[index] then
        deselect_target()
        return
    end

    selected_index = index
    selected_target = targets[index]
    -- Do not let an old asynchronous hover lookup replace the keyboard-selected
    -- word's tooltip after the user has moved the selection.
    hover_serial = hover_serial + 1
    if hover_timer then hover_timer:kill(); hover_timer = nil end
    render_selection()
    hide_tooltip()

    if navigation_kind == "unknown" then
        mp.osd_message(string.format(
            "Unknown morph %d/%d  %s", position or 1, total or 1, selected_target.word
        ), 1)
        if o.auto_dictionary_on_unknown_navigation and show_dictionary_for_target then
            show_dictionary_for_target(selected_target, true)
        end
    else
        mp.osd_message(string.format(
            "%d/%d  %s", position or index, total or #targets, selected_target.word
        ), 1)
        if o.auto_dictionary_on_morph_navigation and show_dictionary_for_target then
            show_dictionary_for_target(selected_target, true)
        end
    end
end

local function is_unknown_navigation_target(target)
    local status = tostring(target.status or ""):lower()
    return status == "unknown"
        or (o.include_learning_in_unknown_navigation and status == "learning")
end

local function navigate_morphs(direction, unknown_only)
    if not extension_enabled then return end
    if #targets == 0 then targets = build_targets() end
    if #targets == 0 then
        deselect_target("AnkiMorphs dictionary: no highlighted words in this subtitle")
        return
    end

    local eligible = {}
    for index, target in ipairs(targets) do
        if not unknown_only or is_unknown_navigation_target(target) then
            eligible[#eligible + 1] = index
        end
    end

    if #eligible == 0 then
        if unknown_only then
            local category = o.include_learning_in_unknown_navigation
                and "unknown or learning morphs" or "unknown morphs"
            mp.osd_message("AnkiMorphs dictionary: no " .. category .. " in this subtitle", 2)
        else
            deselect_target("AnkiMorphs dictionary: no highlighted words in this subtitle")
        end
        return
    end

    local candidate_index, candidate_position
    if selected_index == nil then
        -- A cleared selection starts a fresh traversal at the appropriate end.
        candidate_position = direction > 0 and 1 or #eligible
        candidate_index = eligible[candidate_position]
    elseif direction > 0 then
        for position, target_index in ipairs(eligible) do
            if target_index > selected_index then
                candidate_index = target_index
                candidate_position = position
                break
            end
        end
    else
        for position = #eligible, 1, -1 do
            local target_index = eligible[position]
            if target_index < selected_index then
                candidate_index = target_index
                candidate_position = position
                break
            end
        end
    end

    if not candidate_index then
        local kind = unknown_only
            and (o.include_learning_in_unknown_navigation and "unknown or learning morphs" or "unknown morphs")
            or "highlighted morphs"
        deselect_target("End of " .. kind .. "; selection cleared")
        return
    end

    select_target(candidate_index, unknown_only and "unknown" or "morph",
        candidate_position, #eligible)
end

local function select_next()
    navigate_morphs(1, false)
end

local function select_previous()
    navigate_morphs(-1, false)
end

local function select_next_unknown()
    navigate_morphs(1, true)
end

local function select_previous_unknown()
    navigate_morphs(-1, true)
end

local function wrap_and_limit(value)
    value = tostring(value or "")
    value = value:gsub("\27%[[0-9;]*m", "")
    value = value:gsub("\r\n", "\n"):gsub("\r", "\n")
    local max_chars = math.max(20, tonumber(o.tooltip_max_chars) or 440)
    local max_lines = math.max(1, tonumber(o.tooltip_max_lines) or 9)
    local lines = {}
    for source_line in (value .. "\n"):gmatch("(.-)\n") do
        source_line = trim(source_line)
        while #source_line > max_chars do
            local cut = source_line:sub(1, max_chars):match("^.*()%s")
            if not cut or cut < 8 then cut = max_chars end
            lines[#lines + 1] = source_line:sub(1, cut)
            source_line = trim(source_line:sub(cut + 1))
            if #lines >= max_lines then break end
        end
        if source_line ~= "" and #lines < max_lines then lines[#lines + 1] = source_line end
        if #lines >= max_lines then break end
    end
    if #lines == max_lines then
        lines[#lines] = lines[#lines]:sub(1, math.max(1, max_chars - 1)) .. "…"
    end
    if #lines == 0 then return "No dictionary entry found." end
    return table.concat(lines, "\n")
end

local function render_tooltip(value, anchor, force)
    anchor = anchor or hover
    if not extension_enabled or not anchor or not value or (not o.hover_tooltip and not force) then
        hide_tooltip()
        return
    end
    tooltip_text = wrap_and_limit(value)
    tooltip_anchor_segment_index = tonumber(anchor.segment_index)
    local width, height = mp.get_osd_size()
    if not width or not height then return end
    local fs = tonumber(o.tooltip_font_size) or 21
    local lines = 1
    for _ in tooltip_text:gmatch("\n") do lines = lines + 1 end
    local estimate_width = 0
    for line in (tooltip_text .. "\n"):gmatch("(.-)\n") do
        estimate_width = math.max(estimate_width, text_width(line, fs))
    end
    estimate_width = math.min(width - 20, estimate_width + 24)
    local estimate_height = lines * fs * 1.28 + 16
    local x = (anchor.x or 0) + 18
    local y = (anchor.y or 0) + 22
    if x + estimate_width > width - 8 then x = math.max(8, width - estimate_width - 8) end
    if y + estimate_height > height - 8 then y = math.max(8, (anchor.y or 0) - estimate_height - 14) end
    local header = string.format(
        "{\\an7\\q2\\fs%d\\fnNoto Sans\\bord2\\shad1\\1c&HFFFFFF&\\3c&H202020&\\pos(%.1f,%.1f)}",
        fs, x, y
    )
    tooltip_overlay.res_x = width
    tooltip_overlay.res_y = height
    tooltip_overlay.data = header .. ass_escape(tooltip_text)
    tooltip_overlay:update()
end

local function output_is_no_match(value)
    local lower = tostring(value or ""):lower()
    return lower:find("no matches found", 1, true)
        or lower:find("no match", 1, true)
        or lower:find("no database", 1, true)
        or lower:find("no definition found", 1, true)
end

local function dict_lookup(word, lemma, done)
    local query = trim(word)
    if query == "" then done("No dictionary entry found."); return end
    local cache_key = query:lower()
    if dictionary_cache[cache_key] then
        done(dictionary_cache[cache_key])
        return
    end
    if dictionary_pending[cache_key] then
        dictionary_pending[cache_key][#dictionary_pending[cache_key] + 1] = done
        return
    end
    dictionary_pending[cache_key] = { done }

    local args = { tostring(o.dict_program), "-d", tostring(o.dict_database), "--", query }
    if trim(o.dict_host) ~= "" then
        table.insert(args, 2, "-h")
        table.insert(args, 3, tostring(o.dict_host))
    end
    if trim(o.dict_port) ~= "" then
        table.insert(args, 2, "-p")
        table.insert(args, 3, tostring(o.dict_port))
    end

    local function complete(value)
        value = tostring(value or "No dictionary entry found.")
        dictionary_cache[cache_key] = value
        local callbacks = dictionary_pending[cache_key] or {}
        dictionary_pending[cache_key] = nil
        for _, callback in ipairs(callbacks) do pcall(callback, value) end
    end

    mp.command_native_async({
        name = "subprocess",
        args = args,
        capture_stdout = true,
        capture_stderr = true,
        capture_size = 1024 * 1024,
        playback_only = false,
    }, function(success, result, err)
        local output = result and (result.stdout or "") or ""
        local stderr = result and (result.stderr or "") or ""
        if success and result and result.status == 0 and output ~= "" and not output_is_no_match(output) then
            complete(output)
            return
        end

        local fallback = trim(lemma)
        if fallback ~= "" and fallback:lower() ~= query:lower() then
            local fallback_args = { tostring(o.dict_program), "-d", tostring(o.dict_database), "--", fallback }
            if trim(o.dict_host) ~= "" then
                table.insert(fallback_args, 2, "-h")
                table.insert(fallback_args, 3, tostring(o.dict_host))
            end
            if trim(o.dict_port) ~= "" then
                table.insert(fallback_args, 2, "-p")
                table.insert(fallback_args, 3, tostring(o.dict_port))
            end
            mp.command_native_async({
                name = "subprocess", args = fallback_args,
                capture_stdout = true, capture_stderr = true,
                capture_size = 1024 * 1024, playback_only = false,
            }, function(fallback_success, fallback_result)
                local fallback_output = fallback_result and (fallback_result.stdout or "") or ""
                if fallback_success and fallback_result and fallback_result.status == 0
                    and fallback_output ~= "" and not output_is_no_match(fallback_output) then
                    complete("Lemma: " .. fallback .. "\n\n" .. fallback_output)
                else
                    complete(output ~= "" and output or stderr ~= "" and stderr or "No dictionary entry found for " .. query .. ".")
                end
            end)
            return
        end
        complete(output ~= "" and output or stderr ~= "" and stderr or tostring(err or "No dictionary entry found for " .. query .. "."))
    end)
end

show_dictionary_for_target = function(target, require_selected)
    if not extension_enabled or not target then return end
    hover_serial = hover_serial + 1
    local serial = hover_serial
    dict_lookup(target.word, target.lemma, function(result)
        if serial ~= hover_serial then return end
        if require_selected and selected_target ~= target then return end
        render_tooltip(result, target, true)
    end)
end

local function lookup_current_hover(serial)
    if not extension_enabled or not hover or serial ~= hover_serial then return end
    local target = hover
    dict_lookup(target.word, target.lemma, function(result)
        if serial ~= hover_serial or hover ~= target then return end
        render_tooltip(result, target)
    end)
end

local function show_dictionary()
    if not extension_enabled then return end
    local target = selected_target or hover
    if not target then
        mp.osd_message("AnkiMorphs dictionary: select or hover a highlighted word first", 2)
        return
    end
    show_dictionary_for_target(target, selected_target == target)
end

local function show_lemma_dictionary()
    if not extension_enabled then return end
    local target = selected_target or hover
    if not target then
        mp.osd_message("AnkiMorphs dictionary: select or hover a highlighted word first", 2)
        return
    end
    local lemma = trim(target.lemma)
    if lemma == "" then
        mp.osd_message("AnkiMorphs dictionary: no lemma available for this word", 2)
        return
    end

    -- Query the lemma directly. Passing an empty fallback prevents this lookup
    -- from first trying the inflected surface form (unlike show_dictionary).
    hover_serial = hover_serial + 1
    local serial = hover_serial
    dict_lookup(lemma, "", function(result)
        if serial ~= hover_serial then return end
        render_tooltip("Lemma: " .. lemma .. "\n\n" .. result, target, true)
    end)
end

local function update_hover()
    if not extension_enabled then
        hover = nil
        hover_serial = hover_serial + 1
        if hover_timer then hover_timer:kill(); hover_timer = nil end
        hide_tooltip()
        return
    end
    if not o.hover_tooltip then hide_tooltip(); return end
    local mouse = mp.get_property_native("mouse-pos")
    local next_hover = hit_test(mouse)
    if not next_hover then
        hover = nil
        hover_serial = hover_serial + 1
        if hover_timer then hover_timer:kill(); hover_timer = nil end
        hide_tooltip()
        return
    end
    local key = next_hover.word .. "\0" .. next_hover.phrase
    if hover and hover.key == key then
        hover.x, hover.y = next_hover.x, next_hover.y
        if tooltip_text then render_tooltip(tooltip_text) end
        return
    end
    hover_serial = hover_serial + 1
    local serial = hover_serial
    next_hover.key = key
    hover = next_hover
    if hover_timer then hover_timer:kill(); hover_timer = nil end
    hide_tooltip()
    hover_timer = mp.add_timeout(math.max(0, tonumber(o.hover_delay) or 0.12), function()
        hover_timer = nil
        lookup_current_hover(serial)
    end)
end

local function references_shell_variable(script, name)
    -- Accept both $name and ${name}, but don't mistake $word_count for $word.
    if script:find("${" .. name .. "}", 1, true) then return true end
    return script:find("%$" .. name .. "%f[^%w_]") ~= nil
end

local function action_requires_morph(script)
    -- $1 and $3 are the backwards-compatible positional aliases for word and
    -- lemma. $2 is only the phrase, so it must not force morph selection.
    return references_shell_variable(script, "word")
        or references_shell_variable(script, "lemma")
        or script:find("${1}", 1, true) ~= nil
        or script:find("${3}", 1, true) ~= nil
        or script:find("$1", 1, true) ~= nil
        or script:find("$3", 1, true) ~= nil
end

local function run_script(script, action_name, mouse_first)
    if not extension_enabled then return end
    script = trim(script)
    if script == "" then
        mp.osd_message("AnkiMorphs dictionary: no script configured for " .. action_name, 2)
        return
    end

    local mouse = mp.get_property_native("mouse-pos")
    local mouse_target = hit_test(mouse)
    local selected
    if mouse_first then
        selected = mouse_target
    else
        selected = selected_target or hover or mouse_target
    end

    local requires_morph = action_requires_morph(script)
    if requires_morph and not selected then
        mp.osd_message("AnkiMorphs dictionary: select or hover a highlighted word first", 2)
        return
    end

    -- Phrase-only actions do not need a morph selection. When the pointer is
    -- over a highlighted morph (or one is keyboard-selected), use its sentence;
    -- otherwise pass the complete active subtitle cue as $phrase.
    local phrase = selected and selected.phrase or ""
    if not selected and type(cue) == "table" and cue.active == true then
        phrase = trim(cue.text or "")
    end
    local word = selected and selected.word or ""
    local lemma = selected and selected.lemma or ""

    -- Keep subtitle data out of shell source. Values travel as positional
    -- subprocess arguments and are assigned to the named shell variables.
    -- Legacy positional aliases remain: $1=word, $2=phrase, $3=lemma.
    local shell_source = table.concat({
        "word=$1",
        "phrase=$2",
        "lemma=$3",
        "export word phrase lemma",
        script,
    }, "\n")
    mp.command_native_async({
        name = "subprocess",
        -- Always invoke a real shell; never let an option accidentally point
        -- this source string at python3 (which produces a misleading SyntaxError).
        args = { "/bin/sh", "-c", shell_source, "ankimorphs-dict",
            word, phrase, lemma },
        capture_stdout = true,
        capture_stderr = true,
        playback_only = false,
    }, function(success, result, err)
        if not success or (result and result.status ~= 0) then
            msg.error("AnkiMorphs dictionary: " .. action_name .. " failed: "
                .. tostring(err or (result and result.stderr) or (result and result.status) or "unknown error"))
        end
    end)
end

local function run_left() run_script(o.left_click_script, "left-click", true) end
local function run_right() run_script(o.right_click_script, "right-click", true) end

local function set_extension_enabled(value)
    value = not not value
    if extension_enabled == value then return end
    extension_enabled = value
    hover_serial = hover_serial + 1
    if hover_timer then hover_timer:kill(); hover_timer = nil end
    if not extension_enabled then
        hover = nil
        hide_tooltip()
        hide_selection()
        mp.osd_message("AnkiMorphs dictionary: disabled", 1.2)
    else
        mp.osd_message("AnkiMorphs dictionary: enabled", 1.2)
        update_hover()
    end
end

local function toggle_extension()
    set_extension_enabled(not extension_enabled)
end

local function set_cue(_, value)
    local previous_cue = cue
    local previous_segment_index = selected_target and selected_target.segment_index or nil
    local previous_tooltip = tooltip_text
    local previous_tooltip_segment_index = tooltip_anchor_segment_index
    local same_cue = type(previous_cue) == "table"
        and previous_cue.active == true
        and type(value) == "table"
        and value.active == true
        and tonumber(previous_cue.generation) == tonumber(value.generation)

    cue = type(value) == "table" and value or nil
    targets = build_targets()

    if same_cue and previous_segment_index then
        -- A dimensions-only update is the same cue, not a new subtitle. Keep
        -- keyboard selection attached to its original segment while its
        -- hit-test coordinates are recalculated for the new OSD size.
        selected_index = nil
        selected_target = nil
        for index, target in ipairs(targets) do
            if tonumber(target.segment_index) == tonumber(previous_segment_index) then
                selected_index = index
                selected_target = target
                break
            end
        end
        if selected_target then
            render_selection()
        else
            hide_selection()
        end
    else
        hide_selection()
    end

    update_hover()

    -- A dimensions-only update keeps the same generation and must not reset the
    -- current selection. On a genuinely new visible cue, optionally select the
    -- first item eligible for unknown-only navigation. This shares the exact
    -- status filter with next/previous-unknown, including the learning toggle.
    if not same_cue and extension_enabled and cue and cue.active == true
        and o.auto_select_first_unknown_on_new_cue then
        local first_unknown_index, first_unknown_position, eligible_count
        first_unknown_position = 0
        eligible_count = 0
        for index, target in ipairs(targets) do
            if is_unknown_navigation_target(target) then
                eligible_count = eligible_count + 1
                if not first_unknown_index then
                    first_unknown_index = index
                    first_unknown_position = eligible_count
                end
            end
        end
        if first_unknown_index then
            select_target(first_unknown_index, "unknown", first_unknown_position, eligible_count)
        end
    end

    if same_cue and previous_tooltip and previous_tooltip_segment_index then
        -- Keep an already-open dictionary result visible only if its original
        -- morph still exists. Do not attach a stale result to a different word
        -- merely because a resize moved the mouse over another hitbox.
        local anchor = nil
        if selected_target
            and tonumber(selected_target.segment_index) == previous_tooltip_segment_index then
            anchor = selected_target
        elseif hover and tonumber(hover.segment_index) == previous_tooltip_segment_index then
            anchor = hover
        end
        if anchor then render_tooltip(previous_tooltip, anchor, true) end
    end
end

mp.observe_property("user-data/ankimorphs/current-cue", "native", set_cue)
mp.observe_property("mouse-pos", "native", function() update_hover() end)

if o.left_click_key ~= "" then
    mp.add_key_binding(o.left_click_key, "ankimorphs-dict-run-left", run_left)
end
if o.right_click_key ~= "" then
    mp.add_key_binding(o.right_click_key, "ankimorphs-dict-run-right", run_right)
end
mp.register_script_message("run-left", run_left)
mp.register_script_message("run-right", run_right)
if o.toggle_extension_key ~= "" then
    mp.add_key_binding(o.toggle_extension_key, "ankimorphs-dict-toggle-extension", toggle_extension)
end
mp.register_script_message("toggle-extension", toggle_extension)

if o.select_previous_key ~= "" then
    mp.add_key_binding(o.select_previous_key, "ankimorphs-dict-select-previous", select_previous)
end
if o.select_next_key ~= "" then
    mp.add_key_binding(o.select_next_key, "ankimorphs-dict-select-next", select_next)
end
if o.select_next_unknown_key ~= "" then
    mp.add_key_binding(o.select_next_unknown_key, "ankimorphs-dict-select-next-unknown", select_next_unknown)
end
if o.select_previous_unknown_key ~= "" then
    mp.add_key_binding(o.select_previous_unknown_key, "ankimorphs-dict-select-previous-unknown", select_previous_unknown)
end
if o.show_dictionary_key ~= "" then
    mp.add_key_binding(o.show_dictionary_key, "ankimorphs-dict-show-dictionary", show_dictionary)
end
if o.show_lemma_dictionary_key ~= "" then
    mp.add_key_binding(o.show_lemma_dictionary_key, "ankimorphs-dict-show-lemma-dictionary", show_lemma_dictionary)
end
if o.activate_left_key ~= "" then
    mp.add_key_binding(o.activate_left_key, "ankimorphs-dict-activate-left", function()
        run_script(o.left_click_script, "keyboard left action")
    end)
end
if o.activate_right_key ~= "" then
    mp.add_key_binding(o.activate_right_key, "ankimorphs-dict-activate-right", function()
        run_script(o.right_click_script, "keyboard right action")
    end)
end
mp.register_script_message("select-next", select_next)
mp.register_script_message("select-previous", select_previous)
mp.register_script_message("select-next-unknown", select_next_unknown)
mp.register_script_message("select-previous-unknown", select_previous_unknown)
mp.register_script_message("show-dictionary", show_dictionary)
mp.register_script_message("show-lemma-dictionary", show_lemma_dictionary)

for index = 1, 6 do
    local action_index = index
    local key = o["action_" .. action_index .. "_key"]
    local script = o["action_" .. action_index .. "_script"]
    local message = "run-action-" .. action_index
    local callback = function() run_script(script, "action " .. action_index) end
    mp.register_script_message(message, callback)
    if key and key ~= "" then
        mp.add_key_binding(key, "ankimorphs-dict-action-" .. action_index, callback)
    end
end

mp.register_event("end-file", function()
    cue = nil
    hover = nil
    targets = {}
    hover_serial = hover_serial + 1
    if hover_timer then hover_timer:kill(); hover_timer = nil end
    hide_tooltip()
    hide_selection()
end)
mp.register_event("shutdown", function()
    hide_tooltip()
    hide_selection()
end)

msg.info("AnkiMorphs dictionary: loaded (database " .. tostring(o.dict_database)
    .. "; keyboard navigation: " .. tostring(o.select_previous_key) .. "/" .. tostring(o.select_next_key)
    .. "; unknown navigation: " .. tostring(o.select_previous_unknown_key)
    .. "/" .. tostring(o.select_next_unknown_key)
    .. "; auto dict: " .. tostring(o.auto_dictionary_on_morph_navigation)
    .. "/" .. tostring(o.auto_dictionary_on_unknown_navigation)
    .. "; dictionary: " .. tostring(o.show_dictionary_key)
    .. "; lemma dictionary: " .. tostring(o.show_lemma_dictionary_key)
    .. "; toggle: " .. tostring(o.toggle_extension_key) .. "; actions via /bin/sh)")
