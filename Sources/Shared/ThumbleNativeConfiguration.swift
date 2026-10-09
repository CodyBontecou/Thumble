#if os(macOS)
import CryptoKit
import Darwin
import Foundation

/// Credential-free native configuration IPC. The editor retains runtime.lock;
/// clients compare-and-swap against a snapshot instead of writing its defaults.
enum ThumbleNativeConfiguration {
    static let socketName = "native-configuration.sock"
    static let maximumFrameBytes = 18 * 1024 * 1024
    static let maximumReplayBytes = 256 * 1024

    struct Request: Codable {
        var schemaVersion = 1
        var requestID: UUID
        var action: String
        var instanceID: UUID?
        var expectedRevision: UInt64?
        var expectedContentHash: String?
        var invocationID: UUID
        var requestDigest: String
        var document: ThumbleBridgeConfigurationDocument?
        var replayResponse: ThumbleBridgeJSONValue?
    }

    struct Failure: Codable { var code: String; var message: String }
    struct Response: Codable {
        var schemaVersion = 1
        var requestID: UUID
        var instanceID: UUID
        var configurationRevision: UInt64
        var contentHash: String
        var document: ThumbleBridgeConfigurationDocument?
        var replayResponse: ThumbleBridgeJSONValue?
        var error: Failure?
    }

    struct Snapshot {
        let instanceID: UUID
        let revision: UInt64
        let contentHash: String
        let document: ThumbleBridgeConfigurationDocument
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func stateDirectory() -> URL {
        let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        let canonical = support.appendingPathComponent("ThumbleHost", isDirectory: true)
        let previous = support.appendingPathComponent("PocketPadHost", isDirectory: true)
        return !FileManager.default.fileExists(atPath: canonical.path) && FileManager.default.fileExists(atPath: previous.path) ? previous : canonical
    }

    static func socketDirectory(for directory: URL) -> URL {
        // NSURL may collapse /private/tmp back to /tmp after resolving links;
        // POSIX realpath matches Rust's filesystem canonicalization exactly.
        let resolved = realpath(directory.path, nil)
        let canonical = resolved.map { String(cString: $0) } ?? directory.path
        if let resolved { free(resolved) }
        let key = digest(Data(canonical.utf8)).prefix(32)
        return URL(fileURLWithPath: "/tmp/tnc-\(geteuid())-\(key)", isDirectory: true)
    }

    static func endpointExists(in directory: URL = stateDirectory()) -> Bool {
        var status = stat()
        if lstat(directory.appendingPathComponent("control.sock").path, &status) == 0 { return false }
        guard lstat(socketDirectory(for: directory).appendingPathComponent(socketName).path, &status) == 0 else { return false }
        let fd = open(directory.appendingPathComponent("runtime.lock").path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return true }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { _ = flock(fd, LOCK_UN); return false }
        return true
    }

