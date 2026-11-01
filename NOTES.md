# iOS 16 on OnePlus 6T (fajita, SDM845) - Engineering Notes

## Overview & Porting Summary

This document records the architectural details, hardware mappings, bring-up decisions, and debugging procedures for porting Apple's iOS 16 XNU kernel (`xnu-8796`) and iPhone X userland from the Redmi Note 10 Pro (`sweet`, SM7150) to the **OnePlus 6T** (`fajita`, Qualcomm SDM845).

### Target Specifications
- **Device Codename**: `fajita`
- **SoC**: Qualcomm Snapdragon 845 (SDM845)
- **CPU Architecture**: 8 Cores (ARMv8.2-A, 64-bit, non-PAC):
  - 4x Kryo 385 Silver (ARM Cortex-A55 @ 1.77 GHz)
  - 4x Kryo 385 Gold (ARM Cortex-A75 @ 2.80 GHz)
- **Memory**: 6 GB, 8 GB, or 10 GB LPDDR4X SDRAM.
- **Display**: 6.41-inch Optic AMOLED, 1080×2340 resolution (19.5:9), 32bpp (`a8r8g8b8`), continuous splash at `0x9d400000`.
- **Storage**: Internal UFS 2.1 (JEDEC JESD223), controller at `0x01d84000`.
- **Power Management**: Qualcomm PM8998 and PMI8998 PMICs over SPMI bus (`0x0c440000`).
- **Touchscreen**: Synaptics RMI4 I2C (`s6sy761`) at address `0x20` on GENI QUP SE10 (`0x00a90000`).

---

## Architectural Comparison: Sweet vs. Fajita

| Component | Redmi Note 10 Pro (`sweet`) | OnePlus 6T (`fajita`) | Porting Strategy |
| :--- | :--- | :--- | :--- |
| **SoC** | Qualcomm Snapdragon 732G (SM7150) | Qualcomm Snapdragon 845 (SDM845) | Generic ARMv8.2-A machine configuration |
| **CPU Cluster** | 6x Cortex-A55 + 2x Cortex-A76 | 4x Cortex-A55 + 4x Cortex-A75 | Homogeneous 8-core SMP cluster via PSCI `CPU_ON` |
| **MPIDR Aff1** | Cores 0–5 (A55), Cores 6–7 (A76) | Cores 0–3 (A55), Cores 4–7 (A75) | Cores `0x000` to `0x700` (`reg = core << 8`) |
| **GIC Architecture** | GICv3 (GICD `0x17a00000`, GICR `0x17a60000`) | GICv3 (GICD `0x17a00000`, GICR `0x17a60000`) | Identical base addresses; Group 1 NS IRQs |
| **Timer PPI** | INTID 19 (Qualcomm PPI 3) | INTID 19 (Qualcomm PPI 3) | Identical timer INTID and 19.2 MHz timebase |
| **Splash Buffer** | `0x9c000000` (1080×2400, 36 MB) | `0x9d400000` (1080×2340, 36 MB) | Updated `FB_BASE`, `FB_H`, and early console mapping |
| **Display Presentation** | 1080×2400 centered in 1125×2436 | 1080×2340 centered in 1125×2436 | Offsets: `fOffX = 22`, `fOffY = 48` |
| **UFS Host** | `0x01d84000` (UFSHCI 2.1) | `0x01d84000` (UFSHCI 2.1) | Shared Qualcomm UFSHCI polling driver |
| **SPMI Controller** | `0x0c440000` (PM6150 / PM6150L) | `0x0c440000` (PM8998 / PMI8998) | Identical SPMI core; PON block at SID 0, `0x0800` |
| **Touch Controller** | Goodix GT9896 / Focaltech | Synaptics RMI4 (`s6sy761`) | SE10 at `0xa90000`, I2C slave address `0x20` |
| **Boot Header** | Android boot.img v2 | Android boot.img v0 (or v2) | Packed via `mkbootimg --header_version 0` |

---

## Memory & Carve-Out Map (SDM845)

Qualcomm bootloaders and TrustZone enforce hardware memory protection via XPUs. Speculative accesses into secure memory regions trigger asynchronous bus errors or hypervisor panics.

