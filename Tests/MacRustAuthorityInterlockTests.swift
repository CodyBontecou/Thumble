import Darwin
import Foundation
import XCTest

final class MacRustAuthorityInterlockTests: XCTestCase {
    func testLegacyBackendLeaseUsesExactExclusiveAuthorityLock() throws {
        let stateDirectory = try temporaryStateDirectory()
        var first: MacLegacyAuthorityLease? = try .acquire(stateDirectory: stateDirectory)
        XCTAssertThrowsError(try MacLegacyAuthorityLease.acquire(stateDirectory: stateDirectory)) {
            XCTAssertTrue($0 is MacLegacyAuthorityLease.LeaseError)
        }
        first = nil
        XCTAssertNoThrow(try MacLegacyAuthorityLease.acquire(stateDirectory: stateDirectory))
    }

    func testSymlinkedAuthorityLockFailsClosed() throws {
        let stateDirectory = try temporaryStateDirectory()
        let target = stateDirectory.appendingPathComponent("target")
        try Data().write(to: target)
        try FileManager.default.createSymbolicLink(
            at: stateDirectory.appendingPathComponent("runtime.lock"),
            withDestinationURL: target
        )
        XCTAssertThrowsError(try MacLegacyAuthorityLease.acquire(stateDirectory: stateDirectory)) {
            XCTAssertTrue($0 is MacLegacyAuthorityLease.LeaseError)
        }
    }

    func testNativeCompareAndSwapRejectsGuiChangesInvalidOwnersAndPersistenceFailures() throws {
        var current = try nativeDocument()
        var writes = 0
        var persistFails = false
        let authority = ThumbleNativeConfigurationAuthority(read: { current }, write: { candidate in
            if persistFails { throw CocoaError(.fileWriteUnknown) }
            writes += 1; current = candidate
        })
        func send(_ request: ThumbleNativeConfiguration.Request) throws -> ThumbleNativeConfiguration.Response {
            try JSONDecoder().decodeUnique(ThumbleNativeConfiguration.Response.self, from: authority.handle(ThumbleNativeConfiguration.encoder().encode(request)))
        }
        let get = ThumbleNativeConfiguration.Request(requestID: UUID(), action: "snapshot", invocationID: UUID(), requestDigest: String(repeating: "a", count: 64))
        let snapshot = try send(get)
        XCTAssertEqual(snapshot.document, current)
        var candidate = current
        if case .object(var fields) = candidate.profiles[0] { fields["name"] = .string("Requested"); candidate.profiles[0] = .object(fields) }
        var commit = ThumbleNativeConfiguration.Request(requestID: UUID(), action: "commit", instanceID: snapshot.instanceID, expectedRevision: snapshot.configurationRevision,
            expectedContentHash: snapshot.contentHash, invocationID: UUID(), requestDigest: String(repeating: "b", count: 64), document: candidate)
        // A GUI write between the read and commit must not be overwritten.
        if case .object(var fields) = current.profiles[0] { fields["name"] = .string("GUI changed"); current.profiles[0] = .object(fields) }
        XCTAssertEqual(try send(commit).error?.code, "configuration_revision_conflict")
        XCTAssertEqual(writes, 0)
        let fresh = try send(get)
        commit.expectedRevision = fresh.configurationRevision; commit.expectedContentHash = fresh.contentHash
        var invalid = candidate
        invalid.keyBindings = .object(["jump": .object([:])])
        commit.document = invalid
        XCTAssertNotNil(try send(commit).error)
        XCTAssertEqual(writes, 0)
        let before = current
        commit.document = candidate; persistFails = true
        XCTAssertNotNil(try send(commit).error)
        XCTAssertEqual(current, before)
        XCTAssertEqual(writes, 0)
        persistFails = false
        let accepted = try send(commit)
        XCTAssertNil(accepted.error)
        XCTAssertEqual(accepted.configurationRevision, fresh.configurationRevision + 1)
        XCTAssertEqual(current, candidate)
        XCTAssertEqual(writes, 1)
    }

