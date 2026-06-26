-- ============================================================
--  RR Shelf Keeper — entry point
--  Phase 1: layout snapshot (read + log only).      F9 / `rrshelf snapshot`
--  Phase 2: persist a snapshot to a per-save file +  `rrshelf save` / `rrshelf load`
--           load it back. Still NO shelf mutation — disk I/O only.
--
--  Persistence (Phase 2):
--   - File key  = gm["Save Slot Name"] (the .sav basename), sanitized (key.lua).
--   - File path = <mod>/layouts/<key>.lua, a sandboxed Lua return-table (store.lua).
--   - Shelf key = the serialized GUID Shelf ("g:a-b-c-d"), with a loc+yaw fallback —
--     restart-durable, unlike Phase 1's GetFName which renumbers on reload (layout.lua).
--
--  Bump VERSION on every edit and confirm it appears in UE4SS.log after Ctrl+R hot-reload.
--  All output is tagged [RR-Shelf]. Reads/writes run inside ExecuteInGameThread — one
--  synchronous pass off the trigger, never a continuous async loop (CLAUDE.md §7 / gotcha 19).
-- ============================================================
local VERSION = "shelf-v4"

local Config = require("config")
local layout = require("layout")
local store  = require("store")
local key    = require("key")

local P = "[RR-Shelf] "
local function log(m) print(P .. tostring(m) .. "\n") end

local function logSnap(snap)            -- emit a snapshot/persist table as readable lines
    for _, line in ipairs(layout.format(snap)) do log(line) end
end

-- Phase 1: build a snapshot and log it (no disk, no mutation). Returns the in-memory snapshot.
local function runSnapshot()
    local snap = layout.snapshot()
    logSnap(snap)
    if snap.shelfCount == 0 then
        log("No movie shelves found — load a stocked store and stand in it, then retry.")
    end
    return snap
end

-- Phase 2: snapshot the live shelves, then write the durable, per-save layout file.
local function runSave()
    local snap = layout.snapshot()
    if snap.shelfCount == 0 then
        log("save aborted: no movie shelves found (load a stocked store first).")
        return
    end
    local k, raw = key.fromGamemode()
    if not raw then
        log("WARNING: could not read gm['Save Slot Name'] — saving under key '" .. k .. "'.")
    end
    local persist = layout.toPersist(snap, k)
    logSnap(snap)                                    -- show the live snapshot (+ collision check)
    if snap.durableCollisions and snap.durableCollisions > 0 then
        log("WARNING: " .. snap.durableCollisions .. " shelves share a durable key — Phase 3 "
            .. "enforcement may mis-target them. Investigate before relying on this layout.")
    end

    local dir  = store.resolveDir(Config.LayoutsDir)
    local path = store.pathFor(dir, k)
    local ok, err = store.save(path, persist)
    if ok then
        log(string.format("SAVED %d shelves / %d slots -> %s", persist.shelfCount, persist.totalSlots, path))
    else
        log("SAVE FAILED -> " .. path .. "  (" .. tostring(err) .. ")")
        log("  If the path looks wrong, set Config.LayoutsDir to an absolute folder and retry.")
    end
end

-- Phase 2: load the per-save layout file back into memory and log it (no mutation yet).
local function runLoad()
    local k, raw = key.fromGamemode()
    if not raw then
        log("WARNING: could not read gm['Save Slot Name'] — loading key '" .. k .. "'.")
    end
    local dir  = store.resolveDir(Config.LayoutsDir)
    local path = store.pathFor(dir, k)
    local persist, err = store.load(path)
    if not persist then
        log("no layout to load for key '" .. k .. "' (" .. tostring(err) .. ").")
        return
    end
    log("LOADED layout for key '" .. k .. "' from " .. path)
    logSnap(persist)
end

-- Each action is one synchronous game-thread pass (UObject reads + disk I/O), pcall-guarded.
local function inGame(fn, label)
    return function()
        ExecuteInGameThread(function()
            local ok, err = pcall(fn)
            if not ok then log(label .. " error: " .. tostring(err)) end
        end)
    end
end

local onSnapshot = inGame(runSnapshot, "Snapshot")
local onSave     = inGame(runSave, "Save")
local onLoad     = inGame(runLoad, "Load")

-- ---- hotkeys (top-level registration is fine — these are keybinds, not BP hooks) ----------

local function bind(keyName, mods, cb)
    if not keyName then return end
    local kc = Key[keyName]
    if mods and #mods > 0 then
        local m = {}
        for _, name in ipairs(mods) do m[#m + 1] = ModifierKey[name] end
        RegisterKeyBind(kc, m, cb)
    else
        RegisterKeyBind(kc, cb)
    end
end

bind(Config.SnapshotKey, Config.Modifiers, onSnapshot)
bind(Config.SaveKey, nil, onSave)        -- nil by default → console-only
bind(Config.LoadKey, nil, onLoad)        -- nil by default → console-only

-- ---- console: `rrshelf snapshot|save|load` (bare `rrshelf` = snapshot) ---------------------
-- The console is the reliable trigger on this install (no GUI console — GraphicsAPI=opengl).
RegisterConsoleCommandHandler("rrshelf", function(fullCommand, parameters, outputDevice)
    local sub = (parameters and parameters[1] and tostring(parameters[1]):lower()) or "snapshot"
    if sub == "snapshot" then onSnapshot()
    elseif sub == "save" then onSave()
    elseif sub == "load" then onLoad()
    else log("Usage: rrshelf snapshot | save | load") end
    return true
end)

log("RR Shelf Keeper loaded (" .. VERSION .. ", Phase 2: persist). "
    .. Config.SnapshotKey .. " = snapshot;  console: `rrshelf snapshot|save|load`.")
