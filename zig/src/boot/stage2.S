/*
 * fx-init standalone disk image — BIOS MBR stage2 (fx-image unit U4).
 *
 * Entered by stage1 (zig/src/boot/stage1.S) per the frozen entry contract:
 *   CS:IP = 0000:7E02   (image bytes 0..1 are the 'F','X' DATA magic,
 *                        never executed — see stage1.S)
 *   DS = ES = SS = 0; SP = 0x7C00 (empty stack); DF = 0; DL = 0x80
 *   SI = 0x600 (stage1's validated FXIMG header sector 0)
 *   this image at 0x7E00, CRC32-verified by stage1 (1..60 sectors).
 *
 * What it does (the M-1 loader):
 *   1. re-reads the full 4 KiB FX header (LBA 1..8) to 0x600 — stage1
 *      leaves only sector 0 resident, and the cmdline spans sectors 0..4
 *   2. copies the baked cmdline to 0x20000 (NUL-terminated, clamped 2047)
 *   3. loads the kernel's SETUP part to 0x10000 (setup_sects read from the
 *      kernel's own header at +0x1F1; validated against its 55 AA + HdrS),
 *      then chunk-loads the PROTECTED-MODE part to 0x1000000 EXACTLY (the
 *      pinned bzImage is NON-relocatable: pref_address 0x1000000 measured,
 *      relocatable=0, protocol 2.15, init_size 0xF55000 stays below the
 *      initrd at 0x2000000)
 *   4. chunk-loads the initrd to 0x2000000
 *   5. patches boot_params at 0x10000:
 *        +0x210 type_of_loader = 0xFF (unknown loader)
 *        +0x211 loadflags      |= LOADED_HIGH (we load at 0x1000000)
 *        +0x214 code32_start    = 0x1000000  (MEASURED: the pinned image's
 *          build-time default is 0x100000, NOT the 16 MiB pref_address —
 *          the kernel's setup jumps to code32_start, so a loader that
 *          loads at pref MUST patch this; syslinux/QEMU's -kernel do)
 *        +0x218 ramdisk_image   = 0x2000000
 *        +0x21C ramdisk_size    = initrd_sectors*512 (sector-rounded: the
 *          FX header has no byte-size field; gzip/newc stop at their own
 *          end markers, and rounded initrd sizes are what real bootloaders
 *          hand the kernel — the zero tail is padding, not payload)
 *        +0x228 cmd_line_ptr    = 0x20000
 *   6. far-jumps to the kernel setup entry 0x1000:0x0200
 *
 * High-memory mechanism (SETTLED by the M-0 spike — do not re-litigate):
 * INT15 AH=87h is the primary per-chunk copy; a protected-mode rep-movsb
 * excursion is the per-chunk fallback if any 87h call refuses (CF=1).
 * M-0's rules, all MEASURED on SeaBIOS/qemu 11.1.1 (KVM + TCG):
 *   - 87h CX counts WORDS, max 0xFFFF/call  -> chunks are 64 sectors
 *     (0x4000 words), and any larger copy needs multiple calls
 *   - the 87h GDT (0x30 bytes) lives in RAM, src/dst LINEAR base fields
 *     patched PER CALL (linear addresses, not seg:off); SeaBIOS scratches
 *     the bytes at GDT+0x08 and GDT+0x20, so it is re-zeroed per call
 *   - every PM excursion is wrapped in cli (no PM IDT)
 *   - the canonical PM->RM path: far-jmp to 16-bit PM code FIRST, reload
 *     16-bit data segs, THEN clear PE, THEN far-jmp to an RM segment.
 *     (Clearing PE from still-32-bit code = KVM emulation failure / hang.)
 *   - GAS .code16 label absolutes resolve at section base 0: in-image
 *     labels are only ever used as `label - _start + 0x7e00` (a constant
 *     expression); `$label` alone would emit a relocation objcopy drops
 *   - reload DL=0x80 before EVERY INT13; never fall through into
 *     subroutines; no .align directives (as and clang pad differently —
 *     the PM GDT is copied at runtime to a fixed 8-aligned address instead)
 *
 * Every chunk is VERIFIED after the copy: the 87h arm copies the bytes
 * BACK OUT to a scratch buffer and rep-cmpsw's them against the bounce
 * buffer; the PM arm flat-compares in PM.  This catches wrong LBA/dst
 * patching, word-count errors and A20-masked aliasing, per chunk.  Scope
 * note (honest): the 87h verify shares patch_desc with the copy, so a
 * systematic patch_desc bug would be self-consistent — that class is
 * covered by M-0's independent flat-PM byte verification of patch_desc
 * and by the real-kernel boot gate.
 *
 * FX header fields READ here (offsets owned by U5's byte_layout in
 * zig/src/image.zig, little-endian; the stage2 trio at +0x0C/+0x14/+0x16
 * is stage1's frozen contract):
 *   +0x28  u64  kernel_lba     (low dword; images are < 2 TiB)
 *   +0x30  u64  kernel_sectors (low dword; setup+PM together)
 *   +0x38  u64  initrd_lba
 *   +0x40  u64  initrd_sectors (low dword; 0 = no initrd)
 *   +0x48  u32  cmdline_len    (clamped to 2047 = cmdline_size)
 *   +0x140 ..   cmdline, NUL-padded
 *
 * Memory map while stage2 runs (nothing clobbers the 0x7E00 image, the
 * 0x600 header, or the stack at 0x7C00; 0x500.. is free conventional
 * memory — M-0 measured SeaBIOS respects it):
 *   0x0500 87h GDT (0x30 B, re-initialized per call)
 *   0x0538 loop vars (LBA/rem/chunk/dst/setup-total/arm/blob/saved-sp)
 *   0x0558 lgdt pseudo-descriptor (limit 0x27, base 0x560)
 *   0x0560 PM GDT (5 descriptors, 40 B, copied from the image at init)
 *   0x0600 full 4 KiB FX header (self-read; cmdline at 0x740..0x940)
 *   0x7000 PM-excursion stack (grows down, far from the 0x7C00 RM stack)
 *   0x7E00 this image (<= 60 sectors, stage1-enforced)
 *   0x10000 kernel setup + boot_params (16 KiB; setup heap ends 0x14F80)
 *   0x20000 cmdline copy (<= 2048 B, above the setup heap)
 *   0x30000 bounce buffer (64-sector chunks; 64 KiB-aligned so a chunk
 *          never crosses a 64 KiB line — the conservative INT13 rule the
 *          M-0 spike did not exercise)
 *   0x40000 verify scratch (87h copy-back target, also 64 KiB-aligned)
 *   0x1000000 kernel PM code (pref_address)
 *   0x2000000 initrd (above init_size end 0x1F55000)
 *
 * debugcon markers (qemu -debugcon file:... -global isa-debugcon.iobase=0x402):
 *   success: 2 entered  H header resident  c cmdline copied  k setup loaded
 *            g A20 confirmed  K kernel PM loaded+verified  I initrd
 *            loaded+verified  P params patched  E entering kernel
 *            ('F' appears once if any 87h call refused and the PM
 *            fallback copy took over — SeaBIOS implements 87h, so a
 *            healthy boot shows no 'F')
 *   failure: h header read  m header magic  s kernel geometry
 *            i initrd geometry  q A20 stuck  r INT13 data read (phase =
 *            the last phase marker: before 'k' setup, before 'K' kernel
 *            PM, before 'I' initrd)  x kernel verify mismatch
 *            X initrd verify mismatch — then halt.
 *
 * Build (GNU):  as -o stage2.o stage2.S && objcopy -O binary
 *               --only-section=.text stage2.o stage2.bin
 * Build (zig):  zig cc -target x86_64-freestanding -c stage2.S (byte-identical)
 * Wrapper:      sh zig/src/boot/build-stage2.sh [-o stage2.bin] [--toolchain ...]
 */

        .code16
        .section .text
        .globl _start

