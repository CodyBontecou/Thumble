import Darwin
import Foundation

/// Unprivileged, bounded IPC client. Only the long-running runtime owns output.
final class ThumbleCLIRuntimeBackend {
    static let schemaVersion = 1
    static let maximumFrameBytes = 64 * 1024

    enum Command: Encodable {
        case status, releaseAll, gamepadStatus, gamepadRetry
        case tapControl(String)
        case testControl(String, ButtonPressState)

        private enum CodingKeys: String, CodingKey { case type, controlID, state }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            let type: String
            switch self {
            case .status: type = "status"
            case .releaseAll: type = "release-all"
            case .gamepadStatus: type = "gamepad-status"
            case .gamepadRetry: type = "gamepad-retry"
            case .tapControl(let id):
                type = "tap-control"
                try c.encode(id, forKey: .controlID)
            case .testControl(let id, let state):
                type = "test-control"
                try c.encode(id, forKey: .controlID)
                try c.encode(state, forKey: .state)
            }
            try c.encode(type, forKey: .type)
        }
    }

    enum Owner: String, Decodable { case rust, none, unreachable }
    struct RemoteFailure: Decodable { let code: String; let message: String }
    struct Response {
        let owner: Owner
        let ok: Bool
        let invocationID: UUID
        let error: RemoteFailure?
        let control: ControlProjection?
        let frame: Data
    }
    struct ControlProjection: Decodable {
        let ok: Bool
        let status: HostProjection?
        let released: Bool?
        let pressedControlID: String?
        let virtualGamepadStatus: VirtualGamepadStatus?
    }
    struct HostProjection: Decodable {
        let pid: UInt32
        let port: UInt16
        let serviceName: String
        let accessibilityTrusted: Bool
        let inputEnabled: Bool
        let output: OutputProjection
    }
    struct OutputProjection: Decodable {
        let mode: String
        let virtualGamepadStatus: VirtualGamepadStatus?
    }
    enum Route {
        case rust(Response)
        /// Raw status is decoded in a separate phase by the CLI, avoiding large model copies here.
        case legacy(Data)
    }
    enum BackendError: LocalizedError {
        case invalidControl, malformedResponse, requestTooLarge, responseTooLarge
        case launchFailed, timeout, helperFailed, noVerifiedOwner
        case remote(RemoteFailure, UUID)
        var errorDescription: String? {
            switch self {
            case .invalidControl: return "Control ID must be a bounded installed-control identifier."
            case .malformedResponse: return "Runtime bridge returned an invalid or uncorrelated response."
            case .requestTooLarge: return "Runtime request exceeds 64 KiB."
            case .responseTooLarge: return "Runtime response exceeds 64 KiB."
            case .launchFailed: return "Could not launch the validated runtime bridge."
            case .timeout: return "Runtime bridge timed out; ownership remains unverified."
            case .helperFailed: return "Runtime bridge did not acknowledge the command."
            case .noVerifiedOwner: return "No verified live runtime owner. Open Thumble Mac or the Rust host first."
            case .remote(let failure, let id): return "\(failure.message) [\(failure.code)] Invocation ID: \(id.uuidString)"
            }
        }
    }

    typealias Transport = (Data) throws -> (Int32, Data)
    private let transport: Transport

    init(executableURL: URL? = nil, timeout: TimeInterval = 20) throws {
        let url = executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            .deletingLastPathComponent().appendingPathComponent("thumble-cli-bridge")
        try ThumbleCLIProfileBackend.validateExecutable(at: url)
        transport = { input in try Self.execute(input, at: url, timeout: timeout) }
    }

    /// Test seam exercises the exact public request/response/routing contract without OS input.
    init(transport: @escaping Transport) { self.transport = transport }

    static func requestFrame(_ command: Command, invocationID: UUID) throws -> Data {
        let controlID: String?
        switch command {
        case .tapControl(let id), .testControl(let id, _): controlID = id
        default: controlID = nil
        }
        if let id = controlID {
            guard !id.isEmpty, id.utf8.count <= 256, !id.contains(".."),
                  id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                      || [45, 95, 58, 46, 35].contains($0) })
            else { throw BackendError.invalidControl }
        }
        struct Request: Encodable {
            let schemaVersion = ThumbleCLIRuntimeBackend.schemaVersion
            let runtimeCommand: Command
            let invocationID: UUID
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(Request(runtimeCommand: command, invocationID: invocationID))
        guard data.count + 1 <= maximumFrameBytes else { throw BackendError.requestTooLarge }
        data.append(10)
        return data
    }

    func perform(_ command: Command, invocationID: UUID = UUID()) throws -> Response {
        let (exitStatus, frame) = try transport(Self.requestFrame(command, invocationID: invocationID))
        let response = try Self.decodeResponse(frame, invocationID: invocationID)
        // A valid typed unreachable error must remain visible to owner routing.
        guard exitStatus == 0 || !response.ok else { throw BackendError.helperFailed }
        return response
    }

    static func decodeResponse(_ frame: Data, invocationID: UUID) throws -> Response {
        guard frame.count <= maximumFrameBytes else { throw BackendError.responseTooLarge }
        guard frame.last == 10 else { throw BackendError.malformedResponse }
        let line = Data(frame.dropLast())
        struct Header: Decodable {
            let schemaVersion: Int
            let ok: Bool
            let invocationID: UUID
            let owner: Owner
        }
        let decoder = JSONDecoder()
        guard !line.isEmpty, !line.contains(10), !line.contains(13),
              let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              noDuplicateJSONKeys(line),
              Set(root.keys).isSubset(of: ["schemaVersion", "ok", "invocationID", "owner", "response", "error"]),
              let header = try? decoder.decode(Header.self, from: line),
              header.schemaVersion == schemaVersion, header.invocationID == invocationID
        else { throw BackendError.malformedResponse }
        let ok = header.ok
        let owner = header.owner
        var control: ControlProjection?
        var failure: RemoteFailure?
        if let object = root["response"] {
            guard owner == .rust, let object = object as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: object),
                  let decoded = try? decoder.decode(ControlProjection.self, from: data), decoded.ok == ok
            else { throw BackendError.malformedResponse }
            guard [decoded.virtualGamepadStatus, decoded.status?.output.virtualGamepadStatus]
                .compactMap({ $0 }).allSatisfy(Self.validGamepadStatus) else { throw BackendError.malformedResponse }
            control = decoded
        }
        if let object = root["error"] {
            guard let object = object as? [String: Any], Set(object.keys) == ["code", "message"],
                  let data = try? JSONSerialization.data(withJSONObject: object),
                  let decoded = try? decoder.decode(RemoteFailure.self, from: data),
                  !decoded.code.isEmpty, decoded.code.utf8.count <= 128,
                  !decoded.message.isEmpty, decoded.message.utf8.count <= 2048,
                  !decoded.code.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  !decoded.message.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else { throw BackendError.malformedResponse }
            failure = decoded
        }
        guard ok ? failure == nil && owner != .unreachable && (owner != .rust || control != nil) : failure != nil,
              owner != .none || (ok && control == nil)
        else { throw BackendError.malformedResponse }
        return Response(owner: owner, ok: ok, invocationID: invocationID, error: failure, control: control, frame: frame)
    }

    /// Both Foundation JSON decoders accept duplicate keys, sometimes differently.
    /// Validate keys on the already syntax-checked, bounded frame before projecting it.
    private static func noDuplicateJSONKeys(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        var stack: [Set<String>?] = []
        var cursor = 0
        while cursor < bytes.count {
            switch bytes[cursor] {
            case 123: stack.append(Set()) // object
            case 91: stack.append(nil) // array
            case 125, 93:
                guard !stack.isEmpty else { return false }
                stack.removeLast()
            case 34:
                let start = cursor
                cursor += 1
                while cursor < bytes.count && bytes[cursor] != 34 {
                    if bytes[cursor] == 92 { cursor += 1 }
                    cursor += 1
                }
                guard cursor < bytes.count else { return false }
                var next = cursor + 1
                while next < bytes.count && [9, 10, 13, 32].contains(bytes[next]) { next += 1 }
                if next < bytes.count && bytes[next] == 58 {
                    guard !stack.isEmpty, var keys = stack[stack.count - 1],
                          let key = try? JSONDecoder().decode(String.self, from: Data(bytes[start...cursor])),
                          keys.insert(key).inserted else { return false }
                    stack[stack.count - 1] = keys
                }
            default: break
            }
            cursor += 1
        }
        return stack.isEmpty
    }

    private static func validGamepadStatus(_ status: VirtualGamepadStatus) -> Bool {
        let sticks = [status.leftStickX, status.leftStickY, status.rightStickX, status.rightStickY]
        let triggers = [status.leftTrigger, status.rightTrigger]
        return sticks.allSatisfy { $0.isFinite && (-1...1).contains($0) }
            && triggers.allSatisfy { $0.isFinite && (0...1).contains($0) }
            && status.pressedButtons.count <= VirtualGamepadButton.allCases.count
            && Set(status.pressedButtons).count == status.pressedButtons.count
            && (status.lastError?.utf8.count ?? 0) <= 2048
    }

    /// A failed Rust socket is not permission to broadcast legacy input. Only an absent
    /// runtime or held lock without Rust artifacts may attempt correlated legacy verification.
    func route(_ command: Command, invocationID: UUID = UUID(),
               legacyStatus: (UUID) throws -> Data,
               processIsLive: (Int32) -> Bool = { Darwin.kill($0, 0) == 0 },
               now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) throws -> Route {
        let response = try perform(command, invocationID: invocationID)
        if response.owner == .rust {
            guard response.ok else { throw failure(response) }
            switch command {
            case .status: guard response.control?.status != nil else { throw BackendError.malformedResponse }
            case .releaseAll: guard response.control?.released == true else { throw BackendError.helperFailed }
            case .tapControl(let id), .testControl(let id, _):
                guard response.control?.pressedControlID?.lowercased() == id.lowercased() else { throw BackendError.helperFailed }
            case .gamepadStatus, .gamepadRetry:
                guard response.control?.virtualGamepadStatus != nil else { throw BackendError.malformedResponse }
            }
            return .rust(response)
        }
        guard response.owner == .none || (response.owner == .unreachable && response.error?.code == "legacy_owner_possible")
        else { throw failure(response) }
        let data = try legacyStatus(invocationID)
        try Self.verifyLegacyStatus(data, requestID: invocationID, now: now, processIsLive: processIsLive)
        return .legacy(data)
    }

    private func failure(_ response: Response) -> BackendError {
        response.error.map { .remote($0, response.invocationID) } ?? .noVerifiedOwner
    }

    static func verifyLegacyStatus(_ data: Data, requestID: UUID, now: Int64,
                                   processIsLive: (Int32) -> Bool) throws {
        struct Identity: Decodable {
            let updatedAt: Int64
            let runtimeProcessID: Int32
            let runtimeInstanceID: UUID
            let runtimeStatusRequestID: UUID
        }
        guard data.count <= maximumFrameBytes,
              let identity = try? JSONDecoder().decodeUnique(Identity.self, from: data),
              identity.runtimeStatusRequestID == requestID,
              identity.runtimeProcessID > 0,
              identity.updatedAt <= now + 1000, identity.updatedAt >= now - 3000,
              processIsLive(identity.runtimeProcessID)
        else { throw BackendError.noVerifiedOwner }
    }

    private static func execute(_ input: Data, at url: URL, timeout: TimeInterval) throws -> (Int32, Data) {
        try ThumbleCLIProfileBackend.validateExecutable(at: url)
        let process = Process()
        process.executableURL = url
        process.arguments = []
        process.environment = sanitizedEnvironment()
        process.currentDirectoryURL = URL(fileURLWithPath: "/", isDirectory: true)
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }
        do { try process.run() } catch { throw BackendError.launchFailed }
        let pid = process.processIdentifier
        _ = Darwin.setpgid(pid, pid)
        let output = RuntimeReadBox(maximum: maximumFrameBytes)
        let diagnostics = RuntimeReadBox(maximum: 16 * 1024)
        let readers = DispatchGroup()
        for (box, handle) in [(output, stdout.fileHandleForReading), (diagnostics, stderr.fileHandleForReading)] {
            readers.enter()
            DispatchQueue.global().async { box.read(handle); readers.leave() }
        }
        let written = DispatchSemaphore(value: 0)
        let inputResult = RuntimeReadBox(maximum: 1)
        DispatchQueue.global().async {
            do { try stdin.fileHandleForWriting.write(contentsOf: input) }
            catch { inputResult.markOverflow() }
            try? stdin.fileHandleForWriting.close()
            written.signal()
        }
        func killHelper() {
            _ = Darwin.kill(-pid, SIGKILL)
            _ = Darwin.kill(pid, SIGKILL)
        }
        guard terminated.wait(timeout: .now() + timeout) == .success else {
            killHelper()
            throw BackendError.timeout
        }
        guard written.wait(timeout: .now() + 1) == .success,
              readers.wait(timeout: .now() + 1) == .success else {
            killHelper()
            throw BackendError.timeout
        }
        guard !inputResult.overflowed else { throw BackendError.helperFailed }
        guard !output.overflowed else { throw BackendError.responseTooLarge }
        return (process.terminationStatus, output.data)
    }

    private static func sanitizedEnvironment() -> [String: String] {
        guard let home = ProcessInfo.processInfo.environment["HOME"], home.hasPrefix("/") else { return [:] }
        var status = stat()
        guard lstat(home, &status) == 0, status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == geteuid(), status.st_mode & 0o022 == 0 else { return [:] }
        return ["HOME": home]
    }
}

private final class RuntimeReadBox: @unchecked Sendable {
    private let lock = NSLock()
    private let maximum: Int
    private var stored = Data()
    private var overflow = false
    init(maximum: Int) { self.maximum = maximum }
    var data: Data { lock.lock(); defer { lock.unlock() }; return stored }
    var overflowed: Bool { lock.lock(); defer { lock.unlock() }; return overflow }
    func markOverflow() { lock.lock(); overflow = true; lock.unlock() }
    func read(_ handle: FileHandle) {
        while let chunk = try? handle.read(upToCount: 16 * 1024), !chunk.isEmpty {
            lock.lock()
            if chunk.count > maximum - stored.count { overflow = true }
            stored.append(chunk.prefix(maximum - stored.count))
            lock.unlock()
        }
        try? handle.close()
    }
}
