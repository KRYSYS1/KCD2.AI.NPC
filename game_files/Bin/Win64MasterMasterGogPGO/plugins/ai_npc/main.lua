--[[
  KCD2 AI NPC — Main entry point
  Requires: KCD2ModLoader (https://github.com/xiaoxiao921/KCD2ModLoader)
  
  This mod allows players to have AI-powered conversations with any NPC
  using a local Python server (LLM + optional TTS).
]]

-- Configuration
local CONFIG = {
    server_url = "http://127.0.0.1:4999",
    chat_key = "F5",           -- Key to open chat with nearest NPC
    end_key = "F6",            -- Key to end current conversation
    max_npc_distance = 5.0,    -- Max distance to NPC to start conversation (meters)
    window_width = 600,
    window_height = 400,
}

-- State
local state = {
    chat_open = false,
    input_text = "",
    messages = {},            -- { {role="player"|"npc", name=string, text=string}, ... }
    current_npc = nil,        -- { id, name, class, location }
    waiting_response = false,
    error_message = nil,
    server_online = false,
}

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

-- HTTP POST (async via KCD2ModLoader net module if available, otherwise sync)
local pending_request = nil

local function http_post(endpoint, data, callback)
    local url = CONFIG.server_url .. endpoint
    local body = json.encode(data)

    -- Try KCD2ModLoader's async HTTP if available
    if rom and rom.net and rom.net.http_post then
        rom.net.http_post(url, body, "application/json", function(status, response_body)
            if status >= 200 and status < 300 then
                local parsed = json.decode(response_body)
                callback(parsed, nil)
            else
                callback(nil, "HTTP " .. tostring(status))
            end
        end)
        return
    end

    -- Fallback: use os.execute with curl (blocking, not ideal but works)
    local tmp_file = os.tmpname()
    local cmd = string.format(
        'curl -s -X POST -H "Content-Type: application/json" -d \'%s\' "%s" -o "%s" 2>/dev/null',
        body:gsub("'", "'\\''"), url, tmp_file
    )
    local ok = os.execute(cmd)
    if ok then
        local f = io.open(tmp_file, "r")
        if f then
            local resp = f:read("*a")
            f:close()
            os.remove(tmp_file)
            local parsed = json.decode(resp)
            callback(parsed, nil)
            return
        end
    end
    os.remove(tmp_file)
    callback(nil, "Request failed")
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
                            nearest = {
                                id = tostring(ent.id or ent:GetName() or "unknown"),
                                name = ent:GetName() or "Villager",
                                class = ent.class or "",
                                location = "",
                            }
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

local function send_message(text)
    if not state.current_npc then return end
    if state.waiting_response then return end
    if text == "" then return end

    -- Add player message to chat
    table.insert(state.messages, {
        role = "player",
        name = "Henry",
        text = text,
    })

    state.waiting_response = true
    state.error_message = nil

    local request_data = {
        npc_id = state.current_npc.id,
        npc_name = state.current_npc.name,
        npc_class = state.current_npc.class,
        npc_location = state.current_npc.location,
        player_message = text,
        extra_context = "",
    }

    http_post("/chat", request_data, function(response, err)
        state.waiting_response = false
        if err then
            state.error_message = "Server error: " .. tostring(err)
            return
        end
        if response and response.response then
            table.insert(state.messages, {
                role = "npc",
                name = response.npc_name or state.current_npc.name,
                text = response.response,
            })
        else
            state.error_message = "Invalid response from server"
        end
    end)
end

local function start_conversation()
    local npc = get_nearest_npc()
    if not npc then
        state.error_message = "No NPC nearby"
        return
    end
    state.current_npc = npc
    state.messages = {}
    state.chat_open = true
    state.error_message = nil
    state.input_text = ""
end

local function end_conversation()
    if state.current_npc then
        -- Notify server
        http_post("/end_conversation", { npc_id = state.current_npc.id }, function() end)
    end
    state.chat_open = false
    state.current_npc = nil
    state.messages = {}
    state.input_text = ""
    state.error_message = nil
    state.waiting_response = false
end

-- ============================================================================
-- ImGui UI (requires KCD2ModLoader with ImGui support)
-- ============================================================================

local function draw_chat_window()
    if not state.chat_open then return end
    if not ImGui then return end

    local npc_name = state.current_npc and state.current_npc.name or "NPC"

    ImGui.SetNextWindowSize(CONFIG.window_width, CONFIG.window_height, ImGuiCond.FirstUseEver)
    local visible = ImGui.Begin("AI Chat — " .. npc_name, true)

    if not visible then
        end_conversation()
        ImGui.End()
        return
    end

    -- Chat history area
    local avail_x, avail_y = ImGui.GetContentRegionAvail()
    ImGui.BeginChild("ChatHistory", avail_x, avail_y - 35, true)

    for _, msg in ipairs(state.messages) do
        if msg.role == "player" then
            ImGui.PushStyleColor(ImGuiCol.Text, 0.4, 0.8, 1.0, 1.0)  -- Blue for player
            ImGui.TextWrapped("[" .. msg.name .. "]: " .. msg.text)
            ImGui.PopStyleColor()
        else
            ImGui.PushStyleColor(ImGuiCol.Text, 1.0, 0.9, 0.5, 1.0)  -- Yellow for NPC
            ImGui.TextWrapped("[" .. msg.name .. "]: " .. msg.text)
            ImGui.PopStyleColor()
        end
    end

    if state.waiting_response then
        ImGui.PushStyleColor(ImGuiCol.Text, 0.6, 0.6, 0.6, 1.0)
        ImGui.TextWrapped(npc_name .. " is thinking...")
        ImGui.PopStyleColor()
    end

    if state.error_message then
        ImGui.PushStyleColor(ImGuiCol.Text, 1.0, 0.3, 0.3, 1.0)
        ImGui.TextWrapped("Error: " .. state.error_message)
        ImGui.PopStyleColor()
    end

    -- Auto-scroll to bottom
    if ImGui.GetScrollY() >= ImGui.GetScrollMaxY() - 20 then
        ImGui.SetScrollHereY(1.0)
    end

    ImGui.EndChild()

    -- Input field
    ImGui.PushItemWidth(avail_x - 70)
    local changed
    state.input_text, changed = ImGui.InputText("##input", state.input_text, 256, ImGuiInputTextFlags.EnterReturnsTrue)

    if changed and state.input_text ~= "" then
        send_message(state.input_text)
        state.input_text = ""
        ImGui.SetKeyboardFocusHere(-1)
    end

    ImGui.PopItemWidth()
    ImGui.SameLine()

    if ImGui.Button("Send", 60, 0) then
        if state.input_text ~= "" then
            send_message(state.input_text)
            state.input_text = ""
        end
    end

    ImGui.End()
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
    if rom and rom.net and rom.net.http_get then
        rom.net.http_get(CONFIG.server_url .. "/health", function(status, body)
            state.server_online = (status >= 200 and status < 300)
        end)
    end
end

-- ============================================================================
-- Main hooks
-- ============================================================================

-- Register keybinds
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

-- Draw UI every frame
local function on_draw()
    draw_chat_window()
end

-- ============================================================================
-- KCD2ModLoader integration
-- ============================================================================

-- Register with KCD2ModLoader if available
if rom and rom.gui then
    rom.gui.add_to_menu_bar(function()
        if ImGui.BeginMenu("AI NPC") then
            if ImGui.MenuItem("Open Chat (F5)") then
                if state.chat_open then
                    end_conversation()
                else
                    start_conversation()
                end
            end
            if ImGui.MenuItem("Server Status") then
                check_server_health()
            end
            ImGui.EndMenu()
        end
    end)

    rom.gui.add_imgui(on_draw)
end

-- Register key handler
if rom and rom.on_key then
    rom.on_key(on_key_press)
end

-- Fallback: use CryEngine input system
if System and System.AddCCommand then
    System.AddCCommand("ai_chat", "AI_NPC_Toggle()", "Toggle AI NPC chat window")
end

-- Global function for console command
function AI_NPC_Toggle()
    if state.chat_open then
        end_conversation()
    else
        start_conversation()
    end
end

function AI_NPC_Status()
    if state.server_online then
        System.LogAlways("[AI NPC] Server is ONLINE")
    else
        System.LogAlways("[AI NPC] Server is OFFLINE — start the Python server first!")
    end
end

-- Log startup
if System and System.LogAlways then
    System.LogAlways("[AI NPC] Mod loaded. Press " .. CONFIG.chat_key .. " to chat with NPCs.")
    System.LogAlways("[AI NPC] Make sure the Python server is running on " .. CONFIG.server_url)
end

-- Print to console as well
print("[AI NPC] Mod loaded v0.1.0")
print("[AI NPC] Press " .. CONFIG.chat_key .. " near an NPC to start a conversation")
print("[AI NPC] Server: " .. CONFIG.server_url)
