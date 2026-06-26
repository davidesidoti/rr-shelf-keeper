-- ============================================================
--  RR Shelf Keeper - PROBE  (Phase 0, READ-ONLY)
--  Version marker: probe-v2  (change this string when you edit,
--  then confirm it appears in UE4SS.log after Ctrl+R so you know
--  the hot reload actually picked up your edit.)
--
--  PURPOSE: resolve every unknown in CLAUDE.md Section 6 with a
--  single hotkey press, by dumping data to UE4SS.log. This mod
--  ONLY READS. It never spawns, moves, writes, or destroys
--  anything. Safe to leave installed.
--
--  TRIGGER: press F8  (or type `rrprobe` in the in-game `~`/`` ` ``
--  console). Everything is tagged [RR-Probe] so you can grep it
--  out of the shared UE4SS.log.
--
--  v2 CHANGES (after the v1 dump):
--   - Section A now probes the REAL movie-shelf classes found by
--     the v1 keyword sweep (Shelf_Movie_*, Shelf_NewMovie_*,
--     Shelf_Movie-Display_*, MovieDisplay_C). There is no single
--     "MovieShelf_C" - the game has ~18 leaf shelf classes.
--   - Section B dumps the shelf nearest a placed cassette (so it
--     is a STOCKED, visible shelf) and now also enumerates the
--     shelf's UFunctions (the "Spawn and Fill Snack" analogue we
--     need for the move primitive, unknowns #4/#5).
--   - Section D prints the VALUES of the persistence-key
--     candidates (Save Slot Name / Current Save ID / Current ID of
--     loop) - the SaveGames folder holds Player_Save2.sav, so the
--     key is almost certainly the "Save Slot Name" string.
--
--  WHY REFLECTION, NOT LIVE VIEW: this install runs GraphicsAPI=
--  opengl, so the UE4SS GUI / Live View window never spawns even
--  with GuiConsoleEnabled=1 (confirmed in the sibling rr-dupe-
--  finder repo, its CLAUDE.md gotcha 11). We discover GUID-mangled
--  struct keys via Lua reflection (UStruct:ForEachProperty) and
--  read the results from UE4SS.log on disk.
-- ============================================================

local VERSION = "probe-v4"
local P = "[RR-Probe] "
local function log(m) print(P .. tostring(m) .. "\n") end

-- ---- tunables (keep the log readable; bump if you need more) ----
local MAX_DEPTH = 4   -- shelf -> containers[] -> container -> ownedCassette is depth 3-4
local MAX_ELEMS = 4   -- only dump the first N elements of any array

-- Real movie-shelf classes (harvested from the v1 keyword sweep).
-- FindAllOf matches an exact leaf class, so list them all; the probe
-- collects every instance across all of these and dumps the one
-- nearest a placed cassette.
local SHELF_CANDIDATES = {
    "Shelf_Movie_4Row_01_C", "Shelf_Movie_4Row_02_C", "Shelf_Movie_4Row_03_C",
    "Shelf_Movie_5Row_01_C", "Shelf_Movie_5Row_02_C",
    "Shelf_Movie_6Row_01_C", "Shelf_Movie_6Row_02_C",
    "Shelf_NewMovie_4Row_02_C", "Shelf_NewMovie_5Row_02_C", "Shelf_NewMovie_6Row_02_C",
    "Shelf_Movie-Display_4Row_01_C", "Shelf_Movie-Display_5Row_01_C", "Shelf_Movie-Display_6Row_01_C",
    "Shelf_Movie-Display_WallMounted_01_C", "Shelf_Movie-Display_Base_C",
    "Shelf_Movie-Shelf_MovieDisplay_Unit_01_C", "Shelf_Movie-Shelf_MovieDisplay_Cabinet_01_C",
    "MovieDisplay_C",
}

-- ForEachUObject fallback: any loaded class whose short name contains
-- one of these substrings gets reported once (deduped). This finds the
-- real shelf class even if it is not in SHELF_CANDIDATES above.
-- (NB: "rack" matches "...Track" -> MovieScene noise; harmless.)
local CLASS_KEYWORDS = { "shelf", "movie", "display", "vhs", "cassette", "cartridge" }

-- Cassette SKU/title keys (verbatim from rr-dupe-finder; do NOT guess).
local PRODUCT_STRUCTURE_KEY = "Product Structure"
local BASE_STRUCTURE_KEY    = "BaseStructure_2_FBB12C464AE570CAFD12ED8506160683"
local BOX_DATA_KEY          = "BoxData_25_B5A798DA4F509BDCCF4B189171C1DA10"
local SKU_KEY               = "SKU_26_C5F25F4E49D05A4DEC2DEEAE5AEE5876"
local TITLE_KEY             = "ProductName_14_055828B1436E5AD27BFA95AF181099DE"

-- Persistence-key candidates on Core_Gamemode_C (from the v1 Section D dump).
local PERSIST_KEYS = { "Save Slot Name", "Current Save ID", "Current ID of loop" }

-- Candidate placement/function names to probe by name if ForEachFunction
-- is unavailable in this UE4SS build (the movie analogue of the snack
-- mod's "Spawn and Fill Snack" / "Return Snack Base Save Struct").
local CANDIDATE_FNS = {
    "Spawn and Fill Snack", "Spawn and Fill", "Spawn and Fill Cartridge", "Spawn and Fill Movie",
    "Return Snack Base Save Struct", "Return Base Save Struct", "Return Shelve Base Save Struct",
    "Place Cartridge", "Add Cartridge", "Place Movie", "Add Movie", "Fill Shelf", "Fill",
    "Restock", "Spawn Cartridge", "Empty Shelf", "Empty", "Refill by Player",
}

-- When recursing into an object's properties, LIST every property but
-- do not descend into these (engine components -> avoids log blowup).
local NO_DESCEND = { "component", "root", "mesh", "collision", "billboard", "attach", "instance", "scene" }

-- ============================================================
-- small reflection helpers (every call guarded; this build's
-- exact method names are not 100% known, so we try alternatives)
-- ============================================================

local function tryStr(fns)
    for _, f in ipairs(fns) do
        local ok, s = pcall(f)
        if ok and s ~= nil and s ~= "" then return tostring(s) end
    end
    return "?"
end

local function fullName(o) return tryStr({ function() return o:GetFullName() end }) end

local function propName(p)
    return tryStr({
        function() return p:GetFName():ToString() end,
        function() return p:GetName() end,
        function() return p:GetFullName() end,
    })
end

local function propType(p)
    return tryStr({
        function() return p:GetClass():GetName() end,
        function() return p:GetClass():GetFName():ToString() end,
    })
end

local function isValidObj(v)
    local ok, valid = pcall(function() return v.IsValid and v:IsValid() end)
    return ok and valid == true
end

local function getLoc(o)
    local loc
    if pcall(function() loc = o:K2_GetActorLocation() end) and loc then return loc end
    -- USceneComponent (e.g. a Shelve_Container_C slot) -> world location even when empty
    if pcall(function() loc = o:K2_GetComponentLocation() end) and loc then return loc end
    return nil
end

local function dist2(a, b)  -- squared XY distance between two FVectors
    local dx, dy = a.X - b.X, a.Y - b.Y
    return dx * dx + dy * dy
end

-- Render a scalar/struct/text value for the log.
local function scalarStr(v)
    local lt = type(v)
    if lt == "number" or lt == "boolean" then return tostring(v) end
    if lt == "string" then return '"' .. v .. '"' end
    -- FText / FName / FString -> ToString(); else just show the type tag
    local s
    if pcall(function() s = v:ToString() end) and s ~= nil and s ~= "" then return 'text:"' .. s .. '"' end
    return "<" .. tostring(lt) .. ">"
end

local function noDescend(name)
    local lc = name:lower()
    for _, k in ipairs(NO_DESCEND) do if lc:find(k, 1, true) then return true end end
    return false
end

-- arrayCount(v) -> number or nil  (nil = not an array)
local function arrayCount(v)
    local n
    if pcall(function() n = v:GetArrayNum() end) and type(n) == "number" then return n end
    return nil
end

-- For a struct/array property, dump the inner struct's field NAMES + TYPES.
-- This is where GUID-mangled keys (e.g. SKU_26_...) become visible WITHOUT
-- needing a live element. StructProperty:GetStruct() and
-- ArrayProperty:GetInner() are the relevant accessors.
local function dumpInnerStructFields(prop, pad)
    pcall(function()
        local st = prop:GetStruct()           -- StructProperty
        if st then
            st:ForEachProperty(function(sp)
                log(pad .. "      <" .. propName(sp) .. " : " .. propType(sp) .. ">")
            end)
        end
    end)
    pcall(function()
        local inner = prop:GetInner()         -- ArrayProperty -> element property
        if inner then
            log(pad .. "      (array element type: " .. propType(inner) .. ")")
            local st = inner:GetStruct()
            if st then
                st:ForEachProperty(function(sp)
                    log(pad .. "        <" .. propName(sp) .. " : " .. propType(sp) .. ">")
                end)
            end
        end
    end)
end

-- Forward declaration so walkValue and walkObject can call each other.
local walkValue

-- List an object's properties (names + types + inner struct fields), then
-- recurse into array/object property VALUES that look interesting.
local function walkObject(obj, depth, pad)
    -- location, if it is an actor
    local loc = getLoc(obj)
    if loc then
        log(pad .. "  loc = (" .. tostring(loc.X) .. ", " .. tostring(loc.Y) .. ", " .. tostring(loc.Z) .. ")")
    end
    local cls = obj:GetClass()
    local guard = 0
    while cls and isValidObj(cls) and guard < 8 do
        guard = guard + 1
        pcall(function()
            cls:ForEachProperty(function(prop)
                local nm = propName(prop)
                local ty = propType(prop)
                log(pad .. "  ." .. nm .. " : " .. ty)
                local tl = ty:lower()
                if tl:find("struct", 1, true) or tl:find("array", 1, true) then
                    dumpInnerStructFields(prop, pad)
                end
                -- recurse into live values for arrays + (non-component) objects
                if depth < MAX_DEPTH and not noDescend(nm) then
                    local wantArray  = tl:find("array", 1, true) ~= nil
                    local wantObject = tl:find("object", 1, true) ~= nil
                    if wantArray or wantObject then
                        local val
                        if pcall(function() val = obj[nm] end) and val ~= nil then
                            walkValue(val, depth + 1, nm)
                        end
                    end
                end
            end)
        end)
        local ok, super = pcall(function() return cls:GetSuperStruct() end)
        cls = ok and super or nil
    end
end

-- Recurse a value: array -> first MAX_ELEMS elements; object -> walkObject;
-- otherwise a scalar/struct one-liner.
walkValue = function(v, depth, label)
    if depth > MAX_DEPTH then return end
    local pad = string.rep("  ", depth)

    local n = arrayCount(v)
    if n ~= nil then
        log(pad .. label .. " = TArray[" .. n .. "]")
        local lim = math.min(n, MAX_ELEMS)
        for i = 1, lim do
            local el
            if pcall(function() el = v[i] end) and el ~= nil then
                walkValue(el, depth + 1, "[" .. i .. "]")
            end
        end
        return
    end

    if isValidObj(v) then
        log(pad .. label .. " = OBJ " .. tryStr({ function() return v:GetClass():GetFullName() end })
            .. "  (" .. fullName(v) .. ")")
        walkObject(v, depth, pad)
        return
    end

    log(pad .. label .. " = " .. scalarStr(v))
end

-- Enumerate a shelf's UFunctions (Blueprint classes only, to skip native
-- AActor/UObject noise). This is what we need for the move primitive
-- (unknowns #4/#5): the analogue of the snack pack's "Spawn and Fill Snack".
local function dumpFunctions(obj)
    log("  -- functions (Blueprint classes only) --")
    local any = false
    local cls = obj:GetClass()
    local guard = 0
    while cls and isValidObj(cls) and guard < 8 do
        guard = guard + 1
        local cname = tryStr({
            function() return cls:GetFName():ToString() end,
            function() return cls:GetName() end,
        })
        if cname:find("_C", 1, true) then  -- BlueprintGeneratedClass
            pcall(function()
                cls:ForEachFunction(function(fn)
                    any = true
                    log("    fn[" .. cname .. "]: " .. propName(fn))
                end)
            end)
        end
        local ok, super = pcall(function() return cls:GetSuperStruct() end)
        cls = ok and super or nil
    end
    if not any then
        log("    ForEachFunction unavailable/empty -> probing candidate names by index:")
        for _, name in ipairs(CANDIDATE_FNS) do
            local v
            if pcall(function() v = obj[name] end) and v ~= nil then
                log("    candidate present: '" .. name .. "' (type " .. type(v) .. ")")
            end
        end
    end
end

-- ============================================================
-- find a placed (non-origin) cassette location to anchor the
-- shelf search on a stocked, visible shelf.
-- ============================================================
local function firstPlacedCassetteLoc()
    local carts = FindAllOf("Cartridge_Base_C")
    if not carts then return nil end
    for _, cart in pairs(carts) do
        if isValidObj(cart) and not fullName(cart):find("Default__") then
            local loc = getLoc(cart)
            if loc and (math.abs(loc.X) > 0.5 or math.abs(loc.Y) > 0.5) then
                return loc
            end
        end
    end
    return nil
end

-- ============================================================
-- SECTION A - find the movie shelf class + pick the nearest shelf
-- ============================================================
local function findShelf(refPoint)
    log("== SECTION A: shelf class discovery ==")
    if refPoint then
        log(string.format("  anchor (placed cassette) = (%s, %s, %s)",
            tostring(refPoint.X), tostring(refPoint.Y), tostring(refPoint.Z)))
    else
        log("  anchor: none (no placed cassette found) -> will dump the first shelf")
    end

    local best, bestD, bestName = nil, math.huge, nil
    local firstAny = nil
    for _, name in ipairs(SHELF_CANDIDATES) do
        local insts = FindAllOf(name)
        local count = 0
        for _, o in pairs(insts or {}) do
            if isValidObj(o) and not fullName(o):find("Default__") then
                count = count + 1
                if not firstAny then firstAny = o end
                local loc = getLoc(o)
                if refPoint and loc then
                    local d = dist2(loc, refPoint)
                    if d < bestD then best, bestD, bestName = o, d, name end
                end
            end
        end
        if count > 0 then
            log(string.format("  FindAllOf(%-42s) -> %d valid instance(s)", name, count))
        end
    end

    local chosen = best or firstAny
    if chosen then
        local loc = getLoc(chosen)
        log("  CHOSEN shelf = " .. fullName(chosen))
        if bestName then log("  chosen class = " .. bestName .. "  (nearest, dist=" .. string.format("%.1f", math.sqrt(bestD)) .. ")") end
        if loc then log(string.format("  chosen loc = (%s, %s, %s)", tostring(loc.X), tostring(loc.Y), tostring(loc.Z))) end
        return chosen
    end

    log("  no candidate matched -- running ForEachUObject keyword sweep (unique classes):")
    local seen = {}
    pcall(function()
        ForEachUObject(function(o)
            local ok, cn = pcall(function() return o:GetClass():GetFName():ToString() end)
            if not ok or not cn then return end
            local lc = cn:lower()
            for _, k in ipairs(CLASS_KEYWORDS) do
                if lc:find(k, 1, true) then
                    if not seen[cn] then seen[cn] = true; log("    class: " .. cn) end
                    break
                end
            end
        end)
    end)
    log("  (re-run the probe after adding the right class to SHELF_CANDIDATES)")
    return nil
end

-- ============================================================
-- SECTION B - dump the shelf's slot model + functions
-- v3: TARGETED + BOUNDED. The v2 generic deep walker recursed a
-- cycle (shelf -> containers -> cassettes -> product -> back-refs)
-- and produced 92k lines. v3 never recurses freely: it lists the
-- shelf's own properties (no value descent), then for container-ish
-- ARRAY properties dumps a bounded number of elements SHALLOWLY
-- (class + world loc + SKU read + one-level property list).
-- ============================================================

-- Array property names that plausibly hold the slots / owned objects.
local CONTAINER_HINTS = { "container", "owning", "shelve", "slot", "stored", "film", "cartridge", "content" }
-- Object/struct property names on a container that plausibly hold the cassette.
local STORED_HINTS = { "object", "stored", "owning", "cartridge", "product", "film", "content" }

local function nameMatches(nm, hints)
    local lc = nm:lower()
    for _, h in ipairs(hints) do if lc:find(h, 1, true) then return true end end
    return false
end

-- List an object's properties (names + types + inner struct fields) across the
-- whole class hierarchy. NO value recursion (this is what kept v2 bounded-safe).
local function listProps(obj, pad)
    local cls = obj:GetClass()
    local guard = 0
    while cls and isValidObj(cls) and guard < 8 do
        guard = guard + 1
        pcall(function()
            cls:ForEachProperty(function(prop)
                local nm = propName(prop)
                local ty = propType(prop)
                log(pad .. "  ." .. nm .. " : " .. ty)
                local tl = ty:lower()
                if tl:find("struct", 1, true) or tl:find("array", 1, true) then
                    dumpInnerStructFields(prop, pad)
                end
            end)
        end)
        local ok, super = pcall(function() return cls:GetSuperStruct() end)
        cls = ok and super or nil
    end
end

-- Try the cassette SKU/title read path on an arbitrary object (nil if not a cassette).
local function readCassette(o)
    local sku, title
    pcall(function()
        local ps   = o[PRODUCT_STRUCTURE_KEY]
        local base = ps and ps[BASE_STRUCTURE_KEY]
        local box  = base and base[BOX_DATA_KEY]
        sku = box and box[SKU_KEY]
        if box and box[TITLE_KEY] ~= nil then pcall(function() title = box[TITLE_KEY]:ToString() end) end
    end)
    return sku, title
end

-- Shallow dump of a single container/slot element: class, world loc, a SKU read
-- on the element itself, its property list (no recursion), and a one-level scan
-- of its object/struct props for a stored cassette.
local function shallowElement(o, pad)
    log(pad .. "  class = " .. tryStr({ function() return o:GetClass():GetFName():ToString() end }))
    local loc = getLoc(o)
    if loc then log(pad .. "  loc = (" .. tostring(loc.X) .. ", " .. tostring(loc.Y) .. ", " .. tostring(loc.Z) .. ")") end
    local sku, title = readCassette(o)
    if sku then log(pad .. "  *element IS a cassette* SKU=" .. tostring(sku) .. " title=" .. tostring(title)) end
    listProps(o, pad)
    -- one level: look for a stored cassette referenced by an object/struct prop
    local cls = o:GetClass()
    local guard = 0
    while cls and isValidObj(cls) and guard < 8 do
        guard = guard + 1
        pcall(function()
            cls:ForEachProperty(function(prop)
                local nm = propName(prop)
                local tl = propType(prop):lower()
                if (tl:find("object", 1, true) or tl:find("struct", 1, true)) and nameMatches(nm, STORED_HINTS) then
                    local v
                    if pcall(function() v = o[nm] end) and v ~= nil then
                        if isValidObj(v) then
                            log(pad .. "  -> '" .. nm .. "' = OBJ " .. fullName(v))
                            local s2, t2 = readCassette(v)
                            if s2 then log(pad .. "       stored cassette SKU=" .. tostring(s2) .. " title=" .. tostring(t2)) end
                            local l2 = getLoc(v)
                            if l2 then log(pad .. "       stored loc=(" .. tostring(l2.X) .. ", " .. tostring(l2.Y) .. ", " .. tostring(l2.Z) .. ")") end
                        else
                            log(pad .. "  -> '" .. nm .. "' = " .. scalarStr(v))
                        end
                    end
                end
            end)
        end)
        local ok, super = pcall(function() return cls:GetSuperStruct() end)
        cls = ok and super or nil
    end
end

local MAX_SLOTS = 16   -- dump up to this many container elements (enough to see ordering)

local function dumpShelf(shelf)
    log("== SECTION B: shelf slot model ==")
    if not shelf then log("  (no shelf found; skipping)"); return end
    log("  shelf = " .. fullName(shelf))
    log("  class = " .. tryStr({ function() return shelf:GetClass():GetFullName() end }))
    dumpFunctions(shelf)

    log("  -- top-level properties (names+types, NO recursion) --")
    listProps(shelf, "")

    -- Summary line for EVERY array property (count only) so the container array
    -- is visible even if its name doesn't match our hints.
    log("  -- all array properties (counts) --")
    do
        local cls = shelf:GetClass()
        local guard, seen = 0, {}
        while cls and isValidObj(cls) and guard < 8 do
            guard = guard + 1
            pcall(function()
                cls:ForEachProperty(function(prop)
                    local nm = propName(prop)
                    if seen[nm] then return end
                    if propType(prop):lower():find("array", 1, true) then
                        seen[nm] = true
                        local val, n = nil, -1
                        if pcall(function() val = shelf[nm] end) and val ~= nil then n = arrayCount(val) or -1 end
                        log("    array '" .. nm .. "' count=" .. tostring(n))
                    end
                end)
            end)
            local ok, super = pcall(function() return cls:GetSuperStruct() end)
            cls = ok and super or nil
        end
    end

    -- Bounded element dump for container-ish array properties.
    log("  -- container/slot arrays (bounded, shallow) --")
    do
        local cls = shelf:GetClass()
        local guard, seen = 0, {}
        while cls and isValidObj(cls) and guard < 8 do
            guard = guard + 1
            pcall(function()
                cls:ForEachProperty(function(prop)
                    local nm = propName(prop)
                    if seen[nm] then return end
                    local isArray = propType(prop):lower():find("array", 1, true) ~= nil
                    if isArray and nameMatches(nm, CONTAINER_HINTS) then
                        seen[nm] = true
                        local val
                        if not (pcall(function() val = shelf[nm] end) and val ~= nil) then return end
                        local n = arrayCount(val) or -1
                        log("  ARRAY '" .. nm .. "' count=" .. tostring(n))
                        local lim = math.min(n >= 0 and n or 0, MAX_SLOTS)
                        for i = 1, lim do
                            local el
                            if pcall(function() el = val[i] end) and el ~= nil then
                                if isValidObj(el) then
                                    log("    [" .. i .. "] OBJ " .. fullName(el))
                                    shallowElement(el, "    ")
                                else
                                    log("    [" .. i .. "] = " .. scalarStr(el))
                                end
                            else
                                log("    [" .. i .. "] (unreadable)")
                            end
                        end
                    end
                end)
            end)
            local ok, super = pcall(function() return cls:GetSuperStruct() end)
            cls = ok and super or nil
        end
    end

    -- v4: dump the FIRST container's own BP functions + world location.
    -- This is the store/free move-primitive surface for Phase 3 (the
    -- analogue of the snack pack's placement functions), and confirms
    -- a container reports a world location even when empty (ordering).
    log("  -- first container: functions + world loc (move primitive recon) --")
    do
        local val
        if pcall(function() val = shelf["All Selve Containers"] end) and val ~= nil then
            local c0
            if pcall(function() c0 = val[1] end) and c0 ~= nil and isValidObj(c0) then
                local cloc = getLoc(c0)
                if cloc then
                    log("  container[1] world loc = (" .. tostring(cloc.X) .. ", " .. tostring(cloc.Y) .. ", " .. tostring(cloc.Z) .. ")")
                end
                dumpFunctions(c0)
            else
                log("  (could not read All Selve Containers[1])")
            end
        end
    end
end

-- ============================================================
-- SECTION C - confirm the cassette SKU read path + a placed location
-- ============================================================
local function dumpCassette()
    log("== SECTION C: cassette SKU/title read path ==")
    local carts = FindAllOf("Cartridge_Base_C")
    if not carts then log("  FindAllOf(Cartridge_Base_C) -> nil"); return end
    local shown = 0
    for _, cart in pairs(carts) do
        if shown >= 3 then break end
        if isValidObj(cart) and not fullName(cart):find("Default__") then
            pcall(function()
                local ps   = cart[PRODUCT_STRUCTURE_KEY]
                local base = ps and ps[BASE_STRUCTURE_KEY]
                local box  = base and base[BOX_DATA_KEY]
                local sku  = box and box[SKU_KEY]
                local title
                if box and box[TITLE_KEY] ~= nil then
                    pcall(function() title = box[TITLE_KEY]:ToString() end)
                end
                local loc = cart:K2_GetActorLocation()
                log(string.format("  cassette SKU=%s title=%s loc=(%s, %s, %s)",
                    tostring(sku), tostring(title),
                    loc and tostring(loc.X) or "?", loc and tostring(loc.Y) or "?", loc and tostring(loc.Z) or "?"))
                shown = shown + 1
            end)
        end
    end
    if shown == 0 then log("  no readable cassette found") end
end

-- ============================================================
-- SECTION D - persistence keying (find a per-save name/id)
-- ============================================================
local function dumpPersistence()
    log("== SECTION D: persistence key (gamemode + savegame) ==")
    local gms = FindAllOf("Core_Gamemode_C")
    local gm = gms and gms[1] or nil
    if not gm then log("  Core_Gamemode_C not found"); return end
    log("  gamemode = " .. fullName(gm))
    -- VALUES of the persistence-key candidates (this is the answer to unknown #6)
    for _, key in ipairs(PERSIST_KEYS) do
        local v
        if pcall(function() v = gm[key] end) and v ~= nil then
            log("  VALUE gm['" .. key .. "'] = " .. scalarStr(v))
        else
            log("  gm['" .. key .. "'] not readable")
        end
    end
    -- the SaveGame object hangs off the gamemode as "Save Game VHS"
    local sg
    if pcall(function() sg = gm["Save Game VHS"] end) and isValidObj(sg) then
        log("  -- Save Game VHS object: " .. fullName(sg))
        for _, key in ipairs({ "LevelName" }) do
            local v
            if pcall(function() v = sg[key] end) and v ~= nil then
                log("  VALUE savegame['" .. key .. "'] = " .. scalarStr(v))
            end
        end
    else
        log("  gm['Save Game VHS'] not readable")
    end
    log("  NOTE: SaveGames folder holds Player_Save1.sav + Player_Save2.sav (active = Save2).")
    log("        Expect 'Save Slot Name' to equal the active .sav basename.")
end

-- ============================================================
-- ENTRY
-- ============================================================
local function runProbe()
    log("================= PROBE START (" .. VERSION .. ") =================")
    local ref = firstPlacedCassetteLoc()
    local shelf = findShelf(ref)
    dumpShelf(shelf)
    dumpCassette()
    dumpPersistence()
    log("================= PROBE END =================")
end

local function onProbe()
    ExecuteInGameThread(function()
        local ok, err = pcall(runProbe)
        if not ok then log("PROBE ERROR: " .. tostring(err)) end
    end)
end

-- F8 hotkey (game or UE4SS console must be focused for keybinds to fire).
RegisterKeyBind(Key.F8, onProbe)

-- Console command alias: type `rrprobe` in the in-game `~` / `` ` `` console.
-- This is the reliable trigger since the GUI console never spawns here.
RegisterConsoleCommandHandler("rrprobe", function()
    onProbe()
    return true
end)

log("RR Shelf Keeper PROBE loaded (" .. VERSION .. "). Press F8 or type `rrprobe` in the console.")

-- Approach A1 recon lived in airecon.lua (F7 / `rrrecon` + observational restock hooks). It located the
-- slot-chooser hook (CLAUDE.md §6.8) and is now disabled — the file is kept as the recon record but no
-- longer required, so its hooks don't fire during play. Re-add `require("airecon")` to use it again.
