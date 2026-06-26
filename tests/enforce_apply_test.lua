-- tests/enforce_apply_test.lua — run from repo root:  lua tests/enforce_apply_test.lua
-- Exercises enforce.apply()'s collect→place ORCHESTRATION offline with fake Shelve_Container_C
-- objects. The real Blueprint move primitive needs the game; here we stub Empty Container /
-- Store Object … / Set Stored … so we can verify the orchestration contract WITHOUT the game:
--   • a cyclic permutation (A↔B) resolves correctly (all sources emptied before any store),
--   • a dry run mutates nothing,
--   • a not-live shelf is skipped, not crashed.
-- This is the offline proxy for the in-game Phase 3 criterion; the arg signature of the real
-- store call is still confirmed in-game (see enforce.reflectSignature / the dry-run log).
package.path = package.path .. ";RR Shelf Keeper/Scripts/?.lua"
local enforce = require("enforce")
local layout  = require("layout")
local OWNED   = layout.OWNED_OBJECT_KEY

local failures = 0
local function check(name, cond)
    if cond then print("PASS: " .. name)
    else print("FAIL: " .. name); failures = failures + 1 end
end

local sink = function() end   -- swallow log lines

-- A fake container: real fields .stored/.calls; the BP function names + the owned-object key are
-- served via __index (apply calls them as container[NAME](...), closing over self). The store closure
-- is CONVENTION-AGNOSTIC: apply probes several UE4SS call forms (the cassette may be arg 1, 2, …),
-- so the fake picks whichever argument is a cassette (a table carrying .sku) and ignores self/bools.
-- This keeps the orchestration test independent of the in-game arg-binding convention.
local function isCassette(a) return type(a) == "table" and a.sku ~= nil end
local function makeContainer(stored)
    local c = { stored = stored, calls = {} }
    return setmetatable(c, { __index = function(self, k)
        if k == OWNED then return self.stored end
        if k == "Empty Container" then
            return function() self.calls[#self.calls + 1] = "empty"; self.stored = nil end
        elseif k == "Store Object From Game Code And No Animation" then
            return function(...)
                self.calls[#self.calls + 1] = "store"
                for _, a in ipairs({ ... }) do
                    if isCassette(a) then self.stored = a; break end
                end
            end
        elseif k == "Set Stored Object to Container Transform" then
            return function() self.calls[#self.calls + 1] = "snap" end
        end
        return nil
    end })
end

local function savedShelf(key, slotCount, slotMap)
    local slots = {}
    for i = 1, slotCount do
        local rec = { index = i }
        if slotMap[i] then rec.sku = slotMap[i] end
        slots[i] = rec
    end
    return { id = key, class = "Shelf", slotCount = slotCount, slots = slots }
end

local function liveShelf(key, slotCount, slotMap, containers)
    local slots = {}
    for i = 1, slotCount do
        local rec = { index = i, container = containers[i] }
        if slotMap[i] then rec.sku = slotMap[i] end
        slots[i] = rec
    end
    return { durableId = key, id = "sess", class = "Shelf", slotCount = slotCount, slots = slots, obj = {} }
end

-- Cyclic swap (A↔B): both source slots must be emptied before either store, or one cassette is
-- overwritten. Verifies the two-pass orchestration.
do
    local cA, cB = { sku = "A" }, { sku = "B" }
    local C1, C2 = makeContainer(cB), makeContainer(cA)   -- live: slot1=B, slot2=A
    local saved   = { shelves = { savedShelf("K", 2, { [1] = "A", [2] = "B" }) } }
    local current = { shelves = { liveShelf("K", 2, { [1] = "B", [2] = "A" }, { C1, C2 }) } }
    local p   = enforce.plan(saved, current)
    local ref = enforce.indexLive(current)
    local stats = enforce.apply(p, ref, sink, false)
    check("swap applies 2 stores", stats.stores == 2)
    check("swap empties both sources", stats.empties == 2)
    check("swap no errors", stats.errors == 0)
    check("swap leaves slot1 holding A", C1.stored == cA)
    check("swap leaves slot2 holding B", C2.stored == cB)
end

-- Dry run: same scramble, dryRun=true → no Empty/Store calls, containers untouched.
do
    local cA, cB = { sku = "A" }, { sku = "B" }
    local C1, C2 = makeContainer(cB), makeContainer(cA)
    local saved   = { shelves = { savedShelf("K", 2, { [1] = "A", [2] = "B" }) } }
    local current = { shelves = { liveShelf("K", 2, { [1] = "B", [2] = "A" }, { C1, C2 }) } }
    local p     = enforce.plan(saved, current)
    local stats = enforce.apply(p, enforce.indexLive(current), sink, true)
    check("dry run plans 2 moves", stats.moves == 2)
    check("dry run does 0 stores / 0 empties", stats.stores == 0 and stats.empties == 0)
    check("dry run touches no container", #C1.calls == 0 and #C2.calls == 0)
    check("dry run leaves cassettes in place", C1.stored == cB and C2.stored == cA)
end

-- Relocate into an originally-empty destination slot.
do
    local cA = { sku = "A" }
    local C1, C2 = makeContainer(nil), makeContainer(cA)   -- slot1 empty, slot2 holds A
    local saved   = { shelves = { savedShelf("K", 2, { [1] = "A" }) } }  -- slot1 wants A, slot2 empty
    local current = { shelves = { liveShelf("K", 2, { [2] = "A" }, { C1, C2 }) } }
    local stats = enforce.apply(enforce.plan(saved, current), enforce.indexLive(current), sink, false)
    check("relocate 1 store", stats.stores == 1)
    check("relocate fills slot1 with A", C1.stored == cA)
    check("relocate empties slot2", C2.stored == nil)
end

-- A planned shelf that isn't in the live index is skipped, not crashed.
do
    local saved   = { shelves = { savedShelf("K", 2, { [1] = "A", [2] = "B" }) } }
    local current = { shelves = { liveShelf("K", 2, { [1] = "B", [2] = "A" },
                                            { makeContainer({ sku = "B" }), makeContainer({ sku = "A" }) }) } }
    local p = enforce.plan(saved, current)
    local stats = enforce.apply(p, {}, sink, false)        -- empty ref index
    check("missing shelf skipped", stats.skippedShelves == 1 and stats.stores == 0)
end

print(string.format("\n%s", failures == 0 and "ALL PASS" or (failures .. " FAILURE(S)")))
os.exit(failures == 0 and 0 or 1)
