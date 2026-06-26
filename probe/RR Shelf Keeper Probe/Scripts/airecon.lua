-- ============================================================
--  RR Shelf Keeper PROBE — AI restock slot-selection recon (Approach A1)
--  Version: airecon-v1
--
--  PURPOSE: find WHERE the restocking employee chooses which container
--  a movie goes into, and whether that choice is interceptable, so the
--  real mod can override it to fill slots in physical order (left→right,
--  top→bottom) instead of a random empty slot.
--
--  READ-ONLY. It (1) reflects the AiDirector / AI-Employee / shelf-container
--  classes on F7 (or console `rrrecon`), and (2) registers OBSERVATIONAL
--  post-hooks on the candidate container functions that only LOG when they
--  fire. It never spawns, moves, writes, reserves, or stores anything.
--  Everything is tagged [RR-Recon]; grep it out of the shared UE4SS.log.
--
--  LESSON FROM Phase 2/3 (CLAUDE.md §7): ForEachFunction on a NATIVE UClass
--  native-crashes — so every function enumeration here is GATED to Blueprint
--  (_C) classes, exactly like the proven-safe shelf probe.
-- ============================================================
local VERSION = "airecon-v2"
local P = "[RR-Recon] "
local function log(m) print(P .. tostring(m) .. "\n") end

-- ---- tunables ----
local FN_LOG_CAP = 60       -- max observed hook firings logged per function before suppressing
local SWEEP_KEYWORDS = { "employee", "staff", "worker", "clerk", "director", "aidirector" }

-- Function-name keywords worth a full parameter dump (the slot-choice is likely one of these).
local HOT_FN_KEYWORDS = {
    "stock", "shelf", "shelve", "container", "slot", "place", "store", "empty",
    "available", "reserve", "fill", "pick", "movie", "film", "target", "find",
    "choose", "random", "assign", "next", "free", "spot",
}

-- Container BP functions to OBSERVE during a live restock (full paths resolved at runtime).
local OBSERVE_CONTAINER_FNS = {
    "Can AI reserve it?",
    "Store the Object",
    "AI Pick UP",
}

-- Shelf-level BP functions to OBSERVE — the PRIME A1 candidate `Does any Shelve Containers still
-- empty` (it loops the containers and returns the empty one the staff will fill). The observer logs
-- the shelf's empty containers (array index + world loc) at fire time; correlate with the container
-- `Store the Object` hook (which slot actually got the movie) to confirm the selection rule.
local OBSERVE_SHELF_FNS = {
    "Does any Shelve Containers still empty",
    "Can AI reserve it?",
}

-- ============================================================
-- small reflection helpers (every call guarded; mirrors the shelf probe)
-- ============================================================
local function tryStr(fns)
    for _, f in ipairs(fns) do
        local ok, s = pcall(f)
        if ok and s ~= nil and s ~= "" then return tostring(s) end
    end
    return "?"
end

local function isValid(o)
    local ok, v = pcall(function() return o.IsValid and o:IsValid() end)
    return ok and v == true
end

local function fullName(o) return tryStr({ function() return o:GetFullName() end }) end
local function classFullName(o) return tryStr({ function() return o:GetClass():GetFullName() end }) end
local function shortClass(o)
    return tryStr({
        function() return o:GetClass():GetFName():ToString() end,
        function() return o:GetClass():GetName() end,
    })
end

local function propName(p)
    return tryStr({
        function() return p:GetFName():ToString() end,
        function() return p:GetName() end,
    })
end
local function propType(p)
    return tryStr({
        function() return p:GetClass():GetFName():ToString() end,
        function() return p:GetClass():GetName() end,
    })
end

local function getLoc(o)
    local loc
    if pcall(function() loc = o:K2_GetComponentLocation() end) and loc then return loc end
    if pcall(function() loc = o:K2_GetActorLocation() end) and loc then return loc end
    return nil
end

local function nameMatches(nm, keywords)
    local lc = nm:lower()
    for _, k in ipairs(keywords) do if lc:find(k, 1, true) then return true end end
    return false
end

