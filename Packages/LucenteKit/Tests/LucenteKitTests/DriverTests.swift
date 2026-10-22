import Foundation
import Testing
@testable import LucenteKit

// Pure protocol tests: identification, byte encoders, notification parsing. No Bluetooth.
// Ported from the Linux app's tests/test_encoders.py, plus macOS-specific advertisement cases
// captured from the real devices (see docs/bars-investigation.md).

private func bytes(_ encoded: Encoded) -> [[UInt8]] { encoded.frames.map(\.bytes) }

@Suite("Identification")
struct IdentificationTests {
    @Test func happyLightingByName() throws {
        let driver = try #require(DriverRegistry.identify(Advertisement(name: "Triones:0882A400033E")))
        #expect(driver is HappyLightingDriver)
        #expect(driver.capabilities.isSuperset(of: [.power, .color, .effect]))
        #expect(driver.defaultName(advertisedName: "Triones:0882A400033E", id: UUID()) == "Strip 033E")
    }

    @Test func raingelByManufacturerData() throws {
        // Exactly what CoreBluetooth reports for the bars: company 0x5958 ("XY"), group 16, type 2.
        let raw: [UInt8] = [0x58, 0x59, 0x10, 0x02]
        let ad = Advertisement(name: "VC-BLELIGHT", serviceUUIDs: ["AF30"], manufacturerData: Advertisement.manufacturerData(fromRaw: raw))
        let driver = try #require(DriverRegistry.identify(ad) as? RaingelDriver)
        #expect(driver.group == 16 && driver.deviceType == 2)
        #expect(driver.capabilities.isSuperset(of: [.power, .brightness, .color, .white, .effect]))
        #expect(driver.config == ["group": 16, "type": 2])
    }

    @Test func raingelByServiceOnly() throws {
        let ad = Advertisement(serviceUUIDs: ["0000af30-0000-1000-8000-00805f9b34fb"])
        #expect(DriverRegistry.identify(ad) is RaingelDriver)
    }

    @Test func raingelCCTOnlyHasNoColor() throws {
        let driver = try #require(RaingelDriver.match(Advertisement(manufacturerData: [0x5958: [0x02, 0x01]])))
        #expect(driver.capabilities.contains(.white))
        #expect(!driver.capabilities.contains(.color))
        #expect(driver.effects.isEmpty)
    }

    @Test func unrelatedDevicesIgnored() {
        #expect(DriverRegistry.identify(Advertisement(name: "Power2000-10046G")) == nil)
        #expect(DriverRegistry.identify(Advertisement(name: "iPhone", manufacturerData: [0x004C: [0x10, 0x05]])) == nil)
    }

    @Test func restoreFromPersistedConfig() throws {
        let driver = try #require(DriverRegistry.restore(id: "raingel", config: ["group": 2, "type": 1]) as? RaingelDriver)
        #expect(driver.group == 2)
        #expect(DriverRegistry.restore(id: "happylighting", config: [:]) is HappyLightingDriver)
        #expect(DriverRegistry.restore(id: "nope", config: [:]) == nil)
    }
}

@Suite("HappyLighting strips")
struct HappyLightingTests {
    let driver = HappyLightingDriver()

    @Test func power() {
        #expect(bytes(driver.encode(.power(true), state: .init())) == [[0xCC, 0x23, 0x33]])
        #expect(bytes(driver.encode(.power(false), state: .init())) == [[0xCC, 0x24, 0x33]])
    }

    @Test func colorAtFullBrightness() {
        let out = driver.encode(.color(RGB(255, 128, 0)), state: LightState(brightness: 100))
        #expect(bytes(out) == [[0x56, 255, 128, 0, 0x00, 0xF0, 0xAA]])
        #expect(out.state.mode == .color && out.state.color == RGB(255, 128, 0))
    }

    @Test func colorScalesByBrightness() {
        let out = driver.encode(.color(RGB(200, 100, 0)), state: LightState(brightness: 50))
        #expect(bytes(out) == [[0x56, 100, 50, 0, 0x00, 0xF0, 0xAA]])
    }

    @Test func brightnessRescalesCurrentColor() {
        let out = driver.encode(.brightness(50), state: LightState(color: RGB(100, 200, 50)))
        #expect(bytes(out) == [[0x56, 50, 100, 25, 0x00, 0xF0, 0xAA]])
        #expect(out.state.brightness == 50)
    }

    @Test func brightnessInWhiteModeScalesWhite() {
        let out = driver.encode(.brightness(50), state: LightState(mode: .white, white: 100))
        #expect(bytes(out) == [[0x56, 0, 0, 0, 128, 0x0F, 0xAA]])
    }

    @Test func brightnessDuringEffectSendsNothing() {
        let out = driver.encode(.brightness(40), state: LightState(mode: .effect, effect: 0x25))
        #expect(out.frames.isEmpty)
        #expect(out.state.brightness == 40)
    }

    @Test func white() {
        let out = driver.encode(.white(100), state: .init())
        #expect(bytes(out) == [[0x56, 0x00, 0x00, 0x00, 255, 0x0F, 0xAA]])
        #expect(out.state.mode == .white)
    }

    @Test func effectSpeedIsInverted() {
        #expect(bytes(driver.encode(.effect(id: 0x25, speed: 100), state: .init())) == [[0xBB, 0x25, 1, 0x44]])
        #expect(bytes(driver.encode(.effect(id: 0x25, speed: 0), state: .init())) == [[0xBB, 0x25, 31, 0x44]])
    }

