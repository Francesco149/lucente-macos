# HappyLighting BLE protocol

Reverse-engineered from the decompiled **HappyLighting** Android app (package `com.qh.blelight`,
vendor string `Consmart`). This is the classic "Triones / LEDBLE / Consmart" RGB(W) strip
protocol used by a huge family of cheap AliExpress BLE controllers.

All facts cite `file:line` in `build/decompiled/happylighting/jadx/sources/...`.
Bytes below are shown unsigned hex; the Java source uses signed `byte`, so e.g. `-86 == 0xAA`,
`-16 == 0xF0`, `-17 == 0xEF`, `-52 == 0xCC`, `-49 == 0xCF`, `-69 == 0xBB`, `-98 == 0x9E`.

> **Verified on hardware from macOS (2026-10-22).** Real GATT: service `FFD5` has `FFD9`
> (write-without-response, write) and `FFDA` (notify); service `FFD0` has `FFD4` (notify) and
> `FFD1` (write-without-response). Captured status reply to `EF 01 77`:
> `66 04 24 41 20 01 FF 4B 00 00 03 99` (off, static, orange). Password reply `A0 F0 24 0A` = OK.
>
> Paths cited below refer to the decompiled APK trees in the Linux repo (`../lucente/build/`).

> **Status legend:** facts are from source unless tagged **[INFERRED]** (deduced, not seen) or
> **[UNCERTAIN]** (seen but ambiguous).

---

## Overview

- One GATT profile, many marketing names / chip families, all funneled through the same
  write/notify characteristics and (mostly) the same command bytes.
- Default password handshake on connect (`CF 01 02 03 04 FC` for the unset default `1234`).
- **No checksum** on the common RGB / power / mode commands — they use fixed head + tail
  framing bytes (e.g. `56 ... F0 AA`, `BB ... 44`). A few newer "Dream"/dream-music commands
  *do* carry an XOR checksum.
- **Brightness for RGB strips is not a wire field** — the app scales each R/G/B channel by a
  `progress` (0–100) percentage before sending the `56` color command. There is a separate
  `89` "dimmer" command but it is used *only* for single-channel `Dimmer-` devices.
- Status is read by writing `EF 01 77` and parsing the 12-byte `66 ...` notification.

This driver targets the mainstream **RGB / RGBW strip** subset (names like `Triones`, `LEDBLE`,
`Color+`, `Dream-`, `Flash`, `LD-`). The protocol also covers Triones "qicai" presets,
"DreamY" addressable (`Dream#`/`Dream~`/`Dream=`/`QLAMP`) and `QHM` music variants — noted but
not the primary target.

---

## Identification (scan filter)

Devices are recognized purely by **advertised name** (GAP local name) via one big regex; there
is **no service-UUID scan filter**. Match this prefix set to claim a device for this driver.

Master scan regex — `BluetoothLeService.java:31` (`COMPANY_NAME`):

```
^Triones-|^BRGlight|^Color\+|^Triones\+|^Dream-|^Light-|^Triones~|^Triones|^Color-|^QHM|
^Flash|^LD-|^Dimmer|^Dream\*|^Dream\#|^Dream~|^Dream&|^Morimoto|^Thaillamp|^LXDZ|^Archaic|
^GLOWDRIV|^RAMAND|^Dream=|^QLAMP
```

Applied in the scan callback at `BluetoothLeService.java:99`
(`Pattern.compile(COMPANY_NAME).matcher(name).find()`).

### Name-driven variant selection

The app picks per-feature behavior from substrings of the name (not from GATT). Key buckets:

| Name pattern | Constant / location | Meaning for us |
|---|---|---|
| `^Triones-` / `Triones+` / `Triones` (+ `Triones:` `Triones=` `Triones#`) | `MyBluetoothGatt.java:54` `TRIONES_NAME`; `DeviceUUID`→`MyApplication.java:37` `COMPANY_NAME_TRIONES="Triones="` | classic RGB(W) strips; also enables AES keep-alive (see Auth) and "qicai" presets |
| `^Color\+` / `^Color-` / `^QHM` | `MyApplication.java:28` `COMPANY_NAME2` | classic RGB strips; `QHM` adds 2 extra modes + a different music packet |
| `^Dream#` `^Dream~` `^Dream=` `^QLAMP` | `MyApplication.java:33` `COMPANY_NAME_DREAMY` | **addressable / "DreamY"** — different mode + music commands (`9E`, `FF..`, `A1`); RGBW color still works |
| `^Dream\*` | `MyApplication.java:31` `COMPANY_NAME_DREAMX` | "Dreamf" effects → uses `setDreamMod` (`FF 03 ...` w/ XOR checksum) |
| `^Flash` | `MyApplication.java:39` `COMPANY_NAME_XX` | polls extra status (`getFLightData`) |
| `^Dimmer` | `MyApplication` `Dimmer` (used `MyApplication.java:952`) | single-channel; uses `89` dimmer command, **not** RGB |

**[INFERRED]** For Lucente's first cut, treat any name matching the master regex as a generic
RGB(W) strip and use the common command set below; gate `Dream#/~/=/QLAMP/Dream*` and `Dimmer`
behind capability flags later. The common subset works across the whole family.

---

## GATT

Two *different* services are used: a **WRGB control service** (`ffd5`) for nearly all writes,
and a **data/notify service** (`ffd0`) for notifications. (Many similar protocols collapse these
into `0xffe0`/`0xffe1`; this app uses the `0xffd*` Consmart layout.) UUIDs from
`DeviceUUID.java:5-32`.

| Role | Service UUID | Characteristic UUID | Write type | Source |
|---|---|---|---|---|
| **Write** (all commands) | `0000ffd5-0000-1000-8000-00805f9b34fb` | `0000ffd9-0000-1000-8000-00805f9b34fb` | **Write w/o response** (`WRITE_TYPE_NO_RESPONSE`) for color/power/mode; **Write w/ response** for `setDate`/`setDayData` | `DeviceUUID.java:13,11`; types at `MyBluetoothGatt.java:854,798,1185` |
| **Notify** (status/replies) | `0000ffd0-0000-1000-8000-00805f9b34fb` | `0000ffd4-0000-1000-8000-00805f9b34fb` | notifications (CCCD) | `setNotify()` `MyBluetoothGatt.java:665-666` |
| Device-info read (optional) | `0000180a-...` | `00002a25-...` (serial) | read | `read180a()` `MyBluetoothGatt.java:1414-1415` |

Notes / gotchas:

- **Write characteristic `ffd9` lives in service `ffd5`** — you must look it up under `ffd5`,
  not the notify service. (`setColor` etc. all use `CONSMART_BLE_NOTIFICATION_SERVICE_WRGB_UUID`
  = `ffd5`, `MyBluetoothGatt.java:835-836`.)
- **Notify characteristic `ffd4` lives in service `ffd0`** (`setNotify` looks it up via
  hard-coded `ffd0` at `MyBluetoothGatt.java:665`). The notify handler filters on
  `ffd4` (`MyBluetoothGatt.java:329`).
- Write type: most commands force `setWriteType(1)` = `WRITE_TYPE_NO_RESPONSE` when payload
  ≤ 20 bytes (`MyBluetoothGatt.java:747-748, 796-799, 854`). `setColor` explicitly sets type 1
  (`:854`). `setDate`/`setDayData` use type 2 = `WRITE_TYPE_DEFAULT` (with response)
  (`:1185, 1230`).
- **CCCD**: write `ENABLE_NOTIFICATION_VALUE` (`01 00`) to descriptor
  `00002902-0000-1000-8000-00805f9b34fb` of the notify char (`MyBluetoothGatt.java:679-685`;
  CCCD UUID at `SampleGattAttributes.java:17`).

### Connect sequence (what the app does after services discovered)

`onServicesDiscovered` schedules (`MyBluetoothGatt.java:236-277`):

| Delay | Action | Bytes |
|---|---|---|
| 50 ms | `setNotify()` — enable CCCD | (descriptor `01 00`) |
| 300 ms | `getLightData()` — query status | `EF 01 77` |
| 700 ms | `getFLightData()` (Flash devices only) | — |
| 1000 ms | `checkpwd(pwd)` — auth | `CF 01 02 03 04 FC` (default) |
| 1200 ms | `setDate()` — sync clock | `10 14 yy MM dd hh mm ss w fmt 01` |
| 1600 ms | `getTimeData()` — query timers | `24 2A 2B 42` |
| 1800 ms | `read180a()` — read serial (0x180a/0x2a25) | (GATT read) |

