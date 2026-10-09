import Darwin
import Foundation

/// Lifetime lease preventing the legacy writable defaults backend and the Rust
/// host from becoming simultaneous configuration authorities.
final class MacLegacyAuthorityLease {
    enum LeaseError: Error {
        case insecureStateDirectory
        case activeRustControlSocket
        case insecureLock
        case authorityHeld
    }

    private let descriptor: Int32
    let stateDirectory: URL

    static func acquire() throws -> MacLegacyAuthorityLease {
        try acquire(stateDirectory: canonicalStateDirectory())
    }

    static func acquire(stateDirectory: URL) throws -> MacLegacyAuthorityLease {
        try secureDirectory(stateDirectory)
        let controlSocket = stateDirectory.appendingPathComponent("control.sock", isDirectory: false)
        if try socketExistsOrIsInsecure(controlSocket) {
            throw LeaseError.activeRustControlSocket
        }

        let lockURL = stateDirectory.appendingPathComponent("runtime.lock", isDirectory: false)
        let descriptor = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw LeaseError.insecureLock }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == geteuid(),
              status.st_mode & 0o077 == 0
        else {
            close(descriptor)
            throw LeaseError.insecureLock
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw LeaseError.authorityHeld
        }
        return MacLegacyAuthorityLease(descriptor: descriptor, stateDirectory: stateDirectory)
    }

    private init(descriptor: Int32, stateDirectory: URL) {
        self.descriptor = descriptor
        self.stateDirectory = stateDirectory
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    private static func canonicalStateDirectory() -> URL {
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let canonical = support.appendingPathComponent("ThumbleHost", isDirectory: true)
        let legacy = support.appendingPathComponent("PocketPadHost", isDirectory: true)
        if !FileManager.default.fileExists(atPath: canonical.path),
           FileManager.default.fileExists(atPath: legacy.path) {
            return legacy
        }
        return canonical
    }

    private static func secureDirectory(_ url: URL) throws {
        var status = stat()
        if lstat(url.path, &status) == 0 {
            guard status.st_mode & S_IFMT == S_IFDIR,
                  status.st_uid == geteuid()
            else { throw LeaseError.insecureStateDirectory }
        } else if errno != ENOENT {
            throw LeaseError.insecureStateDirectory
        }
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard chmod(url.path, 0o700) == 0, lstat(url.path, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == geteuid(),
              status.st_mode & 0o077 == 0
        else { throw LeaseError.insecureStateDirectory }
    }

    private static func socketExistsOrIsInsecure(_ url: URL) throws -> Bool {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            if errno == ENOENT { return false }
            throw LeaseError.activeRustControlSocket
        }
        guard status.st_mode & S_IFMT == S_IFSOCK,
              status.st_uid == geteuid(),
              status.st_mode & 0o077 == 0
        else { throw LeaseError.activeRustControlSocket }
        return true
    }
}
