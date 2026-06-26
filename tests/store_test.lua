-- tests/store_test.lua — run from repo root:  lua tests/store_test.lua
-- Exercises the PURE serialize/deserialize and the disk save/load round-trip in store.lua.
-- store.resolveDir() self-locates the mod folder via debug.getinfo and needs the running
-- game's file layout, so it is verified in-game (docs/PLAN.md Phase 2), not here.
package.path = package.path .. ";RR Shelf Keeper/Scripts/?.lua"
local store = require("store")

local failures = 0
local function check(name, cond)
    if cond then print("PASS: " .. name)
    else print("FAIL: " .. name); failures = failures + 1 end
end

-- A realistic Phase-2 persist shape: per-shelf durable id + per-slot {index, sku, title};
-- an EMPTY slot is a real recorded value with sku absent (nil), not an omitted slot.
local function sampleSnap()
    return {
        version = 2, key = "Player_Save2",
        shelfCount = 1, totalSlots = 3, totalFilled = 2,
        shelves = {
            {
                id = "g:11-22-33-44", class = "Shelf_Movie_4Row_02_C",
                loc = { x = 1020.0, y = -1610.5, z = 0.0 }, yaw = 90, slotCount = 3, filled = 2,
                slots = {
                    { index = 1, sku = 1532223, title = "The Kennel, Our Hero" },
                    { index = 2 },                                  -- empty: sku/title absent
                    { index = 3, sku = 42, title = 'Quote "x" and \\ slash' },
                },
            },
        },
    }
end

-- deep value-equality (treats absent vs nil the same; integer/float compared with ==).
local function deepEq(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return a == b end
    for k, v in pairs(a) do if not deepEq(v, b[k]) then return false end end
    for k, v in pairs(b) do if a[k] == nil and v ~= nil then return false end end
    return true
end

-- round-trip: deserialize(serialize(t)) deep-equals t
do
    local t = sampleSnap()
    local s = store.serialize(t)
    check("serialize returns a string", type(s) == "string" and #s > 0)
    local back, err = store.deserialize(s)
    check("deserialize returns a table", type(back) == "table")
    check("round-trip preserves the snapshot", deepEq(t, back))
end

-- idempotent: serialize(deserialize(serialize(t))) == serialize(t)
do
    local s1 = store.serialize(sampleSnap())
    local s2 = store.serialize(store.deserialize(s1))
    check("serialize is idempotent across a round-trip", s1 == s2)
end

-- integers stay integers (no "1532223.0" — SKUs must read back clean)
do
    local s = store.serialize(sampleSnap())
    check("integer SKU has no decimal point", s:find("1532223", 1, true) ~= nil
        and s:find("1532223.0", 1, true) == nil)
end

-- empty slot survives as {index=N} with no sku
do
    local back = store.deserialize(store.serialize(sampleSnap()))
    local slot2 = back.shelves[1].slots[2]
    check("empty slot keeps its index", slot2 and slot2.index == 2)
    check("empty slot has nil sku", slot2 and slot2.sku == nil)
end

-- string escaping: quotes + backslashes round-trip exactly
do
    local back = store.deserialize(store.serialize(sampleSnap()))
    check("escaped string round-trips", back.shelves[1].slots[3].title == 'Quote "x" and \\ slash')
end

-- bad input never throws: returns nil + error
do
    local r1, e1 = store.deserialize("this is not lua {{{")
    check("garbage deserialize -> nil + err", r1 == nil and type(e1) == "string")
    local r2, e2 = store.deserialize("")
    check("empty deserialize -> nil + err", r2 == nil and type(e2) == "string")
    local r3 = store.deserialize("return 5")            -- valid lua, not a table
    check("non-table chunk -> nil", r3 == nil)
end

-- sandbox: a malicious file body cannot reach globals (os/io are nil in the load env)
do
    local r, e = store.deserialize("return os.time()")
    check("deserialize body cannot call os.* (sandboxed) -> nil + err", r == nil and type(e) == "string")
end

-- pathFor joins dir + key + .lua
do
    local p = store.pathFor("BASEDIR", "Player_Save2")
    check("pathFor contains the base dir", p:find("BASEDIR", 1, true) ~= nil)
    check("pathFor ends in <key>.lua", p:match("Player_Save2%.lua$") ~= nil)
end

-- save() then load() round-trips through a real file on disk
do
    local tmp = "tests/_tmp_store_out.lua"
    local ok, serr = store.save(tmp, sampleSnap())
    check("save writes a file (ok)", ok == true and serr == nil)
    local back, lerr = store.load(tmp)
    check("load reads it back", type(back) == "table" and lerr == nil)
    check("disk round-trip preserves snapshot", deepEq(sampleSnap(), back))
    os.remove(tmp)
    local miss, merr = store.load("tests/_does_not_exist_.lua")
    check("load of a missing file -> nil + err (no crash)", miss == nil and type(merr) == "string")
end

print(string.format("\n%s", failures == 0 and "ALL PASS" or (failures .. " FAILURE(S)")))
os.exit(failures == 0 and 0 or 1)
