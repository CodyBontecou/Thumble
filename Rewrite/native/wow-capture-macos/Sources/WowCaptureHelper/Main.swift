import Darwin
import Foundation
import WowCaptureMac

@main
struct CaptureHelper {
  @MainActor static func main() async {
    let args = Array(CommandLine.arguments.dropFirst())
    do {
      if args.isEmpty || args == ["--status"] {
        try permissionReply("wow-capture-permission-status", CapturePermission.status())
      } else if args == ["--request-permission"] {
        try permissionReply("wow-capture-permission-result", CapturePermission.request())
      } else if args == ["--capture"] {
        let session = CaptureSession()
        while let data = try CaptureFraming.read(from: .standardInput) {
          let request = try CaptureRequest.decode(data)
          let response = await session.perform(request)
          try CaptureFraming.write(try response.encoded(for: request), to: .standardOutput)
        }
      } else {
        throw CaptureProtocolError.invalidRequest
      }
    } catch {
      // Fixed protocol error only. Never print paths, process identity or capture bytes.
      let error = Data(
        #"{"version":1,"command":"wow-capture-protocol-error","status":"unavailable"}"#.utf8)
      try? CaptureFraming.write(error, to: .standardOutput)
      exit(1)
    }
  }
  static func permissionReply(_ command: String, _ status: String) throws {
    let data = try JSONSerialization.data(
      withJSONObject: ["version": 1, "command": command, "status": status], options: [.sortedKeys])
    try CaptureFraming.write(data, to: .standardOutput)
  }
}
