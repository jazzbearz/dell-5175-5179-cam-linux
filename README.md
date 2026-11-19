# Dell Latitude 5175 / 5179 cameras on Linux

Makes both built-in cameras of the **Dell Latitude 11 5179** 2-in-1 work on Linux:

| Camera | Sensor | ACPI | Status |
|---|---|---|---|
| Front (user-facing, 5 MP) | OmniVision OV5670 | `INT3479` | ✅ streams via libcamera / PipeWire |
| Rear (world-facing, 8 MP AF) | OmniVision OV8858 + DW9714 VCM | `INT3477` | ✅ streams, VCM probes |
| Camera privacy LED | TPS68470 ILED A | — | ✅ on while either camera streams |

Tested on Ubuntu 26.04, kernel `7.0.0-43-generic` (7.0.14 based), BIOS 1.7.2.
The **Latitude 5175** uses the same Windows camera driver package and very
likely the same design, but it is **untested** (see below).

How the fix was found — DSDT analysis, reverse-engineering the Windows driver's
PMIC settings, and the boot-time bugs hit along the way — is written up in
**[PAPER.md](PAPER.md)**.

## Why the cameras don't work out of the box

1. The cameras sit on an Intel IPU3 (Skylake) and are powered by a **TI TPS68470
   PMIC**. Linux has no per-model *board data* for this laptop, so the PMIC
   driver stops with `int3472-tps68470 ...: No board-data found for this model`
   and the sensors never get power.
2. The front sensor's I²C controller (`INT3446`, I2C4) fails with `-EBUSY`
   because a BIOS OpRegion (`GEXP.BAR0`) overlaps its MMIO range.
3. The rear sensor (`INT3477`) is unknown to `ipu-bridge` and `ov8858`.
4. Even with kernel support, IPU3 cameras need **libcamera**; apps that open
   `/dev/video*` directly (e.g. Cheese) will not work.

## What this repository contains

```
dkms/latitude5179-camera-1.4/   DKMS package (sources = Linux v7.0.14 + patches)
patches/                        the same changes as patches against v7.0.14
modprobe.d/                     selects ILED A as the privacy LED
install.sh / uninstall.sh       convenience scripts (Ubuntu/Debian)
userspace/                      optional libcamera patch + rebuild script (>720p in apps)
PAPER.md                        research write-up
```

| Module | Change |
|---|---|
| `intel_skl_int3472_tps68470` | board data for Latitude 5179 (regulators, GPIOs); creates an LED cell; `privacy_led=a\|b` option |
| `leds-tps68470` (new) | LED class driver for TPS68470 indicator outputs ILED A/B (`ILEDCTL` 0x28) |
| `ipu-bridge` | adds OV8858 (`INT3477`, 360 MHz link) |
| `ov8858` | ACPI ID `INT3477`, optional `vsio` supply, `-EPROBE_DEFER` when the bridge endpoint isn't there yet |
| `intel-lpss-acpi` | ignore the bogus resource conflict on `INT3446` (Latitude 5179 only) |

