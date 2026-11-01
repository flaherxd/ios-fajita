# ios-fajita

**Apple's iOS 16 running on the OnePlus 6T (Experimental Bringup).**

> [!CAUTION]
> ### ⚠️ ALMOST NOTHING WORKS!
> This project is an early-stage, proof-of-concept research bring-up. 
> - **BOOT TAKES A REALLY LONG TIME**: The device stays on the Apple logo for a very long time (typically 4–6+ minutes) before anything appears, as SpringBoard and UIKit views are rendered purely on the CPU via software rasterization.
> - **TOUCH DOES NOT WORK**: The touchscreen does not respond to input (Synaptics RMI4 driver is WIP / not yet implemented).
> - **NO GPU ACCELERATION**: CoreAnimation runs purely on CPU software rasterization (very slow / high CPU load).
> - **NO WI-FI / BLUETOOTH**: Wireless chipsets are uninitialized and non-functional.
> - **NO CELLULAR / CALLS / SMS**: Baseband modem is completely unmanaged.
> - **NO AUDIO / CAMERAS / SENSORS**: No DSP, no camera sensor drivers, no haptics.
> - **DO NOT ATTEMPT TO USE AS A DAILY OS**: It currently only boots as far as the **iOS 16 Lock Screen clock**.
> - **ERASES STORAGE**: Flashing writes an HFS+ image to the `userdata` partition and wipes all existing data!

---

## Current Status

The project can boot Apple's open-source XNU Mach-O kernel (xnu-8796, iOS 16 generation) on the **OnePlus 6T** (`fajita`, Qualcomm Snapdragon 845 / SDM845), mounting genuine unmodified **iOS 16.7.16 (20H392)** userland from the UFS storage partition. PID 1 `launchd`, `backboardd`, and `SpringBoard` execute and composite the iOS 16 Lock Screen with the clock rendered via CPU software rasterization to the bootloader's continuous AMOLED framebuffer.

However, beyond booting to the lock screen clock, **practically nothing is functional**.

### Hardware & Feature Status

| Subsystem | State | Details |
| :--- | :--- | :--- |
| **Bootchain** | Working | Stock OnePlus ABL &rarr; `fastboot boot shim-boot.img` &rarr; XNU. **Takes a very long time** (sits on Apple logo for several minutes). |
| **CPU / PSCI** | Working | Snapdragon 845 (4x Gold + 4x Silver), GICv3 interrupts, 16 KB pages. |
| **Storage (UFS)** | Working | Qualcomm UFSHCI 2.1 driver (`0x01d84000`), mounts HFS+ root on `userdata`. |
| **Display / Lock Screen** | Partial | Framebuffer blitted to `0x9d400000`. Displays the iOS 16 Lock Screen and clock. |
| **Touchscreen** | **NOT WORKING** | Synaptics RMI4 (`0x00a90000` / address `0x20`) driver not yet implemented. Touch does not register. |
| **GPU Acceleration** | **NOT WORKING** | Adreno 630 unsupported; relies on slow CPU software rasterization. |
| **Wi-Fi & Bluetooth** | **NOT WORKING** | WCN3990 uninitialized; no wireless connectivity. |
| **Cellular / Modem** | **NOT WORKING** | Qualcomm MDM / QMI modem unmanaged; no calls, data, or SMS. |
| **Audio** | **NOT WORKING** | WCD9340 codec and audio DSP uninitialized; no sound. |
| **Cameras** | **NOT WORKING** | Spectra 280 ISP and camera sensors unmanaged. |
| **Hardware Buttons** | Partial | Power and Volume buttons handled as basic HID events. |
| **Battery / Power** | Stubbed | Synthetic power source reporting stubbed values to prevent shutdown. |

---

## Boot Architecture

```
OnePlus ABL (stock bootloader, unlocked)
  -> fastboot boot shim/out/shim-boot.img              (temporary; nothing written to boot)
     -> shim: sets up EL1 MMU, parses live FDT, loads kernel payload from ramdisk
        -> XNU Mach-O + generated Apple Device Tree (ADT) + boot-args
           -> XNU -> internal UFSHCI driver -> HFS+ root in userdata partition
              -> dyld + shared cache -> launchd -> daemons -> backboardd + SpringBoard
```

The bootloader leaves the 1080&times;2340 AMOLED continuous splash buffer active at `0x9d400000`. The early kernel draws diagnostics and panic reports into this buffer. A persistent 4 MiB circular log ring is mirrored to the trailing blocks of the `userdata` partition, extractable from recovery using `tools/fajita-log-pull.sh`.

---

## Build and Installation Instructions

### Prerequisites
- OnePlus 6T (`fajita`, SDM845) with an **unlocked bootloader**.
- A Linux host machine (with `fastboot`, `adb`, `python3`, `img2simg`, `hfsprogs`, `apfs-fuse`).
- GitHub account with GitHub Actions enabled for kernel CI builds.

### 0. Device Backup
Before modifying storage, boot TWRP or OrangeFox recovery via fastboot and back up critical device-specific calibration partitions:
```sh
adb pull /dev/block/by-name/persist persist.img
adb pull /dev/block/by-name/modemst1 modemst1.img
adb pull /dev/block/by-name/modemst2 modemst2.img
adb pull /dev/block/by-name/fsg fsg.img
adb pull /dev/block/by-name/fsc fsc.img
```

### 1. Build the Kernel (GitHub Actions)
The XNU kernel compiles on macOS runners using Xcode 15 and `darwin-xnu-build`:
1. Fork or push this repository to GitHub.
2. Trigger the workflow:
   ```sh
   gh workflow run xnu.yml -R YOUR_USER/ios-fajita -f machine_config=FAJITA
   ```
