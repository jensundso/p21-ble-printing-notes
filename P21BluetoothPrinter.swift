import Foundation
import CoreBluetooth
import Combine

final class P21BluetoothPrinter: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published private(set) var isBusy = false
    @Published private(set) var status = ""

    private enum Phase { case config, ready, unpause, readyAfterUnpause, printing }
    private lazy var central = CBCentralManager(delegate: self, queue: .main)
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var phase: Phase?
    private var job = Data()
    private var pending = Data()
    private var offset = 0
    private var waitingForWriteResponse = false
    private var writeType: CBCharacteristicWriteType = .withoutResponse
    private var scanTimeout: DispatchWorkItem?
    private var operationTimeout: DispatchWorkItem?
    private var candidates: [(CBCharacteristic, CBCharacteristic, Int)] = []
    private var notificationCharacteristics: [CBCharacteristic] = []
    private var serviceCount = 0
    private var inspectedServiceCount = 0
    private var pendingNotificationCount = 0
    private var probeIndex = 0
    private var probeTimeout: DispatchWorkItem?

    func printLabel(_ bitmap: Data) {
        guard !isBusy else { return }
        guard bitmap.count == 3408 else {
            status = "Etikettbild hat eine unerwartete Größe (\(bitmap.count) statt 3408 Bytes)."
            return
        }
        var job = Data("SIZE 15 mm,40 mm\r\nGAP 5.0 mm,0 mm\r\nDIRECTION 0,0\r\nDENSITY 15\r\nCLS\r\nBITMAP 0,18,12,284,1,".utf8)
        job.append(bitmap)
        job.append(Data("\r\nPRINT 1\r\n".utf8))
        self.job = job
        isBusy = true
        _ = central
        switch central.state {
        case .poweredOn:
            connectOrScan()
        case .unknown, .resetting:
            status = "Bluetooth wird gestartet …"
        case .poweredOff:
            fail("Bluetooth am iPhone einschalten.")
        case .unauthorized:
            fail("Bluetooth-Zugriff für P21 Filamentetiketten in den iPhone-Einstellungen erlauben.")
        case .unsupported:
            fail("Dieses iPhone unterstützt keine Bluetooth-Verbindung zum P21.")
        @unknown default:
            fail("Bluetooth-Status konnte nicht ermittelt werden.")
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard isBusy else { return }
        if central.state == .poweredOn { connectOrScan() }
        else if central.state == .poweredOff { fail("Bluetooth am iPhone einschalten.") }
        else if central.state == .unauthorized { fail("Bluetooth-Zugriff für P21 Filamentetiketten in den iPhone-Einstellungen erlauben.") }
    }

    private func connectOrScan() {
        guard peripheral == nil else { return }
        status = "Suche den P21 …"
        central.scanForPeripherals(withServices: nil)
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.isBusy, self.peripheral == nil else { return }
            self.central.stopScan()
            self.fail("Kein P21 gefunden. Drucker einschalten und erneut drucken.")
        }
        scanTimeout?.cancel()
        scanTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? ""
        guard name.localizedCaseInsensitiveContains("p21") else { return }
        scanTimeout?.cancel()
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        status = "P21 gefunden – verbinde …"
        startTimeout("P21-Verbindung oder Dienstsuche hat zu lange gedauert.")
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        operationTimeout?.cancel()
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: "p21.bluetoothPeripheral")
        status = "P21 verbunden – suche Druckdienst …"
        startTimeout("P21-Dienste konnten nicht rechtzeitig gefunden werden.")
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        fail("P21-Verbindung fehlgeschlagen: \(error?.localizedDescription ?? "unbekannter Fehler")")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard isBusy else { return }
        fail("P21-Verbindung wurde getrennt: \(error?.localizedDescription ?? "kein Grund gemeldet")")
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { fail("P21-Dienste konnten nicht gelesen werden: \(error.localizedDescription)"); return }
        let services = peripheral.services ?? []
        guard !services.isEmpty else { fail("P21 meldet keine Bluetooth-Dienste."); return }
        serviceCount = services.count
        inspectedServiceCount = 0
        for service in services { peripheral.discoverCharacteristics(nil, for: service) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error { fail("P21-Druckmerkmale konnten nicht gelesen werden: \(error.localizedDescription)"); return }
        let characteristics = service.characteristics ?? []
        let writable = characteristics.filter { $0.properties.contains(.writeWithoutResponse) || $0.properties.contains(.write) }
        let notifiable = characteristics.filter { $0.properties.contains(.notify) || $0.properties.contains(.indicate) }
        notificationCharacteristics.append(contentsOf: notifiable)
        if let write = writable.first(where: { $0.properties.contains(.writeWithoutResponse) }) ?? writable.first,
           let notify = notifiable.first {
            let score = write.properties.contains(.writeWithoutResponse) ? 2 : 1
            candidates.append((write, notify, score))
        }
        inspectedServiceCount += 1
        guard inspectedServiceCount == serviceCount else { return }
        guard !candidates.isEmpty, !notificationCharacteristics.isEmpty else {
            fail("P21-Druckdienst mit Schreib- und Statuskanal wurde nicht gefunden.")
            return
        }
        candidates.sort { $0.2 > $1.2 }
        notificationCharacteristics = Array(Set(notificationCharacteristics))
        pendingNotificationCount = notificationCharacteristics.count
        status = "Aktiviere P21-Statuskanäle (\(pendingNotificationCount)) …"
        for characteristic in notificationCharacteristics {
            peripheral.setNotifyValue(true, for: characteristic)
        }
        startTimeout("P21-Statuskanäle konnten nicht aktiviert werden.")
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if pendingNotificationCount > 0 { pendingNotificationCount -= 1 }
        guard pendingNotificationCount == 0 else { return }
        let activeNotifications = notificationCharacteristics.filter(\.isNotifying)
        candidates.removeAll { !activeNotifications.contains($0.1) }
        guard !candidates.isEmpty else {
            fail("P21 hat keinen Statuskanal aktiviert. Prüfe Bluetooth und verbundene Geräte.")
            return
        }
        probeIndex = 0
        probeConfigChannel()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { fail("P21-Status konnte nicht gelesen werden: \(error.localizedDescription)"); return }
        guard let value = characteristic.value else { return }
        if phase == .config, value.starts(with: Data("CONFIG ".utf8)) {
            probeTimeout?.cancel()
            notifyCharacteristic = characteristic
            if let channel = candidates.first(where: { $0.1 == characteristic }) {
                writeCharacteristic = channel.0
                writeType = channel.0.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
            } else {
                fail("P21-Konfigurationsantwort kam über einen unbekannten Statuskanal.")
                return
            }
            phase = .ready
            status = "P21 antwortet – prüfe Druckerstatus …"
            send(Data("\u{1b}!?\r\n".utf8))
            startTimeout("P21 hat den Bereitschaftsstatus nicht gemeldet.")
            return
        }
        guard characteristic == notifyCharacteristic else { return }
        guard let currentPhase = phase else { return }
        switch currentPhase {
        case .ready where value == Data([0]):
            phase = .unpause
            send(Data("\u{1b}!o\r\n".utf8))
            startTimeout("P21 konnte nicht aus dem Pausemodus geweckt werden.")
        case .unpause where !value.isEmpty:
            phase = .readyAfterUnpause
            send(Data("\u{1b}!?\r\n".utf8))
            startTimeout("P21 hat nach dem Aufwecken nicht geantwortet.")
        case .readyAfterUnpause where value == Data([0]):
            phase = .printing
            status = "Etikett wird übertragen …"
            send(job, isPrintJob: true)
            startTimeout("Druckdaten konnten nicht vollständig übertragen werden.")
        default:
            break
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { fail("P21 hat einen Schreibvorgang abgelehnt: \(error.localizedDescription)"); return }
        waitingForWriteResponse = false
        if offset == pending.count { completePendingWrite() } else { pumpWrites() }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        pumpWrites()
    }

    private var finishingPrint = false
    private func send(_ data: Data, isPrintJob: Bool = false) {
        guard pending.isEmpty, offset == 0 else { fail("Interner Druckdatenfehler: Schreibwarteschlange ist belegt."); return }
        pending = data
        offset = 0
        finishingPrint = isPrintJob
        pumpWrites()
    }

    private func pumpWrites() {
        guard let peripheral, let characteristic = writeCharacteristic, !pending.isEmpty else { return }
        let maxLength = peripheral.maximumWriteValueLength(for: writeType)
        guard maxLength > 0 else { fail("P21 erlaubt keine Bluetooth-Schreibdaten."); return }
        if writeType == .withResponse {
            guard !waitingForWriteResponse else { return }
            let end = min(offset + maxLength, pending.count)
            peripheral.writeValue(pending.subdata(in: offset..<end), for: characteristic, type: .withResponse)
            offset = end
            waitingForWriteResponse = true
            return
        }
        while offset < pending.count && peripheral.canSendWriteWithoutResponse {
            let end = min(offset + maxLength, pending.count)
            peripheral.writeValue(pending.subdata(in: offset..<end), for: characteristic, type: .withoutResponse)
            offset = end
        }
        guard offset == pending.count else { return }
        completePendingWrite()
    }

    private func completePendingWrite() {
        let wasPrint = finishingPrint
        pending.removeAll(keepingCapacity: true)
        offset = 0
        finishingPrint = false
        if wasPrint {
            operationTimeout?.cancel()
            operationTimeout = nil
            phase = nil
            job.removeAll()
            isBusy = false
            status = "Druckauftrag für ein Etikett gesendet."
        }
    }

    private func startTimeout(_ message: String) {
        operationTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.isBusy else { return }
            self.fail(message)
        }
        operationTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)
    }

    private func probeConfigChannel() {
        guard probeIndex < candidates.count else {
            fail("Keiner der \(candidates.count) P21-Druckkanäle hat auf CONFIG? geantwortet.")
            return
        }
        let candidate = candidates[probeIndex]
        writeCharacteristic = candidate.0
        notifyCharacteristic = candidate.1
        writeType = candidate.0.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        phase = .config
        status = "Prüfe P21-Druckkanal \(probeIndex + 1) von \(candidates.count) …"
        send(Data("CONFIG?\r\n".utf8))
        probeTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.isBusy, self.phase == .config else { return }
            self.probeIndex += 1
            self.probeConfigChannel()
        }
        probeTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: timeout)
    }

    private func fail(_ message: String) {
        scanTimeout?.cancel()
        operationTimeout?.cancel()
        central.stopScan()
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        self.peripheral = nil
        writeCharacteristic = nil
        notifyCharacteristic = nil
        candidates.removeAll()
        notificationCharacteristics.removeAll()
        probeTimeout?.cancel()
        probeTimeout = nil
        phase = nil
        pending.removeAll()
        job.removeAll()
        offset = 0
        waitingForWriteResponse = false
        finishingPrint = false
        isBusy = false
        status = message
    }
}
