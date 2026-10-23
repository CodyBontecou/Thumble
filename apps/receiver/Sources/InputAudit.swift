import Foundation

// Opt-in QA report trace, not enabled in normal use. No credentials or network identifiers.
final class InputAudit {
    private let file: FileHandle
    private let writer = DispatchQueue(label: "tapping.input.audit", qos: .utility)
    init?(path: String?) {
        guard let path, FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let file = FileHandle(forWritingAtPath: path) else { return nil }
        self.file = file
    }
    func record(_ report: [UInt8], result: Int32) {
        let row = ["at": ProcessInfo.processInfo.systemUptime * 1000, "result": Double(result), "report": report] as [String: Any]
        guard let data = try? JSONSerialization.data(withJSONObject: row) else { return }
        writer.async { [file] in try? file.write(contentsOf: data + Data([10])) }
    }
}
