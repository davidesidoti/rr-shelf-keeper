-- RR Shelf Keeper — configuration (Phase A1: ordered restock).
-- Plain return-table. Consumed by restock.lua (the slot override) and main.lua (the hook).
return {
    -- Phase A1: ordered restock — staff fill the next empty slot in physical order.
    OrderedRestock = true,    -- master enable for the at-restock slot override
    RestockDryRun  = false,   -- true = only LOG what it would set; false = APPLY the override
    RestockVerbose = false,   -- log each applied override (fires per shelf during shelf-finding; debug only)
    FillTopFirst   = true,    -- rows top→bottom (Z descending); set false to fill bottom-up
    FillLeftFirst  = true,    -- columns left→right (shelf-relative); flip if it comes out mirrored
    RowTol         = 15,      -- Z grouping tolerance for "same row" (rows are ~30 apart)
}
