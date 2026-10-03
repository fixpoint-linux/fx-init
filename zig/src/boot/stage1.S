/*
 * fx-init standalone disk image — BIOS MBR stage1 (fx-image unit U3).
 *
 * Real-mode, position-independent; BIOS loads us at 0000:7C00.
 * Read the FXIMG header sector (LBA 1) to 0x0600, verify its magic and
 * stage2 geometry, extended-read (INT13 AH=42h) stage2 to 0x7E00, CRC32
 * the copy against the header value, check the copy's 'F','X' magic,
 * far-jump to stage2.
 *
 * FXIMG header sector 0 (little-endian) — offsets stage1 READS; the fx-image
 * builder (U5) owns the full layout and must keep these frozen:
 *   +0x00  8s   magic "FXIMGv1\n"
 *   +0x08  u32  header version (stage1 does not check)
 *   +0x0C  u64  stage2_lba   (low 32 bits used; images are < 2 TiB)
 *   +0x14  u16  stage2_sectors   (stage1 enforces 1..60 -> dst < 0x10000)
 *   +0x16  u32  stage2_crc32     (crc32 of stage2_sectors*512 bytes at
 *                                 stage2_lba; reflected poly 0xEDB88320,
 *                                 init/final 0xFFFFFFFF == python zlib.crc32)
 *
 * debugcon markers (qemu -debugcon ... -global isa-debugcon.iobase=0x402):
 *   success: S start  E int13-ext ok  H header ok  C crc ok  J jump
 *            (stage2 then prints its own marker)
 *   failure: 1 no int13 extensions   2 header read      3 header magic
 *            4 stage2 geometry       5 stage2 read      6 crc mismatch
 *            7 copied magic mismatch — then halt
 *
 * Entry contract handed to stage2 at the far jump (POLICY, channel fx-image):
 *   CS:IP = 0000:7E02 (image bytes 0..1 are the 'F','X' magic DATA, never
 *           executed — 'F'=0x46=inc %si and 'X'=0x58=pop %ax would corrupt
 *           the handed-over state; stage2 code starts at image offset 2)
 *   DS = ES = SS = 0;  SP = 0x7C00 (empty stack); DF = 0
 *   DL = 0x80 (boot drive; INT13 extensions verified present for it)
 *   SI = 0x0600 (validated FXIMG header sector 0 still resident there)
 *   memory: stage2 image at 0x7E00, CRC-verified; all other regs undefined.
 *   stage2 image bytes 0..1 must be 'F','X' (0x46,0x58) — stage1 verifies
 *   the copy against this, so every stage2 build must start with them.
 *
 * Build (GNU):   as -o stage1.o zig/src/boot/stage1.S \
 *                  && objcopy -O binary --only-section=.text stage1.o stage1.bin
 * Build (zig):   zig cc -target x86_64-freestanding -c zig/src/boot/stage1.S \
 *                  -o stage1_z.o && objcopy -O binary --only-section=.text \
 *                  stage1_z.o stage1_z.bin     (bytes identical to GNU build)
 * Wrapper:       sh zig/src/boot/build-stage1.sh -o stage1.bin
 *
 * Hard limits: code+data <= 446 bytes (.org 446 fails the build if exceeded;
 * build-stage1.sh also asserts it); bytes 446..509 are the MBR partition
 * table (zeros here — the image builder writes the real entry); 510..511 = 55 AA.
 */

        .code16
        .section .text
        .globl _start

/* Constants: gas-native assignments, NOT cpp #define — plain `as` does not
 * run the preprocessor and on x86 gas '#' starts a comment, so #defines are
 * silently dropped and the names assemble as undefined symbols at value 0
 * (MEASURED: every macro operand encoded as 0x0000 in the GNU build).
 * Symbol assignments are supported by both GNU as and clang's assembler. */
HDR         = 0x600              /* FXIMG header sector base (DS=0) */
H_S2LBA     = HDR + 0x0c         /*   +0x0C u64 stage2_lba */
H_S2SEC     = HDR + 0x14         /*   +0x14 u16 stage2_sectors */
H_S2CRC     = HDR + 0x16         /*   +0x16 u32 stage2_crc32 */

S2_DST      = 0x7e00             /* stage2 destination; 0x7E00+60*512 = 0xF600 */
S2_MAX_SEC  = 60                 /* keep stage2 strictly below 0x10000 */
S2_MAGIC    = 0x5846             /* 'F' | 'X' << 8 (little-endian word) */

_start:
        xorw %ax, %ax
        movw %ax, %ds
        movw %ax, %es
        movw %ax, %ss
        movw $0x7c00, %sp
        cld
        jmp main                  /* never fall through into subroutines */

