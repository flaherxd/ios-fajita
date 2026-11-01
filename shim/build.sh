#!/bin/bash
# Build the fajita shim and wrap it in a boot.img for OnePlus 6T (SDM845).
set -euo pipefail
cd "$(dirname "$0")"
CC=${CROSS_COMPILE:-aarch64-linux-gnu-}gcc
OBJCOPY=${CROSS_COMPILE:-aarch64-linux-gnu-}objcopy
CFLAGS="-O2 -ffreestanding -nostdlib -fno-pic -mgeneral-regs-only -mstrict-align -fno-stack-protector -Wall -Wextra"
mkdir -p out

if ! command -v "$CC" >/dev/null 2>&1; then
	echo "warning: $CC not found; skipping shim compilation"
	exit 0
fi

for f in start.S shim.c console.c mmu.c fdt.c loader.c ufs.c; do
	$CC $CFLAGS -c $f -o out/${f%.*}.o
done

abs=$(${CROSS_COMPILE:-aarch64-linux-gnu-}readelf -r out/shim.o out/console.o out/mmu.o out/fdt.o out/loader.o out/ufs.o | grep -c ABS64 || true)
[ "$abs" = 0 ] || { echo "error: $abs absolute relocations in C objects" >&2; exit 1; }

$CC $CFLAGS -static -T shim.ld -Wl,--build-id=none -Wl,--no-warn-rwx-segments -Wl,-N \
	out/start.o out/shim.o out/console.o out/mmu.o out/fdt.o out/loader.o out/ufs.o -o out/shim.elf
$OBJCOPY -O binary out/shim.elf out/Image

size=$(${CROSS_COMPILE:-aarch64-linux-gnu-}nm out/shim.elf | awk '$3=="_end"{print strtonum("0x"$1)}')
truncate -s "$size" out/Image

if [ -n "${1:-}" ]; then
	cp "$1" out/ramdisk.bin
else
	(cd out && rm -rf rd && mkdir rd && cd rd && find . | cpio -o -H newc --quiet | gzip -9 > ../ramdisk.bin)
fi

DTB_FILE="../dtb/sdm845-oneplus-fajita.dtb"
if [ ! -f "$DTB_FILE" ]; then
	DTB_FILE="../dtb/boot_unpacked/dtb"
fi

mkbootimg --header_version 0 --kernel out/Image --ramdisk out/ramdisk.bin \
	--second "$DTB_FILE" --base 0x00000000 --kernel_offset 0x00008000 \
	--ramdisk_offset 0x01000000 --tags_offset 0x00000100 --pagesize 4096 \
	--os_version 11.0.0 --os_patch_level 2021-08 \
	--cmdline "console=null" -o out/shim-boot.img

gcc -O1 -Wall -o out/host_test console.c host_test.c && ./out/host_test
ls -l out/Image out/shim-boot.img
