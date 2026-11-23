# Code mods for this port

Copy these folders into a `mods` folder next to your NSPs before you build. Each one has a `dm_toggle.txt` (`<setting>=<value>`) that names the launcher setting that switches it on; the build embeds a copy of each patched module for every combination, and the app picks one when you press Play ([dm/tools/exefs_mods.py](../../../../dm/tools/exefs_mods.py), `loader.c` `code_mods`).

| Folder | Switched by | What it is |
|---|---|---|
| `ACNH 60 FPS + SpeedFix/` | Frame rate **60** (`DM_FPS_TARGET=60`) | Only its `dm_toggle.txt`: download the mod itself from GameBanana (see its README) |
| `ACNH Ultrawide (iPhone 19.5x9)/` | **Ultrawide** (`DM_ULTRAWIDE=1`) | The ACNH 3.0.3 21:9 Ultrawide v2 patch (MIT No Attribution), its target ratio changed from 43:18 to 19.5:9 for iPhone screens (noted at the top of its `.pchtxt`) |
