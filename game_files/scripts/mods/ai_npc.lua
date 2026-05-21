pcall(function() System.LogAlways("[AI NPC] bootstrap: loading Scripts/ai_npc/main.lua") end)
local ok, err = pcall(function() Script.ReloadScript("Scripts/ai_npc/main.lua") end)
if ok then
    pcall(function() System.LogAlways("[AI NPC] bootstrap: main.lua loaded OK") end)
else
    pcall(function() System.LogAlways("[AI NPC] bootstrap: main.lua FAILED - " .. tostring(err)) end)
end