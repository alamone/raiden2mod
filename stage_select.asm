; ============================================================
; Raiden 2 Stage Select  —  segment B692, offset 0x0000
; Called via CALL FAR B692:0000 from 9AD50 (9800 segment)
; (cpu 186: V30 = 8086+186 extensions only; forbid NASM's silent 386
; long-form Jcc promotion — see the note in stage_select2.asm)
; DS=0 on entry.  Returns via RETF.
; ============================================================
;
; ROM PATCHES REQUIRED:
;   9AD50 : 9A 00 00 92 B6 90   CALL FAR B692:0000 + NOP
;           (was: C7 06 5E 9F 00 00  MOV [9F5E],0)
;
;   9A8E7 : 90 90 90             NOP x3
;           (was: A3 60 9F  MOV [9F60],AX — redundant zero-init of loop counter)
;
;   9AC35 : 9A 08 00 92 B6 90     CALL FAR B692:0008 + NOP
;           (was: 89 47 0A        MOV [BX+0A],AX   — scroll struct Y start position = 0
;                 89 47 0C        MOV [BX+0C],AX   — absorbed; reconstructed in trampoline)
;           Called twice per stage load (type=0 and type=1), both with layer index 0.
;           Override applies on first call; AREA_POS cleared so second call is a no-op.
;
;   9A9CB : FF 36 04 BF FF 36 5E 9F E8 96 45  (11 bytes)
;           (was: 6A 00           PUSH 0              — seek pos hardcoded to 0
;                 FF 76 04        PUSH [BP+04]        — stage var
;                 E8 99 45        CALL 9EF6C          — level data loader
;           New:  PUSH [AREA_POS] / PUSH [STAGE_VAR] / CALL 9EF6C (recalculated offset)
;           This passes AREA_POS as the scroll seek position to the level data loader,
;           which advances the enemy spawn cursors ([9F9E],[9FA0]) to the right point
;           in the stage data, matching the game's own checkpoint restart behaviour.)
;
;   9A9E8 : 9A 10 00 92 B6  CALL FAR B692:0010  (new patch)
;           (was: 83 3E 76 9F 04  CMP [9F76],4  — exactly 5 bytes, perfect fit)
;           Note: was previously at 9A9E4 (INC [9F76], 4 bytes + 1 NOP absorbing
;           the first byte of CMP) which corrupted the instruction stream.
;           Now at 9A9E8: carrier_spawn reconstructs both INC [9F76] and
;           CMP [9F76],4 before RETF so the JB at 9A9ED uses correct flags.
;
;   9BF66 : E8 E1 5A CA 04 00   bridge (existing, kept for completeness)
;           This bridge is NO LONGER CALLED by our code — we use direct VRAM writes.
;
; ============================================================
; VRAM LAYOUT  (Seibu SPI text layer, transposed storage)
; ============================================================
; Physical base : 0xE800  (mapped 0xE800–0xF7FF, 4096 bytes)
; Dimensions    : 64 cols × 32 rows (2048 cells × 2 bytes each)
;
; VOFF(screen_row, screen_col) = screen_col × 128 + (39 − screen_row) × 2
;
; Advance rightward on screen → VOFF += 128  (CHAR_ADVANCE)
; Advance downward  on screen → VOFF −= 2
;
; VRAM word layout: low byte = tile index (= raw ASCII char), high byte = attribute
; Attribute 0x22: palette group 2 (yellow), tile bank 2 (font glyphs at 0x220–0x27F)
;
; ============================================================

cpu 186
org 0x0000      ; segment B692, offset 0.  All labels are CS-relative.

; ── Constants ──────────────────────────────────────────────
VRAM_SEG    equ 0x0E80      ; text VRAM segment  (phys 0xE800)
CHAR_ADV    equ 128         ; bytes per rightward character step

; Attribute byte format: 0xXY where X=foreground color, Y=background color
; Foreground: 0=gray 1=red 2=yellow 3=green 4=cyan 7=orange
; Background: 0=transparent 1=red 2=gray
ATTR        equ 0x20        ; yellow text, transparent background
ATTR_HI     equ 0x70        ; orange text, transparent background (selected row)
ATTR_RED    equ 0x10		; red text, transparent background

ROW_HEADER  equ 20          ; first section header row

COL_CURSOR  equ 7           ; cursor ">" column
COL_LABEL   equ 9           ; item label column
COL_SEP     equ 17          ; separator ":" column
COL_VALUE   equ 19          ; value column

NUM_ITEMS   equ 13          ; Stage, Loop, Area, Rank, Vulcan, Laser, Plasma,
                            ; Nuclear, Homing, BombStock, BombType, Fairy, Multi
ITEM_SZ     equ 10          ; bytes per menu-table entry

; Game variables (DS=0)
VBLANK_CTR  equ 0x9F5A
cpu 186

STAGE_VAR   equ 0x9F5E
LOOP_VAR    equ 0x9F60
P1P2_PORT   equ 0x0744      ; active-low; bit 0=P1_UP ... bit 4=P1_BTN1
SYS_PORT    equ 0x074C      ; active-low; bit 0=P1_START

; Scroll layer state (DS=0) — adjusted by 9B5DE on checkpoint restart; we replicate that here
SCR_L0_BASE equ 0xB14A      ; scroll layer 0 Y base
SCR_L1_BASE equ 0xB14E      ; scroll layer 1 Y base
SCR_L2_BASE equ 0xB152      ; scroll layer 2 Y base
SCR_L0_WIN  equ 0x9FA6      ; scroll layer 0 window offset
SCR_L1_WIN  equ 0x9FA8      ; scroll layer 1 window offset
SCR_L2_WIN  equ 0x9FAA      ; scroll layer 2 window offset
SCROLL_POS  equ 0x83A       ; required for area select — exact role TBD

; Scratch RAM (0xBF00-0xBFFF, initialised to 0 at boot, unused during play)
DIGIT_RAM   equ 0xBF00      ; single-char string buffer for digit display
AREA_VAR    equ 0xBF02      ; chosen area index (0-based)
; 0xBF03 = null terminator for DIGIT_RAM (stays 0)
AREA_POS    equ 0xBF04      ; resolved checkpoint position (0 = no override / area 1)
                             ; written at stage-select confirm, read by ck_override
PROG_VAR    equ 0xBF06      ; chosen progress level 0-F; scaled to [9F8E] at confirm
GAME_TIME   equ 0x9F8E      ; gameplay accumulator driving dynamic difficulty
BOOT_DONE   equ 0xBF08      ; 0 = boot menu not yet shown; 1 = shown
DEBUG_EN    equ 0xBF0A      ; 1 = debug menu enabled (default); 0 = disabled
STSEL_EN    equ 0xBF0C      ; 1 = stage select enabled (default); 0 = disabled
BOOT_TICKS  equ 1800        ; auto-confirm timeout: 1800 vblanks = 30 seconds
BOOT_NO_TMR equ 0xFFFF      ; sentinel: timer permanently stopped
REGION_VAR  equ 0xBF0E      ; raw region byte for ROM patch at 9843D (reads FFFFB -> [9F67])
RF_RATE     equ 0xBF10      ; rapid-fire rate index (0=off, 1=30HZ, 2=20HZ, 3=15HZ, 4=10HZ)
RF_CTR      equ 0xBF12      ; rapid-fire frame countdown (reloads from bm_rf_reloads table)
DBG_HOLD    equ 0xBF14      ; debug menu hold counter
RF_SUPPRESS equ 0xBF16      ; set to 1 while debug menu is open to suppress rapid fire
MW_VULCAN   equ 0xBF18      ; main weapon: vulcan level  (0=off, 1-8)
MW_LASER    equ 0xBF1A      ; main weapon: laser level   (0=off, 1-8)
MW_PLASMA   equ 0xBF1C      ; main weapon: plasma level  (0=off, 1-8)
SW_NUCLEAR  equ 0xBF1E      ; sub weapon:  nuclear level (0=off, 1-4)
SW_HOMING   equ 0xBF20      ; sub weapon:  homing level  (0=off, 1-4)
MULTI_WPN   equ 0xBF22      ; 0=OFF (single weapon enforced), 1=ON (all independent)
WEAPON_ARMED equ 0xBF24     ; PENDING BITMASK: bit0=P1, bit1=P2; set to 3 at menu
                            ; confirm. The 9AC0E hooks apply the menu loadout to
                            ; a player whose bit is still set; the per-frame tick
                            ; (L2_BJOIN) clears a bit once that player is ACTIVE.
                            ; Result: only each player's FIRST arrival (cold start
                            ; or late join) is armed — deaths, game-over cleanup
                            ; and continues re-init stock (vulcan-1).
SW_ARMED     equ 0xBF26     ; legacy slot, unused (subs share WEAPON_ARMED bits)
MENU_LIVE    equ 0xBF5C     ; 1 = a menu-started game is in progress. Gates the
                            ; arming paths in main_override/weapon_init so plain
                            ; games and the attract demo stay stock. Set at menu
                            ; confirm, cleared by default_stage and menu entry.
BOMB_PEND    equ 0xBF5E     ; player struct base of a late joiner whose bomb
                            ; array still needs the ITEM STOCK fill. 9AC0E
                            ; writes the stock bombs AFTER our hook sites, so
                            ; the fill is deferred one frame to the per-frame
                            ; tick (L2_BJOIN). 0 = nothing pending.
SPAWN_Y      equ 0xBF28     ; (unused legacy slot, kept zeroed for safety)
SPAWN_Y_VAL  equ 0xBF2A     ; adjusted_base; spawn_y_apply_impl forces player Y from this
                            ; each init-loop pass, self-disarms when zeroing stops
HOOK_RET_IP  equ 0xBF2C     ; scratch far-return IP for arg-substitution hooks
HOOK_RET_CS  equ 0xBF2E     ; scratch far-return CS (popped/jmp-far'd as a pair)
BGM_VAR      equ 0xBF30     ; boot menu SOUND TEST track number (0x00-BGM_MAX)
BGM_MAX      equ 0x5A       ; last valid sound id (user-verified)
RANK_VAL     equ 0xBF34     ; scaled GAME_TIME from confirm (PROG_VAR *
                            ; (LOOP*8+stage_factor)); applied to [9F8E] in
                            ; area_start_impl AFTER 9A8C9's zeroing at 9A8EC
                            ; destroyed the old confirm-time write
SS_USED      equ 0xBF36     ; 1 = this cold start came from the stage-select
                            ; menu -> prime difficulty (consumed one-shot)
SFX_TMP      equ 0xBF38     ; staging word for the deduped sound-queue push
REAP_TMR     equ 0xBF3A     ; homing-orphan reaper: sweep timer
REAP_SLOT    equ 0xBF3C     ; homing-orphan reaper: candidate slot addr
SFX_LAST2A   equ 0xBF3E     ; vblank stamp of the last impact sound passed
SUBN_P1      equ 0xBF40     ; sub-weapon RF gate: frame stamp of P1's last
SUBN_P2      equ 0xBF42     ;   allowed NUCLEAR dispatch (and P2's)
SUBH_P1      equ 0xBF44     ; same for HOMING, P1
SUBH_P2      equ 0xBF46     ;   and P2
FAIRY_VAR    equ 0xBF4A     ; stage select FAIRY row: fairies in stock (0-9).
                            ; The death-fairy trigger is the per-player stock
                            ; counter [player+0x24] (P1 9EF4 / P2 9F32), DEC'd
                            ; once per death by 9800:39CE — each stocked fairy
                            ; covers one death. bomb_fill (blob2) writes
                            ; FAIRY_VAR into it at start/join.
BOMB_STOCK   equ 0xBF58     ; ITEM STOCK menu: bombs in stock (0-7)
BOMB_TYPE    equ 0xBF5A     ; 0 = NUKE (red, slot value 1, entity 0x14),
                            ; 1 = CLUSTER (yellow, slot value 2, entity 0x16)
WSU_VAR      equ 0xBF48     ; WEAPON SWITCH UPGRADE: 0=OFF (stock: picking a
                            ; different weapon transfers the level unchanged),
                            ; 1=ON (a switch pickup also gains +1 level)

; ── second blob (stage_select2.asm, segment B581, phys B5810) ─
; The primary blob's free-fill region hard-ends at phys B8102 (the
; game's string tables follow — overrunning them corrupted the
; title text). Self-contained impls + the logo palette images live
; in the second blob; these offsets are its FIXED vector ABI.
L2_SEG        equ 0xB581
L2_SUB_EDGE   equ 0x0000
L2_SUBG_NUKE  equ 0x0008
L2_SUBG_HOM   equ 0x0010
L2_RF_HELD    equ 0x0018
L2_MAIN_VUL   equ 0x0020
L2_MAIN_LAS   equ 0x0028
L2_MAIN_PLA   equ 0x0030
L2_PICKUP_M   equ 0x0038
L2_PICKUP_S   equ 0x0040
L2_FAIRY      equ 0x0048    ; retired slot (fairy = [player+0x24] counter)
L2_BOMBS      equ 0x0050
L2_WINIT      equ 0x0058
L2_BJOIN      equ 0x0060
L2_MAINOVR    equ 0x0068
L2_LOGO_WHITE equ 0x0500
L2_LOGO_COLOR equ 0x05C0
LOGO_VAR     equ 0xBF32     ; title logo palette: 0 = WHITE (boot-set art),
                            ; 1 = COLOR (attract-movie art). Forced into the
                            ; staging buffer every non-gameplay frame, so the
                            ; choice covers fresh-boot, post-demo and
                            ; post-game-over title screens alike.
; NOTE: [061C] (written by A16FD) is a PALETTE SELECTOR, not a brightness
; register — writing 0x07 there recolored the text layer (tested 2026-06-10).
; Do not use it for menu dimming.
SP4_GADGET   equ 0x5820     ; 9800:5820 = ADD SP,4 / RETF — arg cleanup for
                            ; near-calling 9800 functions with 2 word args
RETF_GADGET  equ 0x7FFE     ; 9800:7FFE = RETF — for arg-less near calls
ROW_BOOT_HDR  equ 8         ; boot menu header row (moved up for LOGO row)
ROW_BOOT_DBG  equ 10        ; "DEBUG MENU" row
ROW_BOOT_SS   equ 12        ; "STAGE SELECT" row
ROW_BOOT_RF   equ 14        ; "RAPID FIRE" row
ROW_BOOT_RG   equ 16        ; "REGION" label row
ROW_BOOT_RGVAL equ 17       ; region name value row
ROW_BOOT_LOGO equ 19        ; "TITLE LOGO" row (WHITE/COLOR)
ROW_BOOT_BGM  equ 21        ; "SOUND TEST" row (A/B plays the selected sound)
ROW_BOOT_WSU  equ 23        ; "WPN UPGRADE" row (weapon switch upgrade ON/OFF)
ROW_BOOT_HINT equ 25        ; "START TO CONFIRM" row
ROW_BOOT_CTR  equ 26        ; countdown row
ROW_SS_CTR    equ 38        ; stage-select countdown row (below the menu)
SS_TICKS      equ 3600      ; stage-select auto-confirm: 3600 vblanks = 60 s.
                            ; Unlike the boot menu, input does NOT stop this
                            ; timer — at zero the current settings are taken.
ROW_BOOT_VER  equ 36        ; version string row (bottom right)
ROW_BOOT_TT0  equ 28        ; tooltip title line "HOW TO USE xxx:"
ROW_BOOT_TT1  equ 29        ; tooltip line 1
ROW_BOOT_TT2  equ 30        ; tooltip line 2
ROW_BOOT_TT3  equ 31        ; tooltip line 3
ROW_BOOT_TT4  equ 32        ; tooltip line 4

; ── VOFF macro (compile-time only — row and col must be constants) ──
%define VOFF(row,col)  ((col)*128 + (39-(row))*2)

; ============================================================
; FIXED VECTOR TABLE  — offsets in this segment must never change.
; ROM patches use CALL FAR B692:xxxx to reach these stubs.
; Each stub is a 3-byte near JMP to the real implementation,
; padded to 8 bytes so future vectors slot in cleanly.
;
;   B692:0000  vec_stage_select   — CALL FAR from 9AD50 (existing patch)
;   B692:0008  vec_ck_override    — CALL FAR from 9AC35 (existing patch)
;   B692:0010  vec_carrier_spawn  — CALL FAR from 9A9E4 (new patch)
;   B692:0018  vec_boot_menu      — CALL FAR from 9889E
;             Replaces: C7 06 54 9F 01 00  MOV [9F54],1  (6 bytes)
;             Patch:    9A 18 00 92 B6 90  CALL FAR B692:0018 + NOP
;   B692:0020  vec_rapid_fire     — CALL FAR from 9A71C (title) and 9A72E (gameplay)
;             Contains full rapid-fire tick: dec RF_CTR, on zero reload + clear B142.
;             Gameplay relay at 9A72E: CALL 9ACF9 + CALL FAR B692:0020 + RET
;             ROM patches: 9A72E (relay), 9AF2E and 9AFF1 (redirect to relay)
;   B692:0028  vec_weapon_init   — CALL FAR from 9AC3B (inside 9AC0E player struct init)
;             Replaces: MOV [BX+0E],AX / MOV [BX+10],AX / MOV [BX+12],AX
;             Writes SW_NUCLEAR/SW_HOMING to player struct if stage select configured them.
; ============================================================
vec_stage_select:                   ; B692:0000  (must stay at 0000)
    jmp  entry
    times (8 - ($ - vec_stage_select)) db 0x90   ; pad to 8 bytes

vec_ck_override:                    ; B692:0008  (must stay at 0008)
    jmp  near ck_override           ; 3 bytes (E9 lo hi) — near forced for deterministic padding
    times (8 - ($ - vec_ck_override)) db 0x90    ; pad to 8 bytes (5 NOPs)

vec_carrier_spawn:                  ; B692:0010  (must stay at 0010)
    jmp  near carrier_spawn
    times (8 - ($ - vec_carrier_spawn)) db 0x90  ; pad to 8 bytes
    ; Patch: 9A9E8 replaced with CALL FAR B692:0010 (5 bytes, exact fit for CMP [9F76],4)

vec_boot_menu:                      ; B692:0018  (must stay at 0018)
    jmp  near boot_menu_gate
    times (8 - ($ - vec_boot_menu)) db 0x90      ; pad to 8 bytes

vec_rapid_fire:                     ; B692:0020  (CALL FAR from 9A71C and 9A72E)
    jmp  near rapid_fire_tick
    times (8 - ($ - vec_rapid_fire)) db 0x90     ; pad to 8 bytes

vec_weapon_init:                    ; B692:0028  — CALL FAR from 9AC3B
    jmp  L2_SEG:L2_WINIT
    times (8 - ($ - vec_weapon_init)) db 0x90

vec_vblank_dbg:                     ; B692:0030  — CALL FAR from rewritten 9A484
    jmp  near vblank_dbg_impl
    times (8 - ($ - vec_vblank_dbg)) db 0x90

vec_spawn_y_apply:                  ; B692:0038  — CALL FAR from 9AE70
    jmp  near spawn_y_apply_impl
    times (8 - ($ - vec_spawn_y_apply)) db 0x90

vec_isr_rf:                         ; B692:0040  — CALL FAR from 9819C (vblank ISR)
    jmp  near isr_rf_impl
    times (8 - ($ - vec_isr_rf)) db 0x90

vec_bright:                         ; B692:0048  — CALL FAR from 9BF9B (debug menu loop)
    jmp  near bright_impl
    times (8 - ($ - vec_bright)) db 0x90

vec_dbg_menu:                       ; B692:0050  — CALL FAR from B5510 trampoline
    jmp  near dbg_menu_far
    times (8 - ($ - vec_dbg_menu)) db 0x90

vec_area_ckpt:                      ; B692:0058  — CALL FAR from 9AADD (inside 9AA88)
    jmp  near area_ckpt_impl
    times (8 - ($ - vec_area_ckpt)) db 0x90

vec_area_start:                     ; B692:0060  — CALL FAR from 9A9F5 (inside 9A8C9)
    jmp  near area_start_impl
    times (8 - ($ - vec_area_start)) db 0x90

vec_spawn_args:                     ; B692:0068  — CALL FAR from 9A973 (inside 9A8C9)
    jmp  near spawn_args_impl
    times (8 - ($ - vec_spawn_args)) db 0x90

vec_scroll_init:                    ; B692:0070  — CALL FAR from 9A988 (inside 9A8C9)
    jmp  near scroll_init_impl
    times (8 - ($ - vec_scroll_init)) db 0x90

vec_loader_args:                    ; B692:0078  — CALL FAR from 9A9CB (inside 9A8C9)
    jmp  near loader_args_impl
    times (8 - ($ - vec_loader_args)) db 0x90

vec_rf_loop:                        ; B692:0080  — CALL FAR from 9ADBC (gameplay loop)
    jmp  near rf_loop_impl
    times (8 - ($ - vec_rf_loop)) db 0x90

vec_multi_pool:                     ; B692:0088  — CALL FAR from 9F8C1/9F8F5 (recalc 7888)
    jmp  near multi_pool_impl
    times (8 - ($ - vec_multi_pool)) db 0x90

vec_pool_ext:                       ; B692:0090  — CALL FAR from A270:F786 (F74D tail)
    jmp  near pool_ext_impl
    times (8 - ($ - vec_pool_ext)) db 0x90

vec_pool_cap:                       ; B692:0098  — CALL FAR from 9F888 (recalc head)
    jmp  near pool_cap_impl
    times (8 - ($ - vec_pool_cap)) db 0x90

vec_walk_ext:                       ; B692:00A0  — CALL FAR from 9B62A (bullet repositioner)
    jmp  near walk_ext_impl
    times (8 - ($ - vec_walk_ext)) db 0x90

vec_pool_prio:                      ; B692:00A8  — CALL FAR from A270:BCA5 (bullet allocator)
    jmp  near pool_prio_impl
    times (8 - ($ - vec_pool_prio)) db 0x90

vec_sfx_dedupe:                     ; B692:00B0  — CALL FAR from 9800:8F15 and 8F33
    jmp  near sfx_dedupe_impl
    times (8 - ($ - vec_sfx_dedupe)) db 0x90

vec_sub_edge:                       ; B692:00B8  — CALL FAR from A270:895E/8992/8E52/8F3C
    jmp  L2_SEG:L2_SUB_EDGE
    times (8 - ($ - vec_sub_edge)) db 0x90

vec_subgate_nuke:                   ; B692:00C0  — CALL FAR from A270:7CA2 (fire dispatcher)
    jmp  L2_SEG:L2_SUBG_NUKE
    times (8 - ($ - vec_subgate_nuke)) db 0x90

vec_subgate_hom:                    ; B692:00C8  — CALL FAR from A270:7CB8 (fire dispatcher)
    jmp  L2_SEG:L2_SUBG_HOM
    times (8 - ($ - vec_subgate_hom)) db 0x90

vec_rf_held:                        ; B692:00D0  — CALL FAR from A270:79CB (held-autofire)
    jmp  L2_SEG:L2_RF_HELD
    times (8 - ($ - vec_rf_held)) db 0x90

vec_main_vul:                       ; B692:00D8  — CALL FAR from A270:7C48 (vulcan dispatch)
    jmp  L2_SEG:L2_MAIN_VUL
    times (8 - ($ - vec_main_vul)) db 0x90

vec_main_las:                       ; B692:00E0  — CALL FAR from A270:7C66 (laser dispatch)
    jmp  L2_SEG:L2_MAIN_LAS
    times (8 - ($ - vec_main_las)) db 0x90

vec_main_pla:                       ; B692:00E8  — CALL FAR from A270:7C84 (plasma dispatch)
    jmp  L2_SEG:L2_MAIN_PLA
    times (8 - ($ - vec_main_pla)) db 0x90

vec_pickup_main:                    ; B692:00F0  — CALL FAR from A270:6279 (main pickup)
    jmp  L2_SEG:L2_PICKUP_M
    times (8 - ($ - vec_pickup_main)) db 0x90

vec_pickup_sub:                     ; B692:00F8  — CALL FAR from A270:62FC (sub pickup)
    jmp  L2_SEG:L2_PICKUP_S
    times (8 - ($ - vec_pickup_sub)) db 0x90

; ============================================================
; BOOT MENU DEFAULTS BLOCK — FIXED ABI offset B692:0100 (phys B6A20).
; One byte per setting, consumed once by the boot-menu init. The
; canonical values live in patch_roms.py's BOOT_DEFAULTS dict (it
; overwrites these bytes after the blob is placed and verifies them),
; so users building from source edit the dict, not this file. Users
; with only a patched ROM SET can hex-edit single bytes — the phys
; space interleaves even bytes into prg0.u0211 and odd bytes into
; rom2j.u0212 at file offset phys/2:
;   B6A20 debug menu   0/1          -> prg0.u0211  @ 0x5B510
;   B6A21 stage select 0/1          -> rom2j.u0212 @ 0x5B510
;   B6A22 region index 0..n         -> prg0.u0211  @ 0x5B511
;   B6A23 rapid fire   0..4         -> rom2j.u0212 @ 0x5B511
;   B6A24 sound test track 0..5Ah   -> prg0.u0211  @ 0x5B512
;   B6A25 title logo   0=WHT 1=COL  -> rom2j.u0212 @ 0x5B512
;   B6A26 wpn sw upgrade 0/1        -> prg0.u0211  @ 0x5B513
; The TIMES below also asserts the vector table still ends at 0x100.
; ============================================================
    times (0x100 - ($ - $$)) db 0x90
