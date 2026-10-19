// Read-only native IPC probe for the isolated Android interoperability fixture.
// stdout is consumed privately by verify-mac.py; it contains ephemeral pairing data.
import Foundation

struct ProbeFailure: Error { let message: String }

guard CommandLine.arguments.count == 2,
      let defaults = UserDefaults(suiteName: CommandLine.arguments[1]) else {
    throw ProbeFailure(message: "Expected an isolated native helper defaults domain")
}
let requestID = UUID().uuidString
let payload = try JSONSerialization.data(withJSONObject: ["command": "publishStatus", "requestID": requestID])
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("com.codybontecou.PocketPadMac.cliCommand"),
    object: nil,
    userInfo: ["commandData": payload],
    deliverImmediately: true
)
let deadline = Date().addingTimeInterval(3)
while Date() < deadline {
    defaults.synchronize()
    if let data = defaults.data(forKey: "PocketPadMac.runtimeStatus.v1"),
       let status = try JSONSerialization.jsonObject(with: data) as? [String: Any],
       status["runtimeStatusRequestID"] as? String == requestID {
        try FileHandle.standardOutput.write(contentsOf: data)
        exit(0)
    }
    Thread.sleep(forTimeInterval: 0.025)
}
throw ProbeFailure(message: "Native helper did not publish fresh correlated status")
