-- RR Shelf Keeper — layout enforcement (Phase 3: the correction primitive).
--
-- Two layers, split so the dangerous part is isolated and the safe part is fully testable:
--   • PURE decision logic — diff() and plan() — compares a saved layout to a live snapshot and
--     decides which cassettes to move where. No game calls; unit-tested in tests/enforce_test.lua.
--   • RUNTIME mutation — apply() / signature recon — calls the Blueprint move primitive on
--     Shelve_Container_C. This is the crux and the risk: the primitive's exact arg signature is
--     UNCONFIRMED (Phase 0 named it but did not capture its params), and a wrong BP call can
--     NATIVE-crash (pcall-uncatchable, like the GUID read in §7). So it is gated behind an
--     explicit `rrshelf enforce go`, and `rrshelf enforce` (+ F10) is a DRY RUN that logs the
--     plan and reflects the primitive's signature WITHOUT mutating. Validate the signature from
--     the dry-run log before arming `go`.
--
-- Enforcement model (collect → place), per shelf, matched by durable key:
--   A slot is "satisfied" when its current SKU == its saved SKU (empty==empty counts). Satisfied
--   slots are never touched. Every other (not-satisfied) slot is freed; its cassette, if any, is
--   collected into a per-shelf pool. Targets (slots that should hold a specific SKU) are filled
--   from the pool by SKU; leftover cassettes are re-placed into the remaining freed slots so no
--   actor is ever orphaned. A target whose SKU is nowhere on the shelf is "unfulfillable" (left
--   empty + logged). Sourcing is PER SHELF for Phase 3 (a cassette stays on its own shelf) — a
--   global pool / backstock sourcing is a later refinement.
local layout = require("layout")
local M = {}

-- Blueprint move-primitive family on Shelve_Container_C (Phase 0 §6.5). Names are confirmed;
-- the ARG SIGNATURES are not — reflectSignature() logs them so we validate before arming `go`.
-- CONFIRMED signature (reflected in-game): two inputs — (Object to store:ObjectProperty,
-- Set Location:BoolProperty). "Set Location"=true positions the cassette to the slot transform.
-- (The rest of the reflected props — K2Node_*/CallFunc_* — are compiler-generated locals, not args.)
-- shelf-v7 found `(cart, true)` errors "expected 2 parameters, received 1" → the UE4SS bracket-call
-- arg binding for this function is not what we assumed; shelf-v8 probes the call forms (STORE_FORMS).
local FN_STORE   = "Store Object From Game Code And No Animation"  -- code-driven place, no anim
local FN_EMPTY   = "Empty Container"                               -- detach the stored cassette
local FN_FITS    = "Does it fit in the container?"                 -- genre/class filter check
local FN_ISEMPTY = "Return is container empty"
local FN_SNAP    = "Set Stored Object to Container Transform"      -- snap the cassette to slot pose
local RECON_FNS  = { [FN_STORE] = true, [FN_EMPTY] = true, [FN_FITS] = true,
                     [FN_ISEMPTY] = true, [FN_SNAP] = true }

-- ---- pure helpers --------------------------------------------------------------------------

-- Durable match key: persisted shelves carry it as `id`, live snapshots as `durableId`.
local function keyOf(sh) return sh.durableId or sh.id end

-- Map a shelf's slots list -> { [index] = sku }. Absent sku (empty slot) -> no entry (nil).
local function skuByIndex(sh)
    local m = {}
    for _, slot in ipairs(sh.slots or {}) do
        if slot.sku ~= nil then m[slot.index] = slot.sku end
    end
    return m
end

