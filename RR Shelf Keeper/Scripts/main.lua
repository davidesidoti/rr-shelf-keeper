-- ============================================================
--  RR Shelf Keeper — entry point
--  Phase 1: layout snapshot (read + log only). On a hotkey (F9) or the console command
--  `rrshelf snapshot`, enumerate every movie shelf, build an ordered slotIndex -> SKU table,
--  and log it. Nothing is written to disk and nothing is mutated this phase.
--
--  Bump VERSION on every edit and confirm it appears in UE4SS.log after Ctrl+R hot-reload,
--  so you know the reload took. All output is tagged [RR-Shelf] (grep it out of the shared
--  UE4SS.log). Reads run inside ExecuteInGameThread — one synchronous pass off the trigger,
--  never a continuous async loop (CLAUDE.md §7 / sibling gotcha 19).
-- ============================================================
local VERSION = "shelf-v2"

local Config = require("config")
local layout = require("layout")

local P = "[RR-Shelf] "
local function log(m) print(P .. tostring(m) .. "\n") end

-- Build a snapshot and log it. Returns the in-memory snapshot (Phase 2 will serialize it).
local function runSnapshot()
    local snap = layout.snapshot()
    for _, line in ipairs(layout.format(snap)) do log(line) end
    if snap.shelfCount == 0 then
        log("No movie shelves found — load a stocked store and stand in it, then retry.")
    end
    return snap
end

local function onSnapshot()
    ExecuteInGameThread(function()                      -- UObject reads on the game thread
        local ok, err = pcall(runSnapshot)
        if not ok then log("Snapshot error: " .. tostring(err)) end
    end)
end

-- snapshot hotkey (+ optional modifiers) — top-level registration is fine (not a hook)
local key = Key[Config.SnapshotKey]
if Config.Modifiers and #Config.Modifiers > 0 then
    local mods = {}
    for _, name in ipairs(Config.Modifiers) do mods[#mods + 1] = ModifierKey[name] end
    RegisterKeyBind(key, mods, onSnapshot)
else
    RegisterKeyBind(key, onSnapshot)
end

-- console: `rrshelf snapshot` (bare `rrshelf` also runs it). The console is the reliable
-- trigger on this install (the GUI console never spawns — GraphicsAPI=opengl, CLAUDE.md §7).
RegisterConsoleCommandHandler("rrshelf", function(fullCommand, parameters, outputDevice)
    local sub = (parameters and parameters[1] and tostring(parameters[1]):lower()) or "snapshot"
    if sub == "snapshot" then
        onSnapshot()
    else
        log("Usage: rrshelf snapshot   (Phase 1: read + log only)")
    end
    return true
end)

log("RR Shelf Keeper loaded (" .. VERSION .. ", Phase 1: snapshot). Press "
    .. Config.SnapshotKey .. " or type `rrshelf snapshot` in the console.")
