# rr-shelf-keeper — Phased Build Plan

> ## ⚠️ SUPERSEDED — do NOT start a session from this plan
> This is the **Approach B** roadmap (build a save/snapshot/**enforce** layout engine,
> Phases 0→6, with at-source AI hooking as the optional Phase 7). The project **pivoted to
> Approach A1 (ordered restock)** and shipped it. A1 corresponds to this plan's optional
> **Phase 7**, and it is **complete & committed**; Phases 1–5 (the Approach-B layout engine)
> were set aside and their code **deleted** (`enforce`/`store`/`key.lua` + tests). Phase 6
> cleanup (remove probe, README) is also done.
>
> **Continuing at Phase 2/3 here would rebuild exactly what was deleted.** For the real,
> current state and roadmap, read instead:
> - `docs/PROGRESS.md` → "Status at a glance"
> - `docs/superpowers/{specs,plans}/2026-06-26-a1-ordered-restock*.md` (the A1 design that shipped)
> - `CLAUDE.md §6.8` (durable A1 record)
>
> This file is kept only as the historical Approach-B design record.

> **Planning artifact.** This file is the cross-session roadmap. Each phase is a
> single focused session with one testable outcome. Execute phases in order.
> **Phase 0 is a hard gate:** no feature code (Phases 1+) until Phase 0's answers are
> written back into `CLAUDE.md`.

**Goal:** A UE4SS Lua mod that makes movie-shelf stocking deterministic — snapshot a
slot→SKU layout per save, then re-apply it so staff stop scrambling shelves; with a
forced-ordering mode on top.

**Core insight (from `CLAUDE.md` §1):** both requested features are one system —
"control which SKU sits in which slot." Build the **save/enforce layout engine** first;
forced ordering is just a generated layout fed to that engine.

---

## Ground rules for every session

**Always read first (every phase lists these in PREREQUISITES):**
- `CLAUDE.md` (this repo) — authoritative project context, the running record of
  discovered facts.
- `docs/PLAN.md` (this file).
- `docs/PROGRESS.md` — what previous sessions did and left for you.

**Reference repo (local-only, NOT on GitHub):** `D:\Github\rr-dupe-finder\` — a sibling
mod by the same author. Its `CLAUDE.md` and `RR Dupe Finder\Scripts\*.lua` document the
verified cassette SKU read path, the UE4SS Lua API, the working actor-spawn recipe, and
~20 hard-won gotchas. **Reuse it; do not re-derive it.** If the path is missing, ask the
user where it is checked out.

**Hard constraints — repeated in the phases they bite (from `CLAUDE.md` §7 and the
sibling repo's gotchas):**

1. **Synchronous / game-thread only.** Do all UObject reads and shelf mutation inside
   `ExecuteInGameThread(...)`, one-shot, off a discrete trigger. **Never** run a
   continuous async loop touching UObjects — `LoopAsync` on a worker thread hard-crashes
   the Lua VM (sibling gotcha 19), and async on NPC refs caused GC crashes (`CLAUDE.md`
   §7). "Synchronous" here means *game thread, one pass*, accepting the brief hitch.
2. **Shipping build → `DrawDebug*` is a no-op.** For any visual feedback (e.g.
   marking an out-of-place cassette), spawn a marker mesh or set a premade material —
   **never** debug draw. **Do not** create a DynamicMaterialInstance: it hard-crashes
   (sibling gotcha 10). Reuse the proven spawn recipe in the sibling's `highlight.lua`.
3. **Hooks register late.** Blueprint UFunctions don't exist in memory at mod startup.
   Register hooks via `ExecuteWithDelay(...)` or `NotifyOnNewObject(...)` + a retry
   guard. **Never** `RegisterHook` at top level. (Keybinds and console commands *are*
   fine to register at top level.)
4. **GUID-suffixed struct keys.** Field names look like `SKU_26_C5F25F4E...`. Copy them
   **verbatim** from working code or from a probe dump. Never guess them.
5. **Enforce only on discrete triggers** (store open, per-minute tick, end of day,
   hotkey) — **never** continuously — so you don't yank a cassette out of an employee's
   hands mid-animation.
6. **No Live View on this install.** `GraphicsAPI = opengl` → the UE4SS GUI window never
   spawns even with `GuiConsoleEnabled = 1` (sibling gotcha 11). Discover struct keys via
   **Lua reflection** (`UStruct:ForEachProperty`) and read **`UE4SS.log` from disk**.
   Trigger mods via the in-game `` ` `` console (e.g. `rrprobe`) or an F-key.

**Key paths:**
- Game root: `D:\SteamLibrary\steamapps\common\RetroRewind`
- Mods dir: `...\RetroRewind\Binaries\Win64\ue4ss\Mods\`
- UE4SS log: `...\ue4ss\UE4SS.log` (all `print()` output; tag ours, grep by tag)
- Saves: `%LOCALAPPDATA%\RetroRewind\Saved\SaveGames\`

**The build/test loop (from the sibling repo):**
1. Edit Lua in the repo. 2. The mod folder is a junction into `Mods\` (set up once,
below). 3. In-game press **Ctrl+R** to hot reload (`EnableHotReloadSystem = 1`). 4.
Trigger the feature (F-key or console command). 5. Read `UE4SS.log` from disk and grep
your tag. Confirm the **version banner / timestamp** changed so you know the reload took.

**Mod naming & install (do this once, Phase 0):** the shipping mod folder will be
`Mods\RR Shelf Keeper\`; the throwaway probe is `Mods\RR Shelf Keeper Probe\`. Install via
a directory junction so repo edits hot-reload in place (PowerShell):

```powershell
New-Item -ItemType Junction `
  -Path   "D:\SteamLibrary\steamapps\common\RetroRewind\RetroRewind\Binaries\Win64\ue4ss\Mods\RR Shelf Keeper Probe" `
  -Target "D:\Github\rr-shelf-keeper\probe\RR Shelf Keeper Probe"
```

---

## Phase sequencing & rationale

`CLAUDE.md` §9 build order is: (1) investigate → (2) snapshot → (3) enforce → (4)
forced-order → (5) config/polish → (6) optional at-source AI hook. This plan keeps that
order but splits two steps so each session has **one** testable outcome and the riskiest
work is isolated and reversible:

- **Snapshot is split** into **Phase 1 (read + log, no file I/O)** and **Phase 2
  (persist to a per-save file + load back)**. Reading shelves is low-risk and proves
  ordering; file I/O is a separate concern with its own failure modes.
- **Enforcement is split** into **Phase 3 (correct mismatches on a manual hotkey)** and
  **Phase 4 (wire it to automatic triggers)**. Prove the correction primitive by hand —
  the dangerous part — before letting it fire automatically. This directly serves
  constraint #5 (don't fight the AI) and #1 (synchronous): a manual press is the safest
  way to validate mutation before automating it.

Net order: **0 → 1 → 2 → 3 → 4 → 5 → 6.** Phase 6 (Approach A) stays optional and last;
build it only if Phase 0 finds the slot-selection point cleanly hookable.

---

## PHASE 0 — Runtime investigation (HARD GATE)

**Objective:** With the game running, resolve **every** unknown in `CLAUDE.md` §6 and
write the answers back into `CLAUDE.md` §3/§6. No feature code may start until this is done.

**Unknowns to resolve (all of `CLAUDE.md` §6):**
1. Movie shelf **class name** (the `SnackShelf_C` analogue).
2. **Slot model**: the slot/container array field name(s), and **how a slot references a
   cassette** — a `Cartridge_Base_C` object ref? a SKU int? a transform? a nested struct?
3. **Slot ordering vs world transform**: does array index map to a stable physical order
   (left→right, top→bottom)? Cross-check array index against each slot's / cassette's
   world location.
4. **Where the employee picks a slot** — the Behavior Tree task / function that places a
   cassette and whether it chooses a *random* empty slot (decides Phase 6 feasibility).
5. **Cleanest primitive to move a cassette between slots** — a Blueprint placement
   function on the shelf/cassette (analogue of snack `Spawn and Fill Snack`), or teleport
   the actor (`K2_SetActorLocation`) + rewrite the slot's stored ref.
6. **Persistence keying** — the active save's name/id (on `Core_Gamemode_C` or the
   `USaveGame_VHS_C`), plus the `.sav` filename in the SaveGames folder.

**PREREQUISITES (read at session start):**
- `CLAUDE.md` (this repo), `docs/PLAN.md`, `docs/PROGRESS.md`.
- `D:\Github\rr-dupe-finder\CLAUDE.md` — esp. §5 (SKU keys), §7 (reflection API), gotchas
  10/11/13/19.
- `D:\Github\rr-dupe-finder\RR Dupe Finder\Scripts\sku.lua` and `scan.lua` — the verified
  read path and enumeration pattern.
- Reference mod (read-only): `...\Mods\Auto Restock Snacks QoL\Scripts\main.lua` — the
  snack shelf→pack→container model and the `Return Snack Base Save Struct` /
  `Spawn and Fill Snack` placement functions (the analogue to look for on movie shelves).
- Reference mod: `...\Mods\Employee Mod\Scripts\main.lua` — `gm["Save Game VHS"]` access
  and the `NotifyOnNewObject` + `ExecuteWithDelay` hook-when-loaded pattern.

**Deliverables:**
- **The probe mod is already written** (this session): `probe/RR Shelf Keeper Probe/`
  (`enabled.txt` + `Scripts/main.lua`, version marker `probe-v1`). It is **READ-ONLY** —
  it only reads/reflects/logs; it never spawns, moves, writes, or destroys. On **F8** (or
  console `rrprobe`) it logs four sections, all tagged `[RR-Probe]`:
  - **A** — `FindAllOf` over candidate shelf class names with valid-instance counts; if
    none hit, a `ForEachUObject` keyword sweep listing unique class names containing
    "shelf/rack/display/case/vhs/cassette".
  - **B** — a depth-bounded reflection + value dump of the first shelf found: class
    hierarchy, every property name+type, inner struct field names (GUID keys), array
    counts, first elements, and any actor locations.
  - **C** — reads up to 3 cassettes' SKU + title via the sibling's key chain and logs each
    with its world location (confirms the read path still works in this build and gives a
    placed cassette's coords to cross-check slot ordering).
  - **D** — `Core_Gamemode_C` top-level property names+types, the `Save Game VHS` object
    walked shallowly, and a reminder to list the SaveGames folder for the `.sav` key.
- Captured answers to all six unknowns.
- Updated `CLAUDE.md` (§3 shelf/slot model filled in; §6 marked resolved with the facts).

**Tasks:**
1. Install the probe via the junction command above; confirm `enabled.txt` is present.
2. **Set up the iteration loop (one-time):** confirm in
   `...\ue4ss\UE4SS-settings.ini` that `EnableHotReloadSystem = 1`. (Live View is
   unavailable here — do not rely on it.)
3. Launch the game, **load a save whose store has movie shelves with cassettes already
   stocked** (staff must have placed cassettes, or place some yourself), and stand in the
   store near a movie shelf.
4. Press **F8** (or open the `` ` `` console and type `rrprobe`).
5. Read `UE4SS.log` from disk; grep `[RR-Probe]`. Work through Sections A→D.
6. **Iterate the probe as needed** (this is expected): if Section A's candidate list
   missed, copy the real class name from the sweep into `SHELF_CANDIDATES`, bump the
   `VERSION` string, save, **Ctrl+R**, press F8 again. To go deeper into a newly-named
   array/struct, raise `MAX_DEPTH`/`MAX_ELEMS` or read the specific key directly. Editing
   the probe is the **only** allowed code change in Phase 0.
7. From Section B + Section C coordinates, determine the **ordering rule**: sort slots by
   array index, list each slot's cassette world location, and confirm whether index order
   tracks a clean physical sweep (e.g. ascending then row-stepping). Record the exact rule.
8. For unknown #4 (employee slot pick) and #5 (move primitive): in Section B's dump look
   for shelf Blueprint **functions** with names like `*Place*`, `*Shelve*`, `*Restock*`,
   `*Slot*`, `*Add*Cartridge*` (the `Spawn and Fill Snack` analogue). If a clean
   placement function exists, record its name + signature (this is the Phase 3 primitive
   and may make Phase 6 unnecessary). If not, the Phase 3 primitive will be
   `K2_SetActorLocation` + rewriting the slot's stored ref — record what the slot ref is.
9. For unknown #4 specifically (Approach A feasibility): note any BT task class
   (`BTTask_*`) or shelf function that selects an empty slot; flag whether it looks
   randomized. If the running game doesn't expose it via reflection, mark Phase 6 as
   "needs deeper recon" — it does not block Phases 1–5.

**Constraints in play:** #6 (no Live View → reflection + log), #4 (copy GUID keys
verbatim into `CLAUDE.md`), #1 (the probe wraps reads in `ExecuteInGameThread`). The probe
writes nothing, so #2/#3/#5 don't apply yet.

**TEST / verify in-game:**
- `UE4SS.log` shows `PROBE START (probe-v1)` then a non-empty Section A with at least one
  class at count ≥ 1, and a Section B dump for that shelf.
- Section C prints at least one cassette with a numeric SKU (read path confirmed).
- You can answer, in writing, all six unknowns. If any section is empty or errors, the log
  shows the `pcall` error — iterate the probe (task 6) until every unknown is answered.

**HANDOFF:**
- Write every resolved fact into `CLAUDE.md`: fill §3 with the real movie-shelf class,
  slot array field name(s), slot→cassette reference type, and the ordering rule; mark each
  §6 item **RESOLVED** with the answer (and the exact GUID keys, verbatim). Note the move
  primitive decision and the persistence key. If you learned something the sibling's
  gotchas didn't cover, add it.
- Append a dated entry to `docs/PROGRESS.md`: what the probe revealed, the chosen move
  primitive, the persistence key, Approach A feasibility, and anything the next session
  must know.
- Leave the probe installed (read-only, harmless) until Phase 5 cleanup.

**Session kickoff (paste to start this session):**
> Read `CLAUDE.md`, `docs/PLAN.md`, and `docs/PROGRESS.md`, then execute Phase 0 (runtime
> investigation) exactly as specified in the plan. The probe mod already exists at
> `probe/RR Shelf Keeper Probe/`. Help me install it, walk me through pressing F8 in-game,
> then read `UE4SS.log` and resolve every unknown in `CLAUDE.md` §6, iterating the probe
> as needed. Write all answers back into `CLAUDE.md` and `docs/PROGRESS.md`.

---

## PHASE 1 — Layout snapshot (read + log, no file I/O)

**Objective:** On a hotkey, enumerate every movie shelf, build an ordered
`shelf → slotIndex → SKU` snapshot in the deterministic order fixed in Phase 0, and log it
— proving enumeration and ordering before any persistence or mutation.

**PREREQUISITES:** `CLAUDE.md`, `docs/PLAN.md`, `docs/PROGRESS.md`;
`D:\Github\rr-dupe-finder\RR Dupe Finder\Scripts\scan.lua` + `sku.lua` (enumeration +
SKU read pattern); `...\Mods\Auto Restock Snacks QoL\Scripts\main.lua` (shelf/array
iteration: `ForEach`, `GetArrayNum` with pcall guard, `[i]` access).

**Tasks:**
1. Create the shipping mod folder `RR Shelf Keeper/` (`enabled.txt` + `Scripts/main.lua`)
   and a config module. Junction it into `Mods\` (mirror the Phase 0 install command,
   `RR Shelf Keeper` target).
2. `sku.lua`: copy the verified SKU read (and title, for readable logs) from the sibling —
   reuse, don't re-derive. Use the **exact GUID keys recorded in `CLAUDE.md`**.
3. `layout.lua` → `snapshot()`: `FindAllOf(<movie shelf class>)`, skip `Default__`, and for
   each shelf read its slot array (field name from Phase 0). For each slot record
   `{ slotIndex, sku }` (or `nil`/empty for an empty slot), in the Phase-0 ordering. Key
   each shelf by a stable id (full name, or a name+location hash — decide from Phase 0).
4. `main.lua`: a hotkey (suggest **F9**) + console command (`rrshelf snapshot`) that runs
   `snapshot()` inside `ExecuteInGameThread` and logs a readable table per shelf
   (`slot 1: "Title" (SKU n)` …). Tag output `[RR-Shelf]`.

**Deliverables:** `RR Shelf Keeper/Scripts/{main,config,sku,layout}.lua`,
`RR Shelf Keeper/enabled.txt`. `layout.snapshot()` returns an in-memory table; nothing is
written to disk yet.

**Constraints in play:** #1 (snapshot runs in `ExecuteInGameThread`, one-shot off the
hotkey — no async loop); #4 (GUID keys verbatim); #3 (the hotkey/console registration is
top-level and fine; no hooks this phase).

**TEST / verify in-game:** Load a stocked store, press F9, read `UE4SS.log`: every movie
shelf is listed with its slots in a stable order; SKUs match what you see on the shelf;
re-pressing F9 without moving anything yields an identical dump. Empty slots are clearly
marked.

**HANDOFF:** Update `CLAUDE.md` if anything about the slot model/ordering was refined.
Append a dated `docs/PROGRESS.md` entry: the shelf-id scheme chosen, the snapshot table
shape, and the exact field names used. Note the in-memory snapshot format Phase 2 will
serialize.

**Session kickoff:**
> Read `CLAUDE.md`, `docs/PLAN.md`, and `docs/PROGRESS.md`, then implement Phase 1
> (layout snapshot, read + log only) exactly as specified in the plan. Stop at an
> in-memory snapshot logged to `UE4SS.log` — no file I/O yet.

---

## PHASE 2 — Persist snapshot to a per-save file + load back

**Objective:** Save the Phase 1 snapshot to a side file keyed by the active save, and load
it back into the same in-memory shape — so a layout survives a game restart.

**PREREQUISITES:** `CLAUDE.md`, `docs/PLAN.md`, `docs/PROGRESS.md`; the Phase 0
persistence-key finding; `CLAUDE.md` §5 (UE4SS Lua has standard `io` file access — write
the snapshot to the mod folder keyed by the active save).

**Tasks:**
1. `store.lua`: `save(key, snapshot)` and `load(key)` using Lua `io`. Serialize as a Lua
   return-table (simplest, no JSON dependency) or minimal JSON — pick one and note why.
   Write under the mod folder (e.g. `RR Shelf Keeper/layouts/<key>.lua`). Guard all I/O
   with `pcall`; never crash the game on a bad/missing file.
2. `key.lua`: derive the per-save key from the Phase 0 finding (gamemode/savegame field or
   the `.sav` name). Sanitize to a safe filename. If no reliable key exists, fall back to a
   single `default` file and log a warning.
3. Wire hotkeys/console: `rrshelf save` (snapshot → `store.save`) and `rrshelf load`
   (`store.load` → in-memory, log it). All inside `ExecuteInGameThread`.

**Deliverables:** `RR Shelf Keeper/Scripts/{store,key}.lua`; a written
`layouts/<key>.lua`; save/load wired to commands. Optionally a tiny pure-Lua unit test for
serialize/deserialize round-trip (the sibling unit-tests its pure modules with standalone
Lua — mirror that if convenient).

**Constraints in play:** #1 (I/O triggered one-shot on the game thread); #4 (keys
verbatim if any struct read is added).

**TEST / verify in-game:** `rrshelf save` writes `layouts/<key>.lua` (verify on disk);
restart the game, load the same save, `rrshelf load` — the logged layout matches what was
saved. Loading a non-existent key logs a clean "no layout" message, no crash. Two
different saves produce two different key files.

**HANDOFF:** Record the final key scheme + file format and path in `CLAUDE.md`. Append a
`docs/PROGRESS.md` entry noting the serialization choice and any sanitization rules.

**Session kickoff:**
> Read `CLAUDE.md`, `docs/PLAN.md`, and `docs/PROGRESS.md`, then implement Phase 2
> (persist the snapshot to a per-save side file and load it back) exactly as specified in
> the plan.

---

## PHASE 3 — Layout enforcement on a manual hotkey (the correction primitive)

**Objective:** On a manual hotkey, compare current shelves to a loaded snapshot and
correct **only mismatched** slots so each slot holds its assigned SKU again — proving the
mutation primitive by hand before any automation. This is the crux of the project.

**PREREQUISITES:** `CLAUDE.md`, `docs/PLAN.md`, `docs/PROGRESS.md`; the Phase 0 move-
primitive decision; `D:\Github\rr-dupe-finder\RR Dupe Finder\Scripts\highlight.lua` (the
proven actor spawn/destroy recipe and `K2_DestroyActor`, in case correction relocates or
respawns actors); `...\Mods\Auto Restock Snacks QoL\Scripts\main.lua` (the
`Return Snack Base Save Struct` / `Spawn and Fill Snack` pattern — the closest analogue if
movie shelves expose a placement function).

**Tasks:**
1. `enforce.lua` → `diff(currentSnapshot, savedSnapshot)`: per shelf+slot, list slots
   whose current SKU ≠ saved SKU (and slots that should be empty/filled). Pure logic —
   unit-testable without the game.
2. `enforce.lua` → `apply(diffs)`: for each mismatch, run the **Phase-0 move primitive**:
   - If a clean Blueprint placement function exists, call it with output-param tables as
     needed (pattern: `obj["Fn Name"](inArg, out1, out2)`).
   - Else relocate: find the cassette actor with the wanted SKU, `K2_SetActorLocation` to
     the slot's transform, and rewrite the slot's stored cassette ref. Handle the
     swap/displacement case (the cassette currently in the slot must go somewhere).
   - Correct **only** mismatches (constraint: don't touch correct slots).
3. Wire `rrshelf enforce` + a hotkey (suggest **F10**), running `diff`+`apply` inside one
   `ExecuteInGameThread` pass. Log how many slots were corrected.
4. (Optional, if useful for debugging) mark an out-of-place slot with a spawned marker
   mesh — **reuse the sibling's spawn recipe**; **no DrawDebug, no DMI** (constraint #2).

**Deliverables:** `RR Shelf Keeper/Scripts/enforce.lua`; `rrshelf enforce` + hotkey; a
pure-Lua unit test for `diff`.

**Constraints in play (call out explicitly):** **#1** — the entire correction is one
synchronous `ExecuteInGameThread` pass; **never** a continuous loop (sibling gotcha 19
hard-crashes). **#5** — this phase only fires on a *manual* press; do not auto-run it yet.
**#2** — any visual marker is a spawned mesh/premade material, never debug draw, never a
DMI. **#4** — slot/cassette struct keys verbatim from Phase 0.

**TEST / verify in-game:** Snapshot a tidy store (Phase 2 `save`). Let staff scramble it
(or move cassettes yourself). Press F10 (or `rrshelf enforce`): mismatched slots return to
their saved SKU; correct slots are untouched; the log reports the corrected count.
Enforcing an already-correct store corrects 0 and is a no-op. No crash, no GC hitch beyond
a brief one-pass stall.

**HANDOFF:** Record the working move primitive (function name + signature, or the
relocate+rewrite recipe) and any displacement/edge-case handling in `CLAUDE.md`. Append a
`docs/PROGRESS.md` entry: what worked, what didn't, measured hitch on your store size.

**Session kickoff:**
> Read `CLAUDE.md`, `docs/PLAN.md`, and `docs/PROGRESS.md`, then implement Phase 3
> (manual-hotkey layout enforcement / the correction primitive) exactly as specified in
> the plan. Keep it manual-trigger only — no automatic triggers this session.

---

## PHASE 4 — Wire enforcement to automatic triggers

**Objective:** Run enforcement automatically on discrete game triggers (store open,
per-minute tick, end of day) — never continuously — with config to choose which triggers
are active.

**PREREQUISITES:** `CLAUDE.md`, `docs/PLAN.md`, `docs/PROGRESS.md`; `CLAUDE.md` §3
(confirmed event paths: `OpenSign_C:Change Sign`, `WeatherSystem_C:Timer Event - Add one
minute`, `WeatherSystem_C:ReceiveBeginPlay`, `Core_Gamemode_C:End of the day`);
`...\Mods\Auto Restock Snacks QoL\Scripts\main.lua` (the exact hook registration for all
of these, the `ExecuteWithDelay(3000, ...)` deferral, gamemode caching, and per-day reset
trackers) — this is the closest working template; mirror it.

**Tasks:**
1. `triggers.lua`: register hooks via `ExecuteWithDelay`/`NotifyOnNewObject` (never at
   startup). On each enabled trigger, run the Phase 3 enforce pass once
   (`ExecuteInGameThread`). Reuse the sibling's de-dupe guards (e.g. `openedAtHour`,
   `lastRestockHour`) so a trigger doesn't fire enforcement repeatedly within the same
   game-minute/open event.
2. Reset per-day/per-session state on `WeatherSystem_C:ReceiveBeginPlay` and
   `Core_Gamemode_C:End of the day` (mirror the snack mod's `resetTrackers`).
3. Cache the gamemode/shelf list where safe (sibling `getGamemode` pattern); re-validate
   with `:IsValid()` before reuse.
4. Config: booleans for each trigger (`enforceOnOpen`, `enforceHourly`/which hours,
   `enforceOnEndOfDay`, hotkey-only). Auto-load the saved layout on
   `ReceiveBeginPlay` so enforcement has a snapshot to enforce against.

**Deliverables:** `RR Shelf Keeper/Scripts/triggers.lua`; config trigger flags; auto-load
on save load.

**Constraints in play (call out explicitly):** **#5** — enforcement fires only on these
discrete events, never on a tick loop, so a cassette is never yanked mid-animation. **#3**
— all hooks registered late via `ExecuteWithDelay`/`NotifyOnNewObject` + retry guard.
**#1** — each trigger runs one synchronous enforce pass.

**TEST / verify in-game:** With `enforceOnOpen = true`, scramble the store while closed,
open the store → shelves snap to the saved layout. With a per-minute/hourly trigger, watch
it correct at the configured time and **not** spam every minute (de-dupe guard works).
End-of-day trigger fires once. Disabling all triggers reverts to hotkey-only (Phase 3
behavior). Confirm no crash across a full open→close→new-day cycle.

**HANDOFF:** Record which triggers proved reliable and any timing gotchas in `CLAUDE.md`.
Append a `docs/PROGRESS.md` entry with the final trigger set and config flags.

**Session kickoff:**
> Read `CLAUDE.md`, `docs/PLAN.md`, and `docs/PROGRESS.md`, then implement Phase 4 (wire
> layout enforcement to automatic discrete triggers) exactly as specified in the plan.

---

## PHASE 5 — Forced-order mode

**Objective:** Generate an ordered snapshot — SKUs laid out across slots left→right,
top→bottom in a chosen order — and feed it to the Phase 3/4 engine, expressing the
"forced ordered placement" feature entirely through the layout engine.

**PREREQUISITES:** `CLAUDE.md`, `docs/PLAN.md`, `docs/PROGRESS.md`; Phase 1 ordering rule;
Phases 2–4 modules.

**Tasks:**
1. `order.lua` → `generate(currentInventory, rule)`: collect the SKUs to place (from the
   current shelves' contents and/or backstock), sort by the chosen `rule` (e.g. SKU
   ascending, or a configured genre/shelf grouping), and assign them to slots in the
   Phase-0 physical order, producing a snapshot in the Phase 1/2 shape.
2. Add `rrshelf order` (+ optional hotkey): generate an ordered snapshot, save it as the
   active layout (Phase 2), and enforce it (Phase 3). Forced-order = generated layout +
   enforce.
3. Config: the ordering rule and its scope (all shelves vs a named shelf).

**Deliverables:** `RR Shelf Keeper/Scripts/order.lua`; `rrshelf order`; pure-Lua unit test
for `generate` (deterministic ordering).

**Constraints in play:** #1 (generation is pure logic; the subsequent enforce is the
existing synchronous pass); #5 (enforcement still trigger/hotkey-gated).

**TEST / verify in-game:** Run `rrshelf order` on a scrambled store → cassettes fill slots
in the configured order, left→right/top→bottom, deterministically. Re-running yields the
same arrangement. The generated layout persists (Phase 2) and is re-applied by triggers
(Phase 4).

**HANDOFF:** Record the ordering rule(s) implemented in `CLAUDE.md`. Append a
`docs/PROGRESS.md` entry on inventory sourcing (placed vs backstock) and any sort caveats.

**Session kickoff:**
> Read `CLAUDE.md`, `docs/PLAN.md`, and `docs/PROGRESS.md`, then implement Phase 5
> (forced-order mode: generate an ordered snapshot and enforce it) exactly as specified in
> the plan.

---

## PHASE 6 — Config, polish & cleanup

**Objective:** Finalize configuration, per-shelf targeting, optional visual feedback, and
remove the probe — ship-ready.

**PREREQUISITES:** `CLAUDE.md`, `docs/PLAN.md`, `docs/PROGRESS.md`; all prior modules;
`D:\Github\rr-dupe-finder\RR Dupe Finder\Scripts\highlight.lua` (spawn-marker recipe) if
adding visual feedback.

**Tasks:**
1. Consolidate `config.lua`: triggers (open/hour/end-of-day/hotkey-only), managed-shelf
   selection (all vs named like "New Releases"), ordering rule, debug verbosity, hotkey
   bindings. Document each option.
2. Optional visual feedback: mark out-of-place cassettes with a spawned marker mesh /
   premade material (reuse the sibling recipe). **No DrawDebug, no DMI** (constraint #2).
3. Performance pass: cache the gamemode + shelf list; correct only mismatching slots;
   confirm the hitch is acceptable on a large store (sibling saw ~0.5 s for snacks).
4. Remove/disable the probe mod (delete the junction or `enabled.txt`). Write a `README.md`
   describing install, config, and commands.

**Deliverables:** finalized `config.lua`, optional marker feedback, `README.md`, probe
removed.

**Constraints in play:** #2 (marker mesh / premade material only), #1 (no async),
#5 (triggers stay discrete).

**TEST / verify in-game:** Each config toggle behaves as documented; named-shelf targeting
limits scope correctly; on a large store the enforce pass stays within an acceptable
hitch; with the probe removed the log only shows `[RR-Shelf]` output.

**HANDOFF:** Final `CLAUDE.md` pass — mark the project shipped, list config options and
commands. Append a closing `docs/PROGRESS.md` entry.

**Session kickoff:**
> Read `CLAUDE.md`, `docs/PLAN.md`, and `docs/PROGRESS.md`, then implement Phase 6 (config,
> polish, visual feedback, and probe cleanup) exactly as specified in the plan.

---

## PHASE 7 — (OPTIONAL) Approach A: at-source AI placement hook

**Objective:** Intercept the employee's slot-selection decision so cassettes are placed in
the right slot at restock time — only if Phase 0 found the decision point cleanly hookable.

**Build only if:** Phase 0 (unknown #4) identified a hookable BT task / function that
selects the target slot, and you want true at-source ordering rather than after-the-fact
correction.

**PREREQUISITES:** `CLAUDE.md`, `docs/PLAN.md`, `docs/PROGRESS.md`; the Phase 0 finding on
the slot-selection point; `CLAUDE.md` §7 gotchas (Blackboard navigation is unreliable —
`GetOuter()` from a BT context can return Blackboard key addresses, not real refs;
hook late).

**Tasks:**
1. Hook the slot-selection function/task (via `ExecuteWithDelay`/`NotifyOnNewObject`).
2. In the callback, override the chosen slot with the next slot from the active layout /
   forced order, reading shelves directly (don't traverse from AI context — gotcha).
3. Fall back to the Phase 3/4 enforce engine if the override can't be applied safely.

**Deliverables:** an at-source hook module; config flag to enable it.

**Constraints in play:** #3 (hook late), #1 (no async on NPC refs — synchronous reads
only), and the Blackboard-traversal gotcha (enumerate shelves directly).

**TEST / verify in-game:** With the hook on, staff place restocked cassettes directly into
the correct slots; the enforce engine becomes a rarely-needed safety net.

**HANDOFF:** Record feasibility + the hooked function in `CLAUDE.md`. Append a final
`docs/PROGRESS.md` entry.

**Session kickoff:**
> Read `CLAUDE.md`, `docs/PLAN.md`, and `docs/PROGRESS.md`, then implement Phase 7
> (optional at-source AI placement hook) exactly as specified in the plan — only if Phase 0
> confirmed the slot-selection point is cleanly hookable.

---

## Module map (target end state, under `RR Shelf Keeper/Scripts/`)

| Module | Responsibility | Introduced |
|--------|----------------|-----------|
| `main.lua` | entry: keybinds, console commands, wiring | P1 |
| `config.lua` | all tunables/flags | P1, finalized P6 |
| `sku.lua` | cassette SKU/title read (verbatim keys) | P1 |
| `layout.lua` | enumerate shelves → ordered slot→SKU snapshot | P1 |
| `store.lua` | serialize/deserialize snapshot to side file | P2 |
| `key.lua` | per-save key derivation | P2 |
| `enforce.lua` | diff snapshot vs current; apply corrections | P3 |
| `triggers.lua` | late-registered discrete-trigger hooks | P4 |
| `order.lua` | generate forced-order snapshot | P5 |
| (probe) `probe/RR Shelf Keeper Probe/` | READ-ONLY Phase 0 recon; removed in P6 | P0 |

Pure-logic modules (`layout` ordering, `enforce.diff`, `order.generate`,
`store` round-trip) should have standalone Lua unit tests, mirroring the sibling repo's
`tests/` approach.