/* constants — gas symbol assignments, NOT cpp #define (plain `as` runs no
 * preprocessor and '#' starts a comment; MEASURED in U3: #defines assemble
 * as undefined symbols at value 0 in every operand) */
HDR       = 0x600                   /* full 4 KiB FX header (self-read)   */
H_KLBA    = HDR + 0x28              /* u64 kernel_lba (low dword)         */
H_KSEC    = HDR + 0x30              /* u64 kernel_sectors (low dword)     */
H_ILBA    = HDR + 0x38              /* u64 initrd_lba                     */
H_ISEC    = HDR + 0x40              /* u64 initrd_sectors (low dword)     */
H_CMDLEN  = HDR + 0x48              /* u32 cmdline_len                    */
H_CMD     = HDR + 0x140             /* cmdline bytes                      */

GDT87     = 0x500                   /* INT15-87h GDT, 0x30 bytes          */
V_LBA     = 0x538                   /* u32 current chunk LBA              */
V_REM     = 0x53c                   /* u32 sectors remaining              */
V_CSEC    = 0x540                   /* u16 sectors in this chunk          */
V_DST     = 0x544                   /* u32 high dest linear address       */
V_SETTOT  = 0x548                   /* u8  total setup sectors (sect+1)   */
V_PM      = 0x549                   /* u8  nonzero = a PM fallback ran    */
V_BLOB    = 0x54a                   /* u8  0=kernel 1=initrd (fail codes) */
V_SP      = 0x54c                   /* u16 RM SP saved across PM trips    */
GDTR      = 0x550                   /* lgdt pseudo-desc: word limit,      */
                                    /* dword base 0x560                   */
