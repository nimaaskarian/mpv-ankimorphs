-- AnkiMorphs-style subtitle highlighter for mpv.
-- The installer places backend.py beside this script as a directory script.

local mp = require 'mp'
local msg = require 'mp.msg'
local utils = require 'mp.utils'
local options = require 'mp.options'
local input = require 'mp.input'

local o = {
    profile_dir = "~/.local/share/Anki2/User 1",
    spacy_venv = "~/.local/share/Anki2/addons21/spacy-venv-python-3_14",
    python = "",
    db_path = "~/.local/share/Anki2/User 1/ankimorphs.db",
    priority_dir = "~/.local/share/Anki2/User 1/priority-files",
    priority_file = "",
    cache_dir = "", -- blank = private per-user directory under /tmp (tmpfs)
    spacy_model = "de_core_news_lg",
    subtitle_source = "primary", -- primary or secondary
    enabled = true,
    toggle_highlighting_key = "ctrl+alt+h", -- empty = no physical key; script-binding remains available
    font_size = 38,
    font_name = "Noto Sans",
    outline = 2,
    bottom_margin = 48,
    status_unknown = "&HFF0000&", -- CSS blue (#0000ff), ASS uses BBGGRR
    status_learning = "&H3DB38B&", -- CSS #8bb33d
    status_known = "&H008000&", -- CSS green
    status_undefined = "&H808080&",
}
options.read_options(o, "ankimorphs")

-- mp.get_script_directory() is non-nil only when mpv loads this as a
-- directory script (scripts/ankimorphs/main.lua). Keep a fallback for users
-- who launch the Lua file directly with --script.
local script_dir = mp.get_script_directory()
if not script_dir then
    local source = debug.getinfo(1, "S").source or ""
    if source:sub(1, 1) == "@" then
        script_dir = utils.split_path(source:sub(2))
    end
end
if not script_dir or script_dir == "" then
    error("AnkiMorphs: cannot determine script directory; install as scripts/ankimorphs/main.lua")
end
local backend = script_dir .. "/backend.py"
local overlay = mp.create_osd_overlay("ass-events")
local socket_path
local python
local models = {}
local priority_files = {}
local model_index = 1
local priority_index = 0
local generation = 0
local original_visibility = {}
local overlay_active = false
local backend_ready = false
local current_segments = nil
local current_cue_generation = 0
local selection_state = nil
local interaction_generation = 0
local precomputed_cache = {}
local prefetch_job_id = nil
local prefetch_cursor = 0
local prefetch_generation = 0
local prefetch_poll_timer = nil
local prefetch_selected_subtitle
local resize_timer = nil

local function expand(path)
    if path:sub(1, 2) == "~/" then
        return (os.getenv("HOME") or "") .. path:sub(2)
    end
    return mp.command_native({ "expand-path", path }) or path
end

local function join(a, b)
    if a:sub(-1) == "/" then return a .. b end
    return a .. "/" .. b
end

local function file_exists(path)
    local f = io.open(path, "rb")
    if f then f:close(); return true end
    return false
end

local function osd(text, duration)
    mp.osd_message(text, duration or 3)
end

local function json_request(request, callback)
    if not socket_path or not python then
        callback(false, nil, "backend is not configured")
        return
    end
    mp.command_native_async({
        name = "subprocess",
        args = { python, backend, "request", "--socket", socket_path },
        stdin_data = utils.format_json(request),
        capture_stdout = true,
        capture_stderr = true,
        playback_only = false,
    }, function(success, result, error)
        if not success then
            callback(false, nil, error or (result and result.stderr) or "backend request failed")
            return
        end
        local response, decode_error = utils.parse_json(result.stdout or "")
        if not response then
            callback(false, nil, decode_error or "invalid backend response")
            return
        end
        if not response.ok then
            callback(false, response, response.error or "backend error")
            return
        end
        callback(true, response, nil)
    end)
end

local function select_python()
    local configured = o.python ~= "" and expand(o.python) or ""
    if configured ~= "" then return configured end
    local venv_python = join(expand(o.spacy_venv), "bin/python")
    if file_exists(venv_python) then return venv_python end
    return "python3"
end

local function hide_native_subtitle()
    local property = o.subtitle_source == "secondary"
        and "secondary-sub-visibility" or "sub-visibility"
    if original_visibility[property] == nil then
        local value = mp.get_property_native(property)
        if value == nil then value = true end
        original_visibility[property] = value
    end
    mp.set_property_native(property, false)
end

local function restore_native_subtitle()
    for property, value in pairs(original_visibility) do
        pcall(mp.set_property_native, property, value)
    end
    original_visibility = {}
end

local function publish_inactive_interaction_state()
    interaction_generation = interaction_generation + 1
    current_cue_generation = interaction_generation
    current_segments = nil
    selection_state = nil
    pcall(mp.set_property_native, "user-data/ankimorphs/current-cue", {
        active = false,
        generation = interaction_generation,
        text = "",
        segments = {},
    })
end

local function clear_overlay()
    generation = generation + 1
    if resize_timer then
        resize_timer:kill()
        resize_timer = nil
    end
    publish_inactive_interaction_state()
    if overlay_active then
        overlay.data = ""
        overlay:update()
        overlay_active = false
    end
    restore_native_subtitle()
end

local function escape_ass(text)
    text = tostring(text or "")
    text = mp.command_native({ "escape-ass", text }) or text
    text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
    return text:gsub("\n", "\\N")
end

local function draw_segments(segments)
    local width, height = mp.get_osd_size()
    if not width or not height or width <= 0 or height <= 0 then return end
    local font_name = tostring(o.font_name):gsub("[{}]", ""):gsub("\\", "")
    local base_outline = tonumber(o.outline) or 2
    local header = string.format(
        "{\\an2\\q2\\fs%d\\fn%s\\bord%d\\3c&H000000&\\shad0\\pos(%.1f,%.1f)}",
        tonumber(o.font_size) or 38,
        font_name,
        base_outline,
        width / 2,
        height - (tonumber(o.bottom_margin) or 48)
    )
    local colors = {
        unknown = o.status_unknown,
        learning = o.status_learning,
        known = o.status_known,
        undefined = o.status_undefined,
    }
    local out = { header }
    for index, segment in ipairs(segments or {}) do
        local status = segment.status or "normal"
        local color = colors[status]
        local is_selected = selection_state
            and selection_state.active == true
            and tonumber(selection_state.generation) == current_cue_generation
            and tonumber(selection_state.segment_index) == index
        if is_selected then
            -- An absent/empty selection color preserves this segment's normal
            -- AnkiMorphs status color. A configured selection color overrides it.
            local selected_color = tostring(selection_state.color or "")
            if selected_color == "" then selected_color = tostring(color or "") end
            local foreground_tag = selected_color ~= "" and ("\\1c" .. selected_color) or ""
            local outline_color = tostring(selection_state.outline_color or "&HFFFFFF&")
            local selected_outline = math.max(0, tonumber(selection_state.outline) or 3)
            out[#out + 1] = string.format(
                "{%s\\3c%s\\bord%.2f}",
                foreground_tag, outline_color, selected_outline
            )
            out[#out + 1] = escape_ass(segment.text or "")
            out[#out + 1] = string.format(
                "{\\1c&HFFFFFF&\\3c&H000000&\\bord%d}", base_outline
            )
        elseif color then
            out[#out + 1] = "{\\1c" .. color .. "}"
            out[#out + 1] = escape_ass(segment.text or "")
            out[#out + 1] = "{\\1c&HFFFFFF&}"
        else
            out[#out + 1] = escape_ass(segment.text or "")
        end
    end
    overlay.res_x = width
    overlay.res_y = height
    overlay.data = table.concat(out)
    overlay:update()
    overlay_active = true
end

local function publish_current_cue()
    -- Publish the exact segment stream for the companion dictionary plugin.
    -- The companion sends back a segment index to recolor in this same overlay.
    -- This is also refreshed after a resize so its hit-testing geometry stays
    -- synchronized without changing the cue generation or re-running spaCy.
    local width, height = mp.get_osd_size()
    local cue_text = {}
    local shared_segments = {}
    for _, segment in ipairs(current_segments or {}) do
        local segment_text = tostring(segment.text or "")
        cue_text[#cue_text + 1] = segment_text
        shared_segments[#shared_segments + 1] = {
            text = segment_text,
            status = tostring(segment.status or "normal"),
            lemma = segment.lemma and tostring(segment.lemma) or "",
        }
    end
    pcall(mp.set_property_native, "user-data/ankimorphs/current-cue", {
        active = true,
        generation = current_cue_generation,
        text = table.concat(cue_text),
        segments = shared_segments,
        width = width,
        height = height,
        font_size = tonumber(o.font_size) or 38,
        bottom_margin = tonumber(o.bottom_margin) or 48,
        font_name = tostring(o.font_name or "Noto Sans"),
    })
end

local function render_segments(segments)
    current_segments = segments or {}
    interaction_generation = interaction_generation + 1
    current_cue_generation = interaction_generation
    draw_segments(current_segments)
    publish_current_cue()
end

local function redraw_current_cue()
    if not o.enabled or not overlay_active or type(current_segments) ~= "table" then
        return
    end
    -- Reuse the already analyzed segments. draw_segments() reads the current
    -- OSD dimensions and updates the ASS overlay's resolution/anchor positions.
    draw_segments(current_segments)
    publish_current_cue()
end

local function schedule_resize_redraw()
    if resize_timer then resize_timer:kill() end
    -- mpv may emit several osd-dimensions notifications during a fullscreen
    -- transition. Debounce them and render once after the final size settles.
    resize_timer = mp.add_timeout(0.06, function()
        resize_timer = nil
        if not overlay_active or not o.enabled or type(current_segments) ~= "table" then
            return
        end
        local width, height = mp.get_osd_size()
        if width and height and width > 0 and height > 0
            and (overlay.res_x ~= width or overlay.res_y ~= height) then
            redraw_current_cue()
        end
    end)
end

local function subtitle_property()
    if o.subtitle_source == "secondary" then return "secondary-sub-text" end
    return "sub-text"
end

local function normalize_cache_key(text)
    text = tostring(text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
    -- Match the backend's HTML-to-text conversion for common subtitle markup.
    text = text:gsub("<([%w]+)[^>]*>", function(tag)
        tag = tag:lower()
        if tag == "br" or tag == "p" or tag == "div" or tag == "li" then return "\n" end
        return ""
    end)
    text = text:gsub("</([%w]+)%s*>", function(tag)
        tag = tag:lower()
        if tag == "p" or tag == "div" or tag == "li" then return "\n" end
        return ""
    end)
    text = text:gsub("<.->", "")
    local entities = {
        ["&amp;"] = "&", ["&lt;"] = "<", ["&gt;"] = ">",
        ["&quot;"] = '"', ["&#39;"] = "'", ["&apos;"] = "'",
        ["&nbsp;"] = " ",
    }
    text = text:gsub("&[%w#]+;", function(entity)
        return entities[entity:lower()] or entity
    end)
    return text
end

local function store_prefetched_results(results)
    for _, entry in ipairs(results or {}) do
        if entry.text and entry.result then
            precomputed_cache[entry.text] = entry.result
        end
    end
end

local function stop_prefetch_poll()
    prefetch_generation = prefetch_generation + 1
    if prefetch_poll_timer then
        prefetch_poll_timer:kill()
        prefetch_poll_timer = nil
    end
    prefetch_job_id = nil
    prefetch_cursor = 0
end

local function poll_prefetch_status(this_generation)
    if not prefetch_job_id or this_generation ~= prefetch_generation then return end
    json_request({
        action = "prefetch_status",
        job_id = prefetch_job_id,
        cursor = prefetch_cursor,
        limit = 500,
    }, function(success, response, err)
        if this_generation ~= prefetch_generation then return end
        if not success then
            msg.warn("AnkiMorphs prefetch status: " .. tostring(err))
            prefetch_poll_timer = mp.add_timeout(1.0, function()
                poll_prefetch_status(this_generation)
            end)
            return
        end
        store_prefetched_results(response.results)
        prefetch_cursor = tonumber(response.next_cursor) or prefetch_cursor
        local result_count = tonumber(response.result_count) or prefetch_cursor
        if response.status == "stale" then
            prefetch_job_id = nil
            prefetch_poll_timer = nil
        elseif response.status == "done" and prefetch_cursor >= result_count then
            local total = tonumber(response.total) or prefetch_cursor
            local completed = tonumber(response.completed) or prefetch_cursor
            local failed = tonumber(response.failed) or 0
            msg.info(string.format(
                "AnkiMorphs: pre-cached %d/%d subtitle cues (%d failed)",
                completed, total, failed
            ))
            prefetch_job_id = nil
            prefetch_poll_timer = nil
        else
            -- When analysis is already done, drain cached pages quickly. While
            -- analysis is running, poll less often to avoid subprocess churn.
            local delay = response.status == "done" and 0.01 or 0.35
            prefetch_poll_timer = mp.add_timeout(delay, function()
                poll_prefetch_status(this_generation)
            end)
        end
    end)
end

local function begin_prefetch(request)
    stop_prefetch_poll()
    local this_generation = prefetch_generation
    json_request(request, function(success, response, err)
        if this_generation ~= prefetch_generation then return end
        if not success then
            msg.warn("AnkiMorphs: subtitle prefetch unavailable: " .. tostring(err))
            return
        end
        prefetch_job_id = response.job_id
        prefetch_cursor = 0
        if not prefetch_job_id then return end
        msg.info(string.format(
            "AnkiMorphs: pre-caching %d subtitle cues (%d already cached)",
            tonumber(response.total) or 0,
            tonumber(response.cache_hits) or 0
        ))
        poll_prefetch_status(this_generation)
    end)
end

local function selected_subtitle_track()
    local property = o.subtitle_source == "secondary" and "current-tracks/sub2" or "current-tracks/sub"
    local track = mp.get_property_native(property)
    if type(track) == "table" then return track end
    return nil
end

local BITMAP_SUBTITLE_CODECS = {
    dvd_subtitle = true,
    hdmv_pgs_subtitle = true,
    dvb_subtitle = true,
    xsub = true,
}

prefetch_selected_subtitle = function()
    if not backend_ready or not o.enabled then return end
    local track = selected_subtitle_track()
    if not track then
        stop_prefetch_poll()
        return
    end

    local external_filename = track["external-filename"]
    if external_filename and external_filename ~= "" then
        local path = expand(external_filename)
        begin_prefetch({ action = "prefetch_file", path = path, model = o.spacy_model })
        return
    end

    local codec = tostring(track.codec or "")
    if BITMAP_SUBTITLE_CODECS[codec] then
        msg.warn("AnkiMorphs: embedded image subtitles cannot be pre-cached; using live analysis if text is exposed")
        stop_prefetch_poll()
        return
    end

    local media_path = mp.get_property("path", "")
    local stream_index = tonumber(track["ff-index"])
    if not stream_index then
        local track_id = tonumber(track.id)
        if track_id then stream_index = track_id - 1 end
    end
    if media_path == "" or not stream_index then
        msg.warn("AnkiMorphs: cannot identify embedded subtitle stream for pre-caching")
        return
    end

    stop_prefetch_poll()
    local this_generation = prefetch_generation
    msg.info("AnkiMorphs: extracting embedded subtitle track for pre-caching")
    mp.command_native_async({
        name = "subprocess",
        args = {
            "ffmpeg", "-nostdin", "-v", "error", "-i", media_path,
            "-map", "0:" .. tostring(stream_index), "-c:s", "srt", "-f", "srt", "pipe:1",
        },
        capture_stdout = true,
        capture_stderr = true,
        capture_size = 64 * 1024 * 1024,
        playback_only = false,
    }, function(success, result, error)
        if this_generation ~= prefetch_generation then return end
        if not success or not result or result.status ~= 0 or not result.stdout or result.stdout == "" then
            msg.warn("AnkiMorphs: FFmpeg subtitle extraction failed; keeping live-analysis fallback: "
                .. tostring(error or (result and result.stderr) or "no subtitle output"))
            return
        end
        begin_prefetch({
            action = "prefetch_text",
            text = result.stdout,
            source = "embedded subtitle (" .. codec .. ")",
            model = o.spacy_model,
        })
    end)
end

local function process_current_subtitle(text)
    if not o.enabled then
        clear_overlay()
        return
    end
    text = text or ""
    if text == "" then
        clear_overlay()
        return
    end

    generation = generation + 1
    local this_generation = generation
    if not backend_ready then
        return
    end
    hide_native_subtitle()
    local cached = precomputed_cache[normalize_cache_key(text)]
    if cached then
        render_segments(cached.segments)
        return
    end
    json_request({ action = "analyze", text = text, model = o.spacy_model }, function(success, response, err)
        if this_generation ~= generation or not o.enabled then return end
        if not success then
            msg.error("AnkiMorphs: " .. tostring(err))
            -- Keep the original subtitle visible if analysis failed.
            clear_overlay()
            return
        end
        render_segments(response.segments)
    end)
end

local function refresh_subtitle()
    local text = mp.get_property(subtitle_property(), "")
    process_current_subtitle(text)
end

local function set_source(source)
    if source ~= "primary" and source ~= "secondary" then return end
    if o.subtitle_source == source then return end
    clear_overlay()
    o.subtitle_source = source
    refresh_subtitle()
    prefetch_selected_subtitle()
    osd("AnkiMorphs: " .. source .. " subtitles")
end

local function choose_model()
    if #models == 0 then
        osd("AnkiMorphs: no spaCy models found in configured venv")
        return
    end
    input.select({
        prompt = "AnkiMorphs: select spaCy model",
        items = models,
        default_item = model_index,
        submit = function(index)
            if not index or not models[index] then return end
            model_index = index
            o.spacy_model = models[index]
            precomputed_cache = {}
            refresh_subtitle()
            prefetch_selected_subtitle()
            osd("AnkiMorphs model: " .. o.spacy_model)
        end,
    })
end

local function choose_priority_file()
    local items = { "(none)" }
    for _, name in ipairs(priority_files) do items[#items + 1] = name end
    input.select({
        prompt = "AnkiMorphs: select priority file",
        items = items,
        default_item = priority_index + 1,
        submit = function(index)
            if not index or not items[index] then return end
            if index == 1 then
                priority_index = 0
                o.priority_file = ""
                osd("AnkiMorphs priority file: (none)")
            else
                priority_index = index - 1
                o.priority_file = priority_files[priority_index]
                osd("AnkiMorphs priority file: " .. o.priority_file .. " (selection only; not used by am-highlight)")
            end
        end,
    })
end

local function start_backend()
    local profile_dir = expand(o.profile_dir)
    local db_path = expand(o.db_path)
    local priority_dir = expand(o.priority_dir)
    local names_path = join(profile_dir, "names.txt")
    python = select_python()

    if not file_exists(backend) then
        osd("AnkiMorphs: backend.py missing: " .. backend, 8)
        return
    end
    if python == "python3" then
        msg.warn("Could not find venv Python at " .. join(expand(o.spacy_venv), "bin/python") .. "; using python3 fallback")
    end

    math.randomseed(os.time() + math.floor(mp.get_time() * 1000))
    local runtime_dir = os.getenv("XDG_RUNTIME_DIR") or "/tmp"
    socket_path = join(runtime_dir, "am-" .. tostring(math.random(100000, 999999)) .. ".sock")
    local log_path = join(runtime_dir, "mpv-ankimorphs.log")
    local daemon_args = { python, backend, "daemon",
        "--socket", socket_path,
        "--profile-dir", profile_dir,
        "--db", db_path,
        "--priority-dir", priority_dir,
        "--names", names_path,
        "--log", log_path }
    if o.cache_dir ~= "" then
        daemon_args[#daemon_args + 1] = "--cache-dir"
        daemon_args[#daemon_args + 1] = expand(o.cache_dir)
    end

    mp.command_native_async({
        name = "subprocess",
        args = daemon_args,
        capture_stdout = true,
        capture_stderr = true,
        playback_only = false,
    }, function(success, result, error)
        if not success and backend_ready then
            backend_ready = false
            msg.error("AnkiMorphs backend exited: " .. tostring(error or (result and result.stderr) or "unknown error"))
            clear_overlay()
        end
    end)

    -- Each request waits briefly for the backend socket while spaCy initializes.
    json_request({ action = "list" }, function(success, response, err)
        if not success then
            osd("AnkiMorphs backend failed: " .. tostring(err) .. " (see " .. log_path .. ")", 8)
            msg.error("AnkiMorphs backend failed: " .. tostring(err))
            return
        end
        backend_ready = true
        models = response.models or {}
        priority_files = response.priority_files or {}
        if #models > 0 then
            local found = false
            for i, model in ipairs(models) do
                if model == o.spacy_model then model_index = i; found = true; break end
            end
            if not found then model_index = 1; o.spacy_model = models[1] end
        end
        if o.priority_file ~= "" then
            for i, name in ipairs(priority_files) do
                if name == o.priority_file then priority_index = i; break end
            end
        end
        if priority_index == 0 and #priority_files > 0 then
            priority_index = 1
            o.priority_file = priority_files[1]
        end
        local model_label = #models > 0 and o.spacy_model or "no models found"
        local status_label = response.evaluation .. ", known >= " .. tostring(response.known_threshold_days) .. " days"
        local priority_label = o.priority_file ~= "" and o.priority_file or "(none)"
        local cache_label = response.disk_cache_enabled and ("tmpfs cache: " .. tostring(response.cache_entries or 0)) or "memory cache only"
        msg.info("AnkiMorphs tmpfs cache directory: " .. tostring(response.cache_dir or "unknown"))
        osd("AnkiMorphs ready: " .. model_label .. " | " .. status_label .. " | " .. cache_label, 5)
        refresh_subtitle()
        prefetch_selected_subtitle()
    end)
end

-- The OSD dimensions change on window resize and fullscreen transitions.
-- Re-render the current cue from cached spaCy segments instead of waiting for
-- the next subtitle event (or launching another backend analysis request).
mp.observe_property("osd-dimensions", "native", function()
    if overlay_active and current_segments then
        schedule_resize_redraw()
    end
end)

-- The dictionary companion selects an existing segment by its 1-based
-- index. Re-render the SAME main subtitle overlay with different ASS style
-- tags; never draw a duplicate word on a second overlay.
mp.observe_property("user-data/ankimorphs/selection", "native", function(_, value)
    selection_state = type(value) == "table" and value.active == true and value or nil
    if o.enabled and overlay_active and current_segments then
        draw_segments(current_segments)
    end
end)

mp.observe_property("sub-text", "string", function(_, value)
    if o.subtitle_source == "primary" then process_current_subtitle(value) end
end)
mp.observe_property("secondary-sub-text", "string", function(_, value)
    if o.subtitle_source == "secondary" then process_current_subtitle(value) end
end)

local function toggle_highlighting()
    o.enabled = not o.enabled
    if o.enabled then refresh_subtitle() else clear_overlay() end
    osd("AnkiMorphs highlighting: " .. (o.enabled and "on" or "off"))
end

local function toggle_subtitle_source()
    set_source(o.subtitle_source == "primary" and "secondary" or "primary")
end

-- Keep script-message entry points for users who prefer input.conf bindings.
mp.register_script_message("ankimorphs-toggle", toggle_highlighting)
mp.register_script_message("ankimorphs-source", function(source)
    set_source(source)
end)
mp.register_script_message("ankimorphs-model-select", choose_model)
mp.register_script_message("ankimorphs-priority-select", choose_priority_file)

-- mpv's canonical key syntax uses lowercase modifier names (e.g. ctrl+q).
-- Bind directly to the callbacks rather than routing a key press through
-- script-message, which is only needed for external input.conf bindings.
mp.add_key_binding(o.toggle_highlighting_key ~= "" and o.toggle_highlighting_key or nil,
    "ankimorphs-toggle", toggle_highlighting)
mp.add_key_binding("ctrl+alt+s", "ankimorphs-source", toggle_subtitle_source)
mp.add_key_binding("ctrl+alt+m", "ankimorphs-model-select", choose_model)
mp.add_key_binding("ctrl+alt+p", "ankimorphs-priority-select", choose_priority_file)
mp.add_key_binding("ctrl+alt+r", "ankimorphs-prefetch", function()
    prefetch_selected_subtitle()
    osd("AnkiMorphs: subtitle pre-cache requested")
end)
local toggle_key_label = o.toggle_highlighting_key ~= "" and o.toggle_highlighting_key or "disabled (script-binding only)"
msg.info("AnkiMorphs: registered toggle key " .. toggle_key_label
    .. "; source ctrl+alt+s, model ctrl+alt+m, priority ctrl+alt+p, prefetch ctrl+alt+r")

mp.register_event("file-loaded", function()
    clear_overlay()
    stop_prefetch_poll()
    precomputed_cache = {}
    refresh_subtitle()
    mp.add_timeout(0.4, function() prefetch_selected_subtitle() end)
end)
mp.register_event("tracks-changed", function()
    if backend_ready then
        refresh_subtitle()
        prefetch_selected_subtitle()
    end
end)
mp.observe_property("sid", "native", function()
    if o.subtitle_source == "primary" and backend_ready then
        refresh_subtitle()
        prefetch_selected_subtitle()
    end
end)
mp.observe_property("secondary-sid", "native", function()
    if o.subtitle_source == "secondary" and backend_ready then
        refresh_subtitle()
        prefetch_selected_subtitle()
    end
end)
mp.register_event("end-file", function()
    clear_overlay()
    stop_prefetch_poll()
end)
mp.register_event("shutdown", function()
    clear_overlay()
    stop_prefetch_poll()
    if socket_path and python then
        -- Ask the persistent backend to stop without blocking mpv shutdown.
        mp.command_native_async({
            name = "subprocess",
            args = { python, backend, "request", "--socket", socket_path, "--action", "quit" },
            capture_stdout = true,
            capture_stderr = true,
            playback_only = false,
        }, function() end)
    end
end)

start_backend()
