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
- **Current feature:** **Approach A1 — ordered restock — WORKING & CONFIRMED IN-GAME (shelf-v13, 2026-06-26).**
  Staff restock each movie into the next empty slot in physical order (top→bottom, left→right), no gaps, by
  overriding the AI slot-chooser `Shelve_C:Does any Shelve Containers still empty` (POST hook → `:set()` the
  returned `Empty Container`). Columns are ordered SHELF-RELATIVE (projected on the shelf right-vector) because
  movie shelves are double-sided pairs facing ~180° apart. No cassette is moved after placement. Durable record
  in `CLAUDE.md` §6.8; spec/plan under `docs/superpowers/`. **Cleanup TODO:** remove the `airecon` recon probe
  (log noise); optionally remove the now-unused Phase 1–3 save/enforce modules. Nothing committed yet.
- **Phase 3 (Approach B, physical enforce):** SET ASIDE — not the mechanism the user wanted. Code present but
  the store-call convention was never fully proven; resume only if post-hoc enforce is ever needed.
- **Current phase:** Phase 3 (layout enforcement — the correction primitive) — **CODE COMPLETE (shelf-v6);
  DRY RUN signatures CONFIRMED in-game; `go` mutation still UNVALIDATED.** Pure `diff`/`plan` TDD'd (30
  assertions) + `apply` collect→place orchestration offline-tested with fakes (13 assertions, cyclic-swap
  safe). shelf-v5's dry run native-crashed in `reflectSignature` (ForEachFunction on native classes) —
  **fixed in shelf-v6** (gate to `_C`, mirror the probe); that run also CONFIRMED the BP signatures: store =
  **`Store Object …(Object to store, Set Location:bool)`** (two args; `apply` now passes `(cart, true)`).
  USER must re-run the dry run (no crash now) then `rrshelf enforce go`. See the Phase 3 entries.
- **Phase 2:** **COMPLETE (2026-06-26, shelf-v4).** Per-save layout file (`layouts/<key>.lua`, sandboxed
  Lua return-table); durable shelf key = **loc+yaw** (GUID reflection native-crashed — removed, §6.7/§7).
  Save→restart→load round-trip verified (56/1019/378/641, 0 collisions). 60 offline assertions pass.
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

---

### 2026-06-26 — Phase 2: persist snapshot to a per-save file + load back (COMPLETE, VERIFIED)
**Phase:** Phase 2. Mod version `shelf-v2` → `shelf-v3` (crashed) → **`shelf-v4`** (fixed, verified).
**In-game round-trip CONFIRMED:** `rrshelf save` wrote `layouts/Player_Save2.lua`; after a **game
restart** `rrshelf load` reproduced the **identical 56 shelves / 1019 slots / 378 filled / 641
empty** layout (UE4SS.log 16:23:04). The saved file re-checked offline: version=2, 56 shelves,
**0 durable-key collisions**. Offline suites: **60/60 assertions across 4 suites** under standalone
`lua` (5.5 locally; UE4SS 5.4 — both take the modern `load(...,"t",{})` path).

**What was done (TDD for the pure modules — RED→GREEN watched each step):**
- **`store.lua`** (new) — serialize/deserialize + disk `save`/`load`. Format = a **Lua
  return-table** (no JSON dep; CLAUDE.md §5), deserialized in an **empty sandbox env**
  (`load(s,"=layout","t",{})`) so a tampered layout file can't execute code. Integers emit
  without `.0` (SKUs read clean); output is key-sorted → deterministic/idempotent. `resolveDir`
  self-locates `<mod>/layouts/` from `debug.getinfo(1,"S").source` (override `config.LayoutsDir`),
  logged each save. `tests/store_test.lua` (18 checks: round-trip, idempotency, escaping,
  garbage/empty/non-table → nil+err, sandbox blocks `os.*`, disk round-trip, missing file).
- **`key.lua`** (new) — `sanitize()` (keep `[A-Za-z0-9_-]`; dots→`_` kills `../`; empty/non-string
  →`"default"`) + runtime `fromGamemode()` reading `gm["Save Slot Name"]`. `tests/key_test.lua`
  (11 checks).
