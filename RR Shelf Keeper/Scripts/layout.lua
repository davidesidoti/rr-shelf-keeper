-- RR Shelf Keeper — layout snapshot (Phase 1: read + log only, no file I/O, no mutation).
--
-- snapshot() enumerates every movie shelf, reads its ordered slot list, and records
-- slotIndex -> SKU per shelf, returning an in-memory table. format() turns that table into
-- readable log lines. shelfId()/round() are pure helpers (unit-tested in tests/layout_test).
--
-- Slot identity = the "All Selve Containers" array index (Phase 0 §6.3: stable per shelf
-- class, even though it is NOT a clean left→right/top→bottom physical sweep — physical
-- ordering is computed from world transforms later, in Phase 5). Empty slot = no cassette.
--
-- Shelf identity = the actor's own object name (GetFName, e.g. Shelf_Movie_4Row_01_C_42):
-- unique per instance and stable within a session. IMPORTANT (Phase 1 finding): movie shelves
-- come in CO-LOCATED PAIRS (two actors at the same rounded world location, likely the front
-- and back racks of a double-sided shelf — see the yaw logged per shelf), so rounded location
-- alone is NOT a unique key. The durable cross-restart key is the game's own serialized GUID
-- (CLAUDE.md §3 "GUID Shelf" / Shelve_Save.ID); capturing its verbatim field keys is deferred
-- to Phase 2. shelfId(class,loc) is kept only as a fallback when GetFName is unreadable.
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

-- Slot model (Phase 0 §6.2). Note the in-game typo "Selve".
local CONTAINER_ARRAY_KEY = "All Selve Containers"            -- TArray<Shelve_Container_C>
local OWNED_OBJECT_KEY    = "Object owning of this container" -- ObjectProperty -> videotape_C or empty

-- ---- pure helpers (no game state; unit-tested) --------------------------------------------

local function round(n) return math.floor((n or 0) + 0.5) end

-- Stable, restart-durable shelf id. Shelves are static placed actors, so their rounded world
-- location is constant across game loads and unique per shelf — a better Phase-2 persistence
-- key than the object's GetFullName() (whose _N instance suffix is not load-stable). Class is
-- prefixed for readability/disambiguation.
function M.shelfId(class, loc)
    local c = class or "?"
    if not loc then return c .. "@?" end
    return string.format("%s@%d,%d,%d", c, round(loc.x), round(loc.y), round(loc.z))
end

-- Render an in-memory snapshot as an array of log lines (caller adds its tag/prefix).
function M.format(snap)
    local out = {}
    local function add(s) out[#out + 1] = s end
    add("=== RR Shelf Keeper — layout snapshot ===")
    local empty = snap.totalSlots - snap.totalFilled
    add(string.format("shelves: %d | slots: %d | filled: %d | empty: %d",
        snap.shelfCount, snap.totalSlots, snap.totalFilled, empty))
    for si, sh in ipairs(snap.shelves) do
        local lx, ly, lz = "?", "?", "?"
        if sh.loc then lx, ly, lz = round(sh.loc.x), round(sh.loc.y), round(sh.loc.z) end
        local yaw = sh.yaw and round(sh.yaw) or "?"
        add(string.format("--- [%d] %s @ (%s, %s, %s) yaw %s  filled %d/%d  id=%s",
            si, sh.class, tostring(lx), tostring(ly), tostring(lz), tostring(yaw),
            sh.filled, sh.slotCount, sh.id))
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

-- One slot -> { index, sku, title }. Empty slot (no/invalid cassette) -> sku/title nil.
local function readSlot(container, index)
    local rec = { index = index, sku = nil, title = nil }
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

    local rec = {
        id = id, class = class, name = name, loc = loc, yaw = yaw,
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
    return snap
end

return M
