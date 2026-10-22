import CoreBluetooth
import Foundation
import IOBluetooth
import LucenteKit

// lucente-probe — a raw Bluetooth workbench for reverse-engineering and diagnosing lights.
// Run it through `scripts/probe` (or `make probe ARGS=…`), which wraps it in an app bundle so
// macOS grants it Bluetooth access regardless of which terminal or editor launched it.

let usage = """
usage: lucente-probe <command> [options]

  scan [--seconds N] [--all]          list lights (or --all BLE devices) as they advertise
  inspect <id> [--observe N]          connect; dump services, characteristics, properties and
                                      descriptors; subscribe to every notify; print traffic
  write <id> <char> <hex>... [--with-response] [--observe N]
                                      connect and write each hex payload to <char>, 1.2 s apart
  classic [--seconds N]               BR/EDR inquiry — finds dual-mode devices (e.g. the bars)

<id> is a CoreBluetooth identifier as printed by `scan`; any unique prefix works.
"""

let started = Date()

func say(_ line: String) {
    print(String(format: "[%7.2f] ", Date().timeIntervalSince(started)) + line)
    fflush(stdout)
}

func hex(_ bytes: some Sequence<UInt8>) -> String { bytes.map { String(format: "%02x", $0) }.joined(separator: " ") }

func parseHex(_ s: String) -> [UInt8]? {
    let digits = s.filter { !$0.isWhitespace && $0 != ":" && $0 != "-" }
    guard digits.count.isMultiple(of: 2) else { return nil }
    var out: [UInt8] = []
    var i = digits.startIndex
    while i < digits.endIndex {
        let j = digits.index(i, offsetBy: 2)
        guard let b = UInt8(digits[i..<j], radix: 16) else { return nil }
        out.append(b)
        i = j
    }
    return out
}

func describe(_ p: CBCharacteristicProperties) -> String {
    let names: [(CBCharacteristicProperties, String)] = [
        (.broadcast, "broadcast"), (.read, "read"), (.writeWithoutResponse, "write-without-response"),
        (.write, "write"), (.notify, "notify"), (.indicate, "indicate"),
        (.authenticatedSignedWrites, "signed-write"), (.extendedProperties, "extended"),
    ]
    return names.filter { p.contains($0.0) }.map(\.1).joined(separator: ",")
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

struct Options {
    var command = ""
    var positional: [String] = []
    var seconds: Double = 15
    var observe: Double = 6
    var all = false
    var withResponse = false

    init(_ args: [String]) {
        var it = args.makeIterator()
        while let a = it.next() {
            switch a {
            case "--seconds": seconds = Double(it.next() ?? "") ?? seconds
            case "--observe": observe = Double(it.next() ?? "") ?? observe
            case "--all": all = true
            case "--with-response": withResponse = true
            case "-h", "--help": print(usage); exit(0)
            default: if command.isEmpty { command = a } else { positional.append(a) }
            }
        }
    }
}

@MainActor
final class Probe: NSObject {
    let options: Options
    var central: CBCentralManager!
    var target: CBPeripheral?
    var seen: Set<UUID> = []
    var characteristics: [CBUUID: CBCharacteristic] = [:]
    var servicesPending = 0

    init(_ options: Options) {
        self.options = options
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    var targetPrefix: String? { options.positional.first?.uppercased() }

    func finish(after seconds: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            if let target = self.target { self.central.cancelPeripheralConnection(target) }
            say("done")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
        }
    }

    func runWrites(on peripheral: CBPeripheral) {
        guard options.command == "write" else { return finish(after: options.observe) }
        guard options.positional.count >= 3 else { fail(usage) }
        let uuid = CBUUID(string: options.positional[1])
        guard let characteristic = characteristics[uuid] else { fail("no characteristic \(uuid)") }
        let payloads = options.positional.dropFirst(2).map { text -> [UInt8] in
            guard let payload = parseHex(text) else { fail("bad hex: \(text)") }
            return payload
        }
        let type: CBCharacteristicWriteType = options.withResponse ? .withResponse : .withoutResponse
        for (n, payload) in payloads.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2 * Double(n)) {
                say("write \(hex(payload)) → \(uuid) (\(type == .withResponse ? "with" : "without") response)")
                peripheral.writeValue(Data(payload), for: characteristic, type: type)
            }
        }
        finish(after: 1.2 * Double(payloads.count) + options.observe)
    }
}

