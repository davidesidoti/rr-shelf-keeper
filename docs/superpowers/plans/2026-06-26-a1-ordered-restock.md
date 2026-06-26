# A1 Ordered Restock — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make restocking staff place each movie into the next empty slot in physical order (top→bottom, left→right) instead of a random/last slot, by overriding the slot the game's chooser returns — no cassette is moved after placement.

**Architecture:** A pure module (`order.lua`) decides the next slot from container world-positions; a runtime module (`restock.lua`) hooks `Shelve_C: Does any Shelve Containers still empty` and rewrites its `Empty Container` output to that slot. Hook registered late in `main.lua`, gated by config. The Phase 1–3 save/enforce modules are untouched.

**Tech Stack:** UE4SS Lua 5.4 (in-game), standalone Lua 5.5 (offline tests). Hook via `RegisterHook`; out-params via UE4SS `RemoteUnrealParam:get()/:set()`.

---

## File structure

| File | Responsibility |
|------|----------------|
| `RR Shelf Keeper/Scripts/order.lua` | **new, pure:** `nextEmpty(containers, rule) -> index|nil` — physical fill order. |
| `tests/order_test.lua` | **new:** offline unit tests for `order.nextEmpty`. |
| `RR Shelf Keeper/Scripts/restock.lua` | **new, runtime:** read a shelf's containers, compute the target, and the hook callback that rewrites the out-param. |
| `RR Shelf Keeper/Scripts/layout.lua` | **modify:** export `MOVIE_SHELF_CLASSES` for the managed-shelf guard. |
| `RR Shelf Keeper/Scripts/config.lua` | **modify:** add `OrderedRestock`, `RestockDryRun`, `FillTopFirst`, `FillLeftFirst`, `RowTol`. |
| `RR Shelf Keeper/Scripts/main.lua` | **modify:** register the restock hook late, gated by config. |

---

## Task 1: `order.lua` — physical fill order (pure, TDD)

**Files:**
- Create: `RR Shelf Keeper/Scripts/order.lua`
- Test: `tests/order_test.lua`

- [ ] **Step 1: Write the failing tests**

Create `tests/order_test.lua`:

```lua
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

print(string.format("\n%s", failures == 0 and "ALL PASS" or (failures .. " FAILURE(S)")))
os.exit(failures == 0 and 0 or 1)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `lua tests/order_test.lua`
Expected: FAIL — `module 'order' not found`.

- [ ] **Step 3: Write the minimal implementation**

Create `RR Shelf Keeper/Scripts/order.lua`:

```lua
-- RR Shelf Keeper — physical fill order for ordered restock (Approach A1).
-- Pure: decides which empty container the staff should fill next, from container world positions.
-- Slot world transform (Phase 0 §6.3): Z = row, Y = column, X tilts with Z (ignored for ordering).
local M = {}

-- Group a Z coordinate into an integer row key so near-equal Z values are one row (float noise +
-- slight per-slot variance). tol ≈ half the row spacing (rows are ~30 apart; default 15).
local function rowKey(z, tol) return math.floor((z or 0) / tol + 0.5) end

