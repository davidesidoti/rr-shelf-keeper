-- RR Shelf Keeper — layout snapshot (Phase 1 read/log + Phase 2 durable keying & persist shape).
-- No shelf mutation here; disk I/O lives in store.lua. Pure helpers (shelfId, durableShelfId,
-- toPersist, format, round) are unit-tested in tests/layout_test + tests/persist_integration.
--
-- Slot identity = the "All Selve Containers" array index (Phase 0 §6.3: stable per shelf
-- class, even though it is NOT a clean left→right/top→bottom physical sweep — physical
-- ordering is computed from world transforms later, in Phase 5). Empty slot = no cassette.
--
-- Two shelf identities are tracked:
--   • id        = GetFName (e.g. Shelf_Movie_4Row_01_C_42) — unique + stable WITHIN a session,
--                 but renumbers across restarts (shelves are runtime-spawned from the save), so
--                 it is a diagnostic id only.
--   • durableId = the cross-restart key the persist file is keyed on (Phase 2) = rounded
--                 loc+yaw ("l:x,y,z,yaw"): durable (static actor) and unique (co-located
--                 double-sided shelf PAIRS share a location but differ ~180° in yaw).
--                 The serialized "GUID Shelf" would be ideal, but reading it via live struct
--                 reflection NATIVE-CRASHED this build (CLAUDE.md §7) — deferred to the probe.
local sku = require("sku")
local M = {}

-- Movie-shelf leaf classes (Phase 0 §6.1). There is no single MovieShelf_C: ~18 leaves all
-- derive from base Shelve_C, which is ALSO the snack/concession shelf base — so we enumerate
-- the known movie leaves explicitly rather than FindAllOf("Shelve_C") (which would sweep in
-- non-movie shelves). FindAllOf matches an exact leaf class, so we union all of these.
local MOVIE_SHELF_CLASSES = {
    "Shelf_Movie_4Row_01_C", "Shelf_Movie_4Row_02_C", "Shelf_Movie_4Row_03_C",
    "Shelf_Movie_5Row_01_C", "Shelf_Movie_5Row_02_C",
    "Shelf_Movie_6Row_01_C", "Shelf_Movie_6Row_02_C",
    "Shelf_NewMovie_4Row_02_C", "Shelf_NewMovie_5Row_02_C", "Shelf_NewMovie_6Row_02_C",
    "Shelf_Movie-Display_4Row_01_C", "Shelf_Movie-Display_5Row_01_C", "Shelf_Movie-Display_6Row_01_C",
    "Shelf_Movie-Display_WallMounted_01_C", "Shelf_Movie-Display_Base_C",
    "Shelf_Movie-Shelf_MovieDisplay_Unit_01_C", "Shelf_Movie-Shelf_MovieDisplay_Cabinet_01_C",
    "MovieDisplay_C",
}
M.MOVIE_SHELF_CLASSES = MOVIE_SHELF_CLASSES   -- reused by restock.lua's managed-shelf guard

-- Slot model (Phase 0 §6.2). Note the in-game typo "Selve". Exported on M so enforce.lua reuses
-- the exact same field names (no drift) for the mutation pass.
local CONTAINER_ARRAY_KEY = "All Selve Containers"            -- TArray<Shelve_Container_C>
local OWNED_OBJECT_KEY    = "Object owning of this container" -- ObjectProperty -> videotape_C or empty
M.CONTAINER_ARRAY_KEY = CONTAINER_ARRAY_KEY
M.OWNED_OBJECT_KEY    = OWNED_OBJECT_KEY

-- ---- pure helpers (no game state; unit-tested) --------------------------------------------

local function round(n) return math.floor((n or 0) + 0.5) end

-- Legacy class@loc id — kept only as the diagnostic `id` fallback when GetFName is unreadable.
-- NOT a persistence key: Phase 1 found co-located double-sided pairs share a location, so this
-- is not unique. The durable persistence key is durableShelfId() below (GUID, or loc+YAW).
function M.shelfId(class, loc)
    local c = class or "?"
    if not loc then return c .. "@?" end
    return string.format("%s@%d,%d,%d", c, round(loc.x), round(loc.y), round(loc.z))
end

-- Restart-durable per-shelf key (Phase 2). Currently keyed on rounded world transform + yaw
-- ("l:x,y,z,yaw"): durable for a static placed actor, and unique because co-located double-sided
-- shelf pairs differ ~180° in yaw (Phase 1). snapshot() asserts uniqueness via a collision count.
--   The game's serialized "GUID Shelf" would be the ideal key, BUT reading it via live struct
--   reflection NATIVE-CRASHES this build (pcall-uncatchable; see CLAUDE.md §7) — so it is NOT
--   read here. The "g:a-b-c-d" branch is retained for a future SAFE GUID source (e.g. a BP
--   accessor validated in the probe); pass guidInts only once such a source is proven.
function M.durableShelfId(guidInts, loc, yaw)
    if guidInts and #guidInts > 0 then
        return "g:" .. table.concat(guidInts, "-")
    end
    local x = loc and round(loc.x) or 0
    local y = loc and round(loc.y) or 0
    local z = loc and round(loc.z) or 0
    return string.format("l:%d,%d,%d,%d", x, y, z, round(yaw or 0))
