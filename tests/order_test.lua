-- tests/order_test.lua — run from repo root:  lua tests/order_test.lua
package.path = package.path .. ";RR Shelf Keeper/Scripts/?.lua"
local order = require("order")

local failures = 0
local function check(name, cond)
    if cond then print("PASS: " .. name) else print("FAIL: " .. name); failures = failures + 1 end
end

-- A 2-row x 2-col shelf. row Z: bottom=0, top=30. col Y: left=0, right=18.
-- index numbering is deliberately NOT physical order (mirrors the scrambled array index).
local function grid(filledIdx)
    local filled = {}; for _, i in ipairs(filledIdx or {}) do filled[i] = true end
    return {
        { index = 1, loc = { x = 0, y = 18, z = 0  }, isEmpty = not filled[1] },  -- bottom-right
        { index = 2, loc = { x = 0, y = 0,  z = 30 }, isEmpty = not filled[2] },  -- top-left
        { index = 3, loc = { x = 0, y = 0,  z = 0  }, isEmpty = not filled[3] },  -- bottom-left
        { index = 4, loc = { x = 0, y = 18, z = 30 }, isEmpty = not filled[4] },  -- top-right
    }
end

-- default rule (topFirst, leftFirst): first slot = top-left = index 2
check("all empty -> top-left", order.nextEmpty(grid(), {}) == 2)
-- top-left filled -> next is top-right (index 4)
check("top-left filled -> top-right", order.nextEmpty(grid({ 2 }), {}) == 4)
-- top row full -> drop to bottom-left (index 3)
check("top row full -> bottom-left", order.nextEmpty(grid({ 2, 4 }), {}) == 3)
-- only bottom-right empty
check("one empty -> that one", order.nextEmpty(grid({ 2, 3, 4 }), {}) == 1)
-- none empty -> nil
check("none empty -> nil", order.nextEmpty(grid({ 1, 2, 3, 4 }), {}) == nil)
-- topFirst=false -> bottom row first -> bottom-left (index 3)
check("bottom-first -> bottom-left", order.nextEmpty(grid(), { topFirst = false }) == 3)
-- leftFirst=false -> top-right first (index 4)
check("right-first -> top-right", order.nextEmpty(grid(), { leftFirst = false }) == 4)
-- row tolerance: z=0 and z=4 are the same row (tol 15); within a row pick leftmost
do
    local conts = {
        { index = 1, loc = { x = 0, y = 10, z = 0 }, isEmpty = true },
        { index = 2, loc = { x = 0, y = 0,  z = 4 }, isEmpty = true },  -- same row, more left
    }
    check("row tolerance groups near-equal z", order.nextEmpty(conts, { rowTol = 15 }) == 2)
end
check("empty list -> nil", order.nextEmpty({}, {}) == nil)

-- Explicit row/col fields (shelf-relative coords fed by restock for double-sided shelves) take
-- precedence over raw loc. Here loc.z would pick index 1 (higher z), but row says index 2 is the top.
do
    local conts = {
        { index = 1, row = 0,  col = 0, loc = { x = 0, y = 0, z = 999 }, isEmpty = true },
        { index = 2, row = 30, col = 0, loc = { x = 0, y = 0, z = 0   }, isEmpty = true },
    }
    check("row/col override loc (topFirst -> higher row)", order.nextEmpty(conts, {}) == 2)
end
-- col flips independently of world Y: lower col wins under leftFirst even if world y says otherwise.
do
    local conts = {
        { index = 1, row = 0, col = 5, loc = { x = 0, y = -100, z = 0 }, isEmpty = true },
        { index = 2, row = 0, col = 1, loc = { x = 0, y =  100, z = 0 }, isEmpty = true },
    }
    check("col field drives left/right (not world y)", order.nextEmpty(conts, {}) == 2)
end

print(string.format("\n%s", failures == 0 and "ALL PASS" or (failures .. " FAILURE(S)")))
os.exit(failures == 0 and 0 or 1)
