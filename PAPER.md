# Bringing up the IPU3/TPS68470 cameras of the Dell Latitude 5179 on Linux

*A case study in recovering camera PMIC board data from ACPI tables and a Windows driver*

November 2026

---

## Abstract

The Dell Latitude 11 5179 (and very likely its sibling, the 5175) is a
Skylake 2-in-1 tablet whose front OV5670 and rear OV8858 camera sensors are
connected to the Intel IPU3 CSI-2 receiver and powered by a TI TPS68470 camera
PMIC. On a current distribution kernel (Linux 7.0) neither camera works: the
INT3472/TPS68470 driver has no board data for the machine, the front sensor's
I²C controller fails to probe because of a BIOS resource overlap, and the rear
sensor's ACPI ID is unknown to the kernel. The PMIC's regulator voltages and
rail-to-sensor wiring are not described in ACPI, so they cannot be read from
firmware tables. We recovered them from Intel's Windows "control logic"
driver shipped by Dell, by static analysis only: the sensor drivers request a
fixed set of supply voltages, and the control-logic driver maps them onto
specific TPS68470 rails per sensor role (user-facing vs. world-facing). The
recovered values agree exactly with the in-tree Latitude 7212 data and with an
independently developed Latitude 5285 patch series. With six small kernel
changes, packaged as DKMS, both cameras stream through libcamera and PipeWire,
the rear autofocus VCM probes, and the camera privacy LED is driven by the
PMIC's indicator output while a camera is active.

## 1. Introduction

Camera support on Windows-first Intel 2-in-1s from the Skylake/Kaby Lake era
depends on three layers:

1. **ACPI enumeration** of the sensors (`INT34xx` HIDs) and of an `INT3472`
   "control logic" device, which is either a set of discrete GPIOs or a camera
   PMIC (here a TPS68470).
2. **Kernel drivers**: `intel_skl_int3472_*` turns the control-logic device
   into regulators, clocks and GPIOs; `ipu-bridge` builds the fwnode graph that
   ACPI lacks; the sensor drivers (`ov5670`, `ov8858`) attach to it; and
   `ipu3-cio2` receives the CSI-2 stream.
3. **Userspace**: the IPU3 delivers raw Bayer data, so a libcamera pipeline
   (with the IPU3 ImgU and its IPA) is required to produce usable images.
   PipeWire exposes libcamera cameras to applications.

For TPS68470-based machines the kernel needs **per-model board data**:
regulator voltages, which regulator feeds which sensor supply, and which PMIC
GPIOs drive each sensor's reset/powerdown lines. Windows does not take this
from ACPI either, so for every new model the data has to be recovered
somehow. This paper documents how it was done for the Latitude 5179.

## 2. Hardware

| Item | Value |
|---|---|
| Machine | Dell Latitude 5179 (DMI product name `Latitude 5179`), BIOS 1.7.2 |
| SoC | Intel Skylake-Y, IPU3 (CIO2 `8086:9d32`, ImgU `8086:1919`) |
| Camera PMIC | TI TPS68470, ACPI `INT3472` at `\_SB.PCI0.CLP0`, I²C client `i2c-INT3472:04`, REVID `0x21` |
| Front camera | OV5670, ACPI `INT3479` at `\_SB.PCI0.LNK2`, fixed focus |
| Rear camera | OV8858 (rev `0xb2`), ACPI `INT3477` at `\_SB.PCI0.LNK0`, DW9714 VCM |
| Front sensor I²C | I2C4, ACPI `INT3446` (LPSS, ACPI-enumerated) |
| Privacy LED | on TPS68470 indicator sink (ILED A and B both light it) |

Software baseline: Ubuntu 26.04, kernel `7.0.0-43-generic` (7.0.14),
libcamera 0.7.0, PipeWire 1.6.2, WirePlumber 0.5.13.

## 3. Initial diagnosis

With a stock system, PipeWire listed only raw `ipu3-imgu` and `Intel IPU3
CIO2` V4L2 nodes and no camera source. Installing libcamera
(`libcamera-ipa`, `libspa-0.2-libcamera`) made the IPU3 pipeline handler load,
but `cam --list` still reported no cameras. The media graph had no sensor
subdevices and the CSI-2 receivers had no device nodes.