PMGDT     = 0x560                   /* PM GDT, 5 descriptors, 8-aligned   */
/* every var above is disjoint (4-byte-aligned dwords, standalone bytes) —
 * an overlapping scratch layout here silently corrupts loop state (the
 * V_CSEC-inside-V_REM mistake this table replaces looped forever) */

SETUP_BUF = 0x10000                 /* kernel setup + boot_params         */
SETUP_SEG = 0x1000
CMDLINE   = 0x20000                 /* cmdline copy                       */
CMD_SEG   = 0x2000
BOUNCE    = 0x30000                 /* INT13 chunk buffer (64K-aligned)   */
BOUNCE_SEG = 0x3000
SCRATCH   = 0x40000                 /* 87h verify copy-back (64K-aligned) */
SCRATCH_SEG = 0x4000
PM_BASE   = 0x1000000               /* kernel pref_address (measured)     */
INITRD    = 0x2000000               /* initrd load address                */
CHUNK     = 64                      /* sectors per read+copy (0x4000 words) */
MAX_BLOB  = 0x10000                 /* sanity cap: 32 MiB per blob        */
MAX_SETUP = 60                      /* setup_sects cap: stays under 0x20000 */

_start:
        .byte 0x46, 0x58            /* 'F','X' — data magic stage1 checks */
entry:                               /* stage1 far-jumps to 0000:7E02      */
        xorw %ax, %ax
        movw %ax, %ds
        movw %ax, %es
        movw %ax, %ss
        movw $0x7c00, %sp
        cld
        jmp main                    /* never fall through into putc       */

putc:                                /* AL -> debugcon 0x402               */
        pushw %ax
        pushw %dx
        movw $0x402, %dx
        outb %al, %dx
        popw %dx
        popw %ax
        ret

/* patch one 87h copy descriptor: ES:DI = descriptor linear, EAX = base32 */
patch_desc:
        pushw %di
        movw $0xffff, %es:(%di)     /* limit lo (byte-granular 64 KiB)    */
        movb %al, %es:2(%di)
        movb %ah, %es:3(%di)
        shrl $16, %eax
        movb %al, %es:4(%di)
        movb $0x93, %es:5(%di)      /* present, data, rw                  */
        movb $0x00, %es:6(%di)
        movb %ah, %es:7(%di)
        popw %di
        ret

die:
1:      hlt
        jmp 1b

fail:                                /* AL = failure marker; print, halt   */
        call putc
        jmp die

/* A20 wraparound test 0000:0500 vs FFFF:0510; CF=0 on, CF=1 stuck.
 * Runs BEFORE the GDT/vars area is initialized (it writes at 0x500) */
