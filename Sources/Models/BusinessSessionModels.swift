import Foundation

struct BusinessSessionRegistrationPayload: Encodable {
    let installationID: String
    let installationSecret: String
    let deviceName: String
    let deviceModel: String
    let hardwareIdentifier: String
    let platform: String
    let osName: String
    let osVersion: String
    let appVersion: String
    let appBuild: String
    let locale: String
    let timeZone: String
}

struct BusinessAccountSession: Decodable, Identifiable, Hashable {
    let id: String
    let deviceID: String
    let deviceName: String
    let deviceModel: String
    let hardwareIdentifier: String
    let platform: String
    let osName: String
    let osVersion: String
    let appVersion: String
    let appBuild: String
    let locale: String
    let timeZone: String
    let city: String
    let countryCode: String
    let isCurrent: Bool
    let isPrimary: Bool
    let trusted: Bool
    let trustLevel: String
    let createdAt: String
    let lastActiveAt: String
    let expiresAt: String
}

struct BusinessSessionRegistrationResponse: Decodable {
    let ok: Bool
    let sessionToken: String?
    let currentSession: BusinessAccountSession
}

struct BusinessSessionsResponse: Decodable {
    let ok: Bool
    let currentSessionID: String
    let sessions: [BusinessAccountSession]
    let inactivityDays: Int
    let policy: String
}

struct BusinessSessionActionResponse: Decodable {
    let ok: Bool
    let signedOut: Bool?
}