-- compact parameter signature of a UFunction (for the hot-listed functions)
local function fnParams(fn)
    local params = {}
    pcall(function()
        fn:ForEachProperty(function(p)
            params[#params + 1] = propName(p) .. ":" .. propType(p)
        end)
    end)
    return table.concat(params, ", ")
end

-- List a class's Blueprint (_C) functions. Star + full-sig the ones matching HOT_FN_KEYWORDS.
-- ForEachFunction is GATED to _C classes (native-class enumeration crashes — §7).
local function dumpFunctions(obj, label)
    log("-- " .. label .. " functions (Blueprint _C classes only) --")
    local seen, any = {}, false
    local cls = obj:GetClass()
    local guard = 0
    while cls and isValid(cls) and guard < 10 do
        guard = guard + 1
        local cname = tryStr({
            function() return cls:GetFName():ToString() end,
            function() return cls:GetName() end,
        })
        if cname:find("_C", 1, true) then
            pcall(function()
                cls:ForEachFunction(function(fn)
                    local fn_name = propName(fn)
                    if seen[fn_name] then return end
                    seen[fn_name] = true
                    any = true
                    if nameMatches(fn_name, HOT_FN_KEYWORDS) then
                        log(string.format("   *fn[%s] %s  ->  [%s]", cname, fn_name, fnParams(fn)))
                    else
                        log(string.format("    fn[%s] %s", cname, fn_name))
                    end
                end)
            end)
        end
        local ok, super = pcall(function() return cls:GetSuperStruct() end)
        cls = ok and super or nil
    end
    if not any then log("    (no _C functions found)") end
end

-- List a class's property names+types (ForEachProperty is safe on native too — bounded by hierarchy).
local function dumpProps(obj, label)
    log("-- " .. label .. " properties --")
    local seen = {}
    local cls = obj:GetClass()
    local guard = 0
    while cls and isValid(cls) and guard < 10 do
        guard = guard + 1
        local cname = tryStr({ function() return cls:GetFName():ToString() end })
        -- stop at the first native base to keep it readable (Blueprint fields are what we want)
        if not cname:find("_C", 1, true) then break end
        pcall(function()
            cls:ForEachProperty(function(p)
                local nm = propName(p)
                if seen[nm] then return end
                seen[nm] = true
                local star = nameMatches(nm, HOT_FN_KEYWORDS) and " *" or ""
                log(string.format("    .%s : %s%s", nm, propType(p), star))
            end)
        end)
        local ok, super = pcall(function() return cls:GetSuperStruct() end)
        cls = ok and super or nil
    end
end

-- ============================================================
-- PART 1 — static reflection (F7 / `rrrecon`)
-- ============================================================

-- find the first valid, non-default instance of a class
local function firstInstance(className)
    local insts = FindAllOf(className)
    if not insts then return nil end
    for _, o in pairs(insts) do
        if isValid(o) and not fullName(o):find("Default__") then return o end
    end
    return nil
end

-- A) AiDirector
local function reconDirector()
    log("== A: AiDirector ==")
    local dir = firstInstance("AI_Director_C")
    if not dir then
        log("  FindAllOf('AI_Director_C') -> none. (Trying keyword sweep in section C.)")
        return
    end
    log("  director = " .. fullName(dir))
    log("  class    = " .. classFullName(dir))
    dumpProps(dir, "AI_Director_C")
    dumpFunctions(dir, "AI_Director_C")
end

-- B) the AI Employee actor class (discovered by keyword sweep), reflected
local function reconEmployee(employeeClasses)
    log("== B: AI Employee actor class(es) ==")
    if #employeeClasses == 0 then log("  (none found in the sweep)"); return end
    for _, cn in ipairs(employeeClasses) do
        local inst = firstInstance(cn)
        if inst then
            log("  --- " .. cn .. " : " .. fullName(inst) .. " ---")
            dumpProps(inst, cn)
            dumpFunctions(inst, cn)
        else
            log("  --- " .. cn .. " : no live instance ---")
        end
    end
end

