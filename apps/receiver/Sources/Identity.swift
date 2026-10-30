import Foundation
import Security
import CryptoKit

struct ReceiverIdentity {
    let identity: SecIdentity
    let fingerprint: String
    static func create() throws -> ReceiverIdentity {
        // Ephemeral process identity: no private key is bundled or retained on disk.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        func openssl(_ arguments: [String]) throws {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            process.currentDirectoryURL = directory; process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw ReceiverError.message("Could not create the local TLS identity.") }
        }
        try openssl(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "key.pem", "-out", "cert.pem", "-days", "365", "-subj", "/CN=Thumble Local Receiver"])
        let password = UUID().uuidString
        try openssl(["pkcs12", "-export", "-inkey", "key.pem", "-in", "cert.pem", "-out", "identity.p12", "-passout", "pass:\(password)", "-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-3DES", "-macalg", "sha1"])
        let data = try Data(contentsOf: directory.appendingPathComponent("identity.p12"))
        var items: CFArray?
        guard #available(macOS 15.0, *) else { throw ReceiverError.message("The receiver currently requires macOS 15 or newer.") }
        guard SecPKCS12Import(data as CFData, [kSecImportExportPassphrase as String: password, kSecImportToMemoryOnly as String: true] as CFDictionary, &items) == errSecSuccess,
              let first = (items as? [[String: Any]])?.first,
              let raw = first[kSecImportItemIdentity as String] else { throw ReceiverError.message("Could not load the local TLS identity.") }
        let identity = raw as! SecIdentity
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else { throw ReceiverError.message("Missing TLS certificate.") }
        let fingerprint = SHA256.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02x", $0) }.joined()
        return ReceiverIdentity(identity: identity, fingerprint: fingerprint)
    }
}
enum ReceiverError: Error { case message(String), virtualGamepadUnavailable }