end

-- Count shelves that share a durable key (Phase 2 safety check). MUST be 0 — a collision means
-- two physical shelves map to the same persisted slot set, which would corrupt Phase 3
-- enforcement. Pure (unit-tested); snapshot() runs it and format() reports the result.
function M.countDurableCollisions(shelves)
    local seen, collisions = {}, 0
    for _, sh in ipairs(shelves or {}) do
        local k = sh.durableId
        if k ~= nil then
            if seen[k] then collisions = collisions + 1 else seen[k] = true end
        end
    end
    return collisions
end

-- Project a live snapshot to the focused on-disk shape (Phase 2). Keyed by the durable id; each
-- slot keeps its index, a filled slot also keeps sku (+ title for readable files), an empty slot
-- is recorded as just { index = N } (a real, intentional value — slot exists, no cassette). The
-- result is format()-compatible so `save` and `load` log byte-identical layout lines.
function M.toPersist(snap, key)
    local p = {
        version    = 2,
        key        = key,
        shelfCount = snap.shelfCount,
        totalSlots = snap.totalSlots,
        totalFilled = snap.totalFilled,
        shelves    = {},
    }
    for i, sh in ipairs(snap.shelves) do
        local ps = {
            id = sh.durableId or sh.id, class = sh.class, loc = sh.loc, yaw = sh.yaw,
            slotCount = sh.slotCount, filled = sh.filled, slots = {},
        }
        for j, slot in ipairs(sh.slots) do
            local rec = { index = slot.index }
            if slot.sku then rec.sku = slot.sku; rec.title = slot.title end
            ps.slots[j] = rec
        end
        p.shelves[i] = ps
    end
    return p
end