For Lucente we only need **enable notify → `EF 01 77` (status) → `CF 01 02 03 04 FC` (auth)**;
the rest (date/timers/serial) is optional.

---

## Handshake / Auth

Yes — the app sends a password packet on every connect. `checkpwd(String)`
(`MyBluetoothGatt.java:1440-1452`):

- Password is a **4-digit decimal string**, default/unset = `"1234"` (`MyBluetoothGatt.java:91`;
  loaded per-MAC from prefs with fallback `"1234"` at `MyBluetoothGatt.java:605`).
- Each digit is sent as its own byte (BCD-ish, *not* ASCII): for password `i`, bytes are
  `[i/1000, (i%1000)/100, (i%100)/10, i%10]`.

```
checkpwd:  CF  d3 d2 d1 d0  FC        (head 0xCF, tail 0xFC)
default "1234"  ->  CF 01 02 03 04 FC
```

- **Reply (notify):** 4 bytes `A0 <st> ?? 0A` (`MyBluetoothGatt.java:409-435`):
  - `st == 0xF0` → password OK
  - `st == 0x0F` → password is the factory `123456789`-style / wrong-but-known case
  - `st == 0xEE` → error / wrong
- **Set password** `setpwd(new)` (`MyBluetoothGatt.java:1486-1507`): `DF <old 4 digits> <new 4 digits> FD`.
  Reply `B0 <st> ?? 0B` (`MyBluetoothGatt.java:376-398`); `st==0xF0` success.

**Does auth gate control?** **[UNCERTAIN]** The app sends `EF 01 77` and color/power *before*
the `checkpwd` reply arrives and does not block writes on `ischeckpwd`. On most of this hardware
the password is advisory and control works without it, but to be safe Lucente should send
`CF 01 02 03 04 FC` right after enabling notifications. If a unit was given a custom password
the default will be rejected (`A0 ... 0A` with `st!=0xF0`) and control may be refused — treat a
non-`F0` reply as "needs password".

### AES keep-alive (Triones only — likely skip)

For `isTriones` devices the app runs a periodic `setAES()` (`MyBluetoothGatt.java:1382-1400`)
sending an 18-byte `FB ... FA` (or `CB ... CA`) random challenge and validating the `F9 ... F8`
reply against `AES2.Encrypt(...)` (`MyBluetoothGatt.java:511-537`). If validation fails 5× the
app disconnects. **[UNCERTAIN]** Whether *control* requires this depends on firmware; many
Triones clones never send `F9..F8` and the loop simply times out without blocking. Treat as
**optional / out of scope** for v1; revisit if a real Triones unit drops us after ~5 s.

---

## Commands

Service `ffd5` / char `ffd9`, write-without-response unless noted. No checksum unless noted.

### Power on/off — `openLight(boolean)` `MyBluetoothGatt.java:931-945`

| | byte0 | byte1 | byte2 |
|---|---|---|---|
| ON  | `CC` | `23` | `33` |
| OFF | `CC` | `24` | `33` |

```
ON :  CC 23 33
OFF:  CC 24 33
```
3 bytes, head `0xCC`, tail `0x33`, payload `0x23`=on / `0x24`=off. (Also mirrors into the local
status cache `datas[2]`.) Sent via `writeCharacteristic1` → write-no-response (`:944, 796`).

### Static RGB color — `setColor(MyColor)` `MyBluetoothGatt.java:830-861`

7 bytes; head `0x56`, tail `F0 AA`. **Brightness is applied here** by scaling each channel by
`progress/100` (progress clamped to ≥3, `:841`):

```
56  R'  G'  B'  W'  F0  AA
      where R' = red   * progress/100   (0..255)
            G' = green * progress/100
            B' = blue  * progress/100
            W' = warmWhite * progress/100   (0 for pure-RGB)
```

