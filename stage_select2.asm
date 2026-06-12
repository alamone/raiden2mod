; ============================================================
; Raiden 2 mod — SECOND CODE/DATA BLOB, segment B581 (phys B5810)
;
; The primary blob at B692:0000 (phys B6920) lives in a free-fill
; region that HARD-ENDS at phys B8102 — the game's string tables
; ("PUSH", "1 OR 2 PLAYER BUTTON", ...) start right after, and
; overrunning them corrupted the credited-title text (caught
; 2026-06-11). Self-contained hook implementations and pure data
; live here instead; patch_roms.py asserts both blobs' budgets.
;
; This blob occupies the free zero-fill run B5804-B5F03 starting at
; the paragraph boundary B5810 -> max size 0x6F3 bytes.
;
; Reached via FAR JMPs from the primary blob's fixed vector table
; (each B692 vector does JMP B581:offset; the impls end in RETF, so
; they return directly to the original hook caller). The vector
; offsets below are FIXED — the primary blob references them as
; L2_* equates.
;
; The equates below MUST stay in sync with stage_select.asm.
;
; CPU 186: the NEC V30 executes 8086 + 186 extensions (push imm,
; shifts by imm, etc.) but NOT 386 long-form Jcc (0F 8x). Without
; this directive NASM silently promotes an out-of-range short Jcc
; to the 386 encoding, which the V30 misdecodes — that bug shipped
; once (fairy_tick_impl's JNZ fell through and spawned a fairy item
; EVERY frame). With it, NASM errors out instead.
; ============================================================
cpu 186

; ── scratch RAM variables (sync with stage_select.asm) ───────
RF_RATE     equ 0xBF10
RF_SUPPRESS equ 0xBF16
MULTI_WPN   equ 0xBF22
FAIRY_VAR   equ 0xBF4A      ; menu FAIRY row: 1 = start with a fairy in stock
BOMB_STOCK  equ 0xBF58
BOMB_TYPE   equ 0xBF5A
SW_NUCLEAR  equ 0xBF1E
SW_HOMING   equ 0xBF20
SW_ARMED    equ 0xBF26
MENU_LIVE   equ 0xBF5C      ; 1 = menu game live (gates the late-join apply)
BOMB_PEND   equ 0xBF5E      ; struct base of a joiner awaiting the bomb fill
WEAPON_ARMED equ 0xBF24     ; pending bitmask: bit0=P1, bit1=P2 (3 at confirm),
                            ; cleared per player by menu_tick_impl on activation
MW_VULCAN   equ 0xBF18
MW_LASER    equ 0xBF1A
MW_PLASMA   equ 0xBF1C
SUBN_P1     equ 0xBF40
SUBN_P2     equ 0xBF42
SUBH_P1     equ 0xBF44
SUBH_P2     equ 0xBF46
WSU_VAR     equ 0xBF48


; ── FIXED VECTOR TABLE (offsets are ABI for the primary blob) ─
vec2_sub_edge:                      ; B581:0000
    jmp  near sub_edge_impl
    times (8 - ($ - vec2_sub_edge)) db 0x90
vec2_subgate_nuke:                  ; B581:0008
    jmp  near subgate_nuke_impl
    times (8 - ($ - vec2_subgate_nuke)) db 0x90
vec2_subgate_hom:                   ; B581:0010
    jmp  near subgate_hom_impl
    times (8 - ($ - vec2_subgate_hom)) db 0x90
vec2_rf_held:                       ; B581:0018
    jmp  near rf_held_impl
    times (8 - ($ - vec2_rf_held)) db 0x90
vec2_main_vul:                      ; B581:0020
    jmp  near main_vul_impl
    times (8 - ($ - vec2_main_vul)) db 0x90
vec2_main_las:                      ; B581:0028
    jmp  near main_las_impl
    times (8 - ($ - vec2_main_las)) db 0x90
vec2_main_pla:                      ; B581:0030
    jmp  near main_pla_impl
    times (8 - ($ - vec2_main_pla)) db 0x90
vec2_pickup_main:                   ; B581:0038
    jmp  near pickup_main_impl
    times (8 - ($ - vec2_pickup_main)) db 0x90