### Low Bank Carve-Outs (0x80000000 – 0x100000000):
```
0x80000000 - 0x85700000 : Available DRAM (bootloader, shim execution space)
0x85700000 - 0x85d00000 : Hypervisor memory (hyp-mem, 6 MB)
0x85e00000 - 0x85f00000 : XBL memory (1 MB)
0x85fc0000 - 0x86000000 : AOP memory and command database (256 KB)
0x86000000 - 0x86200000 : SMEM shared memory (2 MB)
0x86200000 - 0x88f00000 : Qualcomm TrustZone (QSEE / TZ, 45 MB)
0x88f00000 - 0x8ab00000 : Removed memory region (28 MB)
0x8ab00000 - 0x8bf00000 : QSEECOM carve-out (20 MB)
0x8bf00000 - 0x8c400000 : Camera firmware memory (5 MB)
0x8c500000 - 0x8df00000 : ADSP firmware memory (26 MB)
0x8df00000 - 0x8e000000 : WLAN MSA memory (1 MB)
0x8e000000 - 0x95800000 : MPSS modem memory (120 MB)
0x95800000 - 0x95d00000 : Venus video accelerator (5 MB)
0x95d00000 - 0x96500000 : CDSP compute subsystem (8 MB)
0x96500000 - 0x96700000 : MBA modem boot authenticator (2 MB)
0x96700000 - 0x97b00000 : SLPI sensor low-power island (20 MB)
0x97b00000 - 0x97c00000 : SPSS secure processor subsystem (1 MB)
0x9d400000 - 0x9f800000 : Splash Framebuffer (36 MB)
0xac300000 - 0xac700000 : Ramoops persistent console (4 MB)
0xf5b00000 - 0xf5d02000 : RMTFS remote storage buffer (2 MB)
```

### High Bank (0x100000000 and above):
The upper DDR bank is completely unfragmented and free from static TrustZone firmware carve-outs:
- **Base**: `0x100000000` (4 GiB boundary)
- **Size**: `0xfcc00000` (~3.95 GiB contiguous DRAM allocated to XNU)
- The panic log (`0x100000`, 1 MiB) is carved from the top of this DRAM range.

---

## Hardware Interfacing Details

### 1. Interrupts (GICv3)
- TrustZone runs in Secure EL3/EL1 and owns GIC Group 0.
- All non-secure interrupts arrive as Group 1 IRQs via `ICC_IAR1_EL1` and `sleh_irq()`.
- Virtual timer INTID is `19` (PPI 3).
- Cross-core IPIs use SGI `1`.
- Redistributors have a 128 KB stride (`GICR_PE_SIZE = 0x20000`).

### 2. Display & Framebuffer
- Panel Resolution: 1080×2340 @ 60 Hz.
- Memory: Physical base `0x9d400000`, row stride 4320 bytes (`1080 * 4`), format `a8r8g8b8`.
- Logical Presentation: Centered within the iPhone X 1125×2436 viewport (`fOffX = 22`, `fOffY = 48`).
- Early Console: Mapped into a dedicated kernel L2 block entry at `SWEET_EARLY_FB_VA` (`VM_MIN_KERNEL_ADDRESS + ARM_TT_L2_SIZE`) before bootstrap TTBR0 teardown.

### 3. Touchscreen (Synaptics RMI4)
- Bus: Qualcomm GENI I2C on QUP SE10 (`0x00a90000`).
- Slave Address: `0x20` (7-bit).
- Protocol: Synaptics RMI4 F01 (device control) and F12 (2D multi-touch sensor).
- Coordinates are translated from panel space (1080×2340) to logical display space (1125×2436).

### 4. Hardware Keys (PM8998)
- Power Key: PM8998 PON block status register (`0x0810`, bit 0).
- Volume Keys: PM8998 GPIO 5 (Vol Down) and GPIO 6 (Vol Up) status registers.
- Monitored by a dedicated kernel polling thread at 20 ms intervals, emitting standard `IOHIDEvent` consumer key events.

---

## Boot Testing & Verification Steps

1. **Verify DTB Parsing**:
   ```sh
   python3 tools/mkadt.py shim/out/fajita.adt --dump
   ```
2. **Build Test Boot Image**:
   ```sh
   shim/build.sh
   ```
3. **Execute Host Shim Test**:
   ```sh
   (cd shim && gcc -O1 -Wall -o out/host_test console.c host_test.c && ./out/host_test)
   ```
4. **Validate Repository Integrity**:
   ```sh
   python3 tools/validate-repo.py
   ```
