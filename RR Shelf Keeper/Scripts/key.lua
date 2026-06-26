-- RR Shelf Keeper — per-save key derivation (Phase 2).
--
-- The persistence key (the layout file's basename) is the active save's name, which Phase 0
-- pinned to gm["Save Slot Name"] (a StrProperty == the .sav basename, e.g. "Player_Save2").
-- sanitize() turns it into a safe filename; fromGamemode() reads it live. sanitize() is pure
-- and unit-tested (tests/key_test); fromGamemode() needs the running game (verified in-game).
local M = {}

-- Keep only filename-safe characters [A-Za-z0-9_-]; everything else (spaces, punctuation,
-- DOTS, and path separators) becomes "_". Dropping dots neutralises "../" traversal outright.
-- nil / empty / non-string / all-stripped -> "default" so we always get a usable filename.
function M.sanitize(raw)
    if type(raw) ~= "string" or raw == "" then return "default" end
    local s = raw:gsub("[^%w_-]", "_")
    if s == "" then return "default" end
    return s
end

-- Live read: Core_Gamemode_C -> "Save Slot Name". Returns (key, rawName). rawName is nil when
-- the field can't be read (no gamemode yet, or load in progress) -> key falls back to "default"
-- and the caller should log a warning. "Save Slot Name" is a StrProperty (Lua string); we also
-- tolerate an FString/FName userdata via :ToString() just in case the build differs.
function M.fromGamemode()
    local gm
    pcall(function()
        local gms = FindAllOf("Core_Gamemode_C")
        gm = gms and gms[1] or nil
    end)
    local raw
    if gm then
        pcall(function()
            local v = gm["Save Slot Name"]
            if type(v) == "string" then
                raw = v
            elseif v ~= nil then
                local ok, s = pcall(function() return v:ToString() end)
                if ok and type(s) == "string" then raw = s end
            end
        end)
    end
    if raw == "" then raw = nil end
    return M.sanitize(raw), raw
end

return M
