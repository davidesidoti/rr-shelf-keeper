-- RR Shelf Keeper — cassette product-struct read path.
-- COPIED VERBATIM from the sibling rr-dupe-finder (its sku.lua) — the most build-fragile
-- module. Reuse, do not re-derive. The GUID-mangled keys below are confirmed in this build
-- (CLAUDE.md §5/§13; re-confirmed Phase 0, e.g. SKU 1532223 = "The Kennel, Our Hero").
-- Placed movie cassettes are the videotape_C subclass of Cartridge_Base_C and carry these
-- same product-structure keys.
local M = {}

-- GUID-mangled Blueprint struct property names. Do NOT guess; copy verbatim.
local PRODUCT_STRUCTURE_KEY = "Product Structure"
local BASE_STRUCTURE_KEY    = "BaseStructure_2_FBB12C464AE570CAFD12ED8506160683"
local BOX_DATA_KEY          = "BoxData_25_B5A798DA4F509BDCCF4B189171C1DA10"
local SKU_KEY               = "SKU_26_C5F25F4E49D05A4DEC2DEEAE5AEE5876"
local TITLE_KEY             = "ProductName_14_055828B1436E5AD27BFA95AF181099DE"

-- True only for a real, usable cassette actor (valid + not the class default object).
-- An empty slot's "Object owning of this container" yields nil / an invalid ref → false here.
function M.isCartridge(obj)
    if not obj then return false end
    local ok, valid = pcall(function() return obj.IsValid and obj:IsValid() end)
    if not ok or valid ~= true then return false end
    local okn, name = pcall(function() return obj:GetFullName() end)
    if okn and name and name:find("Default__") then return false end   -- skip CDO
    return true
end

-- Navigate to the BoxData struct that holds SKU + title. Returns the struct or nil.
local function box(cart)
    local ps   = cart[PRODUCT_STRUCTURE_KEY]; if not ps   then return nil end
    local base = ps[BASE_STRUCTURE_KEY];      if not base then return nil end
    return base[BOX_DATA_KEY]
end

-- Returns the integer SKU, or nil if any struct level is missing.
function M.read(cart)
    local sku
    pcall(function()
        local b = box(cart)
        if b then sku = b[SKU_KEY] end
    end)
    return sku
end

-- Returns the movie title as a Lua string, or nil.
-- The field is an FText (userdata) → stringify with value:ToString() (NOT tostring, which
-- yields a userdata address). pcall-wrapped; an empty string is treated as nil.
function M.readTitle(cart)
    local title
    pcall(function()
        local b = box(cart); if not b then return end
        local t = b[TITLE_KEY]; if t == nil then return end
        local ok, s = pcall(function() return t:ToString() end)
        if ok and s ~= nil and s ~= "" then title = s end
    end)
    return title
end

return M
