import CoreBluetooth
import Foundation

/// The radio's availability, as the UI needs to explain it.
public enum BluetoothAvailability: Sendable, Equatable {
    case unknown, ready, poweredOff, unauthorized, unsupported, resetting
}

/// The app's single `CBCentralManager`. Its delegate queue is the main queue, so the whole
/// Bluetooth layer lives on the main actor — the traffic here is a handful of tiny writes, and it
/// keeps CoreBluetooth objects out of cross-thread territory entirely.
@MainActor
final class BluetoothCentral: NSObject {
    private(set) var availability: BluetoothAvailability = .unknown

    var onAvailabilityChange: (@MainActor (BluetoothAvailability) -> Void)?
    var onDiscover: (@MainActor (CBPeripheral, Advertisement) -> Void)?
    var onConnect: (@MainActor (CBPeripheral) -> Void)?
    var onDisconnect: (@MainActor (CBPeripheral, (any Error)?) -> Void)?

    private var manager: CBCentralManager?
    private var wantsScan = false

    /// Creating the manager is what triggers the Bluetooth permission prompt, so it's deferred
    /// until the store starts rather than happening at init.
    func activate() {
        guard manager == nil else { return }
        manager = CBCentralManager(delegate: self, queue: .main)
    }

    func setScanning(_ on: Bool) {
        wantsScan = on
        applyScanning()
    }

    var isScanning: Bool { manager?.isScanning ?? false }

    func retrievePeripheral(_ id: UUID) -> CBPeripheral? {
        guard availability == .ready else { return nil }
        return manager?.retrievePeripherals(withIdentifiers: [id]).first
    }

    /// CoreBluetooth connects never time out: the request stays pending until the device next
    /// advertises, which is exactly what "stay connected" wants.
    func connect(_ peripheral: CBPeripheral) {
        manager?.connect(peripheral)
    }

    func cancel(_ peripheral: CBPeripheral) {
        manager?.cancelPeripheralConnection(peripheral)
    }

    private func applyScanning() {
        guard let manager, manager.state == .poweredOn else { return }
        if wantsScan, !manager.isScanning {
            // Duplicates on: every advert refreshes "last seen", which is how reachability works
            // (these devices stop advertising once connected, and start again when free).
            manager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        } else if !wantsScan, manager.isScanning {
            manager.stopScan()
        }
    }
}

extension BluetoothCentral: @MainActor CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        availability = switch central.state {
        case .poweredOn: .ready
        case .poweredOff: .poweredOff
        case .unauthorized: .unauthorized
        case .unsupported: .unsupported
        case .resetting: .resetting
        default: .unknown
        }
        applyScanning()
        onAvailabilityChange?(availability)
    }

    func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi: NSNumber
    ) {
        onDiscover?(peripheral, Advertisement(advertisementData, peripheral: peripheral, rssi: rssi))
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        onConnect?(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?) {
        onDisconnect?(peripheral, error)
    }

    func centralManager(
        _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?
    ) {
        onDisconnect?(peripheral, error)
    }
}

extension Advertisement {
    init(_ data: [String: Any], peripheral: CBPeripheral, rssi: NSNumber) {
        let raw = (data[CBAdvertisementDataManufacturerDataKey] as? Data).map { [UInt8]($0) } ?? []
        let services = (data[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        self.init(
            name: data[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name,
            serviceUUIDs: services.map(\.uuidString),
            manufacturerData: Advertisement.manufacturerData(fromRaw: raw),
            rssi: rssi.intValue == 127 ? nil : rssi.intValue // 127 = "not available"
        )
    }
}