a20test:
        pushaw
        pushw %ds
        pushw %es
        xorw %ax, %ax
        movw %ax, %ds
        movw $0xffff, %ax
        movw %ax, %es
        movw $0x0500, %bx
        movw $0x0510, %di           /* FFFF:0510 = 0x100500 if A20 on     */
        mov (%bx), %ax
        notw %ax
        mov %ax, (%bx)         /* write ~w0                          */
        cmpw %ax, %es:(%di)         /* saw it through FFFF:0510?          */
        jne a20_on                  /* no alias -> A20 on                 */
        notw %ax
        mov %ax, (%bx)         /* restore; aliased -> A20 off        */
        popw %es
        popw %ds
        popaw
        stc
        ret
a20_on:
        notw %ax
        mov %ax, (%bx)
        popw %es
        popw %ds
        popaw
        clc
        ret

a20ensure:
        call a20test
        jnc a20_done
        inb $0x92, %al              /* fast A20 gate                      */
        orb $2, %al
        andb $0xfe, %al             /* never touch bit 0 (fast reset)     */
        outb %al, $0x92
        call a20test
        jnc a20_done
        movw $0x2401, %ax           /* INT15 2401h backup                 */
        int $0x15
        call a20test
a20_done:
        ret

main:
        movb $'2', %al
        call putc

/* ---- full 4 KiB header (LBA 1..8) -> 0x600; re-verify the magic ------- */
        movw $0x7e00, %si
        addw $(dap_hdr - _start), %si
        movb $0x42, %ah
        movb $0x80, %dl             /* reload DL before EVERY INT13       */
        int $0x13
        jc hdr_fail
        cmpl $0x4d495846, HDR       /* "FXIM"                             */
        jne magic_fail
        cmpl $0x0a317647, HDR+4     /* "Gv1\n"                            */
        jne magic_fail
        movb $'H', %al
        call putc

/* ---- cmdline: H_CMD -> 0x20000, NUL-terminated, clamped to 2047 ------- */
        movl H_CMDLEN, %eax
        cmpw $2047, %ax
        jbe 31f
        movw $2047, %ax
31:     movw %ax, %cx
        movw $CMD_SEG, %ax
        movw %ax, %es
        xorw %di, %di
        movw $H_CMD, %si
        cld
        rep movsb
        movb $0, %es:(%di)
        xorw %ax, %ax
        movw %ax, %es
        movb $'c', %al
        call putc

/* ---- kernel SETUP part -> 0x10000 ------------------------------------ */
/* sector 0 first: setup_sects lives at +0x1F1 of the loaded boot sector  */
        movw $0x7e00, %si
        addw $(dap_k0 - _start), %si
        movl H_KLBA, %eax
        movl %eax, 8(%si)
        movb $0x42, %ah
        movb $0x80, %dl
        int $0x13
        jc rd_fail

        /* sector-0 fields only: boot_flag 55 AA at +0x1FE, setup_sects at
         * +0x1F1.  "HdrS" is at +0x202 = 514 = the SECOND setup sector —
         * it is checked after the rest of setup is loaded (a check here
         * would read not-yet-loaded RAM; MEASURED: 0x10202 still zero) */
        movw $SETUP_SEG, %ax
        movw %ax, %es
        movw %es:0x1fe, %dx
        movb %es:0x1f1, %cl
        xorw %ax, %ax
        movw %ax, %es
        cmpw $0xaa55, %dx
        jne geom1_fail
        orb %cl, %cl                /* 0 -> the protocol default of 4     */
        jnz 33f
        movb $4, %cl
33:     cmpb $MAX_SETUP, %cl
        ja geom_fail
        incb %cl                    /* total setup sectors = setup_sects+1 */
        movb %cl, V_SETTOT

        /* remaining setup sectors: LBA kernel_lba+1 -> 0x10200 */
        movw $0x7e00, %si
        addw $(dap_set - _start), %si
        decb %cl
        movb $0, %ch
        testw %cx, %cx
        jz 34f
        movw %cx, 2(%si)
        movl H_KLBA, %eax
        incl %eax
        movl %eax, 8(%si)
        movb $0x42, %ah
        movb $0x80, %dl
        int $0x13
        jc rd_fail
34:     /* now "HdrS" is resident: +0x202 of the setup image */
        movw $SETUP_SEG, %ax
        movw %ax, %es
        movl %es:0x202, %edi
        xorw %ax, %ax
        movw %ax, %es
        cmpl $0x53726448, %edi      /* "HdrS" (LE dword of 48 64 72 53)   */
        jne geom2_fail
        movb $'k', %al
        call putc