Regulator settings (taken from Intel's Windows control-logic driver, see the paper):

| Rail | Voltage | Consumer |
|---|---|---|
| AUX1 | 1.2132 V | OV5670 `dvdd` |
| AUX2 | 1.8006 V | OV5670 `dovdd` |
| VSIO | 1.8006 V | OV5670 `avdd`, OV8858 `vsio` (I²C pass-through) |
| CORE | 1.2 V | OV8858 `dvdd` |
| ANA | 2.8152 V | OV8858 `avdd` |
| VIO | 1.8006 V (always on) | OV8858 `dovdd` |
| VCM | 2.8152 V | DW9714 `vcc` |

GPIOs (TPS68470, active-low): OV5670 reset 3 / powerdown 4, OV8858 reset 9 / powerdown 7.

## Install

Secure Boot must be off, or you must enroll the DKMS MOK key.

```sh
git clone https://github.com/jazzbearz/dell-5175-5179-cam-linux.git
cd dell-5175-5179-cam-linux
./install.sh
reboot
```

`install.sh` installs `dkms`, kernel headers and the libcamera/PipeWire
packages, builds the DKMS package, installs the LED option into
`/etc/modprobe.d/`, rebuilds the initramfs and adds you to the `video` group.

Check:

```sh
cam --list            # 1: Internal back camera, 2: Internal front camera
wpctl status          # Video → Sources: Built-in Front/Back Camera
```

Use a PipeWire/libcamera app: **GNOME Snapshot** (`sudo apt install gnome-snapshot`),
Firefox/Chromium (WebRTC), OBS (PipeWire camera source). Cheese does not work
with IPU3 cameras.

## Optional: resolutions above 720p in apps (libcamera patch)

libcamera's IPU3 pipeline advertises the Viewfinder/VideoRecording roles only
up to 1280×720, and PipeWire builds its format list from that role, so
Snapshot, browsers and video calls never see a larger size. The ImgU can
actually stream larger viewfinder output, so
[`userspace/libcamera-0.7.0-ipu3-advertise-full-vf-range.patch`](userspace/libcamera-0.7.0-ipu3-advertise-full-vf-range.patch)
keeps 720p as the default but advertises the full range.

| Camera | Max offered to apps (before → after) | Measured via PipeWire |
|---|---|---|
| Rear | 1280×720 → 3200×2400 | 1920×1080 and 3200×2400 ≈ 22 fps |
| Front | 1280×720 → 2560×1600 | 1920×1080 ≈ 28 fps |

To rebuild Ubuntu's libcamera package with the patch, first add `deb-src` to
the `Types:` lines in `/etc/apt/sources.list.d/ubuntu.sources`, then:

```sh
sudo apt-get update
./userspace/build-libcamera.sh      # builds 0.7.0-1ubuntu2+ipu3vf1 and installs it
```

An Ubuntu libcamera update will replace the patched build. To revert by hand:

```sh
sudo apt install --allow-downgrades libcamera0.7=0.7.0-1ubuntu2 libcamera-ipa=0.7.0-1ubuntu2 \
  libcamera-tools=0.7.0-1ubuntu2 libcamera-v4l2=0.7.0-1ubuntu2 gstreamer1.0-libcamera=0.7.0-1ubuntu2
```

## Uninstall

```sh
./uninstall.sh && reboot
```

## Known issues

- **Without the libcamera patch below, apps get at most 1280×720.**
- **Image quality is below Windows.** libcamera's IPU3 IPA has no
  sensor-specific tuning (lens shading, colour matrices) for OV5670/OV8858.
  Windows' per-module Intel tuning files (`*.cpf`, AIQB format) cannot be used
  by libcamera; see PAPER.md §10.
- `ov8858 ...: xvclk mismatched, modes are based on 24MHz` — the PMIC clock
  isn't 24 MHz. Images are fine; frame timing may differ from nominal.
- libcamera logs `Unable to get rectangle ... on pad 0/0` for ov8858 (driver
  lacks crop selection). Harmless.
- If cameras are missing in apps right after boot and you are not in the
  `video` group yet: `systemctl --user restart wireplumber`.
- DKMS rebuilds on kernel updates, but the sources are from v7.0.14; a much
  newer kernel may need the patches refreshed.

## Latitude 5175

Same Windows driver package (Dell `V9X4F` lists 5175, 5179, 7275, XPS 12 9250),
so the PMIC values are almost certainly identical. The patches only match the
DMI product name `Latitude 5179` and the PMIC device `i2c-INT3472:04`. On a
5175, check `dmesg | grep -i int3472` and
`cat /sys/class/dmi/id/product_name`, then add a matching DMI entry in
`tps68470_board_data.c` and `intel-lpss-acpi.c`. Reports welcome.

## Status upstream

Not submitted yet. The closely related Latitude 5285 series (int3472 board
data, ipu-bridge/ov8858 `INT3477`) was under review in 2026; its intel-lpss
quirk patches were applied. This work could be proposed as a follow-up.

## License

Kernel code is GPL-2.0 (see SPDX headers), derived from Linux v7.0.14.
No Dell/Intel Windows driver files are included in this repository.
