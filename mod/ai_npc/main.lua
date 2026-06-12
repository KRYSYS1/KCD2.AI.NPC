--[[
  KCD2 AI NPC — Main entry point
  Requires: KCD2ModLoader (https://github.com/xiaoxiao921/KCD2ModLoader)
  
  This mod allows players to have AI-powered conversations with any NPC
  using a local Python server (LLM + optional TTS).
]]

-- Configuration
local CONFIG = {
    server_url = "http://127.0.0.1:4999",
    chat_key = "v",            -- Key to toggle chat with nearest NPC
    end_key = "",              -- Optional key to end current conversation
    max_npc_distance = 5.0,    -- Max distance to NPC to start conversation (meters)
    target_ray_distance = 6.0, -- Max focus distance for NPC under crosshair
    require_target_lock = true, -- Require crosshair target (native behavior)
    ui_mode = "hud",          -- "hud" (native HUD only) or "overlay" (DLL window + HUD)
    window_width = 600,
    window_height = 400,
    -- When true and Player Event Dispatcher (Nexus 1430) is installed,
    -- subscribe to its events instead of relying solely on 500ms raycast polling.
    -- See docs/reference_mods_findings.md section 1.
    use_event_dispatcher = true,
    -- Auto-end the current dialog silently after this many seconds without any
    -- player activity (no ai_say, no response, no crosshair on the same NPC).
    -- Set to 0 to disable. Default 60s.
    auto_end_idle_sec = 60,
    -- Push-to-talk (smart V).
    -- Tap V (< ptt_hold_threshold_ms) => existing text-overlay toggle.
    -- Hold V longer            => voice capture; server transcribes via STT
    --                              and sends it to the LLM like a normal chat
    --                              message. See server/stt_client.py.
    ptt_enabled = true,
    ptt_hold_threshold_ms = 200,
}

local SOUL_NAME_FALLBACK_RU = {}

local NPC_TOKEN_NAME_FALLBACK = {
    kpri_woman_15 = "Светлана",
    kpri_woman_16 = "Эвелина",
    tzel_woman_7 = "Барбора",
    tzel_woman_8 = "Марта",
    kmal_woman_1 = "Людмила",
    kmal_woman_2 = "Сильвия",
    kmal_woman_3 = "Квета",
    kmal_woman_18 = "Вероника",
    kmal_woman_19 = "Аполена",
    kmal_woman_20 = "Йоханка",
    kzik_woman_1 = "Лена",
    kzik_woman_2 = "Мила",
    kcer_woman_4 = "Мальвина",
    kcer_woman_5 = "Анета",
    kcer_woman_6 = "Тереза",
}

local function load_optional_lua_table(paths)
    if type(dofile) ~= "function" then
        return {}
    end
    for _, path in ipairs(paths) do
        local ok, tbl = pcall(dofile, path)
        if ok and type(tbl) == "table" then
            return tbl
        end
    end
    return {}
end

local function resolve_http_provider()
    local function safe_get_net(obj)
        local ok, value = pcall(function() return obj and obj.net end)
        if ok then return value end
        return nil
    end

    local rom_net = safe_get_net(rom)
    if rom_net and rom_net.http_post then
        return rom_net, "rom.net"
    end
    if _G and type(_G) == "table" then
        for k, v in pairs(_G) do
            if type(v) == "table" then
                local net = safe_get_net(v)
                if type(net) == "table" and net.http_post then
                    return net, tostring(k) .. ".net"
                end
            end
        end
    end
    return nil, nil
end

local function resolve_http_get_provider()
    local function safe_get_net(obj)
        local ok, value = pcall(function() return obj and obj.net end)
        if ok then return value end
        return nil
    end

    local rom_net = safe_get_net(rom)
    if rom_net and rom_net.http_get then
        return rom_net, "rom.net"
    end
    if _G and type(_G) == "table" then
        for k, v in pairs(_G) do
            if type(v) == "table" then
                local net = safe_get_net(v)
                if type(net) == "table" and net.http_get then
                    return net, tostring(k) .. ".net"
                end
            end
        end
    end
    return nil, nil
end

local NPC_TOKEN_NAME_DYNAMIC = load_optional_lua_table({
    "Scripts/ai_npc/npc_token_names.lua",
    "Data/Scripts/ai_npc/npc_token_names.lua",
})

local UI_KEY_NAME_FALLBACK = load_optional_lua_table({
    "Scripts/ai_npc/ui_name_keys.lua",
    "Data/Scripts/ai_npc/ui_name_keys.lua",
})

local RU_NAME_BY_SOUL_KEY = {
    soul_ui_name_catchpole = "Ловчий",
    soul_ui_name_huntsman = "Охотник",
    soul_ui_name_shoemaker = "Сапожник",
    soul_ui_name_villager = "Житель",
    soul_ui_name_varlet = "Работник",
    soul_ui_name_priest = "Священник",
    soul_ui_name_wench = "Служанка",
    soul_ui_name_pig = "Свинья",
    char_667_uiName = "Пёс",
}

local RU_NAME_BY_SOCIAL_CLASS = {
    catchpole = "Ловчий",
    huntsman_crimeauthority = "Охотник",
    shoemaker = "Сапожник",
    varlet = "Работник",
    priest = "Священник",
    wench = "Служанка",
    villager = "Житель",
    dogcompanion = "Пёс",
    ["animal-tamed"] = "Животное",
}

local RU_NAME_BY_TEXT = {
    ["catchpole"] = "Ловчий",
    ["hunter"] = "Охотник",
    ["hired hand"] = "Работник",
    ["priest"] = "Священник",
    ["housemaid"] = "Служанка",
    ["guildsman janek"] = "Цеховой Янек",
    ["bohush's mother"] = "Мать Богуша",
    ["pig"] = "Свинья",
    ["mutt"] = "Пёс",
    ["dog"] = "Пёс",
    ["villager"] = "Житель",
}

local function norm_key(v)
    if v == nil then return "" end
    return tostring(v):gsub("^%s+", ""):gsub("%s+$", ""):gsub("^@", ""):lower()
end

local function localize_npc_name_ru(raw_name, soul_name_key, social_class, npc_class, soul_token, entity_token)
    local raw_text = tostring(raw_name or "")
    if raw_text:match("^@") and not RU_NAME_BY_TEXT[norm_key(raw_name)] then
        raw_text = ""
    end
    if norm_key(raw_text) == "ui_hud_caption_object_read" then
        raw_text = ""
    end

    local soul_key = norm_key(soul_name_key)
    if soul_key ~= "" and RU_NAME_BY_SOUL_KEY[soul_key] then
        return RU_NAME_BY_SOUL_KEY[soul_key]
    end

    local social = norm_key(social_class)
    if social ~= "" and RU_NAME_BY_SOCIAL_CLASS[social] then
        return RU_NAME_BY_SOCIAL_CLASS[social]
    end

    local soul_tok = norm_key(soul_token)
    if soul_tok ~= "" and NPC_TOKEN_NAME_FALLBACK[soul_tok] then
        return NPC_TOKEN_NAME_FALLBACK[soul_tok]
    end
    if soul_tok ~= "" and NPC_TOKEN_NAME_DYNAMIC[soul_tok] then
        return NPC_TOKEN_NAME_DYNAMIC[soul_tok]
    end

    local ent_tok = norm_key(entity_token)
    if ent_tok ~= "" and NPC_TOKEN_NAME_FALLBACK[ent_tok] then
        return NPC_TOKEN_NAME_FALLBACK[ent_tok]
    end
    if ent_tok ~= "" and NPC_TOKEN_NAME_DYNAMIC[ent_tok] then
        return NPC_TOKEN_NAME_DYNAMIC[ent_tok]
    end

    local by_text = RU_NAME_BY_TEXT[norm_key(raw_text)]
    if by_text then return by_text end

    local cls = norm_key(npc_class)
    if cls == "npc_female" then return "Жительница" end
    if cls == "npc" then return "Житель" end
    if cls == "dog" then return "Пёс" end
    if cls == "pig" then return "Свинья" end

    if raw_text ~= "" then
        return raw_text
    end
    return nil
end

-- State
local state = {
    chat_open = false,
    input_text = "",
    messages = {},            -- { {role="player"|"npc", name=string, text=string}, ... }
    current_npc = nil,        -- { id, name, class, location }
    waiting_response = false,
    error_message = nil,
    server_online = false,
    -- Event-dispatcher integration. "polling" = legacy raycast every 500ms.
    -- "events" = subscribed to Player Event Dispatcher (Nexus 1430).
    dispatcher_mode = "polling",
    -- Timestamp of the last event-triggered inject; used to debounce polling.
    last_event_inject_at = -1000.0,
    -- Rolling log of recent player actions against NPCs (pickpocket/stealth/etc).
    -- Each entry: { ts = <gametime>, event = <name>, slot = <slotId>, user_id = <id> }
    -- Capped at 50; sent to server as conversation context enrichment.
    player_action_log = {},
    -- Per-NPC health snapshots. Map: npc_id_str -> { health = <number>, ts = <gametime>, name = <string> }
    -- Used to detect "Hit" events when health drops between observations
    -- (Player Event Dispatcher does NOT emit damage/combat events, so we infer them).
    npc_health_snapshots = {},
    -- Timestamp (os.clock) of the last meaningful activity in the current chat:
    -- chat opened, ai_say sent, response received, or the same NPC re-targeted
    -- by the crosshair. Used by the auto-end-on-idle poll step.
    last_activity_at = 0,
    scene_flags = {},
    npc_scene_memory = {},
    last_request_npc_id = nil,
    last_request_npc_name = nil,
    last_request_entity_ref = nil,
    last_target_npc_id = nil,
    last_target_entity_ref = nil,
}

local TOGGLE_COOLDOWN_SEC = 0.35
local RESPONSE_TIMEOUT_SEC = 18.0
local last_toggle_at = -1000.0
local next_request_id = 0
local pending_request_id = 0
local last_synced_chat_key = nil
local last_synced_end_key = nil
local actionmap_loaded = false
local build_recent_player_actions = function(_current_npc_id) return {} end
local end_conversation

local last_web_command_id = 0
local last_handled_response_id = 0
local ipc_write_cmd
local ipc_poll_input

-- ============================================================================
-- HTTP helpers (using KCD2ModLoader's networking)
-- ============================================================================

local json = {}

-- Minimal JSON encoder
function json.encode(val)
    if type(val) == "nil" then return "null" end
    if type(val) == "boolean" then return val and "true" or "false" end
    if type(val) == "number" then return tostring(val) end
    if type(val) == "string" then
        return '"' .. val:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t') .. '"'
    end
    if type(val) == "table" then
        -- Check if array
        local is_array = true
        local max_i = 0
        for k, _ in pairs(val) do
            if type(k) ~= "number" or k < 1 or math.floor(k) ~= k then
                is_array = false
                break
            end
            if k > max_i then max_i = k end
        end
        if is_array and max_i == #val then
            local parts = {}
            for i = 1, #val do
                parts[i] = json.encode(val[i])
            end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            local parts = {}
            for k, v in pairs(val) do
                table.insert(parts, json.encode(tostring(k)) .. ":" .. json.encode(v))
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    end
    return "null"
end

-- Minimal JSON decoder
function json.decode(str)
    if not str or str == "" then return nil end
    -- Use Lua pattern matching for simple JSON parsing
    local success, result = pcall(function()
        -- Remove whitespace
        str = str:match("^%s*(.-)%s*$")
        if str:sub(1, 1) == "{" then
            local tbl = {}
            -- Extract key-value pairs
            for key, val in str:gmatch('"([^"]+)"%s*:%s*(".-[^\\]"|%d+%.?%d*|true|false|null|%b{}|%b[])') do
                if val == "null" then
                    tbl[key] = nil
                elseif val == "true" then
                    tbl[key] = true
                elseif val == "false" then
                    tbl[key] = false
                elseif val:sub(1, 1) == '"' then
                    tbl[key] = val:sub(2, -2):gsub('\\n', '\n'):gsub('\\t', '\t'):gsub('\\"', '"'):gsub('\\\\', '\\')
                elseif tonumber(val) then
                    tbl[key] = tonumber(val)
                else
                    tbl[key] = val
                end
            end
            return tbl
        end
        return nil
    end)
    if success then return result end
    return nil
end

local function get_player_entity()
    if System and System.GetEntity then
        local p = System.GetEntity("yourPlayer")
        if not p and System.GetEntityByName then
            p = System.GetEntityByName("yourPlayer")
        end
        if p then return p end
    end
    if player then return player end
    return nil
end

local function is_npc_entity(ent)
    if not ent then return false end
    local cls = string.lower(tostring(ent.class or ""))
    if cls == "horse" then return false end
    if cls:find("npc") or cls:find("human") or cls:find("person") or cls:find("villager") then return true end
    if ent.soul then return true end
    return false
end

local function safe_method_call(obj, method_name, ...)
    if not obj then return nil end
    local fn = obj[method_name]
    if type(fn) ~= "function" then return nil end
    local ok, result = pcall(fn, obj, ...)
    if ok then return result end
    return nil
end

local function try_localize_key(raw_key)
    if raw_key == nil then return nil end
    local key = tostring(raw_key)
    if key == "" then return nil end

    local with_at = key
    if with_at:sub(1, 1) ~= "@" then
        with_at = "@" .. with_at
    end

    local function good(v)
        if v == nil then return nil end
        local s = tostring(v):gsub("^%s+", ""):gsub("%s+$", "")
        if s == "" then return nil end
        if s == key or s == with_at then return nil end
        return s
    end

    if System then
        if type(System.GetLocalizedText) == "function" then
            local ok, val = pcall(System.GetLocalizedText, with_at)
            if ok then
                local out = good(val)
                if out then return out end
            end
        end
        if type(System.LocalizeText) == "function" then
            local ok, val = pcall(System.LocalizeText, with_at)
            if ok then
                local out = good(val)
                if out then return out end
            end
        end
    end

    if Game then
        if type(Game.TranslateString) == "function" then
            local ok, val = pcall(Game.TranslateString, with_at)
            if ok then
                local out = good(val)
                if out then return out end
            end
        end
        if type(Game.translate_string) == "function" then
            local ok, val = pcall(Game.translate_string, key)
            if ok then
                local out = good(val)
                if out then return out end
            end
        end
    end

    local plain = key:gsub("^@", "")
    if SOUL_NAME_FALLBACK_RU[plain] then
        return SOUL_NAME_FALLBACK_RU[plain]
    end

    if UI_KEY_NAME_FALLBACK[plain] then
        return UI_KEY_NAME_FALLBACK[plain]
    end

    return nil
end

local function get_language_code()
    local names = {
        "g_language",
        "sys_language",
        "sys_localization_folder",
        "sys_localization_format",
    }
    if System and type(System.GetCVar) == "function" then
        for _, name in ipairs(names) do
            local ok, val = pcall(System.GetCVar, name)
            if ok and val ~= nil then
                local s = tostring(val):lower()
                if s ~= "" then return s end
            end
        end
    end
    return ""
end

local function try_name_from_token(raw_token)
    if raw_token == nil then return nil end
    local token = tostring(raw_token):gsub("^%s+", ""):gsub("%s+$", "")
    if token == "" then return nil end
    if token:sub(1, 1) == "@" then token = token:sub(2) end
    return NPC_TOKEN_NAME_FALLBACK[token] or NPC_TOKEN_NAME_DYNAMIC[token]
end

-- Forward declaration; assigned later (after ai_npc_log_player_action is defined).
-- Records an NPC health observation and, if it dropped since the previous one,
-- logs a synthetic "Hit" event into state.player_action_log.
local track_npc_health_delta = function(_npc_id, _health, _npc_name) end

local function build_npc_from_entity(ent)
    if not ent then return nil end
    local soul = ent.soul
    local entity_token = (ent.GetName and ent:GetName()) or nil
    local caption_name = safe_method_call(soul, "GetReadCaptionObjectText")
    if caption_name ~= nil then
        caption_name = tostring(caption_name):gsub("^%s+", ""):gsub("%s+$", "")
    end
    if caption_name == "" then caption_name = nil end
    local faction_id = safe_method_call(soul, "GetFactionID")
    local social_class = safe_method_call(soul, "GetSocialClass")
    if type(social_class) == "table" then
        social_class = social_class.Name or social_class.name or tostring(social_class)
    end
    local gender = safe_method_call(soul, "GetGender")
    local soul_name_key = safe_method_call(soul, "GetNameStringId")
    local soul_token = safe_method_call(soul, "GetName")

    local localized_from_caption = try_localize_key(caption_name)
    local localized_from_soul = try_localize_key(soul_name_key)
    local token_fallback_name = try_name_from_token(soul_token) or try_name_from_token(entity_token)

    local chosen_name = localized_from_soul or localized_from_caption or token_fallback_name
    if not chosen_name and caption_name and caption_name ~= "@ui_hud_caption_object_read" and caption_name ~= "ui_hud_caption_object_read" then
        chosen_name = caption_name
    end
    chosen_name = localize_npc_name_ru(chosen_name, soul_name_key, social_class, tostring(ent.class or ""), soul_token, entity_token)

    local context_lines = {}
    context_lines[#context_lines + 1] = "The NPC is currently directly targeted by player's crosshair."
    if faction_id ~= nil then context_lines[#context_lines + 1] = "Faction ID: " .. tostring(faction_id) end
    if social_class ~= nil and social_class ~= "" then context_lines[#context_lines + 1] = "Social class: " .. tostring(social_class) end
    if gender ~= nil then context_lines[#context_lines + 1] = "Gender code: " .. tostring(gender) end
    if soul_name_key ~= nil and soul_name_key ~= "" then context_lines[#context_lines + 1] = "Soul name key: " .. tostring(soul_name_key) end
    if soul_token ~= nil and soul_token ~= "" then context_lines[#context_lines + 1] = "Soul token: " .. tostring(soul_token) end
    if entity_token ~= nil and entity_token ~= "" then context_lines[#context_lines + 1] = "Entity token: " .. tostring(entity_token) end

    -- Tag whether the chosen name is a real personal name or a generic occupation label.
    local soul_key_lc = (type(soul_name_key) == "string") and soul_name_key:lower() or ""
    local name_source
    if soul_key_lc:find("^char_") then
        name_source = "unique"
    elseif soul_key_lc:find("^soul_ui_name_") or soul_key_lc == "" then
        name_source = "generic"
    else
        name_source = "unknown"
    end
    context_lines[#context_lines + 1] = "Name source: " .. name_source

    -- Collect runtime state / disposition flags so the LLM can adapt tone.
    local actor = ent.actor
    local human = ent.human
    local player_ent = get_player_entity()
    local player_id = player_ent and player_ent.id or nil

    local function bool_call(obj, method, ...)
        if not obj or type(obj[method]) ~= "function" then return nil end
        local ok, res = pcall(obj[method], obj, ...)
        if not ok then return nil end
        return res
    end

    local state_flags = {}
    local function push_flag(label, value)
        if value == true then state_flags[#state_flags + 1] = label end
    end

    local is_dead = bool_call(actor, "IsDead")
    local is_unconscious = bool_call(actor, "IsUnconscious")
    local in_combat_mode = bool_call(soul, "IsInCombatMode")
    local in_combat_danger = bool_call(soul, "IsInCombatDanger")
    local in_tense = bool_call(soul, "IsInTenseCircumstance")
    local dialog_restricted = player_id and bool_call(soul, "IsDialogRestricted", player_id) or nil
    local can_talk = player_id and bool_call(actor, "CanTalk", player_id) or nil
    local can_chat = player_id and bool_call(actor, "CanChat", player_id) or nil
    local is_following = player_id and bool_call(actor, "IsFollowing", player_id) or nil
    local legal_loot = bool_call(soul, "IsLegalToLoot")
    local is_pickpocketing = bool_call(human, "IsPickpocketing")
    local health = bool_call(actor, "GetHealth")

    -- Health-delta tracking: detect "Henry hit me" events (PED has no damage event).
    if type(health) == "number" and ent.id ~= nil then
        local ok_h, err_h = pcall(track_npc_health_delta,
            tostring(ent.id), health,
            caption_name or entity_token or "")
        if not ok_h and not _G.__ai_npc_health_track_err_logged then
            _G.__ai_npc_health_track_err_logged = true
            System.LogAlways("[AI NPC] track_npc_health_delta error: " .. tostring(err_h))
        end
    end

    push_flag("dead", is_dead)
    push_flag("unconscious", is_unconscious)
    push_flag("in_combat", in_combat_mode)
    push_flag("combat_danger_nearby", in_combat_danger)
    push_flag("tense_circumstance", in_tense)
    push_flag("refuses_dialog", dialog_restricted)
    push_flag("willing_to_talk", can_talk)
    push_flag("willing_to_chat", can_chat)
    push_flag("currently_following_player", is_following)
    push_flag("legal_to_loot", legal_loot)
    push_flag("pickpocketing_player", is_pickpocketing)

    -- Faction-based hostility hint (heuristic from faction_id substrings).
    local faction_hostility = nil
    if type(faction_id) == "string" and faction_id ~= "" then
        local fl = faction_id:lower()
        if fl:find("enemies") or fl:find("bandit") or fl:find("hostile") or fl:find("cuman") then
            faction_hostility = "hostile"
        elseif fl:find("friends") or fl:find("ally") or fl:find("allies") then
            faction_hostility = "friendly"
        end
    end

    -- Animal / non-human entity classification.
    local class_str = tostring(ent.class or "")
    local entity_kind = "human"
    local animal_species = nil
    do
        local cl = class_str:lower()
        if cl:find("cattle") then entity_kind = "animal"; animal_species = "cow"
        elseif cl:find("horse") then entity_kind = "animal"; animal_species = "horse"
        elseif cl == "dog" or cl:find("^dog") then entity_kind = "animal"; animal_species = "dog"
        elseif cl:find("animal") or cl:find("sheep") or cl:find("pig") or cl:find("chicken")
            or cl:find("rabbit") or cl:find("rooster") or cl:find("hen") then
            entity_kind = "animal"
            animal_species = cl
        end
    end

    -- Derive a human-readable disposition summary.
    local disposition
    if is_dead then
        disposition = "dead"
    elseif is_unconscious then
        disposition = "unconscious"
    elseif in_combat_mode then
        disposition = "hostile (in active combat)"
    elseif faction_hostility == "hostile" then
        disposition = "hostile (enemy faction)"
    elseif dialog_restricted == true then
        disposition = "unwilling to talk to the player"
    elseif in_combat_danger or in_tense then
        disposition = "tense / wary (danger nearby)"
    elseif faction_hostility == "friendly" then
        disposition = "friendly (allied faction)"
    elseif can_talk == true or can_chat == true then
        disposition = "neutral / willing to talk"
    else
        disposition = "neutral (no special state)"
    end

    -- Parse faction id into region / settlement / group breadcrumbs.
    local faction_breadcrumb = nil
    if type(faction_id) == "string" and faction_id ~= "" then
        local parts = {}
        for p in faction_id:gmatch("[^_]+") do parts[#parts + 1] = p end
        if #parts >= 2 then
            faction_breadcrumb = table.concat(parts, " > ")
        end
    end

    context_lines[#context_lines + 1] = "Disposition toward player: " .. disposition
    if entity_kind == "animal" then
        context_lines[#context_lines + 1] = "Entity kind: animal" .. (animal_species and (" (" .. animal_species .. ")") or "")
        context_lines[#context_lines + 1] = "Note: this is a non-human animal. Speak in full human sentences (the player magically understands you), but naturally sprinkle the animal's characteristic sounds INSIDE your speech (e.g. cow: 'Здравствуй, мууу, путник'; pig: 'Хрю, я тут жёлуди ищу, хрю-хрю'; dog: 'Гав! Хороший ты, гав-гав, человек'). Do NOT use roleplay actions in asterisks like *виляет хвостом*."
    end
    if faction_hostility then
        context_lines[#context_lines + 1] = "Faction hostility hint: " .. faction_hostility
    end
    if faction_breadcrumb then
        context_lines[#context_lines + 1] = "Faction breakdown: " .. faction_breadcrumb
    end
    if #state_flags > 0 then
        context_lines[#context_lines + 1] = "State flags: " .. table.concat(state_flags, ", ")
    end
    if type(health) == "number" then
        context_lines[#context_lines + 1] = "Health: " .. tostring(health)
    end

    local npc_pos = nil
    local pos = safe_method_call(ent, "GetWorldPos") or safe_method_call(ent, "GetPos")
    if pos then
        npc_pos = { x = pos.x or 0, y = pos.y or 0, z = pos.z or 0 }
    end

    return {
        id = tostring(ent.id or entity_token or "unknown"),
        name = chosen_name or (entity_token or "Villager"),
        engine_name = entity_token or "Villager",
        entity_ref = ent,
        caption_name = caption_name,
        soul_token = soul_token,
        class = tostring(ent.class or ""),
        location = "",
        faction_id = faction_id,
        social_class = social_class,
        gender = gender,
        soul_name_key = soul_name_key,
        extra_context = table.concat(context_lines, "\n"),
        pos = npc_pos,
    }
end

local function get_entity_from_id(id)
    if id == nil or not System or type(System.GetEntity) ~= "function" then
        return nil
    end
    local ok, ent = pcall(System.GetEntity, id)
    if ok then return ent end
    return nil
end

local function add_candidate_entity(candidates, seen, ent)
    if not ent then return end
    local key = tostring(ent.id or ent)
    if seen[key] then return end
    seen[key] = true
    candidates[#candidates + 1] = ent
end

local function resolve_npc_entity_from_hit(hit_entity)
    if not hit_entity then return nil end
    local candidates = {}
    local seen = {}

    add_candidate_entity(candidates, seen, hit_entity)

    local owner_ent = safe_method_call(hit_entity, "GetOwner")
    if type(owner_ent) == "number" or type(owner_ent) == "string" then
        owner_ent = get_entity_from_id(owner_ent)
    end
    add_candidate_entity(candidates, seen, owner_ent)

    local parent_ent = safe_method_call(hit_entity, "GetParent")
    if type(parent_ent) == "number" or type(parent_ent) == "string" then
        parent_ent = get_entity_from_id(parent_ent)
    end
    add_candidate_entity(candidates, seen, parent_ent)

    local parent_by_id = safe_method_call(hit_entity, "GetParentId")
    add_candidate_entity(candidates, seen, get_entity_from_id(parent_by_id))

    for _, ent in ipairs(candidates) do
        if is_npc_entity(ent) then
            return ent
        end
    end

    return nil
end

-- =======================================================================
-- "Поговорить" interaction prompt: override entity.GetActions on the NPC
-- that the player is aiming at. Modelled after the Mercenaries mod
-- (mercenaries_lookatinteraction.lua). The prompt itself does not start
-- the chat — it's purely a visual hint that V will work on this NPC.
-- The V keybind already triggers AI_NPC_ToggleChat via ActionMap.
-- =======================================================================
_G.__ai_npc_injected_ents = _G.__ai_npc_injected_ents or {}

-- Load dynamic chat action name from server-written config (if present).
-- Falls back to companion_bond (V) if the file is missing or empty.
_G.AI_NPC_CHAT_ACTION = "companion_bond"
_G.AI_NPC_CHAT_KEY    = "v"

-- Try to load the server-written action config immediately at mod startup.
-- This must happen BEFORE the player ever aims at an NPC, otherwise the
-- first injection caches the fallback action and the glyph never updates.
if type(dofile) == "function" then
    local startup_paths = {
        "scripts/ai_npc/chat_action.lua",
        "Scripts/ai_npc/chat_action.lua",
        "data/scripts/ai_npc/chat_action.lua",
        "Data/Scripts/ai_npc/chat_action.lua",
    }
    for _, p in ipairs(startup_paths) do
        local ok, err = pcall(dofile, p)
        if ok then
            System.LogAlways("[AI NPC] Startup chat_action loaded: action=" ..
                tostring(_G.AI_NPC_CHAT_ACTION) .. " key=" .. tostring(_G.AI_NPC_CHAT_KEY))
            _G.__ai_npc_chat_action_loaded = true
            break
        else
            if not _G.__ai_npc_chat_action_startup_err then
                _G.__ai_npc_chat_action_startup_err = true
                System.LogAlways("[AI NPC] Startup chat_action error: " .. tostring(p) .. " err=" .. tostring(err))
            end
        end
    end
end

local function inject_ai_interaction(ent)
    if not ent then return end
    local key = tostring(ent.id or (ent.GetName and ent:GetName()) or "")
    if key == "" then return end
    if _G.__ai_npc_injected_ents[key] then return end

    -- Need an NPC-like entity (has actor + soul).
    if not (ent.actor and ent.soul) then return end

    local orig_get_actions = ent.GetActions
    ent.GetActions = function(self, user, firstFast)
        local output = {}
        local ok_base, base = pcall(function()
            if orig_get_actions then
                return orig_get_actions(self, user, firstFast)
            elseif BasicAIActions and BasicAIActions.GetActions then
                return BasicAIActions.GetActions(self, user, firstFast)
            end
            return nil
        end)
        if ok_base and base then
            for _, a in pairs(base) do table.insert(output, a) end
        end

        -- One-shot diagnostic: log the first time GetActions is called after injection.
        local diag_key = tostring(self.id or "") .. "_ga"
        if not _G["__ai_npc_diag_" .. diag_key] then
            _G["__ai_npc_diag_" .. diag_key] = true
            System.LogAlways("[AI NPC] GetActions called for " .. tostring(self.GetName and self:GetName() or "?") ..
                " firstFast=" .. tostring(firstFast) .. " base_actions=" .. tostring(base and #base or 0) ..
                " output_before_add=" .. tostring(#output))
        end

        if self.actor and not self.actor:IsDead() and not self.actor:IsUnconscious() then
            -- Ensure the ai_npc action map is active so the V-key icon renders.
            if ActionMapManager and ActionMapManager.EnableActionMap then
                pcall(ActionMapManager.EnableActionMap, "ai_npc", true)
            end
            local ok_add, add_err = pcall(function()
                local act = Action()
                    :hint("ui_ai_npc_talk")
                    :hintType(AHT_RELEASE)
                local chat_action = (_G.AI_NPC_CHAT_ACTION or "")
                if chat_action ~= "" then
                    act:action(chat_action)
                end
                AddInteractorAction(output, firstFast,
                    act
                        :uiOrder(2)
                        :func(function(this, usr)
                            -- This native CryEngine action runs whenever the
                            -- player presses the key bound to "ai_npc_chat"
                            -- (V by default) while aiming at an NPC. Use it
                            -- as a reliable trigger to (re)arm the polling
                            -- timer — the bootstrap-time Script.SetTimer
                            -- silently no-ops on the rolled-back GOG DLL.
                            -- We do NOT toggle the chat here: the Python
                            -- KeyMonitor + __AI_NPC_TAP__ pipeline is the
                            -- single source of truth for tap-vs-hold so we
                            -- avoid a double-toggle race.
                            if rearm_poll_from_user_context then
                                pcall(rearm_poll_from_user_context)
                            end
                            if System and System.LogAlways then
                                System.LogAlways("[AI NPC] Interaction action ai_npc_chat fired — poll re-armed")
                            end
                        end)
                )
            end)
            if not ok_add then
                System.LogAlways("[AI NPC] AddInteractorAction err: " .. tostring(add_err))
            end
        end
        return output
    end

    _G.__ai_npc_injected_ents[key] = true
    System.LogAlways("[AI NPC] Injected GetActions on entity key=" .. key)
end

-- Lightweight version of the target raycast used by the poll loop to
-- pre-inject the prompt before the player presses V. Skips name lookup
-- and other expensive work.
local function scan_and_inject_target()
    if state.chat_open then return end
    if not (Physics and Physics.RayWorldIntersection) then return end
    if not (System and System.GetViewCameraDir) then return end
    local p = get_player_entity()
    if not p or not p.GetPos then return end
    local from = p:GetPos()
    if not from then return end
    from = { x = from.x, y = from.y, z = (from.z or 0) + 1.615 }
    local view = System.GetViewCameraDir()
    if not view then return end
    local dir = {
        x = (view.x or 0) * CONFIG.target_ray_distance,
        y = (view.y or 0) * CONFIG.target_ray_distance,
        z = (view.z or 0) * CONFIG.target_ray_distance,
    }
    local hitData = {}
    local hits = Physics.RayWorldIntersection(from, dir, 8,
        ent_all or -1, p.id, nil, hitData)
    if not hits or hits <= 0 then return end
    for i = 1, hits do
        local h = hitData[i]
        if h and h.entity then
            local r = resolve_npc_entity_from_hit and resolve_npc_entity_from_hit(h.entity) or h.entity
            if r then
                inject_ai_interaction(r)
                -- Cheap health snapshot to establish a baseline before any combat.
                -- track_npc_health_delta will compare and emit a synthetic Hit event if drops.
                if r.actor and r.id ~= nil then
                    local ok_g, hp = pcall(function() return r.actor:GetHealth() end)
                    if ok_g and type(hp) == "number" then
                        local nm = (r.GetName and r:GetName()) or ""
                        pcall(track_npc_health_delta, tostring(r.id), hp, tostring(nm))
                    end
                end
                -- Re-aiming at the same NPC during an open chat counts as activity.
                if state.chat_open and state.current_npc
                        and tostring(state.current_npc.id) == tostring(r.id) then
                    state.last_activity_at = os.clock()
                end
                return
            end
        end
    end
end

function AI_NPC_ScanInject()
    scan_and_inject_target()
end

-- Debounced version used by the polling loop. When Player Event Dispatcher
-- fired an inject recently we skip the raycast to save CPU.
local SCAN_DEBOUNCE_SEC = 4.0  -- if event fired within last N sec, skip poll-scan
local function scan_and_inject_target_debounced()
    if state.dispatcher_mode == "events" then
        local now = (System and System.GetCurrTime and System.GetCurrTime()) or os.clock()
        if (now - (state.last_event_inject_at or -1000.0)) < SCAN_DEBOUNCE_SEC then
            return  -- event-driven inject just happened, no need to re-scan
        end
    end
    scan_and_inject_target()
end

local function get_targeted_npc()
    local p = get_player_entity()
    if not p or not p.GetPos then return nil end
    if not (Physics and Physics.RayWorldIntersection) then return nil end
    if not (System and System.GetViewCameraDir) then return nil end

    local from = p:GetPos()
    if not from then return nil end
    from = { x = from.x, y = from.y, z = (from.z or 0) + 1.615 }

    local view = System.GetViewCameraDir()
    if not view then return nil end
    local dir = {
        x = (view.x or 0) * CONFIG.target_ray_distance,
        y = (view.y or 0) * CONFIG.target_ray_distance,
        z = (view.z or 0) * CONFIG.target_ray_distance,
    }

    local entMask = ent_all or -1
    local skip = p.id
    local hitData = {}
    local max_hits = 16
    local hits = Physics.RayWorldIntersection(from, dir, max_hits, entMask, skip, nil, hitData)
    if not hits or hits <= 0 then
            return nil
    end

    local hit = nil
    local resolved = nil
    local hit_index = nil
    for i = 1, hits do
        local h = hitData[i]
        if h and h.entity then
            local r = resolve_npc_entity_from_hit(h.entity)
            if r then
                hit = h
                resolved = r
                hit_index = i
                break
            end
        end
    end
    if not hit or not resolved then
        return nil
    end

    -- Make sure the "Поговорить" prompt is attached to this entity going
    -- forward (in case the poll-side scanner hasn't injected it yet).
    inject_ai_interaction(resolved)

    local ok_npc, npc = pcall(build_npc_from_entity, resolved)
    if not ok_npc then
        System.LogAlways("[AI NPC] build_npc_from_entity crashed: " .. tostring(npc))
        return nil
    end
    if not npc then
        System.LogAlways("[AI NPC] build_npc_from_entity returned nil for entity=" .. tostring(resolved and resolved.id or "?"))
        return nil
    end
    if npc and hit.dist ~= nil then
        npc.target_distance = hit.dist
        npc.extra_context = (npc.extra_context ~= "" and (npc.extra_context .. "\n") or "") .. "Target distance: " .. tostring(hit.dist)
        npc.extra_context = npc.extra_context .. "\nRay hit index: " .. tostring(hit_index or "?")
        npc.extra_context = npc.extra_context .. "\nRay hit class: " .. tostring(hit.entity.class or "")
        npc.extra_context = npc.extra_context .. "\nResolved class: " .. tostring(resolved.class or "")
    end
    return npc
end

function AI_NPC_TargetDebug()
    local p = get_player_entity()
    if not p or not p.GetPos or not (Physics and Physics.RayWorldIntersection) or not (System and System.GetViewCameraDir) then
        ui_show("AI NPC: target debug unavailable", 4000, { service = true })
        return
    end
    local from = p:GetPos()
    if not from then
        ui_show("AI NPC: no player pos", 3000, { service = true })
        return
    end
    from = { x = from.x, y = from.y, z = (from.z or 0) + 1.615 }
    local view = System.GetViewCameraDir()
    if not view then
        ui_show("AI NPC: no camera dir", 3000, { service = true })
        return
    end
    local dir = {
        x = (view.x or 0) * CONFIG.target_ray_distance,
        y = (view.y or 0) * CONFIG.target_ray_distance,
        z = (view.z or 0) * CONFIG.target_ray_distance,
    }
    local hitData = {}
    local max_hits = 16
    local hits = Physics.RayWorldIntersection(from, dir, max_hits, ent_all or -1, p.id, nil, hitData)
    if not hits or hits <= 0 then
        ui_show("AI NPC: ray hit none", 3000, { service = true })
        return
    end
    local hit = nil
    local raw = nil
    local resolved = nil
    local hit_index = nil
    for i = 1, hits do
        local h = hitData[i]
        if h and h.entity then
            local r = resolve_npc_entity_from_hit(h.entity)
            if r then
                hit = h
                raw = h.entity
                resolved = r
                hit_index = i
                break
            end
        end
    end
    if not raw then
        local first = hitData[1]
        if first and first.entity then
            raw = first.entity
        end
    end
    local msg = "AI NPC target: hits=" .. tostring(hits) .. ", idx=" .. tostring(hit_index or "nil")
    if raw then
        msg = msg .. ", raw=" .. tostring((raw.GetName and raw:GetName()) or raw.id or "?") .. " [" .. tostring(raw.class or "") .. "]"
    else
        msg = msg .. ", raw=nil"
    end
    if resolved then
        msg = msg .. " -> resolved=" .. tostring((resolved.GetName and resolved:GetName()) or resolved.id or "?") .. " [" .. tostring(resolved.class or "") .. "]"
    else
        msg = msg .. " -> resolved=nil"
    end
    ui_show(msg, 7000)
    System.LogAlways("[AI NPC] TARGET_DEBUG|" .. msg)
end

local function _get_player_pos_fwd()
    local player_pos = nil
    local player_fwd = nil
    local p = get_player_entity()
    if p and p.GetPos then
        local ok_pp, pp = pcall(p.GetPos, p)
        if ok_pp and pp then
            player_pos = { x = pp.x or 0, y = pp.y or 0, z = pp.z or 0 }
        end
    end
    if System and System.GetViewCameraDir then
        local ok_vf, vf = pcall(System.GetViewCameraDir)
        if ok_vf and vf then
            player_fwd = { x = vf.x or 0, y = vf.y or 0, z = vf.z or 0 }
        end
    end
    return player_pos, player_fwd
end

local function npc_debug_probe(npc)
    if not npc then return end
    local actions = {}
    local ok_acts, acts = pcall(build_recent_player_actions, npc.id)
    if ok_acts and type(acts) == "table" then actions = acts end
    local compact_actions = {}
    local start_i = math.max(1, #actions - 7)
    for i = start_i, #actions do
        local a = actions[i]
        if type(a) == "table" then
            local item = {
                event = a.event,
                seconds_ago = a.seconds_ago,
            }
            if a.same_npc then item.same_npc = true end
            if a.npc_id then item.npc_id = a.npc_id end
            if a.npc_name and a.npc_name ~= "" then
                item.npc_name = tostring(a.npc_name):sub(1, 80)
            end
            if a.hp_delta ~= nil then item.hp_delta = a.hp_delta end
            compact_actions[#compact_actions + 1] = item
        end
    end
    local player_pos, player_fwd = _get_player_pos_fwd()
    System.LogAlways("[AI NPC] TARGET|" .. json.encode({
        id = npc.id,
        name = npc.name,
        class = npc.class,
        faction_id = npc.faction_id,
        social_class = npc.social_class,
        gender = npc.gender,
        soul_name_key = npc.soul_name_key,
        target_distance = npc.target_distance,
        recent_player_actions = compact_actions,
        npc_pos = npc.pos,
        player_pos = player_pos,
        player_fwd = player_fwd,
    }))
    if npc.extra_context and npc.extra_context ~= "" then
        System.LogAlways("[AI NPC] TARGET_CTX|" .. tostring(npc.extra_context):gsub("\n", " | "))
    end
end

local function publish_current_target_once()
    if state.chat_open then return end
    local ok, npc = pcall(get_targeted_npc)
    if ok and npc then
        state.last_target_npc_id = npc.id
        state.last_target_entity_ref = npc.entity_ref
        npc_debug_probe(npc)
    end
end

-- HTTP POST (async via KCD2ModLoader net module if available, otherwise sync)
local pending_request = nil

local function use_overlay_ui()
    return CONFIG.ui_mode == "overlay"
end

-- HUD position toggles (set by chat_resp.txt prefix from server, default to all-on).
if _G.__ai_npc_hud_left == nil then _G.__ai_npc_hud_left = true end
if _G.__ai_npc_hud_right == nil then _G.__ai_npc_hud_right = true end
if _G.__ai_npc_hud_center == nil then _G.__ai_npc_hud_center = true end
if _G.__ai_npc_hud_narrator == nil then _G.__ai_npc_hud_narrator = true end
if _G.__ai_npc_hud_narrator_left == nil then _G.__ai_npc_hud_narrator_left = false end
if _G.__ai_npc_hud_narrator_right == nil then _G.__ai_npc_hud_narrator_right = true end
if _G.__ai_npc_hud_narrator_center == nil then _G.__ai_npc_hud_narrator_center = false end

-- Show text above an entity's head (world-space) like scripted dialogue.
-- CryAction.SendGameplayEvent with "ShowInfoText" is the working KCD2 API.
local function show_text_above_entity(entity, text, duration)
    if not entity or not text or text == "" then return end
    duration = duration or 5000
    if CryAction and type(CryAction.SendGameplayEvent) == "function" then
        pcall(CryAction.SendGameplayEvent, entity.id, "ShowInfoText", text, duration)
    end
end

-- ui_show(message, duration, opts)
-- opts.service = true  -> force ONLY top-right notification (no center subtitle,
--                        no left tutorial). Use for non-roleplay UX strings.
-- opts.style overrides _G.__ai_npc_hud_style for one-off calls.
local function ui_show(message, duration, opts)
    duration = duration or 8000
    opts = opts or {}
    local service_only = opts.service == true
    local text = tostring(message)
    local style = opts.style or _G.__ai_npc_hud_style or "gold"
    local show_left = (not service_only) and (style == "gold") and (_G.__ai_npc_hud_left ~= false)
    local show_right = (style == "gold") and (_G.__ai_npc_hud_right ~= false)
    local show_center = (not service_only) and (_G.__ai_npc_hud_center ~= false)
    System.LogAlways(string.format(
        "[AI NPC] HUD: style=%s left=%s right=%s center=%s service=%s text=%s",
        tostring(style), tostring(show_left), tostring(show_right), tostring(show_center),
        tostring(service_only), text
    ))

    if style == "minimal" then
        -- Plain white text in the center (like scripted barks / info text).
        if show_center and CryAction and type(CryAction.SendGameplayEvent) == "function" then
            local ok, err = pcall(CryAction.SendGameplayEvent, 0, "ShowInfoText", text, duration)
            if ok then
                System.LogAlways("[AI NPC] HUD method ok: CryAction.SendGameplayEvent (minimal)")
            else
                System.LogAlways("[AI NPC] HUD minimal error: " .. tostring(err))
            end
        end
        -- Fallback to UIAction if CryAction unavailable.
        if show_center and UIAction and UIAction.CallFunction then
            local ok, err = pcall(UIAction.CallFunction, "HUD", -1, "ShowInfoText", text, 10, duration, true)
            if ok then
                System.LogAlways("[AI NPC] HUD method ok: UIAction.ShowInfoText (minimal)")
            else
                System.LogAlways("[AI NPC] HUD minimal fallback error: " .. tostring(err))
            end
        end
        return
    end

    if style == "subtitle" then
        -- In-game subtitle style (CryAction.SetSubtitle or similar).
        if show_center and CryAction and type(CryAction.SetSubtitle) == "function" then
            local ok, err = pcall(CryAction.SetSubtitle, 0, text, duration / 1000)
            if ok then
                System.LogAlways("[AI NPC] HUD method ok: CryAction.SetSubtitle (subtitle)")
                return
            else
                System.LogAlways("[AI NPC] HUD subtitle error: " .. tostring(err))
            end
        end
        -- Fallback to gold style if subtitle API missing.
        style = "gold"
    end

    if style == "gold" then
        -- Center-bottom: italic gold subtitle with ornament.
        if show_center and Game and Game.ShowTutorial then
            local sec = math.max(1, math.floor(duration / 1000))
            local ok_tut, err_tut = pcall(Game.ShowTutorial, text, sec)
            if ok_tut then
                System.LogAlways("[AI NPC] HUD method ok: Game.ShowTutorial (gold)")
            else
                System.LogAlways("[AI NPC] HUD Game.ShowTutorial error: " .. tostring(err_tut))
            end
        end

        if UIAction and UIAction.CallFunction then
            local candidates = {
                { show_center, "HUD", "ShowInfoText",        text, 10, duration, true },
                { show_left,   "HUD", "ShowTutorial",        "AI_NPC_Chat", text, duration, false, 0, 0, false, "" },
                { show_right,  "HUD", "SetNotificationText", text },
                { show_right,  "HUD", "ShowNotification",    text, duration },
            }
            for _, c in ipairs(candidates) do
                if c[1] then
                    local elem, method = c[2], c[3]
                    local args = {}
                    for i = 4, #c do args[#args + 1] = c[i] end
                    local ok_call, result = pcall(UIAction.CallFunction, elem, -1, method, unpack(args))
                    if ok_call then
                        System.LogAlways("[AI NPC] HUD method ok: " .. tostring(elem) .. "." .. tostring(method) .. " result=" .. tostring(result))
                    else
                        System.LogAlways("[AI NPC] HUD method error: " .. tostring(elem) .. "." .. tostring(method) .. " err=" .. tostring(result))
                    end
                end
            end
        else
            System.LogAlways("[AI NPC] HUD UIAction.CallFunction unavailable")
        end
    end
end

local function ui_show_narrator(message, duration)
    local old_left = _G.__ai_npc_hud_left
    local old_right = _G.__ai_npc_hud_right
    local old_center = _G.__ai_npc_hud_center
    _G.__ai_npc_hud_left = _G.__ai_npc_hud_narrator_left == true
    _G.__ai_npc_hud_right = _G.__ai_npc_hud_narrator_right == true
    _G.__ai_npc_hud_center = _G.__ai_npc_hud_narrator_center == true
    ui_show(message, duration)
    _G.__ai_npc_hud_left = old_left
    _G.__ai_npc_hud_right = old_right
    _G.__ai_npc_hud_center = old_center
end

local function probe_ui_input_methods()
    if not (UIAction and UIAction.CallFunction) then
        System.LogAlways("[AI NPC] Probe: UIAction.CallFunction unavailable")
        return 0
    end

    local candidates = {
        { element = "HUD",  method = "ShowTextInput",       args = {"AI_NPC_Input", "", 128} },
        { element = "HUD",  method = "OpenTextInput",       args = {"AI_NPC_Input", "", 128} },
        { element = "HUD",  method = "ShowInputDialog",     args = {"AI_NPC_Input", "", 128} },
        { element = "HUD",  method = "ShowKeyboard",        args = {"AI_NPC_Input", ""} },
        { element = "Menu", method = "PreparePage",         args = {1500, 380, 3, "@ui_mod_overview", 860} },
        { element = "Menu", method = "AddInputButton",      args = {"ai_input", 0, "@ui_message", "", false} },
        { element = "Menu", method = "AddEditButton",       args = {"ai_input", 0, "@ui_message", "", false} },
        { element = "Menu", method = "AddTextInput",        args = {"ai_input", 0, "@ui_message", "", false} },
        { element = "Menu", method = "SetText",             args = {"ai_input", 0, "test"} },
        { element = "Menu", method = "GetText",             args = {"ai_input", 0} },
        { element = "Menu", method = "IsSomeButtonChanged", args = {} },
    }

    local ok_count = 0
    for _, c in ipairs(candidates) do
        local params = { c.element, -1, c.method }
        for _, a in ipairs(c.args) do params[#params + 1] = a end
        local ok, result = pcall(UIAction.CallFunction, table.unpack(params))
        if ok then
            ok_count = ok_count + 1
            System.LogAlways("[AI NPC] Probe OK: " .. c.element .. "." .. c.method .. " -> " .. tostring(result))
        else
            System.LogAlways("[AI NPC] Probe FAIL: " .. c.element .. "." .. c.method)
        end
    end

    System.LogAlways("[AI NPC] Probe complete. OK methods: " .. tostring(ok_count))
    return ok_count
end

function AI_NPC_ProbeUIInput()
    System.LogAlways("[AI NPC] Probe command invoked")
    local n = probe_ui_input_methods()
    ui_show("AI NPC: UI probe завершён. Успешных методов: " .. tostring(n), 6000, { service = true })
end

local function npc_display_name(raw_name, npc_class)
    local direct = tostring(raw_name or "")
    local direct_trim = direct:gsub("^%s+", ""):gsub("%s+$", "")

    local translated_direct = localize_npc_name_ru(direct_trim, nil, nil, npc_class, nil, nil)
    if translated_direct and tostring(translated_direct):gsub("^%s+", ""):gsub("%s+$", "") ~= "" then
        direct_trim = tostring(translated_direct)
    end

    if direct_trim ~= "" and direct_trim ~= "Villager" and direct_trim ~= "NPC" then
        return direct_trim
    end

    local name = string.lower(direct_trim)
    local class_name = string.lower(tostring(npc_class or ""))
    if class_name == "guard" then return "Стражник" end
    if class_name == "merchant" then return "Торговец" end
    if class_name == "blacksmith" then return "Кузнец" end
    if class_name == "shoemaker" then return "Сапожник" end
    if class_name == "tailor" then return "Портной" end
    if class_name == "beggar" then return "Нищий" end
    if name:find("woman") or name:find("female") then return "Жительница" end
    if name:find("man") or name:find("male") then return "Житель" end
    return "NPC"
end

local function notify_active_npc()
    if state.chat_open and state.current_npc then
        local actions = {}
        local ok_acts, acts = pcall(build_recent_player_actions, state.current_npc.id)
        if ok_acts and type(acts) == "table" then actions = acts end
        local player_pos, player_fwd = _get_player_pos_fwd()
        local npc_pos = state.current_npc.pos
        if state.current_npc.entity_ref then
            local live_pos = safe_method_call(state.current_npc.entity_ref, "GetWorldPos") or safe_method_call(state.current_npc.entity_ref, "GetPos")
            if live_pos then
                npc_pos = { x = live_pos.x or 0, y = live_pos.y or 0, z = live_pos.z or 0 }
                state.current_npc.pos = npc_pos
            end
        end
        System.LogAlways("[AI NPC] ACTIVE|" .. json.encode({
            npc_id = state.current_npc.id,
            npc_name = state.current_npc.name,
            npc_class = state.current_npc.class,
            npc_location = state.current_npc.location,
            soul_name_key = state.current_npc.soul_name_key,
            extra_context = state.current_npc.extra_context,
            recent_player_actions = actions,
            gender = state.current_npc.gender,
            npc_pos = npc_pos,
            player_pos = player_pos,
            player_fwd = player_fwd,
        }))
    else
        System.LogAlways("[AI NPC] ACTIVE|{}")
    end
end

local function http_post(endpoint, data, callback)
    local url = CONFIG.server_url .. endpoint
    local body = tostring(json.encode(data) or "{}")
    System.LogAlways("[AI NPC] HTTP POST " .. tostring(endpoint) .. " body_len=" .. tostring(#body))

    local net_client, provider = resolve_http_provider()
    if not (net_client and net_client.http_post) then
        callback(nil, "HTTP module unavailable")
        return
    end

    local ok_call, call_err = pcall(function()
        System.LogAlways("[AI NPC] HTTP provider=" .. tostring(provider))
        net_client.http_post(url, body, "application/json", function(status, response_body)
            local ok_cb, cb_err = pcall(function()
                local code = tonumber(status) or 0
                if code >= 200 and code < 300 then
                    callback(json.decode(response_body or ""), nil)
                else
                    callback(nil, "HTTP " .. tostring(status))
                end
            end)
            if not ok_cb then
                System.LogAlways("[AI NPC] HTTP callback error: " .. tostring(cb_err))
                callback(nil, "HTTP callback error")
            end
        end)
    end)

    if not ok_call then
        System.LogAlways("[AI NPC] HTTP client call failed: " .. tostring(call_err))
        callback(nil, "HTTP client call failed")
    end
end

function AI_NPC_HandleWebCommand(message, command_id)
    if command_id <= last_web_command_id then return end
    last_web_command_id = command_id
    -- Special control messages emitted by the server (no LLM round-trip).
    -- "__AI_NPC_TAP__" is sent by server/key_monitor.py when the player taps V
    -- (release < ptt_hold_threshold_ms) so the chat overlay can be opened
    -- without a CryEngine bind on V — the engine itself ignores V when the
    -- server-side PTT key monitor is active.
    if type(message) == "string" and message:sub(1, 2) == "__" then
        if message == "__AI_NPC_TAP__" then
            System.LogAlways("[AI NPC] Web cmd: __AI_NPC_TAP__ -> AI_NPC_Toggle()")
            pcall(process_resp_file)
            toggle_chat_with_debounce("server-tap")
            return
        end
        if message == "__AI_NPC_PUBLISH_TARGET__" then
            System.LogAlways("[AI NPC] Web cmd: __AI_NPC_PUBLISH_TARGET__")
            pcall(publish_current_target_once)
            return
        end
        if message == "__AI_NPC_FORCE_UNBIND_V__" then
            -- Sent by the Python server on startup / KeyMonitor (re)start so
            -- that any legacy `bind v ai_chat` left over from an older Lua
            -- run is cleared without requiring the user to restart the game
            -- or type `unbind v` in the console manually.
            local key = (CONFIG and CONFIG.chat_key) or "v"
            if System and System.ExecuteCommand then
                pcall(System.ExecuteCommand, "unbind " .. key)
            end
            _G.__ai_npc_binds_done = nil
            last_synced_chat_key = nil
            _G.__ai_npc_unbind_v_done = nil
            System.LogAlways(
                "[AI NPC] Web cmd: __AI_NPC_FORCE_UNBIND_V__ — unbound '" ..
                tostring(key) .. "' on demand"
            )
            return
        end
        System.LogAlways("[AI NPC] Web cmd: unknown control message: " .. tostring(message))
        return
    end
    AI_NPC_Say(message)
end

_G.__ai_npc_swallow_only = _G.__ai_npc_swallow_only or false
_G.__ai_npc_lingering_ids = _G.__ai_npc_lingering_ids or {}

local function scene_memory_for_npc(npc_id)
    local key = tostring(npc_id or "")
    if key == "" then key = "unknown" end
    state.npc_scene_memory = state.npc_scene_memory or {}
    state.npc_scene_memory[key] = state.npc_scene_memory[key] or {
        warning_count = 0,
        refused_until = 0,
        danger = false,
        strip_level = 0,  -- 0 = fully clothed, 1 = partial (upper off), 2 = fully nude
    }
    return state.npc_scene_memory[key], key
end

local function scene_refusal_text(mem)
    local warnings = tonumber(mem and mem.warning_count) or 0
    if warnings >= 3 then
        return "NPC: Я уже сказал — отойди, пока не стало хуже."
    end
    return "NPC: Я не хочу сейчас с тобой говорить."
end

local function scene_refusal_active(npc_id)
    local mem = scene_memory_for_npc(npc_id)
    return tonumber(mem.refused_until or 0) > os.clock(), mem
end

local function scene_action_feedback(npc_name, action, intent)
    local name = tostring(npc_name or "NPC")
    if action == "walk_away" then
        return name .. " отворачивается и делает вид, что больше не слушает."
    elseif action == "call_help" or intent == "call_help" then
        return name .. " оглядывается, будто собирается позвать на помощь."
    elseif action == "draw_weapon" then
        return name .. " достаёт оружие и смотрит настороженно."
    elseif action == "step_back" then
        return name .. " делает шаг назад и смотрит настороженно."
    end
    return nil
end

local function scene_resolve_entity(scene)
    local npc_id = scene and scene.npc_id or nil
    if state.current_npc and state.current_npc.entity_ref then
        if npc_id == nil or tostring(npc_id) == "" or tostring(state.current_npc.id) == tostring(npc_id) then
            return state.current_npc.entity_ref
        end
    end
    if state.last_request_entity_ref then
        if npc_id == nil or tostring(npc_id) == "" or tostring(state.last_request_npc_id) == tostring(npc_id) then
            return state.last_request_entity_ref
        end
    end
    if state.last_target_entity_ref then
        if npc_id == nil or tostring(npc_id) == "" or tostring(state.last_target_npc_id) == tostring(npc_id) then
            return state.last_target_entity_ref
        end
    end
    local ent = get_entity_from_id(npc_id)
    if ent then return ent end
    if state.current_npc and state.current_npc.engine_name and System and type(System.GetEntityByName) == "function" then
        local ok, named = pcall(System.GetEntityByName, state.current_npc.engine_name)
        if ok and named then return named end
    end
    return nil
end

local function scene_get_pos(ent)
    return safe_method_call(ent, "GetWorldPos") or safe_method_call(ent, "GetPos")
end

local function scene_set_pos(ent, pos)
    if not ent or type(pos) ~= "table" then return false end
    local fn = ent.SetWorldPos or ent.SetPos
    if type(fn) ~= "function" then return false end
    local ok = pcall(fn, ent, pos)
    return ok == true
end

local function scene_move_away_from_player(ent, distance)
    local player_ent = get_player_entity()
    local npc_pos = scene_get_pos(ent)
    local player_pos = scene_get_pos(player_ent)
    if type(npc_pos) ~= "table" or type(player_pos) ~= "table" then return false end
    local dx = (tonumber(npc_pos.x) or 0) - (tonumber(player_pos.x) or 0)
    local dy = (tonumber(npc_pos.y) or 0) - (tonumber(player_pos.y) or 0)
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 0.01 then
        dx = 1
        dy = 0
        len = 1
    end
    local d = tonumber(distance) or 1.0
    local new_pos = {
        x = (tonumber(npc_pos.x) or 0) + dx / len * d,
        y = (tonumber(npc_pos.y) or 0) + dy / len * d,
        z = tonumber(npc_pos.z) or 0,
    }
    return scene_set_pos(ent, new_pos)
end

local function scene_move_towards_player(ent, distance)
    local player_ent = get_player_entity()
    local npc_pos = scene_get_pos(ent)
    local player_pos = scene_get_pos(player_ent)
    if type(npc_pos) ~= "table" or type(player_pos) ~= "table" then return false end
    local dx = (tonumber(player_pos.x) or 0) - (tonumber(npc_pos.x) or 0)
    local dy = (tonumber(player_pos.y) or 0) - (tonumber(npc_pos.y) or 0)
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 1.25 then return false end
    local d = math.min(tonumber(distance) or 0.75, math.max(0, len - 1.15))
    local new_pos = {
        x = (tonumber(npc_pos.x) or 0) + dx / len * d,
        y = (tonumber(npc_pos.y) or 0) + dy / len * d,
        z = tonumber(npc_pos.z) or 0,
    }
    return scene_set_pos(ent, new_pos)
end

local function scene_send_ai_signal(ent, signal)
    if not ent or not AI or type(AI.Signal) ~= "function" then return false end
    local filter = rawget(_G, "SIGNALFILTER_SENDER") or 1
    local ok = pcall(AI.Signal, filter, 1, signal, ent.id or ent)
    return ok == true
end

local function scene_look_at_player(ent)
    if state.disable_scene_temporary_look then
        System.LogAlways("[AI NPC] SCENE_ACTION look_at_player skipped: temporary look disabled")
        return false
    end
    if not ent or type(ent.actor) ~= "table" then return false end
    local player_ent = get_player_entity()
    if not player_ent then return false end
    local ok_any = false
    if type(ent.actor.SetForcedLookDir) == "function" then
        local npc_pos = scene_get_pos(ent)
        local player_pos = scene_get_pos(player_ent)
        if type(npc_pos) == "table" and type(player_pos) == "table" then
            local dir = {
                x = (tonumber(player_pos.x) or 0) - (tonumber(npc_pos.x) or 0),
                y = (tonumber(player_pos.y) or 0) - (tonumber(npc_pos.y) or 0),
                z = ((tonumber(player_pos.z) or 0) + 1.5) - ((tonumber(npc_pos.z) or 0) + 1.5),
            }
            local ok = pcall(function() return ent.actor:SetForcedLookDir(dir) end)
            ok_any = ok_any or ok
            if ok and Script and type(Script.SetTimer) == "function" then
                pcall(Script.SetTimer, 2200, function()
                    if ent and type(ent.actor) == "table" and type(ent.actor.SetForcedLookDir) == "function" then
                        pcall(function() return ent.actor:SetForcedLookDir({ x = 0, y = 0, z = 0 }) end)
                        System.LogAlways("[AI NPC] SCENE_ACTION look_at_player temporary look reset")
                    end
                end)
            end
        end
    end
    return ok_any
end

local function scene_draw_weapon(ent)
    if not ent or type(ent.human) ~= "table" then return false end
    if type(ent.human.IsWeaponDrawn) == "function" then
        local ok_drawn, is_drawn = pcall(function() return ent.human:IsWeaponDrawn() end)
        if ok_drawn and is_drawn then return true end
    end
    if type(ent.human.DrawWeapon) == "function" then
        local ok = pcall(function() return ent.human:DrawWeapon() end)
        if ok then return true end
    end
    if type(ent.human.ToggleWeapon) == "function" then
        local ok = pcall(function() return ent.human:ToggleWeapon() end)
        if ok then return true end
    end
    return false
end

local function scene_play_anim(ent, anims)
    if not ent then return false end
    if type(anims) ~= "table" then return false end
    local ok_any = false
    for _, anim in ipairs(anims) do
        -- entity:StartAnimation(layer, name, blendTime, speed, bLoop, 1) — works for .caf in loaded DBA
        if type(ent.StartAnimation) == "function" then
            local ok_call, result = pcall(function() return ent:StartAnimation(0, anim, 0, 0, 1, false, 1) end)
            System.LogAlways("[AI NPC] DIAG anim try ent:StartAnimation(0,'" .. tostring(anim) .. "') ok=" .. tostring(ok_call) .. " result=" .. tostring(result))
            if ok_call then
                -- result may be nil even on success; treat ok_call as success
                return true
            end
        end
        -- Fallback: actor:StartAnimation (older signatures)
        if type(ent.actor) == "table" and type(ent.actor.StartAnimation) == "function" then
            local ok_call, result = pcall(function() return ent.actor:StartAnimation(0, anim, 0) end)
            System.LogAlways("[AI NPC] DIAG anim try StartAnimation(0,'" .. tostring(anim) .. "',0) ok=" .. tostring(ok_call) .. " result=" .. tostring(result))
            if ok_call and result then return true end
            ok_any = ok_any or (ok_call and result ~= nil)
        end
        if type(ent.actor.QueueAnimation) == "function" then
            local ok_call, result = pcall(function() return ent.actor:QueueAnimation(0, anim, 0) end)
            System.LogAlways("[AI NPC] DIAG anim try QueueAnimation(0,'" .. tostring(anim) .. "',0) ok=" .. tostring(ok_call) .. " result=" .. tostring(result))
            if ok_call and result then return true end
            ok_any = ok_any or (ok_call and result ~= nil)
        end
        -- Interactive actions (action names, not animation names)
        if type(ent.actor.StartInteractiveActionByName) == "function" then
            local ok_call, result = pcall(function() return ent.actor:StartInteractiveActionByName(anim) end)
            System.LogAlways("[AI NPC] DIAG anim try StartInteractiveActionByName('" .. tostring(anim) .. "') ok=" .. tostring(ok_call) .. " result=" .. tostring(result))
            if ok_call and result then return true end
            ok_any = ok_any or (ok_call and result ~= nil)
        end
        if type(ent.actor.SimulateOnAction) == "function" then
            local ok_call, result = pcall(function() return ent.actor:SimulateOnAction(anim, 1, 1.0) end)
            System.LogAlways("[AI NPC] DIAG anim try SimulateOnAction('" .. tostring(anim) .. "',1,1.0) ok=" .. tostring(ok_call) .. " result=" .. tostring(result))
            if ok_call and result then return true end
            ok_any = ok_any or (ok_call and result ~= nil)
        end
        -- Dialog animation states (can drive body language)
        if type(ent.actor.SetDialogAnimationState) == "function" then
            local ok_call, result = pcall(function() return ent.actor:SetDialogAnimationState(anim) end)
            System.LogAlways("[AI NPC] DIAG anim try SetDialogAnimationState('" .. tostring(anim) .. "') ok=" .. tostring(ok_call) .. " result=" .. tostring(result))
            if ok_call and result then return true end
            ok_any = ok_any or (ok_call and result ~= nil)
        end
        -- Human PlayAnim fallback (match TestAnim signature)
        if type(ent.human) == "table" and type(ent.human.PlayAnim) == "function" then
            local ok_call, result = pcall(function() return ent.human:PlayAnim(anim, "") end)
            System.LogAlways("[AI NPC] DIAG anim try human:PlayAnim('" .. tostring(anim) .. "','') ok=" .. tostring(ok_call) .. " result=" .. tostring(result))
            if ok_call and result then return true end
            ok_any = ok_any or (ok_call and result ~= nil)
        end
        -- KCD2 animation state overrides
        if type(ent.actor.SetAnimationState) == "function" then
            local ok_call, result = pcall(function() return ent.actor:SetAnimationState(anim) end)
            System.LogAlways("[AI NPC] DIAG anim try SetAnimationState('" .. tostring(anim) .. "') ok=" .. tostring(ok_call) .. " result=" .. tostring(result))
            if ok_call and result then return true end
            ok_any = ok_any or (ok_call and result ~= nil)
        end
        if type(ent.actor.SetAnimState) == "function" then
            local ok_call, result = pcall(function() return ent.actor:SetAnimState(anim) end)
            System.LogAlways("[AI NPC] DIAG anim try SetAnimState('" .. tostring(anim) .. "') ok=" .. tostring(ok_call) .. " result=" .. tostring(result))
            if ok_call and result then return true end
            ok_any = ok_any or (ok_call and result ~= nil)
        end
    end
    return ok_any
end

local function scene_gesture_wave(ent)
    local ok = scene_play_anim(ent, { "greetings_wave_small_over", "greetings_wave_big_over" })
    if not ok then
        ok = scene_look_at_player(ent)
    end
    System.LogAlways("[AI NPC] SCENE_ACTION gesture_wave ok=" .. tostring(ok))
    return ok
end

local function scene_gesture_bow(ent)
    local ok = scene_play_anim(ent, { "greetings_bow", "greetings_head_bow_over" })
    if not ok then
        ok = scene_look_at_player(ent)
    end
    System.LogAlways("[AI NPC] SCENE_ACTION gesture_bow ok=" .. tostring(ok))
    return ok
end

local function scene_gesture_nod(ent)
    local ok = scene_play_anim(ent, { "greetings_head_nod_over" })
    if not ok then
        ok = scene_look_at_player(ent)
    end
    System.LogAlways("[AI NPC] SCENE_ACTION gesture_nod ok=" .. tostring(ok))
    return ok
end

local function scene_gesture_point(ent)
    local ok = scene_play_anim(ent, { "relaxed_pointing_01", "relaxed_pointing_02", "relaxed_pointing_03" })
    if not ok then
        ok = scene_look_at_player(ent)
    end
    System.LogAlways("[AI NPC] SCENE_ACTION gesture_point ok=" .. tostring(ok))
    return ok
end

local function scene_gesture_cheer(ent)
    local ok = scene_play_anim(ent, { "soldier_cheer_lg_nw", "soldier_cheer_lg_z2_shld" })
    if not ok then
        ok = scene_look_at_player(ent)
    end
    System.LogAlways("[AI NPC] SCENE_ACTION gesture_cheer ok=" .. tostring(ok))
    return ok
end

local function scene_gesture_come_here(ent)
    local ok = scene_play_anim(ent, { "come_here_01" })
    if not ok then
        ok = scene_look_at_player(ent)
    end
    System.LogAlways("[AI NPC] SCENE_ACTION gesture_come_here ok=" .. tostring(ok))
    return ok
end

local function scene_gesture_look_around(ent)
    local ok = scene_play_anim(ent, { "alerted_idle_looking_around_01" })
    if not ok then
        ok = scene_look_at_player(ent)
    end
    System.LogAlways("[AI NPC] SCENE_ACTION gesture_look_around ok=" .. tostring(ok))
    return ok
end

local function scene_emotion_nervous(ent)
    local ok = scene_play_anim(ent, { "behavior_nervous_man_loop" })
    if not ok then
        ok = scene_look_at_player(ent)
    end
    System.LogAlways("[AI NPC] SCENE_ACTION emotion_nervous ok=" .. tostring(ok))
    return ok
end

local function scene_emotion_sad(ent)
    local ok = scene_play_anim(ent, { "angry_sad_loop" })
    if not ok then
        ok = scene_look_at_player(ent)
    end
    System.LogAlways("[AI NPC] SCENE_ACTION emotion_sad ok=" .. tostring(ok))
    return ok
end

local function scene_emotion_angry(ent)
    local ok = scene_play_anim(ent, { "angry_stand_loop" })
    if not ok then
        ok = scene_look_at_player(ent)
    end
    System.LogAlways("[AI NPC] SCENE_ACTION emotion_angry ok=" .. tostring(ok))
    return ok
end

local function scene_emotion_drunk(ent)
    local ok = scene_play_anim(ent, { "drunkard_idle" })
    if not ok then
        ok = scene_look_at_player(ent)
    end
    System.LogAlways("[AI NPC] SCENE_ACTION emotion_drunk ok=" .. tostring(ok))
    return ok
end

local function scene_laugh(ent)
    local is_female = false
    local gender_ok, gender_result = pcall(function() return ai_npc_is_female_ent(ent) end)
    if gender_ok then
        is_female = gender_result == true
    end
    local anims
    if is_female then
        anims = { "female_dialogue_laugh_01", "female_dialogue_laugh_02", "female_dialogue_laugh_03", "dlg_female_neutral_stand_laugh_01", "dlg_female_neutral_stand_laugh_02", "dlg_female_neutral_stand_laugh_03" }
    else
        anims = { "dialogue_laugh_01", "dialogue_laugh_02", "dialogue_laugh_03", "dlg_male_neutral_stand_laugh_01", "dlg_male_neutral_stand_laugh_02", "dlg_male_neutral_stand_laugh_03" }
    end
    local ok = scene_play_anim(ent, anims)
    if not ok then
        ok = scene_look_at_player(ent)
    end
    System.LogAlways("[AI NPC] SCENE_ACTION laugh ok=" .. tostring(ok) .. " female=" .. tostring(is_female))
    return ok
end

local function scene_sit_down(ent)
    local is_female = false
    local gender_ok, gender_result = pcall(function() return ai_npc_is_female_ent(ent) end)
    if gender_ok then
        is_female = gender_result == true
    end
    local anims
    if is_female then
        anims = { "behavior_sitting_variation01_in", "sitting_bench_sitdown_01", "sitting_bench_sitdown_front_01", "sitting_bench_sitdown_front_left" }
    else
        anims = { "sitting_bench_sitdown_frontleft_robe", "sitting_bench_notable_sitdown_01_robe", "sitting_bench_sitdown_bowl_01", "sitting_bench_sitdown_frontright_robe" }
    end
    local ok = scene_play_anim(ent, anims)
    scene_send_ai_signal(ent, "OnLowHideSpot")
    if not ok then
        ok = scene_look_at_player(ent)
    end
    System.LogAlways("[AI NPC] SCENE_ACTION sit_down ok=" .. tostring(ok) .. " female=" .. tostring(is_female))
    return ok
end

local function scene_stand_up(ent)
    local is_female = false
    local gender_ok, gender_result = pcall(function() return ai_npc_is_female_ent(ent) end)
    if gender_ok then
        is_female = gender_result == true
    end
    local anims
    if is_female then
        anims = { "behavior_sitting_variation01_out", "sitting_bench_standup_01", "sitting_bench_standup_02", "sitting_bench_standup_idle" }
    else
        anims = { "sitting_bench_notable_standup_01_robe", "sitting_bench_notable_standup_back_01_robe", "sitting_bench_notable_standup_back_left_robe", "sitting_bench_notable_standup_back_right_robe" }
    end
    local ok = scene_play_anim(ent, anims)
    scene_send_ai_signal(ent, "OnFallAndPlay")
    if not ok then
        ok = scene_look_at_player(ent)
    end
    System.LogAlways("[AI NPC] SCENE_ACTION stand_up ok=" .. tostring(ok) .. " female=" .. tostring(is_female))
    return ok
end

local function scene_pet_dog(ent)
    local ok = scene_play_anim(ent, { "player_dog_carees_v01", "player_dog_carees_v02", "player_dog_carees_v03", "player_dog_carees_v04" })
    if not ok then
        ok = scene_look_at_player(ent)
    end
    System.LogAlways("[AI NPC] SCENE_ACTION pet_dog ok=" .. tostring(ok))
    return ok
end

local function scene_knock_door(ent)
    local ok = scene_play_anim(ent, { "door_nervous_knocking_loop", "door_nervous_knocking_loop_var_01", "door_nervous_knocking_loop_var_02" })
    if not ok then
        ok = scene_look_at_player(ent)
    end
    System.LogAlways("[AI NPC] SCENE_ACTION knock_door ok=" .. tostring(ok))
    return ok
end

local function scene_close_visor(ent)
    local ok = scene_play_anim(ent, { "relaxed_idle_close_visor_lhand_over" })
    if not ok then
        ok = scene_look_at_player(ent)
    end
    System.LogAlways("[AI NPC] SCENE_ACTION close_visor ok=" .. tostring(ok))
    return ok
end

local function scene_open_visor(ent)
    local ok = scene_play_anim(ent, { "relaxed_idle_open_visor_lhand_over" })
    if not ok then
        ok = scene_look_at_player(ent)
    end
    System.LogAlways("[AI NPC] SCENE_ACTION open_visor ok=" .. tostring(ok))
    return ok
end

local function scene_injured_idle(ent)
    local ok = scene_play_anim(ent, { "injured_idle", "injured_walk", "sick_man_loop" })
    if not ok then
        ok = scene_look_at_player(ent)
    end
    System.LogAlways("[AI NPC] SCENE_ACTION injured_idle ok=" .. tostring(ok))
    return ok
end

local function scene_fear_stand(ent)
    local ok = scene_play_anim(ent, { "behavior_fear_stand_loop", "scared_idle2run_lleg_back" })
    if not ok then
        ok = scene_look_at_player(ent)
    end
    System.LogAlways("[AI NPC] SCENE_ACTION fear_stand ok=" .. tostring(ok))
    return ok
end

local function scene_cooking(ent)
    local ok = scene_play_anim(ent, { "cooking_ladle_loop", "cooking_ladle_in", "cooking_ladle_out", "behavior_cooking_pan_camp_player" })
    if not ok then
        ok = scene_look_at_player(ent)
    end
    System.LogAlways("[AI NPC] SCENE_ACTION cooking ok=" .. tostring(ok))
    return ok
end

local ai_npc_item_class_info

local function scene_strip_outerwear(ent)
    if not ent or type(ent.actor) ~= "table" or type(ent.actor.EquipClothingPreset) ~= "function" then return false end
    local ok = pcall(function() return ent.actor:EquipClothingPreset("48691669-b94a-0e6a-d9db-0a70a0ca1fad") end)
    return ok == true
end

--[[  -- INTERMEDIATE STRIP DISABLED until a nude mod supports separate underwear layer
-- Full strip: equip the female naked preset (vanilla bathhouse after-sex preset).
-- This removes all clothing including underwear for female NPCs.
-- Preset: f_bathhouse_afterSex_naked = 45d18962-2691-48af-8eb2-26c67884ac11
local function scene_full_strip(ent)
    if not ent or type(ent.actor) ~= "table" or type(ent.actor.EquipClothingPreset) ~= "function" then return false end
    local ok = pcall(function() return ent.actor:EquipClothingPreset("45d18962-2691-48af-8eb2-26c67884ac11") end)
    System.LogAlways("[AI NPC] SCENE_ACTION full strip (naked preset) ok=" .. tostring(ok))
    return ok == true
end

-- Partial strip: remove outerwear down to underwear layer.
-- Uses EquipClothingPreset "light" which strips to underwear/nightgown.
-- With a patched nude-mod (underwear.xml restored) this shows the NPC in underwear.
local function scene_partial_strip(ent)
    if not ent or type(ent.actor) ~= "table" or type(ent.actor.EquipClothingPreset) ~= "function" then return false end
    local ok = pcall(function() return ent.actor:EquipClothingPreset("48691669-b94a-0e6a-d9db-0a70a0ca1fad") end)
    System.LogAlways("[AI NPC] SCENE_ACTION partial strip (light preset) ok=" .. tostring(ok))
    return ok == true
end
--]]

local function scene_unequip_slot(ent, slot)
    if not ent or type(ent.actor) ~= "table" or type(ent.actor.UnequipInventoryItem) ~= "function" then return false end
    if type(ent.inventory) ~= "table" or type(ent.inventory.GetInventoryTable) ~= "function" then return false end
    if not ItemManager or type(ItemManager.GetItem) ~= "function" then return false end
    local ok_table, inv_table = pcall(function() return ent.inventory:GetInventoryTable() end)
    if not ok_table or type(inv_table) ~= "table" then return false end
    local matches = {}
    for idx, handle in pairs(inv_table) do
        local ok_item, item = pcall(function() return ItemManager.GetItem(handle) end)
        if ok_item and type(item) == "table" then
            local info = ai_npc_item_class_info(item.class)
            if info and tostring(info.slot or "") == slot then
                table.insert(matches, { idx = idx, handle = handle, class = item.class, armor_type = tostring(info.armor_type or "") })
            end
        end
    end
    table.sort(matches, function(a, b) return tostring(a.idx) < tostring(b.idx) end)
    local removed = 0
    for _, m in ipairs(matches) do
        local ok_rm = pcall(function() return ent.actor:UnequipInventoryItem(m.handle) end)
        System.LogAlways("[AI NPC] SCENE_ACTION unequip slot=" .. tostring(slot) .. " index=" .. tostring(m.idx) .. " class=" .. tostring(m.class) .. " armor_type=" .. tostring(m.armor_type) .. " ok=" .. tostring(ok_rm))
        if ok_rm then removed = removed + 1 end
    end
    return removed > 0
end

local function scene_equip_first_in_slot(ent, slot)
    if not ent or type(ent.actor) ~= "table" or type(ent.actor.EquipInventoryItem) ~= "function" then return false end
    if type(ent.inventory) ~= "table" or type(ent.inventory.GetInventoryTable) ~= "function" then return false end
    if not ItemManager or type(ItemManager.GetItem) ~= "function" then return false end
    local ok_table, inv_table = pcall(function() return ent.inventory:GetInventoryTable() end)
    if not ok_table or type(inv_table) ~= "table" then return false end
    local candidates = {}
    for idx, handle in pairs(inv_table) do
        local ok_item, item = pcall(function() return ItemManager.GetItem(handle) end)
        if ok_item and type(item) == "table" then
            local info = ai_npc_item_class_info(item.class)
            if info and tostring(info.slot or "") == slot then
                table.insert(candidates, { idx = idx, handle = handle, class = item.class })
            end
        end
    end
    table.sort(candidates, function(a, b) return tostring(a.idx) < tostring(b.idx) end)
    for _, c in ipairs(candidates) do
        local ok_eq, result = pcall(function() return ent.actor:EquipInventoryItem(c.handle) end)
        System.LogAlways("[AI NPC] SCENE_ACTION equip slot=" .. tostring(slot) .. " index=" .. tostring(c.idx) .. " class=" .. tostring(c.class) .. " ok=" .. tostring(ok_eq) .. " result=" .. tostring(result))
        if ok_eq then return true end
    end
    return false
end

local function scene_equip_inventory_armor(ent)
    if not ent or type(ent.actor) ~= "table" or type(ent.actor.EquipInventoryItem) ~= "function" then return false end
    if type(ent.inventory) ~= "table" or type(ent.inventory.GetInventoryTable) ~= "function" then return false end
    if not ItemManager or type(ItemManager.GetItem) ~= "function" then return false end
    local ok_table, inv_table = pcall(function() return ent.inventory:GetInventoryTable() end)
    if not ok_table or type(inv_table) ~= "table" then return false end
    local equipped = 0
    local slots = { body = 1, legs = 2, feet = 3, arms = 4, head = 5, neck = 6 }
    local candidates = {}
    for idx, handle in pairs(inv_table) do
        local ok_item, item = pcall(function() return ItemManager.GetItem(handle) end)
        if ok_item and type(item) == "table" then
            local info = ai_npc_item_class_info(item.class)
            local slot = info and tostring(info.slot or "") or ""
            if info and info.kind == "armor" and slots[slot] then
                table.insert(candidates, { idx = idx, handle = handle, class = item.class, slot = slot, order = slots[slot] })
            end
        end
    end
    table.sort(candidates, function(a, b)
        if a.order ~= b.order then return a.order < b.order end
        return tostring(a.idx) < tostring(b.idx)
    end)
    for _, c in ipairs(candidates) do
        local ok_equip, result = pcall(function() return ent.actor:EquipInventoryItem(c.handle) end)
        System.LogAlways("[AI NPC] SCENE_ACTION dress_up equip_inventory slot=" .. tostring(c.slot) .. " index=" .. tostring(c.idx) .. " class=" .. tostring(c.class) .. " ok=" .. tostring(ok_equip) .. " result=" .. tostring(result))
        if ok_equip then equipped = equipped + 1 end
    end
    System.LogAlways("[AI NPC] SCENE_ACTION dress_up inventory_candidates=" .. tostring(#candidates) .. " equipped=" .. tostring(equipped))
    return equipped > 0
end

local AI_NPC_DRESS_UP_MALE_PRESETS = {
    { name = "labourer_01", guid = "f8e28d52-f9b0-406d-b72c-12fe058a6aa9" },
    { name = "labourer_02", guid = "449db968-03c7-43ef-8fa4-6ccab7aa9a48" },
    { name = "labourer_03", guid = "a75923bd-3a44-4747-8632-71c54a0505b6" },
    { name = "labourer_04", guid = "3d1e9130-42e0-4a43-a005-ba9db2c939bd" },
    { name = "labourer_05", guid = "3c047c94-255e-46b4-bbc1-4ba85c987e50" },
    { name = "villager_01", guid = "ecf4eea7-ffe5-4a98-a351-8947eeabe5bd" },
    { name = "villager_02", guid = "24e4aa5b-cd2c-4dba-9426-b63e674b7037" },
    { name = "villager_03", guid = "c522ba8f-18ff-4274-8acb-d7d0f50d0365" },
    { name = "villager_04", guid = "cbc20d2b-3fff-4147-a650-92a8dcaf9875" },
    { name = "villager_05", guid = "fd456ed6-f39e-4dad-8c53-e818c9789562" },
}

local AI_NPC_DRESS_UP_FEMALE_PRESETS = {
    { name = "f_bathmaid_01", guid = "298386c4-69d9-42de-9e1f-f294039372e5" },
    { name = "f_bathmaid_02", guid = "dd915fff-4d37-4362-a4b9-945db98e4bd3" },
    { name = "f_bathmaid_03", guid = "0e81d83d-f27f-4384-bb88-75d4a32e67d9" },
    { name = "f_bathmaid_04", guid = "405614af-a376-486e-bc0d-1e1c89e3f8f4" },
    { name = "f_bathmaid_05", guid = "c5a7de75-5a64-4cbd-ab28-91474059e33c" },
    { name = "f_villager_02", guid = "0c6985bb-a767-441d-a95f-90f988ea3b0d" },
    { name = "f_villager_05", guid = "48b428e7-24b9-4e36-b784-08ff77a487fa" },
    { name = "f_villager_08", guid = "08fd88a1-0f0e-4de2-8ba9-c4689ebc29a5" },
    { name = "f_villager_09", guid = "2362b15e-b67f-4956-b962-4f35de309bc4" },
    { name = "f_villager_12", guid = "3b3476fc-5026-4982-bc2f-99569613c90f" },
}

local function ai_npc_is_female_ent(ent)
    if not ent then return false end
    local cls = tostring(ent.class or "")
    if cls:find("Female") or cls:find("female") then return true end
    local soul = ai_npc_get_soul(ent)
    local gender = safe_method_call(soul, "GetGender")
    return tostring(gender) == "2" or tostring(gender):lower() == "female"
end

local function scene_dress_up(ent)
    local ok_preset = false
    local preset = nil
    local is_female = false
    local gender_ok, gender_result = pcall(function() return ai_npc_is_female_ent(ent) end)
    if gender_ok then
        is_female = gender_result == true
    else
        System.LogAlways("[AI NPC] SCENE_ACTION dress_up gender_error=" .. tostring(gender_result))
    end
    if ent and type(ent.actor) == "table" and type(ent.actor.EquipClothingPreset) == "function" then
        local presets = is_female and AI_NPC_DRESS_UP_FEMALE_PRESETS or AI_NPC_DRESS_UP_MALE_PRESETS
        if type(presets) == "table" and #presets > 0 then
            preset = presets[math.random(1, #presets)]
            local equip_ok, equip_result = pcall(function() return ent.actor:EquipClothingPreset(preset.guid) end)
            ok_preset = equip_ok == true
            if not equip_ok then
                System.LogAlways("[AI NPC] SCENE_ACTION dress_up preset_error name=" .. tostring(preset and preset.name) .. " guid=" .. tostring(preset and preset.guid) .. " err=" .. tostring(equip_result))
            end
        else
            System.LogAlways("[AI NPC] SCENE_ACTION dress_up preset_error empty preset list female=" .. tostring(is_female))
        end
        if ok_preset and type(ent.ForceCharacterUpdate) == "function" then
            pcall(function() return ent:ForceCharacterUpdate(0, false) end)
        end
    else
        System.LogAlways("[AI NPC] SCENE_ACTION dress_up unavailable actor=" .. tostring(ent and ent.actor) .. " equip_func=" .. tostring(ent and ent.actor and ent.actor.EquipClothingPreset))
    end
    local ok_inventory = scene_equip_inventory_armor(ent)
    System.LogAlways("[AI NPC] SCENE_ACTION dress_up female=" .. tostring(is_female) .. " preset=" .. tostring(ok_preset) .. " name=" .. tostring(preset and preset.name) .. " guid=" .. tostring(preset and preset.guid) .. " inventory=" .. tostring(ok_inventory))
    return ok_preset or ok_inventory
end

local function scene_collapse_spell(ent)
    if not ent then return false end
    local ok_any = false
    if type(ent.actor) == "table" and type(ent.actor.RagDollize) == "function" then
        local ok, result = pcall(function() return ent.actor:RagDollize() end)
        ok_any = ok or ok_any
        System.LogAlways("[AI NPC] SCENE_ACTION collapse_spell ragdoll ok=" .. tostring(ok) .. " result=" .. tostring(result))
    end
    local signals = { "OnFallAndPlay", "OnFall", "OnKnockedDown", "OnStunned", "OnThreateningSoundHeard" }
    for _, signal in ipairs(signals) do
        ok_any = scene_send_ai_signal(ent, signal) or ok_any
    end
    if type(ent.actor) == "table" then
        local actor_methods = { "Ragdollize", "Fall", "KnockDown", "Stun" }
        for _, method in ipairs(actor_methods) do
            if type(ent.actor[method]) == "function" then
                local ok = pcall(function() return ent.actor[method](ent.actor) end)
                ok_any = ok or ok_any
                System.LogAlways("[AI NPC] SCENE_ACTION collapse_spell actor_method=" .. tostring(method) .. " ok=" .. tostring(ok))
            end
        end
    end
    local ent_methods = { "RagDollize", "Ragdollize", "Fall", "KnockDown", "Stun" }
    for _, method in ipairs(ent_methods) do
        if type(ent[method]) == "function" then
            local ok = pcall(function() return ent[method](ent) end)
            ok_any = ok or ok_any
            System.LogAlways("[AI NPC] SCENE_ACTION collapse_spell ent_method=" .. tostring(method) .. " ok=" .. tostring(ok))
        end
    end
    return ok_any
end

local function scene_execute_game_action(scene, action, intent)
    local ent = scene_resolve_entity(scene)
    if not ent then
        System.LogAlways("[AI NPC] SCENE_ACTION game: no entity resolved")
        return false
    end
    local ok = false
    if action == "step_back" then
        ok = scene_move_away_from_player(ent, 0.65) or ok
        ok = scene_send_ai_signal(ent, "OnPlayerTooClose") or scene_send_ai_signal(ent, "OnThreateningSoundHeard") or ok
    elseif action == "walk_away" then
        ok = scene_move_away_from_player(ent, 1.25) or ok
        ok = scene_send_ai_signal(ent, "OnPlayerTooClose") or scene_send_ai_signal(ent, "OnThreateningSoundHeard") or ok
    elseif action == "come_closer" then
        ok = scene_move_towards_player(ent, 0.75) or scene_look_at_player(ent) or ok
    elseif action == "turn_to_player" or action == "look_at_player" then
        ok = scene_look_at_player(ent) or ok
    elseif action == "draw_weapon" then
        ok = scene_draw_weapon(ent) or scene_send_ai_signal(ent, "DrawWeapon") or scene_send_ai_signal(ent, "OnEnemySeen") or ok
    elseif action == "holster_weapon" then
        if ent and type(ent.human) == "table" and type(ent.human.HolsterWeapon) == "function" then
            local ok_holster, result = pcall(function() return ent.human:HolsterWeapon() end)
            System.LogAlways("[AI NPC] SCENE_ACTION holster_weapon ok=" .. tostring(ok_holster) .. " result=" .. tostring(result))
            ok = ok_holster or ok
        else
            System.LogAlways("[AI NPC] SCENE_ACTION holster_weapon unavailable")
        end
    elseif action == "strip_outerwear" then
        ok = scene_strip_outerwear(ent) or ok
    elseif action == "dress_up" then
        ok = scene_dress_up(ent) or ok
        local mem = scene_memory_for_npc(scene.npc_id or (state.current_npc and state.current_npc.id))
        mem.strip_level = 0
        System.LogAlways("[AI NPC] SCENE_ACTION dress_up reset strip_level=0")
--[[  -- INTERMEDIATE STRIP DISABLED
    elseif action == "strip_partial" then
        ok = scene_partial_strip(ent) or ok
        local mem = scene_memory_for_npc(scene.npc_id or (state.current_npc and state.current_npc.id))
        mem.strip_level = 1
        System.LogAlways("[AI NPC] SCENE_ACTION strip_partial -> ok=" .. tostring(ok))
    elseif action == "strip_full" then
        ok = scene_full_strip(ent) or ok
        local mem = scene_memory_for_npc(scene.npc_id or (state.current_npc and state.current_npc.id))
        mem.strip_level = 2
        System.LogAlways("[AI NPC] SCENE_ACTION strip_full -> ok=" .. tostring(ok))
    elseif action == "dress_partial" then
        local ok_body = scene_equip_first_in_slot(ent, "body")
        local ok_legs = scene_equip_first_in_slot(ent, "legs")
        ok = ok_body or ok_legs or ok
        if not ok then
            ok = scene_dress_up(ent) or ok
        end
        local mem = scene_memory_for_npc(scene.npc_id or (state.current_npc and state.current_npc.id))
        mem.strip_level = 0
        System.LogAlways("[AI NPC] SCENE_ACTION dress_partial ok=" .. tostring(ok) .. " body=" .. tostring(ok_body) .. " legs=" .. tostring(ok_legs))
    elseif action == "dress_full" then
        ok = scene_dress_up(ent) or ok
        local mem = scene_memory_for_npc(scene.npc_id or (state.current_npc and state.current_npc.id))
        mem.strip_level = 0
        System.LogAlways("[AI NPC] SCENE_ACTION dress_full -> ok=" .. tostring(ok))
--]]
    elseif action == "headwear_off" then
        ok = scene_unequip_slot(ent, "head") or ok
    elseif action == "headwear_on" then
        ok = scene_equip_first_in_slot(ent, "head") or ok
    elseif action == "footwear_off" then
        ok = scene_unequip_slot(ent, "feet") or ok
    elseif action == "footwear_on" then
        ok = scene_equip_first_in_slot(ent, "feet") or ok
    elseif action == "legwear_off" then
        ok = scene_unequip_slot(ent, "legs") or ok
    elseif action == "legwear_on" then
        ok = scene_equip_first_in_slot(ent, "legs") or ok
    elseif action == "armwear_off" then
        ok = scene_unequip_slot(ent, "arms") or ok
    elseif action == "armwear_on" then
        ok = scene_equip_first_in_slot(ent, "arms") or ok
    elseif action == "neckwear_off" then
        ok = scene_unequip_slot(ent, "neck") or ok
    elseif action == "neckwear_on" then
        ok = scene_equip_first_in_slot(ent, "neck") or ok
    elseif action == "bodywear_off" then
        ok = scene_unequip_slot(ent, "body") or ok
    elseif action == "bodywear_on" then
        ok = scene_equip_first_in_slot(ent, "body") or ok
    elseif action == "gesture_wave" then
        ok = scene_gesture_wave(ent) or scene_look_at_player(ent) or ok
    elseif action == "gesture_bow" then
        ok = scene_gesture_bow(ent) or scene_look_at_player(ent) or ok
    elseif action == "gesture_nod" then
        ok = scene_gesture_nod(ent) or scene_look_at_player(ent) or ok
    elseif action == "gesture_point" then
        ok = scene_gesture_point(ent) or scene_look_at_player(ent) or ok
    elseif action == "gesture_cheer" then
        ok = scene_gesture_cheer(ent) or scene_look_at_player(ent) or ok
    elseif action == "gesture_come_here" then
        ok = scene_gesture_come_here(ent) or scene_look_at_player(ent) or ok
    elseif action == "gesture_look_around" then
        ok = scene_gesture_look_around(ent) or scene_look_at_player(ent) or ok
    elseif action == "emotion_nervous" then
        ok = scene_emotion_nervous(ent) or scene_look_at_player(ent) or ok
    elseif action == "emotion_sad" then
        ok = scene_emotion_sad(ent) or scene_look_at_player(ent) or ok
    elseif action == "emotion_angry" then
        ok = scene_emotion_angry(ent) or scene_look_at_player(ent) or ok
    elseif action == "emotion_drunk" then
        ok = scene_emotion_drunk(ent) or scene_look_at_player(ent) or ok
    elseif action == "laugh" then
        ok = scene_laugh(ent) or scene_look_at_player(ent) or ok
    elseif action == "sit_down" then
        ok = scene_sit_down(ent) or ok
    elseif action == "stand_up" then
        ok = scene_stand_up(ent) or ok
    elseif action == "pet_dog" then
        ok = scene_pet_dog(ent) or ok
    elseif action == "knock_door" then
        ok = scene_knock_door(ent) or ok
    elseif action == "close_visor" then
        ok = scene_close_visor(ent) or ok
    elseif action == "open_visor" then
        ok = scene_open_visor(ent) or ok
    elseif action == "injured_idle" then
        ok = scene_injured_idle(ent) or ok
    elseif action == "fear_stand" then
        ok = scene_fear_stand(ent) or ok
    elseif action == "cooking" then
        ok = scene_cooking(ent) or ok
    elseif action == "play_anim" then
        local anim_name = tostring(scene.animation_name or "")
        if anim_name ~= "" then
            ok = scene_play_anim(ent, { anim_name }) or ok
            System.LogAlways("[AI NPC] SCENE_ACTION play_anim name=" .. anim_name .. " ok=" .. tostring(ok))
        else
            System.LogAlways("[AI NPC] SCENE_ACTION play_anim missing animation_name")
        end
    elseif action == "collapse_spell" then
        ok = scene_collapse_spell(ent) or ok
    elseif action == "call_help" or intent == "call_help" then
        ok = scene_send_ai_signal(ent, "OnEnemySeen") or scene_send_ai_signal(ent, "OnThreateningSoundHeard") or ok
    elseif intent == "warn" then
        ok = scene_look_at_player(ent)
    end
    System.LogAlways("[AI NPC] SCENE_ACTION game action=" .. tostring(action) .. " intent=" .. tostring(intent) .. " ok=" .. tostring(ok))
    return ok
end

local function handle_scene_action(scene, fallback_npc_name)
    if type(scene) ~= "table" then return end
    local mood = tostring(scene.mood or "neutral")
    local intent = tostring(scene.intent or "continue")
    local action = tostring(scene.suggested_action or "none")
    local apology_attempt = tostring(scene.apology_attempt or "false") == "true"
    local npc_id = scene.npc_id or (state.current_npc and state.current_npc.id) or state.last_request_npc_id
    local mem, mem_key = scene_memory_for_npc(npc_id)
    state.last_scene = {
        mood = mood,
        intent = intent,
        suggested_action = action,
        ts = os.clock(),
    }
    state.scene_flags = state.scene_flags or {}
    state.scene_flags.last_mood = mood
    state.scene_flags.last_intent = intent
    state.scene_flags.last_action = action
    state.scene_flags.last_at = os.clock()
    state.scene_flags.warned = intent == "warn" or state.scene_flags.warned
    state.scene_flags.refused = intent == "refuse" or intent == "end" or state.scene_flags.refused
    state.scene_flags.danger = intent == "call_help" or action == "call_help" or action == "draw_weapon" or state.scene_flags.danger
    state.scene_flags.step_back = action == "step_back" or state.scene_flags.step_back
    state.scene_flags.walk_away = action == "walk_away" or state.scene_flags.walk_away
    mem.last_mood = mood
    mem.last_intent = intent
    mem.last_action = action
    mem.last_at = os.clock()
    if intent == "warn" and not apology_attempt then
        mem.warning_count = (tonumber(mem.warning_count) or 0) + 1
    end
    if intent == "refuse" then
        mem.refused_until = os.clock() + 12
        mem.refused = true
    end
    if intent == "end" or action == "walk_away" then
        mem.refused_until = os.clock() + 45
        mem.refused = true
    end
    if intent == "call_help" or action == "call_help" or action == "draw_weapon" then
        mem.danger = true
    end
    System.LogAlways(
        "[AI NPC] SCENE_ACTION mood=" .. mood ..
        " intent=" .. intent ..
        " action=" .. action ..
        " mem=" .. tostring(mem_key)
    )
    System.LogAlways(
        "[AI NPC] SCENE_MEMORY warnings=" .. tostring(mem.warning_count or 0) ..
        " refused_until=" .. tostring(mem.refused_until or 0) ..
        " danger=" .. tostring(mem.danger == true)
    )
    if intent == "refuse" or intent == "end" then
        System.LogAlways("[AI NPC] SCENE_ACTION lite: NPC wants to end/refuse conversation")
    elseif intent == "warn" then
        System.LogAlways("[AI NPC] SCENE_ACTION lite: NPC warns the player")
    elseif intent == "call_help" or action == "call_help" then
        System.LogAlways("[AI NPC] SCENE_ACTION lite: NPC would call for help")
    elseif action == "step_back" then
        System.LogAlways("[AI NPC] SCENE_ACTION lite: NPC would step back")
    elseif action == "walk_away" then
        System.LogAlways("[AI NPC] SCENE_ACTION lite: NPC would walk away")
    elseif action == "draw_weapon" then
        System.LogAlways("[AI NPC] SCENE_ACTION lite: NPC would draw a weapon")
    end
    if state.scene_flags.danger then
        System.LogAlways("[AI NPC] SCENE_ACTION lite: danger flag set")
    end
    if action ~= "none" or intent == "call_help" then
        scene_execute_game_action(scene, action, intent)
    end
    local scene_npc_name = tostring(scene.npc_name or "")
    local npc_name = scene_npc_name ~= "" and scene_npc_name or fallback_npc_name or state.last_request_npc_name or (state.current_npc and state.current_npc.name) or "NPC"
    local feedback = scene_action_feedback(npc_name, action, intent)
    if feedback and _G.__ai_npc_hud_narrator ~= false then
        System.LogAlways("[AI NPC] SCENE_FEEDBACK " .. feedback)
        ui_show_narrator(feedback, 4500)
        if use_overlay_ui() then
            ipc_write_cmd("MSG|system|Scene|" .. feedback)
        end
    end
    if intent == "warn" and not apology_attempt and (tonumber(mem.warning_count) or 0) >= 4 then
        mem.refused_until = os.clock() + 15
        System.LogAlways("[AI NPC] SCENE_ACTION lite: warning escalation -> temporary refusal")
        if type(end_conversation) == "function" then
            System.LogAlways("[AI NPC] SCENE_ACTION lite: closing conversation after warning escalation")
            end_conversation()
        end
    end
    if (intent == "end" or action == "walk_away" or intent == "call_help" or action == "call_help" or action == "draw_weapon") and type(end_conversation) == "function" then
        System.LogAlways("[AI NPC] SCENE_ACTION lite: closing conversation state")
        end_conversation()
    end
end

function AI_NPC_TestWorldText(text)
    text = tostring(text or "")
    if text == "" then
        text = "Тестовый текст над NPC"
    end
    local npc = state.current_npc
    if not npc then
        ui_show("No active NPC. Hover over an NPC and start chat first.", 4000, { service = true })
        return
    end
    local ent = npc.entity_ref
    if not ent then
        ui_show("Active NPC has no entity ref.", 4000, { service = true })
        return
    end
    show_text_above_entity(ent, text, 7000)
end

function AI_NPC_HandleResponse(npc_name, response_text, request_id, scene)
    local rid = tonumber(request_id) or 0
    if _G.__ai_npc_swallow_only then
        -- Remember this id as "lingering from previous session". Subsequent
        -- dofile()s of the same resp.lua (which we cannot delete from the
        -- Lua sandbox) will be filtered out below.
        if rid > 0 then
            _G.__ai_npc_lingering_ids[rid] = true
        end
        System.LogAlways("[AI NPC] Swallowed lingering response, id=" .. tostring(rid))
        return
    end
    if rid > 0 and _G.__ai_npc_lingering_ids[rid] then
        -- Stale resp.lua content from the previous game session, leaking via
        -- repeated dofile. Skip silently so it cannot poison last_handled.
        return
    end
    if pending_request_id > 0 and rid > 0 and rid < pending_request_id then
        return
    end
    -- Idempotency guard: same response can be delivered through several
    -- channels (Script.LoadScript + dofile fallback + chat_resp.txt). Without
    -- this guard the same NPC reply gets shown 2-3 times in the HUD.
    if rid > 0 and rid <= last_handled_response_id then
        _G.__ai_npc_dup_logged = _G.__ai_npc_dup_logged or {}
        if not _G.__ai_npc_dup_logged[rid] then
            _G.__ai_npc_dup_logged[rid] = true
            System.LogAlways("[AI NPC] Duplicate response ignored, id=" .. tostring(rid))
        end
        return
    end
    if rid > 0 then
        last_handled_response_id = rid
    end

    pending_request_id = 0
    state.waiting_response = false
    state.waiting_since = nil
    state.last_activity_at = os.clock()
    state.error_message = nil

    local npc_name_for_msg = tostring(npc_name or (state.current_npc and state.current_npc.name) or "NPC")
    local npc_class_for_msg = (state.current_npc and state.current_npc.class) or ""
    local text = tostring(response_text or "")

    table.insert(state.messages, {
        role = "npc",
        name = npc_name_for_msg,
        text = text,
    })

    if use_overlay_ui() then
        ipc_write_cmd("MSG|npc|" .. npc_name_for_msg .. "|" .. text)
    end

    local label = npc_display_name(npc_name_for_msg, npc_class_for_msg)
    ui_show(label .. ": " .. text, 12000)

    -- Try to show the reply as world-space text above the NPC's head
    if state.current_npc and state.current_npc.entity_ref then
        show_text_above_entity(state.current_npc.entity_ref, text, 7000)
    end

    handle_scene_action(scene, npc_name_for_msg)
    System.LogAlways("[AI NPC] RESPONSE id=" .. tostring(rid) .. " npc=" .. tostring(npc_name_for_msg))
end

local __ai_npc_poll_ticks = 0

local function process_resp_file()
    -- The KCD2 CryEngine Lua sandbox exposes no `io` library, so we cannot
    -- read or truncate resp.lua ourselves. Instead we just `dofile` it.
    -- AI_NPC_HandleResponse uses last_handled_response_id to ignore the same
    -- response id if dofile is called multiple times for the unchanged file.
    if type(dofile) ~= "function" then
        if not _G.__ai_npc_no_dofile_logged then
            _G.__ai_npc_no_dofile_logged = true
            System.LogAlways("[AI NPC] Poll resp: dofile unavailable")
        end
        return false
    end

    local resp_paths = {
        "Scripts/ai_npc/resp.lua",
        "scripts/ai_npc/resp.lua",
        "Data/Scripts/ai_npc/resp.lua",
        "data/scripts/ai_npc/resp.lua",
    }
    for _, rp in ipairs(resp_paths) do
        local ok_do, do_err = pcall(dofile, rp)
        if ok_do then
            if not _G.__ai_npc_resp_path_logged then
                _G.__ai_npc_resp_path_logged = true
                System.LogAlways("[AI NPC] Poll resp dofile path: " .. tostring(rp))
            end
            return true
        else
            if not _G.__ai_npc_resp_err_logged then
                _G.__ai_npc_resp_err_logged = true
                System.LogAlways("[AI NPC] Poll resp dofile error: " .. tostring(rp) .. " err=" .. tostring(do_err))
            end
        end
    end
    return false
end

local function poll_step(name, fn)
    local ok, err = pcall(fn)
    if not ok and not _G["__ai_npc_step_err_" .. name] then
        _G["__ai_npc_step_err_" .. name] = true
        System.LogAlways("[AI NPC] Poll step '" .. name .. "' error: " .. tostring(err))
    end
end

function AI_NPC_PollWebCommand()
    __ai_npc_poll_ticks = __ai_npc_poll_ticks + 1
    if __ai_npc_poll_ticks == 1 or __ai_npc_poll_ticks % 20 == 0 then
        -- System.LogAlways("[AI NPC] Poll tick #" .. tostring(__ai_npc_poll_ticks))
    end

    poll_step("sync_binds", function() sync_binds_from_actionmap() end)

    poll_step("timeout_check", function()
        if state.waiting_response and state.waiting_since then
            local elapsed = os.clock() - state.waiting_since
            if elapsed >= RESPONSE_TIMEOUT_SEC then
                state.waiting_response = false
                state.waiting_since = nil
                pending_request_id = 0
                state.error_message = "Response timeout"
                System.LogAlways("[AI NPC] Response timeout unlocked in poll; elapsed=" .. tostring(elapsed))
                ui_show("AI NPC: ответ не получен, попробуйте ещё раз", 5000, { service = true })
            end
        end
    end)

    poll_step("ipc_input", function()
        if ipc_poll_input then ipc_poll_input() end
    end)

    poll_step("loadscript_cmd", function()
        if Script and Script.LoadScript then
            local ok_load, load_err = pcall(Script.LoadScript, "scripts/ai_npc/command.lua", true)
            if not ok_load and not _G.__ai_npc_loadscript_cmd_err_logged then
                _G.__ai_npc_loadscript_cmd_err_logged = true
                System.LogAlways("[AI NPC] Poll LoadScript error: " .. tostring(load_err))
            end
        end
    end)

    poll_step("process_resp", function() process_resp_file() end)

    poll_step("active_spatial", function()
        if state.chat_open and state.current_npc and (__ai_npc_poll_ticks % 2 == 0) then
            notify_active_npc()
        end
    end)

    poll_step("inject_target", function() scan_and_inject_target_debounced() end)

    poll_step("auto_end_idle", function()
        local idle_lim = tonumber(CONFIG.auto_end_idle_sec) or 0
        if idle_lim <= 0 then return end
        if not state.chat_open then return end
        if state.waiting_response then return end  -- never end mid-request
        local idle = os.clock() - (state.last_activity_at or 0)
        if idle >= idle_lim then
            System.LogAlways(string.format(
                "[AI NPC] Auto-end on idle: %.1fs >= %ds, ending silently",
                idle, idle_lim))
            -- Use the global wrapper because the local `end_conversation`
            -- is declared after AI_NPC_PollWebCommand and is not visible here.
            if AI_NPC_End then AI_NPC_End() end
        end
    end)

    poll_step("chat_action", function()
        if type(dofile) ~= "function" then return end
        local paths = {
            "scripts/ai_npc/chat_action.lua",
            "Scripts/ai_npc/chat_action.lua",
            "data/scripts/ai_npc/chat_action.lua",
            "Data/Scripts/ai_npc/chat_action.lua",
        }
        for _, p in ipairs(paths) do
            local ok, err = pcall(dofile, p)
            if ok then
                if not _G.__ai_npc_chat_action_loaded then
                    _G.__ai_npc_chat_action_loaded = true
                    System.LogAlways("[AI NPC] Poll chat_action loaded action=" ..
                        tostring(_G.AI_NPC_CHAT_ACTION) .. " key=" .. tostring(_G.AI_NPC_CHAT_KEY))
                end
                return
            else
                if not _G.__ai_npc_chat_action_err then
                    _G.__ai_npc_chat_action_err = true
                    System.LogAlways("[AI NPC] Poll chat_action dofile error: " .. tostring(p) .. " err=" .. tostring(err))
                end
            end
        end
    end)

    AI_NPC_ScheduleNextPoll(500)
end

function AI_NPC_ScheduleNextPoll(ms)
    if not _G.__ai_npc_sched_method then
        return
    end
    local m = _G.__ai_npc_sched_method
    if m == "SetTimerForFunction" then
        pcall(Script.SetTimerForFunction, ms, "AI_NPC_PollWebCommand")
    elseif m == "SetTimer" then
        pcall(Script.SetTimer, ms, function() AI_NPC_PollWebCommand() end)
    end
end

-- ============================================================================
-- NPC Detection
-- ============================================================================

local function get_player_position()
    if System and System.GetEntity then
        local player = System.GetEntity("yourPlayer") or System.GetEntityByName("yourPlayer")
        if player then
            return player:GetPos()
        end
    end
    -- Fallback: use player global
    if player then
        local pos = player:GetPos()
        if pos then return pos end
    end
    return nil
end

local function get_nearest_npc()
    -- Try to get entities near player
    local player_pos = get_player_position()
    if not player_pos then
        -- Return a dummy NPC for testing when entity system is not available
        return {
            id = "test_npc_1",
            name = "Villager",
            class = "peasant",
            location = "Bohemia",
            extra_context = "Fallback test NPC (entity system unavailable)",
        }
    end

    local nearest = nil
    local nearest_dist = CONFIG.max_npc_distance

    -- Use CryEngine entity iteration
    if System and System.GetEntitiesByClass then
        local npc_classes = {"NPC", "BasicEntity", "Human"}
        for _, cls in ipairs(npc_classes) do
            local entities = System.GetEntitiesByClass(cls)
            if entities then
                for _, ent in ipairs(entities) do
                    local pos = ent:GetPos()
                    if pos then
                        local dx = pos.x - player_pos.x
                        local dy = pos.y - player_pos.y
                        local dz = pos.z - player_pos.z
                        local dist = math.sqrt(dx*dx + dy*dy + dz*dz)
                        if dist < nearest_dist then
                            nearest_dist = dist
                            nearest = build_npc_from_entity(ent)
                            if nearest then
                                nearest.extra_context = (nearest.extra_context ~= "" and (nearest.extra_context .. "\n") or "") .. "Selected by nearest-distance fallback."
                            end
                        end
                    end
                end
            end
        end
    end

    return nearest
end

-- ============================================================================
-- Chat Logic
-- ============================================================================

-- (forward declaration of build_recent_player_actions moved above
--  notify_active_npc so that ACTIVE| broadcasts can include recent actions too.)

local function has_http_post_client()
    local net_client = resolve_http_provider()
    return net_client ~= nil
end

local function send_via_log_ipc(request_data)
    next_request_id = next_request_id + 1
    request_data.request_id = next_request_id
    pending_request_id = next_request_id
    -- The new outgoing request invalidates any lingering-id collision: if the
    -- skip-set still holds this id (rare edge case after >=N messages), drop
    -- it so the upcoming real response is delivered.
    if _G.__ai_npc_lingering_ids and _G.__ai_npc_lingering_ids[next_request_id] then
        _G.__ai_npc_lingering_ids[next_request_id] = nil
    end
    System.LogAlways("[AI NPC] REQUEST|" .. json.encode(request_data))
    System.LogAlways("[AI NPC] REQUEST queued via log IPC, id=" .. tostring(next_request_id))
end

local function send_message(text)
    if not state.current_npc then return end
    local refused, refusal_mem = scene_refusal_active(state.current_npc.id)
    if refused then
        local msg = scene_refusal_text(refusal_mem)
        System.LogAlways("[AI NPC] SCENE_REFUSAL active: message blocked for npc=" .. tostring(state.current_npc.id))
        ui_show(msg, 6000)
        if use_overlay_ui() then
            ipc_write_cmd("MSG|npc|" .. tostring(state.current_npc.name or "NPC") .. "|" .. msg)
        end
        return
    end
    if state.waiting_response then
        local started = tonumber(state.waiting_since) or 0
        local elapsed = os.clock() - started
        if started > 0 and elapsed >= RESPONSE_TIMEOUT_SEC then
            state.waiting_response = false
            state.waiting_since = nil
            pending_request_id = 0
            state.error_message = "Response timeout"
            System.LogAlways("[AI NPC] Response timeout unlocked in send_message; elapsed=" .. tostring(elapsed))
            ui_show("AI NPC: предыдущий запрос завис, отправляю заново", 5000, { service = true })
        else
            ui_show("AI NPC: подождите ответ...", 2500, { service = true })
            return
        end
    end
    if text == "" then return end

    -- Add player message to chat
    table.insert(state.messages, {
        role = "player",
        name = "Henry",
        text = text,
    })

    if use_overlay_ui() then
        ipc_write_cmd("MSG|player|Henry|" .. text)
    end

    state.waiting_response = true
    state.waiting_since = os.clock()
    state.last_activity_at = os.clock()
    state.error_message = nil
    state.last_request_npc_id = state.current_npc.id
    state.last_request_npc_name = state.current_npc.name
    state.last_request_entity_ref = state.current_npc.entity_ref
    ui_show("Вы: " .. tostring(text), 5000)

    local player_pos, player_fwd = _get_player_pos_fwd()
    local request_data = {
        npc_id = state.current_npc.id,
        npc_name = state.current_npc.name,
        npc_class = state.current_npc.class,
        npc_location = state.current_npc.location,
        npc_gender = state.current_npc.gender or "unknown",
        player_message = text,
        extra_context = state.current_npc.extra_context or "",
        recent_player_actions = build_recent_player_actions(state.current_npc.id),
        npc_pos = state.current_npc.pos,
        player_pos = player_pos,
        player_fwd = player_fwd,
        request_id = 0,
    }

    if not has_http_post_client() then
        send_via_log_ipc(request_data)
        return
    end

    local ok_http, http_err = pcall(function()
        http_post("/chat", request_data, function(response, err)
            state.waiting_response = false
            state.waiting_since = nil
            state.last_activity_at = os.clock()
            if err then
                if tostring(err) == "HTTP module unavailable" then
                    send_via_log_ipc(request_data)
                    return
                end
                state.error_message = "Server error: " .. tostring(err)
                ui_show("AI NPC: ошибка сервера — " .. tostring(err), 7000, { service = true })
                return
            end
            if response and response.response then
                local npc_name_for_msg = (response.npc_name) or (state.current_npc and state.current_npc.name) or request_data.npc_name or "NPC"
                local npc_class_for_msg = (state.current_npc and state.current_npc.class) or request_data.npc_class or ""
                state.last_request_npc_id = request_data.npc_id
                state.last_request_npc_name = request_data.npc_name
                table.insert(state.messages, {
                    role = "npc",
                    name = npc_name_for_msg,
                    text = response.response,
                })
                if use_overlay_ui() then
                    ipc_write_cmd("MSG|npc|" .. npc_name_for_msg .. "|" .. response.response)
                end
                local label = npc_display_name(npc_name_for_msg, npc_class_for_msg)
                ui_show(label .. ": " .. tostring(response.response), 12000)
            else
                state.error_message = "Invalid response from server"
                ui_show("AI NPC: некорректный ответ от сервера", 7000, { service = true })
            end
        end)
    end)
    if not ok_http then
        state.waiting_response = false
        state.waiting_since = nil
        state.error_message = "HTTP request failed"
        System.LogAlways("[AI NPC] Chat request failed before send: " .. tostring(http_err))
        ui_show("AI NPC: ошибка отправки запроса", 7000, { service = true })
    end
end

function AI_NPC_Say(text)
    send_message(tostring(text or ""))
end

function AI_NPC_SayFromConsole(line)
    rearm_poll_from_user_context()
    -- Pump any pending NPC response first, since the polling timer is dead.
    pcall(process_resp_file)
    local text = tostring(line or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then
        ui_show("AI NPC: используйте ai_say ваш текст", 4000, { service = true })
        return
    end
    AI_NPC_Say(text)
end

-- =====================================================================
-- Game-input lockout while overlay is typing
-- ---------------------------------------------------------------------
-- The Tkinter overlay sits OUTSIDE the game process, so even with focus
-- stolen, KCD2's RawInput pipeline still receives keystrokes. Pressing
-- Enter to send a message can therefore trigger I (inventory), J (journal),
-- M (map) and other shortcuts that were typed into the overlay. To stop
-- this we disable the common gameplay action maps for the duration of the
-- dialog. The world keeps running (no g_pause): NPCs walk, time flows,
-- combat continues — only player keystrokes are absorbed. Our V key lives
-- on the custom "ai_npc" action map, which we deliberately do NOT touch.
-- =====================================================================
local INPUT_LOCKOUT_MAPS = { "default", "player", "singleplayer", "flymode", "menu_unknown" }
local input_lockout_active = false

local function pause_game_input()
    if input_lockout_active then return end
    input_lockout_active = true
    if ActionMapManager and ActionMapManager.EnableActionMap then
        for _, name in ipairs(INPUT_LOCKOUT_MAPS) do
            pcall(ActionMapManager.EnableActionMap, name, false)
        end
    end
    System.LogAlways("[AI NPC] Game input locked (overlay typing)")
end

local function resume_game_input()
    if not input_lockout_active then return end
    input_lockout_active = false
    if ActionMapManager and ActionMapManager.EnableActionMap then
        for _, name in ipairs(INPUT_LOCKOUT_MAPS) do
            pcall(ActionMapManager.EnableActionMap, name, true)
        end
    end
    System.LogAlways("[AI NPC] Game input unlocked")
end

local function start_conversation()
    local npc = get_targeted_npc()
    if not npc and not CONFIG.require_target_lock then
        npc = get_nearest_npc()
    end
    if not npc then
        state.error_message = "No NPC targeted"
        ui_show("AI NPC: наведитесь на персонажа и нажмите V", 4000, { service = true })
        return
    end
    local refused, refusal_mem = scene_refusal_active(npc.id)
    if refused then
        local msg = scene_refusal_text(refusal_mem)
        System.LogAlways("[AI NPC] SCENE_REFUSAL active: start blocked for npc=" .. tostring(npc.id))
        ui_show(msg, 6000)
        if use_overlay_ui() then
            ipc_write_cmd("MSG|npc|" .. tostring(npc.name or "NPC") .. "|" .. msg)
        end
        return
    end
    -- Switching to a different NPC: silently end the previous conversation
    -- on the server so its history is persisted to disk.
    if state.current_npc and state.current_npc.id and state.current_npc.id ~= npc.id then
        local prev_id = state.current_npc.id
        pcall(function() http_post("/end_conversation", { npc_id = prev_id }, function() end) end)
        System.LogAlways("[AI NPC] Auto-ended previous chat with " .. tostring(prev_id) .. " (switched NPC)")
    end
    npc_debug_probe(npc)
    state.current_npc = npc
    state.messages = {}
    state.chat_open = true
    state.last_activity_at = os.clock()
    state.error_message = nil
    state.input_text = ""
    notify_active_npc()
    if use_overlay_ui() then
        ipc_write_cmd("OPEN|" .. npc.name .. "|" .. npc.id)
    end
    ui_show("AI NPC: разговор с " .. npc_display_name(npc.name, npc.class) .. ". Команда: ai_say ваш текст",
            10000, { service = true })
    -- Lock out gameplay input so keystrokes typed into the overlay don't
    -- leak through and trigger inventory/map/etc. Released in end_conversation.
    pcall(pause_game_input)
end

end_conversation = function()
    local npc_id_to_close = state.current_npc and state.current_npc.id or nil
    System.LogAlways("[AI NPC] End requested, current_npc=" .. tostring(npc_id_to_close) .. ", chat_open=" .. tostring(state.chat_open))

    state.chat_open = false
    state.current_npc = nil
    state.messages = {}
    state.input_text = ""
    state.error_message = nil
    state.waiting_response = false
    state.waiting_since = nil
    pending_request_id = 0

    if npc_id_to_close then
        local ok, err = pcall(function()
            http_post("/end_conversation", { npc_id = npc_id_to_close }, function() end)
        end)
        if not ok then
            System.LogAlways("[AI NPC] End notify failed: " .. tostring(err))
        end
    end

    notify_active_npc()
    if use_overlay_ui() then
        ipc_write_cmd("CLOSE")
    end
    System.LogAlways("[AI NPC] End applied, chat_open=" .. tostring(state.chat_open))
    -- Restored as a service-only notification (top-right toast), so it shows up
    -- in the corner and never appears as a centered subtitle.
    ui_show("AI NPC: разговор завершён", 3000, { service = true })
    -- Release input lock so the player regains control.
    pcall(resume_game_input)
end

-- Global (not `local function`) so that AI_NPC_HandleWebCommand — which is
-- defined earlier in the file — can resolve this name via the global table
-- at call time. Marking it `local` here would create a local-only binding
-- that is invisible to closures created above this line, and the
-- __AI_NPC_TAP__ branch would silently raise "attempt to call a nil value"
-- inside the poll-step pcall.
function toggle_chat_with_debounce(source)
    local now = os.clock()
    if now - last_toggle_at < TOGGLE_COOLDOWN_SEC then
        System.LogAlways("[AI NPC] Toggle ignored (debounce), source=" .. tostring(source))
        return
    end
    last_toggle_at = now
    System.LogAlways("[AI NPC] Toggle accepted, source=" .. tostring(source) .. ", chat_open=" .. tostring(state.chat_open))
    if state.chat_open then
        end_conversation()
    else
        start_conversation()
    end
end

-- ============================================================================
-- File IPC with version.dll ImGui overlay
-- ============================================================================

local IPC_DIR = "Data/Scripts/ai_npc"
local IPC_CMD   = IPC_DIR .. "/chat_cmd.txt"    -- Lua writes commands here
local IPC_INPUT = IPC_DIR .. "/chat_input.txt"   -- DLL writes user input here

-- Write a command to the DLL
ipc_write_cmd = function(line)
    local f = io.open(IPC_CMD, "a")
    if f then
        f:write(line .. "\n")
        f:close()
        System.LogAlways("[AI NPC] IPC write: " .. tostring(line))
    else
        System.LogAlways("[AI NPC] IPC write FAILED: " .. tostring(IPC_CMD))
    end
end

-- Poll for user input from the DLL
ipc_poll_input = function()
    -- KCD2 GOG Lua sandbox has no io library, so this whole IPC path is a
    -- no-op. Returning early prevents the polling loop from throwing every
    -- single tick.
    if type(io) ~= "table" or type(io.open) ~= "function" then
        return
    end
    local f = io.open(IPC_INPUT, "r")
    if not f then return end
    local text = f:read("*a")
    f:close()
    if text and text ~= "" then
        System.LogAlways("[AI NPC] IPC input: " .. tostring(text))
        -- Clear the file
        local f2 = io.open(IPC_INPUT, "w")
        if f2 then f2:close() end
        -- Handle TOGGLE command (from V key press)
        if text:match("^TOGGLE") then
            toggle_chat_with_debounce("ipc")
        else
            if not use_overlay_ui() then
                System.LogAlways("[AI NPC] IPC text ignored (HUD mode)")
                return
            end
            -- Send the message
            AI_NPC_Say(text)
        end
    end
end

-- ============================================================================
-- Server status check
-- ============================================================================

local last_health_check = 0
local HEALTH_CHECK_INTERVAL = 10.0

local function check_server_health()
    local now = os.clock()
    if now - last_health_check < HEALTH_CHECK_INTERVAL then return end
    last_health_check = now

    -- Simple health check
    local get_client = nil
    local get_provider = nil
    get_client, get_provider = resolve_http_get_provider()
    if get_client and get_client.http_get then
        System.LogAlways("[AI NPC] Health provider=" .. tostring(get_provider))
        get_client.http_get(CONFIG.server_url .. "/health", function(status, body)
            state.server_online = (status >= 200 and status < 300)
        end)
    else
        state.server_online = false
    end
end

local function normalize_bind_key(raw)
    local key = tostring(raw or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if key == "" then return nil end
    if #key == 1 and key:match("[a-z0-9]") then
        return key
    end
    if key:match("^f%d%d?$") then
        local n = tonumber(key:sub(2)) or 0
        if n >= 1 and n <= 12 then
            return key
        end
    end
    return nil
end

local function load_ai_npc_actionmap_once()
    if actionmap_loaded then return end
    if not ActionMapManager then
        System.LogAlways("[AI NPC] ActionMapManager unavailable")
        return
    end

    local loaded = false
    local candidates = {
        "libs/config/ai_npc_actions.xml",
        "Libs/Config/ai_npc_actions.xml",
        "Data/Libs/Config/ai_npc_actions.xml",
    }

    for _, path in ipairs(candidates) do
        if ActionMapManager.LoadFromXML then
            local ok = pcall(ActionMapManager.LoadFromXML, path)
            if ok then
                loaded = true
                System.LogAlways("[AI NPC] ActionMap loaded from " .. tostring(path))
                break
            end
        end
    end

    if loaded and ActionMapManager.EnableActionMap then
        pcall(ActionMapManager.EnableActionMap, "ai_npc", true)
    end

    actionmap_loaded = loaded
end

function sync_binds_from_actionmap()
    if _G.__ai_npc_binds_done then return end
    load_ai_npc_actionmap_once()
    if not (System and System.ExecuteCommand) then
        return
    end

    local ok_chat = false
    local chat_raw = nil
    if Game and Game.GetActionControl then
        ok_chat, chat_raw = pcall(Game.GetActionControl, "ai_npc", "ai_npc_chat")
    end
    -- We always bind V -> ai_chat in CryEngine. Even when PTT is enabled
    -- (Python KeyMonitor handles tap/hold), we still need the console bind
    -- so the very first V keystroke wakes up the Lua polling timer (which
    -- is dead at bootstrap on the rolled-back GOG DLL). AI_NPC_Toggle()
    -- itself is PTT-aware: under PTT it only rearms the poll and pumps
    -- responses, it does NOT open the chat overlay — the overlay is opened
    -- only via __AI_NPC_TAP__ from the Python KeyMonitor. See AI_NPC_Toggle
    -- comment for the full rationale.
    local bind_target = "ai_chat"
    if bind_target then
        if ok_chat then
            local chat_key = normalize_bind_key(chat_raw)
            if chat_key and chat_key ~= last_synced_chat_key then
                System.ExecuteCommand("bind " .. chat_key .. " " .. bind_target)
                System.LogAlways("[AI NPC] Bound from actionmap: " .. tostring(chat_key) .. " -> " .. bind_target)
                last_synced_chat_key = chat_key
            end
        end
        if not last_synced_chat_key then
            System.ExecuteCommand("bind " .. CONFIG.chat_key .. " " .. bind_target)
            System.LogAlways("[AI NPC] Bound fallback: " .. tostring(CONFIG.chat_key) .. " -> " .. bind_target)
            last_synced_chat_key = CONFIG.chat_key
        end
    else
        -- PTT enabled: server-side KeyMonitor handles V. Pre-emptively
        -- `unbind` whatever the previous session might have stamped on this
        -- key (legacy `bind v ai_chat` or `bind v +ai_ptt`) so that holding V
        -- in a freshly-reloaded session doesn't fire the old action and
        -- spawn the text overlay (which would then receive 'vvvv' from the
        -- still-pressed key). Idempotent and safe: `unbind` of an unbound
        -- key is a no-op.
        if not _G.__ai_npc_unbind_v_done then
            local target_key = nil
            if ok_chat then target_key = normalize_bind_key(chat_raw) end
            target_key = target_key or CONFIG.chat_key
            if target_key and target_key ~= "" then
                pcall(System.ExecuteCommand, "unbind " .. target_key)
                System.LogAlways("[AI NPC] PTT enabled — V delegated to server KeyMonitor; unbound '" .. tostring(target_key) .. "' from any prior action")
            end
            _G.__ai_npc_unbind_v_done = true
        end
        last_synced_chat_key = nil  -- so a future ptt_enabled=false toggle re-binds cleanly
    end

    local ok_end = false
    local end_raw = nil
    if Game and Game.GetActionControl then
        ok_end, end_raw = pcall(Game.GetActionControl, "ai_npc", "ai_npc_end")
    end
    if ok_end then
        local end_key = normalize_bind_key(end_raw)
        if end_key and end_key ~= last_synced_end_key then
            System.ExecuteCommand("bind " .. end_key .. " ai_end")
            System.LogAlways("[AI NPC] Bound from actionmap: " .. tostring(end_key) .. " -> ai_end")
            last_synced_end_key = end_key
        end
    end

    _G.__ai_npc_binds_done = true
end

-- ============================================================================
-- Main hooks
-- ============================================================================

-- Register keybinds via CryEngine console commands
local function on_key_press(key)
    if key == CONFIG.chat_key then
        if state.chat_open then
            end_conversation()
        else
            start_conversation()
        end
    elseif key == CONFIG.end_key then
        if state.chat_open then
            end_conversation()
        end
    end
end

local function ai_npc_diag_target()
    local ok, npc = pcall(get_targeted_npc)
    if ok and npc and npc.entity_ref then
        state.last_target_npc_id = npc.id
        state.last_target_entity_ref = npc.entity_ref
        System.LogAlways("[AI NPC] DIAG target id=" .. tostring(npc.id) .. " name=" .. tostring(npc.name) .. " class=" .. tostring(npc.class))
        return npc.entity_ref, npc
    end
    local ent = scene_resolve_entity({ npc_id = state.last_target_npc_id or state.last_request_npc_id })
    if ent then
        System.LogAlways("[AI NPC] DIAG target fallback entity=" .. tostring(ent))
        return ent, nil
    end
    System.LogAlways("[AI NPC] DIAG no target entity")
    return nil, nil
end

function AI_NPC_TestSignal(line)
    local signal = tostring(line or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if signal == "" then signal = "OnPlayerTooClose" end
    local ent = ai_npc_diag_target()
    if not ent then return end
    local ok = scene_send_ai_signal(ent, signal)
    System.LogAlways("[AI NPC] DIAG signal=" .. signal .. " ok=" .. tostring(ok))
end

function AI_NPC_TestXGenMsg(line)
    local msg = tostring(line or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if msg == "" then msg = "greeting:waveRequest" end
    local ent = ai_npc_diag_target()
    if not ent then return end
    local ok = false
    if XGenAIModule and type(XGenAIModule.SendMessageToEntity) == "function" then
        local targetId = ent.this and ent.this.id or ent.id
        ok = pcall(function() return XGenAIModule.SendMessageToEntity(targetId, msg, "") end)
    else
        System.LogAlways("[AI NPC] DIAG xgen_msg unavailable: XGenAIModule.SendMessageToEntity missing")
    end
    System.LogAlways("[AI NPC] DIAG xgen_msg=" .. msg .. " ok=" .. tostring(ok))
end

function AI_NPC_TestXGenData(line)
    local msg = tostring(line or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if msg == "" then msg = "greeting:waveRequest" end
    local ent = ai_npc_diag_target()
    if not ent then return end
    local ok = false
    if XGenAIModule and type(XGenAIModule.SendMessageToEntityData) == "function" then
        local targetId = ent.this and ent.this.id or ent.id
        local data = { alias = msg, type = "npc_test" }
        ok = pcall(function() return XGenAIModule.SendMessageToEntityData(targetId, msg, data) end)
    else
        System.LogAlways("[AI NPC] DIAG xgen_data unavailable: XGenAIModule.SendMessageToEntityData missing")
    end
    System.LogAlways("[AI NPC] DIAG xgen_data=" .. msg .. " ok=" .. tostring(ok))
end

function AI_NPC_TestGameEvent(line)
    local evt = tostring(line or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if evt == "" then evt = "OnPlayerSeen" end
    local ent = ai_npc_diag_target()
    if not ent then return end
    local ok = false
    if Game and type(Game.SendEventToGameObject) == "function" then
        ok = pcall(function() return Game.SendEventToGameObject(ent.id, evt) end)
    else
        System.LogAlways("[AI NPC] DIAG game_event unavailable: Game.SendEventToGameObject missing")
    end
    System.LogAlways("[AI NPC] DIAG game_event=" .. evt .. " ok=" .. tostring(ok))
end

function AI_NPC_TestAudioTrigger(line)
    local trigger = tostring(line or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local ent = ai_npc_diag_target()
    if not ent then return end
    local function resolve_trigger_id(name)
        local numeric = tonumber(name)
        if numeric then return numeric, "number" end
        if Sound and type(Sound.GetAudioTriggerID) == "function" then
            local ok, id = pcall(function() return Sound.GetAudioTriggerID(name) end)
            System.LogAlways("[AI NPC] DIAG audio_trigger lookup name=" .. tostring(name) .. " ok=" .. tostring(ok) .. " id=" .. tostring(id))
            if ok and id ~= nil and id ~= 0 then return id, "Sound.GetAudioTriggerID" end
        else
            System.LogAlways("[AI NPC] DIAG audio_trigger lookup unavailable: Sound.GetAudioTriggerID missing")
        end
        return nil, "missing"
    end
    local function get_aux_proxy(obj)
        if type(obj) == "table" and type(obj.GetDefaultAuxAudioProxyID) == "function" then
            local ok, proxy = pcall(function() return obj:GetDefaultAuxAudioProxyID() end)
            System.LogAlways("[AI NPC] DIAG audio_trigger aux ok=" .. tostring(ok) .. " proxy=" .. tostring(proxy))
            if ok then return proxy end
        end
        return nil
    end
    local function play_one(name)
        local trigger_id, source = resolve_trigger_id(name)
        if not trigger_id then
            System.LogAlways("[AI NPC] DIAG audio_trigger missing id for trigger=" .. tostring(name))
            return false
        end
        local targets = {
            { label = "entity", obj = ent },
            { label = "actor", obj = ent.actor },
            { label = "human", obj = ent.human },
        }
        for _, target in ipairs(targets) do
            if type(target.obj) == "table" and type(target.obj.ExecuteAudioTrigger) == "function" then
                local aux = get_aux_proxy(target.obj) or get_aux_proxy(ent)
                local ok, result = pcall(function() return target.obj:ExecuteAudioTrigger(trigger_id, aux) end)
                System.LogAlways("[AI NPC] DIAG audio_trigger target=" .. target.label .. " trigger=" .. tostring(name) .. " id=" .. tostring(trigger_id) .. " source=" .. tostring(source) .. " aux=" .. tostring(aux) .. " ok=" .. tostring(ok) .. " result=" .. tostring(result))
                return ok
            end
        end
        System.LogAlways("[AI NPC] DIAG audio_trigger unavailable: ExecuteAudioTrigger missing on entity/actor/human")
        return false
    end
    if trigger == "" then trigger = "all" end
    if trigger == "all" then
        local candidates = { "male_spit", "v_male_injured_reaction1", "v_male_scream_in_pain1", "v_male_falling_scream1", "v_male_choking", "v_eating_apple" }
        for _, name in ipairs(candidates) do play_one(name) end
        return
    end
    play_one(trigger)
end

function AI_NPC_TestQueueAnim(line)
    local anim = tostring(line or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if anim == "" then anim = "GreetingsUpperBody" end
    local ent = ai_npc_diag_target()
    if not ent then return end
    local ok = false
    if ent.actor and type(ent.actor.QueueAnimationState) == "function" then
        ok = pcall(function() return ent.actor:QueueAnimationState(anim) end)
    else
        System.LogAlways("[AI NPC] DIAG queue_anim unavailable: actor.QueueAnimationState missing")
    end
    System.LogAlways("[AI NPC] DIAG queue_anim=" .. anim .. " ok=" .. tostring(ok))
end

function AI_NPC_TestGetAnimState()
    local ent = ai_npc_diag_target()
    if not ent then return end
    local ok, result = false, nil
    if ent.actor and type(ent.actor.GetCurrentAnimationState) == "function" then
        ok, result = pcall(function() return ent.actor:GetCurrentAnimationState() end)
    else
        System.LogAlways("[AI NPC] DIAG get_anim_state unavailable: actor.GetCurrentAnimationState missing")
    end
    System.LogAlways("[AI NPC] DIAG get_anim_state ok=" .. tostring(ok) .. " result=" .. tostring(result))
end

function AI_NPC_TestStartAnim(line)
    local anim = tostring(line or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if anim == "" then anim = "aimposes_pointing_01" end
    local ent = ai_npc_diag_target()
    if not ent then return end
    local function try_layer(layer)
        local ok, result = false, nil
        if type(ent.StartAnimation) == "function" then
            ok, result = pcall(function() return ent:StartAnimation(layer, anim, 0, 0, 1, false, 1) end)
        else
            System.LogAlways("[AI NPC] DIAG start_anim unavailable: ent.StartAnimation missing")
        end
        System.LogAlways("[AI NPC] DIAG start_anim layer=" .. layer .. " anim=" .. anim .. " ok=" .. tostring(ok) .. " result=" .. tostring(result))
    end
    try_layer(0)
    try_layer(1)
end

function AI_NPC_TestAudioMethods()
    local ent = ai_npc_diag_target()
    if not ent then return end
    if Sound then
        System.LogAlways("[AI NPC] DIAG audio_methods Sound.GetAudioTriggerID=" .. tostring(type(Sound.GetAudioTriggerID)) .. " Sound.GetAudioRtpcID=" .. tostring(type(Sound.GetAudioRtpcID)) .. " Sound.GetAudioSwitchID=" .. tostring(type(Sound.GetAudioSwitchID)))
    else
        System.LogAlways("[AI NPC] DIAG audio_methods Sound=nil")
    end
    local function dump_audio_methods(label, t)
        if type(t) ~= "table" then
            System.LogAlways("[AI NPC] DIAG audio_methods " .. label .. "=" .. type(t))
            return
        end
        local keys = {}
        local mt = getmetatable(t)
        local source = t
        if mt and type(mt.__index) == "table" then source = mt.__index end
        for k, v in pairs(source) do
            if type(v) == "function" then
                local name = tostring(k)
                local lower = name:lower()
                if lower:find("audio", 1, true) or lower:find("sound", 1, true) or lower:find("voice", 1, true) or lower:find("trigger", 1, true) then
                    table.insert(keys, name)
                end
            end
        end
        table.sort(keys)
        System.LogAlways("[AI NPC] DIAG audio_methods " .. label .. ": " .. table.concat(keys, ", "))
    end
    dump_audio_methods("entity", ent)
    dump_audio_methods("actor", ent.actor)
    dump_audio_methods("human", ent.human)
end

function AI_NPC_TestEngineTTSLoadBank(line)
    local path = tostring(line or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if path == "" then path = "Bin/Win64MasterMasterGogPGO/plugins/ai_npc/ai_npc_tts.bank" end
    if not rom or not rom.audio or type(rom.audio.load_bank) ~= "function" then
        System.LogAlways("[AI NPC] ENGINE_TTS load_bank unavailable: rom.audio.load_bank missing")
        return
    end
    local ok, result = pcall(function() return rom.audio.load_bank(path) end)
    System.LogAlways("[AI NPC] ENGINE_TTS load_bank path=" .. tostring(path) .. " ok=" .. tostring(ok) .. " result=" .. tostring(result))
end

function AI_NPC_TestEngineTTSPlay(line)
    local trigger = tostring(line or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if trigger == "" then trigger = "ai_npc_tts_reply" end
    local ent = ai_npc_diag_target()
    if not ent then return end
    if not Sound or type(Sound.GetAudioTriggerID) ~= "function" then
        System.LogAlways("[AI NPC] ENGINE_TTS play unavailable: Sound.GetAudioTriggerID missing")
        return
    end
    if type(ent.ExecuteAudioTrigger) ~= "function" then
        System.LogAlways("[AI NPC] ENGINE_TTS play unavailable: entity.ExecuteAudioTrigger missing")
        return
    end
    local ok_id, trigger_id = pcall(function() return Sound.GetAudioTriggerID(trigger) end)
    System.LogAlways("[AI NPC] ENGINE_TTS lookup trigger=" .. tostring(trigger) .. " ok=" .. tostring(ok_id) .. " id=" .. tostring(trigger_id))
    if not ok_id or trigger_id == nil or trigger_id == 0 then return end
    local aux = nil
    if type(ent.GetDefaultAuxAudioProxyID) == "function" then
        local ok_aux, result_aux = pcall(function() return ent:GetDefaultAuxAudioProxyID() end)
        if ok_aux then aux = result_aux end
    end
    local ok_play, result_play = pcall(function() return ent:ExecuteAudioTrigger(trigger_id, aux) end)
    System.LogAlways("[AI NPC] ENGINE_TTS play target=entity trigger=" .. tostring(trigger) .. " id=" .. tostring(trigger_id) .. " aux=" .. tostring(aux) .. " ok=" .. tostring(ok_play) .. " result=" .. tostring(result_play))
end

function AI_NPC_TestEnginePlayFile3D(line)
    local path = tostring(line or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if path == "" then path = "Bin/Win64MasterMasterGogPGO/plugins/ai_npc/tts_reply.wav" end
    local ent = ai_npc_diag_target()
    if not ent then return end
    if not rom or not rom.audio or type(rom.audio.play_file_3d) ~= "function" then
        System.LogAlways("[AI NPC] ENGINE_TTS play_file_3d unavailable: rom.audio.play_file_3d missing")
        return
    end
    local pos = scene_get_pos(ent)
    if type(pos) ~= "table" then
        System.LogAlways("[AI NPC] ENGINE_TTS play_file_3d unavailable: target position missing")
        return
    end
    local x = tonumber(pos.x) or 0
    local y = tonumber(pos.y) or 0
    local z = tonumber(pos.z) or 0
    local ok, result = pcall(function() return rom.audio.play_file_3d(path, x, y, z, 1.0) end)
    System.LogAlways("[AI NPC] ENGINE_TTS play_file_3d path=" .. tostring(path) .. " pos=" .. tostring(x) .. "," .. tostring(y) .. "," .. tostring(z) .. " ok=" .. tostring(ok) .. " result=" .. tostring(result))
end

function AI_NPC_TestAnim(line)
    local anim = tostring(line or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if anim == "" then anim = "stagger_back" end
    local ent = ai_npc_diag_target()
    if not ent then return end
    if type(ent.human) ~= "table" or type(ent.human.PlayAnim) ~= "function" then
        System.LogAlways("[AI NPC] DIAG anim unavailable: human.PlayAnim missing")
        return
    end
    local ok, result = pcall(function() return ent.human:PlayAnim(anim, "") end)
    System.LogAlways("[AI NPC] DIAG anim=" .. anim .. " ok=" .. tostring(ok) .. " result=" .. tostring(result))
end

function AI_NPC_TestIAct(line)
    local action = tostring(line or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if action == "" then action = "stagger" end
    local ent = ai_npc_diag_target()
    if not ent then return end
    if type(ent.actor) ~= "table" or type(ent.actor.StartInteractiveActionByName) ~= "function" then
        System.LogAlways("[AI NPC] DIAG iact unavailable: actor.StartInteractiveActionByName missing")
        return
    end
    local ok, result = pcall(function() return ent.actor:StartInteractiveActionByName(action) end)
    System.LogAlways("[AI NPC] DIAG iact=" .. action .. " ok=" .. tostring(ok) .. " result=" .. tostring(result))
end

function AI_NPC_TestSimAct(line)
    local action = tostring(line or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if action == "" then action = "dodge" end
    local ent = ai_npc_diag_target()
    if not ent then return end
    if type(ent.actor) ~= "table" or type(ent.actor.SimulateOnAction) ~= "function" then
        System.LogAlways("[AI NPC] DIAG simact unavailable: actor.SimulateOnAction missing")
        return
    end
    local ok, result = pcall(function() return ent.actor:SimulateOnAction(action, 1, 1.0) end)
    System.LogAlways("[AI NPC] DIAG simact=" .. action .. " ok=" .. tostring(ok) .. " result=" .. tostring(result))
end

function AI_NPC_TestLook()
    local ent = ai_npc_diag_target()
    if not ent then return end
    local player_ent = get_player_entity()
    if not player_ent then
        System.LogAlways("[AI NPC] DIAG look unavailable: no player entity")
        return
    end
    local ok_look_actor = false
    local result_look_actor = nil
    if type(ent.actor) == "table" and type(ent.actor.MakeLookAsActor) == "function" then
        ok_look_actor, result_look_actor = pcall(function() return ent.actor:MakeLookAsActor(player_ent.id) end)
    end
    local ok_forced = false
    local result_forced = nil
    if type(ent.actor) == "table" and type(ent.actor.SetForcedLookDir) == "function" then
        local npc_pos = scene_get_pos(ent)
        local player_pos = scene_get_pos(player_ent)
        if type(npc_pos) == "table" and type(player_pos) == "table" then
            local dir = {
                x = (tonumber(player_pos.x) or 0) - (tonumber(npc_pos.x) or 0),
                y = (tonumber(player_pos.y) or 0) - (tonumber(npc_pos.y) or 0),
                z = ((tonumber(player_pos.z) or 0) + 1.5) - ((tonumber(npc_pos.z) or 0) + 1.5),
            }
            ok_forced, result_forced = pcall(function() return ent.actor:SetForcedLookDir(dir) end)
        end
    end
    System.LogAlways("[AI NPC] DIAG look MakeLookAsActor=" .. tostring(ok_look_actor) .. "/" .. tostring(result_look_actor) .. " SetForcedLookDir=" .. tostring(ok_forced) .. "/" .. tostring(result_forced))
end

function AI_NPC_TestDialogState(line)
    local state_name = tostring(line or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if state_name == "" then state_name = "angry" end
    local ent = ai_npc_diag_target()
    if not ent then return end
    if type(ent.actor) ~= "table" or type(ent.actor.SetDialogAnimationState) ~= "function" then
        System.LogAlways("[AI NPC] DIAG dialog_state unavailable: actor.SetDialogAnimationState missing")
        return
    end
    local ok, result = pcall(function() return ent.actor:SetDialogAnimationState(state_name) end)
    System.LogAlways("[AI NPC] DIAG dialog_state=" .. state_name .. " ok=" .. tostring(ok) .. " result=" .. tostring(result))
end

function AI_NPC_TestIAct2(line)
    local action = tostring(line or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if action == "" then action = "stagger" end
    local ent = ai_npc_diag_target()
    if not ent then return end
    local player_ent = get_player_entity()
    if type(ent.actor) ~= "table" or type(ent.actor.StartInteractiveActionByName) ~= "function" then
        System.LogAlways("[AI NPC] DIAG iact2 unavailable: actor.StartInteractiveActionByName missing")
        return
    end
    local ok, result = pcall(function() return ent.actor:StartInteractiveActionByName(action, player_ent and player_ent.id or nil, true, 1) end)
    System.LogAlways("[AI NPC] DIAG iact2=" .. action .. " ok=" .. tostring(ok) .. " result=" .. tostring(result))
end

function AI_NPC_TestMethods()
    local ent = ai_npc_diag_target()
    if not ent then return end
    local function dump_methods(label, t)
        if type(t) ~= "table" then
            System.LogAlways("[AI NPC] DIAG methods " .. label .. "=" .. type(t))
            return
        end
        local keys = {}
        local mt = getmetatable(t)
        local source = t
        if mt and type(mt.__index) == "table" then source = mt.__index end
        for k, v in pairs(source) do
            if type(v) == "function" then table.insert(keys, tostring(k)) end
        end
        table.sort(keys)
        System.LogAlways("[AI NPC] DIAG methods " .. label .. ": " .. table.concat(keys, ", "))
    end
    dump_methods("entity", ent)
    dump_methods("actor", ent.actor)
    dump_methods("human", ent.human)
end

function AI_NPC_TestWeapon(line)
    local action = tostring(line or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if action == "" then action = "toggle" end
    local ent = ai_npc_diag_target()
    if not ent then return end
    if type(ent.human) ~= "table" then
        System.LogAlways("[AI NPC] DIAG weapon unavailable: human missing")
        return
    end
    local ok = false
    local result = nil
    if action == "draw" then
        if type(ent.human.DrawWeapon) ~= "function" then
            System.LogAlways("[AI NPC] DIAG weapon draw unavailable")
            return
        end
        ok, result = pcall(function() return ent.human:DrawWeapon() end)
    elseif action == "holster" then
        if type(ent.human.HolsterWeapon) ~= "function" then
            System.LogAlways("[AI NPC] DIAG weapon holster unavailable")
            return
        end
        ok, result = pcall(function() return ent.human:HolsterWeapon() end)
    elseif action == "toggle" then
        if type(ent.human.ToggleWeapon) ~= "function" then
            System.LogAlways("[AI NPC] DIAG weapon toggle unavailable")
            return
        end
        ok, result = pcall(function() return ent.human:ToggleWeapon() end)
    elseif action == "toggle_set" then
        if type(ent.human.ToggleWeaponSet) ~= "function" then
            System.LogAlways("[AI NPC] DIAG weapon toggle_set unavailable")
            return
        end
        ok, result = pcall(function() return ent.human:ToggleWeaponSet() end)
    else
        System.LogAlways("[AI NPC] DIAG weapon unknown action=" .. action .. " use draw|holster|toggle|toggle_set")
        return
    end
    local drawn = "unknown"
    if type(ent.human.IsWeaponDrawn) == "function" then
        local ok_drawn, result_drawn = pcall(function() return ent.human:IsWeaponDrawn() end)
        if ok_drawn then drawn = tostring(result_drawn) end
    end
    System.LogAlways("[AI NPC] DIAG weapon=" .. action .. " ok=" .. tostring(ok) .. " result=" .. tostring(result) .. " drawn=" .. drawn)
end

function AI_NPC_TestFall()
    local ent = ai_npc_diag_target()
    if not ent then return end
    if type(ent.actor) ~= "table" or type(ent.actor.Fall) ~= "function" then
        System.LogAlways("[AI NPC] DIAG fall unavailable: actor.Fall missing")
        return
    end
    local ok, result = pcall(function() return ent.actor:Fall() end)
    System.LogAlways("[AI NPC] DIAG fall ok=" .. tostring(ok) .. " result=" .. tostring(result))
end

function AI_NPC_TestRagdoll()
    local ent = ai_npc_diag_target()
    if not ent then return end
    if type(ent.actor) ~= "table" or type(ent.actor.RagDollize) ~= "function" then
        System.LogAlways("[AI NPC] DIAG ragdoll unavailable: actor.RagDollize missing")
        return
    end
    local ok, result = pcall(function() return ent.actor:RagDollize() end)
    System.LogAlways("[AI NPC] DIAG ragdoll ok=" .. tostring(ok) .. " result=" .. tostring(result))
end

function AI_NPC_TestInventoryMethods()
    local ent = ai_npc_diag_target()
    if not ent then return end
    local function dump_methods(label, t)
        if type(t) ~= "table" then
            System.LogAlways("[AI NPC] DIAG inv_methods " .. label .. "=" .. type(t))
            return
        end
        local keys = {}
        local mt = getmetatable(t)
        local source = t
        if mt and type(mt.__index) == "table" then source = mt.__index end
        for k, v in pairs(source) do
            if type(v) == "function" then table.insert(keys, tostring(k)) end
        end
        table.sort(keys)
        System.LogAlways("[AI NPC] DIAG inv_methods " .. label .. ": " .. table.concat(keys, ", "))
    end
    dump_methods("inventory", ent.inventory)
    dump_methods("soul", ent.soul)
end

function AI_NPC_TestEquipmentMethods()
    local ent = ai_npc_diag_target()
    if not ent then return end
    local needles = {
        "equip", "unequip", "cloth", "clothing", "wear", "worn", "slot", "outfit",
        "preset", "body", "armor", "item", "inventory", "model", "refresh",
        "appearance", "underwear", "storm", "character", "component", "reload",
        "rebuild", "setbody", "setunderwear", "setappearance"
    }
    local function matches(name)
        local lower = tostring(name):lower()
        for _, needle in ipairs(needles) do
            if string.find(lower, needle, 1, true) then return true end
        end
        return false
    end
    local function dump_filtered(label, t)
        if type(t) ~= "table" then
            System.LogAlways("[AI NPC] DIAG equipment_methods " .. label .. "=" .. type(t))
            return
        end
        local funcs = {}
        local fields = {}
        local sources = { t }
        local mt = getmetatable(t)
        if mt and type(mt.__index) == "table" then table.insert(sources, mt.__index) end
        for _, source in ipairs(sources) do
            for k, v in pairs(source) do
                if matches(k) then
                    local entry = tostring(k) .. "=" .. type(v)
                    if type(v) == "function" then
                        table.insert(funcs, tostring(k))
                    else
                        table.insert(fields, entry)
                    end
                end
            end
        end
        table.sort(funcs)
        table.sort(fields)
        System.LogAlways("[AI NPC] DIAG equipment_methods " .. label .. " funcs: " .. table.concat(funcs, ", "))
        System.LogAlways("[AI NPC] DIAG equipment_methods " .. label .. " fields: " .. table.concat(fields, ", "))
    end
    System.LogAlways("[AI NPC] DIAG equipment_methods target entity=" .. type(ent) .. " actor=" .. type(ent.actor) .. " human=" .. type(ent.human) .. " inventory=" .. type(ent.inventory) .. " soul=" .. type(ent.soul))
    dump_filtered("entity", ent)
    dump_filtered("actor", ent.actor)
    dump_filtered("human", ent.human)
    dump_filtered("inventory", ent.inventory)
    dump_filtered("soul", ent.soul)
    dump_filtered("Properties", ent.Properties)
    dump_filtered("PropertiesInstance", ent.PropertiesInstance)
    dump_filtered("PropertiesShared", ent.PropertiesShared)
    dump_filtered("gameParams", ent.gameParams)
end

function AI_NPC_TestAppearanceProps()
    local ent = ai_npc_diag_target()
    if not ent then return end
    local function log_value(path, value)
        System.LogAlways("[AI NPC] DIAG appearance_props " .. path .. "=" .. tostring(value) .. " type=" .. type(value))
    end
    local function log_table_values(label, t)
        if type(t) ~= "table" then
            log_value(label, t)
            return
        end
        local keys = {
            "fileModel", "clientFileModel", "currModel", "currItemModel",
            "esClothingConfig", "aicharacter_character", "characterDetail",
            "nModelVariations", "bClothingRemoveHelmet", "guidSubstituteBodyPresetId",
            "guidBeardHairOverrideId", "sWH_AI_EntityCategory", "esVoice",
            "esFaction", "esCommConfig", "SoundPack", "voiceType"
        }
        for _, key in ipairs(keys) do
            log_value(label .. "." .. key, t[key])
        end
        for k, v in pairs(t) do
            local lower = tostring(k):lower()
            if string.find(lower, "cloth", 1, true)
                or string.find(lower, "body", 1, true)
                or string.find(lower, "model", 1, true)
                or string.find(lower, "appearance", 1, true)
                or string.find(lower, "underwear", 1, true)
                or string.find(lower, "character", 1, true)
                or string.find(lower, "variation", 1, true) then
                log_value(label .. "." .. tostring(k), v)
            end
        end
    end
    System.LogAlways("[AI NPC] DIAG appearance_props has SetActorModel=" .. type(ent.SetActorModel) .. " LoadCharacter=" .. type(ent.LoadCharacter) .. " ForceCharacterUpdate=" .. type(ent.ForceCharacterUpdate) .. " CreateAttachments=" .. type(ent.CreateAttachments))
    log_table_values("entity", ent)
    log_table_values("Properties", ent.Properties)
    log_table_values("PropertiesInstance", ent.PropertiesInstance)
    log_table_values("PropertiesShared", ent.PropertiesShared)
    log_table_values("gameParams", ent.gameParams)
end

function AI_NPC_TestRefreshModel(line)
    local mode = tostring(line or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
    if mode == "" then mode = "force" end
    local ent = ai_npc_diag_target()
    if not ent then return end
    local props = ent.Properties or {}
    System.LogAlways("[AI NPC] DIAG refresh_model mode=" .. mode .. " fileModel=" .. tostring(props.fileModel) .. " esClothingConfig=" .. tostring(props.esClothingConfig) .. " SetActorModel=" .. type(ent.SetActorModel) .. " ForceCharacterUpdate=" .. type(ent.ForceCharacterUpdate) .. " LoadCharacter=" .. type(ent.LoadCharacter))
    if mode == "setmodel" or mode == "both" then
        System.LogAlways("[AI NPC] DIAG refresh_model blocked unsafe SetActorModel mode after crash report; use force only")
        return
    end
    if mode == "force" or mode == "both" then
        if type(ent.ForceCharacterUpdate) == "function" then
            local ok, result = pcall(function() return ent:ForceCharacterUpdate(0, false) end)
            System.LogAlways("[AI NPC] DIAG refresh_model ForceCharacterUpdate ok=" .. tostring(ok) .. " result=" .. tostring(result))
        else
            System.LogAlways("[AI NPC] DIAG refresh_model ForceCharacterUpdate unavailable")
        end
    end
    if mode ~= "force" and mode ~= "setmodel" and mode ~= "both" then
        System.LogAlways("[AI NPC] DIAG refresh_model usage: ai_npc_test_refresh_model force")
    end
end

local AI_NPC_EQUIP_SLOT_TO_CATEGORY = {
    head_coif = "head",
    head_coif_padded = "head",
    head_cap = "head",
    head_helmet = "head",
    head_hood = "head",
    collar = "neck",
    body_cloth = "body",
    body_cloth_padded = "body",
    body_chainmail = "body",
    body_plate = "body",
    body_coat = "body",
    sleeves = "arms",
    gloves = "arms",
    leg_trousers = "legs",
    leg_trousers_padded = "legs",
    leg_armor = "legs",
    boot = "feet",
    spur = "cosmetic",
}

local AI_NPC_ARMOR_TYPE_SLOT_FALLBACK = {
    Gloves = "arms",
    Gauntlets = "arms",
    HandWrap = "arms",
    WeightedHandWrap = "arms",
    BootsAnkle = "feet",
    BootsKnee = "feet",
    Shoes = "feet",
    NoBoots = "feet",
    F_Shoes = "feet",
    Waffenrock = "body",
    Coat = "body",
    Habit = "body",
    Fitted = "body",
    Gambeson = "body",
    Musa = "body",
    Vavak = "body",
    F_Cotehardie = "body",
    F_Surcote = "body",
    F_SimpleDress = "body",
    F_Smock = "body",
    LegsClothTrousersLong = "legs",
    LegsClothTrousersLong_withFeet = "legs",
    LegsClothTrousersShort = "legs",
    Legsmailrh = "legs",
    Coif = "head",
    coifdown = "head",
    coifup = "head",
    HairCapBrabant = "head",
    F_Cap = "head",
    F_Wreath_m = "head",
    F_VeilMagdalena_m = "head",
    Hood = "head",
}

local AI_NPC_WEAPON_CLASS_NAMES = {
    [1] = "sword",
    [2] = "sabre",
    [3] = "axe",
    [4] = "mace",
    [5] = "polearm",
    [6] = "shield",
    [7] = "bow",
    [8] = "arrow",
    [9] = "crossbow",
    [10] = "bolt",
    [11] = "torch",
    [12] = "unarmed",
    [13] = "handgonne",
    [14] = "firearm",
    [15] = "crossbow_heavy",
    [16] = "hunting_sword",
}

local AI_NPC_ITEM_CLASS_INFO = nil
local AI_NPC_ITEM_ALIASES = nil
local AI_NPC_ARMOR_NAME_TO_INFO = nil
local AI_NPC_ARMOR_NAMES_SORTED = nil

local function ai_npc_parse_attrs(tag)
    local attrs = {}
    for k, v in tostring(tag or ""):gmatch('([%w_]+)%s*=%s*"([^"]*)"') do
        attrs[k] = v
    end
    return attrs
end

local function ai_npc_item_load_text(path)
    if not System or type(System.LoadTextFile) ~= "function" then return nil end
    local ok, text = pcall(function() return System.LoadTextFile(path) end)
    if ok and type(text) == "string" and text ~= "" then return text end
    return nil
end

local function ai_npc_item_build_armor_map()
    AI_NPC_ARMOR_NAME_TO_INFO = {}
    AI_NPC_ARMOR_NAMES_SORTED = {}
    local slot_text = ai_npc_item_load_text("libs/tables/item/equipment_slot.xml")
    if slot_text then
        for tc in slot_text:gmatch("<EquipmentSlot%s+([^<>]-)%s*/>") do
            local a = ai_npc_parse_attrs(tc)
            local cat = a.Name and AI_NPC_EQUIP_SLOT_TO_CATEGORY[a.Name]
            if cat and a.ArmorTypes then
                for type_name in a.ArmorTypes:gmatch("%S+") do
                    AI_NPC_ARMOR_NAME_TO_INFO[type_name] = { kind = "armor", slot = cat, armor_type = type_name }
                end
            end
        end
    end
    for type_name, slot in pairs(AI_NPC_ARMOR_TYPE_SLOT_FALLBACK) do
        if not AI_NPC_ARMOR_NAME_TO_INFO[type_name] then
            AI_NPC_ARMOR_NAME_TO_INFO[type_name] = { kind = "armor", slot = slot, armor_type = type_name }
        end
    end
    for name, info in pairs(AI_NPC_ARMOR_NAME_TO_INFO) do
        table.insert(AI_NPC_ARMOR_NAMES_SORTED, { name = name, info = info })
    end
    table.sort(AI_NPC_ARMOR_NAMES_SORTED, function(a, b) return #a.name > #b.name end)
end

local function ai_npc_item_armor_info_from_clothing(clothing)
    if not clothing or clothing == "" then return nil end
    if not AI_NPC_ARMOR_NAMES_SORTED then ai_npc_item_build_armor_map() end
    for _, entry in ipairs(AI_NPC_ARMOR_NAMES_SORTED or {}) do
        if clothing:sub(1, #entry.name) == entry.name then return entry.info end
    end
    return nil
end

local function ai_npc_item_register_info(id, info)
    if not id or id == "" or type(info) ~= "table" then return end
    AI_NPC_ITEM_CLASS_INFO[id:lower()] = info
end

local function ai_npc_item_parse_file(text)
    if not text then return end
    for tc in text:gmatch("<MeleeWeapon%s+([^<>]-)%s*/>") do
        local a = ai_npc_parse_attrs(tc)
        local weapon_type = AI_NPC_WEAPON_CLASS_NAMES[tonumber(a.Class)]
        if a.Id then ai_npc_item_register_info(a.Id, { kind = "weapon", weapon_type = weapon_type or "melee" }) end
    end
    for tc in text:gmatch("<MissileWeapon%s+([^<>]-)%s*/>") do
        local a = ai_npc_parse_attrs(tc)
        local weapon_type = AI_NPC_WEAPON_CLASS_NAMES[tonumber(a.Class)]
        if a.Id then ai_npc_item_register_info(a.Id, { kind = "weapon", weapon_type = weapon_type or "missile" }) end
    end
    for tc in text:gmatch("<Helmet%s+([^<>]-)%s*/>") do
        local a = ai_npc_parse_attrs(tc)
        if a.Id then ai_npc_item_register_info(a.Id, { kind = "armor", slot = "head", armor_type = "Helmet" }) end
    end
    for tc in text:gmatch("<Hood%s+([^<>]-)%s*/>") do
        local a = ai_npc_parse_attrs(tc)
        if a.Id then ai_npc_item_register_info(a.Id, { kind = "armor", slot = "head", armor_type = "Hood" }) end
    end
    for tc in text:gmatch("<Armor%s+([^<>]-)%s*/>") do
        local a = ai_npc_parse_attrs(tc)
        local info = ai_npc_item_armor_info_from_clothing(a.Clothing or "")
        if a.Id and info then
            ai_npc_item_register_info(a.Id, { kind = "armor", slot = info.slot, armor_type = info.armor_type or info.name })
        end
    end
    for tc in text:gmatch("<ItemAlias%s+([^<>]-)%s*/>") do
        local a = ai_npc_parse_attrs(tc)
        if a.Id and a.SourceItemId then AI_NPC_ITEM_ALIASES[a.Id:lower()] = a.SourceItemId:lower() end
    end
end

local function ai_npc_item_ensure_maps()
    if AI_NPC_ITEM_CLASS_INFO then return end
    AI_NPC_ITEM_CLASS_INFO = {}
    AI_NPC_ITEM_ALIASES = {}
    ai_npc_item_build_armor_map()
    ai_npc_item_parse_file(ai_npc_item_load_text("libs/tables/item/item.xml"))
    if System and type(System.ScanDirectory) == "function" then
        local scan_flag = rawget(_G, "SCANDIR_FILES") or 0
        local ok, files = pcall(function() return System.ScanDirectory("libs/tables/item/", scan_flag) end)
        if ok and type(files) == "table" then
            for _, file in ipairs(files) do
                local name = tostring(file or "")
                if name:sub(1, 6) == "item__" and name:sub(-4) == ".xml" and name ~= "item__deprecated.xml" and name ~= "item__reward.xml" then
                    ai_npc_item_parse_file(ai_npc_item_load_text("libs/tables/item/" .. name))
                end
            end
        end
    end
    for alias, src in pairs(AI_NPC_ITEM_ALIASES) do
        if AI_NPC_ITEM_CLASS_INFO[src] and not AI_NPC_ITEM_CLASS_INFO[alias] then
            AI_NPC_ITEM_CLASS_INFO[alias] = AI_NPC_ITEM_CLASS_INFO[src]
        end
    end
    local count = 0
    for _ in pairs(AI_NPC_ITEM_CLASS_INFO) do count = count + 1 end
    System.LogAlways("[AI NPC] DIAG item_classifier loaded classes=" .. tostring(count))
end

ai_npc_item_class_info = function(class_id)
    ai_npc_item_ensure_maps()
    return AI_NPC_ITEM_CLASS_INFO[tostring(class_id or ""):lower()]
end

function AI_NPC_TestInventoryDump()
    local ent = ai_npc_diag_target()
    if not ent then return end
    if type(ent.inventory) ~= "table" then
        System.LogAlways("[AI NPC] DIAG inv_dump unavailable: inventory=" .. type(ent.inventory))
        return
    end
    if type(ent.inventory.Dump) == "function" then
        local ok_dump, result_dump = pcall(function() return ent.inventory:Dump() end)
        System.LogAlways("[AI NPC] DIAG inv_dump Dump ok=" .. tostring(ok_dump) .. " result=" .. tostring(result_dump))
    end
    if type(ent.inventory.GetInventoryTable) ~= "function" then
        System.LogAlways("[AI NPC] DIAG inv_dump GetInventoryTable missing")
        return
    end
    local ok, inv_table = pcall(function() return ent.inventory:GetInventoryTable() end)
    System.LogAlways("[AI NPC] DIAG inv_dump GetInventoryTable ok=" .. tostring(ok) .. " type=" .. type(inv_table))
    if not ok or type(inv_table) ~= "table" then return end
    local count = 0
    for k, v in pairs(inv_table) do
        count = count + 1
        if count > 80 then
            System.LogAlways("[AI NPC] DIAG inv_dump truncated at 80 rows")
            break
        end
        if type(v) == "table" then
            local parts = {}
            local inner = 0
            for kk, vv in pairs(v) do
                inner = inner + 1
                if inner > 16 then
                    table.insert(parts, "...")
                    break
                end
                table.insert(parts, tostring(kk) .. "=" .. tostring(vv))
            end
            table.sort(parts)
            System.LogAlways("[AI NPC] DIAG inv_dump [" .. tostring(k) .. "] table {" .. table.concat(parts, ", ") .. "}")
        else
            System.LogAlways("[AI NPC] DIAG inv_dump [" .. tostring(k) .. "] " .. type(v) .. "=" .. tostring(v))
        end
    end
    System.LogAlways("[AI NPC] DIAG inv_dump rows=" .. tostring(count))
end

function AI_NPC_TestInventoryItems()
    local ent = ai_npc_diag_target()
    if not ent then return end
    if type(ent.inventory) ~= "table" or type(ent.inventory.GetInventoryTable) ~= "function" then
        System.LogAlways("[AI NPC] DIAG inv_items unavailable: inventory/GetInventoryTable missing")
        return
    end
    local ok, inv_table = pcall(function() return ent.inventory:GetInventoryTable() end)
    System.LogAlways("[AI NPC] DIAG inv_items GetInventoryTable ok=" .. tostring(ok) .. " type=" .. type(inv_table))
    if not ok or type(inv_table) ~= "table" then return end
    local has_item_manager = ItemManager and type(ItemManager.GetItem) == "function"
    System.LogAlways("[AI NPC] DIAG inv_items ItemManager.GetItem=" .. tostring(has_item_manager))
    local count = 0
    for k, handle in pairs(inv_table) do
        count = count + 1
        if count > 80 then
            System.LogAlways("[AI NPC] DIAG inv_items truncated at 80 rows")
            break
        end
        if has_item_manager then
            local ok_item, item = pcall(function() return ItemManager.GetItem(handle) end)
            if ok_item and type(item) == "table" then
                local parts = {}
                local inner = 0
                for kk, vv in pairs(item) do
                    inner = inner + 1
                    if inner > 24 then
                        table.insert(parts, "...")
                        break
                    end
                    table.insert(parts, tostring(kk) .. "=" .. tostring(vv))
                end
                table.sort(parts)
                local info = ai_npc_item_class_info(item.class)
                if info then
                    table.insert(parts, "kind=" .. tostring(info.kind or ""))
                    table.insert(parts, "slot=" .. tostring(info.slot or ""))
                    table.insert(parts, "weapon_type=" .. tostring(info.weapon_type or ""))
                    table.insert(parts, "armor_type=" .. tostring(info.armor_type or ""))
                    table.sort(parts)
                end
                System.LogAlways("[AI NPC] DIAG inv_items [" .. tostring(k) .. "] handle=" .. tostring(handle) .. " item {" .. table.concat(parts, ", ") .. "}")
            else
                System.LogAlways("[AI NPC] DIAG inv_items [" .. tostring(k) .. "] handle=" .. tostring(handle) .. " ok_item=" .. tostring(ok_item) .. " item=" .. tostring(item))
            end
        else
            System.LogAlways("[AI NPC] DIAG inv_items [" .. tostring(k) .. "] handle=" .. tostring(handle))
        end
    end
    System.LogAlways("[AI NPC] DIAG inv_items rows=" .. tostring(count))
end

function AI_NPC_TestUnequip(line)
    local arg = tostring(line or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local ent = ai_npc_diag_target()
    if not ent then return end
    if type(ent.actor) ~= "table" or type(ent.actor.UnequipInventoryItem) ~= "function" then
        System.LogAlways("[AI NPC] DIAG unequip unavailable: actor.UnequipInventoryItem missing")
        return
    end
    local item_id = arg
    if item_id == "" or item_id == "right" or item_id == "left" then
        if type(ent.human) ~= "table" or type(ent.human.GetItemInHand) ~= "function" then
            System.LogAlways("[AI NPC] DIAG unequip no item id and human.GetItemInHand missing")
            return
        end
        local hand = item_id ~= "" and item_id or "right"
        local ok_hand, hand_item = pcall(function() return ent.human:GetItemInHand(hand) end)
        System.LogAlways("[AI NPC] DIAG unequip hand=" .. hand .. " ok=" .. tostring(ok_hand) .. " item=" .. tostring(hand_item))
        if not ok_hand or not hand_item then return end
        item_id = hand_item
    end
    local ok, result = pcall(function() return ent.actor:UnequipInventoryItem(item_id) end)
    System.LogAlways("[AI NPC] DIAG unequip item=" .. tostring(item_id) .. " ok=" .. tostring(ok) .. " result=" .. tostring(result))
end

function AI_NPC_TestUnequipIndex(line)
    local idx_text = tostring(line or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local idx = tonumber(idx_text)
    if idx == nil then
        System.LogAlways("[AI NPC] DIAG unequip_index usage: ai_npc_test_unequip_index <number>")
        return
    end
    local ent = ai_npc_diag_target()
    if not ent then return end
    if type(ent.actor) ~= "table" or type(ent.actor.UnequipInventoryItem) ~= "function" then
        System.LogAlways("[AI NPC] DIAG unequip_index unavailable: actor.UnequipInventoryItem missing")
        return
    end
    if type(ent.inventory) ~= "table" or type(ent.inventory.GetInventoryTable) ~= "function" then
        System.LogAlways("[AI NPC] DIAG unequip_index unavailable: inventory/GetInventoryTable missing")
        return
    end
    local ok_table, inv_table = pcall(function() return ent.inventory:GetInventoryTable() end)
    if not ok_table or type(inv_table) ~= "table" then
        System.LogAlways("[AI NPC] DIAG unequip_index GetInventoryTable failed ok=" .. tostring(ok_table) .. " type=" .. type(inv_table))
        return
    end
    local handle = inv_table[idx]
    if not handle then
        System.LogAlways("[AI NPC] DIAG unequip_index no item at index=" .. tostring(idx))
        return
    end
    local class = ""
    if ItemManager and type(ItemManager.GetItem) == "function" then
        local ok_item, item = pcall(function() return ItemManager.GetItem(handle) end)
        if ok_item and type(item) == "table" then
            class = tostring(item.class or "")
        end
    end
    local ok, result = pcall(function() return ent.actor:UnequipInventoryItem(handle) end)
    System.LogAlways("[AI NPC] DIAG unequip_index index=" .. tostring(idx) .. " handle=" .. tostring(handle) .. " class=" .. class .. " ok=" .. tostring(ok) .. " result=" .. tostring(result))
end

function AI_NPC_TestUnequipSlot(line)
    local slot = tostring(line or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
    if slot == "" then
        System.LogAlways("[AI NPC] DIAG unequip_slot usage: ai_npc_test_unequip_slot <head|body|legs|feet|arms|neck>")
        return
    end
    local ent = ai_npc_diag_target()
    if not ent then return end
    if type(ent.actor) ~= "table" or type(ent.actor.UnequipInventoryItem) ~= "function" then
        System.LogAlways("[AI NPC] DIAG unequip_slot unavailable: actor.UnequipInventoryItem missing")
        return
    end
    if type(ent.inventory) ~= "table" or type(ent.inventory.GetInventoryTable) ~= "function" then
        System.LogAlways("[AI NPC] DIAG unequip_slot unavailable: inventory/GetInventoryTable missing")
        return
    end
    if not ItemManager or type(ItemManager.GetItem) ~= "function" then
        System.LogAlways("[AI NPC] DIAG unequip_slot unavailable: ItemManager.GetItem missing")
        return
    end
    local ok_table, inv_table = pcall(function() return ent.inventory:GetInventoryTable() end)
    if not ok_table or type(inv_table) ~= "table" then
        System.LogAlways("[AI NPC] DIAG unequip_slot GetInventoryTable failed ok=" .. tostring(ok_table) .. " type=" .. type(inv_table))
        return
    end
    local matches = {}
    for idx, handle in pairs(inv_table) do
        local ok_item, item = pcall(function() return ItemManager.GetItem(handle) end)
        if ok_item and type(item) == "table" then
            local info = ai_npc_item_class_info(item.class)
            if info and info.kind == "armor" and tostring(info.slot or "") == slot then
                table.insert(matches, { idx = idx, handle = handle, class = item.class, info = info })
            end
        end
    end
    table.sort(matches, function(a, b) return tostring(a.idx) < tostring(b.idx) end)
    if #matches == 0 then
        System.LogAlways("[AI NPC] DIAG unequip_slot slot=" .. slot .. " no matching armor item")
        return
    end
    for _, m in ipairs(matches) do
        local ok, result = pcall(function() return ent.actor:UnequipInventoryItem(m.handle) end)
        System.LogAlways("[AI NPC] DIAG unequip_slot slot=" .. slot .. " index=" .. tostring(m.idx) .. " class=" .. tostring(m.class) .. " armor_type=" .. tostring(m.info.armor_type or "") .. " ok=" .. tostring(ok) .. " result=" .. tostring(result))
    end
end

function AI_NPC_TestEquipSlot(line)
    local slot = tostring(line or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
    if slot == "" then
        System.LogAlways("[AI NPC] DIAG equip_slot usage: ai_npc_test_equip_slot <head|body|legs|feet|arms|neck>")
        return
    end
    local ent = ai_npc_diag_target()
    if not ent then return end
    if type(ent.actor) ~= "table" or type(ent.actor.EquipInventoryItem) ~= "function" then
        System.LogAlways("[AI NPC] DIAG equip_slot unavailable: actor.EquipInventoryItem missing")
        return
    end
    if type(ent.inventory) ~= "table" or type(ent.inventory.GetInventoryTable) ~= "function" then
        System.LogAlways("[AI NPC] DIAG equip_slot unavailable: inventory/GetInventoryTable missing")
        return
    end
    if not ItemManager or type(ItemManager.GetItem) ~= "function" then
        System.LogAlways("[AI NPC] DIAG equip_slot unavailable: ItemManager.GetItem missing")
        return
    end
    local ok_table, inv_table = pcall(function() return ent.inventory:GetInventoryTable() end)
    if not ok_table or type(inv_table) ~= "table" then
        System.LogAlways("[AI NPC] DIAG equip_slot GetInventoryTable failed ok=" .. tostring(ok_table) .. " type=" .. type(inv_table))
        return
    end
    local candidates = {}
    for idx, handle in pairs(inv_table) do
        local ok_item, item = pcall(function() return ItemManager.GetItem(handle) end)
        if ok_item and type(item) == "table" then
            local info = ai_npc_item_class_info(item.class)
            if info and tostring(info.slot or "") == slot then
                table.insert(candidates, { idx = idx, handle = handle, class = item.class })
            end
        end
    end
    table.sort(candidates, function(a, b) return tostring(a.idx) < tostring(b.idx) end)
    if #candidates == 0 then
        System.LogAlways("[AI NPC] DIAG equip_slot slot=" .. slot .. " no matching armor item")
        return
    end
    local chosen = candidates[1]
    local ok_eq, result = pcall(function() return ent.actor:EquipInventoryItem(chosen.handle) end)
    System.LogAlways("[AI NPC] DIAG equip_slot slot=" .. slot .. " index=" .. tostring(chosen.idx) .. " class=" .. tostring(chosen.class) .. " ok=" .. tostring(ok_eq) .. " result=" .. tostring(result))
end

function AI_NPC_TestEquipItem(line)
    local query = tostring(line or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
    if query == "" then
        System.LogAlways("[AI NPC] DIAG equip_item usage: ai_npc_test_equip_item <item_class_substring>")
        return
    end
    local ent = ai_npc_diag_target()
    if not ent then return end
    if type(ent.actor) ~= "table" or type(ent.actor.EquipInventoryItem) ~= "function" then
        System.LogAlways("[AI NPC] DIAG equip_item unavailable: actor.EquipInventoryItem missing")
        return
    end
    if type(ent.inventory) ~= "table" or type(ent.inventory.GetInventoryTable) ~= "function" then
        System.LogAlways("[AI NPC] DIAG equip_item unavailable: inventory/GetInventoryTable missing")
        return
    end
    if not ItemManager or type(ItemManager.GetItem) ~= "function" then
        System.LogAlways("[AI NPC] DIAG equip_item unavailable: ItemManager.GetItem missing")
        return
    end
    local ok_table, inv_table = pcall(function() return ent.inventory:GetInventoryTable() end)
    if not ok_table or type(inv_table) ~= "table" then
        System.LogAlways("[AI NPC] DIAG equip_item GetInventoryTable failed")
        return
    end
    local found = nil
    for idx, handle in pairs(inv_table) do
        local ok_item, item = pcall(function() return ItemManager.GetItem(handle) end)
        if ok_item and type(item) == "table" and type(item.class) == "string" then
            local class_lower = item.class:lower()
            if string.find(class_lower, query, 1, true) then
                found = { idx = idx, handle = handle, class = item.class }
                break
            end
        end
    end
    if not found then
        System.LogAlways("[AI NPC] DIAG equip_item query='" .. query .. "' not found in inventory")
        return
    end
    local ok_eq, result = pcall(function() return ent.actor:EquipInventoryItem(found.handle) end)
    System.LogAlways("[AI NPC] DIAG equip_item query='" .. query .. "' class=" .. tostring(found.class) .. " handle=" .. tostring(found.handle) .. " ok=" .. tostring(ok_eq) .. " result=" .. tostring(result))
end

--[[  -- GESTURE/SIT/STAND TESTS DISABLED
function AI_NPC_TestWave()
    local ent = ai_npc_diag_target()
    if not ent then return end
    local ok = scene_gesture_wave(ent) or scene_look_at_player(ent)
    System.LogAlways("[AI NPC] DIAG gesture_wave ok=" .. tostring(ok))
end

function AI_NPC_TestBow()
    local ent = ai_npc_diag_target()
    if not ent then return end
    local ok = scene_gesture_bow(ent) or scene_look_at_player(ent)
    System.LogAlways("[AI NPC] DIAG gesture_bow ok=" .. tostring(ok))
end

function AI_NPC_TestSit()
    local ent = ai_npc_diag_target()
    if not ent then return end
    local ok = scene_sit_down(ent)
    System.LogAlways("[AI NPC] DIAG sit_down ok=" .. tostring(ok))
end

function AI_NPC_TestStand()
    local ent = ai_npc_diag_target()
    if not ent then return end
    local ok = scene_stand_up(ent)
    System.LogAlways("[AI NPC] DIAG stand_up ok=" .. tostring(ok))
end
--]]

function AI_NPC_TestClothingPreset(line)
    local preset = tostring(line or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
    if preset == "" then preset = "light" end
    local presets = {
        light = "48691669-b94a-0e6a-d9db-0a70a0ca1fad",
        medium = "4fd62c5f-ff3a-8d50-3857-a66724c99d91",
        heavy = "4036a7d4-06fd-4f1f-c75e-c62ace5aa2a8",
        dress = "4036a7d4-06fd-4f1f-c75e-c62ace5aa2a8",
        dressed = "4036a7d4-06fd-4f1f-c75e-c62ace5aa2a8",
        normal = "4036a7d4-06fd-4f1f-c75e-c62ace5aa2a8",
        male = "4036a7d4-06fd-4f1f-c75e-c62ace5aa2a8",
    }
    local guid = presets[preset] or preset
    local ent = ai_npc_diag_target()
    if not ent then return end
    if type(ent.actor) ~= "table" or type(ent.actor.EquipClothingPreset) ~= "function" then
        System.LogAlways("[AI NPC] DIAG clothing_preset unavailable: actor.EquipClothingPreset missing")
        return
    end
    local ok, result = pcall(function() return ent.actor:EquipClothingPreset(guid) end)
    System.LogAlways("[AI NPC] DIAG clothing_preset preset=" .. tostring(preset) .. " guid=" .. tostring(guid) .. " ok=" .. tostring(ok) .. " result=" .. tostring(result))
end

function AI_NPC_TestDressUp()
    local ent = ai_npc_diag_target()
    if not ent then return end
    local ok = scene_dress_up(ent)
    System.LogAlways("[AI NPC] DIAG dress_up ok=" .. tostring(ok))
end

--[[  -- INTERMEDIATE STRIP DISABLED
function AI_NPC_TestPartialStrip()
    local ent = ai_npc_diag_target()
    if not ent then return end
    local ok = scene_partial_strip(ent)
    System.LogAlways("[AI NPC] DIAG partial_strip ok=" .. tostring(ok))
end

function AI_NPC_TestFullStrip()
    local ent = ai_npc_diag_target()
    if not ent then return end
    local ok = scene_full_strip(ent)
    System.LogAlways("[AI NPC] DIAG full_strip ok=" .. tostring(ok))
end

function AI_NPC_TestDressPartial()
    local ent = ai_npc_diag_target()
    if not ent then return end
    local ok = false
    -- Try equipping body+legs from inventory first
    ok = scene_equip_first_in_slot(ent, "body") or ok
    ok = scene_equip_first_in_slot(ent, "legs") or ok
    if not ok then
        ok = scene_dress_up(ent) or ok
    end
    System.LogAlways("[AI NPC] DIAG dress_partial ok=" .. tostring(ok))
end

function AI_NPC_TestDressFull()
    local ent = ai_npc_diag_target()
    if not ent then return end
    local ok = scene_dress_up(ent)
    System.LogAlways("[AI NPC] DIAG dress_full ok=" .. tostring(ok))
end
--]]

function AI_NPC_TestClothingReset()
    local ent = ai_npc_diag_target()
    if not ent then return end
    if type(ent.actor) ~= "table" or type(ent.actor.EquipClothingPreset) ~= "function" then
        System.LogAlways("[AI NPC] DIAG clothing_reset unavailable: actor.EquipClothingPreset missing")
        return
    end
    local presets = {
        { name = "heavy", guid = "4036a7d4-06fd-4f1f-c75e-c62ace5aa2a8" },
        { name = "medium", guid = "4fd62c5f-ff3a-8d50-3857-a66724c99d91" },
        { name = "light", guid = "48691669-b94a-0e6a-d9db-0a70a0ca1fad" },
    }
    local ok_any = false
    for _, preset in ipairs(presets) do
        local ok, result = pcall(function() return ent.actor:EquipClothingPreset(preset.guid) end)
        System.LogAlways("[AI NPC] DIAG clothing_reset preset=" .. tostring(preset.name) .. " guid=" .. tostring(preset.guid) .. " ok=" .. tostring(ok) .. " result=" .. tostring(result))
        ok_any = ok_any or ok
    end
    local ok_inventory = scene_equip_inventory_armor(ent)
    local ok_force = false
    local force_result = nil
    if type(ent.ForceCharacterUpdate) == "function" then
        ok_force, force_result = pcall(function() return ent:ForceCharacterUpdate(0, false) end)
    end
    System.LogAlways("[AI NPC] DIAG clothing_reset ok_any=" .. tostring(ok_any) .. " inventory=" .. tostring(ok_inventory) .. " force_update=" .. tostring(ok_force) .. " result=" .. tostring(force_result))
end

local function ai_npc_get_initial_clothing_preset(ent)
    if not ent then return nil, false, nil, nil end
    if type(ent.actor) == "table" and type(ent.actor.GetInitialClothingPreset) == "function" then
        local ok, result = pcall(function() return ent.actor:GetInitialClothingPreset() end)
        if ok and result and tostring(result) ~= "" then return tostring(result), true, "actor", result end
        ok, result = pcall(function() return ent.actor.GetInitialClothingPreset(ent.actor) end)
        if ok and result and tostring(result) ~= "" then return tostring(result), true, "actor_dot", result end
    end
    if type(ent.human) == "table" and type(ent.human.GetInitialClothingPreset) == "function" then
        local ok, result = pcall(function() return ent.human:GetInitialClothingPreset() end)
        if ok and result and tostring(result) ~= "" then return tostring(result), true, "human", result end
        ok, result = pcall(function() return ent.human.GetInitialClothingPreset(ent.human) end)
        if ok and result and tostring(result) ~= "" then return tostring(result), true, "human_dot", result end
    end
    return nil, false, nil, nil
end

function AI_NPC_TestInitialClothing()
    local ent = ai_npc_diag_target()
    if not ent then return end
    local guid, ok, source, raw = ai_npc_get_initial_clothing_preset(ent)
    System.LogAlways("[AI NPC] DIAG initial_clothing methods actor=" .. tostring(type(ent.actor) == "table" and type(ent.actor.GetInitialClothingPreset) or "nil") .. " human=" .. tostring(type(ent.human) == "table" and type(ent.human.GetInitialClothingPreset) or "nil") .. " actor_equip=" .. tostring(type(ent.actor) == "table" and type(ent.actor.EquipClothingPreset) or "nil") .. " human_equip=" .. tostring(type(ent.human) == "table" and type(ent.human.EquipClothingPreset) or "nil"))
    if type(ent.actor) == "table" and type(ent.actor.GetInitialClothingPreset) == "function" then
        local ok_actor, result_actor = pcall(function() return ent.actor:GetInitialClothingPreset() end)
        System.LogAlways("[AI NPC] DIAG initial_clothing actor_call ok=" .. tostring(ok_actor) .. " result=" .. tostring(result_actor))
    end
    if type(ent.human) == "table" and type(ent.human.GetInitialClothingPreset) == "function" then
        local ok_human, result_human = pcall(function() return ent.human:GetInitialClothingPreset() end)
        System.LogAlways("[AI NPC] DIAG initial_clothing human_call ok=" .. tostring(ok_human) .. " result=" .. tostring(result_human))
    end
    System.LogAlways("[AI NPC] DIAG initial_clothing ok=" .. tostring(ok) .. " source=" .. tostring(source) .. " guid=" .. tostring(guid) .. " raw=" .. tostring(raw))
end

function AI_NPC_TestClothingRestoreInitial()
    local ent = ai_npc_diag_target()
    if not ent then return end
    local guid, ok_initial, source = ai_npc_get_initial_clothing_preset(ent)
    if not ok_initial or not guid then
        System.LogAlways("[AI NPC] DIAG clothing_restore_initial no initial preset source=" .. tostring(source) .. " guid=" .. tostring(guid))
        return
    end
    local ok_actor = false
    local result_actor = nil
    if type(ent.actor) == "table" and type(ent.actor.EquipClothingPreset) == "function" then
        ok_actor, result_actor = pcall(function() return ent.actor:EquipClothingPreset(guid) end)
    end
    local ok_human_policy = false
    local result_human_policy = nil
    if type(ent.human) == "table" and type(ent.human.EquipClothingPreset) == "function" then
        ok_human_policy, result_human_policy = pcall(function() return ent.human:EquipClothingPreset(guid, 1) end)
    end
    local ok_inventory = scene_equip_inventory_armor(ent)
    local ok_force = false
    local force_result = nil
    if type(ent.ForceCharacterUpdate) == "function" then
        ok_force, force_result = pcall(function() return ent:ForceCharacterUpdate(0, false) end)
    end
    System.LogAlways("[AI NPC] DIAG clothing_restore_initial source=" .. tostring(source) .. " guid=" .. tostring(guid) .. " actor=" .. tostring(ok_actor) .. "/" .. tostring(result_actor) .. " human_policy=" .. tostring(ok_human_policy) .. "/" .. tostring(result_human_policy) .. " inventory=" .. tostring(ok_inventory) .. " force_update=" .. tostring(ok_force) .. "/" .. tostring(force_result))
end

local AI_NPC_CLOTHING_CYCLE_PRESETS = {
    { name = "heavy", guid = "4036a7d4-06fd-4f1f-c75e-c62ace5aa2a8" },
    { name = "medium", guid = "4fd62c5f-ff3a-8d50-3857-a66724c99d91" },
    { name = "light", guid = "48691669-b94a-0e6a-d9db-0a70a0ca1fad" },
    { name = "docs_example", guid = "46ea38bb-0be7-ca10-a8ac-d526056c04b3" },
    { name = "labourer_01", guid = "f8e28d52-f9b0-406d-b72c-12fe058a6aa9" },
    { name = "labourer_02", guid = "449db968-03c7-43ef-8fa4-6ccab7aa9a48" },
    { name = "labourer_03", guid = "a75923bd-3a44-4747-8632-71c54a0505b6" },
    { name = "labourer_04", guid = "3d1e9130-42e0-4a43-a005-ba9db2c939bd" },
    { name = "labourer_05", guid = "3c047c94-255e-46b4-bbc1-4ba85c987e50" },
    { name = "villager_01", guid = "ecf4eea7-ffe5-4a98-a351-8947eeabe5bd" },
    { name = "villager_02", guid = "24e4aa5b-cd2c-4dba-9426-b63e674b7037" },
    { name = "villager_03", guid = "c522ba8f-18ff-4274-8acb-d7d0f50d0365" },
    { name = "villager_04", guid = "cbc20d2b-3fff-4147-a650-92a8dcaf9875" },
    { name = "villager_05", guid = "fd456ed6-f39e-4dad-8c53-e818c9789562" },
    { name = "miller_01_poor", guid = "fde58768-1b0f-4232-bc7d-55456e8fa3b5" },
    { name = "miner_01", guid = "95edcf9d-7199-4778-9751-bd0d8f4d2069" },
    { name = "nomad_01", guid = "c4251e9e-6cf5-4b06-aa9a-7cb8b2b85b58" },
    { name = "f_bathmaid_01", guid = "298386c4-69d9-42de-9e1f-f294039372e5" },
    { name = "f_bathmaid_02", guid = "dd915fff-4d37-4362-a4b9-945db98e4bd3" },
    { name = "f_bathmaid_03", guid = "0e81d83d-f27f-4384-bb88-75d4a32e67d9" },
    { name = "f_bathmaid_04", guid = "405614af-a376-486e-bc0d-1e1c89e3f8f4" },
    { name = "f_bathmaid_05", guid = "c5a7de75-5a64-4cbd-ab28-91474059e33c" },
    { name = "f_villager_02", guid = "0c6985bb-a767-441d-a95f-90f988ea3b0d" },
    { name = "f_villager_05", guid = "48b428e7-24b9-4e36-b784-08ff77a487fa" },
    { name = "f_villager_08", guid = "08fd88a1-0f0e-4de2-8ba9-c4689ebc29a5" },
    { name = "f_villager_09", guid = "2362b15e-b67f-4956-b962-4f35de309bc4" },
    { name = "f_villager_12", guid = "3b3476fc-5026-4982-bc2f-99569613c90f" },
    { name = "female_default", guid = "45db15cb-246a-a3c8-7dc0-f99af7be1399" },
}

local AI_NPC_CLOTHING_CYCLE_INDEX = 0

function AI_NPC_TestClothingCycle(line)
    local arg = tostring(line or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
    if arg == "reset" then
        AI_NPC_CLOTHING_CYCLE_INDEX = 0
        System.LogAlways("[AI NPC] DIAG clothing_cycle reset count=" .. tostring(#AI_NPC_CLOTHING_CYCLE_PRESETS))
        return
    end
    local idx = tonumber(arg)
    if idx == nil then
        AI_NPC_CLOTHING_CYCLE_INDEX = AI_NPC_CLOTHING_CYCLE_INDEX + 1
        if AI_NPC_CLOTHING_CYCLE_INDEX > #AI_NPC_CLOTHING_CYCLE_PRESETS then AI_NPC_CLOTHING_CYCLE_INDEX = 1 end
        idx = AI_NPC_CLOTHING_CYCLE_INDEX
    else
        AI_NPC_CLOTHING_CYCLE_INDEX = idx
    end
    local preset = AI_NPC_CLOTHING_CYCLE_PRESETS[idx]
    if not preset then
        System.LogAlways("[AI NPC] DIAG clothing_cycle no preset index=" .. tostring(idx) .. " count=" .. tostring(#AI_NPC_CLOTHING_CYCLE_PRESETS))
        return
    end
    local ent = ai_npc_diag_target()
    if not ent then return end
    if type(ent.actor) ~= "table" or type(ent.actor.EquipClothingPreset) ~= "function" then
        System.LogAlways("[AI NPC] DIAG clothing_cycle unavailable: actor.EquipClothingPreset missing")
        return
    end
    local ok, result = pcall(function() return ent.actor:EquipClothingPreset(preset.guid) end)
    local ok_force = false
    local force_result = nil
    if type(ent.ForceCharacterUpdate) == "function" then
        ok_force, force_result = pcall(function() return ent:ForceCharacterUpdate(0, false) end)
    end
    System.LogAlways("[AI NPC] DIAG clothing_cycle index=" .. tostring(idx) .. "/" .. tostring(#AI_NPC_CLOTHING_CYCLE_PRESETS) .. " name=" .. tostring(preset.name) .. " guid=" .. tostring(preset.guid) .. " ok=" .. tostring(ok) .. " result=" .. tostring(result) .. " force_update=" .. tostring(ok_force) .. "/" .. tostring(force_result))
end

function AI_NPC_TestCheatClothes()
    local ent = ai_npc_diag_target()
    if not ent then return end
    if type(ent.actor) ~= "table" or type(ent.actor.EquipInventoryItem) ~= "function" then
        System.LogAlways("[AI NPC] DIAG cheat_clothes unavailable: actor.EquipInventoryItem missing")
        return
    end
    local add_item_type = "nil"
    if ent.inventory then
        local ok_type, value = pcall(function() return type(ent.inventory.AddItem) end)
        add_item_type = ok_type and tostring(value) or ("err:" .. tostring(value))
    end
    local inv_create_type = "nil"
    if ent.inventory then
        local ok_type, value = pcall(function() return type(ent.inventory.CreateItem) end)
        inv_create_type = ok_type and tostring(value) or ("err:" .. tostring(value))
    end
    System.LogAlways("[AI NPC] DIAG cheat_clothes types actor=" .. tostring(type(ent.actor)) .. " inventory=" .. tostring(type(ent.inventory)) .. " AddItem=" .. add_item_type .. " InventoryCreateItem=" .. inv_create_type .. " ItemManager=" .. tostring(type(ItemManager)) .. " CreateItem=" .. tostring(ItemManager and type(ItemManager.CreateItem)))
    local guids = {
        "4d29d49a-e6d1-d0a0-47b7-3fac105c23b5",
        "407f6f52-d70e-7e3b-056d-cda8069aab86",
        "43f19e40-1107-38aa-a226-5d6179e9b4a3",
        "4e8bfdae-a38a-fae5-1177-b513733f1c90",
        "4249522f-a1db-7d3e-020f-237390c80ba2",
    }
    local equipped = 0
    for _, guid in ipairs(guids) do
        local item = nil
        if ItemUtils and type(ItemUtils.CreateInvItem) == "function" then
            local ok_create, created = pcall(function() return ItemUtils.CreateInvItem(ent, guid) end)
            System.LogAlways("[AI NPC] DIAG cheat_clothes ItemUtils guid=" .. tostring(guid) .. " ok=" .. tostring(ok_create) .. " item=" .. tostring(created))
            if ok_create and created then item = created end
        end
        if not item and ItemManager and type(ItemManager.CreateItem) == "function" and ent.inventory then
            local ok_create, created = pcall(function() return ItemManager.CreateItem(guid, 1, 1) end)
            System.LogAlways("[AI NPC] DIAG cheat_clothes ItemManager guid=" .. tostring(guid) .. " ok=" .. tostring(ok_create) .. " item=" .. tostring(created))
            if ok_create and created then
                local ok_add, added = pcall(function() return ent.inventory:AddItem(created) end)
                System.LogAlways("[AI NPC] DIAG cheat_clothes AddItem guid=" .. tostring(guid) .. " ok=" .. tostring(ok_add) .. " item=" .. tostring(added))
                item = ok_add and added or created
            end
        end
        if not item and ent.inventory then
            local ok_create, created = pcall(function() return ent.inventory:CreateItem(guid, 1, 1) end)
            System.LogAlways("[AI NPC] DIAG cheat_clothes InventoryCreateItem guid=" .. tostring(guid) .. " ok=" .. tostring(ok_create) .. " item=" .. tostring(created))
            if ok_create and created then item = created end
        end
        if item then
            local ok_equip, result = pcall(function() return ent.actor:EquipInventoryItem(item) end)
            System.LogAlways("[AI NPC] DIAG cheat_clothes Equip guid=" .. tostring(guid) .. " item=" .. tostring(item) .. " ok=" .. tostring(ok_equip) .. " result=" .. tostring(result))
            if ok_equip then equipped = equipped + 1 end
        end
    end
    System.LogAlways("[AI NPC] DIAG cheat_clothes equipped=" .. tostring(equipped))
end

function AI_NPC_TestGoalBack()
    System.LogAlways("[AI NPC] DIAG goal_back disabled: AI refpoint/SelectPipe crashed the game in testing")
end

-- ============================================================================
-- KCD2ModLoader / CryEngine integration
-- ============================================================================

-- Use CryEngine console commands for key binding
if System and System.AddCCommand then
    local ok_chat = pcall(System.AddCCommand, "ai_chat", "AI_NPC_Toggle()", "Toggle AI NPC chat window")
    local ok_say = pcall(System.AddCCommand, "ai_say", "AI_NPC_SayFromConsole(%line)", "Send message to active AI NPC")
    local ok_end = pcall(System.AddCCommand, "ai_end", "AI_NPC_End()", "End active AI NPC chat")
    local ok_sync_bind = pcall(System.AddCCommand, "ai_sync_bind", "AI_NPC_SyncBind()", "Sync key binds from in-game action map")
    local ok_probe = pcall(System.AddCCommand, "ai_probe_ui", "AI_NPC_ProbeUIInput()", "Probe native HUD/Menu input methods")
    local ok_probe_alias = pcall(System.AddCCommand, "aiprobe", "AI_NPC_ProbeUIInput()", "Probe native HUD/Menu input methods")
    local ok_target_debug = pcall(System.AddCCommand, "ai_target_debug", "AI_NPC_TargetDebug()", "Debug targeted entity resolution")
    local ok_poll_resp = pcall(System.AddCCommand, "ai_poll_resp", "AI_NPC_PollRespNow()", "Force read+exec of resp.lua")
    local ok_diag_signal = pcall(System.AddCCommand, "ai_npc_test_signal", "AI_NPC_TestSignal(%line)", "Test AI.Signal on targeted NPC")
    local ok_diag_xgen = pcall(System.AddCCommand, "ai_npc_test_xgen_msg", "AI_NPC_TestXGenMsg(%line)", "Test XGenAIModule.SendMessageToEntity on targeted NPC")
    local ok_diag_xgen_data = pcall(System.AddCCommand, "ai_npc_test_xgen_data", "AI_NPC_TestXGenData(%line)", "Test XGenAIModule.SendMessageToEntityData on targeted NPC")
    local ok_diag_game_event = pcall(System.AddCCommand, "ai_npc_test_game_event", "AI_NPC_TestGameEvent(%line)", "Test Game.SendEventToGameObject on targeted NPC")
    local ok_diag_audio_trigger = pcall(System.AddCCommand, "ai_npc_test_audio_trigger", "AI_NPC_TestAudioTrigger(%line)", "Test ExecuteAudioTrigger on targeted NPC")
    local ok_diag_audio_methods = pcall(System.AddCCommand, "ai_npc_test_audio_methods", "AI_NPC_TestAudioMethods()", "Dump audio methods for targeted NPC")
    local ok_engine_tts_load = pcall(System.AddCCommand, "ai_npc_engine_tts_load_bank", "AI_NPC_TestEngineTTSLoadBank(%line)", "Load AI NPC TTS FMOD bank through ROM")
    local ok_engine_tts_play = pcall(System.AddCCommand, "ai_npc_engine_tts_play", "AI_NPC_TestEngineTTSPlay(%line)", "Play AI NPC TTS trigger on targeted NPC")
    local ok_engine_tts_file = pcall(System.AddCCommand, "ai_npc_engine_play_file_3d", "AI_NPC_TestEnginePlayFile3D(%line)", "Play wav file at targeted NPC position through ROM FMOD bridge")
    local ok_diag_anim = pcall(System.AddCCommand, "ai_npc_test_anim", "AI_NPC_TestAnim(%line)", "Test human:PlayAnim on targeted NPC")
    local ok_diag_queue_anim = pcall(System.AddCCommand, "ai_npc_test_queue_anim", "AI_NPC_TestQueueAnim(%line)", "Test actor:QueueAnimationState on targeted NPC")
    local ok_diag_get_anim_state = pcall(System.AddCCommand, "ai_npc_test_get_anim_state", "AI_NPC_TestGetAnimState()", "Test actor:GetCurrentAnimationState on targeted NPC")
    local ok_diag_start_anim = pcall(System.AddCCommand, "ai_npc_test_start_anim", "AI_NPC_TestStartAnim(%line)", "Test entity:StartAnimation on targeted NPC")
    local ok_diag_iact = pcall(System.AddCCommand, "ai_npc_test_iact", "AI_NPC_TestIAct(%line)", "Test actor:StartInteractiveActionByName on targeted NPC")
    local ok_diag_simact = pcall(System.AddCCommand, "ai_npc_test_simact", "AI_NPC_TestSimAct(%line)", "Test actor:SimulateOnAction on targeted NPC")
    local ok_diag_goal = pcall(System.AddCCommand, "ai_npc_test_goal_back", "AI_NPC_TestGoalBack()", "Test AI refpoint/goto_point step back on targeted NPC")
    local ok_diag_look = pcall(System.AddCCommand, "ai_npc_test_look", "AI_NPC_TestLook()", "Test look-at methods on targeted NPC")
    local ok_diag_dialog = pcall(System.AddCCommand, "ai_npc_test_dialog_state", "AI_NPC_TestDialogState(%line)", "Test actor:SetDialogAnimationState on targeted NPC")
    local ok_diag_iact2 = pcall(System.AddCCommand, "ai_npc_test_iact2", "AI_NPC_TestIAct2(%line)", "Test extended StartInteractiveActionByName on targeted NPC")
-- GESTURE/SIT/STAND COMMANDS DISABLED
--    local ok_diag_wave = pcall(System.AddCCommand, "ai_npc_test_wave", "AI_NPC_TestWave()", "Test gesture wave on targeted NPC")
--    local ok_diag_bow = pcall(System.AddCCommand, "ai_npc_test_bow", "AI_NPC_TestBow()", "Test gesture bow on targeted NPC")
--    local ok_diag_sit = pcall(System.AddCCommand, "ai_npc_test_sit", "AI_NPC_TestSit()", "Test sit down on targeted NPC")
--    local ok_diag_stand = pcall(System.AddCCommand, "ai_npc_test_stand", "AI_NPC_TestStand()", "Test stand up on targeted NPC")
    local ok_diag_methods = pcall(System.AddCCommand, "ai_npc_test_methods", "AI_NPC_TestMethods()", "Dump actor/human methods for targeted NPC")
    local ok_diag_weapon = pcall(System.AddCCommand, "ai_npc_test_weapon", "AI_NPC_TestWeapon(%line)", "Test weapon draw/holster/toggle on targeted NPC")
    local ok_diag_fall = pcall(System.AddCCommand, "ai_npc_test_fall", "AI_NPC_TestFall()", "Test actor:Fall on targeted NPC")
    local ok_diag_ragdoll = pcall(System.AddCCommand, "ai_npc_test_ragdoll", "AI_NPC_TestRagdoll()", "Test actor:RagDollize on targeted NPC")
    local ok_diag_inv_methods = pcall(System.AddCCommand, "ai_npc_test_inventory_methods", "AI_NPC_TestInventoryMethods()", "Dump inventory/soul methods for targeted NPC")
    local ok_diag_equipment_methods = pcall(System.AddCCommand, "ai_npc_test_equipment_methods", "AI_NPC_TestEquipmentMethods()", "Dump equipment/outfit/clothing methods for targeted NPC")
    local ok_diag_appearance_props = pcall(System.AddCCommand, "ai_npc_test_appearance_props", "AI_NPC_TestAppearanceProps()", "Dump appearance/model/clothing properties for targeted NPC")
    local ok_diag_refresh_model = pcall(System.AddCCommand, "ai_npc_test_refresh_model", "AI_NPC_TestRefreshModel(%line)", "Test ForceCharacterUpdate/SetActorModel refresh on targeted NPC")
    local ok_diag_inv_dump = pcall(System.AddCCommand, "ai_npc_test_inventory_dump", "AI_NPC_TestInventoryDump()", "Dump inventory table for targeted NPC")
    local ok_diag_inv_items = pcall(System.AddCCommand, "ai_npc_test_inventory_items", "AI_NPC_TestInventoryItems()", "Dump ItemManager data for targeted NPC inventory")
    local ok_diag_unequip = pcall(System.AddCCommand, "ai_npc_test_unequip", "AI_NPC_TestUnequip(%line)", "Test actor:UnequipInventoryItem on targeted NPC")
    local ok_diag_unequip_index = pcall(System.AddCCommand, "ai_npc_test_unequip_index", "AI_NPC_TestUnequipIndex(%line)", "Test actor:UnequipInventoryItem by inventory index")
    local ok_diag_unequip_slot = pcall(System.AddCCommand, "ai_npc_test_unequip_slot", "AI_NPC_TestUnequipSlot(%line)", "Test actor:UnequipInventoryItem by classified armor slot")
    local ok_diag_equip_slot = pcall(System.AddCCommand, "ai_npc_test_equip_slot", "AI_NPC_TestEquipSlot(%line)", "Test actor:EquipInventoryItem by classified armor slot")
    local ok_diag_equip_item = pcall(System.AddCCommand, "ai_npc_test_equip_item", "AI_NPC_TestEquipItem(%line)", "Test actor:EquipInventoryItem by item class substring")
    local ok_diag_clothing_preset = pcall(System.AddCCommand, "ai_npc_test_clothing_preset", "AI_NPC_TestClothingPreset(%line)", "Test actor:EquipClothingPreset on targeted NPC")
    local ok_diag_dress_up = pcall(System.AddCCommand, "ai_npc_test_dress_up", "AI_NPC_TestDressUp()", "Test actor:EquipClothingPreset dress/normal on targeted NPC")
-- INTERMEDIATE STRIP DISABLED (console commands commented out)
--    local ok_diag_partial_strip = pcall(System.AddCCommand, "ai_npc_test_partial_strip", "AI_NPC_TestPartialStrip()", "Test partial strip (upper clothes only) on targeted NPC")
--    local ok_diag_full_strip = pcall(System.AddCCommand, "ai_npc_test_full_strip", "AI_NPC_TestFullStrip()", "Test full strip (all clothes) on targeted NPC")
--    local ok_diag_dress_partial = pcall(System.AddCCommand, "ai_npc_test_dress_partial", "AI_NPC_TestDressPartial()", "Test partial dress (underwear/lower clothes) on targeted NPC")
--    local ok_diag_dress_full = pcall(System.AddCCommand, "ai_npc_test_dress_full", "AI_NPC_TestDressFull()", "Test full dress (complete outfit) on targeted NPC")
    local ok_diag_clothing_reset = pcall(System.AddCCommand, "ai_npc_test_clothing_reset", "AI_NPC_TestClothingReset()", "Try known clothing presets and safe inventory refresh on targeted NPC")
    local ok_diag_initial_clothing = pcall(System.AddCCommand, "ai_npc_test_initial_clothing", "AI_NPC_TestInitialClothing()", "Dump actor:GetInitialClothingPreset for targeted NPC")
    local ok_diag_restore_initial = pcall(System.AddCCommand, "ai_npc_test_clothing_restore_initial", "AI_NPC_TestClothingRestoreInitial()", "Restore targeted NPC initial clothing preset")
    local ok_diag_clothing_cycle = pcall(System.AddCCommand, "ai_npc_test_clothing_cycle", "AI_NPC_TestClothingCycle(%line)", "Cycle known clothing preset GUID candidates on targeted NPC")
    local ok_diag_cheat_clothes = pcall(System.AddCCommand, "ai_npc_test_cheat_clothes", "AI_NPC_TestCheatClothes()", "Test cheat clothes EquipInventoryItem on targeted NPC")
    local ok_test_world_text = pcall(System.AddCCommand, "ai_test_world_text", "AI_NPC_TestWorldText(%line)", "Test world-space text above active NPC")
    System.LogAlways("[AI NPC] Register ai_chat: " .. tostring(ok_chat))
    System.LogAlways("[AI NPC] Register ai_say: " .. tostring(ok_say))
    System.LogAlways("[AI NPC] Register ai_end: " .. tostring(ok_end))
    System.LogAlways("[AI NPC] Register ai_sync_bind: " .. tostring(ok_sync_bind))
    System.LogAlways("[AI NPC] Register ai_probe_ui: " .. tostring(ok_probe))
    System.LogAlways("[AI NPC] Register aiprobe: " .. tostring(ok_probe_alias))
    System.LogAlways("[AI NPC] Register ai_target_debug: " .. tostring(ok_target_debug))
    System.LogAlways("[AI NPC] Register ai_poll_resp: " .. tostring(ok_poll_resp))
    System.LogAlways("[AI NPC] Register ai_npc_test_signal: " .. tostring(ok_diag_signal))
    System.LogAlways("[AI NPC] Register ai_npc_test_xgen_msg: " .. tostring(ok_diag_xgen))
    System.LogAlways("[AI NPC] Register ai_npc_test_xgen_data: " .. tostring(ok_diag_xgen_data))
    System.LogAlways("[AI NPC] Register ai_npc_test_game_event: " .. tostring(ok_diag_game_event))
    System.LogAlways("[AI NPC] Register ai_npc_test_audio_trigger: " .. tostring(ok_diag_audio_trigger))
    System.LogAlways("[AI NPC] Register ai_npc_test_audio_methods: " .. tostring(ok_diag_audio_methods))
    System.LogAlways("[AI NPC] Register ai_npc_engine_tts_load_bank: " .. tostring(ok_engine_tts_load))
    System.LogAlways("[AI NPC] Register ai_npc_engine_tts_play: " .. tostring(ok_engine_tts_play))
    System.LogAlways("[AI NPC] Register ai_npc_engine_play_file_3d: " .. tostring(ok_engine_tts_file))
    System.LogAlways("[AI NPC] Register ai_npc_test_anim: " .. tostring(ok_diag_anim))
    System.LogAlways("[AI NPC] Register ai_npc_test_queue_anim: " .. tostring(ok_diag_queue_anim))
    System.LogAlways("[AI NPC] Register ai_npc_test_get_anim_state: " .. tostring(ok_diag_get_anim_state))
    System.LogAlways("[AI NPC] Register ai_npc_test_start_anim: " .. tostring(ok_diag_start_anim))
    System.LogAlways("[AI NPC] Register ai_npc_test_iact: " .. tostring(ok_diag_iact))
    System.LogAlways("[AI NPC] Register ai_npc_test_simact: " .. tostring(ok_diag_simact))
    System.LogAlways("[AI NPC] Register ai_npc_test_goal_back: " .. tostring(ok_diag_goal))
    System.LogAlways("[AI NPC] Register ai_npc_test_look: " .. tostring(ok_diag_look))
    System.LogAlways("[AI NPC] Register ai_npc_test_dialog_state: " .. tostring(ok_diag_dialog))
    System.LogAlways("[AI NPC] Register ai_npc_test_iact2: " .. tostring(ok_diag_iact2))
-- GESTURE/SIT/STAND LOGS DISABLED
--    System.LogAlways("[AI NPC] Register ai_npc_test_wave: " .. tostring(ok_diag_wave))
--    System.LogAlways("[AI NPC] Register ai_npc_test_bow: " .. tostring(ok_diag_bow))
--    System.LogAlways("[AI NPC] Register ai_npc_test_sit: " .. tostring(ok_diag_sit))
--    System.LogAlways("[AI NPC] Register ai_npc_test_stand: " .. tostring(ok_diag_stand))
    System.LogAlways("[AI NPC] Register ai_npc_test_methods: " .. tostring(ok_diag_methods))
    System.LogAlways("[AI NPC] Register ai_npc_test_weapon: " .. tostring(ok_diag_weapon))
    System.LogAlways("[AI NPC] Register ai_npc_test_fall: " .. tostring(ok_diag_fall))
    System.LogAlways("[AI NPC] Register ai_npc_test_ragdoll: " .. tostring(ok_diag_ragdoll))
    System.LogAlways("[AI NPC] Register ai_npc_test_inventory_methods: " .. tostring(ok_diag_inv_methods))
    System.LogAlways("[AI NPC] Register ai_npc_test_equipment_methods: " .. tostring(ok_diag_equipment_methods))
    System.LogAlways("[AI NPC] Register ai_npc_test_appearance_props: " .. tostring(ok_diag_appearance_props))
    System.LogAlways("[AI NPC] Register ai_npc_test_refresh_model: " .. tostring(ok_diag_refresh_model))
    System.LogAlways("[AI NPC] Register ai_npc_test_inventory_dump: " .. tostring(ok_diag_inv_dump))
    System.LogAlways("[AI NPC] Register ai_npc_test_inventory_items: " .. tostring(ok_diag_inv_items))
    System.LogAlways("[AI NPC] Register ai_npc_test_unequip: " .. tostring(ok_diag_unequip))
    System.LogAlways("[AI NPC] Register ai_npc_test_unequip_index: " .. tostring(ok_diag_unequip_index))
    System.LogAlways("[AI NPC] Register ai_npc_test_unequip_slot: " .. tostring(ok_diag_unequip_slot))
    System.LogAlways("[AI NPC] Register ai_npc_test_equip_slot: " .. tostring(ok_diag_equip_slot))
    System.LogAlways("[AI NPC] Register ai_npc_test_equip_item: " .. tostring(ok_diag_equip_item))
    System.LogAlways("[AI NPC] Register ai_npc_test_clothing_preset: " .. tostring(ok_diag_clothing_preset))
    System.LogAlways("[AI NPC] Register ai_npc_test_dress_up: " .. tostring(ok_diag_dress_up))
-- INTERMEDIATE STRIP DISABLED (log lines commented out)
--    System.LogAlways("[AI NPC] Register ai_npc_test_partial_strip: " .. tostring(ok_diag_partial_strip))
--    System.LogAlways("[AI NPC] Register ai_npc_test_full_strip: " .. tostring(ok_diag_full_strip))
--    System.LogAlways("[AI NPC] Register ai_npc_test_dress_partial: " .. tostring(ok_diag_dress_partial))
--    System.LogAlways("[AI NPC] Register ai_npc_test_dress_full: " .. tostring(ok_diag_dress_full))
    System.LogAlways("[AI NPC] Register ai_npc_test_clothing_reset: " .. tostring(ok_diag_clothing_reset))
    System.LogAlways("[AI NPC] Register ai_npc_test_initial_clothing: " .. tostring(ok_diag_initial_clothing))
    System.LogAlways("[AI NPC] Register ai_npc_test_clothing_restore_initial: " .. tostring(ok_diag_restore_initial))
    System.LogAlways("[AI NPC] Register ai_npc_test_clothing_cycle: " .. tostring(ok_diag_clothing_cycle))
    System.LogAlways("[AI NPC] Register ai_npc_test_cheat_clothes: " .. tostring(ok_diag_cheat_clothes))
    System.LogAlways("[AI NPC] Register ai_test_world_text: " .. tostring(ok_test_world_text))
end

function AI_NPC_PollRespNow()
    System.LogAlways("[AI NPC] Manual ai_poll_resp invoked, ticks_seen=" .. tostring(__ai_npc_poll_ticks))
    local ok, err = pcall(process_resp_file)
    if not ok then
        System.LogAlways("[AI NPC] Manual ai_poll_resp error: " .. tostring(err))
    end
end

sync_binds_from_actionmap()

-- =============================================================================
-- Player Event Dispatcher integration (Nexus 1430)
-- =============================================================================
-- Optional dependency. When the dispatcher mod is installed, we register
-- listeners and skip the heavy raycast polling. When absent, we fall back to
-- the existing 500ms polling loop.
-- See docs/reference_mods_findings.md section 1.
local function ai_npc_event_inject_target()
    local now = (System and System.GetCurrTime and System.GetCurrTime()) or os.clock()
    state.last_event_inject_at = now
    -- Single immediate raycast — game already knows there's a focused NPC.
    local ok, err = pcall(scan_and_inject_target)
    if not ok then
        System.LogAlways("[AI NPC] Event inject error: " .. tostring(err))
    end
end

-- Best-effort resolution of which NPC was affected by a player action event.
-- 1) If a chat is open, the current NPC is almost certainly the target.
-- 2) Otherwise do a quick raycast and inspect entity under crosshair.
-- Returns { id = <string>, name = <string> } or nil.
local function resolve_event_target_npc()
    if state.current_npc and state.current_npc.id then
        return {
            id   = state.current_npc.id,
            name = state.current_npc.name or "",
        }
    end
    local ok, npc = pcall(get_targeted_npc)
    if ok and npc and npc.id then
        return { id = npc.id, name = npc.name or "" }
    end
    return nil
end

local function ai_npc_log_player_action(event_name, user, slot_id)
    local now = (System and System.GetCurrTime and System.GetCurrTime()) or os.clock()
    local user_id = (user and user.id) or nil
    local target = resolve_event_target_npc()
    local entry = {
        ts       = now,
        event    = event_name,
        slot     = slot_id,
        user_id  = user_id,
        npc_id   = target and target.id or nil,
        npc_name = target and target.name or nil,
    }
    state.player_action_log[#state.player_action_log + 1] = entry
    -- Cap the log at 50 entries.
    while #state.player_action_log > 50 do
        table.remove(state.player_action_log, 1)
    end
    System.LogAlways(string.format(
        "[AI NPC] Event: %s slot=%s user=%s npc=%s/%s (log size=%d)",
        tostring(event_name), tostring(slot_id), tostring(user_id),
        tostring(entry.npc_id), tostring(entry.npc_name),
        #state.player_action_log
    ))
    -- Refresh ACTIVE| cache so the overlay-submit path (which does not call
    -- build_recent_player_actions itself) picks up the new event.
    if state.chat_open and state.current_npc then
        pcall(notify_active_npc)
    end
end

-- Health-delta tracker (implements the forward-declared local from build_npc_from_entity).
-- Records the latest health for each NPC; if a drop is observed since the last
-- snapshot, logs a synthetic "Hit" event (with damage delta) into player_action_log
-- so the server can tell the LLM that the player just beat this NPC up.
local HEALTH_HIT_THRESHOLD = 0.001   -- ignore floating-point jitter
local HEALTH_HEAL_THRESHOLD = 0.05   -- treat large rises as heal/respawn -> rebaseline
track_npc_health_delta = function(npc_id, current_health, npc_name)
    if not npc_id or npc_id == "" then return end
    if type(current_health) ~= "number" then return end
    local now = (System and System.GetCurrTime and System.GetCurrTime()) or os.clock()
    local snap = state.npc_health_snapshots[npc_id]
    if snap and type(snap.health) == "number" then
        local delta = snap.health - current_health
        if delta > HEALTH_HIT_THRESHOLD then
            -- Damage observed: synthesize a Hit event tied to this NPC.
            local entry = {
                ts        = now,
                event     = "Hit",
                npc_id    = npc_id,
                npc_name  = (npc_name and npc_name ~= "" and npc_name) or snap.name,
                hp_before = snap.health,
                hp_after  = current_health,
                hp_delta  = delta,
            }
            state.player_action_log[#state.player_action_log + 1] = entry
            while #state.player_action_log > 50 do
                table.remove(state.player_action_log, 1)
            end
            System.LogAlways(string.format(
                "[AI NPC] Hit detected: npc=%s/%s hp %.3f -> %.3f (delta=%.3f, log size=%d)",
                tostring(npc_id), tostring(entry.npc_name),
                snap.health, current_health, delta, #state.player_action_log
            ))
            -- Refresh ACTIVE| cache so the overlay-submit path picks up the hit.
            if state.chat_open and state.current_npc then
                pcall(notify_active_npc)
            end
        elseif -delta > HEALTH_HEAL_THRESHOLD then
            -- Health went up significantly (heal/respawn/different actor reuse): rebaseline silently.
        end
    end
    state.npc_health_snapshots[npc_id] = {
        health = current_health,
        ts     = now,
        name   = (npc_name and npc_name ~= "" and npc_name) or (snap and snap.name) or "",
    }
end

-- Build a compact list of recent player actions to send with /chat requests.
-- Only events from the last RECENT_ACTIONS_WINDOW_SEC seconds are included.
-- Events tied to the current NPC are prioritized.
-- Assigned to forward-declared local from the Chat Logic section above.
local RECENT_ACTIONS_WINDOW_SEC = 600  -- 10 minutes
build_recent_player_actions = function(current_npc_id)
    local now = (System and System.GetCurrTime and System.GetCurrTime()) or os.clock()
    local cutoff = now - RECENT_ACTIONS_WINDOW_SEC
    local out = {}
    for _, e in ipairs(state.player_action_log or {}) do
        local ts = tonumber(e.ts) or 0
        if ts >= cutoff then
            local short = tostring(e.event or ""):gsub("BasicAIActionsOn", "")
            local item = {
                event       = short,
                seconds_ago = math.max(0, math.floor(now - ts)),
            }
            if e.npc_id then item.npc_id = e.npc_id end
            if e.npc_name and e.npc_name ~= "" then item.npc_name = e.npc_name end
            -- Pass damage-delta details for synthetic "Hit" entries.
            if e.hp_before ~= nil then item.hp_before = e.hp_before end
            if e.hp_after  ~= nil then item.hp_after  = e.hp_after  end
            if e.hp_delta  ~= nil then item.hp_delta  = e.hp_delta  end
            -- Mark events that targeted the NPC we're now talking to.
            if current_npc_id and e.npc_id == current_npc_id then
                item.same_npc = true
            end
            out[#out + 1] = item
        end
    end
    return out
end

if CONFIG.use_event_dispatcher and _G.PlayerEventDispatcher
        and type(_G.PlayerEventDispatcher.Register) == "function" then
    local ped = _G.PlayerEventDispatcher
    state.dispatcher_mode = "events"

    -- Chat-initiation events — fired by the focused NPC when the player presses
    -- the native talk/chat key. We don't intercept the chat; we just take this
    -- opportunity to pre-warm our context cache with a single raycast.
    for _, ev in ipairs({
        "BasicAIActionsOnChat",
        "BasicAIActionsOnChatWithFocus",
        "BasicAIActionsOnChatRequestAccepted",
        "BasicAIActionsOnChatOpen",
        "BasicAIActionsOnTalk",
    }) do
        ped:Register(ev, function(user, slot_id)
            -- Also (re)arm the polling timer here: bootstrap-time
            -- Script.SetTimer never fires on the rolled-back GOG DLL, so
            -- we lazily start the poller from any reliable user-context
            -- event. Required for AI_NPC_HandleWebCommand (V tap via
            -- __AI_NPC_TAP__) to actually run.
            if rearm_poll_from_user_context then
                pcall(rearm_poll_from_user_context)
            end
            ai_npc_event_inject_target()
        end)
    end

    -- Memory-enrichment events — log notable player actions so the server can
    -- include "Henry recently stole from / attacked / killed this person" in
    -- the system prompt context.
    for _, ev in ipairs({
        "BasicAIActionsOnPickpocketing",
        "BasicAIActionsOnStealthKill",
        "BasicAIActionsOnKnockout",
        "BasicAIActionsOnLoot",
        "BasicAIActionsOnGrabCorpse",
        "BasicAIActionsOnMercyKill",
        "BasicAIActionsOnHorsePullDown",
        "BasicAIActionsOnFollow",
    }) do
        ped:Register(ev, function(user, slot_id)
            ai_npc_log_player_action(ev, user, slot_id)
        end)
    end

    -- Lifecycle: clean state on script reload.
    ped:Register("OnReloadEvent", function(bFromInit, bIsReload)
        if bIsReload then
            System.LogAlways("[AI NPC] PED OnReloadEvent — clearing transient state")
            state.player_action_log = {}
            state.last_event_inject_at = -1000.0
        end
    end)

    System.LogAlways("[AI NPC] Player Event Dispatcher detected: events mode ACTIVE")
else
    if CONFIG.use_event_dispatcher then
        System.LogAlways("[AI NPC] Player Event Dispatcher NOT found (install Nexus mod 1430 for event mode). Falling back to polling.")
    else
        System.LogAlways("[AI NPC] Event dispatcher disabled in CONFIG; using polling.")
    end
end

if Script and Script.SetTimerForFunction then
    Script.SetTimerForFunction(3000, "AI_NPC_ProbeUIInput")
    System.LogAlways("[AI NPC] Scheduled startup UI probe in 3s")
end

-- Enumerate Script.* surface so we can diagnose which timer APIs exist.
if Script then
    local keys = {}
    for k, v in pairs(Script) do
        keys[#keys + 1] = tostring(k) .. "=" .. type(v)
    end
    System.LogAlways("[AI NPC] Script.* keys: " .. table.concat(keys, ", "))
end

-- Start IPC/web polling loop. Try multiple KCD2 timer APIs and use the first
-- one that actually fires. AI_NPC_PollWebCommand will re-schedule via
-- AI_NPC_ScheduleNextPoll using the chosen method.
-- SetTimerForFunction silently no-ops under the current rolled-back DLL build
-- (call returns ok but the callback never fires). Try Script.SetTimer first;
-- fall back to SetTimerForFunction only if SetTimer is missing.
_G.__ai_npc_sched_method = nil
if Script then
    if type(Script.SetTimer) == "function" then
        _G.__ai_npc_sched_method = "SetTimer"
        local ok = pcall(Script.SetTimer, 500, function() AI_NPC_PollWebCommand() end)
        System.LogAlways("[AI NPC] Sched via SetTimer: ok=" .. tostring(ok))
    elseif type(Script.SetTimerForFunction) == "function" then
        _G.__ai_npc_sched_method = "SetTimerForFunction"
        local ok = pcall(Script.SetTimerForFunction, 500, "AI_NPC_PollWebCommand")
        System.LogAlways("[AI NPC] Sched via SetTimerForFunction: ok=" .. tostring(ok))
    else
        System.LogAlways("[AI NPC] No Script timer API available")
    end
end

-- Silently consume any lingering resp.lua from the previous game session so
-- the stale text never appears in the HUD and the duplicate-guard does not
-- block the new session's request_id sequence (which restarts at 1).
do
    _G.__ai_npc_swallow_only = true
    pcall(process_resp_file)
    _G.__ai_npc_swallow_only = false
    last_handled_response_id = 0
    System.LogAlways("[AI NPC] Startup: lingering resp.lua swallowed, last_handled reset")
end

function rearm_poll_from_user_context()
    -- The polling timer scheduled during Bootstrap.lua never fires under the
    -- current DLL (the timer subsystem is likely not live yet at that point).
    -- Re-arming from a user-triggered context (after the world is loaded)
    -- often makes it tick. Re-arming is harmless, so we allow repeats.
    if not Script then return end
    local ok_st, err_st = pcall(function()
        if type(Script.SetTimer) == "function" then
            _G.__ai_npc_sched_method = "SetTimer"
            Script.SetTimer(500, function() AI_NPC_PollWebCommand() end)
        elseif type(Script.SetTimerForFunction) == "function" then
            _G.__ai_npc_sched_method = "SetTimerForFunction"
            Script.SetTimerForFunction(500, "AI_NPC_PollWebCommand")
        end
    end)
    System.LogAlways("[AI NPC] Re-arm poll from user context: method=" .. tostring(_G.__ai_npc_sched_method) .. " ok=" .. tostring(ok_st) .. " err=" .. tostring(err_st))
end

-- Global function for console command.
--
-- When CONFIG.ptt_enabled is true (default) the V key is owned by the
-- server-side Python KeyMonitor: it distinguishes tap-vs-hold and routes
-- taps through __AI_NPC_TAP__. We still keep `bind v ai_chat` active in
-- CryEngine so that the legacy V keystroke can WAKE UP the polling timer
-- (which is dead at bootstrap on the rolled-back GOG DLL). In that mode
-- AI_NPC_Toggle does NOT toggle the chat itself — it only rearms the poll
-- and pumps the response file. The actual toggle arrives via the poller
-- reading __AI_NPC_TAP__ from command.lua. This avoids the original
-- "vvvv leak into overlay" bug because:
--   * on a HOLD, the engine fires ai_chat once on press but we don't open
--     the overlay; Python's KeyMonitor handles STT recording in parallel;
--   * on a TAP, Python writes __AI_NPC_TAP__ on release; the poll tick
--     (now alive thanks to this rearm) reads it and toggles the overlay.
function AI_NPC_Toggle()
    rearm_poll_from_user_context()
    pcall(publish_current_target_once)
    -- Polling timer is unreliable on the rolled-back GOG build, so pump any
    -- pending NPC response right here, on every V press / ai_chat.
    pcall(process_resp_file)
    local ptt_on = (CONFIG.ptt_enabled == nil) or (CONFIG.ptt_enabled == true)
    if ptt_on then
        -- Suppress the legacy console-driven toggle: the server-side
        -- KeyMonitor + __AI_NPC_TAP__ pipeline is the only authority for
        -- tap/hold semantics when PTT is enabled.
        return
    end
    toggle_chat_with_debounce("console")
end

-- =============================================================================
-- Push-to-talk (smart V)
-- -----------------------------------------------------------------------------
-- The CryEngine "+v"/"-v" console-bind prefix that would normally give us
-- separate press/release callbacks turned out to fire BOTH events on key-down
-- in the current KCD2 build, which made it impossible to distinguish a tap
-- from a hold on the Lua side. As a workaround the server polls the V key
-- directly via Win32 GetAsyncKeyState (see server/key_monitor.py) and:
--   * on a tap (release < ptt_hold_threshold_ms) writes the special web
--     command "__AI_NPC_TAP__" via command.lua, which AI_NPC_HandleWebCommand
--     below routes to AI_NPC_Toggle();
--   * on a hold (>= threshold) opens the microphone and submits the
--     transcribed text directly through the existing chat pipeline — the
--     overlay never opens.
-- When CONFIG.ptt_enabled is true, sync_binds_from_actionmap() therefore
-- skips the legacy `bind v ai_chat` so the engine ignores V entirely.
-- =============================================================================

function AI_NPC_End()
    end_conversation()
end

function AI_NPC_SyncBind()
    -- Allow re-running the bind sync from the console even after the
    -- one-shot guard has been set, e.g. after toggling ptt_enabled at
    -- runtime. Also force-unbind the chat key when PTT is enabled so the
    -- console state can never disagree with the Lua intention ("V is owned
    -- by the server-side KeyMonitor").
    _G.__ai_npc_binds_done = nil
    last_synced_chat_key = nil
    _G.__ai_npc_unbind_v_done = nil
    local ptt_on = (CONFIG.ptt_enabled == nil) or (CONFIG.ptt_enabled == true)
    if ptt_on and System and System.ExecuteCommand then
        local key = CONFIG.chat_key or "v"
        pcall(System.ExecuteCommand, "unbind " .. key)
        if System.LogAlways then
            System.LogAlways(
                "[AI NPC] ai_sync_bind: force-unbound '" .. tostring(key) ..
                "' (PTT delegated to server KeyMonitor)"
            )
        end
    end
    sync_binds_from_actionmap()
end

-- Poll IPC input from DLL
function AI_NPC_PollIPC()
    ipc_poll_input()
    Script.SetTimerForFunction(200, "AI_NPC_PollIPC")
end

function AI_NPC_Status()
    if state.server_online then
        System.LogAlways("[AI NPC] Server is ONLINE")
    else
        System.LogAlways("[AI NPC] Server is OFFLINE — start the Python server first!")
    end
    System.LogAlways("[AI NPC] Dispatcher mode: " .. tostring(state.dispatcher_mode)
        .. " (action log entries: " .. tostring(#state.player_action_log) .. ")")
end

-- Log startup
if System and System.LogAlways then
    System.LogAlways("[AI NPC] Mod loaded. Press " .. CONFIG.chat_key .. " to chat with NPCs.")
    System.LogAlways("[AI NPC] Make sure the Python server is running on " .. CONFIG.server_url)
    System.LogAlways("[AI NPC] Initial dispatcher mode: " .. tostring(state.dispatcher_mode))
end

-- Print to console as well
print("[AI NPC] Mod loaded v0.1.0")
print("[AI NPC] Press " .. CONFIG.chat_key .. " near an NPC to start a conversation")
print("[AI NPC] Server: " .. CONFIG.server_url)

-- Run one poll cycle immediately so the first NPC the player is looking at
-- gets injected right away (the scheduled timer may not tick on GOG DLL).
pcall(function()
    System.LogAlways("[AI NPC] Immediate startup poll")
    AI_NPC_PollWebCommand()
end)

-- GOG rolled-back DLL: Script.SetTimer scheduled at bootstrap silently no-ops.
-- Re-arm after a longer delay once the level/world is fully loaded.
function AI_NPC_AutoRearmPoll()
    System.LogAlways("[AI NPC] Auto-rearm poll after startup delay")
    rearm_poll_from_user_context()
end

if Script then
    if type(Script.SetTimerForFunction) == "function" then
        Script.SetTimerForFunction(10000, "AI_NPC_AutoRearmPoll")
    elseif type(Script.SetTimer) == "function" then
        Script.SetTimer(10000, function() AI_NPC_AutoRearmPoll() end)
    end
end