The kernel log contained the root cause:

```
int3472-tps68470 i2c-INT3472:04: TPS68470 REVID: 0x21
int3472-tps68470 i2c-INT3472:04: error -ENODEV: No board-data found for this model
ipu3-cio2 0000:00:14.3: Found supported sensor INT3479:00
ipu3-cio2 0000:00:14.3: Connected 1 cameras
```

The PMIC answers on I²C, but the driver refuses to register regulators,
clocks and GPIOs without board data. The sensors are therefore never powered,
and only the front sensor is even recognised by `ipu-bridge`. The installed
driver contained board data only for the Surface Go 1/2/3 and the Latitude
7212 Rugged Extreme Tablet.

## 4. Prior work

- **Latitude 7212 (in tree).** Uses the same front sensor (`INT3479`/OV5670)
  on a TPS68470: VSIO 1.8006 V → `avdd`, AUX1 1.2132 V → `dvdd`, AUX2
  1.8006 V → `dovdd`, GPIO 3/4 = reset/powerdown.
- **Latitude 5285 series** (T. Chatard, linux-media / platform-driver-x86,
  v1 March 2026 – v12 October 2026). Enables OV5670 + OV8858 on a TPS68470,
  including an `ipu-bridge` entry and an ACPI ID for OV8858, and an
  `intel-lpss` resource-conflict quirk. Only the intel-lpss patches (5285 and
  Latitude 7275) had been applied at the time of writing. Its front-camera
  values match the 7212; rear: CORE 1.2 V, ANA 2.8152 V, VIO 1.8006 V,
  VCM 2.8152 V, VSIO 1.8006 V, GPIO 9/7 = reset/powerdown. It was also
  reported to work on the Latitude 5290.

The 5179 has the same sensors and PMIC, so the 5285 data was an obvious
candidate. However, the wiring is board-specific, and over-voltage on the
wrong rail can damage a sensor. We wanted evidence specific to this machine
before applying power.

## 5. What ACPI does (not) tell us

The DSDT was extracted (`acpidump`, `iasl -d`). The relevant devices follow
Intel's reference "CRD" camera template:

- `CLP0` (`_HID "INT3472"`, `_DDN "PMIC-CRDG"`) has a `CLDB` buffer whose
  fields (`C0TP` = control-logic type, `C0CV`, …) are filled at runtime from
  GNVS. Linux reads `control_logic_type == 2` → TPS68470 on a Windows platform.
- `LNK0`/`LNK2` have `SSDB` buffers (link, lanes, MCLK, rotation, VCM type…)
  and `_DSM`s returning I²C addresses. They also take everything from GNVS
  variables (`L0xx`, `L2xx`).

**Neither the PMIC nor the sensors carry voltages or PMIC GPIO numbers in
ACPI.** The 144 KB DSDT has no static data about supply rails. Firmware
tables can confirm the topology (one PMIC serving `LNK0` and `LNK2`), but
not the values.

## 6. Recovering the board data from the Windows driver

### 6.1 Source

Dell ships the camera stack for the Latitude 7275/5175/5179 and XPS 12 9250
as *Intel 2D Imaging Driver*, ID `V9X4F`, version 30.14393.9656.3064 A03
(2016). The 145 MB `.EXE` is a self-extracting ZIP. We verified it against
Dell's published SHA-256 and opened it as a ZIP without executing it. The
analysis below is static only. No Windows code was run, and no driver files
are redistributed here.

### 6.2 INF files

`ov5670.inf` (`ACPI\INT3479`), `ov8858.inf` (`ACPI\INT3477`) and
`skccontroller.inf` (`ACPI\INT3472`, "Intel(R) Control Logic") contain only
device bindings and security descriptors. **The INFs contain no regulator
settings.** The data had to be in the binaries.

### 6.3 `SkcController.sys`: per-design, not per-model

The control-logic driver contains no OEM or model strings ("Dell",
"Latitude", SKU IDs, etc.). Its trace strings name C++ classes per *reference
design*:

```
tps68470::CrdGTiSensor / CrdG2TiSensor / SSCrdG2TiSensor
tps68470::Tps68470VoltageUF / Tps68470VoltageWF   (user-facing / world-facing)
tps68470::Tps68470Flash  (IndicatorPowerOn, TorchPowerOn, …)
up6641::…                (alternative uP6641 PMIC)
discrete::…              (GPIO-only control logic)
```

So any machine built on the same Intel design (selected through ACPI
`CLDB`) gets the same PMIC programming on Windows, whatever the model.

**Voltage encoding.** Each `*Voltage*::Initialize` converts millivolt values
held in the object into TPS68470 register codes using double-precision
constants from `.rdata`:

| Constant | Value |
|---|---|
| step / base (LDOs) | 17.8 mV / 875 mV |
| step / base (CORE) | 25 mV / 900 mV |
| rounding threshold | −0.5 mV |

i.e. `code = ⌊(mV − base)/step⌋`, incremented if the result is more than
0.5 mV below the request. These are exactly the linear ranges in Linux's
`tps68470-regulator` driver, which confirms the decoding.

**Where the millivolts come from.** The object constructors preload defaults,
but `*Voltage*::SetConf` overwrites five 16-bit fields from a caller-supplied
structure. The caller is the sensor driver.

### 6.4 `ov5670.sys` / `ov8858.sys`: the requested voltages

Both sensor drivers fill that configuration with the same constants:

```
mov  DWORD PTR [rbx+0xa32], 0x07080af0   ; 2800, 1800
mov  DWORD PTR [rbx+0xa36], 0x07080af0   ; 2800, 1800
mov  eax, 0x4b0                          ; 1200
mov  WORD  PTR [rbx+0xa30], ax
```

That is `{1200, 2800, 1800, 2800, 1800}` mV for {core, analog, I/O, VCM,
sensor-I/O} (`ov8858.sys` is identical at different offsets). With the
encoding above these become **1.2 V (CORE) / 1.2132 V (AUX, 875-based) /
2.8152 V / 1.8006 V**, the "odd" values seen in Linux board data.

### 6.5 Which rail feeds which sensor

The register writes in the two `Initialize` methods (write helper
`0x1400118a0(ctx, reg, val)`; TPS68470 register map from
`include/linux/mfd/tps68470.h`):

**World-facing (rear, OV8858)**, `Tps68470VoltageWF::Initialize`:

| Field | Request | Register | Rail | Result |
|---|---|---|---|---|
| core | 1200 | `0x42` VDVAL | CORE | 1.2 V |
| analog | 2800 | `0x41` VAVAL | ANA | 2.8152 V |
| I/O | 1800 | `0x3F` VIOVAL | VIO | 1.8006 V |
| VCM | 2800 | `0x3C` VCMVAL | VCM | 2.8152 V |
| sensor I/O | 1800 | `0x40` VSIOVAL | VSIO | 1.8006 V |

**User-facing (front, OV5670)**, `Tps68470VoltageUF::Initialize`:

| Field | Request | Register | Rail | Result |
|---|---|---|---|---|
| core | 1200 | `0x3D` VAUX1VAL | AUX1 | 1.2132 V |
| I/O | 1800 | `0x3E` VAUX2VAL | AUX2 | 1.8006 V |
| — | — | `0x1A`, `0x1C` | GPCTL3A / GPCTL4A | GPIO 3, GPIO 4 configured |

The UF path also enables VSIO through `SetVSIOCtl` for the front sensor's
analog supply, matching the in-tree 7212 mapping (VSIO → OV5670 `avdd`).

**Result.** For both sensors, every voltage and rail assignment recovered
from the Windows driver matches the Latitude 5285 series exactly, and the
front-camera part matches the in-tree Latitude 7212 data. The front GPIOs
(3, 4) are confirmed by the GPIO control registers. The rear GPIOs (9, 7)
were not visible in this analysis. They were confirmed empirically when the
OV8858 chip ID read succeeded (§8.1).

### 6.6 The privacy LED

