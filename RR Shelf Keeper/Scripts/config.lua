-- RR Shelf Keeper — configuration
-- Phase 1 only needs the snapshot hotkey; later phases extend this file (store/enforce
-- triggers, ordering rule, managed-shelf selection). Keep it a plain return-table.
return {
    Debug       = false,    -- verbose logging (extra diagnostics)
    SnapshotKey = "F9",     -- resolved in main.lua via Key[SnapshotKey]
    Modifiers   = {},       -- optional, e.g. { "CONTROL" }, resolved via ModifierKey[name]
}
