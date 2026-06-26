-- RR Shelf Keeper — configuration
-- Phases extend this file (later: enforce triggers, ordering rule, managed-shelf selection).
-- Keep it a plain return-table.
return {
    Debug       = false,    -- verbose logging (extra diagnostics)

    -- Snapshot hotkey (Phase 1). Resolved in main.lua via Key[SnapshotKey].
    SnapshotKey = "F9",
    Modifiers   = {},       -- optional, e.g. { "CONTROL" }, resolved via ModifierKey[name]

    -- Phase 2 persistence. save/load are console-driven by default (`rrshelf save` / `rrshelf
    -- load`) — a deliberate choice so a disk write is never a fat-fingered keypress. Set these
    -- to a key name (e.g. "F7"/"F6") to also bind a hotkey; nil = console-only.
    SaveKey     = nil,
    LoadKey     = nil,

    -- Phase 3 enforcement. F10 runs a DRY RUN only (logs the correction plan + reflects the move-
    -- primitive's BP arg signature, mutates nothing) — safe to press anytime. The actual mutation
    -- is console-only and deliberate: `rrshelf enforce go` (no hotkey), because the primitive's arg
    -- signature is unconfirmed and a wrong BP call can NATIVE-crash. Set EnforceKey=nil for
    -- console-only. There is intentionally no hotkey that mutates.
    EnforceKey  = "F10",

    -- Where layout files are written: "<this>/<saveKey>.lua". nil = auto-resolve to the mod's
    -- own "layouts/" folder (store.resolveDir self-locates via the module path). Set an absolute
    -- path here only if auto-resolution lands in the wrong place (the resolved dir is logged).
    LayoutsDir  = nil,

    -- Phase A1: ordered restock (staff fill the next empty slot in physical order).
    OrderedRestock = true,    -- master enable for the at-restock slot override
    RestockDryRun  = false,   -- true = only LOG what it would set; false = APPLY the override
    RestockVerbose = false,   -- log each applied override (fires per shelf during shelf-finding; debug only)
    FillTopFirst   = true,    -- rows top→bottom (Z descending); set false to fill bottom-up
    FillLeftFirst  = true,    -- columns left→right (Y ascending); flip if it comes out mirrored
    RowTol         = 15,      -- Z grouping tolerance for "same row" (rows are ~30 apart)
}
