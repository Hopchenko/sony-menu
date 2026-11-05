import Foundation
import IOBluetooth

// Inspect only the connected Sony headset; send no setting changes.
guard let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice],
      let device = devices.first(where: { $0.name == "WH-1000XM3" && $0.isConnected() }) else {
    print("Connected WH-1000XM3 not accessible to this process.")
    exit(1)
}
func describeServices(_ device: IOBluetoothDevice) {
    let records = device.services as? [IOBluetoothSDPServiceRecord] ?? []
    print("Service records: \(records.count)")
    for record in records {
        var channel: BluetoothRFCOMMChannelID = 0
        let status = record.getRFCOMMChannelID(&channel)
        print("Service: \(record.getServiceName() ?? "unnamed") | RFCOMM: \(status == 0 ? String(channel) : "none")")
        print(record.attributes ?? [:])
    }
}
final class SDPObserver: NSObject {
    var complete = false
    @objc func sdpQueryComplete(_ device: IOBluetoothDevice, status: IOReturn) {
        print("SDP result: \(status)")
        describeServices(device)
        complete = true
    }
}
print("Connected: \(device.name ?? "Sony headset")")
let observer = SDPObserver()
let status = device.performSDPQuery(observer)
print("SDP query started: \(status)")
let deadline = Date().addingTimeInterval(15)
while !observer.complete && Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
}
if !observer.complete {
    print("No SDP callback; inspecting cached records.")
    describeServices(device)
}
