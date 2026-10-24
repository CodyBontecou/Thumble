import Foundation
import Vision

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
setenv("TAPPING_PROFILE_DIR", directory.path, 1)
let invitation = "thumble://pair?data=" + Data(String(repeating: "synthetic-test-payload-", count: 20).utf8).base64EncodedString()
let png = try PairingCode.png(invitation)
let request = VNDetectBarcodesRequest()
request.symbologies = [.qr]
try VNImageRequestHandler(data: png).perform([request])
precondition(request.results?.first?.payloadStringValue == invitation, "QR did not decode exactly")

let bridge = ProfileBridge()
let path = directory.appendingPathComponent("pairing-code.json")
func waitFor(_ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(5)
    while !condition() && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
    precondition(condition(), "Bridge did not publish/clear pairing image")
}
bridge.start()
bridge.updatePairingCode(invitation, expires: Date().timeIntervalSince1970 + 120)
waitFor { FileManager.default.fileExists(atPath: path.path) }
let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
precondition((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
let payload = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
precondition(payload["png"] as? String == png.base64EncodedString())
precondition(payload["version"] as? Int == 1)
let updated = payload["updatedAt"] as! Int
waitFor {
    guard let data = try? Data(contentsOf: path), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
    return (value["updatedAt"] as? Int ?? 0) > updated
}
bridge.updatePairingCode("")
waitFor { !FileManager.default.fileExists(atPath: path.path) }
bridge.updatePairingCode(invitation, expires: Date().timeIntervalSince1970 + 1)
waitFor { FileManager.default.fileExists(atPath: path.path) }
waitFor { !FileManager.default.fileExists(atPath: path.path) }
bridge.updatePairingCode(invitation, expires: Date().timeIntervalSince1970 + 120)
waitFor { FileManager.default.fileExists(atPath: path.path) }
bridge.stop()
precondition(!FileManager.default.fileExists(atPath: path.path))
print("Pairing QR decodes exactly; private bridge refresh, clear, expiry and stop passed.")
