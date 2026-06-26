-- ============================================================
--  RR Shelf Keeper — entry point
--  Phase 1: layout snapshot (read + log only).      F9 / `rrshelf snapshot`
--  Phase 2: persist a snapshot to a per-save file +  `rrshelf save` / `rrshelf load`
--           load it back. Disk I/O only.
--  Phase 3: enforce the saved layout — correct mismatched slots back to it (the move primitive).
--           F10 / `rrshelf enforce`     = DRY RUN: log the plan + reflect the BP signature, NO mutation.
--           `rrshelf enforce go`        = APPLY: actually move cassettes. Console-only & deliberate
--           because the move primitive's arg signature is unconfirmed and a bad BP call can
--           NATIVE-crash (§7) — validate the reflected signature from the dry run first.
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
local VERSION = "shelf-v13"

local Config  = require("config")
local layout  = require("layout")
local store   = require("store")
local key     = require("key")
local enforce = require("enforce")
local restock = require("restock")

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

-- Phase 3: compare live shelves to the saved layout, then correct mismatched slots.
--   dryRun=true  -> log the plan + reflect the move-primitive signature; mutate NOTHING.
--   dryRun=false -> run the moves through the BP primitive.
local function runEnforce(dryRun)
    local snap = layout.snapshot()
    if snap.shelfCount == 0 then
        log("enforce aborted: no movie shelves found (load a stocked store first).")
        return
    end
    local k, raw = key.fromGamemode()
    if not raw then
        log("WARNING: could not read gm['Save Slot Name'] — using key '" .. k .. "'.")
    end
    local dir   = store.resolveDir(Config.LayoutsDir)
    local path  = store.pathFor(dir, k)
    local saved, err = store.load(path)
    if not saved then
        log("enforce: no saved layout for key '" .. k .. "' (" .. tostring(err) .. ").")
        log("  run `rrshelf save` first to capture the layout you want enforced.")
        return
    end

    local d = enforce.diff(saved, snap)
    local p = enforce.plan(saved, snap)
    log(string.format("=== enforce %s — key '%s' ===", dryRun and "DRY RUN" or "GO", k))
    log(string.format("matched %d shelf/shelves, %d missing; %d slot mismatch(es)",
        d.matched, #d.missing, d.totalMismatches))
    log(string.format("plan: %d move(s), %d surplus re-place(s), %d unfulfillable",
        p.totalMoves, p.totalSurplus, p.totalUnfulfillable))
    if #d.missing > 0 then
        log("  missing (saved but not live now): " .. table.concat(d.missing, ", "))
    end
    local shownUf = 0
    for _, sh in ipairs(p.shelves) do
        for _, uf in ipairs(sh.unfulfillable) do
            if shownUf < 20 then
                log(string.format("  unfulfillable: shelf %s slot %d wants SKU %s (no copy on this shelf)",
                    tostring(sh.key), uf.to, tostring(uf.wantSku)))
                shownUf = shownUf + 1
            end
        end
    end

    local refIndex = enforce.indexLive(snap)
    -- reflect the move-primitive signature off the first managed container (cheap, read-only, always)
    local firstContainer
    for _, sh in ipairs(p.shelves) do
        local ref = refIndex[sh.key]
        if ref then
            for _, mv in ipairs(sh.moves) do
                if ref.containers[mv.from] then firstContainer = ref.containers[mv.from]; break end
            end
        end
        if firstContainer then break end
    end
    if firstContainer then
        log("-- move-primitive signatures (reflected, read-only — confirm before `go`) --")
        enforce.reflectSignature(firstContainer, log)
    end

    if p.totalMoves == 0 then
        log("nothing to correct — every managed slot already matches the saved layout.")
        return
    end

    local stats = enforce.apply(p, refIndex, log, dryRun)
    if dryRun then
        log(string.format("DRY RUN complete: %d move(s) planned, nothing changed.", stats.moves))
        log("  Review the plan + signatures above, then `rrshelf enforce go` to apply.")
    else
        log(string.format("ENFORCE complete: %d/%d store(s) ok, %d empt(ies), %d error(s), %d shelf-skip(s).",
            stats.stores, stats.moves, stats.empties, stats.errors, stats.skippedShelves))
        if stats.errors > 0 then
            log("  errors above usually mean the move-primitive arg signature is wrong — check the reflected sig.")
        end
    end
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

local onSnapshot  = inGame(runSnapshot, "Snapshot")
local onSave      = inGame(runSave, "Save")
local onLoad      = inGame(runLoad, "Load")
local onEnforce   = inGame(function() runEnforce(true)  end, "Enforce(dry)")  -- safe preview
local onEnforceGo = inGame(function() runEnforce(false) end, "Enforce")       -- mutates

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
bind(Config.SaveKey, nil, onSave)            -- nil by default → console-only
bind(Config.LoadKey, nil, onLoad)            -- nil by default → console-only
bind(Config.EnforceKey, nil, onEnforce)      -- F10 = DRY RUN only; `go` stays console-only (deliberate)

-- ---- console: `rrshelf snapshot|save|load` (bare `rrshelf` = snapshot) ---------------------
-- The console is the reliable trigger on this install (no GUI console — GraphicsAPI=opengl).
RegisterConsoleCommandHandler("rrshelf", function(fullCommand, parameters, outputDevice)
    local sub = (parameters and parameters[1] and tostring(parameters[1]):lower()) or "snapshot"
    local arg2 = parameters and parameters[2] and tostring(parameters[2]):lower() or nil
    if sub == "snapshot" then onSnapshot()
    elseif sub == "save" then onSave()
    elseif sub == "load" then onLoad()
    elseif sub == "enforce" then
        if arg2 == "go" then onEnforceGo() else onEnforce() end   -- bare `enforce` = dry run
    else log("Usage: rrshelf snapshot | save | load | enforce [go]") end
    return true
end)

-- Phase A1: ordered restock. Hook the slot-chooser late (BP class loads after mod start). The path
-- is the base Shelve_C function confirmed by the recon probe; one hook covers all movie shelves.
if Config.OrderedRestock then
    ExecuteWithDelay(3000, function()
        local path = "/Game/VideoStore/asset/prop/shelve/Shelve.Shelve_C:Does any Shelve Containers still empty"
        local ok, err = pcall(function() RegisterHook(path, restock.onDoesAnyEmpty) end)
        if ok then
            log("ordered-restock hook active" .. (Config.RestockDryRun and " (DRY RUN — logging only)" or ""))
        else
            log("ordered-restock hook FAILED: " .. tostring(err))
        end
    end)
end

log("RR Shelf Keeper loaded (" .. VERSION .. ", Phase A1: ordered restock). "
    .. Config.SnapshotKey .. " = snapshot, " .. tostring(Config.EnforceKey) .. " = enforce DRY RUN;  "
    .. "console: `rrshelf snapshot|save|load|enforce [go]`.")