boot_defaults:
bd_debug:   db 1                    ; placeholder — patch_roms.py overwrites
bd_stsel:   db 1
bd_region:  db 0
bd_rf:      db 0
bd_bgm:     db 1
bd_logo:    db 1
bd_wsu:     db 0
    times (0x10 - ($ - boot_defaults)) db 0




; ============================================================
; RAPID_FIRE_TICK  (reached via vec_rapid_fire = B692:0020)
;
; Called from:
;   9A5FC relay -> CALL FAR B692:0020, from 981B4 hook (vblank interrupt handler)
;   9A71C relay -> CALL FAR B692:0020, from 982A6 (title screen loop)
;
; The 981B4 hook fires exactly once per vblank, unconditionally, in all
; game states including 2-player simultaneous.
;
; Also handles debug menu hold trigger: reads P2 START directly from hardware
; Also handles debug menu hold trigger: increments DBG_HOLD in B5510 trampoline.
; rapid_fire_tick itself only handles rapid fire.
;
; MUST save/restore ALL registers and FLAGS.
; ============================================================
rapid_fire_tick:
    pushf
    push ax
    push bx

    ; ── Rapid fire ───────────────────────────────────────────
    ; (No state gating needed here any more: this is reached only from
    ; rf_loop_impl, hooked at 9ADBC inside the gameplay loop's frame-
    ; update section — which the loop SKIPS while the continue screen,
    ; game-over or high-score name entry handlers run, and which never
    ; executes in menus, intro, or demo play.)
    cmp  word [RF_RATE], 0
    je   rft_done
    cmp  word [RF_SUPPRESS], 0  ; suppress RF while debug menu is open
    jne  rft_done
    ; PLASMA-ONLY edge synthesis. The engine has two fire cadences:
    ; plasma equipped = fire per press EDGE (the mash-to-charge plasma
    ; mechanic), otherwise = fire after 30 held frames (held-autofire).
    ; Press edges — real mash or this latch-clear — make the engine
    ; suppress nuclear/homing volleys (bot-measured in pure stock, RF
    ; off: 10s hold = 6-11 nukes, 10s mash at ANY speed = 0). So edges
    ; are synthesized only while a player has plasma (which cannot fire
    ; without them); everyone else gets RF through the rf_held hook at
    ; A270:79CB, which accelerates the held-autofire threshold instead.
    cmp  word [0x9EDA], 0       ; P1 plasma level
    jne  .edges
    cmp  word [0x9F18], 0       ; P2 plasma level
    je   rft_done
.edges:
    dec  word [RF_CTR]
    jnz  rft_done
    mov  bx, [RF_RATE]
    shl  bx, 1
    cs   mov  ax, [bm_rf_reloads + bx]
    mov  [RF_CTR], ax
    mov  word [0xB142], 0

rft_done:
    pop  bx
    pop  ax
    popf
    retf

; ============================================================
; WEAPON_INIT_IMPL  (called via vec_weapon_init = B692:0028)
; Replaces: MOV [BX+0E],AX / MOV [BX+10],AX / MOV [BX+12],AX
; BX = player struct base. AX = 0.
; Armed players (WEAPON_ARMED pending bit set) get the menu subs via BX.
; ============================================================
; SPAWN_Y_IMPL  (called via vec_spawn_y = B692:0030)
; Called on every vblank spin-loop iteration. Checks SPAWN_Y:
; if non-zero, writes to P1/P2 player struct Y fields, then clears it.
; Must end with TEST [074C],02h to restore flags for 9A62E's JNZ.
; ============================================================
vblank_dbg_impl:
    ; Relocated 9A62E debug-hold relay — the old relay sat INSIDE the game's
    ; checkpoint table (CS:25FC) and destroyed stage 1/2 checkpoint data.
    ; Reached via vec_vblank_dbg (B692:0030) from the rewritten 9A484:
    ;   9A484: call far B692:0030 / cmp ax,[9F5A] / je -6 / ret
    ; Called once per vblank-wait. Holds P2 START ~1s -> debug menu (9BD54).
    ; Must end with AX=[9F5A] (the absorbed first instruction of 9A484).
    cmp  word [DEBUG_EN], 0       ; boot menu "DEBUG MENU: OFF"?
    je   .reset                   ; -> never count, never trigger
    cmp  byte [0x9F54], 0         ; game state must be 00 (credited title/
    jne  .reset                   ; gameplay) — not demo play (04) etc.
    test byte [0x074C], 0x02      ; P2 START held? (bit set = not held)
    jnz  .reset
    inc  word [0xBF14]
    cmp  word [0xBF14], 0x3C      ; ~60 frames
    jb   .done
    mov  word [0xBF14], 0
    mov  word [0x9DC0], 0         ; clear P1/P2 input latches
    mov  word [0x9DC2], 0
    mov  word [0xBF16], 1         ; RF_SUPPRESS = 1
    ; Near-call the debug menu (9800:3D54) from this far segment using the
    ; RETF gadget at 9800:7FFE (stock POP BP/RETF epilogue): its near RET
    ; pops 7FFE -> RETF -> pops our far return below.
    push cs
    push word .back
    push word 0x7FFE
    jmp  0x9800:0x3D54
.back:
.wait:
    test word [0x9DC0], 0x8000    ; wait for P2 START edge to clear
    jnz  .wait
    mov  word [0xBF16], 0         ; RF_SUPPRESS = 0
    jmp  .done
.reset:
    mov  word [0xBF14], 0
.done:
    mov  ax, [0x9F5A]             ; absorbed original instruction of 9A484
    retf

isr_rf_impl:
    ; Per-frame ISR hook via vec_isr_rf (B692:0040) from 9819C in the
    ; vblank ISR (replacing CMP byte [9F62],0). Fires once per frame in
    ; every game state. The rapid-fire tick used to live here, but firing
    ; in ALL states leaked autofire edges into the high-score name entry
    ; and sped up the CONTINUE countdown — it moved to rf_loop_impl
    ; (9ADBC hook), which only runs while gameplay frames actually update.
    ; This hook now carries the TITLE LOGO forcing + the reconstruction,
    ; plus the transition-time rapid-fire tick below.

    ; ── Rapid fire during stage-ADVANCE approaches ───────────
    ; The approach scroll (1A->1B etc., FEC0->0000, ~12 s) pins the main
    ; loop inside the transition handler 9B1A1, so rf_loop_impl (9ADBC)
    ; never ticks there — held-button autofire produced no edges for the
    ; whole approach ("can't shoot when starting from 1A"; direct stage
    ; starts load at position 0 and have no approach). Entities run from
    ; the ISR script engine during transitions (ship moves, bombs work),
    ; so the tick belongs here, gated tightly: gameplay state 00 AND
    ; [9D64] >= 4 (stage clear/transition — verified 05 for the entire
    ; approach, 0 in normal play where rf_loop covers it). The death/
    ; continue context is [9D64] == 3 and stays RF-free.
    cmp  byte [0x9F54], 0
    jne  .no_rf
    cmp  byte [0x9D64], 4
    jb   .no_rf
    push cs                       ; rapid_fire_tick ends in RETF
    call rapid_fire_tick
.no_rf:

    ; ── TITLE LOGO choice (per-frame, non-gameplay only) ─────
    ; Lives here because this is the only hook that truly fires every
    ; frame. (A first attempt sat in boot_menu_gate/9889E — but 9AD4D(0)
    ; runs the entire attract cycle internally, so that gate fires about
    ; once per CYCLE, before the title's palette load, and never covered
    ; the title screen.) Gate: only while no player slot is active
    ; ([9ED0]=[9F0E]=0) — i.e. title, attract movie, coin screen. Never
    ; during gameplay or demo play, whose stages reuse sprite palette
    ; lines 36-41. The copy lands after this frame's 15h palette-DMA
    ; upload (98176 precedes us in the ISR), so it shows from the next
    ; frame on.
    ; State gate: [9F54] game state (user-documented): 00 = title screen /
    ; coin-in / gameplay, 01 = boot menu, 03 = intro movie (ship from
    ; trees + kanji logo reveal — animates the logo palette, so content
    ; guarding alone failed there), 04 = demo play, 05 = highscore.
    ; Only state 00 is forced; the player gate below excludes gameplay.
    cmp  byte [0x9F54], 0
    jne  .no_logo
    cmp  word [0x9ED0], 0
    jne  .no_logo
    cmp  word [0x9F0E], 0
    jne  .no_logo
    push ax
    push bx
    push ds
    push es
    push si
    push di
    push cx
    mov  bx, [LOGO_VAR]           ; cache while DS still covers our vars
    mov  ax, 0x1F00
    mov  es, ax
    mov  ax, L2_SEG               ; logo images live in the second blob
    mov  ds, ax
    cld
    ; Content guard: rewrite only when buffer line 37 currently holds one
    ; of the two known TITLE images (white or color). Attract-movie scenes
    ; that author their own logo palette — e.g. the kanji logo-reveal
    ; scene, which alternates per attract cycle — match neither and are
    ; left untouched. (Fade blends also match neither, so fades complete
    ; naturally and the correction lands when they finish.)
    mov  si, L2_LOGO_WHITE + 32   ; line 37 of the white image
    mov  di, 36*32 + 32           ; line 37 in the staging buffer
    mov  cx, 16
.chk_w:
    lodsw                         ; DS = L2_SEG
    cmp  ax, [es:di]
    jne  .not_white
    inc  di
    inc  di
    loop .chk_w
    jmp  short .known
.not_white:
    mov  si, L2_LOGO_COLOR + 32   ; line 37 of the color image
    mov  di, 36*32 + 32
    mov  cx, 16
.chk_c:
    lodsw
    cmp  ax, [es:di]
    jne  .done_pops               ; unknown content -> leave alone
    inc  di
    inc  di
    loop .chk_c
.known:
    mov  si, L2_LOGO_WHITE
    test bx, bx                   ; cached LOGO_VAR
    jz   .src_ok
    mov  si, L2_LOGO_COLOR
.src_ok:
    mov  di, 36 * 32              ; staging buffer offset of palette line 36
    mov  cx, 6 * 16               ; 6 lines x 16 colors
.cpy:
    lodsw
    stosw
    loop .cpy
.done_pops:
    pop  cx
    pop  di
    pop  si
    pop  es
    pop  ds
    pop  bx
    pop  ax
.no_logo:
    cmp  byte [0x9F62], 0         ; reconstruct absorbed instruction (flags
    retf                          ; feed the JNZ at 981A1)

multi_pool_impl:
    ; Hooked over both SUB word [AC66],38h sites (9F8C1 and 9F8F5) inside
    ; the difficulty recalc 7888. [AC66] is the master bullet-slot budget
    ; (0xAA = 170, the bullet array's designed capacity; refreshed into the
    ; live allocator limit [AC68]); the stock code cuts 56 slots per player
    ; whose PLASMA level is nonzero — headroom for the slot-hungry plasma
    ; snake, sane when plasma excludes the other mains. With MULTI_WPN the
    ; same player also fires vulcan+laser, so the cut starved the allocator
    ; (A270:BCA5 fails silently with carry when [AC6A] hits the limit) and
    ; shots vanished at 30Hz autofire. Keep the full budget in multi mode.
    cmp  word [MULTI_WPN], 0
    jne  .skip                  ; multi-weapon: keep all 170 slots
    sub  word [0xAC66], 0x38    ; stock behaviour (absorbed instruction)
.skip:
    retf

; ============================================================
; BULLET POOL EXTENSION — multi-weapon at 30Hz saturates the stock
; 170-slot shared bullet pool (segment 1000, slots 0C00-5660, stride 70h,
; free-list allocator at A270:BCA5 fails silently when [AC6A] hits the
; limit [AC68], refreshed from the master budget [AC66]). RAM dumps under
; worst-case fire show 1000:B440-E7D0 unused, so 117 extra slots are
; chained into the free list there (capacity 170 -> 287 = 11Fh). The
; raised budget applies ONLY in multi-weapon mode; stock/single games
; keep the exact original 0AAh cap, so the extension slots stay inactive
; and original behaviour is bit-identical.
; ============================================================