    /// A present but insecure/stale endpoint is an error, never offline fallback.
    static func exchange(_ request: Request, directory: URL = stateDirectory()) throws -> Response {
        try validateDirectory(directory)
        let socketDirectory = socketDirectory(for: directory)
        try validateDirectory(socketDirectory)
        let path = socketDirectory.appendingPathComponent(socketName).path
        var status = stat()
        guard lstat(path, &status) == 0, status.st_mode & S_IFMT == S_IFSOCK,
              status.st_uid == geteuid(), status.st_mode & 0o077 == 0 else { throw TransportError.insecureEndpoint }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TransportError.unavailable }
        defer { close(fd) }
        try configure(fd)
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw TransportError.unavailable }
        var address = try address(for: path)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if result != 0 {
            guard errno == EINPROGRESS || errno == EINTR || errno == EAGAIN else { throw TransportError.unavailable }
            try waitReady(fd, events: Int16(POLLOUT), deadline: .now() + 10)
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0,
                  length == MemoryLayout<Int32>.size, error == 0 else { throw TransportError.unavailable }
        }
        try validatePeer(fd)
        var input = try encoder().encode(request)
        guard input.count + 1 <= maximumFrameBytes else { throw TransportError.frameTooLarge }
        input.append(0x0A)
        try write(input, to: fd)
        guard shutdown(fd, SHUT_WR) == 0 else { throw TransportError.unavailable }
        let output = try read(from: fd)
        try JSONDecoder.validateUniqueKeys(in: output)
        guard let fields = try JSONSerialization.jsonObject(with: output) as? [String: Any],
              Set(fields.keys).isSubset(of: ["schemaVersion", "requestID", "instanceID", "configurationRevision", "contentHash", "document", "replayResponse", "error"]) else { throw TransportError.invalidResponse }
        let response = try JSONDecoder().decode(Response.self, from: output)
        guard response.schemaVersion == 1, response.requestID == request.requestID,
              response.configurationRevision > 0, validDigest(response.contentHash) else { throw TransportError.invalidResponse }
        if let error = response.error { throw TransportError.remote(error.code, error.message) }
        if let document = response.document { try ThumbleConfigurationBridge.validate(document) }
        return response
    }

    static func snapshot(directory: URL = stateDirectory()) throws -> Snapshot {
        let response = try exchange(Request(requestID: UUID(), action: "snapshot", invocationID: UUID(), requestDigest: String(repeating: "0", count: 64)), directory: directory)
        guard let document = response.document else { throw TransportError.invalidResponse }
        return Snapshot(instanceID: response.instanceID, revision: response.configurationRevision, contentHash: response.contentHash, document: document)
    }

    static func commit(_ document: ThumbleBridgeConfigurationDocument, from snapshot: Snapshot, directory: URL = stateDirectory()) throws {
        try ThumbleConfigurationBridge.validate(document)
        let request = Request(requestID: UUID(), action: "commit", instanceID: snapshot.instanceID, expectedRevision: snapshot.revision,
            expectedContentHash: snapshot.contentHash, invocationID: UUID(), requestDigest: digest(try encoder().encode(document)), document: document)
        _ = try exchange(request, directory: directory)
    }

    enum TransportError: LocalizedError {
        case insecureEndpoint, unavailable, frameTooLarge, invalidResponse, remote(String, String)
        var errorDescription: String? {
            switch self {
            case .insecureEndpoint: return "Native configuration endpoint failed ownership or permission validation."
            case .unavailable: return "Native editor configuration authority is unreachable; no other store was written."
            case .frameTooLarge: return "Native configuration frame exceeds its size limit."
            case .invalidResponse: return "Native editor returned an invalid configuration response."
            case .remote(let code, let message): return "\(message) [\(code)]"
            }
        }
    }

    fileprivate static func validDigest(_ value: String) -> Bool { value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    fileprivate static func validateDirectory(_ directory: URL) throws {
        var status = stat()
        guard lstat(directory.path, &status) == 0, status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == geteuid(), status.st_mode & 0o077 == 0 else { throw TransportError.insecureEndpoint }
    }
    fileprivate static func address(for path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw TransportError.insecureEndpoint }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in buffer.copyBytes(from: bytes) }
        return address
    }
    fileprivate static func configure(_ fd: Int32) throws {
        // Normalize Darwin's inherited listener flags. Framing uses polled,
        // nonblocking recv/send with absolute deadlines; these socket timeouts
        // also bound connection setup and remain a syscall-level backstop.
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) == 0 else { throw TransportError.unavailable }
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        var one: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
              setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
              setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw TransportError.unavailable }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }
    fileprivate static func validatePeer(_ fd: Int32) throws {
        var uid: uid_t = 0; var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid() else { throw TransportError.insecureEndpoint }
    }
    private static func waitReady(_ fd: Int32, events: Int16, deadline: DispatchTime) throws {
        var descriptor = pollfd(fd: fd, events: events, revents: 0)
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard deadline.uptimeNanoseconds > now else { throw TransportError.unavailable }
            let milliseconds = Int32((deadline.uptimeNanoseconds - now + 999_999) / 1_000_000)
            let result = poll(&descriptor, 1, milliseconds)
            if result > 0 {
                guard descriptor.revents & Int16(POLLNVAL) == 0 else { throw TransportError.unavailable }
                return // HUP is readable EOF; do not reconfigure a disconnected socket.
            }
            if result < 0, errno == EINTR { continue }
            throw TransportError.unavailable
        }
    }
    static func read(from fd: Int32, timeout: TimeInterval = 10) throws -> Data {
        guard timeout.isFinite, timeout > 0, timeout <= 10 else { throw TransportError.unavailable }
        let deadline = DispatchTime.now() + timeout
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 8192)
        while true {
            try waitReady(fd, events: Int16(POLLIN), deadline: deadline)
            let count = Darwin.recv(fd, &bytes, bytes.count, MSG_DONTWAIT)
            if count == 0 { break }
            if count < 0 { if errno == EINTR || errno == EAGAIN { continue }; throw TransportError.unavailable }
            guard data.count + count <= maximumFrameBytes else { throw TransportError.frameTooLarge }
            data.append(contentsOf: bytes.prefix(count))
        }
        guard data.last == 0x0A else { throw TransportError.invalidResponse }
        data.removeLast()
        guard !data.isEmpty, !data.contains(0x0A), !data.contains(0x0D) else { throw TransportError.invalidResponse }
        return data
    }
    static func write(_ data: Data, to fd: Int32, timeout: TimeInterval = 10) throws {
        guard timeout.isFinite, timeout > 0, timeout <= 10 else { throw TransportError.unavailable }
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw TransportError.unavailable }
        let deadline = DispatchTime.now() + timeout
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try waitReady(fd, events: Int16(POLLOUT), deadline: deadline)
                let count = Darwin.send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, MSG_DONTWAIT)
                if count < 0 { if errno == EINTR || errno == EAGAIN { continue }; throw TransportError.unavailable }
                guard count > 0 else { throw TransportError.unavailable }
                offset += count
            }
        }
    }
}

