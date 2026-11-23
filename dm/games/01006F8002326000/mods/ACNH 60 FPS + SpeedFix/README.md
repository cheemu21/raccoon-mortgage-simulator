# ACNH 60 FPS + SpeedFix (not included)

[**ACNH 60 FPS + SpeedFix (3.0.X)**](https://gamebanana.com/mods/722295) by **tmouh** (v1.4.5, CC BY-NC 4.0). It is not redistributed here: its `romfs/Pack/StaticParam.pack` is modified Nintendo game data.

1. Download it from its GameBanana page.
2. Copy its `ACNH 60 FPS + SpeedFix` folder (the one holding `exefs/` and `romfs/`) into the `mods` folder next to your NSPs.
3. Copy `dm_toggle.txt` from this folder into it. It holds `DM_FPS_TARGET=60`: the launcher's Frame rate 60 turns the mod on, and 30 plays the game as it is.

The build then makes the copies of `main` and `sdk` it needs and puts the mod's romfs files in the app ([dm/tools/exefs_mods.py](../../../../../dm/tools/exefs_mods.py)).