sfx_dedupe_impl:
    ; Hooked over the 11-byte queue-push tail in BOTH sound-command senders
    ; (9800:8F15 and 8F33: LEA AX,[BP+4] / PUSH / MOV AX,B0E0 / PUSH /
    ; CALL A24A). DX = the command word. The Z80 command queue at B0E0
    ; holds 40 word entries and silently DROPS on overflow (A244:
    ; MOV AX,FFFF / RET) — under heavy multi-weapon combat the SFX flood
    ; overflowed it, dropping whatever came next including music commands
    ; ("sound glitching when lots of objects onscreen"). Identical
    ; commands already pending are skipped: ten same-frame explosion
    ; sounds queue once, slashing pressure; the Z80 couldn't render
    ; near-simultaneous duplicates as distinct sounds anyway. Interrupts
    ; are off on both paths (8F06 does CLI; 8F25 runs in ISR context),
    ; so the scan is atomic. Registers: the replaced code clobbered
    ; AX and called A24A (clobbers BX/CX/SI/DI); callers have nothing
    ; live afterwards.
    ; Multi-weapon shot-sound thinning: with three mains firing, every
    ; volley pushes three different shot samples (vulcan 0027, laser 0028,
    ; plasma 0034) into the OKI's four ADPCM voices — constant voice-
    ; stealing = crackling/gurgling at ANY fire rate. In multi mode keep
    ; only vulcan's shot sound per volley; stock loadouts are untouched.
    cmp  word [MULTI_WPN], 0
    je   .no_thin
    ; (sound commands are 0x80XX words — an earlier version compared the
    ; low byte only and never matched)
    cmp  dx, 0x8028              ; laser shot sound
    je   .done
    cmp  dx, 0x8034              ; plasma shot sound
    je   .done
    cmp  dx, 0x8026              ; homing launch sound (nuclear's 8025 kept
    je   .done                   ; as the single sub-weapon report)
    cmp  dx, 0x802A              ; enemy impact sound — multiple weapon
    jne  .no_thin                ; streams stack it; rate-limit to one
    mov  ax, [0x9F5A]            ; per 6 frames (~10/s, a stock ceiling)
    sub  ax, [SFX_LAST2A]
    cmp  ax, 6
    jb   .done                   ; too soon -> drop this instance
    mov  ax, [0x9F5A]
    mov  [SFX_LAST2A], ax
.no_thin:
    ; Depth gate: identical commands in quick succession are NORMAL audio
    ; (a repeated command restarts a sample — an intentional retrigger).
    ; Only deduplicate when the queue is genuinely congested (>= 16 of 40
    ; entries pending), i.e. when the alternative is overflow drops.
    ; (The ungated version of this dedupe caused crackling in normal play.)
    push ax
    mov  ax, [0xB0E4]            ; write ptr
    sub  ax, [0xB0E6]            ; - read ptr = pending bytes (may wrap)
    jns  .depth_ok
    add  ax, 80                  ; wrap: 40 entries x 2 bytes
.depth_ok:
    cmp  ax, 32                  ; >= 16 pending entries?
    pop  ax                      ; (pop preserves flags)
    jb   .push                   ; queue healthy -> always push (stock-like)
    mov  si, [0xB0E6]            ; read pointer
.scan:
    cmp  si, [0xB0E4]            ; caught up to write pointer -> no dup
    je   .push
    cmp  dx, [si]
    je   .done                   ; identical command pending: skip push
    inc  si
    inc  si
    cmp  si, [0xB0E2]            ; wrap at buffer end
    jne  .scan
    mov  si, 0xB0E8              ; buffer start (header + 8)
    jmp  .scan
.push:
    mov  [SFX_TMP], dx
    push cs
    push word .done
    push word SFX_TMP            ; arg2: source ptr  ([bp+6] in A24A)
    push word 0xB0E0             ; arg1: queue header ([bp+4])
    push word SP4_GADGET         ; ADD SP,4 / RETF cleans args
    jmp  0x9800:0xA24A           ; stock ring-buffer push (drops if full)
.done:
    retf

