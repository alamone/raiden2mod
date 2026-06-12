#!/usr/bin/env python3
"""
patch_roms.py -- Apply all Raiden 2 patches to prg0.u0211 and rom2j.u0212.
Usage: python3 patch_roms.py [prg0_path] [rom2j_path]
Inputs : raiden2j/prg0.u0211 and raiden2j/rom2j.u0212 (user-supplied,
         verified against known checksums; see README.md)
Outputs: raiden2j-modded/prg0.u0211 and raiden2j-modded/rom2j.u0212
Assembles stage_select.asm and stage_select2.asm with nasm first.

ROM layout:
  prg0.u0211  = even bytes of the physical address space
  rom2j.u0212 = odd bytes of the physical address space
  Physical 0x98000-0xA7FFF = segment 9800h (main code)
  Physical 0xB5000-0xBFFFF = segment B000h (our trampoline/vector area)
  Physical 0xB6920+        = segment B692h (stage_select.bin)
"""

import sys, subprocess, os, hashlib

# Pristine Raiden II (Japan) program ROM checksums — the dumps every
# patch site in this script is verified against (see README.md).
EXPECTED_SHA256 = {
    'prg0.u0211':  '90bb05525c1529b97c359deb47305e8e25ee9de8d7c951b0be0b5587c89354ec',
    'rom2j.u0212': '2a3d999822e85400237efbcaac88569e5a6bd809e07899c39e673cfa81be37ed',
}

# ════════════════════════════════════════════════════════════════════
# BOOT MENU DEFAULTS — edit these to change what the boot menu starts
# with on every power-on. Written into the ROM's defaults table at
# phys B6A20 (B692:0100) and verified after patching.
#
# If you only have a patched ROM set (no build tools), the same bytes
# can be hex-edited directly: even phys bytes live in prg0.u0211 and
# odd ones in rom2j.u0212, both at file offset phys/2 — see the table
# comment in stage_select.asm for the per-setting file offsets.
# ════════════════════════════════════════════════════════════════════
BOOT_DEFAULTS = {
    "debug_menu":     1,   # 0=OFF 1=ON
    "stage_select":   1,   # 0=OFF 1=ON
    "region":         0,   # index into the region list (0 = first entry)
    "rapid_fire":     0,   # 0=OFF 1=30HZ 2=20HZ 3=15HZ 4=10HZ
    "sound_test":     1,   # default SOUND TEST track (0x00-0x5A)
    "title_logo":     1,   # 0=WHITE 1=COLOR
    "wpn_sw_upgrade": 0,   # 0=OFF 1=ON (switch pickups gain +1 level)
}
assert BOOT_DEFAULTS["debug_menu"]     in (0, 1)
assert BOOT_DEFAULTS["stage_select"]   in (0, 1)
assert 0 <= BOOT_DEFAULTS["region"]     <= 21  # 22 entries; see README.md
assert 0 <= BOOT_DEFAULTS["rapid_fire"] <= 4
assert 0 <= BOOT_DEFAULTS["sound_test"] <= 0x5A
assert BOOT_DEFAULTS["title_logo"]     in (0, 1)
assert BOOT_DEFAULTS["wpn_sw_upgrade"] in (0, 1)
BOOT_DEFAULTS_BYTES = [BOOT_DEFAULTS[k] for k in (
    "debug_menu", "stage_select", "region", "rapid_fire",
    "sound_test", "title_logo", "wpn_sw_upgrade")]

prg0_path  = sys.argv[1] if len(sys.argv) > 1 else os.path.join('raiden2j', 'prg0.u0211')
rom2j_path = sys.argv[2] if len(sys.argv) > 2 else os.path.join('raiden2j', 'rom2j.u0212')

for path, name in ((prg0_path, 'prg0.u0211'), (rom2j_path, 'rom2j.u0212')):
    if not os.path.exists(path):
        print(f"ERROR: {path} not found.")
        print(f"Place your own '{name}' from the Raiden II (Japan) ROM set in")
        print("the 'raiden2j' folder - see README.md.")
        sys.exit(1)

with open(prg0_path,  'rb') as f: prg0  = bytearray(f.read())
with open(rom2j_path, 'rb') as f: rom2j = bytearray(f.read())
print(f"Loaded {prg0_path}: {len(prg0):,} bytes")
print(f"Loaded {rom2j_path}: {len(rom2j):,} bytes")

for data, name in ((prg0, 'prg0.u0211'), (rom2j, 'rom2j.u0212')):
    got = hashlib.sha256(data).hexdigest()
    if got != EXPECTED_SHA256[name]:
        print(f"ERROR: {name} checksum mismatch - this is not the dump the")
        print("patches were verified against (or it is already patched).")
        print(f"  expected SHA256: {EXPECTED_SHA256[name]}")
        print(f"  got      SHA256: {got}")
        sys.exit(1)
print("ROM checksums OK.")