-- C) keyword sweep over loaded classes (find the employee/director class names)
local function sweepClasses()
    log("== C: class keyword sweep (employee/staff/worker/director) ==")
    local seen, hits = {}, {}
    pcall(function()
        ForEachUObject(function(o)
            local ok, cn = pcall(function() return o:GetClass():GetFName():ToString() end)
            if not ok or not cn or seen[cn] then return end
            if nameMatches(cn, SWEEP_KEYWORDS) then
                seen[cn] = true
                log("    class: " .. cn)
                if cn:find("_C", 1, true) and (cn:lower():find("employee") or cn:lower():find("staff")
                    or cn:lower():find("worker") or cn:lower():find("clerk")) then
                    hits[#hits + 1] = cn
                end
            end
        end)
    end)
    return hits
end

-- D) shelf + container full function/property dump (find a reserve/find-empty/next-container fn)
local function reconShelfContainer()
    log("== D: shelf + container functions (slot-choice candidates) ==")
    local shelf = firstInstance("Shelf_Movie_4Row_02_C") or firstInstance("Shelf_Movie_4Row_01_C")
    if not shelf then log("  no movie shelf live"); return end
    log("  shelf = " .. fullName(shelf))
    dumpFunctions(shelf, "Shelve_C (shelf)")

    local cont
    pcall(function()
        local arr = shelf["All Selve Containers"]
        if arr then cont = arr[1] end
    end)
    if cont and isValid(cont) then
        log("  container[1] = " .. fullName(cont))
        log("  container class = " .. classFullName(cont))  -- the path the hooks need
        dumpProps(cont, "Shelve_Container_C")
        dumpFunctions(cont, "Shelve_Container_C")
    else
        log("  could not read All Selve Containers[1]")
    end
end

local function runRecon()
    log("================= RECON START (" .. VERSION .. ") =================")
    reconDirector()
    local employeeClasses = sweepClasses()
    reconEmployee(employeeClasses)
    reconShelfContainer()
    log("================= RECON END =================")
    log("Now set up a restock (empty a few slots, ensure a staffer + stock) and watch the [hook] lines.")
end

-- ============================================================
-- PART 2 — observational post-hooks on container functions
-- ============================================================
local fnFireCount = {}

-- Resolve the live container class path (e.g. "/Game/.../Shelve_Container.Shelve_Container_C")
-- from a movie shelf's first container, so we can build "<path>:<Function>" hook targets.
local function containerClassPath()
    local shelf = firstInstance("Shelf_Movie_4Row_02_C") or firstInstance("Shelf_Movie_4Row_01_C")
        or firstInstance("Shelf_Movie_5Row_01_C") or firstInstance("Shelf_Movie_6Row_01_C")
    if not shelf then return nil end
    local cont
    pcall(function() cont = shelf["All Selve Containers"][1] end)
    if not (cont and isValid(cont)) then return nil end
    local cfn = classFullName(cont)                       -- "BlueprintGeneratedClass /Game/...Shelve_Container_C"
    local path = cfn:match("%s(/.+)$") or cfn             -- strip the leading "BlueprintGeneratedClass "
    return path
end

-- One observer per function: logs the firing + the container's identity/world position, throttled.
local function makeObserver(fnLabel)
    return function(self)
        local n = (fnFireCount[fnLabel] or 0) + 1
        fnFireCount[fnLabel] = n
        if n > FN_LOG_CAP then return end
        pcall(function()
            local c = self:get()
            local loc = getLoc(c)
            local where = loc and string.format("(%.0f, %.0f, %.0f)", loc.X, loc.Y, loc.Z) or "(?)"
            log(string.format("  [hook] %-48s #%d  container=%s  loc=%s",
                fnLabel, n, tryStr({ function() return c:GetFName():ToString() end }), where))
            if n == FN_LOG_CAP then log("  [hook] (" .. fnLabel .. ") reached log cap — suppressing further") end
        end)
    end
end

-- Resolve the base Shelve_C class path (where `Does any Shelve Containers still empty` is defined)
-- by walking a movie shelf's class hierarchy to the class named exactly "Shelve_C".
local function shelveClassPath()
    local shelf = firstInstance("Shelf_Movie_4Row_02_C") or firstInstance("Shelf_Movie_4Row_01_C")
        or firstInstance("Shelf_Movie_5Row_01_C") or firstInstance("Shelf_Movie_6Row_01_C")
    if not shelf then return nil end
    local cls = shelf:GetClass()
    local guard = 0
    while cls and isValid(cls) and guard < 12 do
        guard = guard + 1
        local nm = tryStr({ function() return cls:GetFName():ToString() end })
        if nm == "Shelve_C" then
            local cfn = tryStr({ function() return cls:GetFullName() end })
            return cfn:match("%s(/.+)$") or cfn
        end
        local ok, super = pcall(function() return cls:GetSuperStruct() end)
        cls = ok and super or nil
    end
    return nil
