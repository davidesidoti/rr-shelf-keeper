-- tests/layout_test.lua — run from repo root:  lua tests/layout_test.lua
-- Exercises the PURE helpers in layout.lua (shelfId, format). snapshot() needs the running
-- game (FindAllOf / ExecuteInGameThread) and is verified in-game per docs/PLAN.md Phase 1.
package.path = package.path .. ";RR Shelf Keeper/Scripts/?.lua"
local layout = require("layout")

local failures = 0
local function check(name, cond)
    if cond then print("PASS: " .. name)
    else print("FAIL: " .. name); failures = failures + 1 end
end

-- shelfId: class-prefixed, rounded world location; restart-stable.
do
    check("shelfId rounds half-up",
        layout.shelfId("Shelf_X", { x = 1234.4, y = -1530.6, z = 92.5 }) == "Shelf_X@1234,-1531,93")
    check("shelfId integer loc",
        layout.shelfId("Shelf_Movie_4Row_02_C", { x = 10, y = 20, z = 30 })
            == "Shelf_Movie_4Row_02_C@10,20,30")
    check("shelfId nil loc -> @?", layout.shelfId("Shelf_X", nil) == "Shelf_X@?")
    check("shelfId nil class tolerated", layout.shelfId(nil, nil) == "?@?")
end

-- format: header counts + per-slot lines (filled vs empty).
do
    local snap = {
        shelfCount = 1, totalSlots = 3, totalFilled = 2,
        shelves = {
            {
                id = "Shelf_Movie_4Row_02_C_42", class = "Shelf_Movie_4Row_02_C",
                loc = { x = 10, y = 20, z = 30 }, yaw = 90, slotCount = 3, filled = 2,
                slots = {
                    { index = 1, sku = 1532223, title = "The Kennel, Our Hero" },
                    { index = 2, sku = nil,     title = nil },                    -- empty
                    { index = 3, sku = 42,      title = nil },                    -- filled, unknown title
                },
            },
        },
    }
    local lines = layout.format(snap)
    local blob = table.concat(lines, "\n")
    check("format header counts",
        blob:find("shelves: 1 | slots: 3 | filled: 2 | empty: 1", 1, true) ~= nil)
    check("format shelf header has class+loc+yaw+id",
        blob:find("Shelf_Movie_4Row_02_C @ (10, 20, 30) yaw 90", 1, true) ~= nil
        and blob:find("id=Shelf_Movie_4Row_02_C_42", 1, true) ~= nil)
    check("format filled slot shows title + SKU",
        blob:find('slot  1: "The Kennel, Our Hero" (SKU 1532223)', 1, true) ~= nil)
    check("format empty slot marked", blob:find("slot  2: <empty>", 1, true) ~= nil)
    check("format unknown title shows ?", blob:find('slot  3: "?" (SKU 42)', 1, true) ~= nil)
end

-- format: empty snapshot is still well-formed (zero shelves).
do
    local lines = layout.format({ shelfCount = 0, totalSlots = 0, totalFilled = 0, shelves = {} })
    check("format empty snapshot",
        table.concat(lines, "\n"):find("shelves: 0 | slots: 0 | filled: 0 | empty: 0", 1, true) ~= nil)
end

-- durableShelfId (Phase 2): the restart-DURABLE per-shelf key. GUID Shelf ints win; if the
-- GUID can't be read we fall back to loc+yaw (itself durable for static actors, and unique
-- because co-located shelf pairs differ ~180° in yaw — Phase 1 finding).
do
    check("durableId from GUID ints -> g:a-b-c-d",
        layout.durableShelfId({ 11, 22, 33, 44 }, { x = 1, y = 2, z = 3 }, 90) == "g:11-22-33-44")
    check("durableId no GUID -> rounded loc+yaw",
        layout.durableShelfId(nil, { x = 1020.4, y = -1610.6, z = 0 }, 90.5) == "l:1020,-1611,0,91")
    check("durableId empty GUID list -> loc+yaw fallback",
        layout.durableShelfId({}, { x = 1, y = 2, z = 3 }, -90) == "l:1,2,3,-90")
end

-- countDurableCollisions (Phase 2 safety check): the loc+yaw keys must be unique across shelves.
-- A co-located pair that genuinely differs in yaw is NOT a collision; identical keys are.
do
    check("no collisions when all durable keys differ",
        layout.countDurableCollisions({
            { durableId = "l:1020,-1350,0,90" },
            { durableId = "l:1020,-1350,0,-90" },   -- same loc, opposite yaw = the double-sided pair
            { durableId = "l:0,0,0,0" },
        }) == 0)
    check("one collision when two shelves share a durable key",
        layout.countDurableCollisions({
            { durableId = "l:1020,-1350,0,90" },
            { durableId = "l:1020,-1350,0,90" },     -- identical -> collision
            { durableId = "l:7,7,7,7" },
        }) == 1)
    check("empty shelf list -> 0 collisions", layout.countDurableCollisions({}) == 0)
end

-- format: the durable-key safety line (collisions == 0 clean; > 0 flagged loudly).
do
    local clean = layout.format({
        shelfCount = 2, totalSlots = 0, totalFilled = 0, durableCollisions = 0, shelves = {},
    })
    check("format shows clean durable-key line",
        table.concat(clean, "\n"):find("durable keys (loc+yaw): 2 shelves, 0 collision(s)", 1, true) ~= nil)
    local bad = table.concat(layout.format({
        shelfCount = 2, totalSlots = 0, totalFilled = 0, durableCollisions = 1, shelves = {},
    }), "\n")
    check("format flags a collision loudly",
        bad:find("1 collision(s)", 1, true) ~= nil and bad:find("MUST be 0", 1, true) ~= nil)
end

-- toPersist (Phase 2): project a live snapshot to the focused on-disk shape — keyed by the
-- durable id, empty slot keeps its index but drops sku — and it stays format()-compatible so
-- save and load log identical lines.
do
    local snap = {
        shelfCount = 1, totalSlots = 2, totalFilled = 1,
        shelves = {
            {
                id = "Shelf_Movie_4Row_02_C_42", durableId = "g:1-2-3-4",
                class = "Shelf_Movie_4Row_02_C", loc = { x = 10, y = 20, z = 30 }, yaw = 90,
                slotCount = 2, filled = 1,
                slots = {
                    { index = 1, sku = 1532223, title = "The Kennel, Our Hero" },
                    { index = 2, sku = nil, title = nil },
                },
            },
        },
    }
    local p = layout.toPersist(snap, "Player_Save2")
    check("toPersist carries the file key", p.key == "Player_Save2")
    check("toPersist tags the format version", p.version == 2)
    check("toPersist keys the shelf by durableId", p.shelves[1].id == "g:1-2-3-4")
    check("toPersist keeps filled slot sku+title",
        p.shelves[1].slots[1].sku == 1532223
        and p.shelves[1].slots[1].title == "The Kennel, Our Hero")
    check("toPersist empty slot keeps index, drops sku",
        p.shelves[1].slots[2].index == 2 and p.shelves[1].slots[2].sku == nil)
    local blob = table.concat(layout.format(p), "\n")
    check("persist shape renders via format() with the durable id",
        blob:find("id=g:1-2-3-4", 1, true) ~= nil
        and blob:find('slot  1: "The Kennel, Our Hero" (SKU 1532223)', 1, true) ~= nil
        and blob:find("slot  2: <empty>", 1, true) ~= nil)
end

print(string.format("\n%s", failures == 0 and "ALL PASS" or (failures .. " FAILURE(S)")))
os.exit(failures == 0 and 0 or 1)
