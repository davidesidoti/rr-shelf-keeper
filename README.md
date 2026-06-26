# rr-shelf-keeper

A [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) Lua mod for **Retro Rewind: Video Store Simulator** that stops your staff from scattering movies across your shelves. Employees restock each shelf in a fixed physical order — top to bottom, left to right — so it fills up neatly instead of leaving random gaps.

> **Game:** Retro Rewind: Video Store Simulator (Unreal Engine 5.4)
> **Framework:** UE4SS v3.0.1

---

## What it does

By default, staff drop restocked movies into whatever empty slot the game picks, which leaves your shelves looking scattered and full of gaps. This mod overrides that choice: when an employee restocks a movie shelf, the mod points them at the **next empty slot in physical order** — filling the top row left to right, then the next row down, and so on.

- Shelves fill in a clean, predictable order instead of at random.
- It works at the moment of restocking — the mod redirects the staff's slot choice, so **no cassette is ever yanked around or moved after it's placed**.
- Every movie shelf type is covered, including the double-sided racks (front and back fill from the same physical end, not mirrored).

## Configuration

Settings live in `RR Shelf Keeper\Scripts\config.lua`:

| Setting | Default | Effect |
|---------|---------|--------|
| `OrderedRestock` | `true` | Master switch for the ordered-restock override. |
| `FillTopFirst` | `true` | Fill rows top→bottom. Set `false` to fill bottom-up. |
| `FillLeftFirst` | `true` | Fill each row left→right. Flip if it comes out mirrored on your shelves. |
| `RowTol` | `15` | Height tolerance (cm) for grouping slots into the same row. |
| `RestockDryRun` | `false` | `true` logs what it *would* do without changing placement (debugging). |
| `RestockVerbose` | `false` | `true` logs each override (noisy; debugging only). |

Edit the file and use UE4SS hot-reload (Ctrl+R) to apply changes without restarting the game.

---

## Requirements

- **UE4SS v3.0.1** must be installed first. Follow the install instructions on the [UE4SS Nexus page](https://www.nexusmods.com/retrorewindvideostoresimulator/mods/52).

## Installation

Install like any UE4SS Lua mod: copy the `RR Shelf Keeper` folder into your game's UE4SS Mods folder, e.g.

```
<SteamLibrary>\steamapps\common\RetroRewind\Binaries\Win64\ue4ss\Mods\
```

The folder contains an empty `enabled.txt` and the `Scripts\` Lua. Launch the game and load your save — on load you'll see `RR Shelf Keeper loaded (...)` in `UE4SS.log`, and from then on staff restock movies in order.

---

## How it works

Each movie shelf exposes an ordered array of slots, and the restock AI calls one Blueprint function (`Shelve_C: Does any Shelve Containers still empty`) to get the slot it should fill next. The mod hooks that function and rewrites its answer to the next empty slot in **physical** order, computed from each slot's world position: rows by height, columns projected onto the shelf's own facing (so the two sides of a double-sided shelf both fill from the same end). The staff then place the movie there as normal — the mod never touches a cassette directly, so there's no fighting the AI mid-animation and no risk to your save.

A second, more ambitious feature — snapshotting and locking an exact movie-to-slot layout — was prototyped and set aside in favor of this simpler at-restock approach; see `docs/` for that history.

## Compatibility

- The mod only redirects the staff's slot choice at restock time; it does not modify your game save.
- Guarded to movie shelves only — snack and concession shelves are left untouched.
- Built to coexist with other UE4SS Lua mods.

## Development

See [`docs/PROGRESS.md`](./docs/PROGRESS.md) for the session-by-session build log, and [`docs/superpowers/`](./docs/superpowers/) for the ordered-restock spec and plan. The full technical context (the game's shelf/AI architecture, UE4SS API patterns, and known gotchas) lives in the project's local `CLAUDE.md`.

## Credits

- **UE4SS-RE** for the scripting framework.
- The **Auto Restock Snacks QoL** mod, the primary reference for the game's shelf and slot model.
- The **Employee Mod** and **SKU QoL** mods for the staff/save and cassette/SKU internals.

## License

MIT. See [`LICENSE`](./LICENSE). (Swap this out if you prefer something else.)
