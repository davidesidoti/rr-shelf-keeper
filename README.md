# rr-shelf-keeper

A [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) Lua mod for **Retro Rewind: Video Store Simulator** that stops your staff from scrambling your shelves. Stock movies in a fixed order, and save a shelf layout so employees keep it that way instead of mixing everything up.

> **Status: in development.** Not released yet. The design is scoped and the game's shelf system is understood; the build is in progress. Feature behavior below describes the goal.

> **Game:** Retro Rewind: Video Store Simulator (Unreal Engine 5.4)
> **Framework:** UE4SS v3.0.1

---

## What it does

By default, staff restock movies into random empty slots, which wrecks any layout you set up (New Releases, genre shelves, alphabetical, whatever). This mod fixes that two ways:

- **Ordered placement.** Staff fill shelves in a fixed order (left to right, top to bottom) instead of at random.
- **Save and lock a layout.** Snapshot which movie belongs in which slot, then keep your shelves matching that snapshot so staff stop rearranging them.

Under the hood these are the same system: forced ordering is just a layout the mod generates and enforces.

## Roadmap

- [ ] Snapshot the current shelf layout (which SKU is in which slot) to a per-save file.
- [ ] Enforce the saved layout on triggers (store open, end of day, or on demand).
- [ ] Forced ordered placement (left to right, top to bottom).
- [ ] Config: which shelves to manage, when to enforce, ordering rule, keybinds.
- [ ] Optional: correct placement at the source by overriding the staff slot pick.

---

## Requirements

- **UE4SS v3.0.1** must be installed first. Follow the install instructions on the [UE4SS Nexus page](https://www.nexusmods.com/retrorewindvideostoresimulator/mods/52).

## Installation

Once released, install like any UE4SS Lua mod: copy the `RR Shelf Keeper` folder into

```
<SteamLibrary>\steamapps\common\RetroRewind\RetroRewind\Binaries\Win64\ue4ss\Mods\
```

The folder will contain an empty `enabled.txt` and a `Scripts\main.lua`. Then launch the game and load your save.

## Usage

Planned: save your current layout with a keypress, and the mod keeps your shelves matching it. Full controls and config will be documented here at release.

---

## How it works

Movie shelves hold an ordered array of slots, each slot holding a cassette (`Cartridge_Base_C`) identified by its SKU. The mod reads that slot to SKU mapping, saves it, and re-applies it whenever staff have moved things out of place, rather than fighting the AI mid-action. Layout enforcement runs on discrete triggers (store open, end of day, on demand) to stay safe and stable.

## Compatibility

- Layout data is stored in a side file per save; your game save is not modified by the layout system.
- Built to coexist with other UE4SS Lua mods.

## Development

See [`CLAUDE.md`](./CLAUDE.md) for the full technical context: the game's shelf and AI architecture, the UE4SS API patterns used, the design approaches, known gotchas, and the open questions to resolve before and during the build.

## Credits

- **UE4SS-RE** for the scripting framework.
- The **Auto Restock Snacks QoL** mod, the primary reference for the game's shelf and slot model.
- The **Employee Mod** and **SKU QoL** mods for the staff/save and cassette/SKU internals.

## License

MIT. See [`LICENSE`](./LICENSE). (Swap this out if you prefer something else.)
