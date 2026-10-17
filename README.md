# Nelko P21 BLE printing notes

These notes describe the BLE path implemented by a small iOS label-printing app for a Nelko P21. They are implementation observations from one printer, not an official protocol specification.

This is a vibe-coded project created with AI assistance.

## Connection: BLE/GATT on iOS

The iOS implementation uses Apple's CoreBluetooth API:

1. Start a BLE scan without a service filter and match the advertised peripheral name containing `P21`.
2. Connect, then discover all GATT services and characteristics. The implementation does not assume fixed service or characteristic UUIDs.
3. Within each service, look for a writable characteristic (`writeWithoutResponse` preferred, otherwise `write`) and a status characteristic supporting `notify` or `indicate`.
4. Enable notifications, then probe each writable/status pair by writing `CONFIG?\r\n`.
5. Select the pair whose notification begins with `CONFIG `. Send `ESC ! ?\r\n` to query status. If the status is `0`, send `ESC ! o\r\n` to wake the printer, then query status again.

The app sends data in chunks no larger than `maximumWriteValueLength(for:)`. For writes with response it waits for the write callback before sending the next chunk; for writes without response it respects CoreBluetooth's `canSendWriteWithoutResponse` flow control.

The complete `CoreBluetooth` implementation used by the app is in [`P21BluetoothPrinter.swift`](P21BluetoothPrinter.swift). Its channel probe is:

```swift
private func probeConfigChannel() {
    guard probeIndex < candidates.count else {
        fail("Keiner der P21-Druckkanäle hat auf CONFIG? geantwortet.")
        return
    }

    let candidate = candidates[probeIndex]
    writeCharacteristic = candidate.0
    notifyCharacteristic = candidate.1
    writeType = candidate.0.properties.contains(.writeWithoutResponse)
        ? .withoutResponse : .withResponse
    phase = .config

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
```

When the matching notification starts with `CONFIG `, the implementation keeps that write/notify pair, asks for printer status, wakes a paused printer, and submits the label job when ready. See the linked class for the notification handling and MTU-aware write queue.

## Label payload used by the app

For its single-label job, the app sends this command sequence followed by a 3,408-byte, 1-bit raster:

```text
SIZE 15 mm,40 mm
GAP 5.0 mm,0 mm
DIRECTION 0,0
DENSITY 15
CLS
BITMAP 0,18,12,284,1,<3408 raster bytes>
PRINT 1
```

The bitmap and command values are specific to the app's 14 × 40 mm roll layout. They are not claimed to be universal P21 settings.

## macOS RFCOMM attempt

A separate macOS attempt to open RFCOMM channel 1 failed with `-536870212`. That failure was not the path used by the iOS app and does not establish that the printer exposes a usable RFCOMM serial channel. The iOS implementation above uses BLE GATT through CoreBluetooth.

## Limits and troubleshooting

- The `CONFIG?` probe must receive a notification beginning with `CONFIG `; if none of the discovered pairs responds, the app stops rather than guessing a channel.
- A status message that the print job was sent confirms that the Bluetooth writes were handed off. It is not a printer-side confirmation that the label physically printed.
- Printer firmware variations may expose different GATT characteristics or behave differently. Confirm the channel and label dimensions on the specific printer before relying on these values.
- No Bluetooth address, pairing secret, or other device-specific identifier is included here.