/* ---- A20 on (the 87h/PM copies above 1 MiB need it) ------------------- */
        call a20ensure
        jnc 35f
        movb $'q', %al
        jmp fail
35:     movb $'g', %al
        call putc

/* ---- PM GDT -> 0x560 + vars (after a20test's probe write at 0x500) ---- */
        movw $PMGDT, %di
        movw $(gdt - _start + 0x7e00), %si
        movw $20, %cx
        cld
        rep movsw
        movw $0x27, GDTR            /* limit: 5 descriptors * 8 - 1       */
        movl $PMGDT, GDTR+2
        movb $0, V_PM

/* ---- kernel PROTECTED-MODE part -> 0x1000000, chunked + verified ------ */
        movl H_KSEC, %eax           /* u64 low dword                      */
        movzbl V_SETTOT, %ecx
        cmpl %ecx, %eax             /* kernel smaller than its own setup? */
        jb geom_fail
        subl %ecx, %eax             /* PM sectors                         */
        cmpl $MAX_BLOB, %eax
        ja geom_fail
        movl %eax, V_REM
        movl H_KLBA, %eax
        addl %ecx, %eax             /* first PM sector                    */
        movl %eax, V_LBA
        movl $PM_BASE, %eax
        movl %eax, V_DST
        movb $0, V_BLOB
        call chunk_loop
        movb $'K', %al
        call putc

/* ---- initrd -> 0x2000000, chunked + verified -------------------------- */
        movl H_ILBA, %eax
        movl %eax, V_LBA
        movl H_ISEC, %eax
        testl %eax, %eax
        jz 36f                      /* no initrd: patch size 0, skip load */
        cmpl $MAX_BLOB, %eax
        ja ird_fail
        movl %eax, V_REM
        movl $INITRD, %eax
        movl %eax, V_DST
        movb $1, V_BLOB
        call chunk_loop
36:     movb $'I', %al
        call putc

/* ---- patch boot_params (ES = 0x1000, the setup base) ------------------ */
        movw $SETUP_SEG, %ax
        movw %ax, %es
        movb $0xff, %es:0x210       /* type_of_loader = unknown           */
        orb $0x81, %es:0x211        /* loadflags |= LOADED_HIGH |
                                       CAN_USE_HEAP — MEASURED: bit 7 is
                                       what setup's init_heap tests; clear
                                       -> "Ancient bootloader" tiny-heap
                                       branch -> dies pre-decompressor.
                                       QEMU's -kernel leaves 0x81 here.
                                       (KEEP_SEGMENTS is bit 6 — NOT set) */
        movl $PM_BASE, %eax
        movl %eax, %es:0x214        /* code32_start = actual load address */
        movl $INITRD, %eax
        movl %eax, %es:0x218        /* ramdisk_image                      */
        movl H_ISEC, %eax           /* u64 low dword                      */
        shll $9, %eax               /* sectors -> bytes (sector-rounded)  */
        movl %eax, %es:0x21c        /* ramdisk_size                       */
        movl $CMDLINE, %eax
        movl %eax, %es:0x228        /* cmd_line_ptr (linear)              */
        xorw %ax, %ax
        movw %ax, %es
        movb $'P', %al
        call putc

/* ---- hand off to the kernel setup entry -------------------------------
 * The kernel's real-mode entry (arch/x86/boot/header.S start_of_setup)
 * does `push %ds; push $0x2a3; lret` as its SECOND act — it jumps to
 * DS:0x2a3, i.e. it REQUIRES DS = the setup segment (0x1000).  We set
 * CS=DS=ES=SS=0x1000 (the canonical loader handoff, what syslinux and
 * QEMU's -kernel leave behind) and a stack just under the 0x200 entry
 * (the boot protocol's own "stack at 0x9000:0xe000"-style convention,
 * keeping the heap above 0x200 untouched).
 */
        movb $'E', %al
        call putc
        xorl %esi, %esi             /* boot.rst: ESI must not point at
                                       memory (EDD30 signature probe)     */
        movw $SETUP_SEG, %ax
        movw %ax, %ds
        movw %ax, %es
        xorw %ax, %ax
        movw %ax, %ss               /* SS != DS: setup then computes its
                                       own SP = heap_end_ptr + 0x400 (its
                                       canonical choice).  With SS == DS
                                       it would KEEP our SP; any SP low
                                       enough to be under the setup heap's
                                       static end (~0x4b4c) clamps
                                       heap_end below the allocator and
                                       heap writes smash the stack (the
                                       garbage-retl death, MEASURED)      */
        movb $0x80, %dl             /* boot drive                         */
        ljmp $SETUP_SEG, $0x0200    /* setup_seg:0x0200                   */

