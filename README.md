# Daydream Checkpoints — Project Zomboid Build 42

**Sleep to set a checkpoint. Die, and wake up from the nightmare — back at
your last morning, the whole world rewound with you.**

Every time your character wakes from sleep, the game saves and the entire
save is snapshotted. If you die, the death screen offers **Wake up at last
checkpoint**: the world rolls all the way back to that morning — your body,
your inventory, the map, the zombies, the clock — and your survivor recounts
the death as a bad dream.

Unlike an in-game "second chance" that only heals you, this is a true
save-level rewind. Nothing from the lost run carries over.

Singleplayer only.

## What it does

- **Wake = checkpoint.** Waking from sleep saves and snapshots the save
  folder. Your survivor mutters something about the new day.
- **Configurable cadence.** Options → Mods → Daydream Checkpoints: set a
  minimum number of in-game days between checkpoints (0 = every sleep).
- **Die = rewind.** The death screen gains "Wake up at last checkpoint".
  Click it and the game restores the snapshot and loads you straight back
  in — no menu fiddling.
- **Nightmare narration.** After a rewind, your survivor remembers how they
  "died" — a bite, a fire, the cold, starvation, the horde — as a dream.

## Requirements

- Windows 10/11 (64-bit)
- Project Zomboid Build 42
- The companion watcher must be running (see install) — it does the
  file-level snapshot/restore the in-game Lua can't. Without it, the mod
  still saves on sleep but can't make or restore checkpoints.

## Install

1. Extract this package into your Project Zomboid **install** folder
   (the one with `ProjectZomboid64.exe`), e.g.
   `C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid\`.
   This places `dinput8.dll` next to the exe and the mod under `mods\`.
2. Start Project Zomboid and enable **Daydream Checkpoints** in the Mods
   menu (and in your save's mod list).
3. Play. The checkpoint watcher starts automatically with the game.

### Don't want the auto-start DLL?

The `dinput8.dll` only exists to launch the watcher for you. If you'd
rather not use it, delete it and start the watcher yourself before playing
by running `watcher\DaydreamWatcher.ps1` (or the included
`Play PZ (Daydream).bat`).

## How it works

Project Zomboid streams the world to disk continuously — there's no single
"save file" a mod can copy, and Lua can't touch the save folder. So Daydream
splits in two:

- The **mod** (in-game Lua) detects sleep and death, forces saves, and
  writes tiny request files to `Zomboid\Lua\`.
- The **watcher** (a small PowerShell process) reads those requests and does
  the real file work: copying the save folder to
  `Zomboid\DaydreamCheckpoints\` on checkpoint, and swapping it back on
  restore. It waits for the game to fully unload the save before restoring,
  and always takes a safety snapshot of the pre-restore state first.

## Uninstall

Disable the mod in-game, then delete `mods\DaydreamCheckpoints`, the
`dinput8.dll` next to the exe, and (optionally) your `Zomboid\DaydreamCheckpoints`
backups.

## Project layout

```
mods\DaydreamCheckpoints\   the mod (Lua, mod.info, poster)
watcher\                    the companion watcher (PowerShell)
proxy\                      dinput8.dll source (auto-starts the watcher)
build\package.ps1           assembles the distributable zip
```

## Building from source

The proxy DLL is built with [Zig](https://ziglang.org/) (works as a plain C
compiler here, no Zig code involved):

```
zig cc -O2 -shared -o proxy\dinput8.dll proxy\dinput8.c
```

Then package everything into a distributable zip:

```
powershell -File build\package.ps1
```

This writes `dist\DaydreamCheckpoints_v<version>.zip`, laid out to extract
straight into the Project Zomboid install folder.

## License

MIT (see LICENSE). Original work — same general idea as other Project
Zomboid save-checkpoint mods (snapshot the save folder, restore it later),
but built from scratch against the vanilla game API. Not affiliated with
The Indie Stone.