-- Pair saved shelves to live shelves by durable key. Returns:
--   pairs   = { { key, saved, current }, ... }  (only shelves present in BOTH)
--   missing = { key, ... }                       (saved but not found live)
-- Live shelves with no saved entry are simply ignored (unmanaged / newly placed).
local function pairShelves(saved, current)
    local liveByKey = {}
    for _, sh in ipairs(current.shelves or {}) do
        local k = keyOf(sh)
        if k ~= nil then liveByKey[k] = sh end
    end
    local paired, missing = {}, {}
    for _, sh in ipairs(saved.shelves or {}) do
        local k = keyOf(sh)
        local live = k ~= nil and liveByKey[k] or nil
        if live then paired[#paired + 1] = { key = k, saved = sh, current = live }
        else missing[#missing + 1] = k end
    end
    return paired, missing
end

-- diff(saved, current): per shelf+slot, list slots whose current SKU ≠ saved SKU (a want/have
-- pair; nil = empty). Pure reporting — the readable answer to "what is out of place".
function M.diff(saved, current)
    local paired, missing = pairShelves(saved, current)
    local out = { matched = #paired, missing = missing, mismatches = {}, totalMismatches = 0 }
    for _, pr in ipairs(paired) do
        local want = skuByIndex(pr.saved)
        local have = skuByIndex(pr.current)
        local slots = {}
        for _, slot in ipairs(pr.saved.slots or {}) do
            local i = slot.index
            if want[i] ~= have[i] then
                slots[#slots + 1] = { index = i, want = want[i], have = have[i] }
            end
        end
        if #slots > 0 then
            out.mismatches[#out.mismatches + 1] = { key = pr.key, class = pr.saved.class, slots = slots }
            out.totalMismatches = out.totalMismatches + #slots
        end
    end
    return out
end

-- plan one shelf -> moves[], unfulfillable[]. See the collect→place model in the file header.
-- A move = { from, to, sku, surplus } : take the cassette currently at `from`, store it at `to`.
-- `from == to` is never emitted (a cassette left in place needs no work).
local function planShelf(saved, current)
    local want = skuByIndex(saved)
    local have = skuByIndex(current)

    -- not-satisfied slots, ascending → deterministic output across re-runs
    local notSat = {}
    for _, slot in ipairs(saved.slots or {}) do
        local i = slot.index
        if want[i] ~= have[i] then notSat[#notSat + 1] = i end
    end
    table.sort(notSat)

    -- pool of loose cassettes (a not-satisfied slot that is currently filled), FIFO by index;
    -- and the set of free destination slots (all not-satisfied slots — empty after collect).
    local pool, freeOrder, freeSet = {}, {}, {}
    for _, i in ipairs(notSat) do
        freeOrder[#freeOrder + 1] = i
        freeSet[i] = true
        if have[i] ~= nil then pool[#pool + 1] = { sku = have[i], from = i } end
    end

    local moves, unfulfillable = {}, {}

    -- pass 1: fill real targets (slots that should hold a specific SKU) from the pool by SKU
    for _, i in ipairs(notSat) do
        local w = want[i]
        if w ~= nil then
            local srcIdx
            for j, src in ipairs(pool) do
                if src.sku == w then srcIdx = j; break end
            end
            if srcIdx then
                local src = table.remove(pool, srcIdx)
                if src.from ~= i then moves[#moves + 1] = { from = src.from, to = i, sku = w, surplus = false } end
                freeSet[i] = nil
            else
                unfulfillable[#unfulfillable + 1] = { to = i, wantSku = w }
            end
        end
    end

    -- pass 2: re-place leftover (surplus) cassettes into the remaining free slots so none orphan.
    -- A leftover whose own slot is still free stays put (no move). |free| ≥ |pool| always holds.
    for _, src in ipairs(pool) do
        local to
        if freeSet[src.from] then
            to = src.from                                  -- already where it can stay
        else
            for _, f in ipairs(freeOrder) do
                if freeSet[f] then to = f; break end
            end
        end
        if to ~= nil then
            freeSet[to] = nil
            if src.from ~= to then
                moves[#moves + 1] = { from = src.from, to = to, sku = src.sku, surplus = true }
            end
        end
    end

    return moves, unfulfillable
end

-- plan(saved, current): full move plan across all matched shelves. Pure; drives apply().
function M.plan(saved, current)
    local paired, missing = pairShelves(saved, current)
    local out = {
        matched = #paired, missing = missing, shelves = {},
        totalMoves = 0, totalSurplus = 0, totalUnfulfillable = 0,
    }
    for _, pr in ipairs(paired) do
        local moves, unfulfillable = planShelf(pr.saved, pr.current)
        if #moves > 0 or #unfulfillable > 0 then
            out.shelves[#out.shelves + 1] =
                { key = pr.key, class = pr.saved.class, moves = moves, unfulfillable = unfulfillable }
            out.totalMoves = out.totalMoves + #moves
            out.totalUnfulfillable = out.totalUnfulfillable + #unfulfillable
            for _, mv in ipairs(moves) do if mv.surplus then out.totalSurplus = out.totalSurplus + 1 end end
        end
    end
    return out
end

-- ---- runtime mutation (needs the running game; validated in-game, NOT unit-tested) ---------

-- Reflect the move-primitive family's parameter signatures off a live container and log them.
-- READ-ONLY reflection (the same UStruct:ForEachFunction/ForEachProperty the Phase 0 probe used
-- safely) — it never CALLS the functions, so it cannot trigger the native-crash that an actual
-- bad invocation could. Run this in the dry run to capture the exact args before arming `go`.
function M.reflectSignature(container, log)
    if not container then log("  (no container to reflect — store has no managed slots?)"); return end
    local seen, found = {}, false
    local remaining = 0
    for _ in pairs(RECON_FNS) do remaining = remaining + 1 end
    local cls
    pcall(function() cls = container:GetClass() end)
    local guard = 0
    while cls and guard < 8 and remaining > 0 do
        guard = guard + 1
        -- ONLY enumerate Blueprint (_C) classes' functions. Calling ForEachFunction on a NATIVE
        -- UClass (Shelve_Container_C's bases: StaticMeshComponent → … → UObject) NATIVE-crashed the
        -- dry run — AV reading 0x40 in the shipping exe, after the 5 leaf sigs logged (shelf-v5,
        -- 2026-06-26). The Phase 0 probe's dumpFunctions gated to "_C" for this exact reason. The
        -- move primitives all live on the leaf Shelve_Container_C (a _C class), so we lose nothing.
        local cname = "?"
        pcall(function() cname = cls:GetFName():ToString() end)
        if cname:find("_C", 1, true) then
            pcall(function()
                cls:ForEachFunction(function(fn)
                    local fname = "?"
                    pcall(function() fname = fn:GetFName():ToString() end)
                    if RECON_FNS[fname] and not seen[fname] then
                        seen[fname] = true; found = true; remaining = remaining - 1
                        local params = {}
                        pcall(function()
                            fn:ForEachProperty(function(p)
                                local pn, pt = "?", "?"
                                pcall(function() pn = p:GetFName():ToString() end)
                                pcall(function() pt = p:GetClass():GetFName():ToString() end)
                                if pt == "?" then pcall(function() pt = p:GetClass():GetName() end) end
                                params[#params + 1] = pn .. ":" .. pt
                            end)
                        end)
                        log(string.format("  sig '%s' -> [%s]", fname, table.concat(params, ", ")))
                    end
                end)
            end)
        end
        local ok, super = pcall(function() return cls:GetSuperStruct() end)
        cls = ok and super or nil
    end
    if not found then log("  (no move-primitive functions found via reflection on this container)") end
end

-- Build { [durableKey] = { shelf = obj, containers = { [index] = obj } } } from a LIVE snapshot
-- (layout.snapshot attaches obj/container refs). apply() resolves move slots through this.
function M.indexLive(snap)
    local idx = {}
    for _, sh in ipairs((snap and snap.shelves) or {}) do
        local k = sh.durableId or sh.id
        if k ~= nil then
            local containers = {}
            for _, slot in ipairs(sh.slots or {}) do
                if slot.container ~= nil then containers[slot.index] = slot.container end
            end
            idx[k] = { shelf = sh.obj, containers = containers }
        end
    end
    return idx
end

-- Candidate UE4SS call conventions for the store primitive (the binding is the open question).
-- d = destination container, c = cassette object. We try these in order on the FIRST store, log
-- each outcome, then cache + reuse whichever doesn't raise. shelf-v7 proved form 'obj,bool' fails
-- ("expected 2, received 1"), so 'self,obj,bool' (pass the container explicitly) is the lead bet.
local STORE_FORMS = {
    { tag = "self,obj,bool", fn = function(d, c) d[FN_STORE](d, c, true) end },
    { tag = "obj,bool",      fn = function(d, c) d[FN_STORE](c, true) end },
    { tag = "self,obj",      fn = function(d, c) d[FN_STORE](d, c) end },
    { tag = "obj",           fn = function(d, c) d[FN_STORE](c) end },
}

-- Attempt the store. If cachedIdx is set, only that form is tried (quietly). Otherwise every form is
-- tried in order and each outcome logged; returns (ok, idx, err) — idx = the winning form index.
local function tryStore(dest, cart, log, cachedIdx)
    if cachedIdx then
        local ok, err = pcall(STORE_FORMS[cachedIdx].fn, dest, cart)
        return ok, cachedIdx, err
    end
    local lastErr
    for i, form in ipairs(STORE_FORMS) do
        local ok, err = pcall(form.fn, dest, cart)
        log(string.format("    store form '%s': %s", form.tag, ok and "OK" or ("ERR " .. tostring(err))))
        if ok then return true, i, nil end
        lastErr = err
    end
    return false, nil, lastErr
end

-- Execute a plan against the live container index. dryRun=true logs the moves and touches nothing.
--
-- GO (dryRun=false) — cycle-safe collect→place per shelf: read+Empty every distinct source FIRST
-- (so a dest is free when its cassette arrives — a true A↔B swap resolves), then Store each held
-- cassette into its dest with (cart, true). It **ABORTS the store pass on the FIRST store failure**,
-- capturing the error string (the same call would fail identically for every move, so there's no
-- point spamming — and it surfaces WHY). pcall catches Lua errors; a native crash still can't be
-- caught. If a run fails mid-way the sources are already detached → RELOAD the save before retrying.
--   log: line sink.   Returns stats { moves, stores, empties, errors, skippedShelves, lastError }.
function M.apply(plan, refIndex, log, dryRun)
    local stats = { moves = 0, stores = 0, empties = 0, errors = 0, skippedShelves = 0 }
    for _, sh in ipairs(plan.shelves) do
        local ref = refIndex[sh.key]
        if not ref then
            stats.skippedShelves = stats.skippedShelves + 1
            log("  ! shelf " .. tostring(sh.key) .. " not live now — skipping " .. #sh.moves .. " move(s)")
        elseif dryRun then
            for _, mv in ipairs(sh.moves) do
                stats.moves = stats.moves + 1
                log(string.format("  [dry] SKU %s : slot %d -> slot %d%s",
                    tostring(mv.sku), mv.from, mv.to, mv.surplus and "  (surplus re-place)" or ""))
            end
        else
            -- collect pass: read each distinct source cassette, then detach it
            local held = {}
            local diagDone = false      -- log the cassette's validity ACROSS Empty once (pivotal:
                                        -- does Empty destroy the cassette, or just detach it?)
            for _, mv in ipairs(sh.moves) do
                if held[mv.from] == nil then
                    local c = ref.containers[mv.from]
                    local cart
                    if c then pcall(function() cart = c[layout.OWNED_OBJECT_KEY] end) end
                    held[mv.from] = cart or false               -- false = read but empty/unreadable
                    if c and cart then
                        local v1, n1 = "?", "?"
                        if not diagDone then
                            pcall(function() v1 = tostring(cart:IsValid()) end)
                            pcall(function() n1 = cart:GetFullName() end)
                        end
                        local okE, errE = pcall(function() c[FN_EMPTY]() end)
                        if okE then stats.empties = stats.empties + 1
                        else stats.errors = stats.errors + 1; log("  ! empty failed slot " .. mv.from .. ": " .. tostring(errE)) end
                        if not diagDone then
                            diagDone = true
                            local v2, n2 = "?", "?"
                            pcall(function() v2 = tostring(cart:IsValid()) end)
                            pcall(function() n2 = cart:GetFullName() end)
                            log(string.format("  [diag] cassette across Empty (slot %d): valid %s -> %s",
                                mv.from, v1, v2))
                            log("  [diag]   name pre : " .. n1)
                            log("  [diag]   name post: " .. n2)
                        end
                    end
                end
            end
            -- place pass: store each held cassette into its dest. The first store probes the call
            -- forms (logs each); the winner is cached + reused. Abort on a store that no form lands.
            local storeForm = nil
            for _, mv in ipairs(sh.moves) do
                stats.moves = stats.moves + 1
                local dest = ref.containers[mv.to]
                local cart = held[mv.from]
                if dest and cart then
                    local okS, idx, errS = tryStore(dest, cart, log, storeForm)
                    if okS then
                        if not storeForm then
                            storeForm = idx
                            log("  store call form = '" .. STORE_FORMS[storeForm].tag .. "' (using for the rest)")
                        end
                        pcall(function() dest[FN_SNAP]() end)      -- best-effort pose snap
                        pcall(function() dest[FN_SNAP](dest) end)  -- ...in either bind convention
                        stats.stores = stats.stores + 1
                    else
                        stats.errors = stats.errors + 1
                        stats.lastError = tostring(errS)
                        log(string.format("  ! store failed: SKU %s slot %d -> %d : %s",
                            tostring(mv.sku), mv.from, mv.to, tostring(errS)))
                        log("  ABORTING — no store call form worked. RELOAD the save, then we adjust.")
                        return stats
                    end
                else
                    stats.errors = stats.errors + 1
                    log(string.format("  ! cannot place SKU %s -> slot %d (missing %s)",
                        tostring(mv.sku), mv.to, (not dest) and "dest container" or "held cassette"))
                end
            end
        end
    end
    return stats
end

return M