/// Called on the native editor's serial/main queue. Document fingerprints detect
/// GUI edits as well as CLI writes without requiring every GUI setter to publish
/// a second revision source. Replay records are bounded to this editor instance.
final class ThumbleNativeConfigurationAuthority {
    private let instanceID = UUID()
    private var revision: UInt64 = 1
    private var contentHash = String(repeating: "0", count: 64)
    private var previousHash: String?
    private let readDocument: () throws -> ThumbleBridgeConfigurationDocument
    private let writeDocument: (ThumbleBridgeConfigurationDocument) throws -> Void
    private struct Replay { let digest: String; let response: ThumbleBridgeJSONValue }
    private var replays: [UUID: Replay] = [:]
    private var replayOrder: [UUID] = []

    init(read: @escaping () throws -> ThumbleBridgeConfigurationDocument, write: @escaping (ThumbleBridgeConfigurationDocument) throws -> Void) {
        readDocument = read; writeDocument = write
    }

    func handle(_ data: Data) -> Data {
        var requestID = UUID()
        var response = ThumbleNativeConfiguration.Response(requestID: requestID, instanceID: instanceID, configurationRevision: revision, contentHash: contentHash)
        do {
            guard data.count <= ThumbleNativeConfiguration.maximumFrameBytes else { throw ThumbleNativeConfiguration.TransportError.frameTooLarge }
            try JSONDecoder.validateUniqueKeys(in: data)
            guard let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ThumbleNativeConfiguration.TransportError.invalidResponse }
            let common: Set<String> = ["schemaVersion", "requestID", "action", "invocationID", "requestDigest"]
            let action = fields["action"] as? String
            let allowed = action == "commit" ? common.union(["instanceID", "expectedRevision", "expectedContentHash", "document", "replayResponse"]) : common
            guard Set(fields.keys).isSubset(of: allowed) else { throw ThumbleNativeConfiguration.TransportError.invalidResponse }
            let request = try JSONDecoder().decode(ThumbleNativeConfiguration.Request.self, from: data)
            requestID = request.requestID
            guard request.schemaVersion == 1, ThumbleNativeConfiguration.validDigest(request.requestDigest), ["snapshot", "commit"].contains(request.action) else { throw ThumbleNativeConfiguration.TransportError.invalidResponse }
            if request.action == "commit" {
                guard request.instanceID == instanceID else { throw ThumbleNativeConfiguration.TransportError.remote("native_instance_changed", "Native editor instance changed; no configuration was written") }
                guard let candidate = request.document else { throw ThumbleNativeConfiguration.TransportError.invalidResponse }
                try ThumbleConfigurationBridge.validate(candidate)
                if let replay = request.replayResponse { try validateReplay(replay, invocationID: request.invocationID) }
            }
            let current = try readDocument()
            try ThumbleConfigurationBridge.validate(current)
            let currentHash = ThumbleNativeConfiguration.digest(try ThumbleNativeConfiguration.encoder().encode(current))
            if let previousHash, previousHash != currentHash {
                guard revision < UInt64.max else { throw ThumbleNativeConfiguration.TransportError.remote("revision_exhausted", "Native configuration revision is exhausted") }
                revision += 1
            }
            previousHash = currentHash; contentHash = currentHash
            response = ThumbleNativeConfiguration.Response(requestID: requestID, instanceID: instanceID, configurationRevision: revision, contentHash: contentHash)
            if let replay = replays[request.invocationID] {
                guard replay.digest == request.requestDigest else { throw ThumbleNativeConfiguration.TransportError.remote("commit_id_conflict", "Invocation ID was already used for different native configuration content") }
                response.replayResponse = replay.response
            } else if request.action == "snapshot" {
                response.document = current
            } else {
                guard request.instanceID == instanceID else { throw ThumbleNativeConfiguration.TransportError.remote("native_instance_changed", "Native editor instance changed; no configuration was written") }
                guard request.expectedRevision == revision, request.expectedContentHash == contentHash else { throw ThumbleNativeConfiguration.TransportError.remote("configuration_revision_conflict", "Native configuration changed after the read; no configuration was written") }
                guard let candidate = request.document else { throw ThumbleNativeConfiguration.TransportError.invalidResponse }
                try ThumbleConfigurationBridge.validate(candidate)
                let candidateHash = ThumbleNativeConfiguration.digest(try ThumbleNativeConfiguration.encoder().encode(candidate))
                if candidateHash != contentHash {
                    guard revision < UInt64.max else { throw ThumbleNativeConfiguration.TransportError.remote("revision_exhausted", "Native configuration revision is exhausted") }
                    try writeDocument(candidate)
                    revision += 1; previousHash = candidateHash; contentHash = candidateHash
                }
                response.configurationRevision = revision; response.contentHash = contentHash
                if let replay = request.replayResponse {
                    replays[request.invocationID] = Replay(digest: request.requestDigest, response: replay)
                    replayOrder.append(request.invocationID)
                    if replayOrder.count > 16 { replays[replayOrder.removeFirst()] = nil }
                    response.replayResponse = replay
                }
            }
        } catch {
            response.requestID = requestID
            if case ThumbleNativeConfiguration.TransportError.remote(let code, let message) = error {
                response.error = .init(code: code, message: message)
            } else { response.error = .init(code: "invalid_native_configuration", message: "Native configuration request is invalid or obsolete; no configuration was written") }
        }
        return (try? ThumbleNativeConfiguration.encoder().encode(response)) ?? Data()
    }

    private func validateReplay(_ replay: ThumbleBridgeJSONValue, invocationID: UUID) throws {
        let encoded = try ThumbleNativeConfiguration.encoder().encode(replay)
        guard encoded.count <= ThumbleNativeConfiguration.maximumReplayBytes,
              let root = try JSONSerialization.jsonObject(with: encoded) as? [String: Any],
              Set(root.keys).isSubset(of: ["schemaVersion", "ok", "invocationID", "authorityMode", "outcome"]),
              root["schemaVersion"] as? Int == 8, root["ok"] as? Bool == true,
              UUID(uuidString: root["invocationID"] as? String ?? "") == invocationID,
              root["authorityMode"] as? String == "native", let outcome = root["outcome"] as? [String: Any],
              Set(outcome.keys).isSubset(of: ["operation", "profileNames", "destination", "removedEveryProfile", "changed", "configurationRevision", "draftID", "commitID", "idempotentReplay"])
        else { throw ThumbleNativeConfiguration.TransportError.invalidResponse }
    }
}

