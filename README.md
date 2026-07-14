# Raiden II (Japan) — Enhancement Patch

A ROM patch for **Raiden II (Japan)** (`raiden2j`, Seibu Kaihatsu 1993) adding a
boot-time options menu and an in-game stage select with weapon, item, and
difficulty controls. Verified against MAME's `raiden2j` set.

> **Most people should use the web patcher at
> <https://kiban.alamone.net/modtools/r2tool/>** — it
> applies the patch and lets you choose the default options right in your
> browser, no tools needed. This repository is the source code and the
> command-line build, for anyone who wants to inspect or modify the mod.

## Features

**Boot menu** (shown once at power-on; the auto-confirm timeout is adjustable
0–60 s, default 30 s — set it to 0 to skip the menu entirely, in which case
holding P1 Start at power-on still brings it up):

| Option       | Values                          |
|--------------|---------------------------------|
| DEBUG MENU   | ON / OFF                        |
| STAGE SELECT | ON / OFF                        |
| MULTI WEAPON | ON / OFF (gates the stage-select MULTI WPN option) |
| REGION       | 22 region/license variants      |
| RAPID FIRE   | OFF / 30HZ / 20HZ / 15HZ / 10HZ |
| SOUND TEST   | BGM/SFX track player            |
| TITLE LOGO   | WHITE / COLOR                   |
| WPN UPGRADE  | ON / OFF (weapon-switch +1 lvl) |

**Stage select** (insert coin(s), hold any button while pressing 1P or 2P Start):

- STAGE / AREA / LOOP — start anywhere, any loop
- MISS CTR (0–2) — pre-loads the game's internal death counter, which reduces the
  impact of post-death temporary difficulty reduction (the game's "rank" variable)
- MAIN WEAPON POWER — Vulcan / Laser / Plasma levels 0–8
- SUB WEAPON POWER — Nuclear / Homing levels 0–4
- ITEM STOCK — BOMBS 0–7, B.TYPE NUKE/CLUSTER (2P side defaults to CLUSTER),
  FAIRY 0–9 (each stocked fairy appears with item drops on one death)
- MULTI WPN — allow multiple main and sub weapons to be equipped simultaneously
  (this row is hidden when MULTI WEAPON is set to OFF in the boot menu)

All settings apply to both players, including a second player joining
mid-game. Deaths and continues revert to stock behavior (reset to vulcan level 1).

## Files

(IPS distribution is deprecated — use the web patcher above, or build from
source as described below.)

To build the patch from scratch, you need:

```
patch_roms.py        the build script (also holds the boot-menu defaults)
stage_select.asm     mod code, primary blob
stage_select2.asm    mod code, second blob
README.md            this file
raiden2j/            folder for ROM files
```

Build prerequisites:

- **Python 3** (3.8 or newer)
- **NASM** (the Netwide Assembler), available on your PATH

## Building

1. Place your own copies of the two Raiden II (Japan) program ROMs into `raiden2j` folder.
   **These files are not provided.** They must match these checksums:

   | File          | Size    | CRC32      | SHA1                                       |
   |---------------|---------|------------|--------------------------------------------|
   | `prg0.u0211`  | 524,288 | `09475ec4` | `05027f2d8f9e11fcbd485659eda68ada286dae32` |
   | `rom2j.u0212` | 524,288 | `e4e4fb4c` | `7ccf33fe9a1cddf0c7e80d7ed66d615a828b3bb9` |

   The build verifies the checksums and refuses to patch anything else.

2. Run:

   ```
   python patch_roms.py
   ```

3. The patched ROMs are written to a `raiden2j-modded` folder:

   ```
   raiden2j-modded/prg0.u0211
   raiden2j-modded/rom2j.u0212
   ```

   Replace the matching files in your Raiden II (Japan) ROM set with these
   (all other files in the set are unchanged). Note that emulators that
   verify ROM checksums will report the two patched files as BAD — that is
   expected for a modified set.  To bypass the check in MAME, specify the
   romset directly from commandline.  For example, "MAME raiden2j".
   If patching a PCB, burn to 2x 27C240 EPROMs and replace the existing ROMs.
   Be aware of Pin 1 alignment and do not insert backwards.

## Web patcher

The browser tool under `web/r2tool/` is the user-facing patcher hosted on the
project site. It is fully client-side: it loads the two ROMs, verifies them by
checksum, applies the same fixed patch this script produces, and overlays the
boot-menu defaults the user picks. To regenerate its data after a code change,
build first and then run the generator:

```
python patch_roms.py        # writes raiden2j-modded/
python make_webtool.py      # writes web/r2tool/r2patch.js from the diff
node web/r2tool/test_webtool.js   # verifies it reproduces raiden2j-modded byte-for-byte
```

`r2patch.js` is auto-generated (the pristine→modded byte-runs plus the defaults
metadata); `r2apply.js` and `index.html` are hand-written.

## Changing the boot-menu defaults

The values the boot menu starts with on every power-on live in the
`BOOT_DEFAULTS` dictionary at the top of `patch_roms.py`:

```python
BOOT_DEFAULTS = {
    "debug_menu":     1,   # 0=OFF 1=ON
    "stage_select":   1,   # 0=OFF 1=ON
    "region":         0,   # 0-21, index into the region list (0 = JAPAN #1)
    "rapid_fire":     0,   # 0=OFF 1=30HZ 2=20HZ 3=15HZ 4=10HZ
    "sound_test":     1,   # default SOUND TEST track (0x00-0x5A)
    "title_logo":     1,   # 0=WHITE 1=COLOR
    "wpn_sw_upgrade": 0,   # 0=OFF 1=ON
    "boot_timeout":   30,  # boot-menu auto-confirm seconds (0-60); 0 = skip menu
    "multi_weapon":   1,   # 0=OFF (MULTI WPN hidden in stage select) 1=ON
}
```

Edit the values and re-run `python patch_roms.py`. The script validates the
ranges and writes the table into the ROM (physical address `B6A20`).

If you only have the patched ROMs (no build tools), the same nine bytes can
be changed in a hex editor — even physical addresses live in `prg0.u0211`
and odd ones in `rom2j.u0212`, both at file offset `phys/2`:

| Setting        | File          | Offset    |
|----------------|---------------|-----------|
| debug_menu     | `prg0.u0211`  | `0x5B510` |
| stage_select   | `rom2j.u0212` | `0x5B510` |
| region         | `prg0.u0211`  | `0x5B511` |
| rapid_fire     | `rom2j.u0212` | `0x5B511` |
| sound_test     | `prg0.u0211`  | `0x5B512` |
| title_logo     | `rom2j.u0212` | `0x5B512` |
| wpn_sw_upgrade | `prg0.u0211`  | `0x5B513` |
| boot_timeout   | `rom2j.u0212` | `0x5B513` |
| multi_weapon   | `prg0.u0211`  | `0x5B514` |

by alamone
twitter: @alamone
web: https://alamone.net/

AI disclosure: Portions of the modification are AI assisted (Claude Code).