def write_combined(data, phys_start):
    for i, b in enumerate(data):
        addr = phys_start + i
        if addr % 2 == 0: prg0[addr // 2]  = b
        else:              rom2j[addr // 2] = b

def read_combined(phys_addr, length=8):
    out = []
    for i in range(length):
        addr = phys_addr + i
        out.append(prg0[addr//2] if addr%2==0 else rom2j[addr//2])
    return bytes(out)

def patch(name, phys, data):
    write_combined(data, phys)
    print(f"  PATCH {phys:#07x}  {name}")

# Assemble stage_select.asm
print("\nAssembling stage_select.asm ...")
r = subprocess.run(['nasm', 'stage_select.asm', '-o', 'stage_select.bin'],
                   capture_output=True, text=True)
if r.returncode != 0:
    print("NASM FAILED:"); print(r.stdout); print(r.stderr); sys.exit(1)
with open('stage_select.bin', 'rb') as f: ss_bytes = f.read()
print(f"  stage_select.bin: {len(ss_bytes)} bytes")

# HARD BUDGET: the primary blob's free-fill region (zeros in the pristine
# ROM) is B6912-B8102; from our B6920 base that is 0x17E2 = 6114 bytes.
# The game's STRING TABLES ("PUSH", "1 OR 2 PLAYER BUTTON", ...) follow —
# overrunning corrupted the credited-title text (caught 2026-06-11 after
# the blob had silently crept past the boundary). NEVER raise this limit;
# grow stage_select2.asm (or find a third region) instead.
SS_LIMIT = 0xB8102 - 0xB6920
assert len(ss_bytes) <= SS_LIMIT,     f"stage_select.bin {len(ss_bytes)} exceeds budget {SS_LIMIT}"
print(f"  budget: {len(ss_bytes)}/{SS_LIMIT} (headroom {SS_LIMIT - len(ss_bytes)})")

print("\nAssembling stage_select2.asm ...")
r = subprocess.run(['nasm', 'stage_select2.asm', '-o', 'stage_select2.bin'],
                   capture_output=True, text=True)
if r.returncode != 0:
    print("NASM FAILED:"); print(r.stdout); print(r.stderr); sys.exit(1)
with open('stage_select2.bin', 'rb') as f: ss2_bytes = f.read()
# Second blob: zero-fill run B5804-B5F03, paragraph-aligned base B5810
# (segment B581) -> 0x6F3 = 1779 bytes available.
SS2_LIMIT = 0xB5F03 - 0xB5810
assert len(ss2_bytes) <= SS2_LIMIT,     f"stage_select2.bin {len(ss2_bytes)} exceeds budget {SS2_LIMIT}"
print(f"  stage_select2.bin: {len(ss2_bytes)} bytes "
      f"(budget {len(ss2_bytes)}/{SS2_LIMIT})")
assert read_combined(0xB5810, len(ss2_bytes)) == bytes(len(ss2_bytes)), \
    "B5810 region not pristine zero fill"

print("\nPatching...")

# ── Region override ────────────────────────────────────────────────────────────
# Original code reads a hardcoded region byte from ROM.
# Redirect to read from scratch RAM [BF0E] (REGION_VAR) instead,
# so the boot menu can set it at runtime.
#
# 9843D:
#   mov  al, [0BF0Eh]    ; A0 0E BF  (was: mov al, [0FFFFBh])
#   nop                  ; 90
patch("9843D: region read [0FFFFBh] -> [BF0Eh]",
      0x9843D, [0xA0, 0x0E, 0xBF, 0x90])




# ── 9A484: vblank-wait + debug-hold (rewritten in place) ─────────────────────
# Original 12-byte function:
#   9A484: A1 5A 9F      mov  ax,[9F5A]
#   9A487: 3B 06 5A 9F   cmp  ax,[9F5A]
#   9A48B: 75 02 / EB F8 jnz +2 / jmp -8   (spin until [9F5A] changes)
#   9A48F: C3            ret
# Rewritten so the first instruction far-calls vblank_dbg_impl (B692:0030),
# which contains the relocated debug-hold logic (old 9A62E relay — that relay
# sat INSIDE the checkpoint table and destroyed stage 1/2 data) and returns
# AX=[9F5A]. Spin semantics are identical.
#   9A484: 9A 30 00 92 B6   call far B692:0030
#   9A489: 3B 06 5A 9F      cmp  ax,[9F5A]
#   9A48D: 74 FA            je   9A489
#   9A48F: C3               ret
patch("9A484: CALL FAR B692:0030 + spin (debug-hold relocated out of table)",
      0x9A484, [0x9A, 0x30, 0x00, 0x92, 0xB6,
                0x3B, 0x06, 0x5A, 0x9F,
                0x74, 0xFA,
                0xC3])


# ── 9819C: per-frame ISR hook (reconstruction + title-logo forcing) ───────────
# Replaces CMP byte [9F62],0 (5 bytes) at the top of the vblank ISR with a far
# call. isr_rf_impl fires once per frame in ALL states: it forces the chosen
# TITLE LOGO palette (state-00, no-players gated) and re-executes the absorbed
# CMP so the JNZ at 981A1 sees correct flags. (The rapid-fire tick used to
# live here; firing in all states leaked autofire into the high-score name
# entry and continue countdown — moved to the 9ADBC gameplay-loop hook.)
patch("9819C: CALL FAR B692:0040 (ISR hook: logo forcing; absorbed CMP reconstructed)",
      0x9819C, [0x9A, 0x40, 0x00, 0x92, 0xB6])

# ── 9F8C1/9F8F5: bullet budget — keep full capacity with multi-weapon ─────────
# Inside the difficulty recalc 7888, the stock code does SUB [AC66],38h per
# player whose plasma level != 0 ([AC66] = master bullet-slot budget, 0xAA =
# the bullet array's designed capacity; copied to the live allocator limit
# [AC68]; allocator A270:BCA5 fails silently when the count [AC6A] hits it).
# Sane in stock play (plasma excludes other mains), but with MULTI_WPN the
# same player also fires vulcan+laser — the cut starved the pool and dropped
# shots at 30Hz autofire. multi_pool_impl performs the SUB only when
# MULTI_WPN is off.
patch("9F8C1: CALL FAR B692:0088 (P1 plasma budget cut, skipped in multi)",
      0x9F8C1, [0x9A, 0x88, 0x00, 0x92, 0xB6])
patch("9F8F5: CALL FAR B692:0088 (P2 plasma budget cut, skipped in multi)",
      0x9F8F5, [0x9A, 0x88, 0x00, 0x92, 0xB6])

# ── Bullet pool extension (multi-weapon capacity 170 -> 287) ──────────────────
# The shared bullet pool (seg 1000, slots 0C00-5660, stride 70h, free-list
# allocator A270:BCA5) physically holds 170 slots — saturated by multi-weapon
# at 30Hz (vulcan spread visibly narrows). RAM 1000:B440-E7D0 verified unused
# under worst-case fire; 117 extra slots are chained in. Raised budget applies
# only when MULTI_WPN is on; stock games keep the original 0AAh cap and never
# touch the extension slots.

# 9800:8F15 / 8F33 (phys A0F15/A0F33): the 11-byte queue-push tails of both
# sound-command senders. sfx_dedupe_impl skips commands identical to one
# already pending in the 40-entry Z80 queue at B0E0 (which silently DROPS on
# overflow — the cause of audio glitching under heavy combat), else performs
# the stock A24A push via the SP4 gadget.
patch("A0F15: CALL FAR B692:00B0 + 6 NOPs (sound queue dedupe, main sender)",
      0xA0F15, [0x9A, 0xB0, 0x00, 0x92, 0xB6] + [0x90]*6)
patch("A0F33: CALL FAR B692:00B0 + 6 NOPs (sound queue dedupe, ISR sender)",
      0xA0F33, [0x9A, 0xB0, 0x00, 0x92, 0xB6] + [0x90]*6)

# A270:BCA5 (phys AE3A5): the allocator's cap check (MOV BX,[AC6A] /
# CMP BX,[AC68], 8 bytes). pool_prio_impl applies a type-aware reserve:
# the vulcan stream (type 0C, measured 100+ slots at lvl8+30Hz) is refused
# 24 slots below the cap so homing (type 19), laser and enemy fire never
# starve. Flags returned to the JC at BCAD; RETF preserves them.
patch("AE3A5: CALL FAR B692:00A8 + 3 NOPs (bullet allocator vulcan reserve)",
      0xAE3A5, [0x9A, 0xA8, 0x00, 0x92, 0xB6] + [0x90]*3)

# Sub-weapon volley edge-abort neutralizer. The nuclear/homing volley
# scripts TEST the owner's input-flags word [BP+58] bits 2/3 (fire press
# EDGES) before every missile pair and at every delay step, aborting the
# volley so a fresh press can restart it (stock mash-to-re-time). Rapid
# fire synthesizes an edge every 2-6 frames (B142 latch clear), so with
# RF at ANY rate sub-volleys aborted forever: 10s of held fire = 11 nukes
# RF-off vs 0 nukes at 10/15/30Hz (bot-measured). sub_edge_impl reports
# "no edge" while RF is enabled, original TEST when RF is off.
# Original bytes at all four sites: F7 46 58 0C 00 (TEST [BP+58],000Ch).
for _name, _phys in (("A270:895E nuke pair gate A", 0xAB05E),
                     ("A270:8992 nuke pair gate B", 0xAB092),
                     ("A270:8E52 volley delay step A", 0xAB552),
                     ("A270:8F3C volley delay step B", 0xAB63C)):
    assert read_combined(_phys, 5) == bytes([0xF7, 0x46, 0x58, 0x0C, 0x00]), _name
    patch(f"{_phys:05X}: CALL FAR B692:00B8 ({_name})",
          _phys, [0x9A, 0xB8, 0x00, 0x92, 0xB6])

# Main-weapon pool reserve, fire dispatcher A270:7C48. ALL player shot
# objects allocate from seg-0 pool 2 (P1) / pool 3 (P2), 36 slots each;
# the spawner silently fails when full. At 30Hz vulcan8+laser8 peg pool 2
# at 36/36 (bot-measured ~20 vulcan + ~15 laser objects) and nuke/homing
# spawns lose every race (10/10s vs 98-136 with one main absent) — the
# "mains block sub-weapons" bug. main_*_impl hooks the three main-weapon
# dispatch headers (MOV SI,[DI+6/8/A] / TEST SI,SI): in multi mode with a
# sub equipped, a main's dispatch is skipped while its player's pool has
# fewer than 10 free slots. The following JZ consumes our ZF.
for _name, _phys, _vec, _off in (("vulcan pool reserve", 0xAA348, 0xD8, 0x06),
                                 ("laser pool reserve",  0xAA366, 0xE0, 0x08),
                                 ("plasma pool reserve", 0xAA384, 0xE8, 0x0A)):
    assert read_combined(_phys, 5) == bytes([0x8B, 0x75, _off, 0x85, 0xF6]), _name
    patch(f"{_phys:05X}: CALL FAR B692:00{_vec:02X} ({_name})",
          _phys, [0x9A, _vec, 0x00, 0x92, 0xB6])

# Powerup pickup behaviour (A270:6247 mains / 62C7 subs; found via demo
# write-tap). The "different weapon" path zeroes the other weapon levels
# and transfers the carried level unchanged. pickup_main/sub_impl replace
# the 23-byte zero+store tails: stock mode is reconstructed byte-identical
# (the attract demo picks items — determinism required); MULTI_WPN=1 skips
# the zeroing (picked weapon starts at 1, others keep their levels);
# WSU_VAR=1 (boot menu WEAPON SWITCH UPGRADE) adds +1 to the transferred
# level (cap 8/4; first-ever sub still starts at 1).
for _name, _phys, _vec in (("main pickup", 0xA8979, 0xF0),
                           ("sub pickup",  0xA89FC, 0xF8)):
    patch(f"{_phys:05X}: CALL FAR B692:00{_vec:02X} + 18 NOPs ({_name})",
          _phys, [0x9A, _vec, 0x00, 0x92, 0xB6] + [0x90] * 18)

# Held-autofire threshold, A270:79CB (phys A99CB). The engine fires the
# weapon dispatcher every 30 consecutively-held frames (CMP [DI+34],1Eh).
# rf_held_impl swaps the threshold for the RF reload-1 while RF is on:
# real autofire through the engine's own held cadence, no fake edges.
# (Press edges suppress nuclear/homing volleys even in pure stock play —
# bot: 10s hold = 6-11 nukes, mash at any speed = 0 — which was the whole
# multi-weapon "sub-weapon priority" bug: the old RF latch-clear turned a
# held button into a permanent mash.) Original 10 bytes:
# 83 7D 34 1E / 7D 0A / FF 45 34 / C3.
assert read_combined(0xA99CB, 10) == bytes(
    [0x83, 0x7D, 0x34, 0x1E, 0x7D, 0x0A, 0xFF, 0x45, 0x34, 0xC3])
patch("A99CB: CALL FAR B692:00D0 + JNL .fire + RET (RF held-autofire threshold)",
      0xA99CB, [0x9A, 0xD0, 0x00, 0x92, 0xB6, 0x7D, 0x09, 0xC3, 0x90, 0x90])

# Fire dispatcher A270:7C48 walks the weapon slots per trigger; rapid fire
# triggers it every 2-6 frames via faked press edges, and re-triggering a
# sub-weapon launcher mid-volley kills its attached newborn missiles (bot:
# 244 nuke allocs / 219 instant frees per 10s at 30Hz, zero survivors).
# Hook the NUCLEAR ([DI+0E], A270:7CA2) and HOMING ([DI+10], A270:7CB8)
# dispatch headers (MOV SI,[DI+x] / TEST SI,SI): while RF is on, pass a
# sub-weapon dispatch only every 30 frames (stock held-fire cadence) per
# player+weapon; mains keep full RF speed. The original JZ consumes ZF.
for _name, _phys, _vec, _orig in (
        ("nuclear dispatch gate", 0xAA3A2, 0xC0, bytes([0x8B,0x75,0x0E,0x85,0xF6])),
        ("homing dispatch gate",  0xAA3B8, 0xC8, bytes([0x8B,0x75,0x10,0x85,0xF6]))):
    assert read_combined(_phys, 5) == _orig, _name
    patch(f"{_phys:05X}: CALL FAR B692:00{_vec:02X} ({_name})",
          _phys, [0x9A, _vec, 0x00, 0x92, 0xB6])

# A270:F786 (phys B1E86): chain terminator MOV [ES:DI+44],0 inside builder
# F74D — pool_ext_impl appends+zeroes the extension chain for pool 5 (all
# rebuild callers covered), reconstructs the terminator for other pools.
patch("B1E86: CALL FAR B692:0090 + NOP (bullet pool chain extension)",
      0xB1E86, [0x9A, 0x90, 0x00, 0x92, 0xB6, 0x90])

# 9F888: MOV [AC66],0AAh at recalc head — pool_cap_impl writes 11Fh instead
# when MULTI_WPN is on (recalc reasserts every 32 ticks = single authority).
patch("9F888: CALL FAR B692:0098 + NOP (bullet budget 11Fh in multi mode)",
      0x9F888, [0x9A, 0x98, 0x00, 0x92, 0xB6, 0x90])

# 9B62A: MOV SI,0C00/BX,70/CX,0AAh (9 bytes) — setup for the bullet
# repositioner 368C (scroll-delta add). walk_ext_impl runs the extension pass
# and reconstructs the stock setup for the original CALL at 9B633.
patch("9B62A: CALL FAR B692:00A0 + 4 NOPs (bullet repositioner extension pass)",
      0x9B62A, [0x9A, 0xA0, 0x00, 0x92, 0xB6] + [0x90]*4)

# ── 9ADBC: rapid-fire tick (gameplay frame-update section only) ───────────────
# Replaces TEST word [A010],1Fh (6 bytes) in the gameplay loop. This section
# is skipped (loop-top short-circuit to AE92) during continue/game-over/name
# entry and never runs in menus/intro/demo — so autofire edges stay strictly
# in-game. rf_loop_impl ticks rapid fire then reconstructs the absorbed TEST
# (flags feed the JNZ at 9ADC2).
patch("9ADBC: CALL FAR B692:0080 + NOP (rapid fire in gameplay loop; TEST reconstructed)",
      0x9ADBC, [0x9A, 0x80, 0x00, 0x92, 0xB6, 0x90])

# ── 9BF9B: brightness restore (relocated out of the checkpoint table) ─────────
# Replaces CALL 9C08E + TEST AX,AX (5 bytes) in the debug menu loop with a far
# call. bright_impl sets [061C]=0 (inlined A16FD(0)), thunk-calls 9C08E via the
# RETF gadget at 9800:7FFE, then re-executes TEST AX,AX for the JE at 9BFA0.
patch("9BF9B: CALL FAR B692:0048 (brightness relay relocated; TEST AX,AX reconstructed)",
      0x9BF9B, [0x9A, 0x48, 0x00, 0x92, 0xB6])

# ── 9A9E8: stage-select BGM trigger (restored, BGM-only) ──────────────────────
# carrier_spawn (B692:0010) fires the Stage 1B BGM (track 0x0C) once per stage
# init — inside 9A8C9, after the 0x82FF sound reset at 9A8D2 (verified
# ordering) — then reconstructs the absorbed CMP [9F76],4 for the JB at 9A9ED.
# The synthetic carrier spawn formerly here is gone; carriers now come from
# the stock checkpoint path (9AA88 + area_ckpt_impl).
patch("9A9E8: CALL FAR B692:0010 (BGM trigger; absorbed CMP reconstructed)",
      0x9A9E8, [0x9A, 0x10, 0x00, 0x92, 0xB6])

# ── 9AADD: area-select injection at the restart-position read ─────────────────
# Replaces PUSH [A00E] / PUSH [9F5E] / CALL 9AA3A / ADD SP,4 (14 bytes) inside
# the stock checkpoint-restart routine 9AA88. area_ckpt_impl (B692:0058)
# reimplements 9AA3A exactly (returns AX=checkpoint pos, BX=carrier id) and
# substitutes AREA_POS for the [A00E] snapshot when armed, consuming it there.
# This is immune to the [A00E] tracker at 9B8DA (called from 9AEF6 just
# before 9AA88) and to all hook-ordering races.
patch("9AADD: CALL FAR B692:0058 + 9 NOPs (area-select at 9AA3A read site)",
      0x9AADD, [0x9A, 0x58, 0x00, 0x92, 0xB6] + [0x90]*9)

# ── Boot menu gate ─────────────────────────────────────────────────────────────
# Called every non-gameplay frame. If BOOT_DONE flag is not set, shows the
# boot menu (debug toggle, stage select, rapid fire rate, region select).
#
# 9889E:
#   call far B692h:0018h      ; 9A 18 00 92 B6  (vec_boot_menu)
#   nop                       ; 90
patch("9889E: CALL FAR B692:0018 + NOP (boot menu gate)",
      0x9889E, [0x9A, 0x18, 0x00, 0x92, 0xB6, 0x90])

# ── Stage select entry ─────────────────────────────────────────────────────────
# 9AD50:
#   call far B692h:0000h      ; 9A 00 00 92 B6  (vec_stage_select)
#   nop                       ; 90
patch("9AD50: CALL FAR B692:0000 + NOP (stage select entry)",
      0x9AD50, [0x9A, 0x00, 0x00, 0x92, 0xB6, 0x90])

# ── 9A8E6: preserve loop selection across stage init ──────────────────────────
# Original: A3 60 9F = MOV [9F60],AX (AX=0) — zeroes LOOP_VAR at stage start.
# NOP it so the boot-menu loop selection survives.
# (Was patched at 9A8E7 — an off-by-one that NOPed MID-instruction, creating a
# stray MOV [9090],AX, a NEC REPNC-prefixed LAHF clobbering AH, and garbage in
# [9F8E]. Corrected to 9A8E6.)
patch("9A8E6: NOP x3 (preserve LOOP_VAR; fixes prior off-by-one at 9A8E7)",
      0x9A8E6, [0x90, 0x90, 0x90])

# ── Carrier/CK override hooks ──────────────────────────────────────────────────
# 9AC35:
#   call far B692h:0008h      ; 9A 08 00 92 B6  (vec_ck_override)
#   nop                       ; 90
patch("9AC35: CALL FAR B692:0008 + NOP (ck_override)",
      0x9AC35, [0x9A, 0x08, 0x00, 0x92, 0xB6, 0x90])

# 9AC3B: replace MOV [BX+0E],AX / MOV [BX+10],AX / MOV [BX+12],AX (9 bytes)
#   call far B692h:0028h      ; 9A 28 00 92 B6  (vec_weapon_init)
#   nop * 4                   ; 90 90 90 90
# Returns to 9AC44: MOV [BX+14],AX which continues normally.
patch("9AC3B: CALL FAR B692:0028 + 4 NOPs (vec_weapon_init for nuclear/homing)",
      0x9AC3B, [0x9A, 0x28, 0x00, 0x92, 0xB6, 0x90, 0x90, 0x90, 0x90])

# ── AREA SELECT v6: single-init — 9A8C9 loads directly at AREA_POS ────────────
# v5 loaded at 0 then re-ran the stock restart 9AA88 on top: correct but
# ~0.55 s slower than a plain restart (second sound-reset handshake, duplicate
# entity resets). v6 substitutes the position into 9A8C9's own calls,
# mirroring 9AA88's recipe with the real functions and real arg patterns.
# Unarmed (AREA_POS=0) every hook degenerates to byte-identical stock flow.

# 9A973: PUSH 0 / PUSH 0 / PUSH 30h (6 bytes) — first three args of
# F594(row, 30h, pos, 0). spawn_args_impl re-pushes them with AREA_POS in the
# pos slot (pop-return/push-args/far-jmp-back) and performs 9AA88's
# [9D58]=pos write (AAEB) when armed.
patch("9A973: CALL FAR B692:0068 + NOP (F594 position arg + [9D58] write)",
      0x9A973, [0x9A, 0x68, 0x00, 0x92, 0xB6, 0x90])

# 9A988: CALL FAR A270:02C6 (5 bytes). scroll_init_impl first calls the real
# scroll transition 9B5DE(AREA_POS, 0) — 9AA88's AB05 call — via the
# ADD SP,4/RETF gadget at 9800:5820, then performs the 2C6 call itself with a
# re-pushed [9F5A] arg (the caller's copy sits below our far-return frame;
# the caller still cleans its own at 9A98D).
patch("9A988: CALL FAR B692:0070 (9B5DE scroll init + relayed A270:02C6)",
      0x9A988, [0x9A, 0x70, 0x00, 0x92, 0xB6])

# 9A9CB: PUSH 0 / PUSH [bp+4] (5 bytes) — the args of EF6C(stage, pos), where
# the hard-coded PUSH 0 was the literal source of the [83A]=0 bug.
# loader_args_impl re-pushes (stage from the live BP frame, pos=AREA_POS).
patch("9A9CB: CALL FAR B692:0078 (EF6C position arg substitution)",
      0x9A9CB, [0x9A, 0x78, 0x00, 0x92, 0xB6])

# 9A9F5: MOV [9F4E],2 (6 bytes) — start of 9A8C9's presentation tail. When
# armed, area_start_impl spawns the only 9AA88 pieces with no 9A8C9
# counterpart — the item carrier (F4BF, Y=pos+160h) and the restart entity
# seed F594(1Ah,0,pos,0Bh) — using area_ckpt_impl for the carrier-id lookup
# (which also consumes AREA_POS). Reconstructs the MOV either way.
patch("9A9F5: CALL FAR B692:0060 + NOP (carrier spawn + AREA_POS consume)",
      0x9A9F5, [0x9A, 0x60, 0x00, 0x92, 0xB6, 0x90])

# 9AE70: CMP [A012],0x00 (5 bytes) — replaced with CALL FAR B692:0038
# (spawn_y_apply_impl, now a pure reconstruction; the area-select trigger
# lives at 9A9F5). 9AE75: JNZ 9AE8B uses the flags from the reconstructed
# CMP. ✓
patch("9AE70: CALL FAR B692:0038 (pure reconstruction of CMP [A012],0)",
      0x9AE70, [0x9A, 0x38, 0x00, 0x92, 0xB6])



# ── 9BC04: NOT patched (original RETF 6 must remain) ──────────────────────────
# 9800:3C04 is the release build's no-op error logger (RETF 6). All object
# spawn-overflow paths far-call it with 3 pushed words (e.g. F594's pool-full
# branch at A270:F5DB, F448's bad-type paths). An old mod-era patch turned it
# into JMP 9BD54 ("debug menu entry") — meaning any pool overflow would hijack
# the game into the debug menu loop with a mismatched stack. Nothing calls
# 3C04 for debug entry anymore (B5510 -> B692:0050 -> 9800:3D54 direct), so
# the stock RETF 6 stays.


# ── Debug menu exit: prevent title screen reset ────────────────────────────────
# Original bytes at 9BF66: 6A 00 E8 92 57 83 C4 02
# (PUSH 0 / CALL 9F6FD / ADD SP,2 -- called a function that reset game state
# to attract/title on every debug menu exit, even during active gameplay.)
#
# 9BF66:
#   nop * 8                   ; 90 * 8
patch("9BF66: NOP x8 (prevent title reset on debug menu exit)",
      0x9BF66, [0x90] * 8)

# ── Debug trampoline entry redirect ───────────────────────────────────────────
# The gameplay state dispatcher calls 98F0D every frame. Redirect to our
# trampoline at B000:5510 which checks the P2 START hold counter and
# enters the debug menu when it reaches 60 frames, otherwise reconstructs
# the original 98F0D prologue and continues normally.
#
# 98F0D:
#   jmp far B000h:5510h       ; EA 10 55 00 B0
patch("98F0D: JMP FAR B000:5510 (redirect to debug trampoline)",
      0x98F0D, [0xEA, 0x10, 0x55, 0x00, 0xB0])

# ── Debug trampoline at B000:5510 ─────────────────────────────────────────────
# Runs every frame from the gameplay dispatcher (via 98F0D redirect).
# Detects P2 START hold via [074Ch] bit 1 (active low, 0 = held).
# Increments [BF14] (DBG_HOLD) each frame held; resets on release.
# At 60 frames: clears inputs, sets RF_SUPPRESS, calls debug stub via
# CALL FAR B692:0050 (dbg_menu_far), release-waits, clears RF_SUPPRESS.
# Always reconstructs original 98F0D prologue and JMPs to 9800:0F13.
#
# B5510:
#   test  byte [074Ch], 02h   ; F6 06 4C 07 02  - P2 START held? (active low, bit 1)
#   jnz   not_pressed         ; 75 47           - not held -> reset counters
#   inc   word [BF14h]        ; FF 06 14 BF     - increment hold counter
#   cmp   word [BF14h], 3Ch   ; 83 3E 14 BF 3C  - 60 frames (~1 sec at 60Hz)?
#   jb    skip                ; 72 31           - not yet -> continue normally
#   mov   word [BF14h], 0     ; C7 06 14 BF 00 00  - reset hold counter
#   mov   word [BF16h], 0     ; C7 06 16 BF 00 00  - clear RF_SUPPRESS (safety)
#   mov   word [9DC0h], 0     ; C7 06 C0 9D 00 00  - clear P1 inputs
#   mov   word [9DC2h], 0     ; C7 06 C2 9D 00 00  - clear P2 inputs
#   mov   word [BF16h], 1     ; C7 06 16 BF 01 00  - RF_SUPPRESS = 1
#   call far 9800h:2605h      ; 9A 05 26 00 98     - debug stub (-> 9BD54)
#   .wait:
#   test  word [9DC0h], 8000h ; F7 06 C0 9D 00 80  - wait for P2 START release
#   jnz   .wait               ; 75 F8
#   mov   word [BF16h], 0     ; C7 06 16 BF 00 00  - RF_SUPPRESS = 0
#   .skip:
#   push  bp                  ; 55              \
#   mov   bp, sp              ; 8B EC            | reconstruct original
#   sub   sp, 8               ; 83 EC 08         | 98F0D prologue
#   jmp far 9800h:0F13h       ; EA 13 0F 00 98  / continue 98F0D body
#   .not_pressed:
#   mov   word [BF14h], 0     ; C7 06 14 BF 00 00  - reset hold counter
#   mov   word [BF16h], 0     ; C7 06 16 BF 00 00  - clear RF_SUPPRESS
#   jmp   skip                ; EB E7
b5510 = bytes([
    0xF6, 0x06, 0x4C, 0x07, 0x02,
    0x75, 0x47,
    0xFF, 0x06, 0x14, 0xBF,
    0x83, 0x3E, 0x14, 0xBF, 0x3C,
    0x72, 0x31,
    0xC7, 0x06, 0x14, 0xBF, 0x00, 0x00,
    0xC7, 0x06, 0x16, 0xBF, 0x00, 0x00,
    0xC7, 0x06, 0xC0, 0x9D, 0x00, 0x00,
    0xC7, 0x06, 0xC2, 0x9D, 0x00, 0x00,
    0xC7, 0x06, 0x16, 0xBF, 0x01, 0x00,
    0x9A, 0x50, 0x00, 0x92, 0xB6,
    0xF7, 0x06, 0xC0, 0x9D, 0x00, 0x80,
    0x75, 0xF8,
    0xC7, 0x06, 0x16, 0xBF, 0x00, 0x00,
    0x55, 0x8B, 0xEC, 0x83, 0xEC, 0x08,
    0xEA, 0x13, 0x0F, 0x00, 0x98,
    0xC7, 0x06, 0x14, 0xBF, 0x00, 0x00,
    0xC7, 0x06, 0x16, 0xBF, 0x00, 0x00,
    0xEB, 0xE7,
])
patch(f"B5510: debug trampoline ({len(b5510)} bytes)", 0xB5510, b5510)

# ── B692 segment: stage_select.bin ────────────────────────────────────────────
# The B692 segment holds the fixed vector table and all custom handler code:
#   B692:0000  vec_stage_select
#   B692:0008  vec_ck_override
#   B692:0010  vec_carrier_spawn
#   B692:0018  vec_boot_menu
#   B692:0020  vec_rapid_fire  ->  rapid_fire_tick
# Scratch RAM (zeroed at boot): BF00-BFFF
#   BF00 DIGIT_RAM   BF02 AREA_VAR   BF04 AREA_POS   BF06 PROG_VAR
#   BF08 BOOT_DONE   BF0A DEBUG_EN   BF0C STSEL_EN    BF0E REGION_VAR
#   BF10 RF_RATE     BF12 RF_CTR     BF14 DBG_HOLD    BF16 RF_SUPPRESS
patch(f"B6920: stage_select.bin ({len(ss_bytes)} bytes)", 0xB6920, list(ss_bytes))
patch(f"B5810: stage_select2.bin ({len(ss2_bytes)} bytes)", 0xB5810, list(ss2_bytes))
patch("B6A20: boot menu defaults (from BOOT_DEFAULTS dict)",
      0xB6A20, BOOT_DEFAULTS_BYTES)

# ── Write output files ─────────────────────────────────────────────────────────
out_dir = 'raiden2j-modded'
os.makedirs(out_dir, exist_ok=True)
out_prg0  = os.path.join(out_dir, 'prg0.u0211')
out_rom2j = os.path.join(out_dir, 'rom2j.u0212')
with open(out_prg0,  'wb') as f: f.write(prg0)
with open(out_rom2j, 'wb') as f: f.write(rom2j)
print(f"\nOutput: {out_prg0}")
print(f"Output: {out_rom2j}")

# ── Verification ───────────────────────────────────────────────────────────────
print("\nVerification:")
checks = [
    ("9843D region",  0x9843D, [0xA0, 0x0E, 0xBF, 0x90]),
    ("9A484 rewrite", 0x9A484, [0x9A, 0x30, 0x00, 0x92, 0xB6, 0x3B, 0x06, 0x5A, 0x9F, 0x74, 0xFA, 0xC3]),
    ("9889E boot",    0x9889E, [0x9A, 0x18, 0x00, 0x92, 0xB6, 0x90]),
    ("9A9E8 bgm",     0x9A9E8, [0x9A, 0x10, 0x00, 0x92, 0xB6]),
    ("9AADD area",    0x9AADD, [0x9A, 0x58, 0x00, 0x92, 0xB6] + [0x90]*9),
    ("9A973 args",    0x9A973, [0x9A, 0x68, 0x00, 0x92, 0xB6, 0x90]),
    ("9A988 scroll",  0x9A988, [0x9A, 0x70, 0x00, 0x92, 0xB6]),
    ("9A9CB loader",  0x9A9CB, [0x9A, 0x78, 0x00, 0x92, 0xB6]),
    ("9A9F5 start",   0x9A9F5, [0x9A, 0x60, 0x00, 0x92, 0xB6, 0x90]),
    ("9D820 gadget",  0x9D820, [0x83, 0xC4, 0x04, 0xCB]),  # unpatched ROM, must survive
    ("9FFFE gadget",  0x9FFFE, [0xCB]),                    # unpatched ROM, must survive
    ("9819C isr_rf",  0x9819C, [0x9A, 0x40, 0x00, 0x92, 0xB6]),
    ("9ADBC rf_loop", 0x9ADBC, [0x9A, 0x80, 0x00, 0x92, 0xB6, 0x90]),
    ("9F8C1 pool",    0x9F8C1, [0x9A, 0x88, 0x00, 0x92, 0xB6]),
    ("9F8F5 pool",    0x9F8F5, [0x9A, 0x88, 0x00, 0x92, 0xB6]),
    ("B1E86 ext",     0xB1E86, [0x9A, 0x90, 0x00, 0x92, 0xB6, 0x90]),
    ("AE3A5 prio",    0xAE3A5, [0x9A, 0xA8, 0x00, 0x92, 0xB6] + [0x90]*3),
    ("A0F15 sfx",     0xA0F15, [0x9A, 0xB0, 0x00, 0x92, 0xB6] + [0x90]*6),
    ("A0F33 sfx",     0xA0F33, [0x9A, 0xB0, 0x00, 0x92, 0xB6] + [0x90]*6),
    ("9F888 cap",     0x9F888, [0x9A, 0x98, 0x00, 0x92, 0xB6, 0x90]),
    ("A8979 pickupm", 0xA8979, [0x9A, 0xF0, 0x00, 0x92, 0xB6] + [0x90]*18 + [0xEB, 0x2A]),
    ("A89FC pickups", 0xA89FC, [0x9A, 0xF8, 0x00, 0x92, 0xB6] + [0x90]*18 + [0xEB, 0x2A]),
    ("AA348 mainvul", 0xAA348, [0x9A, 0xD8, 0x00, 0x92, 0xB6, 0x74, 0x17]),
    ("AA366 mainlas", 0xAA366, [0x9A, 0xE0, 0x00, 0x92, 0xB6, 0x74, 0x17]),
    ("AA384 mainpla", 0xAA384, [0x9A, 0xE8, 0x00, 0x92, 0xB6, 0x74, 0x17]),
    ("A99CB rfheld",  0xA99CB, [0x9A, 0xD0, 0x00, 0x92, 0xB6, 0x7D, 0x09, 0xC3, 0x90, 0x90]),
    ("AA3A2 subgate", 0xAA3A2, [0x9A, 0xC0, 0x00, 0x92, 0xB6, 0x74, 0x0F]),
    ("AA3B8 subgate", 0xAA3B8, [0x9A, 0xC8, 0x00, 0x92, 0xB6, 0x74, 0x0F]),
    ("AB05E subedge", 0xAB05E, [0x9A, 0xB8, 0x00, 0x92, 0xB6, 0x75, 0x25]),
    ("AB092 subedge", 0xAB092, [0x9A, 0xB8, 0x00, 0x92, 0xB6, 0x75, 0x25]),
    ("AB552 subedge", 0xAB552, [0x9A, 0xB8, 0x00, 0x92, 0xB6, 0x74, 0x47]),
    ("AB63C subedge", 0xAB63C, [0x9A, 0xB8, 0x00, 0x92, 0xB6, 0x74, 0x45]),
    ("9B62A walk",    0x9B62A, [0x9A, 0xA0, 0x00, 0x92, 0xB6] + [0x90]*4),
    ("9BF9B bright",  0x9BF9B, [0x9A, 0x48, 0x00, 0x92, 0xB6]),
    ("9AD50 hook",    0x9AD50, [0x9A, 0x00, 0x00, 0x92, 0xB6, 0x90]),
    ("9A8E6 nop",     0x9A8E6, [0x90, 0x90, 0x90]),
    ("9AC35 hook",    0x9AC35, [0x9A, 0x08, 0x00, 0x92, 0xB6, 0x90]),
    ("9AC3B hook",    0x9AC3B, [0x9A, 0x28, 0x00, 0x92, 0xB6, 0x90, 0x90, 0x90, 0x90]),
    ("9AE70 hook",    0x9AE70, [0x9A, 0x38, 0x00, 0x92, 0xB6]),
    ("9BC04 retf6",   0x9BC04, [0xCA, 0x06, 0x00]),  # original logger preserved
    ("9BF66 nop",     0x9BF66, [0x90] * 8),
    ("98F0D jmp",     0x98F0D, [0xEA, 0x10, 0x55, 0x00, 0xB0]),
    ("B5510 start",   0xB5510, [0xF6, 0x06, 0x4C, 0x07, 0x02, 0x75, 0x47]),
    ("B6920 vec0",    0xB6920, [0xE9]),
    ("B6A20 defaults", 0xB6A20, BOOT_DEFAULTS_BYTES),
]
all_ok = True
for name, phys, exp in checks:
    got = list(read_combined(phys, len(exp)))
    ok  = got == exp
    all_ok = all_ok and ok
    print(f"  {'OK' if ok else 'FAIL':4s}  {name}: {bytes(got).hex(' ')}")

if all_ok: print("\nAll checks passed.")
else:       print("\nSome checks FAILED.")
