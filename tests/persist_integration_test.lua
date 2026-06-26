-- tests/persist_integration_test.lua — run from repo root:
--   lua tests/persist_integration_test.lua
-- Offline proxy for the in-game Phase-2 round-trip ("the logged layout matches what was
-- saved"): build a fake LIVE snapshot, run the exact main.lua data path
--   layout.toPersist -> store.save -> store.load -> layout.format
-- and assert the saved log and the loaded log are byte-identical. Uses a temp file on disk;
-- no game globals are touched (snapshot() itself needs the game and is verified in-game).
package.path = package.path .. ";RR Shelf Keeper/Scripts/?.lua"
local layout = require("layout")
local store  = require("store")

local failures = 0
local function check(name, cond)
    if cond then print("PASS: " .. name)
    else print("FAIL: " .. name); failures = failures + 1 end
end

-- A fake live snapshot shaped like layout.snapshot()'s output: a co-located double-sided PAIR
-- (same loc, opposite yaw → distinct loc+yaw durable keys); filled + empty slots; awkward title.
local live = {
    shelfCount = 2, totalSlots = 4, totalFilled = 2, durableCollisions = 0,
    shelves = {
        {
            id = "Shelf_Movie_4Row_01_C_2147476245", durableId = "l:1020,-1610,0,90",
            class = "Shelf_Movie_4Row_01_C",
            loc = { x = 1020.0, y = -1610.0, z = 0.0 }, yaw = 90, slotCount = 2, filled = 1,
            slots = {
                { index = 1, sku = 1532223, title = 'The Kennel, "Our Hero"' },
                { index = 2 },
            },
        },
        {
            id = "Shelf_Movie_4Row_01_C_2147476246", durableId = "l:1020,-1610,0,-90",
            class = "Shelf_Movie_4Row_01_C",
            loc = { x = 1020.0, y = -1610.0, z = 0.0 }, yaw = -90, slotCount = 2, filled = 1,
            slots = {
                { index = 1, sku = 42, title = nil },
                { index = 2 },
            },
        },
    },
}

local persist = layout.toPersist(live, "Player_Save2")
local savedLog = table.concat(layout.format(persist), "\n")

local tmp = "tests/_tmp_persist_int.lua"
local ok = store.save(tmp, persist)
check("pipeline save succeeds", ok == true)

local loaded = store.load(tmp)
os.remove(tmp)
check("pipeline load returns a table", type(loaded) == "table")

local loadedLog = table.concat(layout.format(loaded), "\n")
check("saved log == loaded log (in-game round-trip criterion)", savedLog == loadedLog)

-- spot-check both members of the co-located pair keep distinct durable keys through the round-trip
check("front-rack durable key survives", loadedLog:find("id=l:1020,-1610,0,90", 1, true) ~= nil)
check("back-rack durable key survives", loadedLog:find("id=l:1020,-1610,0,-90", 1, true) ~= nil)
check("empty slot rendered after round-trip", loadedLog:find("slot  2: <empty>", 1, true) ~= nil)
check("awkward title (embedded quotes) survives", loadedLog:find('The Kennel, "Our Hero"', 1, true) ~= nil)

print(string.format("\n%s", failures == 0 and "ALL PASS" or (failures .. " FAILURE(S)")))
os.exit(failures == 0 and 0 or 1)