    func testNativeReplayAndAmbiguousRequestsNeverRepeatWrites() throws {
        var current = try nativeDocument()
        var writes = 0
        let authority = ThumbleNativeConfigurationAuthority(read: { current }, write: { current = $0; writes += 1 })
        let encoder = ThumbleNativeConfiguration.encoder()
        func send(_ request: ThumbleNativeConfiguration.Request) throws -> ThumbleNativeConfiguration.Response {
            try JSONDecoder().decodeUnique(ThumbleNativeConfiguration.Response.self, from: authority.handle(encoder.encode(request)))
        }
        let invocation = UUID()
        var get = ThumbleNativeConfiguration.Request(requestID: UUID(), action: "snapshot", invocationID: invocation, requestDigest: String(repeating: "a", count: 64))
        let snapshot = try send(get)
        var candidate = current
        if case .object(var fields) = candidate.profiles[0] { fields["name"] = .string("Once"); candidate.profiles[0] = .object(fields) }
        let replay = ThumbleBridgeJSONValue.object(["schemaVersion": .integer(8), "ok": .bool(true), "invocationID": .string(invocation.uuidString), "authorityMode": .string("native"),
            "outcome": .object(["configurationRevision": .integer(Int64(snapshot.configurationRevision + 1)), "changed": .bool(true)])])
        let commit = ThumbleNativeConfiguration.Request(requestID: UUID(), action: "commit", instanceID: snapshot.instanceID, expectedRevision: snapshot.configurationRevision,
            expectedContentHash: snapshot.contentHash, invocationID: invocation, requestDigest: get.requestDigest, document: candidate, replayResponse: replay)
        XCTAssertNil(try send(commit).error)
        XCTAssertEqual(try send(get).replayResponse, replay)
        XCTAssertEqual(try send(commit).replayResponse, replay)
        XCTAssertEqual(writes, 1)
        var invalidReplay = commit
        var obsolete = candidate
        obsolete.keyBindings = .object(["jump": .object([:])])
        invalidReplay.document = obsolete
        XCTAssertEqual(try send(invalidReplay).error?.code, "invalid_native_configuration", "Replay must not authorize obsolete candidate input")
        invalidReplay = commit; invalidReplay.instanceID = UUID()
        XCTAssertEqual(try send(invalidReplay).error?.code, "native_instance_changed")
        XCTAssertEqual(writes, 1)
        get.requestDigest = String(repeating: "b", count: 64)
        XCTAssertEqual(try send(get).error?.code, "commit_id_conflict")
        let ambiguous = Data("{\"schemaVersion\":1,\"schemaVersion\":1}".utf8)
        let rejected = try JSONDecoder().decodeUnique(ThumbleNativeConfiguration.Response.self, from: authority.handle(ambiguous))
        XCTAssertNotNil(rejected.error)
        XCTAssertEqual(writes, 1)
    }

