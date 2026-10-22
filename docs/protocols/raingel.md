# Raingel BLE protocol

Reverse-engineered from the decompiled **Raingel** Android app (Play/AliExpress package
`com.raingel.app`). The shipped app is a **rebrand of the DoHome / "DoIt" `am.doit.dohome.strip`
codebase** — all real logic lives under `am.doit.dohome.strip.*`, while `com.raingel.app` contains
only the manifest + `R`. This is the cheap-AliExpress "Magic"/DoHome LED **bar/strip** ecosystem
(scan service `AF30`, GATT service `AE30`, mfg-ID `0x5958`).

Framework: **native Android (Kotlin/Java), dex only.** BLE is the **Nordic Semiconductor Android
BLE library** (`no.nordicsemi.android.ble.BleManager`) plus the Nordic scanner-compat
(`no.nordicsemi.android.support.v18.scanner`). The app's protocol lives in
`am.doit.dohome.strip.service.{StripBleManager, StripManager}`.

All facts cite `file:line` in the decompiled trees:
- smali (complete, source of truth): `build/decompiled/raingel/apktool/smali/am/doit/dohome/strip/...`
- jadx (partial; some core classes failed to decompile but beans/helpers are readable):
  `build/decompiled/raingel/jadx/sources/am/doit/dohome/strip/...`

Bytes are shown unsigned hex. The app builds every packet as an **uppercase hex string** via
`Conversion.intToHexStr(value, width)` and then `BleUtils.hexStr2Bytes()` — so each "field" below
is literally `width/2` bytes, MSB-first within the field.

> **Verified on hardware from macOS (2026-10-22)** — see `../bars-investigation.md`. The real GATT
> table matches below (`AE01` is write-without-response *only*; there are more characteristics —
> `AE03/AE04/AE05/AE10` and a second service `AE3A` — that the app never uses). Power, brightness,
> color, white and the clock packet all confirmed by eye. No notifications arrive on any
> characteristic, even when subscribed. The bars are **dual-mode** (they also answer BR/EDR
> inquiries), which is what broke them on Linux.
>
> Paths cited below refer to the decompiled APK trees in the Linux repo (`../lucente/build/`).

> **Status legend:** facts are from source unless tagged **[INFERRED]** (deduced, not directly
> seen) or **[UNCERTAIN]** (seen but ambiguous).

---

## Overview & confidence

- **Confidence: HIGH** for identification, GATT, handshake, and the core command set
  (power / brightness / RGB / white / mode) — all read directly from `StripManager` /
  `StripBleManager` smali.