-- Render an in-memory snapshot as an array of log lines (caller adds its tag/prefix).
function M.format(snap)
    local out = {}
    local function add(s) out[#out + 1] = s end
    add("=== RR Shelf Keeper — layout snapshot ===")
    local empty = snap.totalSlots - snap.totalFilled
    add(string.format("shelves: %d | slots: %d | filled: %d | empty: %d",
        snap.shelfCount, snap.totalSlots, snap.totalFilled, empty))
    if snap.key then add("save key: " .. tostring(snap.key)) end
    -- durable-key safety line (live snapshot only; absent on the on-disk shape)
    if snap.durableCollisions ~= nil then
        add(string.format("durable keys (loc+yaw): %d shelves, %d collision(s)%s",
            snap.shelfCount, snap.durableCollisions,
            snap.durableCollisions > 0 and "  <-- MUST be 0; investigate before trusting" or ""))
    end
    for si, sh in ipairs(snap.shelves) do
        local lx, ly, lz = "?", "?", "?"
        if sh.loc then lx, ly, lz = round(sh.loc.x), round(sh.loc.y), round(sh.loc.z) end
        local yaw = sh.yaw and round(sh.yaw) or "?"
        local durable = sh.durableId and ("  durable=" .. sh.durableId) or ""
        add(string.format("--- [%d] %s @ (%s, %s, %s) yaw %s  filled %d/%d  id=%s%s",
            si, sh.class, tostring(lx), tostring(ly), tostring(lz), tostring(yaw),
            sh.filled, sh.slotCount, sh.id, durable))
        for _, slot in ipairs(sh.slots) do
            if slot.sku then
                add(string.format("  slot %2d: \"%s\" (SKU %s)",
                    slot.index, slot.title or "?", tostring(slot.sku)))
            else
                add(string.format("  slot %2d: <empty>", slot.index))
            end
        end
    end
    return out
end

-- ---- game-state readers (integration; require the running game) ---------------------------

local function getLoc(actor)
    local loc
    if pcall(function() loc = actor:K2_GetActorLocation() end) and loc then
        return { x = loc.X, y = loc.Y, z = loc.Z }
    end
    return nil
end

-- Actor yaw (degrees), or nil. Used to tell co-located shelf pairs apart (front vs back of a
-- double-sided shelf differ by ~180°) — diagnostic for choosing the Phase 2 persistence key.
local function getYaw(actor)
    local yaw
    pcall(function() yaw = actor:K2_GetActorRotation().Yaw end)
    return yaw
end

-- NOTE: a reflective GUID Shelf reader once lived here (read the "GUID Shelf" struct's int
-- fields via StructProperty:GetStruct()/struct-value indexing). It NATIVE-CRASHED this build
-- (pcall could not catch it — the whole snapshot aborted with no output; UE4SS.log shelf-v3
-- run, 2026-06-26). Removed. The durable key is loc+yaw (durableShelfId); a safe GUID source is
-- deferred to the read-only probe. See CLAUDE.md §7 "GUID Shelf reflection native-crashes".

-- Read a UE4SS TArray into a plain Lua array { [1..n] = element }. Prefers GetArrayNum + [i]
-- (works for these BP arrays per the snack mod); falls back to ForEach with a running counter
-- (ForEach index base is left to UE4SS — we don't rely on it). Returns elems, count.
local function arrayElems(arr)
    local out = {}
    if not arr then return out, 0 end
    local n
    pcall(function() n = arr:GetArrayNum() end)
    if type(n) == "number" and n > 0 then
        for i = 1, n do
            local el; pcall(function() el = arr[i] end)
            out[i] = el
        end
        return out, n
    end
    local i = 0
    pcall(function()
        arr:ForEach(function(_, e)
            i = i + 1
            local el; pcall(function() el = e:get() end)
            out[i] = el
        end)
    end)
    return out, i
end

-- One slot -> { index, sku, title, container }. Empty slot (no/invalid cassette) -> sku/title nil.
-- `container` is the live Shelve_Container_C ref (runtime-only; Phase 3 enforcement mutates through
-- it). toPersist/format ignore it, so it never reaches disk.
local function readSlot(container, index)
    local rec = { index = index, sku = nil, title = nil, container = container }
    if not container then return rec end
    local cart
    pcall(function() cart = container[OWNED_OBJECT_KEY] end)
    if sku.isCartridge(cart) then
        local s = sku.read(cart)
        if s then
            rec.sku = s
            rec.title = sku.readTitle(cart)
        end
    end
    return rec
end

-- One shelf -> { id, class, name, loc, yaw, slots[], slotCount, filled }.
local function readShelf(shelf)
    local class = "?"
    pcall(function() class = shelf:GetClass():GetFName():ToString() end)
    local name
    pcall(function() name = shelf:GetFullName() end)
    local loc = getLoc(shelf)
    local yaw = getYaw(shelf)

    -- Unique per-instance id = the actor's own object name; fall back to class@loc only if
    -- GetFName is unreadable (loc is NOT unique — co-located pairs collide; see header comment).
    local objName
    pcall(function() objName = shelf:GetFName():ToString() end)
    local id = (objName and objName ~= "") and objName or M.shelfId(class, loc)

    -- Restart-durable key (Phase 2) = loc+yaw (only proven-safe reads; no native-crashing GUID
    -- reflection). snapshot() verifies these are collision-free across all shelves.
    local durableId = M.durableShelfId(nil, loc, yaw)

    local rec = {
        id = id, durableId = durableId,
        class = class, name = name, loc = loc, yaw = yaw,
        obj = shelf,                                   -- live ref (runtime-only; ignored by persist)
        slots = {}, slotCount = 0, filled = 0,
    }

    local arr
    pcall(function() arr = shelf[CONTAINER_ARRAY_KEY] end)
    local elems, n = arrayElems(arr)
    rec.slotCount = n
    for i = 1, n do
        local slot = readSlot(elems[i], i)
        rec.slots[i] = slot
        if slot.sku then rec.filled = rec.filled + 1 end
    end
    return rec
end

-- Enumerate all movie shelves -> in-memory snapshot. Pure of side effects (reads only).
-- Shelves sorted by id for stable, repeatable output (re-pressing yields an identical dump).
function M.snapshot()
    local snap = { shelves = {}, shelfCount = 0, totalSlots = 0, totalFilled = 0 }
    local seen = {}
    for _, class in ipairs(MOVIE_SHELF_CLASSES) do
        local insts = FindAllOf(class)
        if insts then
            for _, shelf in ipairs(insts) do
                local valid = false
                local key
                pcall(function()
                    key = shelf:GetFullName()
                    valid = shelf:IsValid() and not (key and key:find("Default__"))
                end)
                if valid and key and not seen[key] then
                    seen[key] = true
                    local rec = readShelf(shelf)
                    snap.shelves[#snap.shelves + 1] = rec
                    snap.totalSlots  = snap.totalSlots  + rec.slotCount
                    snap.totalFilled = snap.totalFilled + rec.filled
                end
            end
        end
    end
    snap.shelfCount = #snap.shelves
    -- Sort by world location (keeps co-located pairs adjacent for readability), then by the
    -- unique id as a tiebreak so the order is fully deterministic across re-presses.
    table.sort(snap.shelves, function(a, b)
        local al = a.loc or { x = 0, y = 0, z = 0 }
        local bl = b.loc or { x = 0, y = 0, z = 0 }
        if al.x ~= bl.x then return al.x < bl.x end
        if al.y ~= bl.y then return al.y < bl.y end
        if al.z ~= bl.z then return al.z < bl.z end
        return a.id < b.id
    end)

    -- Durable-key safety check (Phase 2): the loc+yaw keys MUST be collision-free, else two
    -- physical shelves would map to one persisted slot set. Reported by format(); absent on the
    -- on-disk shape (toPersist drops it).
    snap.durableCollisions = M.countDurableCollisions(snap.shelves)
    return snap
end

return M
