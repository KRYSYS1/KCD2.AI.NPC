System.LogAlways("[AI-NPC] Bootstrap loading...")
if Script and Script.LoadScript then
    local ok, err = pcall(Script.LoadScript, "scripts/ai_npc/main.lua")
    System.LogAlways("[AI-NPC] Bootstrap main.lua load: " .. tostring(ok) .. (err and (" err="..tostring(err)) or ""))
else
    System.LogAlways("[AI-NPC] Bootstrap: Script.LoadScript unavailable")
end