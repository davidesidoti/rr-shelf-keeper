-- RR Shelf Keeper — ordered restock (Approach A1): override the staff's slot choice.
--
-- Hooks Shelve_C:"Does any Shelve Containers still empty" — the function the restock AI calls to get
-- the empty container it will stock (the staff fill exactly the container it returns; the default
-- rule returns the highest array-index empty). We rewrite that returned `Empty Container` to the
-- next empty slot in PHYSICAL order (order.lua), so staff fill in order. The hook point and its
-- POST-callback behaviour were confirmed by the Phase-A1 recon documented in CLAUDE.md §6.8.
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

local function getActorLoc(a)
    local loc
    if pcall(function() loc = a:K2_GetActorLocation() end) and loc then
        return { x = loc.X, y = loc.Y, z = loc.Z }
    end
    return nil
end

local function getYaw(a)
    local yaw
    pcall(function() yaw = a:K2_GetActorRotation().Yaw end)
    return yaw
end

-- Read a shelf's containers -> array of { index, obj, loc(world), row, col, isEmpty }.
-- row = world Z (up-down; yaw doesn't change height). col = the container's offset projected onto the
-- shelf's RIGHT vector (from its yaw) → a left-right coordinate RELATIVE to the shelf's own facing, so
-- co-located double-sided shelves (which face ~180° apart) both order from the same physical end.
local function readContainers(shelf)
    local out = {}
    local arr
    pcall(function() arr = shelf[CONTAINER_ARRAY_KEY] end)
    if not arr then return out end
    local sLoc = getActorLoc(shelf) or { x = 0, y = 0, z = 0 }
    local yr = math.rad(getYaw(shelf) or 0)
    local rX, rY = -math.sin(yr), math.cos(yr)        -- shelf right vector in the XY plane
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
            local w = getCompLoc(c)
            local rec = { index = i, obj = c, loc = w, isEmpty = isEmpty }
            if w then
                rec.row = w.z
                rec.col = (w.x - sLoc.x) * rX + (w.y - sLoc.y) * rY
            end
            out[#out + 1] = rec
        end
    end
    return out
end

local function ruleFromConfig()
    return { topFirst = Config.FillTopFirst, leftFirst = Config.FillLeftFirst, rowTol = Config.RowTol }
end

-- Compute the target container for a shelf (next empty slot in physical order).
-- Returns obj, idx, loc, nEmpty, nNoLoc — the diagnostics let us verify the fill SEQUENCE in-game
-- and detect the one real failure mode: an empty slot whose world position can't be read (nNoLoc>0)
-- would be dropped from the ordering and cause a premature jump to a lower row.
function M.targetContainer(shelf)
    local conts = readContainers(shelf)
    local nEmpty, nNoLoc = 0, 0
    for _, c in ipairs(conts) do
        if c.isEmpty then
            nEmpty = nEmpty + 1
            if not c.loc then nNoLoc = nNoLoc + 1 end
        end
    end
    local idx = order.nextEmpty(conts, ruleFromConfig())
    if not idx then return nil, nil, nil, nil, nEmpty, nNoLoc end
    for _, c in ipairs(conts) do
        if c.index == idx then return c.obj, idx, c.loc, c.col, nEmpty, nNoLoc end
    end
    return nil, nil, nil, nil, nEmpty, nNoLoc
end

local function locStr(loc)
    if not loc then return "(?)" end
    return string.format("(%.0f,%.0f,%.0f)", loc.x, loc.y, loc.z)
end

-- Hook callback for "Does any Shelve Containers still empty".
-- UE4SS passes the function's params after self: (self, OneContainerIsEmpty, EmptyContainer).
-- In DryRun we only LOG (validate the params + target); otherwise we :set() the out-params.
function M.onDoesAnyEmpty(self, oneEmptyParam, emptyContainerParam)
    if not Config.OrderedRestock then return end
    local ok, err = pcall(function()
        local shelf = self:get()
        if not isManagedMovieShelf(shelf) then return end
        local target, idx, loc, col, nEmpty, nNoLoc = M.targetContainer(shelf)
        if not target then return end

        if Config.RestockDryRun then
            local sname, tname = "?", "?"
            pcall(function() sname = shelf:GetFName():ToString() end)
            pcall(function() tname = target:GetFName():ToString() end)
            local curEmpty, curName = nil, "?"
            pcall(function() curEmpty = emptyContainerParam:get() end)
            if curEmpty then pcall(function() curName = curEmpty:GetFName():ToString() end) end
            log(string.format("[restock dry] %s: game '%s' -> would set '%s' idx %s %s col=%.0f empties=%d noloc=%d",
                sname, curName, tname, tostring(idx), locStr(loc), col or 0, nEmpty, nNoLoc))
        else
            pcall(function() emptyContainerParam:set(target) end)
            pcall(function() if oneEmptyParam then oneEmptyParam:set(true) end end)
            if Config.RestockVerbose then
                local sname, tname = "?", "?"
                pcall(function() sname = shelf:GetFName():ToString() end)
                pcall(function() tname = target:GetFName():ToString() end)
                log(string.format("[restock] %s -> %s idx %s %s col=%.0f empties=%d noloc=%d",
                    sname, tname, tostring(idx), locStr(loc), col or 0, nEmpty, nNoLoc))
            end
        end
    end)
    if not ok then log("ordered-restock hook error: " .. tostring(err)) end
end

return M
