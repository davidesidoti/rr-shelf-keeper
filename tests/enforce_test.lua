-- tests/enforce_test.lua — run from repo root:  lua tests/enforce_test.lua
-- Exercises the PURE decision logic in enforce.lua (diff + plan). The mutation path
-- (apply / the BP move primitive) needs the running game and is validated in-game per
-- docs/PLAN.md Phase 3.
--
-- Shape conventions (mirror the rest of the mod):
--   saved   = the persisted layout (store.load shape): shelves[].id is the durable key,
--             slots[] = { index, sku? } (sku absent = the slot should be EMPTY).
--   current = a live snapshot (layout.snapshot shape): shelves[].durableId is the key,
--             slots[] = { index, sku? }.
-- diff/plan match shelves by key = (durableId or id), and per slot by index.
package.path = package.path .. ";RR Shelf Keeper/Scripts/?.lua"
local enforce = require("enforce")

local failures = 0
local function check(name, cond)
    if cond then print("PASS: " .. name)
    else print("FAIL: " .. name); failures = failures + 1 end
end

-- Build a persisted (saved) shelf. slotMap = { [index] = sku|nil }; nil sku = empty slot.
local function savedShelf(key, slotCount, slotMap)
    local slots = {}
    for i = 1, slotCount do
        local rec = { index = i }
        if slotMap[i] then rec.sku = slotMap[i] end
        slots[i] = rec
    end
    return { id = key, class = "Shelf_Movie_4Row_02_C", slotCount = slotCount, slots = slots }
end

-- Build a live (current) shelf — same as saved but keyed on durableId.
local function liveShelf(key, slotCount, slotMap)
    local sh = savedShelf(key, slotCount, slotMap)
    sh.id = "Shelf_Movie_4Row_02_C_123"   -- a GetFName-style session id (ignored by diff/plan)
    sh.durableId = key
    return sh
end

local function saved(shelves)  return { version = 2, shelves = shelves } end
local function current(shelves) return { shelves = shelves } end

-- ===================== diff =====================