`Tps68470Flash::IndicatorPowerOn` reads and writes register `0x28`
(ILEDCTL). Depending on the LED id it sets bit 2 (ENA, indicator A) or
bit 6 (ENB, indicator B, optionally with current bits `0x30`). Linux 7.0
has no driver for these outputs. A physical test (§8.4) showed that **both A
and B light the same front LED** on this machine.

## 7. Implementation

All changes are against Linux v7.0.14 and built out-of-tree as one DKMS
package (`latitude5179-camera`). The `patches/` directory contains them
individually:

1. **`int3472/tps68470_board_data.c`**: Latitude 5179 board data
   (`i2c-INT3472:04`). Regulator init data per §6.5; consumers OV8858
   `dvdd/avdd/dovdd/vsio`, OV5670 `dvdd/dovdd/avdd`, DW9714 `vcc`. VIO is
   `always_on` (needed for the TPS68470 sensor-I²C pass-through, as on the
   Surface Go). GPIO lookups: `INT3477` reset 9 / powerdown 7, `INT3479`
   reset 3 / powerdown 4, all active-low.
2. **`int3472/tps68470.c`**: adds a `tps68470-led` MFD cell (before the GPIO
   cell, which must stay last) and a `privacy_led=a|b` module parameter. When
   it is set, the driver registers `led_lookup_data` entries with
   `con_id = "privacy"` for every sensor served by the PMIC. This happens
   before the sensors probe, so the V4L2 core attaches the LED to their
   subdevs and switches it with streaming.
3. **`leds/leds-tps68470.c`** (new): an LED-class driver exposing
   `tps68470::ileda` / `tps68470::iledb`. It writes ENA/ENB in ILEDCTL
   through the parent's regmap and leaves the current-select bits at their
   reset value.
4. **`ipu-bridge.c`**: `IPU_SENSOR_CONFIG("INT3477", 1, 360000000)` (the only
   link frequency `ov8858` supports).
5. **`ov8858.c`**: ACPI match `INT3477`, an extra `vsio` bulk supply (a dummy
   regulator elsewhere), and `-EPROBE_DEFER` instead of `-EINVAL` when the
   fwnode endpoint does not exist yet (§8.3).
6. **`mfd/intel-lpss-acpi.c`**: on DMI `Latitude 5179`, set
   `QUIRK_IGNORE_RESOURCE_CONFLICTS` for `INT3446` (§8.2). This is the same
   approach as the applied Latitude 5285/7275 quirks.

## 8. Bring-up problems and their causes

### 8.1 First boot: rear works, front missing

With board data, `ipu-bridge`, and `ov8858` changes in place:

```
ov8858 i2c-INT3477:00: Detected OV8858 sensor, revision 0xb2
ov8858 i2c-INT3477:00: Instantiated dw9714 VCM
ipu3-cio2 0000:00:14.3: Connected 2 cameras
```

Reading the OV8858 chip ID proves that CORE/ANA/VIO/VSIO, the clock, and
GPIO 9/7 are correct. However, `i2c-INT3479:00` was never created, so the
async notifier of `ipu3-cio2` never completed and no camera reached
userspace.

### 8.2 The front sensor's I²C bus does not exist

`INT3479`'s `_CRS` points at I2C4 (`\_SB.PCI0.I2C4`, `INT3446`), which failed:

```
ACPI Warning: SystemMemory range 0xFE028000-0xFE0281FF conflicts with
              OpRegion 0xFE028000-0xFE028207 (\_SB.PCI0.GEXP.BAR0)
intel-lpss INT3446:00: probe with driver intel-lpss failed with error -16
```

This is the same BIOS defect that the Latitude 5285 and 7275 quirks address.
Setting `QUIRK_IGNORE_RESOURCE_CONFLICTS` for this controller on the 5179 let
I2C4 register, and OV5670 probed on it.

### 8.3 A boot-order race

On one boot the cameras disappeared entirely:

```
ov8858 i2c-INT3477:00: Failed to get endpoint
ov8858 i2c-INT3477:00: probe with driver ov8858 failed with error -22
```

