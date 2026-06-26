-- ============================================================
--  RR Shelf Keeper — entry point
--  Phase A1: ordered restock. Staff restock each movie into the next empty slot in PHYSICAL
--  order (top→bottom, left→right) instead of a scattered empty slot — by overriding the AI's
--  slot choice at restock time. No placed cassette is ever moved after it lands.
--
--  Mechanism: hook the base-class slot-chooser
--    Shelve_C:"Does any Shelve Containers still empty"  (returns the empty container staff fill)
--  and rewrite its returned `Empty Container` to the next physically-ordered empty slot
--  (order.lua + restock.lua). One hook on the Shelve_C base covers all movie shelves; the
--  callback guards to movie-shelf leaf classes so snack/concession shelves are left alone.
--
--  Bump VERSION on every edit and confirm it appears in UE4SS.log after Ctrl+R hot-reload.
--  All output is tagged [RR-Shelf]. The hook is registered late (BP classes load after mod
--  start) via ExecuteWithDelay; the callback runs synchronously on the game thread (CLAUDE.md §7).
-- ============================================================
local VERSION = "shelf-v14"

local Config  = require("config")
local restock = require("restock")

local P = "[RR-Shelf] "
local function log(m) print(P .. tostring(m) .. "\n") end

-- Phase A1: ordered restock. Hook the slot-chooser late (the BP class loads after mod start).
-- The path is the base Shelve_C function confirmed by the recon probe; one hook covers every
-- movie shelf, and restock.onDoesAnyEmpty guards to movie-shelf leaf classes only.
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

log("RR Shelf Keeper loaded (" .. VERSION .. ", Phase A1: ordered restock).")
