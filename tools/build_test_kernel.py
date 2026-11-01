#!/usr/bin/env python3
"""Build a minimal standalone arm64 Mach-O kernel for OnePlus 6T early bringup."""
import os, struct, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(ROOT, "xnu/out")
os.makedirs(OUT_DIR, exist_ok=True)

ASM_SRC = """
    .text
    .globl _start
    .align 4

_start:
    /* x0 contains physical pointer to boot_args */
    mov x19, x0                 /* save boot_args */

    /* struct boot_args:
     * Revision: u16 (offset 0)
     * Version:  u16 (offset 2)
     * virtBase: u64 (offset 4)
     * physBase: u64 (offset 12)
     * memSize:  u64 (offset 20)
     * topOfKernelData: u64 (offset 28)
     * Video.v_baseAddr: u64 (offset 40)
     * Video.v_display:  u64 (offset 48)
     * Video.v_rowBytes: u64 (offset 56)
     * Video.v_width:    u64 (offset 64)
     * Video.v_height:   u64 (offset 72)
     * Video.v_depth:    u64 (offset 80)
     */
    ldr x20, [x19, #40]         /* FB base (0x9d400000) */
    ldr x21, [x19, #64]         /* width (1080) */
    ldr x22, [x19, #72]         /* height (2340) */
    ldr x23, [x19, #56]         /* rowBytes (4320) */

    /* Fill screen with Apple Lock/Boot Screen Black (0xFF000000) */
    mov w24, #0
    mov x1, x20
    mul x2, x21, x22            /* total pixels */
1:
    str w24, [x1], #4
    subs x2, x2, #1
    b.ne 1b

    /* Draw Apple white glyph in center of 1080x2340 screen */
    /* Center box: x from 460 to 620 (width 160), y from 1050 to 1290 (height 240) */
    mov w25, #0xffffff          /* white color */
    mov x3, #1050               /* y start */
2:
    mov x4, #460                /* x start */
3:
    /* p = FB + y * rowBytes + x * 4 */
    mul x5, x3, x23
    add x5, x20, x5
    add x5, x5, x4, lsl #2
    str w25, [x5]

    add x4, x4, #1
    cmp x4, #620
    b.ne 3b

    add x3, x3, #1
    cmp x3, #1290
    b.ne 2b

    /* Draw small indicator bar at bottom */
    mov x3, #1800
4:
    mov x4, #340
5:
    mul x5, x3, x23
    add x5, x20, x5
    add x5, x5, x4, lsl #2
    str w25, [x5]
    add x4, x4, #1
    cmp x4, #740
    b.ne 5b
    add x3, x3, #1
    cmp x3, #1810
    b.ne 4b

halt_loop:
    wfe
    b halt_loop
"""

s_file = "/tmp/test_kernel.S"
o_file = "/tmp/test_kernel.o"
bin_file = "/tmp/test_kernel.bin"
with open(s_file, "w") as f:
    f.write(ASM_SRC)

subprocess.run(["aarch64-linux-gnu-gcc", "-c", s_file, "-o", o_file], check=True)
subprocess.run(["aarch64-linux-gnu-objcopy", "-O", "binary", o_file, bin_file], check=True)

with open(bin_file, "rb") as f:
    raw_code = f.read()

# Wrap raw_code into a minimal 64-bit Mach-O executable
# Mach-O load commands:
# LC_SEGMENT_64 for __TEXT (vmaddr=0xfffffe0007004000)
# LC_UNIXTHREAD with PC = 0xfffffe0007004000
VM_BASE = 0xfffffe0007004000
TEXT_SIZE = (len(raw_code) + 0x3fff) & ~0x3fff

hdr = struct.pack("<8I", 0xfeedfacf, 0x0100000c, 0, 2, 2, 72 + 80 + 16 + 32*8, 1, 0)
seg_name = b"__TEXT" + b"\0"*10
cmd_seg = struct.pack("<II16s4Q4I",
    0x19, 72 + 80, seg_name,
    VM_BASE, 0x4000, 0, 0x4000,
    7, 5, 1, 0
)
sect_name = b"__text" + b"\0"*10
sect = struct.pack("<16s16s2Q4I4I",
    sect_name, seg_name,
    VM_BASE + 0x400, len(raw_code),
    0x400, 2, 0, 0,
    0x80000400, 0, 0, 0
)

thread_regs = [0] * 32
thread_regs[30] = 0 # lr
thread_regs[31] = 0 # sp
thread_regs.append(VM_BASE + 0x400) # pc
thread_regs.append(0) # cpsr

cmd_thread = struct.pack("<IIII", 0x5, 16 + len(thread_regs)*8, 6, len(thread_regs)*2)
for r in thread_regs:
    cmd_thread += struct.pack("<Q", r)

macho = bytearray(0x4000)
off = 0
macho[off:off+len(hdr)] = hdr
off += len(hdr)
macho[off:off+len(cmd_seg)] = cmd_seg
off += len(cmd_seg)
macho[off:off+len(sect)] = sect
off += len(sect)
macho[off:off+len(cmd_thread)] = cmd_thread
macho[0x400:0x400+len(raw_code)] = raw_code

out_path = os.path.join(OUT_DIR, "kernel.development.fajita")
with open(out_path, "wb") as f:
    f.write(macho)

print(f"Created Mach-O kernel at {out_path} ({len(macho)} bytes)")