end

-- Shelf observer: logs the shelf's currently-EMPTY containers (array index + world loc) when the
-- slot-chooser fires. Deduped per shelf on the empty-set signature, so the AI re-checking every tick
-- logs only when the set actually changes (e.g. a slot just got filled) — keeps the log readable.
local lastEmptyKey = {}
local function makeShelfObserver(fnLabel)
    return function(self)
        pcall(function()
            local shelf = self:get()
            local sname = tryStr({ function() return shelf:GetFName():ToString() end })
            local arr = shelf["All Selve Containers"]
            local count = 0
            pcall(function() count = arr:GetArrayNum() end)
            local empties, sigParts = {}, {}
            for i = 1, (count or 0) do
                local c; pcall(function() c = arr[i] end)
                if c then
                    local owned; pcall(function() owned = c["Object owning of this container"] end)
                    if not (owned and isValid(owned)) then
                        local loc = getLoc(c)
                        empties[#empties + 1] = string.format("%d@(%.0f,%.0f,%.0f)",
                            i, loc and loc.X or 0, loc and loc.Y or 0, loc and loc.Z or 0)
                        sigParts[#sigParts + 1] = tostring(i)
                        if #empties >= 24 then break end
                    end
                end
            end
            local sig = sname .. "|" .. table.concat(sigParts, ",")
            if lastEmptyKey[sname] == sig then return end       -- unchanged empty-set → skip
            lastEmptyKey[sname] = sig
            local n = (fnFireCount[fnLabel] or 0) + 1
            fnFireCount[fnLabel] = n
            if n > FN_LOG_CAP then return end
            log(string.format("  [hook] %-40s shelf=%s  empty[%d]: %s",
                fnLabel, sname, #empties, table.concat(empties, " ")))
        end)
    end
end

local hooksRegistered = false
local function registerObservers()
    if hooksRegistered then return end
    local path = containerClassPath()
    if not path then
        log("hooks: container class path not resolvable yet (no shelf loaded) — will retry.")
        return
    end
    log("hooks: container class path = " .. path)
    for _, fn in ipairs(OBSERVE_CONTAINER_FNS) do
        local target = path .. ":" .. fn
        local ok, err = pcall(function() RegisterHook(target, makeObserver(fn)) end)
        log((ok and "  hook OK  : " or "  hook FAIL: ") .. target .. (ok and "" or ("  / " .. tostring(err))))
    end

    local spath = shelveClassPath()
    if spath then
        log("hooks: shelf class path = " .. spath)
        for _, fn in ipairs(OBSERVE_SHELF_FNS) do
            local target = spath .. ":" .. fn
            local ok, err = pcall(function() RegisterHook(target, makeShelfObserver(fn)) end)
            log((ok and "  hook OK  : " or "  hook FAIL: ") .. target .. (ok and "" or ("  / " .. tostring(err))))
        end
    else
        log("hooks: shelf (Shelve_C) class path not resolvable — skipping shelf hooks.")
    end
    hooksRegistered = true
end

-- ============================================================
-- ENTRY — F7 / `rrrecon` for the static dump; hooks auto-register late.
-- ============================================================
local function onRecon()
    ExecuteInGameThread(function()
        local ok, err = pcall(runRecon)
        if not ok then log("RECON ERROR: " .. tostring(err)) end
    end)
end

RegisterKeyBind(Key.F7, onRecon)
RegisterConsoleCommandHandler("rrrecon", function() onRecon(); return true end)

-- Register the observational hooks once the game/blueprints are live. Retry a few times in case
-- the store isn't loaded yet when the mod starts (mirrors the snack mod's deferred registration).
local function deferRegister(attempt)
    ExecuteWithDelay(4000 * attempt, function()
        ExecuteInGameThread(function()
            local ok, err = pcall(registerObservers)
            if not ok then log("hook register error: " .. tostring(err)) end
            if not hooksRegistered and attempt < 4 then deferRegister(attempt + 1) end
        end)
    end)
end
deferRegister(1)

log("RR Shelf Keeper RECON loaded (" .. VERSION .. "). Press F7 or type `rrrecon`; restock to see [hook] lines.")