/// Same-user Unix socket owned for the editor lease's entire lifetime. At most
/// four bounded requests may wait for the editor queue; network stop/start does
/// not affect configuration access.
final class ThumbleNativeConfigurationSocket {
    private let descriptor: Int32
    private let path: String
    private let source: DispatchSourceRead
    private let permits = DispatchSemaphore(value: 4)
    private let handler: (Data, @escaping (Data) -> Void) -> Void

    init(directory: URL, handler: @escaping (Data, @escaping (Data) -> Void) -> Void) throws {
        try ThumbleNativeConfiguration.validateDirectory(directory)
        let socketDirectory = ThumbleNativeConfiguration.socketDirectory(for: directory)
        var directoryStatus = stat()
        if lstat(socketDirectory.path, &directoryStatus) != 0 {
            guard errno == ENOENT else { throw ThumbleNativeConfiguration.TransportError.insecureEndpoint }
            try FileManager.default.createDirectory(at: socketDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        try ThumbleNativeConfiguration.validateDirectory(socketDirectory)
        path = socketDirectory.appendingPathComponent(ThumbleNativeConfiguration.socketName).path
        var status = stat()
        if lstat(path, &status) == 0 {
            guard status.st_mode & S_IFMT == S_IFSOCK, status.st_uid == geteuid(), status.st_mode & 0o077 == 0 else { throw ThumbleNativeConfiguration.TransportError.insecureEndpoint }
            // The caller owns runtime.lock, so any socket at this name is stale.
            guard unlink(path) == 0 else { throw ThumbleNativeConfiguration.TransportError.insecureEndpoint }
        } else if errno != ENOENT { throw ThumbleNativeConfiguration.TransportError.insecureEndpoint }
        var address = try ThumbleNativeConfiguration.address(for: path)
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ThumbleNativeConfiguration.TransportError.unavailable }
        let fd = descriptor
        let bound = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 4) == 0 else { close(fd); unlink(path); throw ThumbleNativeConfiguration.TransportError.unavailable }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        self.handler = handler
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "Thumble.NativeConfiguration.Accept"))
        source.setEventHandler { [weak self] in self?.acceptRequests() }
        // Dispatch owns the listener until cancellation has completed. Never
        // allow descriptor reuse while a source may still monitor that number.
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    deinit { source.cancel(); unlink(path); rmdir(URL(fileURLWithPath: path).deletingLastPathComponent().path) }

    private func acceptRequests() {
        while true {
            let client = accept(descriptor, nil, nil)
            if client < 0 { return }
            guard permits.wait(timeout: .now()) == .success else { close(client); continue }
            DispatchQueue.global(qos: .userInitiated).async { [weak self, permits] in
                defer { close(client); permits.signal() }
                do {
                    try ThumbleNativeConfiguration.configure(client)
                    try ThumbleNativeConfiguration.validatePeer(client)
                    let input = try ThumbleNativeConfiguration.read(from: client)
                    guard let handler = self?.handler else { return }
                    let ready = DispatchSemaphore(value: 0)
                    let box = ResponseBox()
                    handler(input) { data in box.store(data); ready.signal() }
                    guard ready.wait(timeout: .now() + 15) == .success else { return }
                    var output = box.load()
                    guard !output.isEmpty, output.count + 1 <= ThumbleNativeConfiguration.maximumFrameBytes else { return }
                    output.append(0x0A)
                    try ThumbleNativeConfiguration.write(output, to: client)
                } catch { /* No request executes after a framing/peer failure. */ }
            }
        }
    }
    private final class ResponseBox {
        private let lock = NSLock(); private var data = Data()
        func store(_ value: Data) { lock.lock(); data = value; lock.unlock() }
        func load() -> Data { lock.lock(); defer { lock.unlock() }; return data }
    }
}
#endif