    func testNativeSocketUsesSameUserEndpointAndFailsClosedAfterShutdown() throws {
        let directory = URL(fileURLWithPath: "/tmp/tnc-test-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let lease = try MacLegacyAuthorityLease.acquire(stateDirectory: directory)
        let original = try nativeDocument()
        var current = original
        let authority = ThumbleNativeConfigurationAuthority(read: { current }, write: { current = $0 })
        let queue = DispatchQueue(label: "Thumble.NativeConfiguration.Test")
        var socket: ThumbleNativeConfigurationSocket? = try .init(directory: directory) { data, reply in
            queue.async { reply(authority.handle(data)) }
        }
        let snapshot = try ThumbleNativeConfiguration.snapshot(directory: directory)
        XCTAssertEqual(snapshot.document, original)
        // A client can pause between any two frame bytes. Darwin's inherited
        // O_NONBLOCK must not turn a partial frame into an immediate rejection.
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        XCTAssertEqual(setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)), 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let path = Array(ThumbleNativeConfiguration.socketDirectory(for: directory).appendingPathComponent(ThumbleNativeConfiguration.socketName).path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
        XCTAssertEqual(withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }, 0)
        let request = ThumbleNativeConfiguration.Request(requestID: UUID(), action: "snapshot", invocationID: UUID(), requestDigest: String(repeating: "0", count: 64))
        var frame = try ThumbleNativeConfiguration.encoder().encode(request); frame.append(0x0A)
        let first = frame.prefix(3)
        XCTAssertEqual(first.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }, first.count)
        Thread.sleep(forTimeInterval: 0.1)
        let remainder = frame.dropFirst(3)
        XCTAssertEqual(remainder.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }, remainder.count)
        XCTAssertEqual(shutdown(fd, SHUT_WR), 0)
        var responseData = Data(); var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count == 0 { break }
            guard count > 0 else { XCTFail("Partial native frame was rejected"); break }
            responseData.append(contentsOf: bytes.prefix(count))
        }
        guard responseData.last == 0x0A else { XCTFail("Native response was not framed"); return }
        responseData.removeLast()
        let response = try JSONDecoder().decodeUnique(ThumbleNativeConfiguration.Response.self, from: responseData)
        XCTAssertNil(response.error)
        XCTAssertEqual(response.document, original)
        XCTAssertThrowsError(try MacLegacyAuthorityLease.acquire(stateDirectory: directory), "Native CLI must not release the authority lease")
        socket = nil
        XCTAssertThrowsError(try ThumbleNativeConfiguration.snapshot(directory: directory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("state.json").path))
        withExtendedLifetime(lease) {}
    }

    func testNativeFrameDeadlineCannotBeExtendedByDrippingBytes() throws {
        var descriptors: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
        let reader = descriptors[0], writer = descriptors[1]
        defer { close(reader); close(writer) }
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        XCTAssertEqual(setsockopt(reader, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)), 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            var byte: UInt8 = 0x20
            for _ in 0..<30 {
                _ = Darwin.write(writer, &byte, 1)
                Thread.sleep(forTimeInterval: 0.015)
            }
            _ = shutdown(writer, SHUT_WR); finished.signal()
        }
        let start = DispatchTime.now().uptimeNanoseconds
        XCTAssertThrowsError(try ThumbleNativeConfiguration.read(from: reader, timeout: 0.12))
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        XCTAssertLessThan(elapsed, 0.3, "A drip must not restart the whole-frame deadline")
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
    }

    func testNativeWriteDeadlineCannotBeExtendedBySlowPeer() throws {
        var descriptors: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
        let writer = descriptors[0], reader = descriptors[1]
        defer { close(writer); close(reader) }
        var bufferSize: Int32 = 8192
        XCTAssertEqual(setsockopt(writer, SOL_SOCKET, SO_SNDBUF, &bufferSize, socklen_t(MemoryLayout<Int32>.size)), 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            var bytes = [UInt8](repeating: 0, count: 4096)
            for _ in 0..<30 {
                if Darwin.read(reader, &bytes, bytes.count) <= 0 { break }
                Thread.sleep(forTimeInterval: 0.015)
            }
            finished.signal()
        }
        let start = DispatchTime.now().uptimeNanoseconds
        XCTAssertThrowsError(try ThumbleNativeConfiguration.write(Data(repeating: 0x20, count: 1024 * 1024), to: writer, timeout: 0.12))
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        XCTAssertLessThan(elapsed, 0.3)
        _ = shutdown(writer, SHUT_WR)
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
    }

    func testNativeSocketOwnershipEndsWithPartialFrameWorkersStillRunning() throws {
        let directory = try temporaryStateDirectory()
        let lease = try MacLegacyAuthorityLease.acquire(stateDirectory: directory)
        var socket: ThumbleNativeConfigurationSocket? = try .init(directory: directory) { _, reply in
            XCTFail("An unfinished frame must not execute"); reply(Data())
        }
        weak var weakSocket = socket
        let path = ThumbleNativeConfiguration.socketDirectory(for: directory).appendingPathComponent(ThumbleNativeConfiguration.socketName).path
        var clients: [Int32] = []
        defer { for client in clients { _ = shutdown(client, SHUT_WR); close(client) }; withExtendedLifetime(lease) {} }
        for _ in 0..<4 {
            let client = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            XCTAssertGreaterThanOrEqual(client, 0); clients.append(client)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
            XCTAssertEqual(withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(client, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }, 0)
            var byte: UInt8 = 0x7B; XCTAssertEqual(Darwin.write(client, &byte, 1), 1)
        }
        Thread.sleep(forTimeInterval: 0.1)
        socket = nil
        XCTAssertNil(weakSocket, "Frame workers must not retain socket/lease ownership")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertThrowsError(try ThumbleNativeConfiguration.snapshot(directory: directory))
    }

    private func nativeDocument() throws -> ThumbleBridgeConfigurationDocument {
        let profile = GamepadConfigurationProfile(name: "Native", primaryCustomization: .blankCanvas)
        let raw = try JSONDecoder().decodeUnique(ThumbleBridgeJSONValue.self, from: JSONEncoder().encode(profile))
        return .init(profiles: [raw], activeProfileID: profile.id.uuidString, defaultProfileID: profile.id.uuidString)
    }

    private func temporaryStateDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("thumble-authority-interlock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
}