| off | b0 | b1 | b2 | b3 | b4 | b5 | b6 |
|---|---|---|---|---|---|---|---|
| | `56` | R' | G' | B' | W' | `F0` | `AA` |

- The `F0` at b5 is a "RGB selected" flag. When sending **warm-white only** (`warmWhite!=0`),
  the app zeros RGB and sets b5=`0F`, b4=`progress*255/100` (`:844-851`):
  ```
  warm-white:  56 00 00 00 WW 0F AA      (WW = progress*255/100)
  ```
- `setColorW(MyColor, isFullWhite)` `MyBluetoothGatt.java:863-890` is the same but head `0x57`
  / tail `0x75`, used for the dedicated white channel on RGBW/`Dream~`/`QLAMP` units:
  ```
  57 R' G' B' W' F0 75            (color)
  57 00 00 00 WW (F0|0F) 75       (white; F0 if isFullWhite else 0F)
  ```

### Brightness

- **RGB strips: no dedicated brightness command.** Set brightness by re-sending `setColor`
  with the desired `progress` (0–100). Helper `setColorProportion(progress, color)`
  (`MyBluetoothGatt.java:902-910`) just updates `savecolor.progress` and re-emits the `56`
  command — this is exactly what the brightness slider does
  (`AdjustActivity.java:337/348/360/371/398`).
- **Dedicated `Dimmer-` hardware only:** `sendDimmer(boolean)` `MyBluetoothGatt.java:1630-1638`,
  gated to `Dimmer` names (`MyApplication.java:952-957`):
  ```
  89 <00|1F> 00 00 98       (b1 = 0x00 brighter / 0x1F dimmer step)   [UNCERTAIN semantics]
  ```
  Not used for RGB strips — ignore unless we add dimmer support.

### Mode / effect — `setMod(int idx, int speed)` `MyBluetoothGatt.java:973-986`