3. Download the resulting kernel artifact (`xnu-kernel`) into `xnu/out/`:
   ```sh
   gh run download <RUN_ID> -R YOUR_USER/ios-fajita -n xnu-kernel -D xnu/out/
   ```

### 2. Create the iOS 16 Root Filesystem
Download the official iPhone X (iPhone10,3) iOS 16.7.16 (20H392) IPSW from Apple:
```sh
# Extract disk images and create the HFS+ root volume
tools/mkiosroot.sh OS.dmg SystemOS.dmg AppOS.dmg ios16-root.img 16G
sudo fsck.hfsplus -fy ios16-root.img
sudo mount -t hfsplus -o loop,force ios16-root.img /mnt/iosroot
sudo python3 tools/fajita-root-tweaks.py /mnt/iosroot
sudo umount /mnt/iosroot
img2simg ios16-root.img ios16-root.simg
```

Extract the genuine iPhone X device tree `/product` properties (required by MobileGestalt):
```sh
python3 tools/remotezip.py <IPSW_URL> DeviceTree.d22ap.im4p research/ipsw-x/dt
ipsw img4 im4p extract research/ipsw-x/dt/Firmware/all_flash/DeviceTree.d22ap.im4p -o research/ipsw-x/d22ap.adt
```

### 3. Generate Boot Image and Payload
```sh
# Generate Apple Device Tree for OnePlus 6T
python3 tools/mkadt.py shim/out/fajita.adt --highmem

# Package Mach-O kernel, ADT, and boot arguments into payload.bin
python3 tools/mkpayload.py xnu/out/kernel.development.fajita shim/out/fajita.adt shim/out/payload.bin \
    --cmdline 'debug=0xc serial=3 cpus=8 keepsyms=1 -enable_kprintf_spam -noprogress rd=ufsroot0 unentitled_ios_sim_launch=1 ignition_level=1 wdt_test=no_user_checkin ufsrw=1 rootrw=1 launchd_unsecure_cache=1 wdt=-1 sweetfb_noconsole=1 sweetfb_hz=30'

# Compile bare-metal boot shim and assemble Android boot.img
shim/build.sh shim/out/payload.bin      # -> shim/out/shim-boot.img
```

### 4. Flash and Boot
Put the OnePlus 6T into Fastboot mode (hold Volume Down + Power):
```sh
# Flash the iOS 16 root sparse image into userdata (~16 GB)
fastboot -S 512M flash userdata ios16-root.simg

# Boot the shim image temporarily (preserves stock boot partition)
fastboot boot shim/out/shim-boot.img
```

> [!IMPORTANT]
> **Booting takes a really long time!**
> The device will sit on the Apple logo for a very long time (typically 4–6+ minutes) while XNU mounts storage, `launchd` spawns background daemons, and `SpringBoard` slowly compiles and rasterizes UIKit views entirely on the CPU. **Do not interrupt or force-reboot the device**—give it plenty of time to reach the clock.

### 5. Diagnostics and Kernel Logs
To retrieve the 4 MiB kernel log buffer from recovery:
```sh
fastboot boot recovery.img
tools/fajita-log-pull.sh logs/boot.txt
```
To monitor live kernel output via CDC-ECM USB networking, boot with `sweetusb=2` and run:
```sh
tools/fajita-usbnet.sh logs/live.txt
```

---

## Repository Layout

| Path | Purpose |
| :--- | :--- |
| `shim/` | Bare-metal ARM64 bootloader shim, MMU configuration, and Android boot.img wrapper |
| `xnu/patches/` | Ordered XNU-8796 patch series (0001–0081) for Qualcomm SDM845 bringup |
| `tools/mkadt.py` | Generates the Apple Device Tree (ADT) from OnePlus 6T hardware specifications |
| `tools/mkpayload.py` | Mach-O chained fixup resolution and kernel + ADT payload packer |
| `tools/mkiosroot.sh` | Assembles composite HFS+ root image from IPSW cryptex volumes |
| `tools/fajita-root-tweaks.py`| iOS root configuration tweaks (Setup bypass, activation, watchdog suppression) |
| `tools/fajita-log-pull.sh` | Pulls persistent circular log buffer from the userdata partition |
| `tools/fajita-crash.py` | Symbolicates crash logs against the dyld shared cache |
| `tools/qemu-fajita.py` | Host-based QEMU virt testing harness |
| `tools/validate-repo.py` | Validates patch ordering, unified diff headers, and tool syntax |
| `NOTES.md` | Detailed hardware facts, register maps, and porting log |

---

## Key Hardware Specifications (OnePlus 6T)

- **SoC**: Qualcomm Snapdragon 845 (SDM845, 10nm LPP)
- **CPUs**: 4x Kryo 385 Gold (Cortex-A75 @ 2.80 GHz) + 4x Kryo 385 Silver (Cortex-A55 @ 1.77 GHz)
- **Interrupts**: ARM GICv3 (Distributor `0x17a00000`, Redistributors `0x17a60000`)
- **Timer PPI**: Virtual timer INTID 19 (Qualcomm PPI 3, 19.2 MHz timebase)
- **Display**: 1080&times;2340 19.5:9 AMOLED; splash framebuffer at `0x9d400000` (36 MiB)
- **Storage**: UFS 2.1 host controller at `0x01d84000`, LUN 0 partition `userdata`
- **Touch**: Synaptics RMI4 over I2C at address `0x20` on GENI QUP SE10 (`0xa90000`)
- **Buttons**: PM8998 SPMI PON at `0x0800` (Power), PM8998 GPIO 5 (Vol-), GPIO 6 (Vol+)