hdr_fail:   movb $'h', %al
        jmp fail
magic_fail: movb $'m', %al
        jmp fail
geom_fail:  movb $'s', %al
        jmp fail
geom1_fail: movb $'1', %al          /* boot_flag 55 AA missing            */
        jmp fail
geom2_fail: movb $'2', %al          /* "HdrS" magic missing                */
        jmp fail
ird_fail:   movb $'i', %al
        jmp fail
rd_fail:    movb $'r', %al
        jmp fail

/* ---- chunk_loop: read+copy+verify V_REM sectors in 64-sector chunks ---
 * state in the 0x538 vars; prints 'r' on INT13 failure, 'x'/'X' on a
 * kernel/initrd verify mismatch (via high_copy).                        */
chunk_loop:
1:      movl V_REM, %eax
        testl %eax, %eax
        jz 3f
        cmpl $CHUNK, %eax
        jbe 2f
        movl $CHUNK, %eax
2:      movw %ax, V_CSEC
        movw $0x7e00, %si
        addw $(dap_chunk - _start), %si
        movw V_CSEC, %ax
        movw %ax, 2(%si)
        movl V_LBA, %eax
        movl %eax, 8(%si)
        movb $0x42, %ah
        movb $0x80, %dl
        int $0x13
        jnc 4f
        movb $'r', %al
        jmp fail
4:      call high_copy
        movzwl V_CSEC, %eax
        addl %eax, V_LBA
        subl %eax, V_REM
        shll $9, %eax
        addl %eax, V_DST
        jmp 1b
3:      ret

/* ---- high_copy: BOUNCE -> V_DST, V_CSEC sectors, then verify ---------- */
high_copy:
        /* 87h GDT at 0x500: zero all 0x30 bytes (SeaBIOS scratches
         * GDT+0x08/+0x20), then patch src=BOUNCE dst=V_DST per call */
        xorw %ax, %ax
        movw %ax, %es
        movw $GDT87, %di
        movw $0x18, %cx
        cld
        rep stosw
        movw $GDT87+0x10, %di
        movl $BOUNCE, %eax
        call patch_desc
        movw $GDT87+0x18, %di
        movl V_DST, %eax
        call patch_desc
        movzwl V_CSEC, %eax         /* CX counts WORDS (M-0 rule)         */
        shlw $8, %ax
        movw %ax, %cx
        movw $GDT87, %si
        movw $0x8700, %ax
        int $0x15
        jnc hc_verify

hc_fallback:                        /* 87h refused -> PM copy this chunk  */
        cmpb $0, V_PM
        jne 37f
        movb $1, V_PM
        movb $'F', %al
        call putc
37:     jmp hc_pm

hc_verify:
        /* copy the bytes BACK OUT to SCRATCH and compare with BOUNCE */
        movw $GDT87+0x10, %di
        movl V_DST, %eax
        call patch_desc
        movw $GDT87+0x18, %di
        movl $SCRATCH, %eax
        call patch_desc
        movzwl V_CSEC, %eax
        shlw $8, %ax
        movw %ax, %cx
        movw $GDT87, %si
        movw $0x8700, %ax
        int $0x15
        jc hc_fallback              /* copy-back refused -> verify in PM  */
        movzwl V_CSEC, %eax         /* read the count while DS is still 0
                                       — after the seg switch below, 0x540
                                       would read INSIDE the bounce buffer
                                       (vacuous-compare bug: CX=garbage<<8,
                                       often 0 -> repz cmpsw compares
                                       nothing and every chunk "passes") */
        shlw $8, %ax
        movw %ax, %cx
        movw $BOUNCE_SEG, %ax
        movw %ax, %ds
        movw $SCRATCH_SEG, %ax
        movw %ax, %es
        xorw %si, %si
        xorw %di, %di
        cld
        repe cmpsw
        jne hc_bad
        xorw %ax, %ax               /* back to flat segment bases         */
        movw %ax, %ds
        movw %ax, %es
        ret