4 bytes; head `0xBB`, tail `0x44`. The mode byte is looked up from the `Mods` table by index;
speed is a raw byte (the app's slider is 1..31, see below).

```
BB  <modeByte>  <speed>  44
       modeByte = Mods[idx]    (see Modes table)
       speed    = 0x01..0x1F   (1 = fastest .. 31 = slowest)  [see note]
```

| off | b0 | b1 | b2 | b3 |
|---|---|---|---|---|
| | `BB` | Mods[idx] | speed | `44` |

- Speed range: the mode UI clamps speed to **1..31** for this command type
  (`ModActivity.java:1084-1089`). `setSpeed(int)` re-sends the same `BB` frame with the cached
  `modId` and a new speed (`MyBluetoothGatt.java:988-1001`). **[INFERRED]** lower = faster
  (typical for this family; speed is sent raw, firmware interprets).

#### Other mode encodings (variant hardware — note only)

- `setSpeed(i, speed, bright)` `MyBluetoothGatt.java:1003-1013` — addressable: `9E 00 i (speed+1) (bright+25) 00 E9`.
- `setMODY(i, bright)` `MyBluetoothGatt.java:1015-1024` — `9E FF FF (i+1) (bright+25) 00 E9`.
- `sendFxMod(i)` `MyBluetoothGatt.java:1626-1628` — `03 i 00 28`.
- `sendNewMod(a,b,c,d)` `MyBluetoothGatt.java:1622-1624` — `9A 00 a b c d A9`.
- `setDreamMod(mode,speed,c,bright)` `MyBluetoothGatt.java:1640-1664` — `FF 03 00 m s' c' 00 b' 0 FE`
  with `b'[8] = m XOR 3 XOR s' XOR c' XOR b'` (**the one common-path command with an XOR
  checksum**); `Dream*` ("Dreamf") devices only.

### Status query — `getLightData()` `MyBluetoothGatt.java:912-914`

```
EF 01 77        (write w/o response; reply is the 0x66 status notification, see below)
```

### Other commands (brief)

| Feature | Method @ line | Bytes |
|---|---|---|
| Timer query | `getTimeData` :927-929 | `24 2A 2B 42` |
| Read DayData/timers via notify | parsed in `onCharacteristicChanged` :454-509 | replies start `0x25` / `0x66` |
| Set clock | `setDate` :1130-1206 | `10 14 yy MM dd hh mm ss weekday (0F\|F0) 01` (with-response) |
| Set per-day on/off table | `setDayData` :1208-1236 | `23 <87 bytes> 32` (with-response) |
| Per-slot timer | `sendNewTime` :1279-1310 | `H[i] (F0\|0F) hh mm ss week (F0\|0F) T[i]`; `H=23 25 27 43 45 47`, `T=32 52 72 34 54 74` (`:52-53`) |
| Music: mic on/off | `openmic` :1509-1531 | `86 (F0\|0F) 00 68` |
| Music: phone-audio color | `setMusicColor` :1026-1050 | `78 R G B 00 F0 EE` (variant of `56`) |
| Music: external-mic packet | `sendColor_m_data` :1533-1566 | `64 (F0\|0F) <int> <mode> 00 EE 76`; `QHM` → `01 (F0\|0F) <int> <mode> 00 18` |
| Triones presets ("qicai") | `setqicaidata` :1465-1484 | `F6 i j (0\|1) 00*5 6F` (`Triones=`) or `69 i j 0F 96` (`Triones#`) |
| Addressable header query | `readhuancai` :1430-1438 | `1D F0 00 F1`; DreamY → `C5 F0 5C` |

---

## Status notification (CRITICAL — used to preload UI)

Trigger: write `EF 01 77`. The controller replies on notify char `ffd4` with a **12-byte**
packet whose **byte0 == `0x66` (102)**. Parsed at `MyBluetoothGatt.java:469-508` (the
`b4 == 102` branch) and cached into `datas[0..11]`.

Byte layout (verified offsets from the parser):

| Offset | Field | Meaning / encoding | Source |
|---|---|---|---|
| 0 | header | `0x66` | `:469` (`b4 == 102`) |
| 1 | device type | model/type id (**[UNCERTAIN]** exact meaning) | stored, not interpreted |
| 2 | **power** | `0x23` = ON, `0x24` = OFF | `:476-482` (and mirrored by `openLight` :940/942) |
| 3 | **mode** | running mode byte (one of `Mods`, or `0x41`/`0x61` static-color marker) | `:507` (passed as mode to `synTimedata`) |
| 4 | run/pause **[UNCERTAIN]** | status/flags byte | not interpreted |
| 5 | **speed** | current effect speed | `:507` (passed as speed arg) |
| 6 | **R** | red 0..255 | `:484` `value[6] & 255` |
| 7 | **G** | green 0..255 | `:485` `value[7] & 255` |
| 8 | **B** | blue 0..255 | `:486` `value[8] & 255` |
| 9 | **W / warm-white** | white channel 0..255 | `:506-507` (used as `warmWhite`) |
| 10 | version/extra **[UNCERTAIN]** | — | not interpreted |
| 11 | trailer **[UNCERTAIN]** | likely fixed tail | not interpreted |

How the app derives display color/brightness from this (`:483-507`):

- Picks the max of (R,G,B) and computes scale `f = 255 / max`, then normalizes
  `(R*f, G*f, B*f)` to get the **full-brightness hue**, and stores `warmWhite = byte9`,
  `progress = 100`. I.e. it treats the reported RGB as already-dimmed and back-computes the
  pure color; **brightness % is recovered as `max(R,G,B)/255`** (the inverse of the `56`
  send-side scaling). For Lucente:
  - `power = (byte2 == 0x23)`
  - `r,g,b = byte6, byte7, byte8`
  - `brightness% = round(max(r,g,b) / 255 * 100)`  *(matches send-side; [INFERRED] but
    consistent with `setColor` scaling)*
  - `white = byte9`
  - `mode = byte3` (if it equals a `Mods` value → effect mode; `0x41` ≈ static color)
  - `speed = byte5`

Other notification shapes the handler recognizes (for completeness, all in
`onCharacteristicChanged`):

| Length / signature | Meaning | Source |
|---|---|---|
| 8 bytes, `b0==0x85`, `b7==0x58` | addressable "huancai" config | `:337-344` |
| 12 bytes, `b0==0xD0`, `b11==0x0D` | DreamY device info (LED count etc.) | `:345-357` |
| 4 bytes, `b0==0xA0`, `b3==0x0A` | **checkpwd reply** (`b1`: F0 ok / 0F / EE) | `:409-435` |
| 4 bytes, `b0==0xB0`, `b3==0x0B` | **setpwd reply** | `:376-398` |
| 3 bytes, `b0==0xB5`, `b2==0x5B` | huancai write ack | `:367-374` |
| 8 bytes, byte0 ∈ TIME_TAIL | timer slot data → `reSetData` | `:437-438, 1348-1375` |
| 20/var bytes, `b0==0x25` | DayData timer table | `:454-468` |
| 18 bytes, `b0==0xF9`, `b17==0xF8` | AES challenge reply (Triones) | `:511-537` |

---

## Modes (id list)

Mode index → mode byte from the `Mods` table (`MyBluetoothGatt.java:80`):

```java
Mods = {0x25,0x26,0x27,0x28,0x29,0x2A,0x2B,0x2C,0x2D,0x2E,0x2F,0x30,0x31,0x32,
        0x33,0x34,0x35,0x36,0x37,0x38,0x61,0x62,0x63}
//      25   26   27 ...                                  ... 38   61   62   63
```

Names from `res/values/arrays.xml` `string-array name="mods"` (`arrays.xml:15-36`), in index
order. Note: the base `mods` array has 20 names (indices 0..19 → `Mods[0]`=0x25 … `Mods[19]`=0x38).
`QHM` devices append `qhm_add` (2 more) which map to `Mods[20..21]` = `0x61, 0x62`
(`ModActivity.java:1169-1180`). `Mods[22]`=0x63 is reserved/extra. The classic firmware
documents 0x25–0x38 + 0x61–0x63.

| idx | byte | name |
|---|---|---|
| 0 | `0x25` | Rainbow pulsating (七彩渐变) |
| 1 | `0x26` | Red pulsating |
| 2 | `0x27` | Green pulsating |
| 3 | `0x28` | Blue pulsating |
| 4 | `0x29` | Yellow pulsating |
| 5 | `0x2A` | Cyan pulsating |
| 6 | `0x2B` | Purple pulsating |
| 7 | `0x2C` | White pulsating |
| 8 | `0x2D` | Red/Green pulsating |
| 9 | `0x2E` | Red/Blue pulsating |
| 10 | `0x2F` | Green/Blue pulsating |
| 11 | `0x30` | Rainbow flashing (七彩闪烁) |
| 12 | `0x31` | Red flashing |
| 13 | `0x32` | Green flashing |
| 14 | `0x33` | Blue flashing |
| 15 | `0x34` | Yellow flashing |
| 16 | `0x35` | Cyan flashing |
| 17 | `0x36` | Purple flashing |
| 18 | `0x37` | White flashing |
| 19 | `0x38` | Rainbow jumping (七彩跳变) |
| 20 | `0x61` | RGB pulsating (`qhm_add`, QHM only) |
| 21 | `0x62` | RGB jumping (`qhm_add`, QHM only) |
| 22 | `0x63` | (reserved) **[UNCERTAIN]** |

Static color (no effect) is reported in status as mode byte `0x41` (the `synTimedata((byte)65,…)`
calls on every `setColor`, `MyBluetoothGatt.java:843`). To *select* static color, just send the
`56` color command (there is no "set static mode" frame).

---

## Timing / MTU / chunking

- **No MTU negotiation.** All command payloads are ≤ 20 bytes, sent in a single write
  (the code only ever forces no-response write type when `len ≤ 20`,
  `MyBluetoothGatt.java:747, 797, 819`). The largest frame is `setDayData` at **89 bytes**
  (`23 <87> 32`, `:1212`) sent with-response — **[INFERRED]** that one relies on a larger
  negotiated/extended MTU or the firmware accepting a long ATT write; not needed for v1.
- **Color write throttle / queue:** rapid color changes go through `addWriteQueue`
  (`MyBluetoothGatt.java:892-900`) — at most one `56` in flight; the next is popped on
  `onCharacteristicWrite` (`:558-560`). Queue capped at 10. For Lucente, rate-limit color
  writes (one in flight, or ~a few per 100 ms).
- **Retry:** the with-retry `writeCharacteristic(..., true)` loops `writeCharacteristic()` every
  **220 ms** until it returns true (`:758-773`); `setDate` retries every **120 ms** (`:1191-1199`).
- **Connect cadence:** discover services 100 ms (DreamY) / 500 ms after connect
  (`:180-193`); the connect→notify→status→auth→date→timers sequence spans ~50–1800 ms
  (table above). A 16 s connect watchdog disconnects stalls (`:637-648`).
- Music/effect refresh loops re-send every **50–80 ms** (`MySendThread.java:28,50,71,89`).

---

## Open questions

1. **Auth necessity** — does control actually require a correct password, or only timer/config
   writes? Source sends `EF 01 77` + color before the `A0…0A` reply and never blocks writes on
   `ischeckpwd`. **[UNCERTAIN]** → verify against real hardware; treat non-`F0` reply as
   "needs password" defensively.
2. **AES keep-alive** — do real Triones units drop the link after ~5 s without a valid
   `F9…F8`? If so we'd need `AES2` (class `com.consmart.ble.AES2`, key TBD). Likely irrelevant
   for non-Triones names. **[UNCERTAIN]**
3. **Status byte 1, 4, 10, 11** — exact meaning (device type / run-state / version / tail).
   Not interpreted by the app beyond power/RGB/mode/speed.
4. **Speed direction & range** for the `BB` command — confirmed clamp 1..31; **[INFERRED]**
   lower = faster.
5. **`setDayData` 89-byte write** — does it need MTU > 23, or does firmware accept a long write?
   Not needed for core control.
6. **White vs warm-white** — `byte9`/`W'` channel: is it a true white LED or warm-white? Names
   like `Dream~`/`QLAMP` use `setColorW` (`57`). **[UNCERTAIN]** capability per SKU.

---

## Evidence (key file:line)

All paths under `build/decompiled/happylighting/jadx/sources/`.

- **Scan filter / identification:** `com/qh/blelight/BluetoothLeService.java:31` (regex),
  `:99` (match in `onLeScan`). Name buckets: `com/qh/blelight/MyApplication.java:27-41`;
  `MyBluetoothGatt.java:54` (`TRIONES_NAME`).
- **GATT UUIDs:** `com/qh/tools/DeviceUUID.java:11` (write char `ffd9`), `:13` (write svc
  `ffd5`), `:7` (notify char `ffd4`), `:12` (notify svc `ffd0`); CCCD
  `com/qh/tools/SampleGattAttributes.java:17`.
- **Notify enable:** `MyBluetoothGatt.java:662-688` (`setNotify`).
- **Write helpers / write types:** `MyBluetoothGatt.java:732-828` (no-response when ≤20),
  `:854` (color type 1), `:1185` (date type 2).
- **Auth:** `MyBluetoothGatt.java:1440-1452` (`checkpwd`), `:1486-1507` (`setpwd`),
  reply parse `:409-435`; AES `:1382-1400`, `:511-537`.
- **Power:** `MyBluetoothGatt.java:931-945` (`openLight`).
- **Color/brightness:** `:830-861` (`setColor`), `:863-890` (`setColorW`),
  `:902-910` (`setColorProportion`), `:892-900` (`addWriteQueue`),
  brightness slider `com/qh/blelight/AdjustActivity.java:337-398`.
- **Dimmer (non-RGB):** `MyBluetoothGatt.java:1630-1638`; gating `MyApplication.java:947-961`.
- **Modes:** `MyBluetoothGatt.java:80` (`Mods`), `:973-1001` (`setMod`/`setSpeed`);
  names `res/values/arrays.xml:15-36`; mode dispatch `com/qh/blelight/ModActivity.java:1080-1108`.
- **Status query + parse:** `MyBluetoothGatt.java:912-914` (`EF 01 77`),
  `:469-508` (12-byte `66` parser), power byte uses `com/qh/blelight/AdjustActivity.java:323`.
- **Connect sequence:** `MyBluetoothGatt.java:236-302`.
- **Timing/throttle/retry:** `:558-560` (queue pop), `:758-773` (220 ms retry),
  `com/qh/data/MySendThread.java:23-98`.
</content>
</invoke>
