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

    -- Where layout files are written: "<this>/<saveKey>.lua". nil = auto-resolve to the mod's
    -- own "layouts/" folder (store.resolveDir self-locates via the module path). Set an absolute
    -- path here only if auto-resolution lands in the wrong place (the resolved dir is logged).
    LayoutsDir  = nil,
}