-- Identical layouts → no mismatches.
do
    local s = saved({ savedShelf("l:1", 3, { [1] = 10, [2] = 20 }) })
    local c = current({ liveShelf("l:1", 3, { [1] = 10, [2] = 20 }) })
    local d = enforce.diff(s, c)
    check("diff identical → 0 mismatches", d.totalMismatches == 0)
    check("diff identical → 1 matched shelf", d.matched == 1)
    check("diff identical → 0 missing", #d.missing == 0)
end

-- A changed SKU is reported with want+have.
do
    local s = saved({ savedShelf("l:1", 3, { [1] = 10, [2] = 20 }) })
    local c = current({ liveShelf("l:1", 3, { [1] = 10, [2] = 99 }) })   -- slot 2 wrong
    local d = enforce.diff(s, c)
    check("diff changed sku → 1 mismatch", d.totalMismatches == 1)
    local m = d.mismatches[1].slots[1]
    check("diff reports the slot index", m.index == 2)
    check("diff reports want+have", m.want == 20 and m.have == 99)
end

-- Slot should be empty but is filled.
do
    local s = saved({ savedShelf("l:1", 2, { [1] = 10 }) })             -- slot 2 should be empty
    local c = current({ liveShelf("l:1", 2, { [1] = 10, [2] = 77 }) })  -- slot 2 filled
    local d = enforce.diff(s, c)
    check("diff should-be-empty filled → mismatch want nil have 77",
        d.totalMismatches == 1 and d.mismatches[1].slots[1].want == nil
        and d.mismatches[1].slots[1].have == 77)
end

-- Slot should be filled but is empty.
do
    local s = saved({ savedShelf("l:1", 2, { [1] = 10, [2] = 20 }) })
    local c = current({ liveShelf("l:1", 2, { [1] = 10 }) })            -- slot 2 empty
    local d = enforce.diff(s, c)
    check("diff should-be-filled empty → mismatch want 20 have nil",
        d.totalMismatches == 1 and d.mismatches[1].slots[1].want == 20
        and d.mismatches[1].slots[1].have == nil)
end

-- A saved shelf with no live counterpart is reported as missing, not a crash.
do
    local s = saved({ savedShelf("l:1", 1, { [1] = 10 }), savedShelf("l:GONE", 1, { [1] = 5 }) })
    local c = current({ liveShelf("l:1", 1, { [1] = 10 }) })
    local d = enforce.diff(s, c)
    check("diff missing shelf listed", #d.missing == 1 and d.missing[1] == "l:GONE")
    check("diff missing shelf doesn't add a mismatch", d.totalMismatches == 0)
    check("diff matched counts only paired shelves", d.matched == 1)
end

-- A live shelf not in the saved layout is ignored (unmanaged / newly placed).
do
    local s = saved({ savedShelf("l:1", 1, { [1] = 10 }) })
    local c = current({ liveShelf("l:1", 1, { [1] = 10 }), liveShelf("l:NEW", 1, { [1] = 8 }) })
    local d = enforce.diff(s, c)
    check("diff ignores unmanaged live shelf", d.totalMismatches == 0 and d.matched == 1)
end

-- ===================== plan =====================

-- A pure two-slot swap → two moves, nothing unfulfillable, nothing surplus.
do
    local s = saved({ savedShelf("l:1", 2, { [1] = 10, [2] = 20 }) })
    local c = current({ liveShelf("l:1", 2, { [1] = 20, [2] = 10 }) })   -- swapped
    local p = enforce.plan(s, c)
    check("plan swap → 2 moves", p.totalMoves == 2)
    check("plan swap → 0 unfulfillable", p.totalUnfulfillable == 0)
    check("plan swap → 0 surplus", p.totalSurplus == 0)
    -- every target ends up satisfied: slot 1 gets a 10 from slot 2, slot 2 gets a 20 from slot 1
    local moves = p.shelves[1].moves
    local bySku = {}
    for _, mv in ipairs(moves) do bySku[mv.sku] = mv end
    check("plan swap moves 10 into slot 1", bySku[10] and bySku[10].to == 1 and bySku[10].from == 2)
    check("plan swap moves 20 into slot 2", bySku[20] and bySku[20].to == 2 and bySku[20].from == 1)
end

-- A single relocation: slot 1 empty wants 10, slot 2 holds the 10 (and should be empty).
do
    local s = saved({ savedShelf("l:1", 2, { [1] = 10 }) })            -- slot1 wants 10, slot2 empty
    local c = current({ liveShelf("l:1", 2, { [2] = 10 }) })          -- 10 sits in slot2
    local p = enforce.plan(s, c)
    check("plan relocate → 1 move", p.totalMoves == 1)
    check("plan relocate from 2 to 1", p.shelves[1].moves[1].from == 2 and p.shelves[1].moves[1].to == 1)
    check("plan relocate → 0 unfulfillable / surplus",
        p.totalUnfulfillable == 0 and p.totalSurplus == 0)
end

-- Unfulfillable: slot wants a SKU that exists nowhere on the shelf.
do
    local s = saved({ savedShelf("l:1", 1, { [1] = 10 }) })           -- wants 10
    local c = current({ liveShelf("l:1", 1, { [1] = 99 }) })          -- only a 99 present
    local p = enforce.plan(s, c)
    check("plan unfulfillable wanted sku", p.totalUnfulfillable == 1
        and p.shelves[1].unfulfillable[1].wantSku == 10
        and p.shelves[1].unfulfillable[1].to == 1)
    -- the loose 99 has nowhere correct to go; it is left in its own slot (no move emitted)
    check("plan leaves the loose surplus in place (no move)", p.totalMoves == 0)
end

-- Surplus that must vacate a target slot is relocated (not orphaned): slot1 wants 10 and a 10
-- is available in slot2; slot1 currently holds a 50 that is wanted nowhere → it gets re-placed
-- into the freed slot2 rather than dropped.
do
    local s = saved({ savedShelf("l:1", 2, { [1] = 10 }) })            -- slot1 wants 10, slot2 empty
    local c = current({ liveShelf("l:1", 2, { [1] = 50, [2] = 10 }) }) -- 50 blocks slot1, 10 in slot2
    local p = enforce.plan(s, c)
    -- 10 must move 2→1; the displaced 50 must land somewhere (slot2) so nothing is orphaned.
    local toSlot1, surplusPlaced = nil, false
    for _, mv in ipairs(p.shelves[1].moves) do
        if mv.to == 1 then toSlot1 = mv.sku end
        if mv.surplus then surplusPlaced = true end
    end
    check("plan fills slot1 with the 10", toSlot1 == 10)
    check("plan re-places the displaced 50 (1 surplus)", p.totalSurplus == 1 and surplusPlaced)
    check("plan → 0 unfulfillable", p.totalUnfulfillable == 0)
    -- every collected cassette is accounted for (no orphan floating actor)
    check("plan emits a move per displaced cassette", p.totalMoves == 2)
end

-- Already-correct slots are never touched (no move references a satisfied slot).
do
    local s = saved({ savedShelf("l:1", 3, { [1] = 10, [2] = 20, [3] = 30 }) })
    local c = current({ liveShelf("l:1", 3, { [1] = 10, [2] = 30, [3] = 20 }) })  -- 2&3 swapped, 1 ok
    local p = enforce.plan(s, c)
    for _, mv in ipairs(p.shelves[1].moves) do
        check("plan never moves into/out of the satisfied slot 1", mv.to ~= 1 and mv.from ~= 1)
    end
    check("plan swaps only 2 and 3", p.totalMoves == 2 and p.totalUnfulfillable == 0)
end

-- Empty store / empty layout → no moves, no crash.
do
    local p = enforce.plan(saved({}), current({}))
    check("plan empty → 0 moves", p.totalMoves == 0 and p.matched == 0)
end

print(string.format("\n%s", failures == 0 and "ALL PASS" or (failures .. " FAILURE(S)")))
os.exit(failures == 0 and 0 or 1)
