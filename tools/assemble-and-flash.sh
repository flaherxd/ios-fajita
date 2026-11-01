#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"
export PATH="/home/artur/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

RUN_ID="${1:-}"
if [ -n "$RUN_ID" ]; then
    echo "=== Downloading XNU Kernel from Run $RUN_ID ==="
    rm -rf "$REPO_ROOT/xnu/out/kernel.development.sweet"*
    gh run download "$RUN_ID" -n xnu-kernel -D "$REPO_ROOT/xnu/out"
else
    echo "=== Using existing kernel at xnu/out/kernel.development.sweet ==="
fi

echo "=== Generating Apple Device Tree (fajita.adt) ==="
python3 "$REPO_ROOT/tools/mkadt.py" "$REPO_ROOT/shim/out/fajita.adt"

echo "=== Packing XNU Payload for OnePlus 6T ==="
python3 "$REPO_ROOT/tools/mkpayload.py" \
    "$REPO_ROOT/xnu/out/kernel.development.sweet" \
    "$REPO_ROOT/shim/out/fajita.adt" \
    "$REPO_ROOT/shim/out/payload.bin" \
    --cmdline "debug=0xc serial=3 cpus=8 keepsyms=1 -enable_kprintf_spam -noprogress rd=ufsroot0 unentitled_ios_sim_launch=1 ignition_level=1 wdt_test=no_user_checkin ufsrw=1 rootrw=1 launchd_unsecure_cache=1 wdt=-1 sweetfb_hz=30"

echo "=== Assembling Android Boot Image ==="
mkbootimg \
    --kernel "$REPO_ROOT/shim/out/Image.gz-dtb" \
    --ramdisk "$REPO_ROOT/shim/out/payload.bin" \
    --base 0x10000000 \
    --kernel_offset 0x00008000 \
    --ramdisk_offset 0x01000000 \
    --tags_offset 0x00000100 \
    --pagesize 2048 \
    --header_version 1 \
    --os_version 11.0.0 \
    --os_patch_level 2021-08 \
    --cmdline "console=null" \
    -o "$REPO_ROOT/shim/out/shim-boot-fajita.img"

echo "=== Flashing boot_a on OnePlus 6T ==="
fastboot flash boot_a "$REPO_ROOT/shim/out/shim-boot-fajita.img"

echo "=== Rebooting OnePlus 6T ==="
fastboot reboot

echo "=== Boot Command Dispatched! ==="