- **`layout.lua`** (extended) — added pure **`durableShelfId`** (GUID `"g:a-b-c-d"` → loc+yaw
  `"l:x,y,z,yaw"` fallback) and **`toPersist`** (project live snapshot → focused on-disk shape,
  format-compatible); runtime **`readGuidInts`** (reflective GUID read, **no hardcoded mangled
  keys**, §7 #4); `snapshot()` now tallies GUID-read coverage + **durable-key collisions** + a
  GUID field-name sample; `format()` logs them. New tests in `tests/layout_test.lua` (+9) and a
  new end-to-end **`tests/persist_integration_test.lua`** (7 checks: `toPersist→save→load→format`,
  asserting the saved log == loaded log — the offline proxy for the in-game criterion).
- **`main.lua`** — `rrshelf save` / `rrshelf load` (+ optional `config.SaveKey`/`LoadKey` hotkeys,
  **nil by default → console-only**, deliberate so a disk write isn't a fat-fingered key). Each
  action is one `ExecuteInGameThread` + `pcall` pass. F9 still = snapshot.
- **`config.lua`** — added `SaveKey`/`LoadKey` (nil) + `LayoutsDir` (nil = auto-resolve).
- **`layouts/.gitkeep`** committed (dir must exist through the junction; `store.save` doesn't
  mkdir). `.gitignore` now ignores `RR Shelf Keeper/layouts/*.lua` + `tests/_tmp_*`.

**Key decisions (durable copy in `CLAUDE.md` §6.7):**
- **Serialization = Lua return-table**, not JSON — zero deps, and a sandboxed `load` is a safe
  one-liner deserializer.
- **Durable shelf key = serialized GUID, loc+yaw fallback.** GetFName renumbers across restarts
  (Phase 1), so it can't key persistence. The GUID is read **reflectively by enumerating the
  struct's int fields** — this sidesteps the "never hardcode GUID-mangled keys" rule entirely.
  loc+yaw is a fully durable+unique fallback on its own (static actors; pairs differ ~180° yaw).

**What's next / for the USER to verify in-game (the build-loop step I can't do):**
1. **Ctrl+R** to hot-reload; confirm `UE4SS.log` shows `loaded (shelf-v3`.
2. Stand in the stocked store, run **`rrshelf save`** in the `` ` `` console. In the log confirm:
   the `durable keys: GUID read for N/56 shelves; 0 collision(s)` line (note **whether N=56**, i.e.
   the GUID read worked, or it fell back to loc+yaw), the sampled **GUID field names**, and a final
   `SAVED 56 shelves / 1019 slots -> <path>`. Verify that `<path>\Player_Save2.lua` exists on disk.
3. **Restart the game**, load the same save, run **`rrshelf load`** → the logged layout must match
   the saved one. Then `rrshelf load` on a save with no file must log a clean "no layout" (no crash).
4. Report the log back. Then I'll finalize `CLAUDE.md` §6.7 (record GUID-read success + verbatim
   field names) and flip this entry to COMPLETE.

**Gotchas/edge cases handled:** empty slot persists as `{index=N}` (sku absent = intentional, not
omitted); bad/missing/tampered file → `nil`+logged error, never a crash; `Save Slot Name` unreadable
→ key `"default"` + warning; durable-key collision → warning before the save is trusted.

**Open item:** Phase 1 was committed (`cc639e9`); Phase 2 committed at the end of this session
(sole-author, no `Co-Authored-By`, `CLAUDE.md`/`layouts/*.lua` excluded per `.gitignore`).

#### Update — shelf-v3 `rrshelf save` NATIVE-CRASHED → fixed in shelf-v4 (durable key = loc+yaw)
**Symptom:** first in-game `rrshelf save` (shelf-v3) hard-crashed the game.
**Root cause (systematic-debugging, confirmed from UE4SS.log):** the log ended right after the
`loaded (shelf-v3` banner with **zero `[RR-Shelf]` output and no "Save error"** line. `runSave`'s
first output is *after* `layout.snapshot()` returns, and every action is `pcall`-wrapped — so a
caught Lua error would have been logged. None was → a **`pcall`-uncatchable NATIVE crash inside
`snapshot()`**. The v2 snapshot (line 107024+) ran cleanly over all 56 shelves printing yaw, so
`getLoc`/`getYaw`/`GetFName` are proven safe; the **only** native code v3 added to that path was
`readGuidInts` (reflective `GUID Shelf` read). That is the crash — same class as the DMI/SetText
native crashes (CLAUDE.md §7).
**Fix (shelf-v4):** removed `readGuidInts` entirely. Durable shelf key is now **loc+yaw**
(`durableShelfId(nil, loc, yaw)` — only proven-safe reads). Added pure `countDurableCollisions`
(the new safety gate: `format()` logs `durable keys (loc+yaw): N shelves, 0 collision(s)`, which
**must be 0**). `durableShelfId` keeps a `"g:"` branch for a *future safe* GUID source but nothing
feeds it. New gotcha + §6.7 rewrite in `CLAUDE.md`. Offline suites still green (now 50+ checks
incl. collision detection + format line).
**What the USER must do now (the game crashed, so relaunch):** launch the game → load the stocked
save → console **`rrshelf save`**. Confirm in `UE4SS.log`: banner `loaded (shelf-v4`, then the
snapshot dump, the **`durable keys (loc+yaw): 56 shelves, 0 collision(s)`** line (must be **0** —
if not, two shelves share loc+yaw and we'll need the GUID after all), and `SAVED 56 shelves / 1019
slots -> <path>`; verify `<path>\Player_Save2.lua` exists. Then restart, `rrshelf load`, confirm the
logged layout matches. Report back.

---

### 2026-06-26 — Phase 3: layout enforcement / the correction primitive (CODE COMPLETE, awaiting in-game)
**Phase:** Phase 3. Mod version `shelf-v4` → **`shelf-v5`**. **No in-game run yet** — I cannot press
keys in the running game; the USER must do the build-loop test (steps at the bottom). Offline: TDD'd
the pure logic and offline-tested the mutation orchestration with fakes. **All 6 suites green
(43 new assertions: 30 in `enforce_test`, 13 in `enforce_apply_test`).**

**What was done:**
- **`enforce.lua`** (new) — split into a PURE layer and a RUNTIME layer:
  - **Pure (TDD, `tests/enforce_test.lua`, 30 checks):**
    - `diff(saved, current)` — matches shelves by durable key (`durableId or id`), lists per-slot
      `{index, want, have}` mismatches (nil = empty). Reports `matched`, `missing` (saved shelf not
      live now), `totalMismatches`. Unmanaged live shelves are ignored.
    - `plan(saved, current)` — **collect→place** model, per shelf: a slot is *satisfied* when
      current SKU == saved SKU (empty==empty counts) and is never touched; every other slot is freed
      and its cassette pooled; targets are filled from the pool by SKU; leftover (surplus) cassettes
      are re-placed into the remaining freed slots so **no actor is ever orphaned**; a target whose
      SKU is nowhere on the shelf is **unfulfillable** (left empty + logged). Emits `moves[]`
      (`{from,to,sku,surplus}`, `from~=to` always), `unfulfillable[]`, and totals. Deterministic
      (ascending slot order, FIFO pool). **Sourcing is PER SHELF** for Phase 3 (a cassette stays on
      its own shelf); global/backstock sourcing is a later refinement.
  - **Runtime (offline-tested via fakes, `tests/enforce_apply_test.lua`, 13 checks):**
    - `apply(plan, refIndex, log, dryRun)` — **two passes in one game-thread call**: collect (read +
      `Empty Container` every distinct source) then place (`Store Object From Game Code And No
      Animation` into each dest, then `Set Stored Object to Container Transform` to snap pose). The
      all-sources-emptied-before-any-store ordering makes a **cyclic swap (A↔B) safe** (proven offline
      with stub containers). `dryRun=true` does reads + reflection only — **zero mutation**.
    - `reflectSignature(container, log)` — READ-ONLY reflection (`ForEachFunction` +
      `fn:ForEachProperty`) that logs the param signatures of the move-primitive family
      (`Store Object …`, `Empty Container`, `Does it fit …?`, `Return is container empty`,
      `Set Stored …`). Same class of reflection the Phase 0 probe used safely — it never *calls* the
      functions, so it can't trigger the native-crash a bad *invocation* could.
    - `indexLive(snap)` — builds `{ [durableKey] = { shelf, containers={[index]=obj} } }` from a live
      snapshot for `apply` to resolve move slots.
- **`layout.lua`** — `snapshot()` now attaches **live object refs** to its records (`shelf.obj`,
  `slot.container`) so `enforce` mutates through the SAME enumeration it diffs against (no second
  `FindAllOf` pass, refs guaranteed consistent with the SKUs read). Refs are runtime-only — `toPersist`
  and `format` ignore them, so nothing new reaches disk. Exported `M.CONTAINER_ARRAY_KEY` /
  `M.OWNED_OBJECT_KEY` so `enforce` reuses the exact slot field names (no drift).
- **`main.lua`** — `runEnforce(dryRun)`: snapshot → load saved layout for the active key → log
  diff/plan summary (+ bounded unfulfillable detail + missing shelves) → reflect the primitive
  signature off the first managed container → `apply`. Wired: **F10 = DRY RUN only** (safe to press),
  `rrshelf enforce` = dry run, **`rrshelf enforce go` = mutate (console-only, deliberate)**.
- **`config.lua`** — `EnforceKey = "F10"` (dry-run hotkey; there is intentionally **no** hotkey that
  mutates — the mutate path is console-only, same reasoning as Phase 2's console-only save).

**Key decisions (durable; fold into `CLAUDE.md` once validated in-game):**
- **F10 is dry-run, mutation is `rrshelf enforce go` (console-only).** Deliberate deviation from the
  plan's "F10 = enforce": the move primitive's arg signature is unconfirmed and a wrong BP call can
  native-crash (uncatchable, §7 / the shelf-v3 GUID crash). The dry run logs the plan AND reflects the
  real signature so we confirm args BEFORE any mutation — the cautious "prove the dangerous part by
  hand" the plan asks for. Mirrors Phase 2 keeping `save`/`load` console-only.
- **collect→place over a per-shelf pool**, not minimal-move: simpler to reason about + test, handles
  arbitrary permutations/cycles uniformly, and guarantees no orphaned (detached, floating) actors.
  Cost: it may touch a few surplus cassettes that a minimal-move plan would leave; acceptable for the
  manual Phase 3, all logged.
- **The store-call arg guess is `dest["Store Object From Game Code And No Animation"](cassette)`** (single
  object arg, from the name). If the reflected signature says otherwise, the call is one edit away —
  that's exactly what the dry-run signature dump is for.

**What's UNVALIDATED / for the USER to do (the build-loop step I can't do):**
1. **Ctrl+R** hot-reload; confirm `UE4SS.log` shows `loaded (shelf-v5`.
2. Stand in the stocked store. Run **`rrshelf enforce`** (or F10) — a DRY RUN. In the log capture:
   the `=== enforce DRY RUN` block, the `plan: N move(s)/…` line, any `unfulfillable` lines, and
   especially the **`-- move-primitive signatures (reflected …)`** lines (`sig 'Store Object …' -> [...]`).
   **Report those signature lines back** — they confirm whether `(cassette)` is the right call.
3. Scramble a shelf (move cassettes / let staff do it), run **`rrshelf enforce`** again to see a
   non-trivial plan, then **`rrshelf enforce go`** to apply. Confirm in-game the slots returned to the
   saved layout and the log shows `ENFORCE complete: N/N store(s) ok, … 0 error(s)`. Watch for a crash
   (would mean the store-call signature is wrong — send me the reflected sig and I'll fix the call).
4. Re-run `rrshelf enforce` on the now-correct store → must report `nothing to correct` (idempotent).
5. Report logs back. Then I finalize `CLAUDE.md` §3/§6.5 with the CONFIRMED signature + the measured
   hitch, and flip this entry to COMPLETE.

**Gotchas/edge cases handled:** cyclic swaps (two-pass collect→place); surplus cassettes re-placed not
orphaned; unfulfillable targets left empty + logged; a saved shelf not live now is skipped (counted,
no crash); dry run is pure read/reflect (cannot crash); every BP call `pcall`-wrapped (catches Lua
errors; a native crash still can't be caught — hence dry-run-first). The reflected-signature step runs
on both dry and go so even a `go` log records the args.

**Open item:** nothing committed this session yet — awaiting the in-game validation before committing
Phase 3 (sole-author, no `Co-Authored-By`; `CLAUDE.md`/`layouts/*.lua` excluded per `.gitignore`).

#### Update — shelf-v5 dry run NATIVE-CRASHED in `reflectSignature` → fixed in shelf-v6
**Symptom:** `rrshelf enforce` (the DRY RUN — supposedly read-only) **fatal-crashed** right after scrambling a
shelf. **Root cause (systematic-debugging, CONFIRMED from the crash dump, not guessed):**
- The clean-store dry run earlier was fine (0 moves → returned before `reflectSignature`/`apply`). The
  crash only fired once there were moves (scrambled), i.e. on the `reflectSignature` + dry `apply` path.
- `UE4SS.log` (16:53) showed `reflectSignature` **logged all 5 move-primitive sigs successfully**, last
  line `sig 'Return is container empty'`, then the log ended. So the 5 leaf-class sigs were NOT the crash.
- The real callstack is in `%LOCALAPPDATA%\RetroRewind\Saved\Crashes\UECC-…16:54:10\CrashContext.runtime-xml`:
  **`EXCEPTION_ACCESS_VIOLATION reading 0x0000000000000040`** in `RetroRewind-Win64-Shipping`, called from a
  deep UE4SS reflection chain — a null UObject deref in the game's reflection data.
- **Differential analysis (working vs broken):** the Phase 0 probe's proven-safe `dumpFunctions` gates
  `cls:ForEachFunction` to Blueprint (`_C`) classes (`if cname:find("_C")`). My `reflectSignature` called
  `ForEachFunction` on EVERY class in `Shelve_Container_C`'s hierarchy — so after the leaf `_C` class it
  walked into the **native** supers (`StaticMeshComponent → … → UObject`) and crashed. `apply`'s dry-run
  read (`c["Object owning of this container"]`) is the identical read `snapshot()` does 1019× safely, so it
  was ruled out. → **New §7 gotcha: never `ForEachFunction` on a native UClass; gate to `_C`.**

**Fix (shelf-v6):** `reflectSignature` now gates `ForEachFunction` to `_C` classes (mirrors the probe) and
early-outs once all 5 are found — so it never touches a native class. No behavioural loss (all 5 primitives
live on the leaf `_C`). Offline suites still green (43 enforce assertions).

**BONUS — the crash run CONFIRMED the BP signatures before dying** (now in `CLAUDE.md` §6.5): the store
primitive is **`Store Object From Game Code And No Animation(Object to store, Set Location:bool)`** — TWO
inputs, not one. The shelf-v5 `go` path passed a single arg (wrong); **shelf-v6 `apply` now calls
`dest["Store…"](cart, true)`** (true = snap to slot). `Empty Container()` / `Set Stored Object to Container
Transform()` take no params (confirmed); `Return is container empty()` → bool. The `go` path is now written
against the REAL signature but is **still unvalidated** (the dry run never calls these — only `go` does).

**What the USER must do now (relaunch — game crashed):** launch → load the stocked save →
1. **`rrshelf enforce`** (or F10) on a scrambled shelf → must now complete with **no crash** and print the
   plan, the `sig '…'` lines, and `[dry] SKU … slot X -> slot Y` lines + `DRY RUN complete: N move(s) planned`.
2. Then **`rrshelf enforce go`** → watch for a crash. If it survives, confirm in-game the slots snapped to
   the saved layout and the log says `ENFORCE complete: N/N store(s) ok … 0 error(s)`. A crash here = the
   `(cart, true)` store call is still off — send me the log and I'll adjust.
3. Re-run `rrshelf enforce` → expect `nothing to correct` (idempotent). Report back.
Note: cross-shelf scrambles show as `unfulfillable` (per-shelf sourcing) — expected, not a bug.

#### Update — shelf-v6 dry run CLEAN; `go` stores all failed → shelf-v7 instrumented for the why
**shelf-v6 result (in-game, UE4SS.log 17:03):**
- **Dry-run crash FIXED.** `rrshelf enforce` on a scrambled shelf completed: plan (9 moves), the 5 `sig`
  lines, 9 `[dry]` lines, `DRY RUN complete`. **No crash.** The `_C`-gating fix worked.
- **`rrshelf enforce go` did NOT crash** but reported **`0/9 store(s) ok, 9 empties, 9 errors`**: every
  `Empty Container()` succeeded, every `Store Object…(cart, true)` **failed at the Lua level** (pcall
  caught it — and shelf-v6 threw the error string away). So the 9 sources were detached and never
  re-placed → those cassettes are now loose; **the save must be reloaded** before re-testing.
- **Confirmed signature** `Store Object From Game Code And No Animation(Object to store, Set Location, …locals)`;
  but the reflected param TYPES all printed `:?` (the type accessor failed), so we don't yet know if
  `Set Location` is a bool/byte. Two live hypotheses for the store failure: **(a) `Empty Container`
  DESTROYS the cassette**, so storing the now-invalid ref errors; **(b)** the `(cart, true)` arg
  types/count are wrong. Counts alone can't distinguish them.

**shelf-v7 (instrumentation only — no algorithm change to the cycle-safe collect→place):**
- `apply` now **captures + logs the store error string** (`! store failed … : <err>`) and **ABORTS the
  store pass on the first failure** (the same call fails identically every move — no point spamming;
  and it stops after disturbing fewer slots).
- Added a **`[diag] cassette across Empty`** line: logs the held cassette's `IsValid()` + full name
  **before vs after** `Empty Container()` for the first move → directly answers hypothesis (a).
- Fixed `reflectSignature` param-TYPE read (`p:GetClass():GetFName():ToString()` w/ `GetName` fallback)
  so the next run prints real types, incl. `Set Location`'s.
- Offline suites still green (collect→place + cycle-safety tests intact).

**What the USER must do (RELOAD first — the v6 `go` left 9 loose cassettes):** reload the stocked save
→ scramble a shelf → **`rrshelf enforce go`** ONCE. Report back these log lines: the **`[diag] cassette
across Empty … valid X -> Y`** + the two name lines, the **`! store failed … : <error>`** line, and the
**`Store Object…` sig** line (now with real param types). Those three pin down whether Empty is
destructive and exactly why the store call errors — then I fix the store path precisely (and, if Empty
is destructive, switch from detach-and-replace to a teleport+ref-rewrite or store-without-empty approach).

#### Update — shelf-v7 answered both questions → shelf-v8 probes the store call convention
**shelf-v7 result (in-game, UE4SS.log 17:19):**
- **`Empty Container` does NOT destroy the cassette** — `[diag] cassette across Empty (slot 12): valid
  true -> true`, identical actor name (`videotape_C_2147446794`) before & after. So **collect→place is
  sound** (detach-and-replace is viable; no teleport/respawn fallback needed).
- **Store error:** `[UFunction::setup_metamethods -> __call] UFunction expected 2 parameters, received 1`.
  Types confirmed: `Store Object…(Object to store:ObjectProperty, Set Location:BoolProperty)`.
- **Diagnosis:** I called `dest["Store…"](cart, true)` (2 Lua args) but UE4SS reported **received 1** — for
  this bracket-call it consumed `cart` as the call's context/self and saw only `true` as a param. i.e. the
  container likely must be the explicit first arg: `dest["Store…"](dest, cart, true)`. (`Empty Container()`
  with 0 args worked because it takes 0 real params either way — doesn't disambiguate.)

**shelf-v8 (probe the call convention):**
- `enforce.lua` `STORE_FORMS` = 4 candidate UE4SS conventions, tried in order on the FIRST store, each
  outcome logged (`store form '<tag>': OK|ERR …`): **`self,obj,bool`** (`d[FN](d,c,true)` — lead bet),
  `obj,bool` (known fail), `self,obj`, `obj`. First non-raising form is **cached + reused**; the winner is
  logged (`store call form = '…'`). Only the winning form mutates (others raise first → no double-store).
- Offline `enforce_apply_test` fake made **convention-agnostic** (store closure picks the arg that is a
  cassette by `.sku`) so the orchestration test is independent of the in-game binding. All 6 suites green.

**What the USER must do (RELOAD first):** reload stocked save → scramble a shelf → **`rrshelf enforce go`**
once. Report: the `store form '…': OK|ERR …` lines, the `store call form = '…'` line, `ENFORCE complete:
N/M store(s) ok …`, AND **whether the cassettes physically moved into saved order in-game** (a form can
stop the Lua error yet still no-op if an internal cast fails — visual confirmation matters). If a form wins
and slots correct → Phase 3 mutation PROVEN; I record the convention in `CLAUDE.md` and finalize.

---

### 2026-06-26 — DIRECTION PIVOT: Approach B (physical enforce) → Approach A1 (at-restock ordering)
**Decision (user, via brainstorming):** The user does **NOT** want post-hoc physical relocation (Phase 3 /
Approach B). They want the **employee to restock cassettes into a fixed PHYSICAL order** — fill the next
empty slot left→right, top→bottom, no scattered gaps (the movie that lands in a slot just depends on restock
order). This is **Approach A1** (CLAUDE.md §4): intercept the employee's slot-selection at restock and
override it to return the next-ordered-empty container. The saved-layout/enforce work (Phases 1–3) is **not
the mechanism** for this — set aside (snapshot/save/load + the slot model + the §6.3 physical-order sort are
still reusable). Phase 3's `enforce.lua` `apply`/store-convention investigation is **paused** (the store
call's working arg form was never confirmed; that thread can resume if physical enforce is ever wanted).

**Why recon first:** Phase 0 found the random empty-slot choice is NOT on the shelf/container — it lives in
the `AI_Director_C` / AI-Employee / Behavior-Tree layer (confirmed again from the Employee Mod, which uses
`AI_Director_C` + "AI Employee in World" actors and the `NotifyOnNewObject → ExecuteWithDelay → RegisterHook`
pattern). So A1's hook point must be found before it can be designed.

**Built — recon probe (READ-ONLY) → `probe/RR Shelf Keeper Probe/Scripts/airecon.lua`** (required by the
probe's `main.lua`; no new junction). `airecon-v1`, F7 / `rrrecon`:
- **Part 1 (static, on F7):** reflects `AI_Director_C` (props+_C-funcs), keyword-sweeps for the AI-Employee
  actor class and reflects it, and dumps the FULL `Shelve_C`/`Shelve_Container_C` function+property lists —
  starring names matching stock/slot/container/reserve/find/empty/place keywords (the slot-choice candidate).
  Hunts for a `Can AI reserve it?` / find-empty / next-container function whose RETURN we could override.
  ForEachFunction is `_C`-gated (native-class enum crashes, §7).
- **Part 2 (observational hooks, auto-registered late):** resolves the live container class path and
  `RegisterHook`s the candidates — `Can AI reserve it?`, `Store the Object`, `AI Pick UP`, `AI Pick up
  Movie…` — logging each firing's container FName + world loc (throttled, cap 60/fn). A live restock then
  reveals which fires, in what order, and which physical slot gets chosen → whether A1 can intercept it.

**What the USER must do:** Ctrl+R → confirm `RECON loaded (airecon-v1` + the deferred `hooks: container class
path = …` / `hook OK : …` lines. Press **F7** (or `rrrecon`) for the static dump. Then **set up a restock**
(empty a few slots on one shelf, ensure a staffer is working + has stock to shelve) and watch the `[hook]`
lines as they restock. Report the `[RR-Recon]` output — esp. any starred `*fn[…]` slot-choice candidate and
the `[hook]` firing sequence/positions. That decides the A1 override point; then we write the A1 spec + plan.

#### Update — recon static dump (F7, airecon-v1) located the A1 hook candidate → airecon-v2 adds it
**The restock AI architecture (from the F7 reflection, UE4SS.log 19:30):**
- **Employee actor:** `AI_Employee_Character_C` (base `AI_Base_Character_C`). Director: `AI_Director_C`.
- **Behavior Tree:** `/Game/VideoStore/core/ai/AI_Staff_BehaviorTree`. Restock-relevant tasks:
  - `BTTask_Staff_MoveToShelve_C` — chooses the SHELF: `Return First Empty Movie Shelf depending of object
    hold`, `Filter Occupied Shelve`, `Return Closest Shelve`, and **`Stock the Shelve`** (the stock driver).
  - `BTTask_Staff_Parallel-Restock_Movie_C` — the per-movie restock task (`Pick another one`, ubergraph).
  - `BTTask_Staff_GoToDropbox_C` — `Pickup 1 movie in Dropbox`, `Put Reserved Scanned Movie on Shelf`, etc.
- **THE SLOT-CHOOSER (A1 hook candidate):** `Shelve_C: Does any Shelve Containers still empty` →
  returns **`[One container is empty:Bool, Empty Container:ObjectProperty, …]`**. It loops the shelf's
  containers (`Temp_int_Loop_Counter`) and hands back the empty container the staff will fill. **Overriding
  its returned `Empty Container` to the next-PHYSICAL-ordered empty container = Approach A1.** Clean: it's a
  function that returns the chosen slot as an output param, hookable on the base `Shelve_C` class.
- **Reservation fns** (`Shelve_C` & `Shelve_Container_C`: `Can AI reserve it?(AI Ref, AI can reserve it:bool)`)
  gate availability; the actual slot CHOICE is `Does any Shelve Containers still empty`. Container store =
  `Shelve_Container_C: Store the Object` (animated). Class paths: container =
  `/Game/VideoStore/asset/prop/shelve/Shelve_Container.Shelve_Container_C`; Shelve_C resolved at runtime.
- Hook registration worked for `Can AI reserve it?`, `Store the Object`, `AI Pick UP` (the
  `AI Pick up Movie…` name was slightly off → FAIL; dropped, not needed).

**airecon-v2 (added the smoking-gun hook):** now also hooks **`Shelve_C: Does any Shelve Containers still
empty`** (resolves the Shelve_C base path by walking a shelf's class hierarchy) + the shelf-level
`Can AI reserve it?`. The shelf observer logs the shelf's empty containers (array index + world loc) at fire
time, **deduped per shelf on the empty-set signature** so per-tick re-checks don't flood the log. Correlate
those with the `Store the Object` hook (which slot got the movie) to confirm: is the chosen slot the
array-first-empty (→ overriding the return reorders it), or random/other?

#### Update — A1 implemented (Tasks 1–5) + dry-run VALIDATED in-game (shelf-v9) → apply (shelf-v10)
**Built (executing-plans, inline; spec `docs/superpowers/specs/2026-06-26-a1-ordered-restock-design.md`,
plan `docs/superpowers/plans/2026-06-26-a1-ordered-restock.md`):**
- **`order.lua`** (new, pure, TDD — `tests/order_test.lua` 9/9): `nextEmpty(containers, rule)` returns the
  next empty container index in PHYSICAL fill order — group by row (Z, `rowTol` default 15) then column
  (Y); `topFirst`/`leftFirst` direction flags. Deterministic.
- **`restock.lua`** (new, runtime): reads a shelf's containers (`All Selve Containers` →
  `Object owning of this container` empties + `K2_GetComponentLocation`), computes the ordered target via
  `order.nextEmpty`, and the hook callback `onDoesAnyEmpty(self, oneEmptyParam, emptyContainerParam)` that
  `:set()`s the returned `Empty Container` out-param to it. Guarded to movie-shelf leaf classes only
  (snack/ClearanceBin untouched). DryRun branch logs instead of setting.
- **`layout.lua`**: exported `M.MOVIE_SHELF_CLASSES` for the guard.
- **`config.lua`**: `OrderedRestock`/`RestockDryRun`/`RestockVerbose`/`FillTopFirst`/`FillLeftFirst`/`RowTol`.
- **`main.lua`** (`shelf-v9`→`v10`): registers the hook late (`ExecuteWithDelay`) on
  **`/Game/VideoStore/asset/prop/shelve/Shelve.Shelve_C:Does any Shelve Containers still empty`**, gated by
  `OrderedRestock`. Offline: all 7 suites green.

**Dry-run validation (shelf-v9, UE4SS.log 19:56) — CONFIRMED:**
- Hook fires; callback **param order is `(self, OneContainerIsEmpty, EmptyContainer)`** — `emptyContainerParam:get()`
  returns a real container (`Shelve_Container19` on 4Row_02, `Container16` on 6Row_01, `Container10`/`Container4`
  elsewhere). Values **differ per shelf matching that shelf's state** → the single-callback `RegisterHook` runs
  **POST** (a stale read would be identical across calls), so `:set()` will override and stick.
- Our physical-order target computes and **differs** from the game's last-index pick (e.g.
  `game returns 'Shelve_Container19' -> would set 'Shelve_Container13'`). Note: `Does any…` fires on ~20 shelves
  per restock (shelf-FINDING), not just the one stocked — expected; setting the sample container is harmless for
  shelf-finding (the bool stays true) and redirects the one that gets stocked.

**What the USER must do now (Task 7 — apply):** Ctrl+R (confirm `loaded (shelf-v10` + `ordered-restock hook
active` WITHOUT "DRY RUN"). Start the day, let a staffer restock. **Watch the shelf:** does the cassette go to
the physical-first empty slot (top-left) instead of the old highest-index slot? Log shows `[restock] <shelf> ->
<container> (slot idx N)` per override. If filling is mirrored (bottom-up / right-to-left), flip `FillTopFirst`
/`FillLeftFirst` in `config.lua` + Ctrl+R. If the staff STILL fill the highest slot (override didn't stick),
the hook needs explicit post-registration (`RegisterHook(path, function() end, cb)`) — report and I'll switch it.

#### Update — apply CONFIRMED working (4/4) → fixed double-sided column ordering (shelf-v10→v12)
**shelf-v10 in-game (UE4SS.log 20:01):** the override APPLIES reliably — all 4 placements landed exactly on the
container we `:set()` (matched the probe's `Store the Object` hook). `:set()` on the post-hook out-param sticks.
The "2nd cassette looked wrong" was a partially-stocked shelf (its top rows were pre-filled, so physical-first
was mid-shelf) — NOT the old behavior (it went to idx 16, not the highest idx 20).
**shelf-v11:** added per-override logging (`loc`, `empties`, `noloc`) for a clean from-empty test.
**shelf-v11 from-EMPTY test (UE4SS.log 20:10, all shelves emptied):** `noloc=0` everywhere (position reads fine).
But the user saw cassettes "most of the time NOT in the top-left slot." **Root cause: double-sided shelf pairs
face ~180° apart (Phase 1), and `order.lua` sorted columns by raw world Y — so "left" was correct for one facing
and mirrored for the back-to-back partner** → ~half the shelves filled from the wrong horizontal end.
**Fix (shelf-v12):** columns are now ordered SHELF-RELATIVE. `restock.readContainers` computes each container's
`col` = offset projected onto the shelf's RIGHT vector (from its yaw); `row` = world Z (yaw-invariant). `order.lua`
now prefers explicit `row`/`col` (falls back to `loc.z`/`loc.y` for the offline tests). All shelves now order from
the same physical end regardless of facing. Offline: order_test +2 (row/col precedence) → all green.

**What the USER must do (shelf-v12):** Ctrl+R (confirm `loaded (shelf-v12`). On the emptied shelves, let staff
restock a while. Now EVERY shelf should fill from the **same consistent corner**. Report which corner it starts
from: if **top-left** → done (verify the sequence marches right then down). If **top-right** → flip
`FillLeftFirst=false`. If **bottom-…** → flip `FillTopFirst=false`. One flag flip then aligns it to your wanted
left→right / top→bottom. The `[restock]` log now also prints `col=` (the shelf-relative column) per pick.

#### Update — shelf-v12 CONFIRMED working; finalized as shelf-v13
**shelf-v12 from-empty test (UE4SS.log 20:30):** the shelf-relative column fix works — every fresh shelf's first
pick is **`idx 12, col=17`**, identical across all shelves (different world locs, same shelf-relative column +
top row), and the **USER confirmed visually: "the employee places everything on the first available slot, top
left."** A1 is DONE — no direction flip needed (`FillTopFirst=true`, `FillLeftFirst=true` = top-left).
**shelf-v13 (finalize):** set `RestockVerbose=false` (the override fires per-shelf during shelf-finding, ~38
lines/restock — debug only). Default config = `OrderedRestock=true`, `RestockDryRun=false`, top-left fill.
Durable A1 record written to `CLAUDE.md` §6.8. Offline suite green (order_test 11 checks + 6 other suites).

**Remaining (not blocking the feature):**
1. **Remove the `airecon` recon probe** — it's still installed in `RR Shelf Keeper Probe` and its `[RR-Recon]`/
   `[hook]` observational hooks fire on every restock (log noise + tiny cost). Delete its junction / `enabled.txt`
   / the `require("airecon")` line in the probe's `main.lua`.
2. **Optional:** prune the now-unused Phase 1–3 modules (`layout` snapshot bits, `store`, `key`, `enforce`) and
   their `rrshelf snapshot|save|load|enforce` commands — A1 doesn't use them. Keep `order`/`restock`/`config`/
   `main` (+ `sku`/`layout` for the shelf-class list & slot keys).
3. **Commit** when the user gives the go-ahead (sole-author, no `Co-Authored-By`; `CLAUDE.md`/`layouts/*.lua`
   excluded per `.gitignore`). Nothing committed this whole A1 arc yet.

**What the USER must do (step 3, now with airecon-v2):** Ctrl+R (confirm `RECON loaded (airecon-v2` + the new
`hook OK : …Shelve_C…:Does any Shelve Containers still empty`). Start the day; when a staffer restocks movies,
watch the `[hook]` lines: the `Does any Shelve Containers still empty` line (the shelf's empty slots) followed
by `Store the Object` (the slot actually filled). Report that sequence — it confirms whether overriding the
chooser's return implements A1. Then we write the A1 spec + plan.
