import Foundation
struct IsolatedReceiverSecrets: ReceiverSecretStore {
    let directory: URL
    init() {
        directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TAPPING_PROFILE_DIR"]!).appendingPathComponent("test-secrets")
    }
    func load(_ account: String) throws -> Data? {
        let path = directory.appendingPathComponent(account)
        return FileManager.default.fileExists(atPath: path.path) ? try Data(contentsOf: path) : nil
    }
    func save(_ data: Data, account: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent(account)
        try data.write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
    func remove(_ account: String) throws {
        let path = directory.appendingPathComponent(account)
        if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
    }
}
let receiver = Receiver(secrets: IsolatedReceiverSecrets())
receiver.onInvitation = { value in
    if !value.isEmpty, let path = ProcessInfo.processInfo.environment["TAPPING_TEST_INVITATION"] { try? Data(value.utf8).write(to: URL(fileURLWithPath: path), options: [.atomic]) }
}
try receiver.start()
RunLoop.main.run()
