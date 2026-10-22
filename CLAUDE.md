# Lucente for macOS

Native macOS controller for BLE LED strips (HappyLighting/Triones) and bars (Raingel/DoHome).
Swift 6 + SwiftUI + CoreBluetooth, macOS 26+, zero third-party dependencies. Port of `../lucente`
(Python/bleak, Windows + Linux), which also holds the original APK reverse-engineering trail.

## Commands

```
make run      build + relaunch the app        make test    swift test (31 tests, ~2 s)
make build    CONFIG=Release for optimized    make logs    unified log stream
make probe ARGS="scan|inspect <id>|write <id> <char> <hex>…|classic"   raw BLE workbench
```

`xcodebuild … test` / ⌘U runs the same package tests through the shared scheme.

## Layout and boundaries

- `Packages/LucenteKit` — all non-UI code. `Model/` (common types) → `Drivers/` (the only place
  that knows bytes; pure values, no I/O) → `Bluetooth/` (CoreBluetooth) → `Store/` (`LightStore`,
  the `@Observable` model the UI binds to). Never leak device bytes above `Drivers/`.
- `App/` — SwiftUI only. Synchronized folder group: drop files in, no project edits needed.
- `Config/*.xcconfig` — every build setting lives here, not in `project.pbxproj`. Committed config
  signs ad hoc; `Config/Local.xcconfig` (git-ignored) sets a real team for a stable signature.
- New vendor = one `Drivers/<Name>Driver.swift` conforming to `LightDriver` + `DriverRegistry` line
  + tests in `DriverTests.swift`.

## Concurrency model

The whole Bluetooth layer and store are `@MainActor`: the `CBCentralManager` uses the main queue
and delegates use isolated conformances (`extension X: @MainActor CBCentralManagerDelegate`).
Traffic is tiny, so this is simpler and safer than a BLE actor. The app target uses the classic
nonisolated default (not MainActor-by-default) because App Intents entities/queries must be
`Sendable` and nonisolated.

## Things that bit us / non-obvious facts

- CoreBluetooth **silently drops** a `.withoutResponse` write to a characteristic that doesn't
  advertise that property — `PeripheralLink` picks the write type from real properties.
- Writes are paced (30 ms) and coalesced per `Frame.Slot`; a replaced frame moves to the back so
  the last user action wins. Scenes send power first: some controllers ignore color while off.
- Bars: write-only (state is optimistic, persisted), hold idle links 5+ min (no keepalive), and
  are **dual-mode** radios — the cause of the Linux regression (fixed in ../lucente with BlueZ
  `PreferredBearer=le`, verified on `ssh maximus`). See docs/bars-investigation.md.
- Strips: keepalive = status query `EF 01 77` every 20 s, which also refreshes live state.
- macOS gives per-Mac peripheral UUIDs, never MACs. Default names: strips use the MAC tail from
  their advertised name (`Triones:…033E` → "Strip 033E"); bars use the UUID tail.
- Bluetooth permission is attributed to the *responsible app*. Run the probe via `scripts/probe`
  (wraps it in an .app and launches with `open`), never the bare binary from an IDE/agent.
- Hardware here (2026-10-22): 4 strips `Triones:{0882A400033E,7882A4001DC1,8882A4001AF7,4882A400149D}`,
  2 bars `VC-BLELIGHT` (mfg `58 59 10 02`). All reachable from this Mac.

## Screenshots

`docs/images/*.png` are `screencapture -x -l<CGWindowID>` captures of the app frontmost (keeps the
shadow); `swift scripts/make-hero.swift` recomposes `hero.png` from them.

## Conventions

- Match surrounding style; comments explain *why*. Tests use Swift Testing (`@Test`, `#expect`).
- Persist knowledge in `docs/`, keep this file dense.
- State file: `~/Library/Containers/uk.headpats.lucente/Data/Library/Application Support/Lucente/state.json`.
