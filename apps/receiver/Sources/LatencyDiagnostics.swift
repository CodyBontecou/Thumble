import Foundation

// Opt-in local QA export. Writes numeric timings/counters off the input queue.
final class LatencyDiagnostics {
    private var counters: [String: Int] = [:]
    func note(_ event: String) { counters[event, default: 0] += 1 }
    private let file: FileHandle
    private let writer = DispatchQueue(label: "tapping.latency.export", qos: .utility)
    init?(path: String?) {
        guard let path, !path.isEmpty else { return nil }
        guard FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let file = FileHandle(forWritingAtPath: path) else { return nil }
        self.file = file
    }
    func append(_ object: [String: Any]) {
        guard let rows = object["rows"] as? [[Any]], rows.count <= 20, rows.allSatisfy({ row in
            guard [6, 12].contains(row.count), ["touch", "heartbeat", "neutral"].contains(row[0] as? String ?? "") else { return false }
            guard row[1..<6].allSatisfy({ value in
                guard let number = value as? Double else { return false }
                return number.isFinite && (-1000...10000).contains(number)
            }) else { return false }
            if row.count == 12 {
                guard ["wss", "udp"].contains(row[11] as? String ?? ""), row[6..<11].allSatisfy({ value in
                    guard let number = value as? Double else { return false }
                    return number.isFinite && (0...9_007_199_254_740_991).contains(number)
                }) else { return false }
            }
            return true
        }) else { return }
        var export: [String: Any] = ["rows": rows, "receiverCounts": counters]
        if let counts = object["counts"] as? [String: Int], Set(counts.keys) == Set(["sent", "acked", "pauses", "superseded"]), counts.values.allSatisfy({ (0...100_000_000).contains($0) }) { export["counts"] = counts }
        guard let data = try? JSONSerialization.data(withJSONObject: export) else { return }
        writer.async { [file] in try? file.write(contentsOf: data + Data([10])) }
    }
}
