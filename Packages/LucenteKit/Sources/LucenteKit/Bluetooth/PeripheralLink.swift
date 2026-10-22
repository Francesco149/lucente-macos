import CoreBluetooth
import Foundation

enum LinkError: LocalizedError {
    case timedOut
    case missingCharacteristic(String)
    case notWritable(String)
    case gatt(String)

    var errorDescription: String? {
        switch self {
        case .timedOut: "The light didn't finish setting up in time."
        case .missingCharacteristic(let uuid): "The light has no \(uuid) characteristic."
        case .notWritable(let uuid): "Characteristic \(uuid) isn't writable."
        case .gatt(let message): message
        }
    }
}

/// A live connection to one light: finds the driver's characteristics, subscribes to its
/// notifications, and runs a paced, coalescing write queue.
///
/// These controllers take Write Without Response, which has no flow control, so writes go out
/// one at a time with a small gap. Frames that share a `Frame.Slot` replace each other while
/// queued, and a replaced frame moves to the back, so the last thing the user did always wins.
@MainActor
final class PeripheralLink: NSObject {
    static let minimumGap: Duration = .milliseconds(30)
    static let setupTimeout: Duration = .seconds(12)

    let peripheral: CBPeripheral
    let profile: GATTProfile
    var onNotification: (@MainActor ([UInt8]) -> Void)?
    var onWrite: (@MainActor ([UInt8]) -> Void)?

    private(set) var writeType: CBCharacteristicWriteType = .withoutResponse
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var setup: CheckedContinuation<Void, any Error>?
    private var servicesPending = 0
    private var queue: [Frame] = []
    private var draining = false
    private var lastWrite: ContinuousClock.Instant?
    private var acknowledgement: CheckedContinuation<Void, Never>?

    init(peripheral: CBPeripheral, profile: GATTProfile) {
        self.peripheral = peripheral
        self.profile = profile
        super.init()
        peripheral.delegate = self
    }

    var isIdle: Bool { queue.isEmpty && !draining }

    /// Discover the driver's characteristics and enable notifications. Throws if the light
    /// doesn't look like what the driver expects.
    func prepare() async throws {
        try await withCheckedThrowingContinuation { continuation in
            setup = continuation
            peripheral.discoverServices(profile.services.map(CBUUID.init(string:)))
            Task {
                try? await Task.sleep(for: Self.setupTimeout)
                self.finishSetup(.failure(LinkError.timedOut))
            }
        }
    }

    func enqueue(_ frames: [Frame]) {
        for frame in frames {
            if let slot = frame.slot { queue.removeAll { $0.slot == slot } }
            queue.append(frame)
        }
        guard !draining else { return }
        draining = true
        Task {
            await drain()
            draining = false
        }
    }

    private func drain() async {
        while !queue.isEmpty, let characteristic = writeCharacteristic, peripheral.state == .connected {
            if let lastWrite {
                let wait = Self.minimumGap - (ContinuousClock.now - lastWrite)
                if wait > .zero { try? await Task.sleep(for: wait) }
            }
            if writeType == .withoutResponse {
                for _ in 0..<50 where !peripheral.canSendWriteWithoutResponse {
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }
            // Popped only now, after the waits, so a newer frame for the same slot wins.
            guard !queue.isEmpty, peripheral.state == .connected else { break }
            let frame = queue.removeFirst()
            peripheral.writeValue(Data(frame.bytes), for: characteristic, type: writeType)
            lastWrite = .now
            onWrite?(frame.bytes)
            if writeType == .withResponse { await waitForAcknowledgement() }
        }
    }

    private func waitForAcknowledgement() async {
        await withCheckedContinuation { continuation in
            acknowledgement = continuation
            Task {
                try? await Task.sleep(for: .seconds(2))
                self.acknowledge()
            }
        }
    }

    private func acknowledge() {
        acknowledgement?.resume()
        acknowledgement = nil
    }

    private func finishSetup(_ result: Result<Void, any Error>) {
        guard let setup else { return }
        self.setup = nil
        setup.resume(with: result)
    }

    private func characteristicsReady() {
        guard let write = writeCharacteristic else {
            finishSetup(.failure(LinkError.missingCharacteristic(profile.write)))
            return
        }
        // CoreBluetooth silently drops a response-less write to a characteristic that doesn't
        // advertise it, so pick the type from the real properties rather than assuming.
        if write.properties.contains(.writeWithoutResponse) {
            writeType = .withoutResponse
        } else if write.properties.contains(.write) {
            writeType = .withResponse
        } else {
            finishSetup(.failure(LinkError.notWritable(profile.write)))
            return
        }
        if let notify = notifyCharacteristic {
            peripheral.setNotifyValue(true, for: notify) // setup finishes once it's confirmed
        } else {
            finishSetup(.success(()))
        }
    }
}

extension PeripheralLink: @MainActor CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        if let error { return finishSetup(.failure(LinkError.gatt(error.localizedDescription))) }
        let services = peripheral.services ?? []
        guard !services.isEmpty else {
            return finishSetup(.failure(LinkError.missingCharacteristic(profile.write)))
        }
        servicesPending = services.count
        let wanted = [profile.write, profile.notify].compactMap { $0 }.map(CBUUID.init(string:))
        for service in services { peripheral.discoverCharacteristics(wanted, for: service) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == CBUUID(string: profile.write) { writeCharacteristic = characteristic }
            if let notify = profile.notify, characteristic.uuid == CBUUID(string: notify) {
                notifyCharacteristic = characteristic
            }
        }
        servicesPending -= 1
        if servicesPending == 0 { characteristicsReady() }
    }

    func peripheral(
        _ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: (any Error)?
    ) {
        // A refused subscription only costs us read-back; control still works.
        finishSetup(.success(()))
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        guard error == nil, let value = characteristic.value else { return }
        onNotification?([UInt8](value))
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        acknowledge()
    }
}
