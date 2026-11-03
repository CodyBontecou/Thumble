import Foundation
import Security
import CryptoKit

struct ReceiverIdentity {
    let identity: SecIdentity
    let fingerprint: String
    private struct Saved: Codable {
        let version: Int
        let archive: Data
        let password: String
    }
    static func create(secrets: ReceiverSecretStore? = nil) throws -> ReceiverIdentity {
        if let data = try secrets?.load("tls-identity") {
            if let saved = try? JSONDecoder().decode(Saved.self, from: data), saved.version == 1, let identity = try? load(saved) { return identity }
            // A damaged identity is replaced. Phones pinned to the old certificate cannot
            // reconnect, so drop the remembered phone and require a fresh QR pairing.
            try secrets?.remove("remembered-phone")
        }
        // Generate once in an owner-only temporary directory, then retain only in Keychain.
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
        try openssl(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "key.pem", "-out", "cert.pem", "-days", "3650", "-subj", "/CN=Thumble Local Receiver"])
        let password = UUID().uuidString
        try openssl(["pkcs12", "-export", "-inkey", "key.pem", "-in", "cert.pem", "-out", "identity.p12", "-passout", "pass:\(password)", "-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-3DES", "-macalg", "sha1"])
        let data = try Data(contentsOf: directory.appendingPathComponent("identity.p12"))
        let saved = Saved(version: 1, archive: data, password: password)
        let identity = try load(saved)
        try secrets?.save(JSONEncoder().encode(saved), account: "tls-identity")
        return identity
    }
    private static func load(_ saved: Saved) throws -> ReceiverIdentity {
        var items: CFArray?
        guard #available(macOS 15.0, *) else { throw ReceiverError.message("The receiver currently requires macOS 15 or newer.") }
        guard SecPKCS12Import(saved.archive as CFData, [kSecImportExportPassphrase as String: saved.password, kSecImportToMemoryOnly as String: true] as CFDictionary, &items) == errSecSuccess,
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
