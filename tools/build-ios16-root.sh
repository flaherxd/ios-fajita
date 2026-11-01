#!/bin/bash
# ==============================================================================
# Automated iOS 16 Root Filesystem Pipeline for OnePlus 6T (fajita, SDM845)
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export PATH="/home/artur/.local/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"

IPSW_URL="https://updates.cdn-apple.com/2025FallFCS/fullrestores/122-77006/1158E502-D76D-4226-AA06-ED5E30CD1111/iPhone10,3,iPhone10,6_16.7.16_20H392_Restore.ipsw"
DMG_DIR="$REPO_ROOT/research/ipsw-x"
OUT_IMG="$REPO_ROOT/ios16-root.img"
OUT_SIMG="$REPO_ROOT/ios16-root.simg"

OS_DMG="087-86698-044.dmg"
SYSOS_DMG="087-86593-047.dmg"
APPOS_DMG="087-86715-047.dmg"

echo "=== OnePlus 6T iOS 16 Root Image Builder ==="
echo "Target: $OUT_SIMG"

# Check sudo access
if [ "$EUID" -ne 0 ] && ! sudo -v; then
    echo "Error: Root privileges (sudo) required for loopback mounting and APFS extraction." >&2
    exit 1
fi

# Install custom-compiled tools to /usr/local/bin so sudo finds them in secure_path
echo "[*] Ensuring tools in /usr/local/bin..."
sudo cp -f /home/artur/.local/bin/apfs-fuse /usr/local/bin/ 2>/dev/null || true
sudo cp -f /home/artur/.local/bin/apfs-dump-quick /usr/local/bin/ 2>/dev/null || true
sudo cp -f /home/artur/.local/bin/mkfs.hfsplus /usr/local/bin/ 2>/dev/null || true
sudo cp -f /home/artur/.local/bin/fsck.hfsplus /usr/local/bin/ 2>/dev/null || true
sudo cp -f /home/artur/.local/bin/rsync /usr/local/bin/ 2>/dev/null || true
sudo chmod +x /usr/local/bin/{apfs-fuse,apfs-dump-quick,mkfs.hfsplus,fsck.hfsplus,rsync} 2>/dev/null || true

mkdir -p "$DMG_DIR"

echo "[1/4] Checking / Downloading IPSW DMGs via HTTP range requests..."
for dmg in "$OS_DMG" "$SYSOS_DMG" "$APPOS_DMG"; do
    if [ ! -f "$DMG_DIR/$dmg" ]; then
        echo "  Downloading $dmg from Apple CDN..."
        python3 "$SCRIPT_DIR/remotezip.py" "$IPSW_URL" "$dmg" "$DMG_DIR"
    else
        echo "  $dmg already present in $DMG_DIR"
    fi
done

echo "[2/4] Assembling HFS+ root volume ($OUT_IMG)..."
rm -f "$OUT_IMG"
sudo env "PATH=/home/artur/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH" "$SCRIPT_DIR/mkiosroot.sh" \
    "$DMG_DIR/$OS_DMG" \
    "$DMG_DIR/$SYSOS_DMG" \
    "$DMG_DIR/$APPOS_DMG" \
    "$OUT_IMG" 16G

echo "[3/4] Applying OnePlus 6T root tweaks (launchd, activation, bypasses)..."
sudo fsck.hfsplus -fy "$OUT_IMG" || true
MNT="/tmp/mnt_iosroot_fajita"
sudo mkdir -p "$MNT"
sudo mount -t hfsplus -o loop,force "$OUT_IMG" "$MNT"
sudo python3 "$SCRIPT_DIR/fajita-root-tweaks.py" "$MNT"
sudo umount "$MNT"
sudo rmdir "$MNT"

echo "[4/4] Creating fastboot sparse image ($OUT_SIMG)..."
rm -f "$OUT_SIMG"
img2simg "$OUT_IMG" "$OUT_SIMG"

echo ""
echo "=== Success! iOS 16 Root Image Generated ==="
ls -lh "$OUT_SIMG"
echo ""
echo "To flash to OnePlus 6T userdata partition:"
echo "  fastboot -S 512M flash userdata $OUT_SIMG"