vec2_pickup_sub:                    ; B581:0040
    jmp  near pickup_sub_impl
    times (8 - ($ - vec2_pickup_sub)) db 0x90
vec2_fairy:                         ; B581:0048 (retired: the fairy is
    retf                            ; just the [player+0x24] stock counter,
    times (8 - ($ - vec2_fairy)) db 0x90  ; written by bomb_fill below)
vec2_bombs:                         ; B581:0050
    jmp  near bomb_apply_impl
    times (8 - ($ - vec2_bombs)) db 0x90
vec2_winit:                         ; B581:0058
    jmp  near weapon_init_impl
    times (8 - ($ - vec2_winit)) db 0x90
vec2_bjoin:                         ; B581:0060 (per-frame menu tick)
    jmp  near menu_tick_impl
    times (8 - ($ - vec2_bjoin)) db 0x90
vec2_mainovr:                       ; B581:0068
    jmp  near main_override_impl
    times (8 - ($ - vec2_mainovr)) db 0x90
; ── rapid-fire reload table (LOCAL COPY — sync with the
;    bm_rf_reloads table in stage_select.asm) ─────────────────
l2_rf_reloads:
    dw 0                        ; OFF
    dw 2                        ; 30HZ
    dw 3                        ; 20HZ
    dw 4                        ; 15HZ
    dw 6                        ; 10HZ

; ============================================================
; SUB_EDGE_IMPL  (called via vec_sub_edge = B692:00B8)
; Replaces the 5-byte TEST WORD [BP+58],000Ch at four sub-weapon
; volley-script sites (A270:895E, 8992, 8E52, 8F3C — phys AB05E,
; AB092, AB552, AB63C; original bytes F7 46 58 0C 00 at each, all
; followed by a JNZ/JZ that consumes ZF).
;
; [BP+58] is the owning object's per-frame input-flags word; bits
; 2/3 are the players' fire PRESS EDGES. The nuclear/homing volley
; scripts test them before every missile pair and at every delay
; step: a fresh press mid-volley ABORTS the volley so it can restart
; from its windup (stock mash-to-re-time behaviour). Rapid fire
; synthesizes a fresh edge every 2-6 frames by clearing the [B142]
; latch, so with RF at ANY rate the volley scripts aborted forever:
; nukes thinned to 0-2 per volley and homing starved (bot-measured:
; 10s held fire = 11 nukes with RF off, 0 nukes at 10/15/30Hz).
;
; While RF is enabled, report "no edge" (ZF=1) so volleys run to
; completion; the launcher re-triggers naturally from the held
; button. With RF off, perform the original test — stock-identical.
; TEST clears CF/OF; CMP AX,AX matches that (ZF=1 CF=0 OF=0).
; No registers touched. CALL FAR/RETF preserve flags.
; ============================================================
sub_edge_impl:
    cmp  word [RF_RATE], 0
    je   .stock
    cmp  ax, ax                  ; ZF=1: pretend no fresh press edge
    retf
.stock:
    test word [bp+0x58], 0x0C    ; absorbed original instruction
    retf

