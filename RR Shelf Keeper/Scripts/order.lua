-- RR Shelf Keeper — physical fill order for ordered restock (Approach A1).
-- Pure: decides which empty container the staff should fill next, from container world positions.
-- Slot world transform (Phase 0 §6.3): Z = row, Y = column, X tilts with Z (ignored for ordering).
local M = {}

-- Group a Z coordinate into an integer row key so near-equal Z values are one row (float noise +
-- slight per-slot variance). tol ≈ half the row spacing (rows are ~30 apart; default 15).
local function rowKey(z, tol) return math.floor((z or 0) / tol + 0.5) end

-- A container's row (up-down) and column (left-right) coordinates. Prefer explicit row/col (which
-- restock.lua feeds as SHELF-RELATIVE coords so double-sided shelves order consistently); fall back
-- to raw world loc (loc.z = row, loc.y = column) when they aren't supplied (e.g. offline tests).
local function rowVal(c) if c.row ~= nil then return c.row end return c.loc and c.loc.z end
local function colVal(c) if c.col ~= nil then return c.col end return c.loc and c.loc.y end

-- nextEmpty(containers, rule) -> index | nil
--   containers : array of { index=int, isEmpty=bool, (row,col) or loc={x,y,z} }
--   rule       : { topFirst=bool(default true), leftFirst=bool(default true), rowTol=num(default 15) }
-- Returns the `index` of the empty container first in physical fill order (row then column), or nil.
function M.nextEmpty(containers, rule)
    rule = rule or {}
    local topFirst  = rule.topFirst  ~= false       -- default true
    local leftFirst = rule.leftFirst ~= false       -- default true
    local tol = rule.rowTol or 15

    local empties = {}
    for _, c in ipairs(containers or {}) do
        local r, co = rowVal(c), colVal(c)
        if c.isEmpty and r ~= nil and co ~= nil then
            empties[#empties + 1] = { index = c.index, r = r, co = co }
        end
    end
    if #empties == 0 then return nil end

    table.sort(empties, function(a, b)
        local ar, br = rowKey(a.r, tol), rowKey(b.r, tol)
        if ar ~= br then
            if topFirst then return ar > br else return ar < br end
        end
        if a.co ~= b.co then
            if leftFirst then return a.co < b.co else return a.co > b.co end
        end
        return a.index < b.index                     -- stable, deterministic tiebreak
    end)
    return empties[1].index
end

return M
