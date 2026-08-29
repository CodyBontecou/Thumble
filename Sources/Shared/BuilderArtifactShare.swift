import Foundation

/// A strict, non-persistable reference to one hosted-builder share.
///
/// The authorization token intentionally has no public accessor and this type does not conform
/// to Codable or CustomStringConvertible. Consumers may only derive the one HTTP header value.
public struct BuilderArtifactShareReference: Sendable, Equatable {
    public enum Policy: Sendable {
        case production
        case localTesting
    }

    public static let productionHost = "thumble-mcp-gateway.fly.dev"

    public let artifactID: String
    public let requestURL: URL
    public let sourceHost: String
    private let token: String

    var authorizationHeaderValue: String { "ThumbleShare \(token)" }

    public init(parsing value: String, policy: Policy = .production) throws {
        guard !value.isEmpty,
              value.utf8.count <= 2_048,
              value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              let components = URLComponents(string: value),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.percentEncodedQuery == nil,
              let scheme = components.scheme,
              let host = components.host,
              host == host.lowercased()
        else {
            throw BuilderArtifactShareError.invalidLink
        }

        let isProduction = scheme == "https"
            && host == Self.productionHost
            && components.port == nil
        let isLoopback = policy == .localTesting
            && (scheme == "http" || scheme == "https")
            && Self.loopbackHosts.contains(host)
            && components.port != nil
        guard isProduction || isLoopback else {
            throw BuilderArtifactShareError.unsupportedOrigin
        }

        let prefix = "/share/"
        let encodedPath = components.percentEncodedPath
        guard encodedPath.hasPrefix(prefix),
              !encodedPath.dropFirst(prefix.count).isEmpty,
              !encodedPath.dropFirst(prefix.count).contains("/"),
              !encodedPath.contains("%")
        else {
            throw BuilderArtifactShareError.invalidPath
        }
        let artifactID = String(encodedPath.dropFirst(prefix.count))
        guard Self.validArtifactID(artifactID) else {
            throw BuilderArtifactShareError.invalidArtifactID
        }

        guard let fragment = components.percentEncodedFragment,
              !fragment.contains("%"),
              fragment.hasPrefix("token="),
              !fragment.contains("&"),
              !fragment.contains(";"),
              fragment.filter({ $0 == "=" }).count == 1
        else {
            throw BuilderArtifactShareError.invalidToken
        }
        let token = String(fragment.dropFirst("token=".count))
        guard Self.isHex(token, count: 64) else {
            throw BuilderArtifactShareError.invalidToken
        }

        var requestComponents = components
        requestComponents.fragment = nil
        requestComponents.percentEncodedFragment = nil
        guard let requestURL = requestComponents.url,
              requestURL.fragment == nil,
              requestURL.query == nil,
              requestURL.absoluteString == "\(scheme)://\(host)\(components.port.map { ":\($0)" } ?? "")/share/\(artifactID)"
        else {
            throw BuilderArtifactShareError.invalidLink
        }

        self.artifactID = artifactID
        self.requestURL = requestURL
        sourceHost = host
        self.token = token
    }

    public static func resemblesHostedShare(_ value: String) -> Bool {
        let lowered = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isNetworkShare = (lowered.hasPrefix("https://") || lowered.hasPrefix("http://"))
            && lowered.contains("/share/")
        return isNetworkShare
            || lowered.contains(Self.productionHost)
            || lowered.contains("#token=")
    }

    private static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1", "[::1]"]

    private static func validArtifactID(_ value: String) -> Bool {
        value.count == 68
            && value.hasPrefix("bar_")
            && isHex(String(value.dropFirst(4)), count: 64)
    }

    private static func isHex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
        }
    }
}

public enum BuilderArtifactShareError: Error, Equatable, Sendable, LocalizedError {
    case invalidLink
    case unsupportedOrigin
    case invalidPath
    case invalidArtifactID
    case invalidToken

    public var errorDescription: String? {
        switch self {
        case .invalidLink: "This is not a valid Thumble shared-build link."
        case .unsupportedOrigin: "This shared-build link is from an unsupported server."
        case .invalidPath, .invalidArtifactID: "This shared-build link has an invalid artifact identifier."
        case .invalidToken: "This shared-build link has invalid authorization."
        }
    }
}