putc:                             /* AL -> debugcon 0x402; clobbers nothing */
        pushw %ax
        pushw %dx
        movw $0x402, %dx
        outb %al, %dx
        popw %dx
        popw %ax
        ret

crc32:                            /* DS:SI data, CX bytes -> EAX = crc32 */
        movl $0xffffffff, %eax
1:      xorl %ebx, %ebx
        movb (%si), %bl
        xorb %bl, %al             /* crc ^= byte (low 8 bits; ebx zeroed) */
        movw $8, %bx
2:      shrl $1, %eax
        jnc 3f
        xorl $0xedb88320, %eax
3:      decw %bx
        jnz 2b
        incw %si
        decw %cx
        jnz 1b
        notl %eax
        ret

die:
1:      hlt
        jmp 1b

fail:                             /* AL = failure marker; print it, halt */
        call putc
        jmp die

main:
        movb $'S', %al
        call putc

        /* INT13 extensions: AH=41h must give BX=0xAA55 and CX bit0 (DAP) */
        movw $0x55aa, %bx
        movb $0x41, %ah
        movb $0x80, %dl
        int $0x13
        jc no_ext
        cmpw $0xaa55, %bx
        jne no_ext
        testb $1, %cl
        jz no_ext

        movb $'E', %al
        call putc

        /* read FXIMG header sector 0 (LBA 1) to 0x0600 */
        movw $0x7c00, %si
        addw $(dap_hdr - _start), %si
        movb $0x42, %ah
        movb $0x80, %dl           /* reload DL before EVERY INT13 */
        int $0x13
        jc hdr_rd_err

        /* magic "FXIMGv1\n" */
        cmpl $0x4d495846, HDR     /* "FXIM" */
        jne bad_magic
        cmpl $0x0a317647, HDR+4   /* "Gv1\n" */
        jne bad_magic

        movb $'H', %al
        call putc

        /* stage2 geometry: 1..S2_MAX_SEC sectors */
        movw H_S2SEC, %cx
        testw %cx, %cx
        jz bad_geom
        cmpw $S2_MAX_SEC, %cx
        ja bad_geom

        /* patch DAP (count, LBA) and read stage2 to 0x7E00 */
        movw $0x7c00, %si
        addw $(dap_s2 - _start), %si
        movw %cx, 2(%si)
        movl H_S2LBA, %eax
        movl %eax, 8(%si)
        movb $0x42, %ah
        movb $0x80, %dl
        int $0x13
        jc s2_rd_err

        /* CRC32 the copy; compare against the header value */
        movw H_S2SEC, %cx
        shl $9, %cx               /* sectors -> bytes (<= 30720, fits u16) */
        movw $S2_DST, %si
        call crc32
        movl H_S2CRC, %edx
        cmpl %edx, %eax
        jne bad_crc

        movb $'C', %al
        call putc

        /* copied image must begin 'F','X' */
        cmpw $S2_MAGIC, S2_DST
        jne bad_s2magic

        movb $'J', %al
        call putc
        movw $HDR, %si            /* entry contract: SI = header sector */
        movb $0x80, %dl           /* entry contract: DL = boot drive */
        ljmp $0, $(S2_DST + 2)    /* +2: skip the 'F','X' data magic */

no_ext:       movb $'1', %al
        jmp fail
hdr_rd_err:   movb $'2', %al
        jmp fail
bad_magic:    movb $'3', %al
        jmp fail
bad_geom:     movb $'4', %al
        jmp fail
s2_rd_err:    movb $'5', %al
        jmp fail
bad_crc:      movb $'6', %al
        jmp fail
bad_s2magic:  movb $'7', %al
        jmp fail

        /* no alignment padding here on purpose: as and clang pick different
         * nop/fill encodings (89 f6 vs 66 90) and INT13 needs no aligned DAP;
         * zero padding anywhere would also work, but none is needed */
dap_hdr:                         /* static: 1 sector, LBA 1 -> 0000:0600 */
        .byte 0x10, 0x00
        .word 0x0001
        .word 0x0600, 0x0000     /* buffer offset THEN segment */
        .quad 0x0000000000000001
dap_s2:                          /* patched at runtime: count + LBA */
        .byte 0x10, 0x00
        .word 0x0000             /* <- stage2_sectors */
        .word S2_DST, 0x0000     /* buffer offset THEN segment */
        .quad 0x0000000000000000 /* <- stage2_lba (low dword) */

        .org 446                 /* hard size gate: build fails if code > 446 */
        .fill 64, 1, 0           /* partition table — written by image builder */
        .word 0xaa55             /* bytes 510..511 = 55 AA */
