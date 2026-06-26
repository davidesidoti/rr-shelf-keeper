# rr-shelf-keeper — Progress Log

One place to record what each session did and what the next session needs to know.
**Append a new dated entry at the end of every session.** Read this top-to-bottom before
starting any phase (it is listed in every phase's PREREQUISITES).

## How to use this file
- One dated entry per session. Newest at the bottom.
- Each entry: **Phase**, **What was done**, **What I learned** (facts that should also go
  into `CLAUDE.md`), **What's next / gotchas for the next session**.
- Durable, reusable facts (struct keys, class names, function signatures, the move
  primitive, the persistence key) belong in `CLAUDE.md` too — this log is the narrative;
  `CLAUDE.md` is the reference.

## Status at a glance
- **Current phase:** Phase 2 (persist snapshot to a per-save file + load back) — ready to start.
- **Phase 1:** **COMPLETE (2026-06-26).** Shipping mod `RR Shelf Keeper/` built; `layout.snapshot()`
  verified in-game (56 shelves / 1019 slots, SKUs + titles correct, empties marked). In-memory
  only — no file I/O yet. Probe stays installed (read-only) until Phase 6.
- **Phase 0 gate:** **CLOSED (2026-06-26).** All six §6 unknowns resolved and written into
  `CLAUDE.md` §3 + §6. Feature code (Phase 1+) may begin.

---

## Log

### 2026-06-26 — Planning session (no in-game work)
**Phase:** Pre-Phase-0 (scoping only).

**What was done:**
- Read this repo's `CLAUDE.md`, the sibling `D:\Github\rr-dupe-finder\` (`CLAUDE.md` +
  all `RR Dupe Finder\Scripts\*.lua`), and the reference mods (Auto Restock Snacks QoL,
  SKU QoL, Employee Mod) under the game's `Mods\` folder.
- Wrote the phased build plan → `docs/PLAN.md` (Phases 0–7).
- Wrote the **read-only Phase 0 probe mod** → `probe/RR Shelf Keeper Probe/`
  (`enabled.txt` + `Scripts/main.lua`, version marker `probe-v1`). F8 / `rrprobe` dumps:
  (A) shelf-class discovery, (B) reflection+value dump of the first shelf's slot model,
  (C) cassette SKU/title read-path confirmation + a placed location, (D) gamemode +
  savegame persistence-key candidates. All tagged `[RR-Probe]`.
- Created this file.

**What I learned (carry into Phase 0 / already reflected in `docs/PLAN.md`):**
- **No Live View on this install.** The sibling repo confirms `GraphicsAPI = opengl` makes
  the UE4SS GUI window never spawn even with `GuiConsoleEnabled = 1` (sibling gotcha 11).
  So `CLAUDE.md` §6's "enable Live View first" is moot — Phase 0 uses **Lua reflection**
  (`UStruct:ForEachProperty`, `StructProperty:GetStruct()`, `ArrayProperty:GetInner()`)
  and reads `UE4SS.log` from disk. The probe is built around this.
- **"Synchronous" precisely.** The real rule (sibling gotcha 19): a *continuous async
  loop* touching UObjects (`LoopAsync` on a worker thread) hard-crashes the Lua VM. A
  one-shot keybind → `ExecuteInGameThread(fn)` is safe. All shelf work must be one-pass on
  the game thread.
- **Two hard-crash traps for later visual feedback:** `CreateDynamicMaterialInstance`
  (sibling gotcha 10) and `TextRenderComponent:SetText(FText)` (gotcha 17) both
  native-crash (uncatchable by `pcall`). Use a spawned marker mesh + a **premade**
  material via `SetMaterial` — the recipe is in the sibling's `highlight.lua`
  (`BeginDeferredActorSpawnFromClass` 6 args → `SetMobility(2)`/`SetStaticMesh` →
  `FinishSpawningActor` 3 args → `SetMaterial` after finish).
- **Verified cassette keys (verbatim, from the sibling):**
  - `Product Structure` → `BaseStructure_2_FBB12C464AE570CAFD12ED8506160683`
    → `BoxData_25_B5A798DA4F509BDCCF4B189171C1DA10`
    → SKU `SKU_26_C5F25F4E49D05A4DEC2DEEAE5AEE5876` (int),
      title `ProductName_14_055828B1436E5AD27BFA95AF181099DE` (FText → `:ToString()`).
- **Snack shelf model (the movie analogue to look for):** `SnackShelf_C` →
  `"As Snack Pack"` (array) → pack → `"Snack Container Array"` (array) → container →
  `"has a Snack"` (bool) + `"Snack Stored"` (item w/ `"Price"`). Placement functions:
  `pack["Return Snack Base Save Struct"](out)` then `pack["Spawn and Fill Snack"](struct)`
  with `savePack[SNACK_COUNT_KEY] = totalSlots`. **Movie shelves are expected to mirror
  this shape but with `Cartridge_Base_C` actors in slots** — Phase 0 confirms.