hc_bad:
        cmpb $1, V_BLOB
        je 38f
        movb $'x', %al
        jmp fail
38:     movb $'X', %al
        jmp fail

/* ---- PM fallback: flat copy + verify, canonical PM->RM exit ----------- */
hc_pm:
        movw %sp, V_SP              /* the excursion resets SP; save it   */
        cli                         /* no PM IDT — M-0 rule               */
        xorw %ax, %ax
        movw %ax, %ds
        movw %ax, %es
        lgdtl GDTR
        movl %cr0, %eax
        orl $1, %eax
        movl %eax, %cr0
        ljmp $0x08, $(pm32c - _start + 0x7e00)

        .code32
pm32c:
        movw $0x10, %ax             /* flat data                          */
        movw %ax, %ds
        movw %ax, %es
        movw %ax, %ss
        movl $0x7000, %esp          /* own stack, clear of the RM stack   */
        movl $BOUNCE, %esi
        movl V_DST, %edi
        movzwl V_CSEC, %ecx
        shll $9, %ecx
        cld
        rep movsb                 /* bare form: explicit operands encode
                                       differently in as vs clang (U3 R9) */
        movl $BOUNCE, %esi
        movl V_DST, %edi
        movzwl V_CSEC, %ecx
        shll $9, %ecx
        repe cmpsb
        jne pm_bad
        ljmp $0x18, $(pm16c - _start + 0x7e00)

pm_bad:                             /* verify mismatch inside PM          */
        movl $0x402, %edx
        movl $'x', %eax
        cmpb $1, V_BLOB
        jne 39f
        movl $'X', %eax
39:     outb %al, %dx
2:      hlt
        jmp 2b

        .code16
pm16c:                              /* 16-bit PM code, PE still 1         */
        movw $0x20, %ax             /* 16-bit PM data selectors           */
        movw %ax, %ds
        movw %ax, %es
        movw %ax, %ss
        movw $0x7c00, %sp
        movl %cr0, %eax
        andl $0xfffffffe, %eax      /* clear PE ...                       */
        movl %eax, %cr0
        ljmp $0x0000, $(rm_ret - _start + 0x7e00)  /* ... THEN reload CS  */

rm_ret:
        xorw %ax, %ax               /* back in real mode                  */
        movw %ax, %ds
        movw %ax, %es
        movw %ax, %ss
        movw V_SP, %sp              /* the caller's frame again           */
        sti
        ret

/* ---- data ------------------------------------------------------------ */
gdt:
        .quad 0x0000000000000000          /* 0x00 null                   */
        .quad 0x00cf9a000000ffff          /* 0x08 code32 flat 4G         */
        .quad 0x00cf92000000ffff          /* 0x10 data32 flat 4G         */
        .quad 0x00009a000000ffff          /* 0x18 code16 PM, base 0, 64K */
        .quad 0x000092000000ffff          /* 0x20 data16 PM, base 0, 64K */

dap_hdr:                             /* static: 8 sectors, LBA 1 -> 0x600 */
        .byte 0x10, 0x00
        .word 0x0008
        .word 0x0600, 0x0000         /* buffer offset THEN segment        */
        .quad 0x0000000000000001

dap_k0:                              /* patched: kernel LBA -> 0x10000    */
        .byte 0x10, 0x00
        .word 0x0001
        .word 0x0000, 0x1000
        .quad 0x0000000000000000

dap_set:                             /* patched: count, LBA -> 0x10200    */
        .byte 0x10, 0x00
        .word 0x0000
        .word 0x0200, 0x1000
        .quad 0x0000000000000000

dap_chunk:                           /* patched: count, LBA -> 0x30000    */
        .byte 0x10, 0x00
        .word 0x0000
        .word 0x0000, 0x3000
        .quad 0x0000000000000000
