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

    return {
        id = tostring(ent.id or entity_token or "unknown"),
        name = chosen_name or (entity_token or "Villager"),
        engine_name = entity_token or "Villager",
        caption_name = caption_name,
        soul_token = soul_token,
        class = tostring(ent.class or ""),
        location = "",
        faction_id = faction_id,
        social_class = social_class,
        gender = gender,
        soul_name_key = soul_name_key,
        extra_context = table.concat(context_lines, "\n"),
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

        if self.actor and not self.actor:IsDead() and not self.actor:IsUnconscious() then
            local ok_add, add_err = pcall(function()
                AddInteractorAction(output, firstFast,
                    Action()
                        :hint("ui_ai_npc_talk")
                        :hintType(AHT_RELEASE)
                        :action("ai_npc_chat")
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
                        :interaction(inr_loot)
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
    if not hits or hits <= 0 then return nil end

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
    if not hit or not resolved then return nil end

    -- Make sure the "Поговорить" prompt is attached to this entity going
    -- forward (in case the poll-side scanner hasn't injected it yet).
    inject_ai_interaction(resolved)

    local npc = build_npc_from_entity(resolved)
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

local function npc_debug_probe(npc)
    if not npc then return end
    local actions = {}
    local ok_acts, acts = pcall(build_recent_player_actions, npc.id)
    if ok_acts and type(acts) == "table" then actions = acts end
    System.LogAlways("[AI NPC] TARGET|" .. json.encode({
        id = npc.id,
        name = npc.name,
        class = npc.class,
        faction_id = npc.faction_id,
        social_class = npc.social_class,
        gender = npc.gender,
        soul_name_key = npc.soul_name_key,
        target_distance = npc.target_distance,
        recent_player_actions = actions,
    }))
    if npc.extra_context and npc.extra_context ~= "" then
        System.LogAlways("[AI NPC] TARGET_CTX|" .. tostring(npc.extra_context):gsub("\n", " | "))
    end
end

local function publish_current_target_once()
    if state.chat_open then return end
    local ok, npc = pcall(get_targeted_npc)
    if ok and npc then
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

-- ui_show(message, duration, opts)
-- opts.service = true  -> force ONLY top-right notification (no center subtitle,
--                        no left tutorial). Use for non-roleplay UX strings:
--                        "разговор с X", "разговор завершён", error toasts.
local function ui_show(message, duration, opts)
    duration = duration or 8000
    opts = opts or {}
    local service_only = opts.service == true
    local text = tostring(message)
    local show_left = (not service_only) and (_G.__ai_npc_hud_left ~= false)
    local show_right = _G.__ai_npc_hud_right ~= false
    local show_center = (not service_only) and (_G.__ai_npc_hud_center ~= false)
    System.LogAlways(string.format(
        "[AI NPC] HUD: left=%s right=%s center=%s service=%s text=%s",
        tostring(show_left), tostring(show_right), tostring(show_center),
        tostring(service_only), text
    ))

    -- Center-bottom: italic gold subtitle with ornament.
    if show_center and Game and Game.ShowTutorial then
        local sec = math.max(1, math.floor(duration / 1000))
        local ok_tut, err_tut = pcall(Game.ShowTutorial, text, sec)
        if ok_tut then
            System.LogAlways("[AI NPC] HUD method ok: Game.ShowTutorial (center)")
        else
            System.LogAlways("[AI NPC] HUD Game.ShowTutorial error: " .. tostring(err_tut))
        end
    end

    if UIAction and UIAction.CallFunction then
        -- Each entry: {position_flag, element, method, args...}
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
        System.LogAlways("[AI NPC] ACTIVE|" .. json.encode({
            npc_id = state.current_npc.id,
            npc_name = state.current_npc.name,
            npc_class = state.current_npc.class,
            npc_location = state.current_npc.location,
            soul_name_key = state.current_npc.soul_name_key,
            extra_context = state.current_npc.extra_context,
            recent_player_actions = actions,
            gender = state.current_npc.gender,
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

function AI_NPC_HandleResponse(npc_name, response_text, request_id)
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
        System.LogAlways("[AI NPC] Poll tick #" .. tostring(__ai_npc_poll_ticks))
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
    ui_show("Вы: " .. tostring(text), 5000)

    local request_data = {
        npc_id = state.current_npc.id,
        npc_name = state.current_npc.name,
        npc_class = state.current_npc.class,
        npc_location = state.current_npc.location,
        player_message = text,
        extra_context = state.current_npc.extra_context or "",
        recent_player_actions = build_recent_player_actions(state.current_npc.id),
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

local function force_game_focus_after_overlay_close()
    local calls = {
        function() if System and System.ShowCursor then System.ShowCursor(0) end end,
        function() if System and System.ShowCursor then System.ShowCursor(false) end end,
        function() if UIAction and UIAction.HideCursor then UIAction.HideCursor() end end,
        function() if UIAction and UIAction.SetCursorVisible then UIAction.SetCursorVisible(false) end end,
        function() if Game and Game.ShowCursor then Game.ShowCursor(false) end end,
        function() if Game and Game.SetMouseCursorVisible then Game.SetMouseCursorVisible(false) end end,
        function() if Input and Input.SetExclusiveMode then Input.SetExclusiveMode(true) end end,
        function() if Input and Input.GrabInput then Input.GrabInput(true) end end,
    }
    for _, fn in ipairs(calls) do
        pcall(fn)
    end
end

local function resume_game_input()
    if not input_lockout_active then
        pcall(force_game_focus_after_overlay_close)
        return
    end
    input_lockout_active = false
    if ActionMapManager and ActionMapManager.EnableActionMap then
        for _, name in ipairs(INPUT_LOCKOUT_MAPS) do
            pcall(ActionMapManager.EnableActionMap, name, true)
        end
    end
    pcall(force_game_focus_after_overlay_close)
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

local function end_conversation()
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
    System.LogAlways("[AI NPC] Register ai_chat: " .. tostring(ok_chat))
    System.LogAlways("[AI NPC] Register ai_say: " .. tostring(ok_say))
    System.LogAlways("[AI NPC] Register ai_end: " .. tostring(ok_end))
    System.LogAlways("[AI NPC] Register ai_sync_bind: " .. tostring(ok_sync_bind))
    System.LogAlways("[AI NPC] Register ai_probe_ui: " .. tostring(ok_probe))
    System.LogAlways("[AI NPC] Register aiprobe: " .. tostring(ok_probe_alias))
    System.LogAlways("[AI NPC] Register ai_target_debug: " .. tostring(ok_target_debug))
    System.LogAlways("[AI NPC] Register ai_poll_resp: " .. tostring(ok_poll_resp))
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
    -- often makes it tick. Do this once.
    if _G.__ai_npc_poll_rearmed then return end
    _G.__ai_npc_poll_rearmed = true
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