-- nextEmpty(containers, rule) -> index | nil
--   containers : array of { index=int, loc={x,y,z}, isEmpty=bool }
--   rule       : { topFirst=bool(default true), leftFirst=bool(default true), rowTol=num(default 15) }
-- Returns the `index` of the empty container first in physical fill order (row then column), or nil.
function M.nextEmpty(containers, rule)
    rule = rule or {}
    local topFirst  = rule.topFirst  ~= false       -- default true
    local leftFirst = rule.leftFirst ~= false       -- default true
    local tol = rule.rowTol or 15

    local empties = {}
    for _, c in ipairs(containers or {}) do
        if c.isEmpty and c.loc then empties[#empties + 1] = c end
    end
    if #empties == 0 then return nil end

    table.sort(empties, function(a, b)
        local ar, br = rowKey(a.loc.z, tol), rowKey(b.loc.z, tol)
        if ar ~= br then
            if topFirst then return ar > br else return ar < br end
        end
        if a.loc.y ~= b.loc.y then
            if leftFirst then return a.loc.y < b.loc.y else return a.loc.y > b.loc.y end
        end
        return a.index < b.index                     -- stable, deterministic tiebreak
    end)
    return empties[1].index
end

return M
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `lua tests/order_test.lua`
Expected: `ALL PASS`.

- [ ] **Step 5: Run the full offline suite (no regressions)**

Run: `for t in tests/*.lua; do lua "$t" >/dev/null 2>&1 && echo "PASS $t" || echo "FAIL $t"; done`
Expected: every suite `PASS`.

- [ ] **Step 6: Commit** (only if the user has approved committing this session)

```bash
git add "RR Shelf Keeper/Scripts/order.lua" tests/order_test.lua
git commit -m "Add Phase A1: physical fill-order (order.nextEmpty) + tests"
```

---

## Task 2: `layout.lua` — export the movie-shelf class list

**Files:**
- Modify: `RR Shelf Keeper/Scripts/layout.lua` (the `MOVIE_SHELF_CLASSES` local + the `M.CONTAINER_ARRAY_KEY`/`M.OWNED_OBJECT_KEY` exports already present)

- [ ] **Step 1: Export the list**

After the `local MOVIE_SHELF_CLASSES = { ... }` table, add:

```lua
M.MOVIE_SHELF_CLASSES = MOVIE_SHELF_CLASSES   -- reused by restock.lua's managed-shelf guard
```

- [ ] **Step 2: Verify the module still loads**

Run: `lua -e "assert(loadfile('RR Shelf Keeper/Scripts/layout.lua')); print('OK')"`
Expected: `OK`.

- [ ] **Step 3: Run the layout suite (no regressions)**

Run: `lua tests/layout_test.lua`
Expected: `ALL PASS`.

---

## Task 3: `restock.lua` — read containers, compute target, hook callback

**Files:**
- Create: `RR Shelf Keeper/Scripts/restock.lua`

This module is runtime (reads live UObjects, sets out-params) → validated in-game, not unit-tested. It depends only on the pure `order.lua` for the decision.

- [ ] **Step 1: Write the module**

Create `RR Shelf Keeper/Scripts/restock.lua`:

```lua
-- RR Shelf Keeper — ordered restock (Approach A1): override the staff's slot choice.
--
-- Hooks Shelve_C:"Does any Shelve Containers still empty" — the function the restock AI calls to get
-- the empty container it will stock (recon airecon-v2: the staff fill exactly the container it
-- returns; default rule returns the highest array-index empty). We rewrite that returned
-- `Empty Container` to the next empty slot in PHYSICAL order (order.lua), so staff fill in order.
-- No placed cassette is ever moved — only the chooser's return is redirected.
local order  = require("order")
local layout = require("layout")
local Config = require("config")

local M = {}
local P = "[RR-Shelf] "
local function log(m) print(P .. tostring(m) .. "\n") end

local CONTAINER_ARRAY_KEY = layout.CONTAINER_ARRAY_KEY      -- "All Selve Containers"
local OWNED_OBJECT_KEY    = layout.OWNED_OBJECT_KEY         -- "Object owning of this container"

-- managed = a movie-shelf leaf class (snack shelves / ClearanceBin share Shelve_C but aren't movies)
local MOVIE_SET = {}
for _, c in ipairs(layout.MOVIE_SHELF_CLASSES) do MOVIE_SET[c] = true end

local function isManagedMovieShelf(shelf)
    local cls
    pcall(function() cls = shelf:GetClass():GetFName():ToString() end)
    return cls ~= nil and MOVIE_SET[cls] == true
end

local function getCompLoc(c)
    local loc
    if pcall(function() loc = c:K2_GetComponentLocation() end) and loc then
        return { x = loc.X, y = loc.Y, z = loc.Z }
    end
    return nil
end

-- Read a shelf's containers -> array of { index, obj, loc, isEmpty }. Empty = no valid owned object.
local function readContainers(shelf)
    local out = {}
    local arr
    pcall(function() arr = shelf[CONTAINER_ARRAY_KEY] end)
    if not arr then return out end
    local n = 0
    pcall(function() n = arr:GetArrayNum() end)
    for i = 1, (n or 0) do
        local c; pcall(function() c = arr[i] end)
        if c then
            local owned; pcall(function() owned = c[OWNED_OBJECT_KEY] end)
            local isEmpty = true
            if owned then
                local ok, valid = pcall(function() return owned.IsValid and owned:IsValid() end)
                if ok and valid == true then isEmpty = false end
            end
            out[#out + 1] = { index = i, obj = c, loc = getCompLoc(c), isEmpty = isEmpty }
        end
    end
    return out
end

local function ruleFromConfig()
    return { topFirst = Config.FillTopFirst, leftFirst = Config.FillLeftFirst, rowTol = Config.RowTol }
end

-- Compute the target container object for a shelf (the next empty slot in physical order), or nil.
function M.targetContainer(shelf)
    local conts = readContainers(shelf)
    local idx = order.nextEmpty(conts, ruleFromConfig())
    if not idx then return nil end
    for _, c in ipairs(conts) do if c.index == idx then return c.obj, idx end end
    return nil
end

-- Hook callback for "Does any Shelve Containers still empty".
-- UE4SS passes the function's params after self: (self, OneContainerIsEmpty, EmptyContainer).
-- In DryRun we only LOG (validate the params + target); otherwise we :set() the out-params.
function M.onDoesAnyEmpty(self, oneEmptyParam, emptyContainerParam)
    if not Config.OrderedRestock then return end
    local ok, err = pcall(function()
        local shelf = self:get()
        if not isManagedMovieShelf(shelf) then return end
        local target, idx = M.targetContainer(shelf)
        if not target then return end

        if Config.RestockDryRun then
            local sname, tname = "?", "?"
            pcall(function() sname = shelf:GetFName():ToString() end)
            pcall(function() tname = target:GetFName():ToString() end)
            -- show what the game currently returns vs what we WOULD set
            local curEmpty, curName = nil, "?"
            pcall(function() curEmpty = emptyContainerParam:get() end)
            if curEmpty then pcall(function() curName = curEmpty:GetFName():ToString() end) end
            log(string.format("[restock dry] %s: game returns '%s' -> would set '%s' (slot idx %s)",
                sname, curName, tname, tostring(idx)))
        else
            pcall(function() emptyContainerParam:set(target) end)
            pcall(function() if oneEmptyParam then oneEmptyParam:set(true) end end)
        end
    end)
    if not ok then log("ordered-restock hook error: " .. tostring(err)) end
end

return M
```

- [ ] **Step 2: Verify the module parses**

Run: `lua -e "assert(loadfile('RR Shelf Keeper/Scripts/restock.lua')); print('OK')"`
Expected: `OK`. (It won't *run* offline — it requires the game — but it must parse.)

---

## Task 4: `config.lua` — ordered-restock flags

**Files:**
- Modify: `RR Shelf Keeper/Scripts/config.lua`

- [ ] **Step 1: Add the flags**

Inside the returned table, add:

```lua
    -- Phase A1: ordered restock (staff fill the next empty slot in physical order).
    OrderedRestock = true,    -- master enable for the at-restock slot override
    RestockDryRun  = true,    -- true = only LOG what it would set (validate first); false = apply
    FillTopFirst   = true,    -- rows top→bottom (Z descending); set false to fill bottom-up
    FillLeftFirst  = true,    -- columns left→right (Y ascending); flip if it comes out mirrored
    RowTol         = 15,      -- Z grouping tolerance for "same row" (rows are ~30 apart)
```

- [ ] **Step 2: Verify it loads**

Run: `lua -e "local c=dofile('RR Shelf Keeper/Scripts/config.lua'); assert(c.OrderedRestock==true and c.RestockDryRun==true); print('OK')"`
Expected: `OK`.

---

## Task 5: `main.lua` — register the restock hook late

**Files:**
- Modify: `RR Shelf Keeper/Scripts/main.lua`

- [ ] **Step 1: Require the module and bump VERSION**

Change the `VERSION` line to:

```lua
local VERSION = "shelf-v9"
```

Add to the requires block (after `local enforce = require("enforce")`):

```lua
local restock = require("restock")
```

- [ ] **Step 2: Register the hook late, gated by config**

Near the bottom of `main.lua` (after the console handler registration, before the final `log(...)` banner), add:

```lua
-- Phase A1: ordered restock. Hook the slot-chooser late (BP class loads after mod start). The path
-- is the base Shelve_C function confirmed by the recon probe; one hook covers all movie shelves.
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
```

- [ ] **Step 3: Verify main.lua parses**

Run: `lua -e "assert(loadfile('RR Shelf Keeper/Scripts/main.lua')); print('OK')"`
Expected: `OK`.

- [ ] **Step 4: Commit** (only if the user has approved committing this session)

```bash
git add "RR Shelf Keeper/Scripts/restock.lua" "RR Shelf Keeper/Scripts/layout.lua" "RR Shelf Keeper/Scripts/config.lua" "RR Shelf Keeper/Scripts/main.lua"
git commit -m "Add Phase A1: ordered-restock hook (dry-run default) + config"
```

---

## Task 6: In-game validation — DRY RUN (does the hook see the right params?)

This needs the running game; the user drives it. `RestockDryRun = true` is the default, so nothing mutates.

- [ ] **Step 1: Hot-reload & confirm**

User: Ctrl+R. Confirm `UE4SS.log` shows `loaded (shelf-v9` and `ordered-restock hook active (DRY RUN — logging only)`.

- [ ] **Step 2: Trigger a restock**

User: start the day, let a staffer restock movies.

- [ ] **Step 3: Read the dry-run log**

Run: `grep -E "\[restock dry\]" "<UE4SS.log path>" | tail -20`
Expected: lines like `[restock dry] Shelf_Movie_4Row_02_C_…: game returns 'Shelve_Container19' -> would set 'Shelve_Container…' (slot idx N)`.
**Confirm:** (a) `game returns '…'` is a real container name (proves `emptyContainerParam` is the right out-param and is readable), and (b) `would set` is a *different, physically-first* slot. If `game returns` is blank/nil or errors, the param order is wrong → swap `oneEmptyParam`/`emptyContainerParam` in `restock.onDoesAnyEmpty` and retry.

---

## Task 7: In-game validation — APPLY (does the override redirect placement?)

- [ ] **Step 1: Turn off dry run**

Edit `config.lua`: `RestockDryRun = false`. User: Ctrl+R (confirm `ordered-restock hook active` without "DRY RUN").

- [ ] **Step 2: Trigger a restock and watch the shelf**

User: empty several slots on one movie shelf, let staff restock. **Observe in-game:** do cassettes fill the next slot in physical order (top-left first), densely, no gaps — instead of the old highest-index slot?

- [ ] **Step 3: Tune direction if mirrored**

If filling is bottom-up or right-to-left versus what you want, flip `FillTopFirst` / `FillLeftFirst` in `config.lua`, Ctrl+R, and re-observe. Repeat until the order matches "left→right, top→bottom."

- [ ] **Step 4: Confirm no collateral damage**

Confirm snack shelves / ClearanceBin restock normally (untouched), and there's no crash across a full restock cycle.

- [ ] **Step 5: Update docs + commit** (only if the user has approved committing)

Record the confirmed param order, the working fill direction, and the hook path in `CLAUDE.md`; append a `docs/PROGRESS.md` entry. Then:

```bash
git add "RR Shelf Keeper/Scripts/config.lua" docs/
git commit -m "Phase A1: confirm ordered-restock override in-game; final fill direction"
```

---

## Self-review notes

- **Spec coverage:** order computation → Task 1; managed-shelf guard → Task 2/3; hook + out-param override → Task 3/5; config (enable/direction/scope) → Task 4; validate-first override risk → Tasks 6–7. All spec sections covered.
- **Type consistency:** `order.nextEmpty(containers, rule)` returns an `index`; `restock.targetContainer` maps that index back to the live object via the same `index` field built in `readContainers`. `rule` keys (`topFirst`/`leftFirst`/`rowTol`) match between `config.lua`, `ruleFromConfig`, and `order.lua`.
- **Risk-gated:** mutation (`:set()`) ships behind `RestockDryRun=true` so the first in-game run only logs — the param-order and redirect risks from the spec are validated before anything changes.