On ACPI systems the sensor's endpoint is a software node that `ipu-bridge`
creates when `ipu3-cio2` probes. If `ov8858` binds first, upstream returns
`-EINVAL`, and the device is never retried. Returning `-EPROBE_DEFER` (as
other ACPI-capable sensor drivers do) fixes this.

### 8.4 Smaller issues

- **VCM supply name.** `dw9714` requests `vcc`, not `vdd` (the name used for
  other VCMs in existing board data). With the wrong name the VCM ran on a
  dummy regulator, and its I²C writes failed with `-EIO`.
- **Privacy-LED connection id.** In Linux 7.0, `v4l2_subdev_get_privacy_led()`
  (called from `v4l2-fwnode` during sensor async registration) looks up
  `con_id "privacy"`. A lookup registered as `"privacy-led"` was silently
  ignored (LED module refcount 0). After the fix, both sensors held the LED
  (refcount 2).
- **LED wiring.** Driving ILED A and ILED B separately through sysfs lit the
  same front LED. A was chosen (`privacy_led=a`).
- **WirePlumber start-up permissions.** WirePlumber could start before logind
  applied ACLs to `/dev/media*` (`Permission denied`), so no cameras appeared
  until it was restarted. Adding the user to the `video` group avoids this.
- **Cheese** opens `/dev/video*` directly. With IPU3 those are raw CSI-2
  receivers and ImgU nodes, so Cheese cannot show an image. GNOME Snapshot
  and browsers use PipeWire → libcamera and work.

## 9. Results

| Test | Result |
|---|---|
| `cam --list` | `Internal back camera (\_SB_.PCI0.LNK0)`, `Internal front camera (\_SB_.PCI0.LNK2)` |
| Rear stream, 1280×720 NV12 (viewfinder) | ≈ 48 fps, correct image |
| Front stream, 1280×720 NV12 (viewfinder) | ≈ 30 fps, correct image |
| Rear stream, 3200×2432 NV12 (still role) | ≈ 24 fps |
| Front stream, 2560×1920 NV12 (still role) | ≈ 30 fps |
| PipeWire | `Built-in Back Camera`, `Built-in Front Camera` (libcamera devices `ov8858`, `ov5670`) |
| Rear VCM | `dw9714` subdev registered |
| Privacy LED (sysfs + visual) | 0 before → 1 while streaming (each camera) → 0 after |
| Repeated boots with v1.4 | sensors, VCM and LED come up every time tested |

Remaining warnings: `ov8858 ... xvclk mismatched, modes are based on 24MHz`.
The PMIC clock is not 24 MHz; the driver's mode timings assume 24 MHz, so the
actual frame rate differs from nominal, but images are correct. libcamera
also reports `Unable to get rectangle` for `ov8858`, because the driver lacks
crop-selection support.

### 9.1 Userspace: the 720p ceiling

With the kernel side working, applications still received at most 1280×720,
even though the sensors stream 3200×2432 (rear) and 2560×1920 (front) in
libcamera's StillCapture role. The xvclk mismatch was not the cause. The
chain is:

1. PipeWire's libcamera plugin (`spa/plugins/libcamera/libcamera-source.cpp`,
   1.6.2) generates a configuration for `StreamRole::VideoRecording` and
   offers applications the sizes in that role's `StreamFormats`.
2. libcamera's IPU3 pipeline handler (`ipu3.cpp`, v0.7.0) uses
   `kViewfinderSize` (1280×720) both as the *default* size for
   Viewfinder/VideoRecording and as the *maximum* of the advertised
   `SizeRange`.
3. `validate()` accepts larger viewfinder sizes regardless:
   `cam -s role=viewfinder,width=2560,height=1920` streamed at 30 fps.

The patch in `userspace/` keeps 1280×720 as the default but advertises the
StillCapture maximum. With a rebuilt Ubuntu package (`0.7.0-1ubuntu2+ipu3vf1`),
PipeWire offers up to 3200×2400 (rear) and 2560×1600 (front). Streams
through `pipewiresrc` ran at 1920×1080 ≈ 28 fps (front), and at 1920×1080 and
3200×2400 ≈ 22 fps (rear). This change is a candidate for libcamera upstream.

### 9.2 Tuning data