- **Write-only protocol.** There is **no auth/password**, **no checksum**, **no terminator**, and
  **CRITICALLY no status notification / read path anywhere in the app** (see
  [Status Notification](#status-notification)). Commands are `[opcode][args…]`, fire-and-forget,
  written **WITHOUT response**.
- The *only* packet sent on connect is a date/time sync (opcode `08`).
- Device capabilities (RGB vs CCT vs white, etc.) are learned at **scan time** from 2 bytes of
  BLE manufacturer-specific data — not by querying the device.
- Effects ("modes") are a large static catalog packed into opcode `07`.

For a clean-room Python/bleak driver targeting LED **bars/strips**, you need exactly: the scan
filter, connect + write-char lookup, the `08` time handshake (optional but the app always sends
it), and opcodes `01/02/03/07`. Everything else (IC config, mic/music, timer/alarm, laser/motor)
is optional / device-class-specific.

---

## Identification (scan filter)

Two independent signals, both checked before a device is accepted:

1. **Advertised service UUID** `0000AF30-0000-1000-8000-00805F9B34FB` (the 16-bit `AF30`
   expanded with the Bluetooth base UUID). Used as a `ScanFilter.setServiceUuid(...)`.
   - `StripBleManager.smali:67` (`SERVER_SCAN = uuid16To128("AF30")`)
   - `StripManager.smali:1216-1222` (`ScanFilter$Builder.setServiceUuid(ParcelUuid(SERVER_SCAN))`)
   - `BleUtils.java:38-43` confirms `uuid16To128` uses base `-0000-1000-8000-00805f9b34fb`.

2. **Manufacturer-specific data, company ID `0x5958`** (decimal 22872; little-endian on air it is
   the bytes `58 59`, ASCII `"XY"`). The record **must be exactly 2 bytes**; those 2 bytes are the
   device's `group` and `type` (see below). Records that aren't present or aren't length-2 are
   ignored.
   - `StripManager$1.smali:68` (`const/16 v0, 0x5958`), `:71` (`getManufacturerSpecificData(0x5958)`),
     `:78-84` (length must `== 2`), `:154-166` (`StripDevice(addr, name, mfg[0]&0xFF, mfg[1]&0xFF)`).

There is **no name-prefix filter** in the scan path. A display name is *derived* from the MAC for
UI only (`StripDevice.getDeviceName()` → `"Light_" + macHi + macLo`, or trims the GAP name; legacy
name `VC-BLELIGHT` is treated as nameless) — `StripDevice.java:114-132`. For our driver, **match on
service UUID `AF30` and/or mfg-ID `0x5958`**; treat the GAP name as cosmetic.

### Manufacturer bytes → capabilities (preload without connecting)

`mfg[0] = group` (capability class), `mfg[1] = type` (physical form). Enum values from
`StripDevice.java:12-45`:

`DeviceGroup` (mfg byte 0) — drives which controls to show:

| group | name | RGB? | CCT? | W/B? |
|------:|------|:---:|:---:|:---:|
| 1  | LIGHT_DIM | | | |
| 2  | LIGHT_CCT | | ✓ | |
| 3  | LIGHT_RGB | ✓ | | |
| 4  | LIGHT_RGBW | ✓ | | ✓ |
| 5  | LIGHT_RGBC | ✓ | ✓ | |
| 6  | LIGHT_RGBCW | ✓ | ✓ | ✓ |
| 16 | LIGHT_MAGIC | ✓ | ✓ | ✓ |
| 17 | LIGHT_MAGIC_W_2PATH | | | |
| 18 | LIGHT_MAGIC_C_2PATH | | | |
| 19 | LIGHT_START | | | |
| 20 | LIGHT_MAGIC_W | | | |
| 21 | LIGHT_MAGIC_CW | | | |

Helper predicates (`StripDevice.java:94-108,150-153`): `isRgb = group∈{3,4,5,6,16}`,
`isCct = group∈{2,5,6,16}`, `isWb = group∈{4,6,16}`, `isTwoPath = group∈{17,18}`,
`isMagic = group∈{16,20,21}`.

`DeviceType` (mfg byte 1): `1 LIGHT_BULB, 2 LIGHT_STRIP, 3 LIGHT_CEILING, 4 LIGHT_FLOOD,
5 LIGHT_SPOT` (`StripDevice.java:39-45`). **[INFERRED]** mapping of which byte is group vs type
is from the constructor arg order `(addr, name, group=mfg[0], type=mfg[1])`; confirm against a real
advertisement when sniffing.

There are also `DeviceTable` / `DeviceUi` enums (`StripDevice.java:27-73`) describing settings
pages — not needed for basic control.

---

## GATT

All UUIDs are 16-bit values expanded with the standard Bluetooth base UUID
(`0000xxxx-0000-1000-8000-00805F9B34FB`). Defined in `StripBleManager.smali:63-118`.

| Role | UUID (16-bit) | Full UUID | Notes |
|------|:-------------:|-----------|-------|
| Scan/advertised service | `AF30` | `0000AF30-0000-1000-8000-00805F9B34FB` | scan filter only (`SERVER_SCAN`) |
| **GATT service** | `AE30` | `0000AE30-0000-1000-8000-00805F9B34FB` | primary service (`SERVER`) |
| **Write characteristic** | `AE01` | `0000AE01-0000-1000-8000-00805F9B34FB` | all commands; **Write Without Response** |
| Notify characteristic | `AE02` | `0000AE02-0000-1000-8000-00805F9B34FB` | declared but **never enabled / read** — see below |

Notes:
- The scan service (`AF30`) differs from the GATT service (`AE30`); connect by service `AE30`.
- `isRequiredServiceSupported` only requires that service `AE30` exposes characteristic `AE01`;
  the device is considered ready once the write char is found (`StripBleManager.smali:51-95`).
- **Write type = WRITE_WITHOUT_RESPONSE.** `StripBleManager.write([B)` calls Nordic
  `writeCharacteristic(AE01, data, 1)` then `.enqueue()`; the trailing `1` is
  `BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE` (Android constant `1`)
  — `StripBleManager.smali:150-173`, Nordic overload `writeCharacteristic(char,[B,int)`
  at `smali_classes3/no/nordicsemi/android/ble/BleManager.smali:2159`.
- Nordic `BleManagerGattCallback.onServicesInvalidated()` is a no-op
  (`StripBleManager.smali:97-101`); there is no `initialize()` override at all.

---

## Handshake / Auth

- **No password, no auth, no challenge.** Nothing in `StripBleManager` or `StripManager` sets a
  password, and `isRequiredServiceSupported` performs no write. The user "never setting a password"
  is moot — the protocol has none.
- **On connect, the app sends exactly one packet: a date/time sync (opcode `08`).** Fired from the
  Nordic `ConnectionObserver.onDeviceReady()` (after service discovery) →
  `StripManager.updateDateTime(manager)` — `StripManager$1$1.smali:163-362` (call at `:360`).
  This is *not* required to control the light (it's a clock for on-device timers); a driver may
  skip it, but sending it matches app behavior.

### `08` — date/time sync (12 bytes)

Built in `StripManager.smali:1787-1950`. Layout (each field MSB-first; the 16-bit year is sent
**little-endian** as two bytes):

| off | bytes | field | value |
|----:|:-----:|-------|-------|
| 0 | 1 | opcode | `08` |
| 1 | 1 | subcmd / fixed | `01` |
| 2 | 3 | fixed | `00 00 00` |
| 5 | 1 | year low byte | `year & 0xFF` |
| 6 | 1 | year high byte | `year >> 8` |
| 7 | 1 | month | `Calendar.MONTH + 1` (1–12) |
| 8 | 1 | day | day of month (1–31) |
| 9 | 1 | hour | 0–23 |
| 10 | 1 | minute | 0–59 |
| 11 | 1 | second | 0–59 |

Example for 2026-06-13 18:30:00 → `08 01 00 00 00 EA 07 06 0D 12 1E 00` (`0x07EA = 2026`).

---

## Commands

General form: **`[opcode][arg]…`**, each value a 1-byte field unless noted, **no checksum, no
terminator**, sent Write-Without-Response. Values pass through `intToHexStr(v,2)`; note `v<=0`
encodes as `00` (so any 0 byte is fine, but **negative/over-255 values are NOT range-clamped** by
the encoder — `Conversion.java:102-125`). The public command methods are on `StripManager`; a
broadcast `write([B)` fans out to every *selected/connected* device
(`StripManager.smali:267-364`).

### Opcode map

| opcode | method | purpose |
|:------:|--------|---------|
| `01` | `switchLight(bool)` | power on/off |
| `02` | `updateBrightness(int)` | brightness |
| `03` | `ColorAdjust(r,g,b,a,b2,c)` / `updateColor(argb)` | RGB + white channels |
| `04` | `deviceMicUpdate(a,b)` | device-side mic/rhythm config |
| `05` | `updateDelay(on,?,sec)` | countdown / delay-off timer |
| `07` | `ModeAdjust(...)` | effects / dynamic modes (two variants) |
| `08` | `updateDateTime(...)` | clock sync (handshake) |
| `0C` | `updateTimer(...)` | scheduled on/off timer |
| `0E` | `IcOrder(int)` | addressable-IC color order |
| `0F` | `IcLength(int)` | addressable-IC pixel count (LE16) |
| `10` | `recorderUpdate(...)` | phone-streamed music/rhythm frame |
| `11` | `openPhoneMic()` | enable phone-mic music mode |
| `12` | `setRgbOrder(a,b)` | RGB channel order |
| `15` | `updateMotor(on,speed)` | motor accessory |
| `17` | `updateLaser(on,speed)` | laser accessory |
| `06`/string | `updateAlarm(list)` | alarm schedule (uses `com.vision.train…Alarm`) |

### Core commands (the LED-bar essentials)

**Power — `01`** (`StripManager.smali:1271-1311`):

| off | byte | value |
|----:|:----:|-------|
| 0 | `01` | opcode |
| 1 | `00`/`01` | `01` = on, `00` = off |

**Brightness — `02`** (`StripManager.smali:1713-1751`):

| off | byte | value |
|----:|:----:|-------|
| 0 | `02` | opcode |
| 1 | level | brightness, 1 byte. **[INFERRED]** range 0–100 (UI uses 0–100 seekbars elsewhere; not clamped in code). Confirm 0–100 vs 0–255 by sniffing. |

**Color — `03`** (`ColorAdjust(p1..p6)`, `StripManager.smali:368-443`). 7-byte packet
`03 p1 p2 p3 p4 p5 p6`. `updateColor(argbInt)` extracts `Color.red/green/blue` and calls
`ColorAdjust(R, G, B, 0, 0, 0)` (`StripManager.smali:1753-1785`):

| off | byte | RGB-set (`updateColor`) | white-set (CCT/W UI) |
|----:|:----:|-------------------------|----------------------|
| 0 | `03` | opcode | opcode |
| 1 | p1 | **R** (0–255) | `00` |
| 2 | p2 | **G** | `00` |
| 3 | p3 | **B** | `00` |
| 4 | p4 | `00` | `00` |
| 5 | p5 | `00` | **white/CCT value** |
| 6 | p6 | `00` | `01` |

The white/CCT path (`ColorFragment.smali:240-281`) sends `ColorAdjust(0,0,0,0, value, 1)`. So
p1–p3 = RGB, and p4/p5/p6 carry the white/CCT channels with p6 acting as a channel/enable selector.
**[UNCERTAIN]** exact semantics of p4/p5/p6 (warm vs cold white, 2-path) — depends on `group`; verify
per device class with a sniffer.

### Effects — `07` (`ModeAdjust`, two overloads)

Both start with opcode `07`. The effect catalog is a big static table in
`bean/Mode.java:42-82` (arrays `RGB_MODES`, `MAGIC_MODES[18][...]`, `SPHERE_MODES`). Strings like
`"0201000000"`, `"67"`, `"5670"` are **palette/segment specifiers sent raw as hex bytes** (they are
already hex digit-strings).

**Variant A — RGB animated modes** (`ModeAdjust(int modeId, int p2, int brightness, int colorCount,
String colorValue)`, `StripManager.smali:545-608`; caller `ModeFragment.smali:707-720`). Packet:

| off | bytes | field |
|----:|:-----:|-------|
| 0 | 1 | `07` opcode |
| 1 | 1 | `modeId` = selected tab + 1 |
| 2 | 1 | `p2` (mode sub-param) |
| 3 | 1 | `brightness` (seekbar) |
| 4 | 1 | `colorCount` (`Mode.getColorCount()`, 2–8) |
| 5 | N | `colorValue` raw hex (palette indices, e.g. `67` → `0x67`) |

**Variant B — "magic"/dynamic modes** (`ModeAdjust(String formatValue, int p2, int brightness,
String colorValue)`, `StripManager.smali:610-661`; caller `ModeFragment.smali:732-742`). Packet:

| off | bytes | field |
|----:|:-----:|-------|
| 0 | 1 | `07` opcode |
| 1 | 1 | `formatValue` — packed mode byte (see below) |
| 2 | 1 | `p2` |
| 3 | 1 | `brightness` |
| 4 | N | `colorValue` raw hex (e.g. `0201000000`) |

`formatValue()` packs the mode id and a direction/section/colorful/alternate/status flag into one
byte (`Mode.java:158-170`):
- generic: `(modeId & 0x1F) | (section << 7) | (direction << 6)`
- modeId 14: `(modeId & 0x1F) | (colorful << 6)`
- modeId 16: `(modeId & 0x1F) | (alternate << 6)`
- modeId 17: `(modeId & 0x1F) | (status << 6)`

So mode ids 1–18 live in the low 5 bits; bits 6/7 are direction/section toggles. The 18 `MAGIC_MODES`
rows each pair a `(modeId, colorId, paletteString)` with both flag states (e.g. forward/reverse).

`RGB_MODES` (`Mode.java:80`) are 30 presets, each `(index, paletteString, colorCount)` — e.g.
`(0,"67",2) … (29,"01234567",8)`. `SPHERE_MODES` (`:81`) are 8 presets for a "sphere"/2-path device.

### Other commands (secondary / device-class-specific)

Captured for completeness; not needed for a basic RGB/CCT bar.

- **`05` delay-off** `updateDelay(bool on, bool ?, int sec)` → `05 [on] [sec_lo] [sec_hi]`
  (16-bit seconds, little-endian) — `StripManager.smali:1952-2019`.
- **`0C` timer** `updateTimer(int,int,bool,int,int,int,int)` opcode `0C` — scheduled on/off
  (`StripManager.smali:2125+`).
- **`0E` IC order** `IcOrder(int)` → `0E [order]` — `StripManager.smali:503-543`.
- **`0F` IC length** `IcLength(int)` → `0F [len_lo] [len_hi]` (16-bit pixel count, little-endian)
  — `StripManager.smali:445-501`.
- **`12` RGB order** `setRgbOrder(int,int)` → `12 [a] [b]` — `StripManager.smali:1105-1153`.
- **`04` device-mic** `deviceMicUpdate(a,b)` → `04 [a] [b]` — `StripManager.smali:855-902`.
- **`11` phone-mic** `openPhoneMic()` → `11 04` — `StripManager.smali:931-973`.
- **`10` music frame** `recorderUpdate(p1,p2,p3,p4,p5)` → `10 p1 p2 p3 00 00 p4 p5` (phone-streamed
  rhythm/audio reactive frame; `recorderStop` calls it with p4=0) — `StripManager.smali:998-1082`.
- **`15` motor** `updateMotor(on,speed)` → `15 [01/00] 00 [speed]` — `StripManager.smali:2075-2123`.
- **`17` laser** `updateLaser(on,speed)` → `17 [01/00] 00 [speed] 64` — `StripManager.smali:2021-2073`.
- **alarm** `updateAlarm(List<Alarm>)` (max 6 entries) — `StripManager.smali:1534+`; uses
  `com.vision.train.data.alarm.Alarm`. Opcode emitted later in the builder (string-literal path).

---

## Status Notification

**There is none.** This is the single most important finding for preloading UI state:

- The notify characteristic `AE02` is declared (`StripBleManager.smali:15,93-103`) but **never used**.
- A full sweep of the app code (`am/doit/dohome/**`) for `enableNotifications`,
  `setNotificationCallback`, `enableIndications`, `waitForNotification`, or `readCharacteristic`
  returns **zero** hits. The `BleManagerGattCallback` has no `initialize()` and no notify setup.
- The `ConnectionObserver` (`StripManager$1$1.smali`) only flips local `connected`/`select` flags
  and sends the `08` clock packet; it never subscribes to anything.
- `BleCallback` (`service/BleCallback.java`) surfaces only `onDeviceFound`, `onDeviceStateChanged`,
  `onDeviceGroupChanged`, `onBleStateChanged` — all driven by scan results and local state, not by
  device-reported state.

**Consequence for the driver:** the device does not report power/RGB/brightness/mode back over BLE.
The app's "current state" is **optimistic local state** plus the **2 manufacturer bytes captured at
scan time** (`group`, `type` → capability set, not live values). To "preload" a panel you can only:
(a) read `group`/`type` from the advertisement to decide which controls to show, and (b) assume an
initial state or cache the last value you sent.

If live read-back is required, it must be obtained by **BLE sniffing** (e.g. nRF Sniffer / Android
HCI snoop log) to check whether the firmware *spontaneously* notifies on `AE02` despite the app not
subscribing — the app gives no evidence either way. Capture: connect with the official app, enable
notifications on `AE02` manually with nRF Connect, toggle the light from a physical remote, and see
if any `66…`/status frame arrives. **[UNCERTAIN]** existence of any such frame.

---

## Modes (effect catalog summary)

- `bean/Mode.java:42-82` holds the entire effect catalog: 18 `MAGIC_MODES` rows (dynamic modes,
  each with forward/reverse or colorful/alternate/curtain variants), 30 `RGB_MODES` presets, and 8
  `SPHERE_MODES`.
- A "mode" carries: `modeId` (1–18 for magic, 0–29 for RGB presets), `colorId`, `colorCount` (2–8),
  a `colorValue` palette string, and flag fields (`section/direction/alternate/colorful/status`)
  that fold into the wire byte via `formatValue()`.
- Speed: there is **no dedicated mode-speed field in the `07` packet**. Speed/brightness is the
  `brightness` byte position, and animation parameters are encoded in `p2` / the palette string.
  **[UNCERTAIN]** whether a separate speed control exists for some device classes.

For a first driver, expose: power, brightness, RGB, white/CCT, and a small set of `07` presets built
from `RGB_MODES` (Variant A) — those are the most broadly supported.

---

## Timing / MTU / chunking

- **MTU:** the app never calls `requestMtu` / `overrideMtu` (no hits in `am/doit/dohome/**`), so it
  uses the **default ATT MTU (23 → 20-byte payload)**. All commands above are ≤ 20 bytes, so no
  chunking is needed. The longest is the date packet (12 B) and `07` mode packets (≈ 4 + palette).
- **Write pacing:** writes go through the Nordic request queue (`.enqueue()`), one at a time;
  because they are Write-Without-Response there is no app-level ack. **[INFERRED]** add a small
  inter-write delay (e.g. 20–50 ms) in bleak to avoid dropping rapid color/brightness updates, since
  WRITE_NO_RESPONSE has no flow control. Tune against real hardware.
- **Connection:** `connect(device).useAutoConnect(true).timeout(0).enqueue()`
  (`StripManager$1.smali:234-248`) — auto-connect, no timeout. For bleak, a normal connect is fine.

---

## Open questions (need BLE sniffing to resolve)

1. **Live state read-back** — does the firmware notify on `AE02` at all? App never subscribes
   (see Status Notification). Capture HCI snoop / nRF Connect to confirm. *Biggest gap.*
2. **Brightness/white ranges** — `02` level and `03` p5 white value: 0–100 or 0–255? Not clamped
   in the encoder; UI seekbars suggest 0–100 **[INFERRED]**.
3. **`03` white-channel semantics** — exact meaning of p4/p5/p6 across `group` types (warm vs cold
   white, 2-path RGBCW). Verify per device class.
4. **Manufacturer-byte order** — confirm `mfg[0]=group, mfg[1]=type` against a real advertisement.
5. **Mode `p2` / speed** — what `p2` encodes in the `07` packet, and whether any speed control
   exists. Catalog is in `Mode.java` but the wire effect of `p2` isn't fully pinned.

---

## Evidence (key file:line)

GATT / write:
- `StripBleManager.smali:63-118` — UUID constants (`AF30/AE30/AE02/AE01`).
- `StripBleManager.smali:150-173` — `write([B)` → `writeCharacteristic(AE01, data, 1)` (no-response).
- `StripBleManager$StripGattCallback.smali:51-95` — requires service `AE30` + char `AE01`.
- `BleUtils.java:34-43` — `uuid16To128` (standard base UUID).
- `smali_classes3/no/nordicsemi/android/ble/BleManager.smali:2159` — Nordic `writeCharacteristic(char,[B,int)`.

Identification:
- `StripManager.smali:1154-1241` — `startScan` builds `ScanFilter.setServiceUuid(AF30)`.
- `StripManager$1.smali:68-166` — mfg-ID `0x5958`, length-2 check, `StripDevice(addr,name,mfg0,mfg1)`.
- `StripDevice.java:12-108,114-153` — group/type enums + capability predicates + name derivation.

Handshake / connect:
- `StripManager$1.smali:204-248` — create `StripBleManager`, set observer, `connect(...).useAutoConnect(true)`.
- `StripManager$1$1.smali:163-362` — `onDeviceReady` → `updateDateTime(manager)` (the only connect-time write).
- `StripManager.smali:1787-1950` — `updateDateTime` packet build (`08 01 00 00 00 yyLO yyHI MM DD hh mm ss`).

Commands:
- Power `01`: `StripManager.smali:1271-1311`. Brightness `02`: `1713-1751`.
- Color `03`: `ColorAdjust` `368-443`, `updateColor` `1753-1785`; white path `ColorFragment.smali:240-281`.
- Mode `07`: `ModeAdjust(I,I,I,I,String)` `545-608`, `ModeAdjust(String,I,I,String)` `610-661`;
  callers `ModeFragment.smali:707-742`; catalog `bean/Mode.java:42-170`.
- IC `0E/0F`: `503-543` / `445-501`. RGB order `12`: `1105-1153`. Mic/music `04/11/10`:
  `855-902` / `931-973` / `998-1082`. Motor/laser `15/17`: `2075-2123` / `2021-2073`.
  Delay/timer/alarm `05/0C/…`: `1952-2019` / `2125+` / `1534+`.

Encoding:
- `Conversion.java:102-125` — `intToHexStr(value,width)` (uppercase hex, zero-pad; `value<=0` → all-zero).
- `BleUtils.java:7-32` — `bytes2HexStr` / `hexStr2Bytes`.

No-notify proof:
- Sweep of `build/decompiled/raingel/apktool/smali/am/doit/dohome/**` for
  `enableNotifications|setNotificationCallback|enableIndications|readCharacteristic|waitForNotification`
  → no matches. `StripBleManager$StripGattCallback` has no `initialize()`.
