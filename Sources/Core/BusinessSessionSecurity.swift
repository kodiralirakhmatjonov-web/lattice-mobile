import Foundation
import Security

struct BusinessInstallationIdentity {
    let id: String
    let secret: String
}

enum BusinessSessionVault {
    private static let service = "com.iumrah.business.device-security"
    private static let installationIDAccount = "installation-id-v1"
    private static let installationSecretAccount = "installation-secret-v1"
    private static let sessionTokenAccount = "business-session-token-v1"

    static func installationIdentity() throws -> BusinessInstallationIdentity {
        if let id = read(installationIDAccount),
           let secret = read(installationSecretAccount),
           !id.isEmpty, !secret.isEmpty {
            return BusinessInstallationIdentity(id: id, secret: secret)
        }

        let identity = BusinessInstallationIdentity(id: UUID().uuidString, secret: try randomToken())
        try write(identity.id, account: installationIDAccount)
        try write(identity.secret, account: installationSecretAccount)
        return identity
    }

    static var sessionToken: String? {
        guard let value = read(sessionTokenAccount), !value.isEmpty else { return nil }
        return value
    }

    static func setSessionToken(_ token: String) throws {
        try write(token, account: sessionTokenAccount)
    }

    static func clearSessionToken() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: sessionTokenAccount
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func write(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw BusinessSessionSecurityError.keychain(status) }

        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw BusinessSessionSecurityError.keychain(addStatus) }
    }

    private static func randomToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBufferPointer { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw BusinessSessionSecurityError.randomGeneration
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum BusinessSessionSecurityError: LocalizedError {
    case keychain(OSStatus)
    case randomGeneration

    var errorDescription: String? {
        switch self {
        case .keychain:
            return "Не удалось безопасно сохранить данные устройства в Keychain."
        case .randomGeneration:
            return "Не удалось создать защищённый идентификатор устройства."
        }
    }
}

enum BusinessDeviceDescriptor {
    static func registrationPayload(identity: BusinessInstallationIdentity) -> BusinessSessionRegistrationPayload {
        let hardware = hardwareIdentifier
        let model = friendlyModelName(for: hardware)
        let info = Bundle.main.infoDictionary
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return BusinessSessionRegistrationPayload(
            installationID: identity.id,
            installationSecret: identity.secret,
            deviceName: model,
            deviceModel: model,
            hardwareIdentifier: hardware,
            platform: "ios",
            osName: "iOS",
            osVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "",
            appBuild: info?["CFBundleVersion"] as? String ?? "",
            locale: Locale.current.identifier,
            timeZone: TimeZone.current.identifier
        )
    }

    private static var hardwareIdentifier: String {
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { buffer in
            let bytes = buffer.prefix { $0 != 0 }
            return String(bytes: bytes, encoding: .utf8) ?? "iPhone"
        }
    }

    private static func friendlyModelName(for identifier: String) -> String {
        let models: [String: String] = [
            "iPhone10,1": "iPhone 8", "iPhone10,4": "iPhone 8",
            "iPhone10,2": "iPhone 8 Plus", "iPhone10,5": "iPhone 8 Plus",
            "iPhone10,3": "iPhone X", "iPhone10,6": "iPhone X",
            "iPhone11,2": "iPhone XS", "iPhone11,4": "iPhone XS Max", "iPhone11,6": "iPhone XS Max",
            "iPhone11,8": "iPhone XR",
            "iPhone12,1": "iPhone 11", "iPhone12,3": "iPhone 11 Pro", "iPhone12,5": "iPhone 11 Pro Max",
            "iPhone12,8": "iPhone SE (2nd generation)",
            "iPhone13,1": "iPhone 12 mini", "iPhone13,2": "iPhone 12", "iPhone13,3": "iPhone 12 Pro", "iPhone13,4": "iPhone 12 Pro Max",
            "iPhone14,4": "iPhone 13 mini", "iPhone14,5": "iPhone 13", "iPhone14,2": "iPhone 13 Pro", "iPhone14,3": "iPhone 13 Pro Max",
            "iPhone14,6": "iPhone SE (3rd generation)",
            "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus", "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max",
            "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus", "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max",
            "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus", "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max",
            "iPhone17,5": "iPhone 16e",
            "i386": "iPhone Simulator", "x86_64": "iPhone Simulator", "arm64": "iPhone Simulator"
        ]
        return models[identifier] ?? (identifier.hasPrefix("iPhone") ? "iPhone" : "Apple device")
    }
}
