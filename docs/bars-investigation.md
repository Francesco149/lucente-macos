# The LED bars: why Linux lost them, and how macOS talks to them

**Status (2026-10-22):** the bars work fully from macOS (CoreBluetooth). The Linux regression is
**confirmed and fixed** on maximus (Arch, BlueZ 5.87) — see "Confirmed on maximus" below; the
patch is in `../lucente` (`lucente/ble/bluez.py`).

## Symptom

The Linux build of Lucente stopped controlling the two Raingel bars (`VC-BLELIGHT`) while the
four HappyLighting strips kept working. Nothing in the BLE path changed: the last commit to the
Linux repo touching it is from 2026-06-14.

## What the bars actually are (measured from macOS)

All of this was captured with `scripts/probe` and confirmed by eye on the real lights.

**Advertisement** (both bars, roughly every 1.5 s): name `VC-BLELIGHT`, manufacturer data
`58 59 10 02` (company `0x5958` "XY"; group 16 = LIGHT_MAGIC, type 2 = strip), service `AF30`.
On this Mac they appear as `D87A02A2-…61C3` and `52FC9509-…35E3` (CoreBluetooth identifiers are
per-Mac; macOS never exposes MAC addresses).

**GATT** (identical on both):

| Service | Characteristic | Properties |
|---|---|---|
| `AE30` | `AE01` | write-without-response |
| | `AE02` | notify |
| | `AE03` | write-without-response |
| | `AE04` | notify |
| | `AE05` | indicate |
| | `AE10` | read, write (reads `00 00 00 00`) |
| `AE3A` | `AE3B` | write-without-response |
| | `AE3C` | notify |

For comparison, a strip's write characteristic `FFD9` (service `FFD5`) is
*write-without-response **and** write*; the bar's `AE01` is write-without-response **only**.

**Behaviour:**

- `01 01`, `03 FF 00 00 00 00 00`, `02 64`, `03 00 00 FF 00 00 00` written to `AE01` turned the
  bar on, red, full, blue — exactly as `docs/protocols/raingel.md` says. The protocol is fine.
- Subscribed to every notify/indicate characteristic, the bars sent nothing back after any
  write: they really are write-only.
- An idle connection stayed up for over 5 minutes with no traffic at all, so the macOS app sends
  the bars no keepalive. (The Linux app's keepalive re-sent the last power state every 15 s,
  which also silently undid anything done with the IR remote.)
- **A classic (BR/EDR) inquiry finds both bars**, as `VC-BLELIGHT` at `35:2E:51:24:A1:C8` and
  `11:33:AB:6D:2F:4B` (`scripts/probe classic`). They are **dual-mode** radios. The strips don't
  answer: they're LE-only.

## Root cause (Linux)

bleak's BlueZ backend connects by calling `org.bluez.Device1.Connect()`. For a dual-mode device
BlueZ connects only one bearer, chosen by `select_conn_bearer()` in `src/device.c`:

1. a bonded bearer wins (if only one is bonded);
2. a random LE address can only be LE;
3. otherwise the most recently seen bearer — and on a tie, *"Prefer BR/EDR if time is the same
   since it might be from an advertisement with BR/EDR flag set."*

So once BlueZ has seen the bar's BR/EDR side — any desktop Bluetooth panel or a plain
`bluetoothctl scan on` runs interleaved BR/EDR + LE discovery — or once it was bonded over
BR/EDR, `Connect()` goes over **classic**. There is no GATT for us there, so bleak never gets
its services and the connect times out or fails. The strips are LE-only, so they're unaffected.
BlueZ keeps this per-device state on disk (`/var/lib/bluetooth/<adapter>/<device>/`), which is
why it "stopped at some point" and stayed broken with no code change.

Ruled out:

- **Write type.** bleak 3.0.2 sends `WriteValue` with `type=command` when `response=False`
  (read from its source), which matches `AE01`'s only property.
- **The bars or their protocol.** The same bytes work over LE today.
- **A bleak upgrade.** The nightly bundle installs unpinned dependencies from `pyproject.toml`
  (`tools/build_bundle.py` uses pip, not `uv.lock`), but the newest bleak on PyPI is still
  3.0.2, the locked version. `dbus-fast` has drifted (5.0.22 locked, 5.2.0 current); unlikely
  to matter here, but the bundle should install from the lockfile anyway.

## Confirmed on maximus (2026-10-22)

- The Linux app's saved addresses for the bars are the same `11:33:AB:6D:2F:4B` /
  `35:2E:51:24:A1:C8` that answer BR/EDR inquiries, so each bar is one BlueZ device with both
  bearers. A plain `bluetoothctl scan le` registers `LE` **and** `BREDR` objects for a bar (only
  `LE` for a strip): the bar's own LE advert marks it dual-mode, no desktop panel needed.
- `diag_connect.py` against a bar, with `btmon`: `Create Connection (0x01|0x0005)` (BR/EDR), then
  `org.bluez.Error.BREDR.ProfileUnavailable: No more profiles to connect to`.
- After `PreferredBearer = "le"`: `LE Extended Create Connection (0x08|0x0043)`, connected, GATT
  up. The patched app connected both bars and set them green through its REST API.
- Separately, maximus's bluetoothd (48 days up) had wedged discovery: it reported
  `Discovering: yes` while the controller wasn't scanning, so nothing could see any light.
  Restarting `bluetooth.service` fixed that.

The patch: Raingel's driver sets `prefers_le`, and the transport sets `PreferredBearer=le` over
D-Bus before each connect (it has to be re-set because BlueZ forgets unpaired devices). maximus
already runs BlueZ with `Experimental = true`, which the property requires. The nightly bundle
now installs from `uv.lock` with hashes.

## Verify on another Linux host

1. `bluetoothctl info <bar address>` — signs BlueZ knows the classic side: `Paired: yes`,
   `Bonded: yes`, a `Class:` line, or classic profile UUIDs. If the address is one of the two
   above, the LE and BR/EDR sides share one BlueZ device object.
2. `sudo btmon` while Lucente connects to a bar. `Create Connection` (opcode `0x0405`) means
   BR/EDR — the bug. `LE Create Connection` / `LE Extended Create Connection` means LE.

## Fixes for the Linux app (least to most invasive)

1. **Quick unblock:** `bluetoothctl remove <address>` for each bar, then avoid opening the
   desktop Bluetooth panel while Lucente runs. Fragile: any dual-mode discovery re-learns it.
2. **Prefer LE per device:** BlueZ ≥ 5.80 has an experimental `PreferredBearer` property
   (`bluetoothd -E`, or `Experimental = true` in `/etc/bluetooth/main.conf`). Lucente could set
   it to `"le"` on Raingel devices before connecting, e.g.
   `busctl set-property org.bluez /org/bluez/hci0/dev_XX_XX_XX_XX_XX_XX org.bluez.Device1 PreferredBearer s le`.
3. **LE-only radio:** `ControllerMode = le` in `main.conf` (disables classic for everything on
   that adapter, e.g. headphones), or give Lucente its own dongle via `LUCENTE_BLE_ADAPTER`.

Separately, `tools/build_bundle.py` should install from `uv.lock` (`uv export --frozen`) so
nightly bundles stop picking up whatever is newest.

## Why macOS is immune

`CBCentralManager.connect` always opens an LE link to a `CBPeripheral`; classic devices live in a
different framework (IOBluetooth). The macOS app also picks each characteristic's write type
from its real properties instead of assuming one, because CoreBluetooth silently drops a
response-less write to a characteristic that doesn't advertise it.
