#!/usr/bin/env python3
"""
make_webtool.py -- generate web/r2tool/r2patch.js for the browser patcher.

Diffs the pristine ROMs (raiden2j/) against the freshly built modded ROMs
(raiden2j-modded/) into compact per-file byte-runs, and emits them plus the
boot-menu defaults metadata as a JS data file. The browser tool applies the
runs to a user's pristine ROM, then overlays the user-chosen default bytes.

Run patch_roms.py first so raiden2j-modded/ is current, then this.
"""
import os, sys, hashlib, zlib, json, re, importlib.util

ROOT  = os.path.dirname(os.path.abspath(__file__))
PRIS  = os.path.join(ROOT, "raiden2j")
MOD   = os.path.join(ROOT, "raiden2j-modded")
OUT   = os.path.join(ROOT, "web", "r2tool", "r2patch.js")
ASM   = os.path.join(ROOT, "stage_select.asm")

FILES = ["prg0.u0211", "rom2j.u0212"]
EXPECTED_SHA1 = {
    "prg0.u0211":  "05027f2d8f9e11fcbd485659eda68ada286dae32",
    "rom2j.u0212": "7ccf33fe9a1cddf0c7e80d7ed66d615a828b3bb9",
}

def load(d, f):
    p = os.path.join(d, f)
    if not os.path.exists(p):
        sys.exit(f"ERROR: {p} not found (run patch_roms.py first).")
    return bytearray(open(p, "rb").read())

def diff_runs(a, b, merge_gap=8):
    """Contiguous runs where b differs from a; runs separated by <= merge_gap
    unchanged bytes are merged (the gap bytes are identical, so re-writing
    them is harmless and keeps the record count small)."""
    assert len(a) == len(b)
    runs = []
    i, n = 0, len(a)
    while i < n:
        if a[i] == b[i]:
            i += 1
            continue
        start = i
        gap = 0
        end = i
        while i < n:
            if a[i] != b[i]:
                end = i + 1
                gap = 0
            else:
                gap += 1
                if gap > merge_gap:
                    break
            i += 1
        runs.append((start, bytes(b[start:end])))
    return runs

# --- pull the 22 region display names from the ASM, in menu order ----------
def region_names():
    txt = open(ASM, encoding="utf-8").read()
    names = re.findall(r'^bm_rg_[0-9A-Fa-f]+:\s*db\s*"([^"]*)"', txt, re.M)
    if len(names) != 22:
        sys.exit(f"ERROR: expected 22 region names, parsed {len(names)}")
    return names

# --- import BOOT_DEFAULTS from patch_roms.py for the default values --------
def boot_defaults():
    spec = importlib.util.spec_from_file_location("pr", os.path.join(ROOT, "patch_roms.py"))
    # patch_roms.py runs its patch flow at import; guard by stubbing argv and
    # catching its SystemExit if ROMs are missing. Simpler: parse the dict.
    txt = open(os.path.join(ROOT, "patch_roms.py"), encoding="utf-8").read()
    m = re.search(r"BOOT_DEFAULTS\s*=\s*\{(.*?)\}", txt, re.S)
    d = {}
    for k, v in re.findall(r'"(\w+)":\s*(\d+)', m.group(1)):
        d[k] = int(v)
    return d

def main():
    bd = boot_defaults()
    regions = region_names()
    rf_names = ["OFF", "30HZ", "20HZ", "15HZ", "10HZ"]

    data = {"files": {}}
    for f in FILES:
        pris = load(PRIS, f)
        mod  = load(MOD, f)
        sha1 = hashlib.sha1(pris).hexdigest()
        if sha1 != EXPECTED_SHA1[f]:
            sys.exit(f"ERROR: pristine {f} SHA1 mismatch ({sha1})")
        runs = diff_runs(pris, mod)
        data["files"][f] = {
            "size":  len(pris),
            "sha1":  sha1,
            "crc32": format(zlib.crc32(pris) & 0xFFFFFFFF, "08x"),
            "runs":  [[off, b.hex()] for off, b in runs],
        }
        total = sum(len(b) for _, b in runs)
        print(f"  {f}: {len(runs)} runs, {total} patched bytes")

    # Boot-menu defaults: file + byte offset (phys/2) + UI type. Offsets match
    # the README hex-edit table; phys B6A20..B6A28 (even->prg0, odd->rom2j).
    P, R = "prg0.u0211", "rom2j.u0212"
    data["defaults"] = [
        {"key":"debug_menu",     "label":"DEBUG MENU",   "file":P, "off":0x5B510, "type":"onoff", "def":bd["debug_menu"]},
        {"key":"stage_select",   "label":"STAGE SELECT", "file":R, "off":0x5B510, "type":"onoff", "def":bd["stage_select"]},
        {"key":"multi_weapon",   "label":"MULTI WEAPON", "file":P, "off":0x5B514, "type":"onoff", "def":bd["multi_weapon"]},
        {"key":"region",         "label":"REGION",       "file":P, "off":0x5B511, "type":"list",  "def":bd["region"], "options":regions},
        {"key":"rapid_fire",     "label":"RAPID FIRE",   "file":R, "off":0x5B511, "type":"list",  "def":bd["rapid_fire"], "options":rf_names},
        {"key":"sound_test",     "label":"SOUND TEST",   "file":P, "off":0x5B512, "type":"num",   "def":bd["sound_test"], "min":0, "max":0x5A},
        {"key":"title_logo",     "label":"TITLE LOGO",   "file":R, "off":0x5B512, "type":"list",  "def":bd["title_logo"], "options":["WHITE","COLOR"]},
        {"key":"wpn_sw_upgrade", "label":"WPN UPGRADE",  "file":P, "off":0x5B513, "type":"onoff", "def":bd["wpn_sw_upgrade"]},
        # boot_timeout: dropdown of 10-second steps. "def"/values are the BYTE
        # written (seconds), not the option index — optvals maps option->byte.
        {"key":"boot_timeout",   "label":"BOOT TIMEOUT", "file":R, "off":0x5B513, "type":"list",
         "def":bd["boot_timeout"],
         "options":["SKIP", "10 SEC.", "20 SEC.", "30 SEC.", "40 SEC.", "50 SEC.", "60 SEC."],
         "optvals":[0, 10, 20, 30, 40, 50, 60],
         "notewhen":0, "note":"Hold P1 Start at power-on to force the boot menu"},
    ]

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    js = "// AUTO-GENERATED by make_webtool.py — do not edit.\n"
    js += "var R2_PATCH = " + json.dumps(data, separators=(",", ":")) + ";\n"
    js += "if (typeof module !== 'undefined') module.exports = R2_PATCH;\n"
    with open(OUT, "w", encoding="utf-8") as fp:
        fp.write(js)
    print(f"Wrote {OUT} ({os.path.getsize(OUT):,} bytes)")

if __name__ == "__main__":
    main()
