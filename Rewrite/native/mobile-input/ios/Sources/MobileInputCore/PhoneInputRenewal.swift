import Foundation

/// Native receipt context. The expired context cannot authorize its own successor.
struct PhoneInputRenewalScope {
  let sessionID: String
  let udpPort: UInt16
  let authorizationExpiresAt: UInt64
  let credentialExpiresAt: UInt64
}

/// Explicit version-six decoding. Ordinary version-four/five grants reject this shape.
struct PhoneInputRenewal {
  let grant: PhoneInputGrant
  let authorizationExpiresAt: UInt64

  init(
    _ value: [String: EnrollmentJSON.Value], connection: String, map: ControlMap,
    scope: PhoneInputRenewalScope, now: UInt64
  ) throws {
    guard value["command"] == .string("input-renewed"),
      value["replacesSessionId"] == .string(scope.sessionID),
      value["sessionId"] != .string(scope.sessionID),
      now < scope.authorizationExpiresAt,
      case .integer(let expires)? = value["authorizationExpiresAt"],
      expires >= scope.authorizationExpiresAt, expires <= scope.credentialExpiresAt,
      expires <= UInt64(Int64.max), expires > now
    else { throw PhoneControlError.rejected }
    var base = value
    base.removeValue(forKey: "replacesSessionId")
    base.removeValue(forKey: "authorizationExpiresAt")
    base["command"] = .string("input-granted")
    grant = try PhoneInputGrant(base, connection: connection, map: map, datagrams: true)
    guard grant.udpPort == scope.udpPort else { throw PhoneControlError.rejected }
    authorizationExpiresAt = expires
  }
}