; ============================================================
; SUBGATE_NUKE_IMPL / SUBGATE_HOM_IMPL
; (vec_subgate_nuke = B692:00C0, vec_subgate_hom = B692:00C8)
;
; The fire dispatcher A270:7C48 (phys AA348) runs once per fire
; trigger and walks the player's weapon slots in order: vulcan
; [DI+6], laser [DI+8], plasma [DI+A], NUCLEAR [DI+E], HOMING
; [DI+10]. Each block begins with the 5-byte pair
;     MOV SI,[DI+x] / TEST SI,SI        (8B 75 xx 85 F6)
; followed by a JZ that skips that weapon. DI = the per-player aux
; struct (P1 = 9ED0, P2 = 9F0E).
;
; A trigger fires on a fire-button PRESS EDGE or after 30 frames of
; continuous hold (A270:79CB's CMP [DI+34],1Eh). Re-triggering a
; sub-weapon launcher mid-volley KILLS its attached just-spawned
; missiles (bot-measured at 30Hz: 244 nuke allocs / 219 instant
; frees per 10s, ZERO missiles survive to fly). Rapid fire fakes a
; press edge every 2-6 frames via the B142 latch clear, so with RF
; at ANY rate sub-volleys died wholesale while vulcan benefited —
; "main weapons block the sub-weapons".
;
; Fix: while RF is enabled, pass a sub-weapon dispatch through only
; every 30 frames (the stock held-fire cadence) per player and per
; weapon; the volley then completes undisturbed exactly as in a
; stock hold. Mains keep retriggering at full RF speed. RF off ->
; stock-identical (gate bypassed).
;
; Contract: replaces the MOV/TEST pair; the original JZ follows and
; consumes our ZF. SI must hold [DI+x] when passing. Gated path
; returns SI=0/ZF=1 (the JZ then skips the weapon block).
; ============================================================
subgate_nuke_impl:
    mov  si, [di+0x0E]
    test si, si
    jz   .out                    ; weapon not equipped: ZF=1 skips
    push bx
    mov  bx, SUBN_P1
    cmp  di, 0x9ED0              ; P1 aux struct?
    je   .gate
    mov  bx, SUBN_P2
.gate:
    call subgate_check           ; ZF=1 -> gated (SI zeroed)
    pop  bx                      ; pop preserves flags
.out:
    retf

subgate_hom_impl:
    ; Pass-through: homing volleys are already self-limited by the
    ; allocator re-entry guard (one unreleased missile blocks respawn)
    ; plus the orphan reaper, and the pool-2 reserve keeps slots free.
    ; A 30-frame dispatch gate on top of those made homing miss light-
    ; combat windows entirely (test_homing 8/9), so homing dispatches
    ; at full trigger rate like stock.
    mov  si, [di+0x10]
    test si, si
    retf

; ============================================================
; RF_HELD_IMPL  (vec_rf_held = B692:00D0)
; Replaces, at A270:79CB (phys A99CB), the held-autofire tail of the
; ship's fire-input handler:
;     CMP WORD [DI+34],001Eh   ; 83 7D 34 1E
;     JNL .fire (+0A)          ; 7D 0A
;     INC WORD [DI+34]         ; FF 45 34
;     RET                      ; C3
; patched to:
;     CALL FAR B692:00D0       ; 9A D0 00 92 B6
;     JNL .fire (+09)          ; 7D 09
;     RET                      ; C3
;     NOP NOP
; [DI+34] counts consecutive held frames; the stock engine fires the
; dispatcher every 30. This path runs only when no plasma is equipped
; ([DI+0A]=0 — the plasma branch is edge-driven). While RF is active
; the threshold becomes (reload-1): reload 2 fires every 2nd frame
; (30Hz), 3 -> 20Hz, etc. This is REAL autofire through the engine's
; own held cadence — no synthesized press edges, so nuclear/homing
; volleys complete exactly as they do on a plain held button.
; Per-player by construction (DI = that player's aux struct).
; Returns flags for the caller's JNL: fire = SF==OF (CMP AX,AX),
; wait = SF!=OF (CMP of 0 against 1); increments [DI+34] itself.
; ============================================================
rf_held_impl:
    push ax
    push bx
    mov  ax, 0x1E               ; stock threshold: 30 held frames
    mov  bx, [RF_RATE]
    test bx, bx
    jz   .have
    cmp  word [RF_SUPPRESS], 0  ; debug menu open: behave stock
    jne  .have
    shl  bx, 1
    cs   mov  ax, [l2_rf_reloads + bx]
    dec  ax                     ; reload N -> fire every N held frames
.have:
    cmp  [di+0x34], ax
    jnl  .fire
    inc  word [di+0x34]
    xor  ax, ax
    cmp  ax, 1                  ; SF != OF -> caller's JNL falls through
    pop  bx
    pop  ax
    retf
.fire:
    cmp  ax, ax                 ; SF == OF (ZF=1) -> caller's JNL taken
    pop  bx
    pop  ax
    retf

; ============================================================
; MAIN_VUL/LAS/PLA_IMPL  (B692:00D8 / 00E0 / 00E8)
; Replace the main-weapon dispatch headers in A270:7C48
; (MOV SI,[DI+6/8/A] / TEST SI,SI; the following JZ skips the block).
;
; EVERY player shot object — vulcan stream, laser, plasma, nuclear,
; homing — is allocated from seg-0 pool 2 for P1 / pool 3 for P2
; (36 slots each; spawner A270:F659 picks pool [ship+0C]+2 and
; silently STCs when it is full). Bot-measured at 30Hz with vulcan 8
; + laser 8: pool 2 pegs at 35-36/36 with ~20 vulcan (h8C6F) and ~15
; laser (h8D5B) objects, so nuclear/homing spawns lose every race:
; 10 nuke spawns/10s vs 98-136 when either main is absent. THIS is
; the "main weapons block the sub-weapons" bug.
;
; Fix: in multi-weapon mode, when the player has a sub weapon
; equipped and their object pool has fewer than POOL2_RESERVE free
; slots, skip that MAIN weapon's dispatch this trigger (ZF=1, SI=0).
; Mains retrigger every few frames under RF, so a skipped dispatch
; just trims peak density; the freed slots let full nuke/homing
; volleys through. Stock/single-weapon games ([MULTI_WPN]=0) are
; untouched.
; ============================================================
; Pool-sharing for the three main weapons. The 36-slot object pool
; is oversubscribed by a full multi loadout (~50 slots of natural
; demand), so static rules always starve someone: a flat free-slot
; floor let first-in-dispatch vulcan refill every freed slot (laser/
; plasma fired one volley then never again), and tiered floors
; locked vulcan out instead. Fix: when the pool is tight (free
; 4..9), admit exactly ONE main per dispatch by 4-frame windows off
; the frame clock [9F5A], cycling V,L,V,P — vulcan (the ship's bread
; and butter, user-tuned) gets every other window, laser and plasma
; one in four each. Below 4 free, all mains stand down (sub-weapon
; floor). 10+ free: everyone fires. Sub weapons are never gated.
MAIN_FREE_OK   equ 10
SUB_FLOOR      equ 4

main_vul_impl:
    mov  si, [di+0x06]
    test si, si
    jz   .out
    push ax
    xor  ax, ax                  ; weapon slot 0 of the rotation
    call main_pool_check
    pop  ax                      ; pop preserves flags
.out:
    retf

main_las_impl:
    mov  si, [di+0x08]
    test si, si
    jz   .out
    push ax
    mov  ax, 1
    call main_pool_check
    pop  ax
.out:
    retf

main_pla_impl:
    mov  si, [di+0x0A]
    test si, si
    jz   .out
    push ax
    mov  ax, 2
    call main_pool_check
    pop  ax
.out:
    retf

; AX = this main's rotation slot (0/1/2). Returns ZF=0 (dispatch,
; SI preserved) or ZF=1/SI=0 (skip this weapon's block).
main_pool_check:
    cmp  word [MULTI_WPN], 0
    je   .pass                   ; stock rules outside multi mode
    push bx
    push cx
    push dx
    mov  bx, [di+0x0E]
    or   bx, [di+0x10]           ; any sub weapon equipped?
    jz   .pass_pop
    ; count free slots in this player's object pool (P1 di=9ED0 ->
    ; pool 2 @5290, P2 -> pool 3 @62C0; 36 slots, stride 70h,
    ; alive flag at +40)
    mov  bx, 0x5290
    cmp  di, 0x9ED0
    je   .base
    mov  bx, 0x62C0
.base:
    mov  cx, 36
    xor  dx, dx                  ; free count
.scan:
    cmp  byte [bx+0x40], 0
    jne  .used
    inc  dx
.used:
    add  bx, 0x70
    loop .scan
    cmp  dx, MAIN_FREE_OK
    jae  .pass_pop               ; plenty of room: everyone fires
    cmp  dx, SUB_FLOOR
    jb   .starve                 ; floor reserved for the subs
    ; pressured: 4-frame windows cycle V,L,V,P (vulcan 2/4 duty).
    ; AX is the caller's scratch copy (pushed/popped around the call).
    mov  dx, [0x9F5A]
    shr  dx, 1
    shr  dx, 1                   ; window index = frame/4
    and  dx, 3                   ; window 0..3
    test ax, ax                  ; vulcan?
    jnz  .not_v
    test dx, 1                   ; vulcan owns the even windows
    jz   .pass_pop
    jmp  .starve
.not_v:
    cmp  ax, 1                   ; laser owns window 1
    jne  .pla
    cmp  dx, 1
    je   .pass_pop
    jmp  .starve
.pla:
    cmp  dx, 3                   ; plasma owns window 3
    jne  .starve
.pass_pop:
    pop  dx
    pop  cx
    pop  bx
.pass:
    test si, si                  ; SI nonzero -> ZF=0, dispatch
    ret
.starve:
    pop  dx
    pop  cx
    pop  bx
    xor  si, si                  ; ZF=1 -> caller's JZ skips this main
    ret

; ============================================================
; PICKUP_MAIN_IMPL / PICKUP_SUB_IMPL  (B692:00F0 / 00F8)
; Replace the tails of the powerup-pickup "different weapon" paths
; (mains A270:6247, subs A270:62C7; DI = player aux struct, BX =
; picked weapon index*2, DX = level carried from the previous
; weapon — or the default 1 in the sub path when no sub was owned).
; Each hook covers the 23-byte block of four zero-stores plus the
; MOV [BX+DI+6],DX; the following JMP .sound survives in ROM.
;
; Stock behaviour ([MULTI_WPN]=0, [WSU_VAR]=0): byte-identical —
; zero the other weapons, transfer the level unchanged. (The attract
; demo picks up items, so this path MUST stay deterministic in
; stock mode or the demo desyncs.)
;
; MULTI_WPN=1: no zeroing — the other weapons keep their levels.
; The picked weapon (necessarily at level 0 on this path) starts at
; level 1 and grows through the same-weapon +1 path thereafter; the
; stock level-transfer would have duplicated the strongest weapon's
; level onto the new one, which has no meaning when nothing is lost.
;
; WSU_VAR=1 (WEAPON SWITCH UPGRADE, boot menu): the stock transfer
; also gains +1 (capped 8 mains / 4 subs), so switching weapons is
; never a wasted pickup. First-ever sub pickup stays at level 1
; (nothing was switched away from). In multi mode WSU is moot: every
; pickup already raises the picked weapon's own level.
;
; Note: a switch pickup that lifts a level past the transform
; threshold (main>4 / sub>2) won't grow the ship until the next
; same-weapon pickup or stage start (transform_check) — the stock
; transfer path has no threshold check either.
; ============================================================
pickup_main_impl:
    cmp  word [MULTI_WPN], 0
    je   .stock
    mov  dx, 1                   ; fresh weapon starts at level 1
    jmp  .store
.stock:
    mov  word [di+0x06], 0       ; reconstruct the stock zeroing
    mov  word [di+0x08], 0
    mov  word [di+0x0A], 0
    mov  word [di+0x0C], 0
    cmp  word [WSU_VAR], 0
    je   .store
    inc  dx                      ; switch upgrade: +1 level
    cmp  dx, 8
    jbe  .store
    mov  dx, 8
.store:
    mov  [bx+di+0x06], dx        ; reconstruct the stock store
    retf

pickup_sub_impl:
    cmp  word [MULTI_WPN], 0
    je   .stock
    mov  dx, 1
    jmp  .store
.stock:
    push ax
    mov  ax, [di+0x0E]           ; capture BEFORE zeroing:
    or   ax, [di+0x10]           ; did the player own any sub?
    or   ax, [di+0x12]
    or   ax, [di+0x14]
    mov  word [di+0x0E], 0
    mov  word [di+0x10], 0
    mov  word [di+0x12], 0
    mov  word [di+0x14], 0
    test ax, ax
    pop  ax                      ; pop preserves flags
    jz   .store                  ; first sub ever: stock level 1
    cmp  word [WSU_VAR], 0
    je   .store
    inc  dx
    cmp  dx, 4
    jbe  .store
    mov  dx, 4
.store:
    mov  [bx+di+0x06], dx
    retf

; BX = gate variable (last-allowed frame stamp). Returns ZF=0 (pass,
; SI preserved nonzero) or ZF=1 with SI=0 (gate). Frame clock [9F5A].
subgate_check:
    cmp  word [RF_RATE], 0
    je   .pass                   ; RF off: stock behaviour, no gate
    push ax
    mov  ax, [0x9F5A]
    sub  ax, [bx]
    cmp  ax, 30                  ; stock held-autofire period
    jb   .gated
    mov  ax, [0x9F5A]
    mov  [bx], ax                ; stamp this allowed dispatch
    pop  ax
.pass:
    test si, si                  ; SI nonzero here -> ZF=0
    ret
.gated:
    pop  ax
    xor  si, si                  ; ZF=1, SI=0 -> caller's JZ skips
    ret


; ============================================================
; BOMB_APPLY_IMPL  (B581:0050 — far-called from area_start_impl on
; every cold start, after the 9AC0E player init). Writes the menu's
; ITEM STOCK bomb loadout into both active players' bomb arrays
; ([aux+0x16..0x1D]: P1 9EE6, P2 9F24; slot value 1 = red/NUKE bomb,
; 2 = yellow/CLUSTER; the bomb button consumes the highest nonzero
; slot via A270:7FB6 -> entity 0x14/0x16). Defaults (3 x NUKE)
; reproduce the init's own 01 01 01, so non-menu games see no change.
; Sets the HUD-redraw flag [9FB4] so the bomb row displays correctly.
; ============================================================
bomb_apply_impl:
    push ax
    push bx
    push cx
    push di
    cmp  word [0x9ED0], 0       ; P1 active?
    je   .p2
    mov  di, 0x9EE6
    call bomb_fill
.p2:
    cmp  word [0x9F0E], 0       ; P2 active?
    je   .done
    mov  di, 0x9F24
    call bomb_fill
.done:
    mov  word [0x9FB4], 1       ; HUD redraw
    pop  di
    pop  cx
    pop  bx
    pop  ax
    retf

; ── bomb_fill: write the ITEM STOCK loadout into the 8-slot bomb
;    array at DI per BOMB_STOCK/BOMB_TYPE, then the FAIRY stock
;    counter at DI+0x0E (= player struct +0x24: P1 9EF4 / P2 9F32 —
;    the death sequence's 9800:39CE tests/decrements it and spawns
;    the death-fairy 0x2B). Clobbers AX BX CX. ──
bomb_fill:
    mov  al, 1                  ; NUKE slot value
    cmp  word [BOMB_TYPE], 0
    je   .haveval
    mov  al, 2                  ; CLUSTER slot value
.haveval:
    mov  cx, [BOMB_STOCK]       ; 0-7
    xor  bx, bx
.slot:
    cmp  bx, cx
    jae  .clear
    mov  [di+bx], al
    jmp  .next
.clear:
    mov  byte [di+bx], 0
.next:
    inc  bx
    cmp  bx, 8
    jb   .slot
    mov  ax, [FAIRY_VAR]
    mov  [di+0x0E], ax          ; fairy stock counter (0 = stock no-op)
    ret

; ============================================================
; PLAYER_BIT  — AX = WEAPON_ARMED pending-mask bit for the player
; struct at BX (9ED0 -> 1, 9F0E -> 2). Clobbers only AX.
; ============================================================
player_bit:
    mov  ax, 1
    cmp  bx, 0x9ED0
    je   .have
    mov  ax, 2
.have:
    ret

; ============================================================
; MAIN_OVERRIDE_IMPL  (B581:0068 — far-JMPed from ck_override in the
; primary blob, inside the 9AC35 hook; relocated for space. RETF here
; returns directly to the hook's caller.) BX = player struct, AX = 0
; on entry; must leave AX = 0.
; WEAPON_ARMED is a per-player PENDING bitmask (3 at menu confirm).
; A player whose bit is still set gets the menu mains on every init;
; the per-frame tick clears the bit once the player is ACTIVE, so
; only their first arrival (cold start or late join) is armed —
; deaths, game-over cleanup and CONTINUES re-init stock.
; ============================================================
main_override_impl:
    cmp  word [MENU_LIVE], 0
    je   .done                  ; plain game / demo: stock (AX still 0)
    call player_bit
    test word [WEAPON_ARMED], ax
    jz   .stock
    ; Enforce: if all main weapons are 0, set vulcan=1.
    mov  ax, [MW_VULCAN]
    or   ax, [MW_LASER]
    or   ax, [MW_PLASMA]
    jnz  .write
    mov  word [MW_VULCAN], 1
.write:
    mov  ax, [MW_VULCAN]
    mov  word [bx+0x06], ax
    mov  ax, [MW_LASER]
    mov  word [bx+0x08], ax
    mov  ax, [MW_PLASMA]
    mov  word [bx+0x0A], ax
.stock:
    xor  ax, ax                 ; restore AX=0 for caller
.done:
    retf

; ============================================================
; MENU_TICK_IMPL  (B581:0060 — far-called EVERY gameplay frame from
; the primary blob's per-frame hook). Two jobs:
;  1. Consume WEAPON_ARMED pending bits once their player is ACTIVE,
;     so that player's later inits (death/game-over/continue) are
;     stock. Safe ordering: a bit can only clear after the player's
;     armed init already ran (activation and init share a frame).
;  2. Deferred ITEM STOCK fill (BOMB_PEND): fills ONLY the arriving
;     player's bomb array — the other player's live stock must not
;     be refilled mid-game. Deferred a frame because 9AC0E writes
;     its own stock bombs after the hook sites inside the init.
; ============================================================
menu_tick_impl:
    push ax
    mov  ax, [WEAPON_ARMED]
    test ax, ax
    jz   .bombs
    test al, 1
    jz   .chk2
    cmp  word [0x9ED0], 0       ; P1 active?
    je   .chk2
    and  word [WEAPON_ARMED], 0xFFFE
.chk2:
    test al, 2
    jz   .bombs
    cmp  word [0x9F0E], 0       ; P2 active?
    je   .bombs
    and  word [WEAPON_ARMED], 0xFFFD
.bombs:
    cmp  word [BOMB_PEND], 0
    je   .done
    push bx
    push cx
    push di
    mov  di, [BOMB_PEND]
    add  di, 0x16               ; struct base -> bomb array (9EE6/9F24)
    call bomb_fill
    mov  word [BOMB_PEND], 0
    mov  word [0x9FB4], 1       ; HUD redraw
    pop  di
    pop  cx
    pop  bx
.done:
    pop  ax
    retf

; ============================================================
; WEAPON_INIT_IMPL  (B581:0058 — far-called via the B692:0028 vector
; from 9AC3B inside the 9AC0E player struct init; relocated from the
; primary blob for space). BX = player struct base, AX = 0 on entry.
; Armed players (WEAPON_ARMED pending bit set) get the menu sub levels.
; ============================================================
weapon_init_impl:
    ; Same per-player pending gate as main_override_impl. An armed init
    ; also schedules the deferred ITEM STOCK fill for this struct
    ; (9AC0E writes its stock bombs after this hook, so the fill runs
    ; next frame via the L2_BJOIN tick).
    cmp  word [MENU_LIVE], 0
    je   vwi_zeros              ; plain game / demo: stock (AX still 0)
    call player_bit
    test word [WEAPON_ARMED], ax
    jz   vwi_zeros_ax
    mov  [BOMB_PEND], bx

    mov  ax, [SW_NUCLEAR]
    or   ax, [SW_HOMING]
    jz   vwi_zeros_ax

    mov  ax, [SW_NUCLEAR]
    mov  word [bx+0x0E], ax
    mov  ax, [SW_HOMING]
    mov  word [bx+0x10], ax
    xor  ax, ax
    mov  word [bx+0x12], ax
    retf

vwi_zeros_ax:
    xor  ax, ax                 ; gate paths leave AX nonzero

vwi_zeros:
    mov  word [bx+0x0E], ax
    mov  word [bx+0x10], ax
    mov  word [bx+0x12], ax
    retf

; ── TITLE LOGO palette images at FIXED offsets (primary blob's
;    isr_rf reads them via DS=B581; L2_LOGO_WHITE/COLOR equates) ─
    times (0x500 - ($ - $$)) db 0
logo_pal_white:
    dw 0x2D00, 0x3543, 0x3D86, 0x4DC9, 0x5A6F, 0x5AB3, 0x6B37, 0x77BD, 0x11CC, 0x3292, 0x3A52, 0x46B5, 0x5318, 0x5F7B, 0x0000, 0x0000   ; line 36
    dw 0x318C, 0x35AD, 0x39CE, 0x3DEF, 0x4210, 0x4631, 0x4A52, 0x4E73, 0x56B5, 0x5EF7, 0x6739, 0x6F7B, 0x77BD, 0x7FFF, 0x00DC, 0x0000   ; line 37
    dw 0x18C6, 0x1CE7, 0x2108, 0x2529, 0x318C, 0x3DEF, 0x39CE, 0x4210, 0x4A52, 0x56B5, 0x6B5A, 0x6F7B, 0x739C, 0x7FFF, 0x0000, 0x0000   ; line 38
    dw 0x0013, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000   ; line 39
    dw 0x318C, 0x35AD, 0x39CE, 0x3DEF, 0x4210, 0x4631, 0x4A52, 0x4E73, 0x56B5, 0x5EF7, 0x6739, 0x6F7B, 0x77BD, 0x7FFF, 0x0000, 0x0000   ; line 40
    dw 0x08A5, 0x1508, 0x256B, 0x3631, 0x4294, 0x4AD6, 0x575A, 0x001F, 0x0084, 0x00E7, 0x01EF, 0x02D6, 0x1F7B, 0x7FFF, 0x0000, 0x0000   ; line 41
logo_pal_color:
    dw 0x20E6, 0x2507, 0x2927, 0x2D48, 0x398A, 0x45ED, 0x5272, 0x6F5A, 0x11CC, 0x3292, 0x3A52, 0x46B5, 0x5318, 0x5F7B, 0x0000, 0x0000   ; line 36
    ; Faithful demo-palette capture (user-approved). The title logo art
    ; uses ONLY line 38, indices 0-13 (marker-mapped); its near-black
    ; entries at 0-4 exist in the original game's palette and are kept
    ; as-is. (A re-authored navy-blue ramp was tried 2026-06-12 and
    ; rejected: the attract sequence renders the logo white/chrome, so
    ; there is no canonical "color" reference beyond this capture.)
    dw 0x0488, 0x0CEB, 0x114E, 0x21B1, 0x2440, 0x3900, 0x55C3, 0x0000, 0x14A4, 0x2529, 0x39CD, 0x4E72, 0x6738, 0x7BDD, 0x0000, 0x0000   ; line 37
    dw 0x00D0, 0x01F7, 0x02FE, 0x0015, 0x02D7, 0x44C0, 0x6180, 0x7EA0, 0x0000, 0x18C5, 0x318C, 0x4A51, 0x6317, 0x7BDD, 0x0000, 0x0000   ; line 38
    dw 0x00E0, 0x1206, 0x1EEB, 0x01F6, 0x033E, 0x44A0, 0x6563, 0x7A06, 0x0011, 0x007B, 0x2D29, 0x4A10, 0x6317, 0x7FFE, 0x0000, 0x0000   ; line 39
    dw 0x0862, 0x10C3, 0x1906, 0x1D27, 0x2568, 0x31CB, 0x3E2E, 0x4A91, 0x0C82, 0x18C5, 0x2528, 0x35AC, 0x4E72, 0x6737, 0x0000, 0x0000   ; line 40
    dw 0x0463, 0x0885, 0x14C7, 0x1909, 0x214B, 0x298D, 0x35EF, 0x4252, 0x1083, 0x18C4, 0x2527, 0x318A, 0x4A50, 0x5EF5, 0x0000, 0x0000   ; line 41

