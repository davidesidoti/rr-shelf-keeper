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

print(string.format("\n%s", failures == 0 and "ALL PASS" or (failures .. " FAILURE(S)")))
os.exit(failures == 0 and 0 or 1)