- **Persistence:** the SaveGame object hangs off the gamemode as `gm["Save Game VHS"]`
  (per Employee Mod). The `.sav` filename in `%LOCALAPPDATA%\RetroRewind\Saved\SaveGames\`
  is the ground-truth per-save key. Phase 0 Section D probes both.
- **Trigger hooks already known to work** (sibling/snack mod): `OpenSign_C:Change Sign`,
  `WeatherSystem_C:Timer Event - Add one minute`, `WeatherSystem_C:ReceiveBeginPlay`,
  `Core_Gamemode_C:End of the day` — all registered late via `ExecuteWithDelay(3000,...)`.
- **Commit attribution (flagged, non-blocking):** the sibling repo's policy is commits
  attributed **only** to the user with **no `Co-Authored-By` trailer**. Confirm with the
  user before the first commit here; nothing was committed this session.

**What's next (Phase 0):**
1. Install the probe junction (command in `docs/PLAN.md` → Ground rules).
2. Load a save with a stocked movie store, stand near a movie shelf, press **F8** (or
   `rrprobe`).
3. Read `UE4SS.log`, grep `[RR-Probe]`, work Sections A→D; iterate the probe (bump
   `VERSION`, edit `SHELF_CANDIDATES` / `MAX_DEPTH`, Ctrl+R) until all six §6 unknowns are
   answered.
4. Write every answer into `CLAUDE.md` (§3 + §6) and append the next dated entry here.

**Open question for the user (non-blocking):** confirm there is a save where movie shelves
are already stocked with cassettes (Phase 0 needs real slot data to dump). If not, place a
few cassettes on a shelf before pressing F8.

---

### 2026-06-26 — Phase 0: runtime investigation (COMPLETE, gate CLOSED)
**Phase:** Phase 0. Probe iterated v1→v4 (read-only, F8 / `rrprobe`). Save `Player_Save2`,
level `L_Player_Store_01`, store stocked (~497 cartridges, 56 shelves in the save).

**What was done:**
- Installed the probe junction into `...\ue4ss\Mods\RR Shelf Keeper Probe`; confirmed hot
  reload (Ctrl+R) picks up a newly-added Lua mod with no game restart (banner in `UE4SS.log`).
- **probe-v1:** candidate shelf classes all returned 0; the `ForEachUObject` keyword sweep
  revealed the real classes. Section C confirmed the SKU read path; Section D dumped the
  gamemode + `SaveGame_VHS_C` structure.
- **probe-v2:** added the real shelf classes + `ForEachFunction` + persistence-key VALUES.
  The generic deep walker recursed a cycle and produced **92,607 log lines** in one pass.
- **probe-v3:** replaced Section B with a BOUNDED targeted dumper (props/functions listed
  without value descent; container arrays dumped shallowly, ≤16 elems). 5k lines, clean.
- **probe-v4:** added a dump of the first `Shelve_Container_C`'s own functions +
  `K2_GetComponentLocation` (confirms empty-slot world pos is readable).

**What I learned (all in `CLAUDE.md` §3/§6 now — the durable copy):**
- **Shelf classes:** ~18 movie leaf classes, base **`Shelve_C`** (`Shelf_Movie_*`,
  `Shelf_NewMovie_*`, `Shelf_Movie-Display_*`, `MovieDisplay_C`). No single `MovieShelf_C`.
- **Slot model:** `shelf["All Selve Containers"]` (TArray, typo "Selve") → `Shelve_Container_C`
  components → `container["Object owning of this container"]` → the `videotape_C` cassette
  (SKU via the sibling's §13 keys, re-confirmed). Per-slot genre filter via `Accept Class type`
  + `Film Error Accepted/Refused`.
- **Ordering:** slot world transform via `K2_GetComponentLocation` (works empty); Z = row,
  Y = column. **Array index is stable but NOT a physical sweep** → use index as the slot id;
  sort by (Z, Y) only for forced-order.
- **Move primitive:** `Shelve_Container_C["Store Object From Game Code And No Animation"]`
  (no-anim, code-driven) + `Empty Container` + `Does it fit in the container?` +
  `Return is container empty` + `Set Stored Object to Container Transform`. Far cleaner than
  manual teleport+rewrite (which is the fallback).
- **Persistence key:** `gm["Save Slot Name"]` = `.sav` basename (this session: `Player_Save2`).
- **Approach A (Phase 7):** AI funcs exist on `Shelve_C`/`Shelve_Container_C`, but the random
  empty-slot choice was not found there (likely AiDirector/BT). Stays optional; doesn't block B.

**What's next (Phase 1):** implement the shipping mod `RR Shelf Keeper/` and
`layout.snapshot()` — `FindAllOf` the movie shelves, read `All Selve Containers` →
`Object owning of this container` → SKU, key each slot by array index, log per shelf. Decide
the shelf-id scheme (full name vs `GUID Shelf` A/B/C/D vs name+loc) and whether
`FindAllOf("Shelve_C")` returns subclasses (filter to movie leaves if so). Probe stays
installed (read-only) until Phase 6.

**Gotchas added to `CLAUDE.md` §7 this session:** slot index ≠ physical order; never
free-recurse the live object graph (bound all recon); `Shelve_C` is a shared base (filter to
movie leaves); placed cassette = `videotape_C`.

---

### 2026-06-26 — Phase 1: layout snapshot (COMPLETE)
**Phase:** Phase 1. Mod versions `shelf-v1` → `shelf-v2` (one in-game fix). Verified on
`Player_Save2` (game already running from the Phase 0 session; Ctrl+R hot-reload, F9).

**What was done:**
- Built the shipping mod `RR Shelf Keeper/` (junctioned into `...\ue4ss\Mods\` the same way as
  the probe): `enabled.txt` + `Scripts/{main,config,sku,layout}.lua`. Module map matches
  `docs/PLAN.md` §"Module map".
  - `sku.lua` — cassette SKU/title read, **copied verbatim** from the sibling (`Product Structure`
    → `BaseStructure_2_…` → `BoxData_25_…` → `SKU_26_…` / `ProductName_14_…`). Re-confirmed live.
  - `layout.lua` — `snapshot()` enumerates the §6.1 movie leaf classes via `FindAllOf`, skips
    `Default__`, reads `All Selve Containers` → `Object owning of this container` → SKU, keys each
    slot by **array index** and each shelf by **`GetFName`**. Pure helpers `shelfId`/`format` are
    unit-tested (`tests/layout_test.lua`, 10/10 pass under standalone `lua`).
  - `main.lua` — **F9** hotkey + `rrshelf snapshot` console command, one `ExecuteInGameThread`
    pass, output tagged `[RR-Shelf]`, `VERSION` banner per the build-loop rule.
- `shelf-v1` worked first try but exposed a real bug (below); `shelf-v2` fixed it. Both runs
  reported identical totals: **56 shelves | 1019 slots | 378 filled | 641 empty**, no errors.

**What I learned (durable copy is in `CLAUDE.md` §3 "Shelf identity" + §7):**
- **Movie shelves are double-sided → co-located actor PAIRS.** Two shelf actors share the same
  world location, ~180° apart in yaw (e.g. `(1020,-1610,0)` yaw `+90` vs `-90`; one side often
  stocked, the other empty). **Rounded location is NOT a unique shelf key** — `shelf-v1` keyed by
  `class@loc` and collided every pair (and made `table.sort` on equal keys non-deterministic).
  `shelf-v2` keys by `GetFName` (unique per instance) and logs `yaw` to expose the pairing.
- **Shelves are runtime-spawned from the save.** `GetFName` instance numbers are near `INT32_MAX`
  (e.g. `Shelf_Movie_4Row_01_C_2147476245`) → unique *this session* but they will renumber on
  reload. **`GetFName` is not a cross-restart key.**
- **Enumeration:** the explicit §6.1 leaf list via `FindAllOf` is sufficient (56 shelves found);
  did not need `FindAllOf("Shelve_C")`.
- **Snapshot shape (what Phase 2 serializes):** `{ shelfCount, totalSlots, totalFilled,
  shelves = [ { id=GetFName, class, name=fullname, loc={x,y,z}, yaw, slotCount, filled,
  slots = [ { index, sku|nil, title|nil } ] } ] }`. Shelves sorted by (loc, id) for a
  deterministic, idempotent dump.

**What's next (Phase 2):** persist the snapshot to a per-save side file and load it back.
**First task is to settle the durable shelf key**, since `GetFName` won't survive a restart:
probe the `GUID Shelf` struct's verbatim field keys (or `Shelve_Save.ID`) and re-key the snapshot
on the GUID before serializing. Persistence key for the *file name* = `gm["Save Slot Name"]`
(Phase 0; `Player_Save2`). Use Lua `io`, write under `RR Shelf Keeper/layouts/<key>.lua`, all I/O
`pcall`-guarded. Decision needed: store per-shelf GUID + per-slot {index→SKU}; an empty slot is a
real, recorded value (slot exists, SKU nil), not an omission.

**Open item:** nothing was committed. `CLAUDE.md` is gitignored; `RR Shelf Keeper/`, `tests/`,
`docs/` are tracked. Awaiting the user's go-ahead to commit Phase 1 (sole-author, no
`Co-Authored-By`, per the policy in `CLAUDE.md` §10).