extension Probe: @MainActor CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            if central.state == .unauthorized { fail("Bluetooth permission denied (System Settings › Privacy & Security › Bluetooth)") }
            if central.state == .poweredOff { fail("Bluetooth is off") }
            return
        }
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        if options.command == "scan" {
            say("scanning \(Int(options.seconds)) s for \(options.all ? "all devices" : "lights")…")
            finish(after: options.seconds)
        } else {
            say("looking for \(targetPrefix ?? "?")…")
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { if self.target == nil { fail("not seen in 30 s") } }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral, advertisementData data: [String: Any], rssi: NSNumber) {
        if options.command == "scan" {
            guard seen.insert(p.identifier).inserted else { return }
            let name = data[CBAdvertisementDataLocalNameKey] as? String ?? p.name
            let raw = (data[CBAdvertisementDataManufacturerDataKey] as? Data).map { [UInt8]($0) } ?? []
            let services = (data[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []).map(\.uuidString)
            let ad = Advertisement(name: name, serviceUUIDs: services, manufacturerData: Advertisement.manufacturerData(fromRaw: raw))
            let driver = DriverRegistry.identify(ad)
            guard driver != nil || options.all else { return }
            var line = "\(p.identifier)  \(String(format: "%4d", rssi.intValue)) dBm  \(name ?? "(no name)")"
            if let driver { line += "  [\(driver.vendor) \(driver.kind.title.lowercased())]" }
            if !raw.isEmpty { line += "\n        mfg: \(hex(raw))" }
            if !services.isEmpty { line += "\n        services: \(services.joined(separator: ", "))" }
            say(line)
        } else if target == nil, let prefix = targetPrefix, p.identifier.uuidString.hasPrefix(prefix) {
            target = p
            p.delegate = self
            central.stopScan()
            say("found \(p.name ?? "?") (\(p.identifier)) at \(rssi) dBm — connecting")
            central.connect(p)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        say("connected; max write \(p.maximumWriteValueLength(for: .withoutResponse)) B without response, \(p.maximumWriteValueLength(for: .withResponse)) B with")
        p.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: (any Error)?) {
        fail("connect failed: \(error?.localizedDescription ?? "unknown")")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: (any Error)?) {
        say("disconnected\(error.map { ": \($0.localizedDescription)" } ?? "")")
    }
}

extension Probe: @MainActor CBPeripheralDelegate {
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: (any Error)?) {
        let services = p.services ?? []
        servicesPending = services.count
        for s in services { p.discoverCharacteristics(nil, for: s) }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: (any Error)?) {
        say("service \(s.uuid)\(s.isPrimary ? "" : " (secondary)")")
        for c in s.characteristics ?? [] {
            say("    characteristic \(c.uuid)  [\(describe(c.properties))]")
            if characteristics[c.uuid] != nil { say("    ⚠︎ duplicate characteristic UUID \(c.uuid)") }
            characteristics[c.uuid] = c
            if c.properties.contains(.notify) || c.properties.contains(.indicate) { p.setNotifyValue(true, for: c) }
            if c.properties.contains(.read) { p.readValue(for: c) }
        }
        servicesPending -= 1
        if servicesPending == 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.runWrites(on: p) }
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: (any Error)?) {
        say("subscribe \(c.uuid): \(error?.localizedDescription ?? "ok")")
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: (any Error)?) {
        say("← \(c.uuid): \(c.value.map(hex) ?? "-")\(error.map { " (\($0.localizedDescription))" } ?? "")")
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: (any Error)?) {
        say("ack \(c.uuid): \(error?.localizedDescription ?? "ok")")
    }
}

@MainActor
final class ClassicInquiry: NSObject, @MainActor IOBluetoothDeviceInquiryDelegate {
    var inquiry: IOBluetoothDeviceInquiry?

    func start(seconds: Double) {
        let inquiry = IOBluetoothDeviceInquiry(delegate: self)
        inquiry?.inquiryLength = UInt8(min(max(seconds, 1), 30))
        inquiry?.updateNewDeviceNames = true
        self.inquiry = inquiry
        say("BR/EDR inquiry for \(Int(seconds)) s — dual-mode lights answer here as well as over LE")
        guard inquiry?.start() == kIOReturnSuccess else { fail("inquiry failed to start") }
    }

    func deviceInquiryDeviceFound(_ sender: IOBluetoothDeviceInquiry!, device: IOBluetoothDevice!) {
        say("\(device.addressString ?? "?")  \(device.name ?? "(no name)")  class \(String(format: "%06x", device.classOfDevice))")
    }

    func deviceInquiryComplete(_ sender: IOBluetoothDeviceInquiry!, error: IOReturn, aborted: Bool) {
        say("inquiry complete")
        exit(0)
    }
}

let options = Options(Array(CommandLine.arguments.dropFirst()))
var keepAlive: AnyObject?
switch options.command {
case "scan", "inspect", "write":
    if options.command != "scan", options.positional.isEmpty { fail(usage) }
    keepAlive = Probe(options)
case "classic":
    let inquiry = ClassicInquiry()
    inquiry.start(seconds: options.seconds)
    keepAlive = inquiry
default:
    fail(usage)
}
RunLoop.main.run()