Windows image quality comes largely from per-module tuning. The Dell package
contains Intel IQ Studio tuning files for 11 OV5670 and 15 OV8858 module
variants (`OV5670_<module>_SKY.cpf`, `OV8858_<module>_SKY.cpf`, each with a
`*_pipeCfg.bin`, plus `defaultCpff.aiqb`). Each `.cpf` is a `CPFF` container
wrapping an `AIQB` blob (AIQ v2.0, IQ Studio 0.10.4, 2015), consumed by the
closed `libia_cp`/`IntelCameraPlugin` stack. Windows selects the file from
the module name that ACPI reports through `SSDB`/`_DSM` (GNVS fields
`L0M0…L0MF`, `L2M0…L2MF`). libcamera's IPU3 IPA (AGC, AWB, tone mapping, AF)
neither reads AIQB nor has OV5670/OV8858 lens-shading or colour tuning, so
images look softer and flatter than on Windows.

### 9.3 Using the Windows tuning: lens shading and colour correction

**Module identification.** The DSDT's GNVS field list gives the offsets of
`L0M0…L0MF` / `L2M0…L2MF`. Reading GNVS (`0x87904000`) through `/dev/mem`
returned `4BA862T2` (rear, LNK0, 4 lanes) and `4BF523T2` (front, LNK2,
2 lanes), both with MCLK 19.2 MHz. That also explains the `ov8858` xvclk
warning. Both names have matching `OV8858_4BA862T2_SKY.cpf` /
`OV5670_4BF523T2_SKY.cpf` files in the Dell package.

**AIQB layout.** A `.cpf` is a `CPFF` header followed by an `AIQB` block
(size at +4). Records start at AIQB+0x18 as
`[u32 size][u16 format][u16 id]`. The camera-module-characterisation ids
used here:

| id | Contents |
|---|---|
| 2 | sensor: width, height, bit depth, colour-order flag |
| 3 | black level per (exposure, gain), ≈ 64 @ 10 bit |
| 4 | 30 near-flat tables, 6 exposures × 5 gains (dark/black-level grid, *not* lens shading) |
| 5 | saturation level (1023) |
| 10 | **lens shading**: header `(1, n, w, h)`, then n × `[u16 light source, u16, u16, u16][4 × w·h u16]`, 4096 = 1.0 |
| 15 | chromaticity per light source |
| 18 | **colour matrices**: n × 84 B `[u16 light source][5 × u16][3×3 s15.16][copy]`, rows sum to 1 |

Light-source ids follow the CIE illuminant order (1 = A 2856 K, 4 = D50,
6 = D65, 7 = D75, 10 = F2, 12 = F4, 16 = F8, 19 = F11 …). Lens-shading
corner gains are 3.3–5.1×. Grid sizes are 41×31 (front) and 51×39 (rear).

**ImgU shading block, measured.** The uapi header doesn't fully specify the
shading LUT, so it was characterised with a test pattern (left half of the
grid set to v, right half 0) under auto exposure:

1. The kernel sizes the shading operations by the **BDS output** height. The
   grid therefore lives in BDS output coordinates: the downscaled IF crop,
   which libcamera places at (0, 0) of the raw frame. A grid built for the
   raw frame covered the whole picture and was cancelled by AGC.
2. LUT entries are **u12**: 4096 behaves like 0 and 6144 like 2048. The left/right
   ratio rose monotonically from 0.70 (v = 0) to 1.89 (v = 4095). Together with
   the header's documented ranges, this gives
   **gain = 1 + v · 2^gain_factor / 1024**.
3. Setting one field at a time showed the four fields are **colour-labelled**:
   `r` raises V, `b` raises U, and `gr`/`gb` are green.
4. The AIQB channels are stored in the **sensor's raw Bayer order**. Front
   (GRBG) needs AIQB→ImgU `r,gr,gb,b` = `[1,0,3,2]`. Rear (BGGR) needs
   `[3,2,1,0]`. Other orders produced magenta/red/cyan corners on neutral
   walls.

**Implementation.** Two new IPU3 IPA algorithms
(`userspace/libcamera-0.7.0-ipu3-ccm-lsc.patch`):

