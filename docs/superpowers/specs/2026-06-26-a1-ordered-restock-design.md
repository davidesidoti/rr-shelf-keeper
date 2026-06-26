# A1 — Ordered restock (at-source slot selection)

**Status:** design approved (2026-06-26). Supersedes the Approach-B physical-enforce mechanism
(Phases 1–3) as the way the user wants ordering achieved. Those modules stay in the tree but are
not the mechanism for this feature.

## Goal

When a staff member restocks a movie shelf, they place each cassette into the **next empty slot in
physical order** (left→right, top→bottom) — so shelves fill densely with no scattered gaps. The
movie that lands in a given slot just depends on restock order; the goal is "no random holes."
**No cassette is ever moved after placement** — we redirect the employee's choice at restock time.

## Confirmed mechanism (recon, airecon-v1/v2, 2026-06-26)

- Restock is driven by the Behavior Tree `AI_Staff_BehaviorTree` on `AI_Employee_Character_C` actors,
  orchestrated by `AI_Director_C`.
- The slot is chosen by **`Shelve_C: Does any Shelve Containers still empty`** →
  returns `(One container is empty: Bool, Empty Container: Object, …locals)`. The staff then stock
  into the returned `Empty Container` (confirmed: 4/4 live placements filled the **highest empty
  array-index**, i.e. the last empty the function's `1→N` loop returns).
- Class path (resolved live): `/Game/VideoStore/asset/prop/shelve/Shelve.Shelve_C`. The function is
  on the base `Shelve_C`, so **one hook covers every movie-shelf leaf class**.
- Genre fitting is shelf-level (a shelf is one genre), so **any** empty slot on a shelf that accepts
  the held movie is a valid target — picking the physical-first empty is safe.

## Approach

Hook `Shelve_C: Does any Shelve Containers still empty` and, for a managed movie shelf with ≥1 empty
container, **overwrite its `Empty Container` output** with the next empty container in physical fill
order. The staff then stock that slot. This is a pure interception — it changes only which empty
slot is returned, never moving a placed cassette.

### Why this over alternatives
- vs gating `Can AI reserve it?` per container: that function only gates availability; the slot
  choice is `Does any Shelve Containers still empty`. Overriding the chooser's return is the direct,
  single point.
- vs hooking the BT task: the BT task's slot logic is buried in its ubergraph (Blackboard refs,
  hard). The `Shelve_C` function is a clean, typed return we can rewrite.

## Components (under `RR Shelf Keeper/Scripts/`)

| Module | Responsibility | Kind |
|--------|----------------|------|
| `order.lua` | **pure:** given a shelf's containers (index, world loc, isEmpty) + a fill rule, return the next container index to fill in physical order. Unit-tested offline. | new, pure |
| `restock.lua` | **runtime:** register the late hook on `Does any Shelve Containers still empty`; on fire, if the shelf is managed + has an empty slot, compute the ordered target via `order.lua` and `:set()` the `Empty Container` (and `One container is empty`) out-params. | new, runtime |
| `config.lua` | add `OrderedRestock` (enable), fill-direction flags (`FillTopFirst`, `FillLeftFirst`), and managed-shelf scope. | extend |
| `main.lua` | register the restock hook on load (late, `NotifyOnNewObject`/`ExecuteWithDelay`), behind the config flag; keep a toggle/log. | extend |

Reused: the movie-shelf leaf-class list + `All Selve Containers` / `Object owning of this container`
keys (`layout.lua`), and the §6.3 physical-order idea (Z = row, Y = column, X tilts with Z). The
Phase 1–3 modules (`store`, `key`, `enforce`) are untouched and unused by this feature.

## Physical fill order (`order.lua`)

Each container exposes a world location (readable even when empty, `K2_GetComponentLocation`).
Group by **row = Z** and **column = Y**; X tilts with Z so it's ignored for ordering. Sort empty
containers by (row, column) per the configured direction and return the first:
- `FillTopFirst` (default true): rows by Z **descending** (top shelf first) — else ascending.
- `FillLeftFirst` (default true): columns by Y **ascending** — else descending. (Exact left/right
  axis sign is confirmed in-game and flipped via this flag if mirrored.)
Rounding tolerance groups near-equal Z into the same row (Z values cluster, e.g. −18/12/42/72).
Pure function: `order.nextEmpty(containers, rule) -> index|nil`, deterministic, fully unit-tested.

## Hook / out-param override (`restock.lua`)

- Register late: `NotifyOnNewObject` on a movie shelf class (or `ExecuteWithDelay`) → `RegisterHook(
  "/Game/VideoStore/asset/prop/shelve/Shelve.Shelve_C:Does any Shelve Containers still empty", cb)`.
- The callback receives `(self, OneContainerIsEmpty, EmptyContainer)` (the function's in/out params,
  RemoteUnrealParam). Read `self:get()` = the shelf:
  - **Guard:** managed movie shelf (class in the leaf list / has `All Selve Containers`); else return
    (leave snack shelves / ClearanceBin untouched).
  - Read `All Selve Containers`, build `{index, loc, isEmpty}` (empty = no valid
    `Object owning of this container`).
  - `idx = order.nextEmpty(...)`; if nil (no empty) return.
  - `EmptyContainer:set(containers[idx])` and `OneContainerIsEmpty:set(true)`.
- Whether a **post** hook (out-params set after the native call) vs pre is needed — and whether
  `:set()` on the out-param actually redirects the placement — is the first thing validated in-game.

## Config

- `OrderedRestock = true` — master enable.
- `FillTopFirst = true`, `FillLeftFirst = true` — fill direction (eyeballed + flipped in-game).
- Managed scope = the movie-shelf leaf classes (snack shelves + `ClearanceBin_Base_C` excluded).

## Testing

- **Offline (TDD):** `order.nextEmpty` — row/column grouping, direction flags, all-empty vs partial,
  no-empty → nil, deterministic, rounding tolerance. (`tests/order_test.lua`.)
- **In-game:** enable, start a day, let staff restock → cassettes fill the next ordered slot
  (top-left first), densely, no gaps; re-confirm across several placements; flip a direction flag and
  see the order mirror. Confirm no crash and snack/clearance restock is unaffected.

## Risks / open items

1. **Out-param override may not redirect placement** — the staff might cache or re-pick. Mitigation:
   validate first with a single hook that logs + sets, watch one restock. If it doesn't redirect,
   fall back to also hooking the commit point (`Store the Object` pre-hook to swap the target) — but
   that edges toward a move, so confirm with the user before going there.
2. **Hook-fire frequency** — `Does any…` fires per-shelf during shelf-finding; the callback must be
   cheap (one container-array read + a sort of ≤24 items) and must not mutate on non-managed shelves.
3. **Concurrent staff** — multiple employees restocking; each call is independent and recomputes from
   live empties, so ordering stays consistent (the next empty is always the physical-first).