pool_prio_impl:
    ; Hook over the bullet allocator's 8-byte cap check at A270:BCA5
    ; (MOV BX,[AC6A] / CMP BX,[AC68]; the JC "proceed" at BCAD consumes
    ; our flags; RETF preserves them). Type byte is in AH at entry.
    ; Type 0C = the player vulcan stream — measured owning 100+ of the
    ; pool's slots at level 8 + 30Hz autofire, starving every later
    ; spawner (homing = type 19 lost every allocation race -> "homing
    ; missiles do not fire"; laser/enemy fire suffered too). Vulcan alone
    ; is refused 24 slots below the cap, guaranteeing headroom for
    ; everything else; a refused vulcan bullet just narrows that volley
    ; by one — exactly what full saturation already did, but fairly.
    ; Stock play without autofire never fields >40 vulcan bullets, so
    ; original behaviour is unaffected.
    mov  bx, [0xAC6A]            ; live bullet count (stock behaviour)
    cmp  ah, 0x19                ; homing missile?
    jne  .not_homing
    ; NOTE inverted convention at this hook: the internal JC at BCAD
    ; treats CARRY SET as "proceed to allocate"; carry CLEAR falls into
    ; the stock fail path (which then STCs for the caller's convention).
    cmp  byte [0x9D64], 4        ; never spawn homing during a stage-
    jae  .hom_refuse             ; transition approach
    ; Launcher re-entry guard: missiles spawn ATTACHED to the ship (inert
    ; handler A270:C2C0) and fly only when the release event sets bit 10h
    ; of [slot+3C]. A 30Hz autofire edge landing inside the attach window
    ; re-entered the launcher, orphaning the pending pair — orphans hover
    ; for ~4-7s and block all relaunches ("homing stops after continuous
    ; shooting"). Refuse new homing while ANY unreleased missile exists;
    ; the launcher simply retries on a later edge.
    push es
    push si
    mov  si, 0x1000
    mov  es, si
    mov  si, [es:0x56D0 + 0x19*2]    ; type-19 list head
.hom_walk:
    test si, si
    jz   .hom_ok                 ; no pending unreleased missile
    ; attached/pre-flight missiles run the tiny state handlers in
    ; A270:C2C0..C32C (inert RET / follow-parent / await-release);
    ; released ones run the homing-flight handler outside that range.
    ; ([+3C] bit 10h turned out to toggle per frame — unusable as a latch.)
    cmp  word [es:si+0x4C], 0xC2C0
    jb   .hom_next
    cmp  word [es:si+0x4C], 0xC32C
    jb   .hom_refuse_pop         ; still attached -> refuse (no re-entry)
.hom_next:
    mov  si, [es:si+0x48]
    jmp  .hom_walk
.hom_ok:
    pop  si
    pop  es
    jmp  .std
.hom_refuse_pop:
    pop  si
    pop  es
.hom_refuse:
    clc                          ; carry clear = take the stock fail path
    retf
.not_homing:
    ; Main-weapon private ceiling. Originally vulcan-only (type 0C), but
    ; probes showed plasma SHARES type 0C with vulcan, and laser fires
    ; types 11 and 16 — uncapped, laser could fill the pool's final slots
    ; and starve nuke/homing volleys at saturation ("sub weapons thin to
    ; 1-2 per volley under multi fire"). All main-weapon types now stop
    ; 24 slots below the cap; subs + enemy fire share the reserve.
    cmp  ah, 0x0C                ; vulcan + plasma bullets
    je   .main_cap
    cmp  ah, 0x11                ; laser beam
    je   .main_cap
    cmp  ah, 0x16                ; laser secondary bolts
    jne  .std
.main_cap:
    push ax
    mov  ax, [0xAC68]
    sub  ax, 24                  ; mains' private ceiling: cap - reserve
    cmp  bx, ax                  ; carry set (bx < limit) = allow
    pop  ax                      ; (pop does not touch flags)
    retf
.std:
    cmp  bx, [0xAC68]            ; everyone else: full cap
    retf

pool_ext_impl:
    ; Tail hook inside the chain builder F74D (replaces the 6-byte chain
    ; terminator MOV word [ES:DI+44],0), covering ALL rebuild callers.
    ; Context: AX = pool index (untouched by F74D's body), ES = pool
    ; segment, DI = last stock slot.
    cmp  ax, 5                  ; pool 5 = the main bullet pool (seg 1000)
    je   .ext5
    mov  word [es:di+0x44], 0   ; reconstruct (all other pools)
    retf
.ext5:
    push si
    push cx
    mov  si, 0xB440             ; extension: 117 slots (RAM-verified free)
    mov  cx, 117
.extend:
    push di
    mov  [es:di+0x44], si       ; stock last -> first extension slot
    xchg si, di                 ; SI = previous slot, DI = extension start
.build:
    push cx
    push di
    mov  cx, 0x38                   ; zero the slot (the boot init only
.zero:                              ; clears the stock array region, and
    mov  word [es:di], 0            ; rebuilds must wipe stale state)
    add  di, 2
    loop .zero
    pop  di
    mov  [es:di+0x42], si           ; back link
    mov  si, di
    add  di, 0x70
    mov  [es:si+0x44], di           ; forward link (last fixed up below)
    pop  cx
    loop .build
    mov  word [es:si+0x44], 0       ; terminate the chain
    pop  di
    pop  cx
    pop  si
    retf

pool_cap_impl:
    ; Hook over MOV word [AC66],0AAh at the difficulty recalc head (9F888).
    ; IMPORTANT (caller-scan verified): the [AC66]->[AC68] refresh routine
    ; A270:BA7C has NO callers — the whole master-budget mechanism,
    ; including the stock plasma -38h cut, is vestigial and never had any
    ; runtime effect. The live allocator limit is [AC68], written once at
    ; init (A270:BD73) and never again — so it is driven directly here,
    ; every 32 ticks. Stock cap for normal games (identical to original
    ; behaviour); full extended capacity in multi-weapon mode.
    mov  ax, 0xAA               ; stock budget
    cmp  word [MULTI_WPN], 0
    je   .set
    mov  ax, 0x11F              ; multi: 170 stock + 117 extension slots
.set:
    mov  [0xAC66], ax           ; absorbed instruction's target (vestigial)
    mov  [0xAC68], ax           ; the limit the allocator actually checks
    retf                        ; (AX is free: 9F88E is XOR AX,AX)

walk_ext_impl:
    ; Hook over the 9-byte walk setup at 9B62A (MOV SI,0C00/BX,70/CX,0AAh).
    ; 9B61B repositions every bullet slot by the scroll delta in AX via
    ; 368C (adds AX to [ES:slot+0A]; clobbers SI/CX/DL, preserves AX/BX/ES).
    ; The extension slots are non-contiguous with the stock array, so run
    ; the extension pass here first, then reconstruct the stock register
    ; setup — the original CALL 368C at 9B633 performs the stock pass.
    mov  bx, 0x70
    mov  si, 0xB440
    mov  cx, 117
    push cs
    push word .back
    push word RETF_GADGET
    jmp  0x9800:0x368C
.back:
    mov  si, 0x0C00             ; reconstruct absorbed stock setup
    mov  bx, 0x70
    mov  cx, 0xAA
    retf

rf_loop_impl:
    ; Rapid-fire tick at its correct altitude: hooked at 9ADBC (replacing
    ; TEST word [A010],1Fh) inside the gameplay loop's frame-update
    ; section. The loop top short-circuits past this section to the AE92
    ; handler block while the continue screen, game-over sequence or
    ; high-score name entry runs, and the section never executes in the
    ; boot/stage-select menus, intro movie, or demo play — so autofire
    ; edges can no longer leak into any of those. rapid_fire_tick
    ; preserves all registers and flags.
    push cs                       ; rapid_fire_tick ends in RETF; push cs +
    call rapid_fire_tick          ; near call forms a valid far frame

    ; ── Menu-arming per-frame tick (blob2) ───────────────────
    ; Consumes WEAPON_ARMED pending bits once their player is
    ; active, and runs the deferred ITEM STOCK fill (BOMB_PEND)
    ; one frame after 9AC0E so the engine's own stock-bomb
    ; writes don't clobber it.
    call L2_SEG:L2_BJOIN

    ; ── Homing-orphan reaper ─────────────────────────────────
    ; Launcher entities starved out of pool 2 under peak load die with
    ; missiles still attached — the orphans sit in the attached-state
    ; handlers (A270:C2C0..C32C) for ~7s, blocking all homing relaunches.
    ; Every 64 frames, scan the type-19 list; a missile found in the
    ; attached state on two consecutive sweeps (~2s — a legitimate attach
    ; lasts only a few frames) is teleported far offscreen, where the
    ; engine's own cull frees it through the normal path.
    inc  word [REAP_TMR]
    test word [REAP_TMR], 63
    jnz  .no_reap
    push es
    push si
    push ax
    mov  si, 0x1000
    mov  es, si
    mov  si, [es:0x56D0 + 0x19*2]
.reap_scan:
    test si, si
    jz   .reap_none
    mov  ax, [es:si+0x4C]
    cmp  ax, 0xC2C0
    jb   .reap_next
    cmp  ax, 0xC32C
    jae  .reap_next
    cmp  si, [REAP_SLOT]          ; same stuck candidate as last sweep?
    jne  .reap_mark
    mov  word [es:si+0x0A], 0xF000  ; confirmed orphan: punt offscreen
    jmp  .reap_none                 ; (engine cull frees it cleanly)
.reap_mark:
    mov  [REAP_SLOT], si          ; first sighting: remember for next sweep
    jmp  .reap_done
.reap_next:
    mov  si, [es:si+0x48]
    jmp  .reap_scan
.reap_none:
    mov  word [REAP_SLOT], 0
.reap_done:
    pop  ax
    pop  si
    pop  es
.no_reap:
    test word [0xA010], 0x1F      ; reconstruct absorbed instruction (flags
    retf                          ; feed the JNZ at 9ADC2)

bright_impl:
    ; Relocated 9A7B2 brightness relay — the old relay sat inside a
    ; checkpoint-table row (the 0000 0590 0880 row at 9A7AC).
    ; Reached via vec_bright (B692:0048) from 9BF9B in the debug menu loop,
    ; replacing CALL 9C08E + TEST AX,AX (5 bytes).
    ; A16FD(0) is a verified leaf: MOV AX,arg / XOR AH,AH / MOV [061C],AX —
    ; so its effect is inlined here directly.
    mov  word [0x061C], 0         ; full brightness (== A16FD(0))
    push cs                       ; near-call 9C08E via the RETF gadget
    push word .back
    push word 0x7FFE
    jmp  0x9800:0x408E            ; 9C08E menu input poller, returns AX
.back:
    test ax, ax                   ; reconstruct absorbed TEST AX,AX (flags
    retf                          ; feed the JE at 9BFA0)

dbg_menu_far:
    ; Far-callable wrapper for the near debug-menu entry 9BD54 (9800:3D54).
    ; Replaces the old 9A605 stub, which sat inside the checkpoint table.
    ; Called via vec_dbg_menu (B692:0050) from the B5510 debug trampoline.
    cmp  word [DEBUG_EN], 0       ; boot menu "DEBUG MENU: OFF"?
    je   .back                    ; -> return without entering; the
                                  ;    trampoline just release-waits
    cmp  byte [0x9F54], 0         ; only in state 00 — the 98F0D dispatcher
    jne  .back                    ; also runs during attract demo play (04)
    push cs
    push word .back
    push word 0x7FFE              ; RETF gadget (stock POP BP/RETF epilogue)
    jmp  0x9800:0x3D54
.back:
    retf

area_ckpt_impl:
    ; AREA SELECT v3 — injection at the read site.
    ; Replaces 14 bytes at 9AADD inside the stock checkpoint-restart 9AA88:
    ;   PUSH [A00E] / PUSH [9F5E] / CALL 9AA3A / ADD SP,4
    ; This reimplements 9AA3A verbatim (hand-decoded from 9AA3A-9AA87) with
    ; one addition: if AREA_POS != 0 it overrides the [A00E] snapshot and is
    ; consumed here (one-shot — later restarts/deaths use the live snapshot,
    ; so checkpoint progression behaves normally after an area start).
    ; Returns AX = bracketing checkpoint position, BX = carrier id (9AA88
    ; pushes BX to the FAR A270:F594 spawner). CX/DX clobbered like 9AA3A.
    push si
    push es
    mov  dx, [0xA00E]            ; position snapshot (tracker-maintained)
    cmp  word [AREA_POS], 0
    je   .pos_ready
    mov  dx, [AREA_POS]          ; area select: override the snapshot...
    mov  word [AREA_POS], 0      ; ...and consume it (one-shot)
.pos_ready:
    mov  si, [0x9F5E]            ; stage (shifts, not MUL — DX must survive)
    shl  si, 4                   ; *16
    mov  ax, si
    shl  ax, 1                   ; *32
    add  si, ax                  ; SI = stage*0x30
    add  si, 0x25FC              ; SI = table row (9800-segment offset)
    mov  ax, 0x9800
    mov  es, ax
    xor  bx, bx
    ; clamp: if DX < 0 or DX < row[0], DX = row[0]   (9AA51-9AA5D)
    cmp  dx, 0
    jl   .clamp
    cmp  dx, [es:bx+si]
    jge  .scan
.clamp:
    mov  dx, [es:bx+si]
.scan:
    mov  cx, 7                   ; up to 7 checkpoint entries (9AA5E)
.loop:
    mov  ax, [es:bx+si]          ; AX = entry position
    cmp  dx, ax
    jb   .next                   ; DX < entry -> advance
    push cx
    mov  cx, [es:bx+si+2]        ; next entry position
    add  cx, [es:bx+si+0x12]     ; + adjustment word (as 9AA6D does)
    cmp  dx, cx
    pop  cx
    jnb  .next                   ; DX >= next+adj -> advance
    mov  ax, [es:bx+si]          ; bracketed: AX = this entry
    jmp  .found
.next:
    inc  bx
    inc  bx
    loop .loop
.found:
    mov  bx, [es:bx+si+0x20]     ; carrier id at the matching index (9AA7F)
    pop  es
    pop  si
    retf

; ============================================================
; AREA SELECT v6 — single-init: the cold-start stage init 9A8C9 loads
; directly at AREA_POS instead of loading at 0 and re-running the stock
; checkpoint restart 9AA88 on top (v5). v5 was correct but cost an extra
; ~0.55 s of frozen screen (measured: area start 1.3 s vs death restart
; 0.72 s) — the entire 9AA88 body ran a second sound-reset handshake and
; duplicate entity resets. v6 substitutes the position into 9A8C9's own
; calls, mirroring 9AA88's recipe piece by piece (all REAL functions, real
; arg patterns — nothing reimplemented):
;
;   9AA88 recipe                     v6 equivalent in 9A8C9
;   ─────────────────────────────    ──────────────────────────────────────
;   [9D58] = pos        (AAEB)       spawn_args_impl  (9A973 hook)
;   F594(row,30h,pos,0) (AAFD)       spawn_args_impl substitutes pos arg
;   B5DE(pos, 0)        (AB05)       scroll_init_impl (9A988 hook)
;   EF6C(stage, pos)    (AB4C)       loader_args_impl (9A9CB hook)
;   carrier F4BF + F594(1Ah,..)      area_start_impl  (9A9F5 hook)
;   (AB69-AB91)
;
; Unarmed (AREA_POS = 0) every hook degenerates to byte-identical stock
; behaviour. Weapon counters need no re-arming: only one round of AC0E
; inits runs now. BGM is single-path (no second 82FF reset).
; ============================================================

; SPAWN_ARGS_IMPL  (vec_spawn_args = B692:0068)
; Hook at 9A973, replacing PUSH 0 / PUSH 0 / PUSH 30h — the first three
; args of F594(row_ptr, 30h, pos, 0); pos slot was the hard-coded 0.
; Pops its own far return into scratch, pushes the args (with AREA_POS
; substituted) onto the CALLER's frame, and far-jumps back to 9A979
; (PUSH [cs:si] / CALL FAR A270:F594 continue as stock). Also performs
; 9AA88's [9D58]=pos write (AAEB) here, before F594, matching its order.
spawn_args_impl:
    pop  word [HOOK_RET_IP]
    pop  word [HOOK_RET_CS]
    mov  ax, [AREA_POS]
    test ax, ax
    jz   .push
    mov  [0x9D58], ax           ; restart-position base (9AA88's AAEB write)
.push:
    push word 0                 ; arg4 = 0
    push ax                     ; arg3 = position (0 unarmed = stock)
    push word 0x30              ; arg2 = 30h
    jmp  far [HOOK_RET_IP]

; SCROLL_INIT_IMPL  (vec_scroll_init = B692:0070)
; Hook at 9A988, replacing CALL FAR A270:02C6 (the caller's PUSH [9F5A] at
; 9A984 and ADD SP,2 at 9A98D are untouched). When armed, first calls the
; REAL scroll-transition 9B5DE(new=AREA_POS, old=0) — the exact call 9AA88
; makes at AB05 — via the SP4 gadget (9800:5820 = ADD SP,4 / RETF), which
; is how a 9800-segment near function with two stack args gets called from
; this segment. Then re-pushes [9F5A] and performs the 2C6 call itself
; (the caller's pushed copy sits below our far-return frame where 2C6
; cannot see it; the caller still cleans its own copy at 9A98D).
scroll_init_impl:
    cmp  word [AREA_POS], 0
    je   .stock
    push cs
    push word .stock
    push word 0                 ; arg2 (old pos)  -> [bp+6] in 9B5DE
    push word [AREA_POS]        ; arg1 (new pos)  -> [bp+4]
    push word SP4_GADGET        ; ADD SP,4 / RETF cleans args, RETFs to .stock
    jmp  0x9800:0x35DE          ; 9B5DE — real checkpoint scroll transition
.stock:
    push word [0x9F5A]          ; fresh read of the vblank counter arg
    call 0xA270:0x02C6
    add  sp, 2
    retf

; LOADER_ARGS_IMPL  (vec_loader_args = B692:0078)
; Hook at 9A9CB, replacing PUSH 0 / PUSH [bp+4] — the args of
; EF6C(stage, pos); pos was the hard-coded 0 (the literal source of the
; [83A]=0 bug). Same pop/push/far-jmp pattern as spawn_args_impl. BP still
; holds 9A8C9's frame (our far call doesn't touch it), so [bp+4] reads the
; caller's stage argument exactly as the original instruction did. EF6C is
; fully self-initializing from its args (verified: it re-derives all script
; cursors by scanning the stage tables each call), so seeking straight to
; AREA_POS on the first load is safe.
loader_args_impl:
    pop  word [HOOK_RET_IP]
    pop  word [HOOK_RET_CS]
    push word [AREA_POS]        ; pos (0 unarmed = stock PUSH 0)
    push word [bp+4]            ; stage (9A8C9's own argument)
    jmp  far [HOOK_RET_IP]      ; back to 9A9D0: CALL EF6C / ADD SP,4

; AREA_START_IMPL  (vec_area_start = B692:0060)
; Hook at 9A9F5, replacing the 6-byte MOV word [9F4E],2 that begins
; 9A8C9's presentation tail. When armed, performs the only 9AA88 pieces
; with no 9A8C9 counterpart — the item-carrier spawn (AB69-AB7F: F4BF with
; Y = pos+160h) and the restart entity seed F594(1Ah, 0, pos, 0Bh) (AB8C)
; — then consumes AREA_POS. The carrier id comes from area_ckpt_impl, the
; same table lookup the restart path uses (it also consumes AREA_POS for
; us, returning AX=pos, BX=carrier id). Runs after the loader + post-
; processing (9A9D6-9A9E1), matching the restart's ordering.
area_start_impl:
    cmp  word [AREA_POS], 0
    je   .done
    push cs
    call area_ckpt_impl         ; near call + pushed CS = far-call emulation
                                ; -> AX = position, BX = carrier id,
                                ;    AREA_POS consumed (one-shot)
    test bx, bx
    jz   .nocarrier
    mov  ax, [0x9D58]
    add  ax, 0x160
    push word 0x0B              ; object pool param
    push ax                     ; Y = position + 160h
    push bx                     ; carrier id
    push word 0x70              ; X = screen centre
    call 0xA270:0xF4BF          ; item carrier spawn (9AA88's AB7A)
    add  sp, 8
.nocarrier:
    push word 0x0B
    push word [0x9D58]
    push word 0
    push word 0x1A
    call 0xA270:0xF594          ; restart entity seed (9AA88's AB8C)
    add  sp, 8
.done:
    ; ── RANK: restore GAME_TIME and prime the difficulty ratchet ──
    ; [9F8E] was zeroed by 9A8C9's reset block (9A8EC) after the confirm
    ; code computed the scaled rank, so apply it here, after the zeroing.
    ; Then run the game's own difficulty recalc once — the two leaf
    ; functions 9800:7888 (rank/weapon indices -> [9F70]/[9F6C]) and
    ; 9800:798D (bullet-speed target -> [9F8C], params [9F78]/[9F7C]),
    ; normally invoked via the every-32-ticks wrapper at 9800:7860 (we
    ; skip the wrapper: its head also decrements unrelated timers).
    ; Finally snap the bullet-speed ratchet [9F7E] to the computed target
    ; [9F8C] — exactly what the stock checkpoint restart does at 9AB63.
    ; Without this the ratchet climbs ~1 step/recalc from 0, taking tens
    ; of seconds to reach a high-rank target (the "difficulty kicks in
    ; late" symptom).
    ; Gated on SS_USED (set at menu confirm, one-shot): EVERY menu start
    ; is primed — including rank 0, because the stage-start ratchet reset
    ; (9800:782F) is only called on COLD starts (9A9DB) and by the attract
    ; demo; the stage-ADVANCE initializer 9B305 never resets it, so in a
    ; real run the ratchet arrives at each stage already at target. Rank 0
    ; on loop 4 with a zero ratchet is a state that never occurs naturally.
    ; Plain no-menu games (SS_USED=0) keep the stock fresh ramp.
    cmp  word [SS_USED], 0
    je   .no_rank
    mov  word [SS_USED], 0      ; consume (one-shot)
    mov  ax, [RANK_VAL]
    mov  [0x9F8E], ax           ; GAME_TIME = scaled rank (0 for rank 0)
    push cs
    push word .rank_mid
    push word RETF_GADGET
    jmp  0x9800:0x7888          ; difficulty/rank index calc
.rank_mid:
    push cs
    push word .rank_back
    push word RETF_GADGET
    jmp  0x9800:0x798D          ; bullet-speed target calc
.rank_back:
    mov  ax, [0x9F8C]           ; freshly computed difficulty target
    mov  [0x9F7E], ax           ; prime ratchet (== 9AA88's AB63 behaviour)
.no_rank:

    ; FAIRY: the death-fairy trigger is simply the per-player STOCK
    ; COUNTER [player+0x24] (P1 9EF4 / P2 9F32) — found by decoding the
    ; return-address chain at the 0x2B spawn: the death sequence's
    ; 9800:39CE does CMP [bx+24],0 / DEC / spawn 0x2B (class 8).
    ; Collecting a fairy item increments it; death consumes one and
    ; runs the show. The old companion-object spawn machinery was never
    ; needed — bomb_fill (blob2) now writes FAIRY_VAR into the counter
    ; alongside the bomb array for starts and late joins alike.

    ; ITEM STOCK: write the bomb arrays ([aux+16..1D], 8 byte slots;
    ; value 1 = red/NUKE bomb -> entity 0x14, value 2 = yellow/CLUSTER
    ; -> entity 0x16; consumed highest-slot-first by A270:7FB6 on the
    ; bomb button). Defaults (3 x NUKE) replicate the player init's
    ; 01 01 01 exactly, so plain games are a byte-identical no-op.
    ; Logic lives in the second blob.
    call L2_SEG:L2_BOMBS

    ; Ship transformation check (big sprite + hitbox at main >= 5 / sub >= 3).
    ; Setting weapon levels directly skips the powerup path that normally
    ; triggers it. The game's own "levels set directly" implementations both
    ; apply it as two flag-sets on the live ship object:
    ;   - debug weapon editor (9C499-9C4CD): if main > 4 or sub > 2 ->
    ;     BX=[struct+4]; SET1 [BX+3C],bit6; OR [BX+8A],1   (per player)
    ;   - attract demo setup (98B36-98B43): same two flags after its 9AA88
    ;     restart, at exactly this point in the init flow (ship object
    ;     exists after the B971 spawns + F85C/FB11 post-processing).
    ; Self-gating: reads the APPLIED levels from the player structs, so a
    ; plain game (level 1) is untouched and both players are handled.
    mov  bx, 0x9ED0             ; P1 struct
    call transform_check
    mov  bx, 0x9F0E             ; P2 struct
    call transform_check
    mov  word [0x9F4E], 2       ; reconstruct absorbed MOV [9F4E],2
    retf

; TRANSFORM_CHECK — BX = player struct base. Near-called within this segment.
; Mirrors the debug weapon editor's threshold test and flag application.
transform_check:
    cmp  word [bx], 0           ; player active? ([9ED0]/[9F0E] != 0)
    je   .no
    cmp  word [bx+0x06], 5      ; vulcan  >= 5 ?
    jge  .yes
    cmp  word [bx+0x08], 5      ; laser   >= 5 ?
    jge  .yes
    cmp  word [bx+0x0A], 5      ; plasma  >= 5 ?
    jge  .yes
    cmp  word [bx+0x0E], 3      ; nuclear >= 3 ?
    jge  .yes
    cmp  word [bx+0x10], 3      ; homing  >= 3 ?
    jl   .no
.yes:
    mov  bx, [bx+0x04]          ; ship object pointer ([9ED4]/[9F12])
    test bx, bx
    jz   .no                    ; safety: object not spawned yet
    or   word [bx+0x3C], 0x40   ; == NEC SET1 [BX+3C],6 (9C4A9/98B3F)
    or   word [bx+0x8A], 1      ; (9C4AE/98B3A)
.no:
    ret

; ============================================================
; SPAWN_Y_APPLY_IMPL  (called via vec_spawn_y_apply = B692:0038)
; Hook at 9AE70 (replaces CMP [A012],0x00, reconstructed before return).
; ============================================================
spawn_y_apply_impl:
    ; Pure reconstruction. (Area select is triggered inside 9A8C9 at 9A9F5
    ; — see area_start_impl above.)
    cmp  word [0xA012], 0       ; reconstruct absorbed CMP [A012],0x00
    retf


; ============================================================
; BOOT_MENU_GATE  (reached via vec_boot_menu = B692:0018)
;
; Called from 9889E every non-gameplay frame. Replaces the
; original  MOV word [9F54], 1  (C7 06 54 9F 01 00, 6 bytes)
; which is reconstructed here before returning.
;
; ROM patch required:
;   9889E : 9A 18 00 92 B6 90   CALL FAR B692:0018 + NOP
;           (was: C7 06 54 9F 01 00  MOV [9F54],1)
;
; On the very first call (BOOT_DONE=0): show the boot options menu.
; On all subsequent calls: just reconstruct and return immediately.
; ============================================================
boot_menu_gate:
    ; Show boot menu once (BOOT_DONE starts at 0 = not yet shown).
    cmp  word [BOOT_DONE], 0
    jne  bmg_skip_menu

    ; First call: initialise scratch RAM, show boot menu.
    ; Zeroing BF28/2A (SPAWN_Y/SPAWN_Y_VAL) here ensures safety without stage select.
    mov  word [SPAWN_Y],      0
    mov  word [SPAWN_Y_VAL],  0
    mov  word [BOOT_DONE], 1
    ; Menu defaults come from the boot_defaults table (B692:0100) so
    ; end users can adjust them without touching this file — see the
    ; table's comment block and patch_roms.py's BOOT_DEFAULTS dict.
    xor  ah, ah
    cs   mov  al, [bd_debug]
    mov  [DEBUG_EN], ax
    cs   mov  al, [bd_stsel]
    mov  [STSEL_EN], ax
    cs   mov  al, [bd_region]
    mov  [REGION_VAR], ax
    cs   mov  al, [bd_rf]
    mov  [RF_RATE], ax
    cs   mov  al, [bd_bgm]
    mov  [BGM_VAR], ax
    cs   mov  al, [bd_logo]
    mov  [LOGO_VAR], ax
    cs   mov  al, [bd_wsu]
    mov  [WSU_VAR], ax
    mov  word [RF_CTR],  1       ; init counter (will reload on first trigger)
    call boot_menu
    ; Translate display index -> raw region byte, then write [9F67] directly.
    mov  bx, [REGION_VAR]
    shl  bx, 1
    cs   mov  ax, [bm_region_values + bx]
    mov  [REGION_VAR], ax
    cmp  al, 0xFF
    jne  short bmg_write_region
    xor  al, al
bmg_write_region:
    mov  [0x9F67], al

bmg_skip_menu:
    ; (The TITLE LOGO palette forcing lives in isr_rf_impl — this gate
    ; turned out to fire once per attract cycle, not per frame.)
    ; Reconstruct the clobbered instruction on every call.
    ; This is required by the main game loop (9AD4D checks [9F54]).
    mov  word [0x9F54], 1
bmg_done:
    retf

; ============================================================
; ENTRY  (reached via vec_stage_select JMP)
; Stack frame: [bp-2]=menu_item  [bp-4]=prev_p1p2  [bp-6]=prev_sys
;              [bp-8]=auto-confirm timer start tick (SS_TICKS, not stoppable)
; ============================================================
entry:
    push bp
    mov  bp, sp
    sub  sp, 8                  ; [bp-8] = auto-confirm timer start tick

    ; If stage select is disabled, go straight to default stage.
    ; (STSEL_EN is set by boot_menu_gate before the game starts.)
    cmp  word [STSEL_EN], 0
    je   default_stage

    ; Entry gesture: ANY player button (P1 A/B or P2 A/B) held while
    ; pressing either start. (The start press is what got us here — the
    ; 9AD50 hook fires inside 9AD4D for both P1 and P2 starts.)
    mov  ax, [P1P2_PORT]
    and  ax, 0x3030         ; P1 A/B (bits 4/5) + P2 A/B (bits 12/13), active-low
    cmp  ax, 0x3030
    je   default_stage      ; all released -> no gesture

    ; Button held → enter stage select
    mov  word [STAGE_VAR],  0
    mov  word [LOOP_VAR],   0
    mov  word [AREA_VAR],   0
    mov  word [PROG_VAR],   0
    mov  word [MW_VULCAN],  1   ; default: vulcan level 1 (ship must have a main weapon)
    mov  word [MW_LASER],   0
    mov  word [MW_PLASMA],  0
    mov  word [SW_NUCLEAR], 0
    mov  word [SW_HOMING],  0
    mov  word [MULTI_WPN],  0
    mov  word [BOMB_STOCK], 3   ; stock default: 3 bombs
    ; B.TYPE default follows the side that opened the menu: the stock
    ; game gives P1 red/NUKE bombs and P2 yellow/CLUSTER bombs, so a
    ; 2P-side start (2P START held in the entry gesture, 1P not)
    ; pre-selects CLUSTER. The row remains freely changeable.
    mov  word [BOMB_TYPE],  0   ; NUKE (P1-side default)
    mov  ax, [SYS_PORT]         ; active-low: bit0=1P start, bit1=2P start
    and  ax, 3
    cmp  ax, 1                  ; bit1 low (2P held), bit0 high (1P not)
    jne  .bt_done
    mov  word [BOMB_TYPE],  1   ; CLUSTER (2P-side default)
.bt_done:
    mov  word [FAIRY_VAR],  0
    mov  word [WEAPON_ARMED], 0
    mov  word [SW_ARMED],     0
    mov  word [MENU_LIVE],    0
    mov  word [BOMB_PEND],    0
    mov  word [SPAWN_Y],      0
    mov  word [SPAWN_Y_VAL],  0
    mov  word [RANK_VAL],     0
    mov  word [SS_USED],      0
    mov  word [bp-2], 0
    mov  word [bp-4], 0xFFFF
    mov  word [bp-6], 0xFFFF

wait_btn1:
    mov  ax, [P1P2_PORT]
    and  ax, 0x3030              ; wait until P1 A/B and P2 A/B all released
    cmp  ax, 0x3030
    jne  wait_btn1

    ; Wait for both STARTs to be released before drawing the menu.
wait_start:
    mov  ax, [SYS_PORT]
    and  ax, 0x0003              ; P1+P2 START released? (1 = released)
    cmp  ax, 0x0003
    jne  wait_start              ; still held -> keep waiting

    ; Play stage-select menu BGM (track 0x14, unused in normal gameplay)
    mov  ax, 0x8014
    call bgm_play

    ; Dim everything except the text layer, so the menu reads clearly while
    ; the screen behind stays faintly visible. Raiden 2 keeps a palette
    ; staging buffer at 1F00:0000 (the fade scripts run by 9800:8D81 write
    ; it with ES=1F00) which the vblank ISR uploads to the real palette
    ; every frame via COP DMA channel 15h. Layout (xBGR555, 2048 entries):
    ; sprites 000-3FF, tiles 400-6FF, TEXT 700-7FF (buffer offset 0E00+).
    ; Halve the RGB channels of entries 000-6FF: word >> 1, then AND 3DEFh
    ; to drop the bits that slid across the 5-bit channel boundaries.
    ; (For a darker menu, repeat the loop for 25%.) No restore is needed:
    ; nothing rewrites the buffer while our blocking loop runs, and the
    ; stage init's palette scripts (8DCD calls in 9A8C9) reload it wholesale
    ; after confirm.
    push es
    push si
    mov  ax, 0x1F00
    mov  es, ax
    xor  si, si
ss_dim_loop:
    mov  ax, [es:si]
    shr  ax, 1
    and  ax, 0x3DEF
    mov  [es:si], ax
    inc  si
    inc  si
    cmp  si, 0x0E00             ; stop before the text palettes (entry 700)
    jb   ss_dim_loop
    pop  si
    pop  es

    ; Clear all character VRAM before drawing the stage select menu.
    ; This removes any attract screen text (PUSH 1 OR 2 PLAYER BUTTON etc.)
    ; regardless of what game state was active when stage select was entered.
    call clear_vram

    call draw_menu

    mov  ax, [VBLANK_CTR]
    mov  [bp-8], ax              ; timer starts now (menu just became visible)

menu_loop:
    mov  ax, [VBLANK_CTR]
vblank_spin:
    cmp  ax, [VBLANK_CTR]
    je   vblank_spin

    ; ── auto-confirm timeout — runs regardless of input ──────
    ; (clobbers AX/CX/DX/SI via ss_draw_counter; placed before the
    ; input reads below, which reload everything)
    mov  ax, [VBLANK_CTR]
    sub  ax, [bp-8]              ; elapsed = now - start
    cmp  ax, SS_TICKS
    jae  ss_confirm              ; timed out -> accept current settings
    mov  cx, SS_TICKS
    sub  cx, ax                  ; remaining ticks
    mov  ax, cx
    xor  dx, dx
    mov  cx, 60
    div  cx                      ; AX = remaining seconds (60-0)
    call ss_draw_counter

    mov  bx, [P1P2_PORT]
    mov  cx, [SYS_PORT]

    mov  ax, bx
    not  ax
    and  ax, [bp-4]         ; newly-pressed P1P2

    mov  dx, cx
    not  dx
    and  dx, [bp-6]         ; newly-pressed SYS

    mov  [bp-4], bx
    mov  [bp-6], cx

    ; Merge P2 directional bits (8-11) into P1 positions (0-3)
    ; so either player can navigate the stage select menu.
    mov  bx, ax
    shr  bx, 8
    or   ax, bx
    ; Keep the edge masks in SI/DI: draw_menu and item_inc/item_dec
    ; clobber AX and DX, which used to corrupt the later direction/START
    ; tests (e.g. a decremented value with bit 3 set faked a RIGHT press
    ; that immediately undid the LEFT). SI/DI survive all callees here.
    mov  si, ax             ; SI = direction/button edge mask
    mov  di, dx             ; DI = START edge mask

    test si, 0x0001         ; P1 or P2 UP
    jz   chk_dn
    cmp  word [bp-2], 0
    jne  ss_up_dec
    mov  word [bp-2], NUM_ITEMS  ; wrap: top -> bottom (dec lands on last)
ss_up_dec:
    dec  word [bp-2]
    call draw_menu

chk_dn:
    test si, 0x0002         ; P1 or P2 DOWN
    jz   chk_lt
    mov  bx, [bp-2]
    cmp  bx, NUM_ITEMS-1
    jb   ss_dn_inc
    mov  word [bp-2], 0xFFFF     ; wrap: bottom -> top (inc lands on 0)
ss_dn_inc:
    inc  word [bp-2]
    call draw_menu

chk_lt:
    test si, 0x0004         ; P1 or P2 LEFT
    jz   chk_rt
    call item_dec
    call draw_menu

chk_rt:
    test si, 0x0008         ; P1 or P2 RIGHT
    jz   chk_ok
    call item_inc
    call draw_menu

chk_ok:
    test di, 0x0003         ; P1 or P2 START
    jnz  ss_confirm
    test si, 0x0030         ; P1 or P2 A or B (bits 4/5, merged from P2 bits 12/13)
    jz   menu_loop
ss_confirm:

    call erase_menu
    ; Stop menu BGM before stage init runs its own sound reset.
    mov  ax, 0x82FF
    call bgm_play
    call resolve_area_pos   ; returns AX = checkpoint position
    mov  word [AREA_POS], ax
    ; Scale PROG_VAR (0-F) to GAME_TIME [9F8E]:
    ;   divisor = LOOP_VAR*8 + stage_table[STAGE_VAR]   (mirrors the difficulty calc)
    ;   GAME_TIME = PROG_VAR * divisor
    ; stage_table lives at 9800:7444, one byte per stage (indexed by STAGE_VAR).
    push bx
    push es
    push dx
    mov  ax, 0x9800
    mov  es, ax
    mov  bx, [STAGE_VAR]
    mov  al, es:[bx + 0x7444]  ; al = stage_factor = stage_table[STAGE_VAR]
    xor  ah, ah                ; ax = stage_factor
    mov  bx, [LOOP_VAR]
    shl  bx, 3                 ; bx = LOOP_VAR * 8
    add  bx, ax                ; bx = LOOP*8 + stage_factor  (= difficulty divisor)
    mov  ax, [PROG_VAR]        ; ax = 0–F
    mul  bx                    ; dx:ax = PROG_VAR * divisor
    mov  [RANK_VAL], ax        ; staged for area_start_impl. (Writing
                               ; [GAME_TIME]/[9F8E] directly here was a bug:
                               ; 9A8C9 zeroes [9F8E] at 9A8EC AFTER this
                               ; confirm code runs, so the rank was lost and
                               ; every start began at difficulty index 0.)
    pop  dx
    pop  es
    pop  bx

    ; ── Write weapon levels to player structs ─────────────────────────────────
    ; Write weapon levels to both P1 and P2 structs.
    ; A new player joining later will be re-initialised by 9AC0E anyway.

    ; Enforce: if all main weapons are 0, set vulcan=1 so the ship has a weapon.
    mov  ax, [MW_VULCAN]
    or   ax, [MW_LASER]
    or   ax, [MW_PLASMA]
    jnz  wpn_has_main
    mov  word [MW_VULCAN], 1
wpn_has_main:

    call write_p1_weapons
    call write_p2_weapons

wpn_done:
    ; Arm the one-shot weapon override flag. ck_override will apply the
    ; configured weapon levels to the player structs on the next 9AC0E call
    ; and then clear this flag, so respawns use game defaults.
    mov  word [WEAPON_ARMED], 3  ; pending bitmask: bit0=P1, bit1=P2. Each bit is
                                 ; cleared by the per-frame tick (L2_BJOIN) once
                                 ; that player is ACTIVE, so only a player's
                                 ; first arrival (cold start or late join) gets
                                 ; the loadout — deaths, game-over cleanup and
                                 ; CONTINUES re-init stock (vulcan-1).
    mov  word [MENU_LIVE],    1  ; menu game live: late joins get the loadout too
    jmp  menu_done

; ── write_p1_weapons / write_p2_weapons ──────────────────────────────────────
write_p1_weapons:
    mov  al, byte [MW_VULCAN]
    mov  byte [0x9ED6], al
    mov  al, byte [MW_LASER]
    mov  byte [0x9ED8], al
    mov  al, byte [MW_PLASMA]
    mov  byte [0x9EDA], al
    mov  al, byte [SW_NUCLEAR]
    mov  byte [0x9EDE], al
    mov  al, byte [SW_HOMING]
    mov  byte [0x9EE0], al
    ret

write_p2_weapons:
    mov  al, byte [MW_VULCAN]
    mov  byte [0x9F14], al
    mov  al, byte [MW_LASER]
    mov  byte [0x9F16], al
    mov  al, byte [MW_PLASMA]
    mov  byte [0x9F18], al
    mov  al, byte [SW_NUCLEAR]
    mov  byte [0x9F1C], al
    mov  al, byte [SW_HOMING]
    mov  byte [0x9F1E], al
    ret

; ============================================================
; ENFORCE_SINGLE  — called by item_inc/item_dec after changing a weapon level.
; If MULTI_WPN=0 (OFF) and a weapon was just set to non-zero,
; zero out all other weapons in the same group (main or sub).
;   BX = address of the var that just changed
; ============================================================
enforce_single:
    cmp  word [MULTI_WPN], 0
    jne  es_done            ; multi weapons ON -> no enforcement

    ; Check if the changed value is now non-zero
    mov  ax, [bx]
    test ax, ax
    jz   es_done            ; value is 0, nothing to enforce

    ; Is this a main weapon? (MW_VULCAN, MW_LASER, MW_PLASMA)
    cmp  bx, MW_VULCAN
    je   es_zero_main
    cmp  bx, MW_LASER
    je   es_zero_main
    cmp  bx, MW_PLASMA
    je   es_zero_main

    ; Is this a sub weapon? (SW_NUCLEAR, SW_HOMING)
    cmp  bx, SW_NUCLEAR
    je   es_zero_sub
    cmp  bx, SW_HOMING
    je   es_zero_sub
    jmp  es_done

es_zero_main:
    ; Zero all main weapons except the one at BX
    cmp  bx, MW_VULCAN
    je   es_zm_skip_v
    mov  word [MW_VULCAN], 0
es_zm_skip_v:
    cmp  bx, MW_LASER
    je   es_zm_skip_l
    mov  word [MW_LASER], 0
es_zm_skip_l:
    cmp  bx, MW_PLASMA
    je   es_done
    mov  word [MW_PLASMA], 0
    jmp  es_done

es_zero_sub:
    ; Zero all sub weapons except the one at BX
    cmp  bx, SW_NUCLEAR
    je   es_zs_skip_n
    mov  word [SW_NUCLEAR], 0
es_zs_skip_n:
    cmp  bx, SW_HOMING
    je   es_done
    mov  word [SW_HOMING], 0

es_done:
    ret

default_stage:
    mov  word [STAGE_VAR], 0
    mov  word [AREA_VAR],  0
    mov  word [PROG_VAR],  0
    mov  word [AREA_POS],  0   ; no area override — ck_override will be a no-op
    mov  word [RANK_VAL],  0   ; no rank override — stock difficulty ramp
    mov  word [SS_USED],   0   ; not a menu start
    mov  word [MULTI_WPN], 0   ; plain game: stock bullet budget rules apply
    mov  word [BOMB_STOCK], 3  ; plain game: the apply writes exactly the
    mov  word [BOMB_TYPE],  0  ; stock loadout (3 x red bomb), a no-op
    mov  word [FAIRY_VAR], 0   ; plain game: no fairy stock
    mov  word [MENU_LIVE], 0   ; plain game: no late-join loadout
    mov  word [BOMB_PEND], 0
    mov  sp, bp
    pop  bp
    retf                       ; return without clearing inputs or touching STSEL_EN

menu_done:
    mov  word [SS_USED], 1     ; menu start: area_start_impl primes difficulty
    ; NOTE: STSEL_EN deliberately stays 1. (An earlier debugging version
    ; cleared it here, but the boot menu — the only thing that re-enables it
    ; — runs once per power-on, so stage select became unreachable after the
    ; first credit. Accidental re-entry is not a concern: entry requires P1
    ; BTN1 to be held at game start, otherwise default_stage is taken.)
    ; NOTE: do NOT clear [9DC0]/[9DC2] here. The START press used to confirm
    ; stage select must remain in [9DC0] so 98E65 (TEST [9DC0],0x8000) can
    ; decrement [9F4C] properly. Without this, attract never plays after
    ; a credit in coin mode.
    mov  sp, bp
    pop  bp
    retf

; ============================================================
; CK_OVERRIDE  (reached via vec_ck_override CALL FAR B692:0008 from 9AC35)
;
; Replaces the 6 bytes at 9AC35–9AC3A inside scroll struct initialiser 9AC0E:
;   9AC35: 89 47 0A   MOV [BX+0A], AX   <- scroll Y start position (AX=0)
;   9AC38: 89 47 0C   MOV [BX+0C], AX   <- next field (also 0); absorbed for size
;
; Patched to:
;   9AC35: 9A 08 00 92 B6   CALL FAR B692:0008
;   9AC3A: 90               NOP
;
; On entry (from CALL FAR):
;   AX  = 0  (was about to be written as scroll Y)
;   BX  = pointer to scroll struct (CS:[CS:6E46 + layer_idx*2])
;   CS  = B692, DS = 0
;   BP  = caller's BP (9AC0E's frame: [BP+4]=type, [BP+6]=layer index)
;
; 9AC0E is called TWICE per stage load targeting the SAME scroll struct:
;   Call 1 — 9A994: push 0 / push 0  -> [BP+4]=0, [BP+6]=0
;   Call 2 — 9A99A: push 1 / push 0  -> [BP+4]=1, [BP+6]=0
; Both load the same struct ptr (layer index 0 both times), so without care
; Call 2's write of AX=0 to [BX+0A] would undo Call 1's override.
;
; Behaviour:
;   If AREA_POS != 0:
;     Write 0 to [BX+0A]  (scroll struct Y offset = 0, same as checkpoint restart)
;     If [BP+4] == 0 (first call): set scroll layer bases directly to AREA_POS
;       [B14A] = [B14E] = [B152] = AREA_POS   (each layer base = checkpoint Y)
;       [9FA6] = [9FA8] = [9FAA] = 0           (window offset = 0)
;       The checkpoint restart does: [B14X] = ([B14X]-Y)&0x1F0 + Y (via 9B5DE).
;       That formula assumes [B14X] is already non-zero (level scrolling).
;       For a fresh game, [B14X]=0, so the equivalent is simply [B14X]=AREA_POS, [9FXX]=0.
;     If [BP+4] == 1 (second call): clear AREA_POS
;     Zero AX, jump to cko_write_0C
;   Else (AREA_POS == 0):
;     Write AX (=0) to [BX+0A] as normal
;   cko_write_0C:
;     Write AX (=0) to [BX+0C]  (reconstructs absorbed instruction)
;     RETF to 9AC3B with AX=0
; ============================================================
ck_override:
    ; Pure reconstruction now. The area-select injection moved to
    ; area_ckpt_impl (9AADD hook inside 9AA88), which substitutes AREA_POS at
    ; the exact moment the restart position is resolved — immune to the
    ; [A00E] tracker (9B8DA) and to hook-ordering races that defeated every
    ; earlier design. Weapon overrides below are unchanged.
    mov  word [bx+0x0A], ax     ; absorbed: MOV [BX+0A],AX (AX=0)

cko_write_0C:
    ; Reconstruct absorbed instruction: MOV [BX+0C], AX (AX=0 in both paths)
    mov  word [bx+0x0C], ax

    ; ── Main weapon override ─────────────────────────────────────────────────
    ; WEAPON_ARMED is a per-player pending bitmask consumed on activation.
    ; Write via BX so each player's weapons are applied in their OWN 9AC0E call,
    ; preventing 9AC0E's own default writes from overwriting us.
    ; Logic relocated to the second blob (main_override_impl, B581:0068)
    ; for space. Far JMP: its RETF returns straight to the hook caller.
    ; Contract preserved: BX = player struct, AX = 0 on entry and exit.
    jmp  L2_SEG:L2_MAINOVR

; ============================================================
; BOOT_MENU  — shown once at power-on before any game starts.
;
; Displays two toggles with a 10-second auto-confirm timeout:
;   DEBUG MENU  : ON / OFF   (controls DEBUG_EN  at BF0A)
;   STAGE SELECT: ON / OFF   (controls STSEL_EN  at BF0C)
;
; Controls (active-low P1P2_PORT / SYS_PORT, edge-detected):
;   UP / DOWN   : move cursor between the two items
;   LEFT / RIGHT: toggle selected item
;   P1 START    : confirm immediately
;
; Countdown uses VBLANK_CTR (increments each vblank = ~60 Hz).
; After BOOT_TICKS (600 = 10 s) the current selection is accepted.
;
; Stack frame: [bp-2] = cursor (0=DEBUG 1=STSEL 2=RF 3=REGION 4=LOGO 5=SOUND)
;              [bp-4] = prev P1P2 (for edge detect)
;              [bp-6] = prev SYS  (for edge detect)
;              [bp-8] = tick_start (VBLANK_CTR snapshot)
; ============================================================
boot_menu:
    push bp
    mov  bp, sp
    sub  sp, 8

    mov  word [bp-2], 0          ; cursor starts on DEBUG_EN row
    mov  word [bp-4], 0xFFFF
    mov  word [bp-6], 0xFFFF
    mov  ax, [VBLANK_CTR]
    mov  [bp-8], ax              ; snapshot tick counter

    call bm_draw                 ; initial draw

bm_loop:
    ; ── vblank sync ─────────────────────────────────────────
    mov  ax, [VBLANK_CTR]
bm_vblank:
    cmp  ax, [VBLANK_CTR]
    je   bm_vblank

    ; ── timeout check ───────────────────────────────────────
    cmp  word [bp-8], BOOT_NO_TMR
    je   bm_timeout_skip         ; timer stopped, never time out
    mov  ax, [VBLANK_CTR]
    sub  ax, [bp-8]              ; elapsed = now - start
    cmp  ax, BOOT_TICKS
    jae  bm_done                 ; timed out -> accept current settings
bm_timeout_skip:

    ; ── countdown display (skip if timer stopped) ───────────
    cmp  word [bp-8], BOOT_NO_TMR
    je   bm_ctr_skip
    mov  cx, BOOT_TICKS
    sub  cx, ax                  ; cx = remaining ticks
    mov  ax, cx
    xor  dx, dx
    mov  cx, 60
    div  cx                      ; ax = remaining seconds (0-10)
    call bm_draw_counter         ; update counter display
bm_ctr_skip:

    ; ── edge-detect inputs ──────────────────────────────────
    mov  bx, [P1P2_PORT]
    mov  cx, [SYS_PORT]

    mov  ax, bx
    not  ax
    and  ax, [bp-4]              ; newly-pressed P1P2
    mov  dx, cx
    not  dx
    and  dx, [bp-6]              ; newly-pressed SYS
    mov  [bp-4], bx
    mov  [bp-6], cx

    ; ── stop timer permanently on any input ─────────────────
    mov  bx, ax
    or   bx, dx
    jz   bm_no_input
    cmp  word [bp-8], BOOT_NO_TMR  ; already stopped? (don't re-erase every frame)
    je   bm_no_input
    mov  word [bp-8], BOOT_NO_TMR  ; sentinel: never time out
    ; Blank the TIMER row so the frozen countdown disappears
    push es
    push di
    push cx
    mov  cx, VRAM_SEG
    mov  es, cx
    mov  di, VOFF(ROW_BOOT_CTR, 11)
    mov  cx, 14                    ; "TIMER: XX" = 9 chars + some margin
bm_tmr_clr:
    mov  word es:[di], 0x0000
    add  di, CHAR_ADV
    loop bm_tmr_clr
    pop  cx
    pop  di
    pop  es
bm_no_input:

    ; ── navigation ──────────────────────────────────────────
    ; Merge P2 directional bits (8-11) into P1 positions (0-3)
    ; so either player can navigate. (The same OR also merges P2 A/B
    ; edges, bits 12/13, into the P1 A/B positions 4/5.)
    mov  bx, ax
    shr  bx, 8                  ; shift P2 bits 8-11 down to bits 0-3
    or   ax, bx                 ; combine: ax bits 0-3 now = P1 or P2 dirs

    ; ── SOUND TEST: A/B on that row plays the selected track ──
    ; Edge-triggered (one play per press). Done here, before bm_left/
    ; bm_right can clobber the edge mask in AX. A sound reset (82FF)
    ; precedes the track command so looping tracks (drum loops etc.)
    ; stop instead of layering under the new selection — same
    ; reset-then-track ordering the stage init uses.
    cmp  word [bp-2], 5          ; cursor 5 = SOUND TEST
    jne  bm_no_bgm_play
    test ax, 0x0030              ; P1 or P2 A/B newly pressed (merged)
    jz   bm_no_bgm_play
    push ax
    mov  ax, 0x82FF              ; sound reset: stop everything first
    call bgm_play
    mov  ax, [BGM_VAR]
    xor  ah, ah
    or   ax, 0x8000              ; sound command: play track AL
    call bgm_play
    pop  ax
bm_no_bgm_play:

    test ax, 0x0001              ; P1 or P2 UP
    jz   bm_chk_dn
    cmp  word [bp-2], 0
    jne  bm_up_dec
    mov  word [bp-2], 7          ; wrap: top -> bottom (dec lands on 6)
bm_up_dec:
    dec  word [bp-2]
    call bm_draw

bm_chk_dn:
    test ax, 0x0002              ; P1 or P2 DOWN
    jz   bm_chk_lt
    cmp  word [bp-2], 6          ; last row = 6 (WPN UPGRADE)
    jb   bm_dn_inc
    mov  word [bp-2], 0xFFFF     ; wrap: bottom -> top (inc lands on 0)
bm_dn_inc:
    inc  word [bp-2]
    call bm_draw

bm_chk_lt:
    test ax, 0x0004              ; P1 or P2 LEFT
    jz   bm_chk_rt
    push ax                      ; bm_left returns the new value in AX —
    call bm_left                 ; without this, a result with bit 3 set
    call bm_draw                 ; (e.g. 5A after wrapping 00->5A) faked a
    pop  ax                      ; RIGHT press and immediately undid it
bm_chk_rt:
    test ax, 0x0008              ; P1 or P2 RIGHT
    jz   bm_chk_ok
    call bm_right
    call bm_draw

bm_chk_ok:
    ; Accept any of: P1 START, P2 START (with release wait),
    ; or P1/P2 A/B buttons (immediate exit — won't trigger free-play auto-start).
    ; EXCEPTION: on the SOUND TEST row (cursor 5), A/B plays the selected
    ; track instead (handled above) and must not exit the menu.
    cmp  word [bp-2], 5
    je   bm_chk_start

    ; Check P1 A or B (P1P2_PORT bits 4/5, mask 0x0030, active-low: 0=held)
    ; Any bit being 0 means that button is held.
    mov  ax, [P1P2_PORT]
    not  ax                      ; invert: held buttons now have bit=1
    test ax, 0x0030              ; P1 A or B held?
    jnz  bm_done                 ; yes -> exit immediately

    ; Check P2 A or B (P1P2_PORT bits 12/13, mask 0x3000, active-low)
    test ax, 0x3000              ; P2 A or B held?
    jnz  bm_done                 ; yes -> exit immediately

bm_chk_start:
    ; Check P1 START (SYS_PORT bit 0, active-low)
    mov  ax, [SYS_PORT]
    test ax, 0x0001              ; P1 START held?
    jnz  bm_chk_p2start          ; not held -> check P2 START
    ; P1 START held -> wait for release before exiting
bm_wait_p1_release:
    mov  ax, [SYS_PORT]
    test ax, 0x0001
    jz   bm_wait_p1_release
    jmp  bm_done

bm_chk_p2start:
    ; Check P2 START (SYS_PORT bit 1, active-low)
    test ax, 0x0002              ; P2 START held?
    jnz  bm_loop                 ; not held -> keep looping
    ; P2 START held -> wait for release before exiting
bm_wait_p2_release:
    mov  ax, [SYS_PORT]
    test ax, 0x0002
    jz   bm_wait_p2_release

bm_done:
    call bm_erase
    mov  sp, bp
    pop  bp
    ret

; ── bm_left / bm_right ───────────────────────────────────────
; Cursor map: 0=DEBUG 1=STSEL 2=RF 3=REGION 4=TITLE LOGO 5=SOUND TEST
bm_left:
    cmp  word [bp-2], 6
    je   short bm_wsu_toggle
    cmp  word [bp-2], 5
    je   short bm_left_bgm
    cmp  word [bp-2], 4
    je   short bm_left_logo
    cmp  word [bp-2], 3
    je   short bm_left_region
    cmp  word [bp-2], 2
    je   short bm_left_rf
    cmp  word [bp-2], 0
    je   short bm_left_dbg
    xor  word [STSEL_EN], 1      ; toggle 0<->1
    ret
bm_left_logo:
    xor  word [LOGO_VAR], 1      ; toggle WHITE<->COLOR
    ret
bm_left_bgm:
    mov  ax, [BGM_VAR]
    test ax, ax
    jnz  short bm_left_bgm_dec
    mov  ax, BGM_MAX + 1         ; wrap: 00 -> 5A
bm_left_bgm_dec:
    dec  ax
    mov  [BGM_VAR], ax
    ret
bm_left_dbg:
    xor  word [DEBUG_EN], 1      ; toggle 0<->1
    ret
bm_left_rf:
    mov  ax, [RF_RATE]
    test ax, ax
    jnz  short bm_left_rf_dec
    mov  ax, NUM_RF_RATES
bm_left_rf_dec:
    dec  ax
    mov  [RF_RATE], ax
    ret
bm_left_region:
    mov  ax, [REGION_VAR]
    test ax, ax
    jnz  short bm_left_dec
    mov  ax, NUM_REGIONS        ; wrap: 0 -> NUM_REGIONS
bm_left_dec:
    dec  ax
    mov  [REGION_VAR], ax
    ret

bm_wsu_toggle:
    xor  word [WSU_VAR], 1       ; toggle ON<->OFF (shared by left/right)
    ret

bm_right:
    cmp  word [bp-2], 6
    je   short bm_wsu_toggle
    cmp  word [bp-2], 5
    je   short bm_right_bgm
    cmp  word [bp-2], 4
    je   short bm_right_logo
    cmp  word [bp-2], 3
    je   short bm_right_region
    cmp  word [bp-2], 2
    je   short bm_right_rf
    cmp  word [bp-2], 0
    je   short bm_right_dbg
    xor  word [STSEL_EN], 1      ; toggle 0<->1
    ret
bm_right_logo:
    xor  word [LOGO_VAR], 1      ; toggle WHITE<->COLOR
    ret
bm_right_bgm:
    mov  ax, [BGM_VAR]
    inc  ax
    cmp  ax, BGM_MAX
    jbe  short bm_right_bgm_store
    xor  ax, ax                  ; wrap: 5A -> 00
bm_right_bgm_store:
    mov  [BGM_VAR], ax
    ret
bm_right_dbg:
    xor  word [DEBUG_EN], 1      ; toggle 0<->1
    ret
bm_right_rf:
    mov  ax, [RF_RATE]
    inc  ax
    cmp  ax, NUM_RF_RATES
    jb   short bm_right_rf_store
    xor  ax, ax
bm_right_rf_store:
    mov  [RF_RATE], ax
    ret
bm_right_region:
    mov  ax, [REGION_VAR]
    inc  ax
    cmp  ax, NUM_REGIONS
    jb   short bm_right_store
    xor  ax, ax                 ; wrap
bm_right_store:
    mov  [REGION_VAR], ax
    ret

; ── bm_draw — redraw the whole boot menu ─────────────────────
bm_draw:
    push es
    push di
    push si
    push ax
    push bx
    push cx
    push dx

    mov  ax, VRAM_SEG
    mov  es, ax

    ; Header
    mov  di, VOFF(ROW_BOOT_HDR, 5)
    mov  si, bm_str_header
    mov  ah, ATTR_RED
    call write_str

    ; "DEBUG MENU" row
    mov  ah, ATTR
    cmp  word [bp-2], 0
    jne  bm_draw_dbg_attr
    mov  ah, ATTR_HI
bm_draw_dbg_attr:
    mov  di, VOFF(ROW_BOOT_DBG, 7)
    mov  si, bm_str_debug
    call write_str
    ; value ON/OFF
    mov  di, VOFF(ROW_BOOT_DBG, 21)
    cmp  word [DEBUG_EN], 0
    je   bm_draw_dbg_off
    mov  si, bm_str_on
    jmp  bm_draw_dbg_val
bm_draw_dbg_off:
    mov  si, bm_str_off
bm_draw_dbg_val:
    call write_str

    ; "STAGE SELECT" row
    mov  ah, ATTR
    cmp  word [bp-2], 1
    jne  bm_draw_ss_attr
    mov  ah, ATTR_HI
bm_draw_ss_attr:
    mov  di, VOFF(ROW_BOOT_SS, 7)
    mov  si, bm_str_stsel
    call write_str
    ; value ON/OFF
    mov  di, VOFF(ROW_BOOT_SS, 21)
    cmp  word [STSEL_EN], 0
    je   bm_draw_ss_off
    mov  si, bm_str_on
    jmp  bm_draw_ss_val
bm_draw_ss_off:
    mov  si, bm_str_off
bm_draw_ss_val:
    call write_str

    ; "RAPID FIRE" row
    mov  ah, ATTR
    cmp  word [bp-2], 2
    jne  short bm_draw_rf_attr
    mov  ah, ATTR_HI
bm_draw_rf_attr:
    mov  di, VOFF(ROW_BOOT_RF, 7)
    mov  si, bm_str_rf
    call write_str
    ; Clear 4 chars at value column before writing (erase any longer previous value)
    mov  di, VOFF(ROW_BOOT_RF, 21)
    mov  cx, 4
bm_draw_rf_clr:
    mov  word es:[di], 0x0000
    add  di, CHAR_ADV
    loop bm_draw_rf_clr
    mov  di, VOFF(ROW_BOOT_RF, 21)
    mov  bx, [RF_RATE]
    shl  bx, 1
    cs   mov  si, [bm_rf_names + bx]
    call write_str

    ; "REGION" label row + name on separate row
    mov  ah, ATTR
    cmp  word [bp-2], 3
    jne  short bm_draw_rg_attr
    mov  ah, ATTR_HI
bm_draw_rg_attr:
    mov  di, VOFF(ROW_BOOT_RG, 7)
    mov  si, bm_str_region
    call write_str
    ; Clear the value row (20 chars) before writing name, to erase old longer text
    mov  di, VOFF(ROW_BOOT_RGVAL, 7)
    mov  cx, 20
bm_draw_rg_clr:
    mov  word es:[di], 0x0000
    add  di, CHAR_ADV
    loop bm_draw_rg_clr
    ; Write region name
    mov  di, VOFF(ROW_BOOT_RGVAL, 7)
    mov  bx, [REGION_VAR]
    shl  bx, 1
    cs   mov  si, [bm_region_names + bx]
    call write_str

    ; "TITLE LOGO" row + WHITE/COLOR value
    mov  ah, ATTR
    cmp  word [bp-2], 4
    jne  short bm_draw_logo_attr
    mov  ah, ATTR_HI
bm_draw_logo_attr:
    mov  di, VOFF(ROW_BOOT_LOGO, 7)
    mov  si, bm_str_logo
    call write_str
    mov  di, VOFF(ROW_BOOT_LOGO, 21)
    mov  si, bm_str_lwhite
    cmp  word [LOGO_VAR], 0
    je   short bm_draw_logo_val
    mov  si, bm_str_lcolor
bm_draw_logo_val:
    call write_str

    ; "SOUND TEST" row + 2-digit hex track number
    mov  ah, ATTR
    cmp  word [bp-2], 5
    jne  short bm_draw_bgm_attr
    mov  ah, ATTR_HI
bm_draw_bgm_attr:
    mov  di, VOFF(ROW_BOOT_BGM, 7)
    mov  si, bm_str_bgm
    call write_str
    mov  di, VOFF(ROW_BOOT_BGM, 21)
    mov  al, [BGM_VAR]
    push ax
    shr  al, 4
    call bm_hexdigit
    pop  ax
    and  al, 0x0F
    call bm_hexdigit

    ; "WPN UPGRADE" row + ON/OFF value
    mov  ah, ATTR
    cmp  word [bp-2], 6
    jne  short bm_draw_wsu_attr
    mov  ah, ATTR_HI
bm_draw_wsu_attr:
    mov  di, VOFF(ROW_BOOT_WSU, 7)
    mov  si, bm_str_wsu
    call write_str
    mov  di, VOFF(ROW_BOOT_WSU, 21)
    cmp  word [WSU_VAR], 0
    je   short bm_draw_wsu_off
    mov  si, bm_str_on
    jmp  short bm_draw_wsu_val
bm_draw_wsu_off:
    mov  si, bm_str_off
bm_draw_wsu_val:
    call write_str

    ; Hint
    mov  ah, ATTR
    mov  di, VOFF(ROW_BOOT_HINT, 3)
    mov  si, bm_str_hint
    call write_str

    ; Version string (bottom right, always dim/normal attr)
    mov  ah, ATTR
    mov  di, VOFF(ROW_BOOT_VER, 0x11)
    mov  si, bm_str_ver
    call write_str

    ; Tooltip lines (cursor-dependent)
    call bm_draw_tooltip

    pop  dx
    pop  cx
    pop  bx
    pop  ax
    pop  si
    pop  di
    pop  es
    ret

; ── bm_hexdigit — write one hex digit ────────────────────────
; Input: AL = nibble (0-F), AH = attribute, ES:DI = cell.
; Advances DI by one cell.
bm_hexdigit:
    cmp  al, 9
    jbe  short bm_hex_dig
    add  al, 'A' - 10
    jmp  short bm_hex_wr
bm_hex_dig:
    add  al, '0'
bm_hex_wr:
    mov  byte es:[di],   al
    mov  byte es:[di+1], ah
    add  di, CHAR_ADV
    ret

; ── ss_draw_counter — stage-select countdown (row ROW_SS_CTR) ─
; Input: AX = remaining seconds (0-60). Same "TIMER: XX" format as
; the boot menu's bm_draw_counter, drawn below the menu.
; Clobbers CX/DX/SI (callers reload them).
ss_draw_counter:
    push es
    push di
    push bx
    push ax

    mov  bx, ax                     ; save seconds count in BX
    mov  cx, VRAM_SEG
    mov  es, cx

    mov  di, VOFF(ROW_SS_CTR, 11)
    mov  si, bm_str_timer
    mov  ah, ATTR
    call write_str

    mov  di, VOFF(ROW_SS_CTR, 18)
    mov  ax, bx
    xor  dx, dx
    mov  cx, 10
    div  cx                         ; AX=tens, DX=units
    add  al, '0'
    mov  byte es:[di],   al
    mov  byte es:[di+1], ATTR
    add  di, CHAR_ADV
    mov  al, dl
    add  al, '0'
    mov  byte es:[di],   al
    mov  byte es:[di+1], ATTR

    pop  ax
    pop  bx
    pop  di
    pop  es
    ret

; ── bm_draw_counter — update the seconds countdown ───────────
; Input: AX = remaining seconds (0-10)
bm_draw_counter:
    push es
    push di
    push bx
    push ax

    mov  bx, ax                     ; save seconds count in BX
    mov  cx, VRAM_SEG
    mov  es, cx

    ; Write "TIMER: " label
    mov  di, VOFF(ROW_BOOT_CTR, 11)
    mov  si, bm_str_timer
    mov  ah, ATTR
    call write_str

    ; Tens digit (BX = 0-10, word divide)
    mov  di, VOFF(ROW_BOOT_CTR, 18)
    mov  ax, bx
    xor  dx, dx
    mov  cx, 10
    div  cx                         ; AX=quotient (tens), DX=remainder (units)
    add  al, '0'
    mov  byte es:[di],   al
    mov  byte es:[di+1], ATTR
    add  di, CHAR_ADV
    ; Units digit
    mov  al, dl
    add  al, '0'
    mov  byte es:[di],   al
    mov  byte es:[di+1], ATTR

    pop  ax
    pop  bx
    pop  di
    pop  es
    ret

; ── bm_draw_tooltip — draw cursor-dependent tooltip lines ─────
; Clears both tooltip rows then draws strings for current cursor position.
; Uses [bp-2] for cursor. Preserves all registers.
bm_draw_tooltip:
    push es
    push si
    push di
    push cx
    push ax
    push bx

    mov  ax, VRAM_SEG
    mov  es, ax
    mov  ah, ATTR

    ; Clear all five tooltip rows (32 chars each)
    mov  di, VOFF(ROW_BOOT_TT0, 0)
    mov  cx, 32
bm_tt_clr0:
    mov  word es:[di], 0x0000
    add  di, CHAR_ADV
    loop bm_tt_clr0
    mov  di, VOFF(ROW_BOOT_TT1, 0)
    mov  cx, 32
bm_tt_clr1:
    mov  word es:[di], 0x0000
    add  di, CHAR_ADV
    loop bm_tt_clr1
    mov  di, VOFF(ROW_BOOT_TT2, 0)
    mov  cx, 32
bm_tt_clr2:
    mov  word es:[di], 0x0000
    add  di, CHAR_ADV
    loop bm_tt_clr2
    mov  di, VOFF(ROW_BOOT_TT3, 0)
    mov  cx, 32
bm_tt_clr3:
    mov  word es:[di], 0x0000
    add  di, CHAR_ADV
    loop bm_tt_clr3
    mov  di, VOFF(ROW_BOOT_TT4, 0)
    mov  cx, 32
bm_tt_clr4:
    mov  word es:[di], 0x0000
    add  di, CHAR_ADV
    loop bm_tt_clr4

    ; Look up string pair for current cursor row
    mov  bx, [bp-2]             ; cursor position (0-3)
    shl  bx, 1                  ; each entry = 2 bytes (word offset)
    cs   mov  si, [bm_tt_line1 + bx]
    test si, si
    jz   bm_tt_done             ; null pointer -> no tooltip

    ; Title line ("HOW TO USE xxx:")
    cs   mov  si, [bm_tt_title + bx]
    cs   mov  di, [bm_tt_col0 + bx]
    call write_str

    ; Line 1
    cs   mov  si, [bm_tt_line1 + bx]
    cs   mov  di, [bm_tt_col1 + bx]
    call write_str

    ; Line 2
    cs   mov  si, [bm_tt_line2 + bx]
    test si, si
    jz   bm_tt_done
    cs   mov  di, [bm_tt_col2 + bx]
    call write_str

    ; Line 3
    cs   mov  si, [bm_tt_line3 + bx]
    test si, si
    jz   bm_tt_done
    cs   mov  di, [bm_tt_col3 + bx]
    call write_str

    ; Line 4
    cs   mov  si, [bm_tt_line4 + bx]
    test si, si
    jz   bm_tt_done
    cs   mov  di, [bm_tt_col4 + bx]
    call write_str

bm_tt_done:
    pop  bx
    pop  ax
    pop  cx
    pop  di
    pop  si
    pop  es
    ret

; Tooltip string pointer tables (indexed by cursor*2, word offsets into CS)
; 0=null means no tooltip for that row.
bm_tt_line1:
    dw bm_tt_dbg1       ; cursor 0: DEBUG MENU
    dw bm_tt_ss1        ; cursor 1: STAGE SELECT
    dw 0                ; cursor 2: RAPID FIRE (no tooltip)
    dw 0                ; cursor 3: REGION (no tooltip)
    dw bm_tt_logo1      ; cursor 4: TITLE LOGO
    dw bm_tt_bgm1       ; cursor 5: SOUND TEST
    dw bm_tt_wsu1       ; cursor 6: WPN UPGRADE

bm_tt_line2:
    dw bm_tt_dbg2       ; cursor 0
    dw bm_tt_ss2        ; cursor 1
    dw 0
    dw 0
    dw bm_tt_logo2      ; cursor 4
    dw bm_tt_bgm2       ; cursor 5
    dw bm_tt_wsu2       ; cursor 6

bm_tt_line3:
    dw bm_tt_dbg3       ; cursor 0
    dw 0                ; cursor 1: STAGE SELECT only has 2 lines
    dw 0
    dw 0
    dw 0
    dw 0
    dw 0                ; cursor 6: WPN UPGRADE has 2 lines

bm_tt_line4:
    dw bm_tt_dbg4       ; cursor 0
    dw 0
    dw 0
    dw 0
    dw 0
    dw 0
    dw 0                ; cursor 6

bm_tt_title:
    dw bm_tt_dbg0       ; cursor 0: "HOW TO USE DEBUG MENU:"
    dw bm_tt_ss0        ; cursor 1: "HOW TO USE STAGE SELECT:"
    dw 0
    dw 0
    dw bm_tt_logo0      ; cursor 4: "ABOUT TITLE LOGO:"
    dw bm_tt_bgm0       ; cursor 5: "HOW TO USE SOUND TEST:"
    dw bm_tt_wsu0       ; cursor 6: "ABOUT WEAPON UPGRADE:"

; Pre-computed VOFF values for each tooltip row per cursor
; All left-justified at col 7 (same as menu labels)
bm_tt_col0:
    dw VOFF(ROW_BOOT_TT0, 3)   ; cursor 0 title
    dw VOFF(ROW_BOOT_TT0, 4)   ; cursor 1 title
    dw 0
    dw 0
    dw VOFF(ROW_BOOT_TT0, 4)   ; cursor 4 title
    dw VOFF(ROW_BOOT_TT0, 4)   ; cursor 5 title
    dw VOFF(ROW_BOOT_TT0, 4)   ; cursor 6 title

bm_tt_col1:
    dw VOFF(ROW_BOOT_TT1, 3)   ; cursor 0 line 1
    dw VOFF(ROW_BOOT_TT1, 4)   ; cursor 1 line 1
    dw 0
    dw 0
    dw VOFF(ROW_BOOT_TT1, 4)   ; cursor 4 line 1
    dw VOFF(ROW_BOOT_TT1, 4)   ; cursor 5 line 1
    dw VOFF(ROW_BOOT_TT1, 4)   ; cursor 6 line 1

bm_tt_col2:
    dw VOFF(ROW_BOOT_TT2, 3)   ; cursor 0 line 2
    dw VOFF(ROW_BOOT_TT2, 4)   ; cursor 1 line 2
    dw 0
    dw 0
    dw VOFF(ROW_BOOT_TT2, 4)   ; cursor 4 line 2
    dw VOFF(ROW_BOOT_TT2, 4)   ; cursor 5 line 2
    dw VOFF(ROW_BOOT_TT2, 4)   ; cursor 6 line 2

bm_tt_col3:
    dw VOFF(ROW_BOOT_TT3, 3)   ; cursor 0 line 3
    dw 0
    dw 0
    dw 0
    dw 0
    dw 0
    dw 0

bm_tt_col4:
    dw VOFF(ROW_BOOT_TT4, 3)   ; cursor 0 line 4
    dw 0
    dw 0
    dw 0
    dw 0
    dw 0
    dw 0

bm_tt_dbg0: db "  HOW TO USE DEBUG MENU:", 0
bm_tt_dbg1: db "- HOLD 2P START TO ENTER", 0
bm_tt_dbg2: db "- PRESS 2P START AGAIN TO", 0
bm_tt_dbg3: db "  ENTER GLOBAL INFO MENU", 0
bm_tt_dbg4: db "- PRESS 1P START TO EXIT", 0
bm_tt_ss0:  db "HOW TO USE STAGE SELECT:", 0
bm_tt_ss1:  db "- HOLD ANY BUTTON WHILE", 0
bm_tt_ss2:  db "  PRESSING 1P/2P START", 0
bm_tt_bgm0: db "HOW TO USE SOUND TEST:", 0
bm_tt_bgm1: db "- PRESS A OR B TO PLAY", 0
bm_tt_bgm2: db "  THE SELECTED SOUND", 0
bm_tt_logo0: db "ABOUT TITLE LOGO:", 0
bm_tt_logo1: db "- WHITE IS THE BOOT LOOK,", 0
bm_tt_logo2: db "  COLOR THE ATTRACT LOOK", 0
bm_tt_wsu0:  db "ABOUT WEAPON UPGRADE:", 0
bm_tt_wsu1:  db "- PICKING A DIFFERENT", 0
bm_tt_wsu2:  db "  WEAPON GAINS +1 LEVEL", 0

; ── bm_erase — clear the boot menu rows ──────────────────────
bm_erase:
    push es
    push bx
    push cx
    push di

    mov  ax, VRAM_SEG
    mov  es, ax

    mov  bx, (39 - ROW_BOOT_HDR) * 2
bm_er_row:
    cmp  bx, (39 - ROW_BOOT_VER) * 2
    jb   bm_er_done
    mov  di, bx
    mov  cx, 32
bm_er_cell:
    mov  word es:[di], 0x0000
    add  di, CHAR_ADV
    loop bm_er_cell
    sub  bx, 2
    jmp  bm_er_row
bm_er_done:
    pop  di
    pop  cx
    pop  bx
    pop  es
    ret

; ── boot menu strings ─────────────────────────────────────────
bm_str_header: db "RAIDEN II MOD OPTIONS", 0
bm_str_debug:  db "DEBUG MENU   :", 0
bm_str_stsel:  db "STAGE SELECT :", 0
bm_str_rf:     db "RAPID FIRE   :", 0
bm_str_region: db "REGION:", 0
bm_str_logo:   db "TITLE LOGO   :", 0
bm_str_lwhite: db "WHITE", 0
bm_str_lcolor: db "COLOR", 0
bm_str_bgm:    db "SOUND TEST   :", 0
bm_str_wsu:    db "WPN UPGRADE  :", 0
bm_str_on:     db "ON ", 0
bm_str_off:    db "OFF", 0
bm_str_hint:   db "PRESS ANY BUTTON TO START", 0
bm_str_timer:  db "TIMER: ", 0
bm_str_ver:    db "VERSION 1.0", 0

; ── title logo palette images ────────────────────────────────
; Sprite palette lines 36-41 (staging buffer 1F00:0480, 6x16 colors,
; xBGR555). Captured from verified MAME palette dumps of the two title
; states. WHITE = the boot path's title set (greyscale chrome, the
; original designed look; ROM source around 89020). COLOR = the attract
; movie's logo palettes (blue/red chrome matching the official logo art;
; ROM sets at 8AEAE/8C656/8EB58/8FCF0/93B62). boot_menu_gate copies the
; selected image into the staging buffer every non-gameplay frame.
; ── rapid-fire rate table ────────────────────────────────────
; RF_RATE index -> frame reload -> HZ at 60HZ vblank
; On fire frames: [B142] cleared in boot_menu_gate so the next vblank's
; input handler sees all held buttons as newly-pressed edges.
NUM_RF_RATES    equ 5

bm_rf_reloads:                  ; frame counts (0=disabled)
    dw 0                        ; OFF
    dw 2                        ; 30HZ
    dw 3                        ; 20HZ
    dw 4                        ; 15HZ
    dw 6                        ; 10HZ

bm_rf_names:
    dw bm_rf_off
    dw bm_rf_30
    dw bm_rf_20
    dw bm_rf_15
    dw bm_rf_10
bm_rf_off: db "OFF", 0
bm_rf_30:  db "30HZ", 0
bm_rf_20:  db "20HZ", 0
bm_rf_15:  db "15HZ", 0
bm_rf_10:  db "10HZ", 0

; ── region table ─────────────────────────────────────────────
; REGION_VAR (BF0E) holds the display index (0..NUM_REGIONS-1).
; At boot_menu_gate confirm, the index is translated to the raw
; byte value and stored back in REGION_VAR for the ROM patch.
; ROM patch: 9843D: 26 A0 0B 00 -> A0 0E BF 90
;   Original: MOV AL, ES:[000Bh]  (reads physical FFFFBh)
;   Patched:  MOV AL, [BF0Eh] + NOP  (reads REGION_VAR)
; The existing CMP FFh / XOR AL,AL / MOV [9F67] logic is unchanged.
NUM_REGIONS     equ 22

bm_region_values:   ; raw byte value for each entry (written to REGION_VAR at confirm)
    dw 0x0000  ; JAPAN #1
    dw 0x0001  ; US (FABTEK)
    dw 0x0002  ; TAIWAN
    dw 0x0003  ; METROTAINMENT
    dw 0x0005  ; GERMANY (TUNING)
    dw 0x0006  ; AUSTRIA
    dw 0x0007  ; BELGIUM
    dw 0x0008  ; DENMARK
    dw 0x0009  ; FINLAND
    dw 0x000A  ; FRANCE
    dw 0x000B  ; GREAT BRITAIN
    dw 0x000C  ; GREECE
    dw 0x000D  ; HOLLAND
    dw 0x000E  ; ITALY
    dw 0x000F  ; NORWAY
    dw 0x0010  ; PORTUGAL
    dw 0x0011  ; SPAIN
    dw 0x0012  ; SWEDEN
    dw 0x0013  ; SWITZERLAND
    dw 0x0014  ; AUSTRALIA
    dw 0x0015  ; NEW ZEALAND
    dw 0x00FF  ; JAPAN #2

bm_region_names:    ; parallel display name pointer table
    dw bm_rg_00
    dw bm_rg_01
    dw bm_rg_02
    dw bm_rg_03
    dw bm_rg_05
    dw bm_rg_06
    dw bm_rg_07
    dw bm_rg_08
    dw bm_rg_09
    dw bm_rg_0A
    dw bm_rg_0B
    dw bm_rg_0C
    dw bm_rg_0D
    dw bm_rg_0E
    dw bm_rg_0F
    dw bm_rg_10
    dw bm_rg_11
    dw bm_rg_12
    dw bm_rg_13
    dw bm_rg_14
    dw bm_rg_15
    dw bm_rg_FF

bm_rg_00:  db "JAPAN #1", 0
bm_rg_01:  db "US (FABTEK)", 0
bm_rg_02:  db "TAIWAN", 0
bm_rg_03:  db "METROTAINMENT", 0
bm_rg_05:  db "GERMANY (TUNING)", 0
bm_rg_06:  db "AUSTRIA", 0
bm_rg_07:  db "BELGIUM", 0
bm_rg_08:  db "DENMARK", 0
bm_rg_09:  db "FINLAND", 0
bm_rg_0A:  db "FRANCE", 0
bm_rg_0B:  db "GREAT BRITAIN", 0
bm_rg_0C:  db "GREECE", 0
bm_rg_0D:  db "HOLLAND", 0
bm_rg_0E:  db "ITALY", 0
bm_rg_0F:  db "NORWAY", 0
bm_rg_10:  db "PORTUGAL", 0
bm_rg_11:  db "SPAIN", 0
bm_rg_12:  db "SWEDEN", 0
bm_rg_13:  db "SWITZERLAND", 0
bm_rg_14:  db "AUSTRALIA", 0
bm_rg_15:  db "NEW ZEALAND", 0
bm_rg_FF:  db "JAPAN #2", 0

; ============================================================
; BGM_PLAY  — enqueue a sound command via A0F06 (9800:8F06)
;
; Input:   AX = sound command (DH=0x80/0x82, DL=track or 0xFF)
; Returns: nothing
; Clobbers: BW (from "pop bw; retf" gadget at A66E8)
; Preserves: AX, CX, DX, SI, DI, BP, ES, DS
;
; RETF trampoline: A0F06 is near-only. After our RETF into it,
; SP points at:
;   [SP+0]  0xE6E8         near-ret gadget "pop bw; retf" at A66E8
;   [SP+2]  AX (command)   -> [BP+04] inside A0F06  ✓
;   [SP+4]  bgm_play_back  gadget RETF IP (popped first = IP)
;   [SP+6]  B692           gadget RETF CS (popped second = CS)
; ============================================================
bgm_play:
    push dx
    mov  dx, bgm_play_back
    push cs                  ; [SP+6] return CS = B692 (first -> highest)
    push dx                  ; [SP+4] return IP  (last  -> lowest  -> IP)
    push ax                  ; [SP+2] command -> [BP+04] in A0F06  ✓
    push word 0xE6E8         ; [SP+0] near-ret gadget
    push word 0x9800         ; RETF target CS
    push word 0x8F06         ; RETF target IP
    retf
bgm_play_back:
    pop  dx
    ret

; ============================================================
; CARRIER_SPAWN  (reached via vec_carrier_spawn CALL FAR B692:0010 from 9A9E4)
;
; Replaces INC [9F76] at 9A9E4 (absorbed; reconstructed before RETF).
; Fires after level data loader and object system init — the right time
; to spawn the item carrier that the checkpoint restart would normally provide.
;
; Carrier lookup:
;   entry_base = CS:0x25FC + STAGE_VAR * 0x30   (9800-segment checkpoint table)
;   carrier_id = CS:[entry_base + 0x20 + AREA_VAR * 2]
;   if carrier_id == 0: no carrier for this area
;
; Spawn call (mirrors checkpoint restart at 9AB74):
;   PUSH 0x000B            ; object pool param
;   PUSH (AREA_POS+0x0160) ; Y spawn position = checkpoint Y + 0x160
;   PUSH carrier_id        ; enemy type
;   PUSH 0x0070            ; X position (centre of screen)
;   CALL FAR A270:F4BF     ; spawn object
; ============================================================
carrier_spawn:
    ; Restored hook (9A9E8) — now BGM-only. The synthetic carrier spawn that
    ; used to live here is gone: carriers come from the stock checkpoint path
    ; (9AA88 + area_ckpt_impl) natively.
    ; Stage 1B (raw 1) has descriptor byte[3]=0 ("inherit BGM from previous
    ; stage"), so a cold start plays nothing. Fires once per stage init,
    ; inside 9A8C9, AFTER the 0x82FF sound reset at 9A8D2 — verified ordering
    ; so the Z80 sees reset then track.
    cmp  word [STAGE_VAR], 1
    jne  cs_bgm_done
    push ax
    mov  ax, 0x800C              ; BGM command: track 0x0C (Stage 1A/1B theme)
    call bgm_play
    pop  ax
cs_bgm_done:
    ; Reconstruct absorbed instruction LAST so its flags reach the JB at 9A9ED
    ; (the old version reconstructed first and then clobbered the flags).
    cmp  word [0x9F76], 4
    retf

; ============================================================
; RESOLVE_AREA_POS — look up checkpoint position for current stage+area
; Returns AX = checkpoint position (word value to write to [83A])
; ============================================================
resolve_area_pos:
    push si
    push bx
    ; Get stage raw value (clamped to 0-9)
    mov  bx, [STAGE_VAR]
    cmp  bx, 9
    jbe  rap_ok_stage
    mov  bx, 0
rap_ok_stage:
    ; Get pointer to this stage's checkpoint list via stage_ck_offsets
    shl  bx, 1              ; *2 for word index
    cs mov si, [stage_ck_offsets + bx]
    ; SI now = offset of checkpoint list in CS segment
    ; Get area index
    mov  bx, [AREA_VAR]
    ; Advance SI by bx words
    shl  bx, 1
    add  si, bx
    ; Read position
    cs mov ax, [si]
    ; If position is 0xFFFF (overrun), return 0
    cmp  ax, 0xFFFF
    jne  rap_done
    xor  ax, ax
rap_done:
    pop  bx
    pop  si
    ret

; ============================================================
; GET_AREA_MAX — return max valid area index for current stage
; Returns AX = max area index (0-based, so N areas = max N-1)
; ============================================================
get_area_max:
    push si
    mov  si, [STAGE_VAR]
    cmp  si, 9
    jbe  gam_ok
    mov  si, 0
gam_ok:
    cs mov al, [stage_max_areas + si]
    xor  ah, ah
    dec  ax              ; max index = count - 1
    pop  si
    ret
; ============================================================
; ITEM INCREMENT  — handles Stage, Loop, and Area items
; ============================================================
item_inc:
    push si
    push bx
    mov  ax, ITEM_SZ
    mov  si, [bp-2]
    mul  si
    add  ax, menu_table
    mov  si, ax
    cs mov bx, [si]         ; BX = var address

    ; Area item special handling
    cmp  bx, AREA_VAR
    jne  item_inc_normal
    call get_area_max       ; returns max index in AX
    mov  cx, ax             ; save max
    mov  ax, [AREA_VAR]
    inc  ax
    cmp  ax, cx
    jle  item_inc_area_ok
    xor  ax, ax             ; wrap: past max -> back to 0 (min)
item_inc_area_ok:
    mov  [AREA_VAR], ax
    jmp  item_inc_done

item_inc_normal:
    mov  ax, [bx]
    inc  ax
    cs cmp ax, [si+4]       ; compare with max
    jle  item_inc_noclamp
    cs mov ax, [si+2]       ; wrap: past max -> back to min
item_inc_noclamp:
item_inc_store:
    mov  [bx], ax
    call enforce_single     ; zero other weapons in group if MULTI_WPN=OFF
    ; If stage changed, reset area to 0
    cmp  bx, STAGE_VAR
    jne  item_inc_done
    mov  word [AREA_VAR], 0
item_inc_done:
    pop  bx
    pop  si
    ret

; ============================================================
; ITEM DECREMENT
; ============================================================
item_dec:
    push si
    push bx
    mov  ax, ITEM_SZ
    mov  si, [bp-2]
    mul  si
    add  ax, menu_table
    mov  si, ax
    cs mov bx, [si]

    ; Area item special handling
    cmp  bx, AREA_VAR
    jne  item_dec_normal
    mov  ax, [AREA_VAR]
    dec  ax
    jge  item_dec_area_ok
    call get_area_max       ; wrap: below 0 -> back to max
item_dec_area_ok:
    mov  [AREA_VAR], ax
    jmp  item_dec_done

item_dec_normal:
    mov  ax, [bx]
    dec  ax
    cs cmp ax, [si+2]       ; compare with min
    jge  item_dec_noclamp
    cs mov ax, [si+4]       ; wrap: below min -> back to max
item_dec_noclamp:
item_dec_store:
    mov  [bx], ax
    call enforce_single     ; zero other weapons in group if MULTI_WPN=OFF
    ; If stage changed, reset area to 0
    cmp  bx, STAGE_VAR
    jne  item_dec_done
    mov  word [AREA_VAR], 0
item_dec_done:
    pop  bx
    pop  si
    ret

; ============================================================
; WRITE_STR  — write null-terminated CS string to ES:DI
;   inputs : CS:SI = string, ES:DI = start VOFF, AH = attribute
;   effect : writes (AH<<8)|char to ES:[DI], DI += CHAR_ADV per char
; ============================================================
write_str:
wstr_lp:
    cs mov al, [si]
    inc  si
    test al, al
    jz   wstr_done
    cmp  al, ' '
    jne  wstr_nofix
    ; space: write full word 0x0000 (tile=0, attr=0) = truly empty cell
    mov  word es:[di], 0x0000
    add  di, CHAR_ADV
    jmp  wstr_lp
wstr_nofix:
    mov  byte es:[di],   al
    mov  byte es:[di+1], ah
    add  di, CHAR_ADV
    jmp  wstr_lp
wstr_done:
    ret

; ============================================================
; WRITE_CHAR  — write one character word to ES:DI
;   inputs : AL = tile, AH = attribute, ES:DI = destination
; ============================================================
write_char:
    mov  byte es:[di],   al
    mov  byte es:[di+1], ah
    ret

; ============================================================
; DRAW_MENU
; Walks layout_table. Each entry is 4 bytes:
;   dw screen_row
;   dw slot   (0x0000-0x0009 = item index; 0xFF00-0xFF03 = section header; 0xFFFF = end)
; SI is kept on the stack during item rendering so it survives mul/clobbers.
; ============================================================
draw_menu:
    push es
    push si
    push di
    push cx

    mov  ax, VRAM_SEG
    mov  es, ax

    mov  si, layout_table       ; SI = current layout entry

dm_layout_loop:
    cs mov  cx, [si+2]          ; cx = slot
    cmp  cx, 0xFFFF
    je   dm_done

    cs mov  ax, [si]            ; ax = screen row

    cmp  cx, 0xFF00
    jb   dm_is_item

    ; ── Section header ──────────────────────────────────────
    ; ax=row, cx=slot, si=layout entry ptr
    push si                     ; save layout entry ptr
    and  cx, 0x00FF             ; cx = header index 0-3
    mov  di, 39
    sub  di, ax
    shl  di, 1                  ; DI = VOFF(row, 0)
    shl  cx, 1                  ; cx*2 for word tables
    mov  bx, cx                 ; BX = index (BX/SI/DI valid as base in 16-bit EA)
    cs mov  ax, [hdr_cols + bx]
    add  di, ax                 ; DI = VOFF(row, col)
    cs mov  si, [hdr_strings + bx]
    mov  ah, ATTR_RED
    call write_str
    pop  si                     ; restore layout entry ptr
    jmp  dm_layout_hdr_done

dm_is_item:
    ; ── Item row ────────────────────────────────────────────
    ; ax=row, cx=item index (0-9), si=layout entry ptr
    ; Compute VOFF(row, COL_CURSOR) into BX
    mov  bx, 39
    sub  bx, ax
    shl  bx, 1
    add  bx, COL_CURSOR * CHAR_ADV   ; BX = VOFF(row, COL_CURSOR)

    ; Push SI (layout ptr) so we can restore after mul/string ops clobber it
    push si                     ; [sp] = layout entry ptr

    ; --- cursor ---
    mov  di, bx
    cmp  cx, [bp-2]
    jne  dm_no_cursor
    mov  al, '>'
    mov  ah, ATTR_HI
    mov  byte es:[di],   al
    mov  byte es:[di+1], ah
    jmp  dm_post_cursor
dm_no_cursor:
    mov  word es:[di], 0x0000
dm_post_cursor:

    ; --- label ---
    push cx                     ; save item index
    mov  ax, ITEM_SZ
    mul  cx                     ; clobbers DX
    add  ax, menu_table
    mov  si, ax
    cs mov si, [si+6]           ; SI = label string
    mov  di, bx
    add  di, (COL_LABEL - COL_CURSOR) * CHAR_ADV
    mov  ah, ATTR
    cmp  cx, [bp-2]
    jne  dm_lbl_write
    mov  ah, ATTR_HI
dm_lbl_write:
    call write_str
    pop  cx                     ; restore item index

    ; --- separator ---
    mov  di, bx
    add  di, (COL_SEP - COL_CURSOR) * CHAR_ADV
    mov  ah, ATTR
    cmp  cx, [bp-2]
    jne  dm_sep_write
    mov  ah, ATTR_HI
dm_sep_write:
    mov  al, ':'
    mov  byte es:[di],   al
    mov  byte es:[di+1], ah

    ; --- value ---
    ; Set attribute DH (must be before mul which clobbers DX)
    ; Actually mul clobbers DX so set DH after mul:
    push cx
    mov  ax, ITEM_SZ
    mul  cx                     ; clobbers DX; AX = cx*ITEM_SZ
    add  ax, menu_table
    mov  si, ax                 ; SI = menu_table entry
    pop  cx
    mov  dh, ATTR
    cmp  cx, [bp-2]
    jne  dm_val_attr_ok
    mov  dh, ATTR_HI
dm_val_attr_ok:
    mov  di, bx
    add  di, (COL_VALUE - COL_CURSOR) * CHAR_ADV
    push bx                     ; save VOFF
    cs mov bx, [si]             ; BX = var address
    mov  ax, [bx]               ; AX = raw value
    pop  bx                     ; restore VOFF

    ; value dispatch on cx (item index = cursor position = menu_table row)
    ;   cx=0 -> Stage (2-char)  cx=3 -> Rank (hex)  cx=9 -> Multi (ON/OFF)
    ;   all others -> decimal + disp_offset
    test cx, cx
    jnz  dm_val_not_stage
    ; Stage: 2-char name
    shl  ax, 1
    add  ax, stage_names
    mov  si, ax
    cs mov al, [si]
    mov  byte es:[di],   al
    mov  byte es:[di+1], dh
    add  di, CHAR_ADV
    cs mov al, [si+1]
    cmp  al, ' '
    je   dm_stage_spc
    mov  byte es:[di],   al
    mov  byte es:[di+1], dh
    jmp  dm_val_done
dm_stage_spc:
    mov  word es:[di], 0x0000
    jmp  dm_val_done

dm_val_not_stage:
    cmp  cx, 3
    je   dm_val_hex
    cmp  cx, 12                 ; item 12 = Multi (ON/OFF)
    je   dm_val_multi
    cmp  cx, 10                 ; item 10 = Bomb type (NUKE/CLUSTER)
    je   dm_val_bombty
    ; item 11 (Fairy) falls through: plain 0-9 decimal counter
    ; Decimal + disp_offset from menu_table[cx]+8
    push ax                     ; save raw value
    push cx
    push dx                     ; save DH (attribute) — mul will clobber DX
    mov  ax, ITEM_SZ
    mul  cx
    add  ax, menu_table
    mov  si, ax
    cs mov si, [si+8]           ; SI = disp_offset
    pop  dx                     ; restore DH
    pop  cx
    pop  ax
    add  ax, si                 ; value + disp_offset
    add  al, '0'
    mov  byte es:[di],   al
    mov  byte es:[di+1], dh
    add  di, CHAR_ADV
    ; Area row: append "/<count>" so the per-stage max is always visible,
    ; e.g. "2/4". The bound is drawn in the steady attribute (not the
    ; cursor highlight) so it reads as fixed secondary info.
    cmp  cx, 1                  ; item 1 = Area
    jne  dm_val_term
    mov  al, '/'
    mov  byte es:[di],   al
    mov  byte es:[di+1], ATTR
    add  di, CHAR_ADV
    call get_area_max           ; AX = max area index (0-based, AX-only)
    inc  ax                     ; -> area count (display is 1-based)
    add  al, '0'
    mov  byte es:[di],   al
    mov  byte es:[di+1], ATTR
    add  di, CHAR_ADV
dm_val_term:
    mov  word es:[di], 0x0000
    jmp  dm_val_done

dm_val_multi:
    test ax, ax
    jnz  dm_multi_on
    mov  si, str_off
    jmp  dm_multi_write
dm_multi_on:
    mov  si, str_on
dm_multi_write:
    mov  ah, dh
    call write_str
    jmp  dm_val_done

dm_val_bombty:
    test ax, ax
    jnz  dm_bombty_c
    mov  si, str_nuke
    jmp  dm_bombty_w
dm_bombty_c:
    mov  si, str_cluster
dm_bombty_w:
    mov  ah, dh
    call write_str
    jmp  dm_val_done

dm_val_hex:
    cmp  al, 9
    jbe  dm_val_hex_digit
    add  al, 'A' - 10
    jmp  dm_val_hex_write
dm_val_hex_digit:
    add  al, '0'
dm_val_hex_write:
    mov  byte es:[di],   al
    mov  byte es:[di+1], dh
    add  di, CHAR_ADV
    mov  word es:[di], 0x0000

dm_val_done:
    pop  si                     ; restore layout entry ptr (pushed before cursor)

dm_layout_hdr_done:
    add  si, 4                  ; advance to next layout entry
    jmp  dm_layout_loop

dm_done:
    pop  cx
    pop  di
    pop  si
    pop  es
    ret

; ============================================================
; CLEAR_VRAM  — zero all 32*32 cells of character VRAM
; VRAM is 32 rows * 32 columns * 2 bytes = 2048 words = 4096 bytes.
; Each cell: byte0=tile, byte1=attribute. 0x0000 = empty/transparent.
; ============================================================
clear_vram:
    push es
    push di
    push cx
    mov  ax, VRAM_SEG
    mov  es, ax
    xor  di, di             ; start at offset 0
    mov  cx, 2048           ; 32*32 = 1024 cells * 2 bytes = 2048 words
    xor  ax, ax
    rep  stosw              ; write 0x0000 to all cells
    pop  cx
    pop  di
    pop  es
    ret

; ============================================================
; ERASE_MENU  — clear the stage select area (calls clear_vram)
; ============================================================
erase_menu:
    call clear_vram
    ret

; ============================================================
; MENU TABLE  (10 bytes per entry, read via CS:)
;   +0 dw var_addr  +2 dw min  +4 dw max  +6 dw label_off  +8 dw disp_offset
; Order matches layout_table visual order (cursor 0-9).
; ============================================================
menu_table:
    dw STAGE_VAR,  0, 9,    str_stage,   0   ; 0: Stage  raw 0-9
    dw AREA_VAR,   0, 0,    str_area,    1   ; 1: Area   max dynamic; 1-based
    dw LOOP_VAR,   0, 3,    str_loop,    1   ; 2: Loop   1-based
    dw PROG_VAR,   0, 2,    str_rank,    0   ; 3: Miss counter 0-2 (the game's
                                             ; "rank" is a death counter whose
                                             ; only effect is post-death mercy
                                             ; sizing; >1 states are identical)
    dw MW_VULCAN,  0, 8,    str_vulcan,  0   ; 4: Vulcan
    dw MW_LASER,   0, 8,    str_laser,   0   ; 5: Laser
    dw MW_PLASMA,  0, 8,    str_plasma,  0   ; 6: Plasma
    dw SW_NUCLEAR, 0, 4,    str_nuclear, 0   ; 7: Nuclear
    dw SW_HOMING,  0, 4,    str_homing,  0   ; 8: Homing
    dw BOMB_STOCK, 0, 7,    str_bombst,  0   ; 9: Bomb stock 0-7
    dw BOMB_TYPE,  0, 1,    str_bombty,  0   ; 10: Bomb type 0=NUKE,1=CLUSTER
    dw FAIRY_VAR,  0, 9,    str_fairy,   0   ; 11: Fairies in stock 0-9
    dw MULTI_WPN,  0, 1,    str_multi,   0   ; 12: Multi  0=OFF,1=ON

; ============================================================
; LAYOUT TABLE  — visual order of the stage select menu
; Each entry: dw screen_row, dw slot
;   slot 0x0000-0x0009 = menu_table item index (= cursor position)
;   slot 0xFF00-0xFF03 = section header index
;   slot 0xFFFF        = end of table
; ============================================================
layout_table:
    dw 20, 0xFF00   ; - STAGE SELECT -
    dw 21, 0x0000   ; Stage
    dw 22, 0x0001   ; Area
    dw 23, 0x0002   ; Loop
    dw 24, 0x0003   ; Rank
    dw 25, 0xFF01   ; - MAIN WEAPON POWER -
    dw 26, 0x0004   ; Vulcan
    dw 27, 0x0005   ; Laser
    dw 28, 0x0006   ; Plasma
    dw 29, 0xFF02   ; - SUB WEAPON POWER -
    dw 30, 0x0007   ; Nuclear
    dw 31, 0x0008   ; Homing
    dw 32, 0xFF04   ; - ITEM STOCK -
    dw 33, 0x0009   ; Bomb stock
    dw 34, 0x000A   ; Bomb type
    dw 35, 0x000B   ; Fairy
    dw 36, 0xFF03   ; - EXTRA OPTION -
    dw 37, 0x000C   ; Multi Weapon
    dw 0xFFFF, 0xFFFF

; Section header string pointers (indexed by header index * 2)
hdr_strings:
    dw str_hdr_stage    ; 0
    dw str_hdr_main     ; 1
    dw str_hdr_sub      ; 2
    dw str_hdr_extra    ; 3
    dw str_hdr_items    ; 4

; Section header column offsets (col * CHAR_ADV, added to VOFF(row,0))
hdr_cols:
    dw 8 * CHAR_ADV    ; "- STAGE SELECT -"     16 chars -> col 8
    dw 5 * CHAR_ADV    ; "- MAIN WEAPON POWER -" 21 chars -> col 5
    dw 6 * CHAR_ADV    ; "- SUB WEAPON POWER -"  20 chars -> col 6
    dw 8 * CHAR_ADV    ; "- EXTRA OPTION -"      16 chars -> col 8
    dw 9 * CHAR_ADV    ; "- ITEM STOCK -"        14 chars -> col 9

; ============================================================
; CHECKPOINT POSITION TABLE  (per-stage, FFFF-terminated lists)
; Raw STAGE_VAR values 0–9, all selectable. Raw 0 = Stage 1A (launch),
; raw 1 = Stage 1B (post-launch). See stage_names for display mapping.
; ============================================================
ck_stage_0: dw 0x0000, 0xffff                                      ; raw 0 Stage 1 - launch
ck_stage_1: dw 0x0000, 0x0300, 0x0600, 0x0900, 0xffff              ; raw 1 Stage 1 - Post launch: 4 areas
ck_stage_2: dw 0x0000, 0x0280, 0x0500, 0x0ac0, 0x0e40, 0xffff      ; raw 2 Stage 2: 5 areas
ck_stage_3: dw 0x0000, 0x0300, 0x05a0, 0x0760, 0x0ad0, 0x0f40, 0xffff  ; raw 3 Stage 3: 6 areas
ck_stage_4: dw 0x0000, 0x0310, 0x0600, 0x0900, 0x0c00, 0x0f10, 0xffff  ; raw 4 Stage 4: 6 areas
ck_stage_5: dw 0x0000, 0x0300, 0x0470, 0x06d0, 0x0900, 0x0b80, 0x0ed0, 0xffff  ; raw 5 Stage 5: 7 areas
ck_stage_6: dw 0x0000, 0xffff                                        ; raw 6 Stage 6: launch 
ck_stage_7: dw 0x0000, 0x0280, 0x0540, 0x0800, 0x0c00, 0x0f00, 0xffff  ; raw 7 Stage 6 - Post launch: 6 areas
ck_stage_8: dw 0x0000, 0x0360, 0x0500, 0x07b0, 0x0ca0, 0x0f00, 0xffff  ; raw 8 Stage 7: 6 areas
ck_stage_9: dw 0x0000, 0x0590, 0x0880, 0xffff                       ; raw 9 Stage 8: 3 areas
;(ROM-verified: Block 10 @ 0x9A7BC has no checkpoint values)

; Stage checkpoint offset table — indexed by raw [9F5E] value (0–9)
stage_ck_offsets:
    dw ck_stage_0   ; raw 0 = Stage 1
    dw ck_stage_1   ; raw 1 = Stage 1 - Post launch
    dw ck_stage_2   ; raw 2 = Stage 2
    dw ck_stage_3   ; raw 3 = Stage 3
    dw ck_stage_4   ; raw 4 = Stage 4
    dw ck_stage_5   ; raw 5 = Stage 5
    dw ck_stage_6   ; raw 6 = Stage 6
    dw ck_stage_7   ; raw 7 = Stage 6 - Post Launch
    dw ck_stage_8   ; raw 8 = Stage 7
    dw ck_stage_9   ; raw 9 = Stage 8

; Max area count — indexed by raw [9F5E] value (0–9)
stage_max_areas:
    db 1  ; raw 0 Stage 1 - launch
    db 4  ; raw 1 Stage 1 - Post launch: 4 areas
    db 5  ; raw 2 Stage 2: 5 areas
    db 6  ; raw 3 Stage 3: 6 areas
    db 6  ; raw 4 Stage 4: 6 areas
    db 7  ; raw 5 Stage 5: 7 areas
    db 1  ; raw 6 Stage 6 - launch
    db 6  ; raw 7 Stage 6 - Post launch: 6 areas
    db 6  ; raw 8 Stage 7: 6 areas
    db 3  ; raw 9 Stage 8: 3 areas

; ============================================================
; STAGE NAME TABLE  (2 bytes per entry: char1, char2)
; Indexed by raw STAGE_VAR value (0–9).
; Char2 = ' ' means single-char stage name (second cell erased).
; ============================================================
stage_names:
    db '1', 'A'     ; raw 0 = Stage 1A (launch stage)
    db '1', 'B'     ; raw 1 = Stage 1B (post-launch)
    db '2', ' '     ; raw 2 = Stage 2
    db '3', ' '     ; raw 3 = Stage 3
    db '4', ' '     ; raw 4 = Stage 4
    db '5', ' '     ; raw 5 = Stage 5
    db '6', 'A'     ; raw 6 = Stage 6A (launch stage)
    db '6', 'B'     ; raw 7 = Stage 6B (post-launch)
    db '7', ' '     ; raw 8 = Stage 7
    db '8', ' '     ; raw 9 = Stage 8

; ============================================================
; STRINGS  (null-terminated ASCII, CS segment)
; ============================================================
str_header:  db "STAGE SELECT", 0
str_stage:   db "STAGE   ", 0
str_loop:    db "LOOP    ", 0
str_area:    db "AREA    ", 0
str_rank:    db "MISS CTR", 0
str_vulcan:  db "VULCAN  ", 0
str_laser:   db "LASER   ", 0
str_plasma:  db "PLASMA  ", 0
str_nuclear: db "NUCLEAR ", 0
str_homing:  db "HOMING  ", 0
str_multi:   db "MULTI WP", 0
str_fairy:   db "FAIRY", 0
str_bombst:  db "BOMBS", 0
str_bombty:  db "B.TYPE", 0
str_nuke:    db "NUKE   ", 0    ; padded to CLUSTER's width (erases tail)
str_cluster: db "CLUSTER", 0
str_hdr_items: db "- ITEM STOCK -", 0
str_on:      db "ON ", 0
str_off:     db "OFF", 0
str_hint:    db "START TO BEGIN", 0

str_hdr_stage: db "- STAGE SELECT -", 0
str_hdr_main:  db "- MAIN WEAPON POWER -", 0
str_hdr_sub:   db "- SUB WEAPON POWER -", 0
str_hdr_extra: db "- EXTRA OPTION -", 0
