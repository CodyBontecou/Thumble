import CryptoKit
import Foundation

/// Save/load boundary for profile-owned binary data. A profile's canonical layout,
/// appearance states and local launch metadata share one content-addressed table.
/// Resolution/rendering continues to use native immutable/COW Data values.
enum GamepadProfileResourceCodec {
    static let versionField = "appearanceResourceVersion"
    static let resourcesField = "appearanceResources"
    static let maximumResourceBytes = 8 * 1024 * 1024

    enum ResourceError: Error, Equatable {
        case invalidEnvelope
        case unsupportedVersion
        case invalidResource(String)
        case missingResource(String)
        case tooLarge
    }

    static func hasResources(_ decoder: Decoder) throws -> Bool {
        let container = try decoder.container(keyedBy: Field.self)
        return container.contains(Field(versionField)) || container.contains(Field(resourcesField))
    }

    static func encode<T: Encodable>(_ value: T, to encoder: Encoder) throws {
        let workspace = EncodingWorkspace()
        try workspace.encode(value, to: encoder)
    }

    private final class EncodingWorkspace {
        let pool = EncodingPool()
        var fields: [String: ThumbleBridgeJSONValue] = [:]

        func encode<T: Encodable>(_ value: T, to encoder: Encoder) throws {
            try encodePayload(value)
            fields[versionField] = .integer(1)
            fields[resourcesField] = .object(pool.snapshot().mapValues { .string($0.base64EncodedString()) })
            try ThumbleBridgeJSONValue.object(fields).encode(to: encoder)
        }

        private func encodePayload<T: Encodable>(_ value: T) throws {
            let nested = JSONEncoder()
            nested.dataEncodingStrategy = .custom { [pool] data, encoder in
                try ResourceReference(resourceSHA256: pool.insert(data)).encode(to: encoder)
            }
            let data = try nested.encode(value)
            fields = try JSONDecoder().decode([String: ThumbleBridgeJSONValue].self, from: data)
        }
    }

    private final class EncodingPool: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: Data] = [:]
        private var digestsByData: [Data: String] = [:]
        private var byteCount = 0

        func insert(_ data: Data) throws -> String {
            lock.lock()
            if let existing = digestsByData[data] { lock.unlock(); return existing }
            lock.unlock()
            let digest = sha256(data)
            lock.lock()
            defer { lock.unlock() }
            if entries[digest] == nil {
                guard data.count <= maximumResourceBytes - byteCount else { throw ResourceError.tooLarge }
                entries[digest] = data
                byteCount += data.count
            }
            digestsByData[data] = digest
            return digest
        }

        func snapshot() -> [String: Data] {
            lock.lock()
            defer { lock.unlock() }
            return entries
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, from decoder: Decoder) throws -> T {
        let workspace = try DecodingWorkspace(decoder)
        return try workspace.decode(type)
    }

    /// Call after removing local-only profile fields for a portable export. An
    /// unreachable bookmark/icon must not survive merely as an orphaned blob.
    static func pruningUnusedResources(in value: ThumbleBridgeJSONValue) throws -> ThumbleBridgeJSONValue {
        guard case .object(var fields) = value else { throw ResourceError.invalidEnvelope }
        guard fields[versionField] != nil || fields[resourcesField] != nil else { return value }
        guard fields[versionField] == .integer(1),
              case .object(let encoded)? = fields[resourcesField] else { throw ResourceError.invalidEnvelope }
        let pool = try DecodingPool(.object(encoded))
        fields[resourcesField] = nil
        let used = try referencedIDs(in: fields, pool: pool)
        fields[resourcesField] = .object(encoded.filter { used.contains($0.key) })
        return .object(fields)
    }

    private static func referencedIDs(in fields: [String: ThumbleBridgeJSONValue], pool: DecodingPool) throws -> Set<String> {
        var pending = Array(fields.values)
        var used = Set<String>()
        while let node = pending.popLast() {
            switch node {
            case .object(let object):
                if object["resourceSHA256"] != nil {
                    guard object.count == 1, case .string(let digest)? = object["resourceSHA256"] else {
                        throw ResourceError.invalidEnvelope
                    }
                    guard pool.entries[digest] != nil else { throw ResourceError.missingResource(digest) }
                    used.insert(digest)
                } else { pending.append(contentsOf: object.values) }
            case .array(let values): pending.append(contentsOf: values)
            default: break
            }
        }
        return used
    }

    private final class DecodingWorkspace {
        var fields: [String: ThumbleBridgeJSONValue]
        let pool: DecodingPool

        init(_ decoder: Decoder) throws {
            guard case .object(var fields) = try ThumbleBridgeJSONValue(from: decoder),
                  let version = fields.removeValue(forKey: versionField),
                  let resources = fields.removeValue(forKey: resourcesField),
                  fields["appearanceBank"] != nil, fields["appearanceBank"] != .null else {
                throw ResourceError.invalidEnvelope
            }
            guard version == .integer(1) else { throw ResourceError.unsupportedVersion }
            let pool = try DecodingPool(resources)
            _ = try referencedIDs(in: fields, pool: pool)
            self.pool = pool
            self.fields = fields
        }

        func decode<T: Decodable>(_ type: T.Type) throws -> T {
            // Payload bytes contain only small references, never repeated Base64
            // expansions. The custom Data strategy returns shared COW buffers.
            let bytes = try JSONEncoder().encode(ThumbleBridgeJSONValue.object(fields))
            let nested = JSONDecoder()
            nested.dataDecodingStrategy = .custom { [pool] decoder in try pool.data(from: decoder) }
            return try nested.decode(type, from: bytes)
        }
    }

    private final class DecodingPool: Sendable {
        let entries: [String: Data]

        init(_ value: ThumbleBridgeJSONValue) throws {
            guard case .object(let resources) = value else { throw ResourceError.invalidEnvelope }
            var entries: [String: Data] = [:]
            var byteCount = 0
            for digest in resources.keys.sorted() {
                let value = resources[digest]!
                guard case .string(let encoded) = value,
                      encoded.utf8.count <= ((maximumResourceBytes + 2) / 3) * 4,
                      let data = Data(base64Encoded: encoded), data.base64EncodedString() == encoded,
                      sha256(data) == digest else { throw ResourceError.invalidResource(digest) }
                guard data.count <= maximumResourceBytes - byteCount else { throw ResourceError.tooLarge }
                byteCount += data.count
                entries[digest] = data
            }
            self.entries = entries
        }

        func data(from decoder: Decoder) throws -> Data {
            let container = try decoder.container(keyedBy: Field.self)
            guard container.allKeys.map(\.stringValue) == ["resourceSHA256"] else { throw ResourceError.invalidEnvelope }
            let digest = try container.decode(String.self, forKey: Field("resourceSHA256"))
            guard let data = entries[digest] else { throw ResourceError.missingResource(digest) }
            return data
        }
    }

    private struct ResourceReference: Encodable { let resourceSHA256: String }

    private struct Field: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ value: String) { stringValue = value }
        init?(stringValue: String) { self.init(stringValue) }
        init?(intValue: Int) { return nil }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