    @Test func connectQueriesAndAuthenticates() {
        let frames = driver.connectFrames(at: Date()).map(\.bytes)
        #expect(frames.contains([0xEF, 0x01, 0x77]))
        #expect(frames.contains([0xCF, 0x01, 0x02, 0x03, 0x04, 0xFC]))
    }

    @Test func parseStatusColor() throws {
        // 66 type power(on) mode(static) flags speed R G B W ver tail
        let packet: [UInt8] = [0x66, 0x01, 0x23, 0x41, 0x00, 0x10, 0x80, 0x40, 0x00, 0x00, 0x00, 0x00]
        let state = try #require(driver.parse(notification: packet, state: .init()))
        #expect(state.power == true)
        #expect(state.mode == .color)
        #expect(state.color == RGB(255, 128, 0))
        #expect(state.brightness == 50)
    }

    @Test func parseRealCapturedStatus() throws {
        // Captured from Triones:0882A400033E on 2026-10-22: off, static orange at full level.
        let packet: [UInt8] = [0x66, 0x04, 0x24, 0x41, 0x20, 0x01, 0xFF, 0x4B, 0x00, 0x00, 0x03, 0x99]
        let state = try #require(driver.parse(notification: packet, state: .init()))
        #expect(state.power == false)
        #expect(state.color == RGB(255, 75, 0) && state.brightness == 100)
    }

    @Test func parseStatusEffect() throws {
        let packet: [UInt8] = [0x66, 0x01, 0x23, 0x30, 0x00, 0x10, 0, 0, 0, 0, 0, 0]
        let state = try #require(driver.parse(notification: packet, state: .init()))
        #expect(state.mode == .effect && state.effect == 0x30)
        #expect(state.speed == 50)
    }

    @Test func whiteRoundTripsThroughStatus() throws {
        let sent = driver.encode(.white(80), state: LightState(brightness: 50))
        let ww = sent.frames[0].bytes[4]
        let packet: [UInt8] = [0x66, 0x01, 0x23, 0x41, 0x00, 0x10, 0, 0, 0, ww, 0, 0]
        let state = try #require(driver.parse(notification: packet, state: sent.state))
        #expect(state.mode == .white && state.white == 80 && state.brightness == 50)
    }

    @Test func parseRejectsOtherPackets() {
        #expect(driver.parse(notification: [0xA0, 0xF0, 0x00, 0x0A], state: .init()) == nil) // password reply
    }
}

@Suite("Raingel bars")
struct RaingelTests {
    let driver = RaingelDriver(group: 16, deviceType: 2)

    @Test func power() {
        #expect(bytes(driver.encode(.power(true), state: .init())) == [[0x01, 0x01]])
        #expect(bytes(driver.encode(.power(false), state: .init())) == [[0x01, 0x00]])
    }

    @Test func brightness() {
        #expect(bytes(driver.encode(.brightness(73), state: .init())) == [[0x02, 73]])
    }

    @Test func color() {
        #expect(bytes(driver.encode(.color(RGB(10, 20, 30)), state: .init())) == [[0x03, 10, 20, 30, 0, 0, 0]])
    }

    @Test func white() {
        #expect(bytes(driver.encode(.white(60), state: .init())) == [[0x03, 0, 0, 0, 0, 60, 0x01]])
    }

    @Test func effectPreset() {
        let out = driver.encode(.effect(id: 1, speed: nil), state: LightState(brightness: 80))
        #expect(bytes(out) == [[0x07, 0x01, 0x00, 80, 0x08, 0x01, 0x23, 0x45, 0x67]])
        #expect(out.state.mode == .effect)
    }

    @Test func brightnessDuringEffectResendsEffect() {
        let out = driver.encode(.brightness(30), state: LightState(mode: .effect, effect: 5))
        #expect(bytes(out) == [[0x07, 0x05, 0x00, 30, 0x02, 0x67]])
    }

    @Test func clockFrame() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 6, day: 13, hour: 18, minute: 30)))
        #expect(RaingelDriver.clockFrame(date, calendar: calendar).bytes == [0x08, 0x01, 0, 0, 0, 0xEA, 0x07, 6, 13, 18, 30, 0])
    }

    @Test func noKeepalive() {
        #expect(driver.keepaliveFrame(at: Date()) == nil)
    }
}

@Suite("Model")
struct ModelTests {
    @Test func hsvRoundTrip() {
        for rgb in [RGB(255, 0, 0), RGB(0, 255, 128), RGB(30, 60, 255), RGB(255, 255, 255)] {
            let (h, s, v) = rgb.hsv
            #expect(RGB(hue: h, saturation: s, value: v) == rgb)
        }
    }

    @Test func hexParsing() {
        #expect(RGB(hex: "#FF8000") == RGB(255, 128, 0))
        #expect(RGB(hex: "00ff00") == RGB(0, 255, 0))
        #expect(RGB(hex: "nope") == nil)
        #expect(RGB(255, 128, 0).hex == "#FF8000")
    }

    @Test func sceneCommandsPowerThenContentThenLevel() {
        let all = Set(Capability.allCases)
        let on = LightState(power: true, mode: .color, color: RGB(1, 2, 3), brightness: 40)
        #expect(LightScene.commands(for: on, capabilities: all) == [.power(true), .color(RGB(1, 2, 3)), .brightness(40)])
        let off = LightState(power: false, mode: .color, color: RGB(1, 2, 3))
        #expect(LightScene.commands(for: off, capabilities: all) == [.power(false)])
        #expect(LightScene.commands(for: on, capabilities: [.power]) == [.power(true)])
    }
}