- `Lsc` interpolates the tables by the AWB colour temperature. It maps each
  ImgU grid point from BDS → IF → raw → sensor array (analogue crop and
  binning) → tuning grid, then resamples bilinearly. It picks the finest grid
  within the ImgU limits (≤ 146 cells per set, ≤ 28 sets) and the smallest
  sufficient `gain_factor`.
- `Ccm` interpolates the 3×3 matrices by colour temperature and writes s2.13
  coefficients, after `Awb`, which otherwise writes a fixed default. An
  optional `saturation` blends towards identity.

The converter `cpf2yaml.py` emits libcamera tuning YAML. `install-tuning.sh`
generates it from the user's own Dell download.

**Results (this unit).** Corner/centre brightness went from 0.43 to ≈ 1.0
(front) and from 0.31 to ≈ 0.6 (rear), with neutral corners. At full strength
the colour matrices (diagonal ≈ 1.7–2.3) amplify the grey-world AWB error,
giving pink centres and green edges under night/mixed light. The default
strength is therefore 0.3. Streaming performance through PipeWire is
unchanged (1080p ≈ 28 fps front, ≈ 22 fps rear).

## 10. Limitations and future work

- **AWB.** Intel's AWB uses per-module chromaticity data (record 15). Porting
  that, or using libipa's Bayesian AWB with these priors, would let the colour
  matrices run at full strength.
- **Rear LSC strength** (≈ 0.6 corner/centre) may need checking on a true
  flat field. The rear test scene was a window at night.
- **Other AIQB records** (black-level tables, noise/sharpening, pipeCfg)
  are not used yet.

- **Latitude 5175** untested. It is covered by the same Windows package and
  is very likely identical, but needs a DMI match and confirmation of the
  `INT3472` instance name.
- **Clock.** Investigate the TPS68470 PLL/HCLK setup (`SetHCLKAB`,
  `EnablePLL` in the Windows driver) and whether 24 MHz can be provided to
  OV8858, or whether `ov8858` should support 19.2 MHz modes.
- **Rear GPIO 9/7** were validated empirically, not from the Windows binary.
- **LED current** is left at the reset value. Windows sometimes sets the ILED
  B current bits (`0x30`).
- **Upstreaming.** The board data, `ipu-bridge` entry and `ov8858` changes
  overlap with the Latitude 5285 series and could be submitted as a 5179
  follow-up once that lands. The `leds-tps68470` driver and the `ov8858`
  probe-defer fix are useful on their own. The LED lookup should probably
  move into board data rather than a module parameter.

## 11. Reproducing the analysis

1. Download Dell `V9X4F` and check its SHA-256
   (`5abbf174cf7bff10a9f6be97d907eee78050fdbed79cf590de8eae8e9d0c9b79`).
2. Open it as a ZIP (`python3 -m zipfile -l …`, or `7z l`). Extract
   `Files/x64/{skccontroller,ov5670,ov8858}.sys`.
3. `objdump -d -M intel skccontroller.sys`. Locate methods through the
   `lea rdx,[rip+…]` references to their `tps68470::…` trace strings. Read
   writes as `call <write>(ctx, edx=reg, r8d=val)`.
4. Decode the `.rdata` doubles near the conversion code (17.8 / 875 / 25 /
   900 / −0.5).
5. Search the sensor drivers for `0x7080af0` and `0x4b0`.

## References

- Linux kernel: `drivers/platform/x86/intel/int3472/`,
  `drivers/media/pci/intel/ipu-bridge.c`, `drivers/media/i2c/ov8858.c`,
  `drivers/mfd/intel-lpss-acpi.c`, `drivers/regulator/tps68470-regulator.c`,
  `include/linux/mfd/tps68470.h`.
- T. Chatard, *Enable cameras on Dell Latitude 5285 2-in-1*, v1–v12,
  linux-media / platform-driver-x86, 2026.
- Dell, *Intel 2D Imaging Driver* `V9X4F`, A03, 30.14393.9656.3064, 2016.
- TI, *TPS68470 Camera PMIC* datasheet.
- libcamera project, IPU3 pipeline handler.
