import Foundation
import Security
import UIKit
import Darwin

struct BusinessInstallationIdentity {
    let id: String
    let secret: String
}

enum BusinessSessionVault {
    private static let service = "com.iumrah.business.device-security"
    private static let installationIDAccount = "installation-id-v1"
    private static let installationSecretAccount = "installation-secret-v1"
    private static let sessionTokenAccount = "business-session-token-v1"
    private static let flightSyncURLAccount = "chatgpt-flight-sync-url-v1"
    private static let hotelSyncMakkahURLAccount = "chatgpt-hotel-sync-makkah-url-v2"
    private static let hotelSyncMadinahURLAccount = "chatgpt-hotel-sync-madinah-url-v2"

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


    static var flightSyncAccessURL: URL? {
        guard let value = read(flightSyncURLAccount), !value.isEmpty else { return nil }
        return URL(string: value)
    }

    static func setFlightSyncAccessURL(_ url: URL) throws {
        try write(url.absoluteString, account: flightSyncURLAccount)
    }

    static func clearFlightSyncAccessURL() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: flightSyncURLAccount
        ]
        SecItemDelete(query as CFDictionary)
    }


    static func hotelSyncAccessURL(city: String) -> URL? {
        let account = hotelSyncAccount(city: city)
        guard let account, let value = read(account), !value.isEmpty else { return nil }
        return URL(string: value)
    }

    static func setHotelSyncAccessURL(_ url: URL, city: String) throws {
        guard let account = hotelSyncAccount(city: city) else { return }
        try write(url.absoluteString, account: account)
    }

    static func clearHotelSyncAccessURL(city: String) {
        guard let account = hotelSyncAccount(city: city) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func hotelSyncAccount(city: String) -> String? {
        switch city.lowercased() {
        case "makkah", "mecca": return hotelSyncMakkahURLAccount
        case "madinah", "medina": return hotelSyncMadinahURLAccount
        default: return nil
        }
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
        let info = Bundle.main.infoDictionary
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let descriptor = currentDevice
        return BusinessSessionRegistrationPayload(
            installationID: identity.id,
            installationSecret: identity.secret,
            deviceName: descriptor.name,
            deviceModel: descriptor.model,
            hardwareIdentifier: descriptor.hardwareIdentifier,
            platform: descriptor.platform,
            osName: descriptor.osName,
            osVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "",
            appBuild: info?["CFBundleVersion"] as? String ?? "",
            locale: Locale.current.identifier,
            timeZone: TimeZone.current.identifier
        )
    }

    private struct Descriptor {
        let name: String
        let model: String
        let hardwareIdentifier: String
        let platform: String
        let osName: String
    }

    private static var currentDevice: Descriptor {
#if targetEnvironment(macCatalyst)
        let hardware = macHardwareIdentifier
        let model = friendlyMacModelName(identifier: hardware, hostName: ProcessInfo.processInfo.hostName)
        return Descriptor(
            name: model,
            model: model,
            hardwareIdentifier: hardware,
            platform: "macos",
            osName: "macOS"
        )
#else
        let rawHardware = hardwareIdentifier
#if targetEnvironment(simulator)
        let simulatedHardware = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? rawHardware
        let simulatedModel = friendlyAppleMobileModelName(for: simulatedHardware)
        let model = simulatedModel == "Apple device" ? "iOS Simulator" : "\(simulatedModel) Simulator"
        return Descriptor(
            name: model,
            model: model,
            hardwareIdentifier: simulatedHardware,
            platform: "ios-simulator",
            osName: UIDevice.current.userInterfaceIdiom == .pad ? "iPadOS" : "iOS"
        )
#else
        let model = friendlyAppleMobileModelName(for: rawHardware)
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        return Descriptor(
            name: model,
            model: model,
            hardwareIdentifier: rawHardware,
            platform: isPad ? "ipados" : "ios",
            osName: isPad ? "iPadOS" : "iOS"
        )
#endif
#endif
    }

    private static var hardwareIdentifier: String {
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { buffer in
            let bytes = buffer.prefix { $0 != 0 }
            return String(bytes: bytes, encoding: .utf8) ?? "Apple"
        }
    }

    private static var macHardwareIdentifier: String {
        var size: size_t = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 1 else {
            return hardwareIdentifier
        }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else {
            return hardwareIdentifier
        }
        return String(cString: bytes)
    }

    private static func friendlyMacModelName(identifier: String, hostName: String) -> String {
        let host = hostName.lowercased().replacingOccurrences(of: "-", with: " ")
        if host.contains("macbook pro") { return "MacBook Pro" }
        if host.contains("macbook air") { return "MacBook Air" }
        if host.contains("mac mini") { return "Mac mini" }
        if host.contains("mac studio") { return "Mac Studio" }
        if host.contains("mac pro") { return "Mac Pro" }
        if host.contains("imac") { return "iMac" }

        if identifier.hasPrefix("MacBookPro") { return "MacBook Pro" }
        if identifier.hasPrefix("MacBookAir") { return "MacBook Air" }
        if identifier.hasPrefix("MacBook") { return "MacBook" }
        if identifier.hasPrefix("Macmini") { return "Mac mini" }
        if identifier.hasPrefix("MacPro") { return "Mac Pro" }
        if identifier.hasPrefix("iMacPro") { return "iMac Pro" }
        if identifier.hasPrefix("iMac") { return "iMac" }

        // Apple silicon generations that use the generic MacXX,Y identifiers.
        // These mappings intentionally resolve the product family only; the raw
        // identifier is still sent to the server for future exact model mapping.
        let macStudio: Set<String> = ["Mac13,1", "Mac13,2", "Mac14,13", "Mac14,14"]
        let macMini: Set<String> = ["Mac14,3", "Mac14,12", "Mac16,10", "Mac16,11"]
        let macPro: Set<String> = ["Mac14,8"]
        let iMac: Set<String> = ["Mac15,4", "Mac15,5"]
        let macBookAir: Set<String> = ["Mac14,2", "Mac14,15", "Mac15,12", "Mac15,13", "Mac16,12", "Mac16,13"]
        let macBookPro: Set<String> = [
            "Mac14,5", "Mac14,6", "Mac14,7", "Mac14,9", "Mac14,10",
            "Mac15,3", "Mac15,6", "Mac15,7", "Mac15,8", "Mac15,9", "Mac15,10", "Mac15,11",
            "Mac16,1", "Mac16,5", "Mac16,6", "Mac16,7", "Mac16,8"
        ]
        if macStudio.contains(identifier) { return "Mac Studio" }
        if macMini.contains(identifier) { return "Mac mini" }
        if macPro.contains(identifier) { return "Mac Pro" }
        if iMac.contains(identifier) { return "iMac" }
        if macBookAir.contains(identifier) { return "MacBook Air" }
        if macBookPro.contains(identifier) { return "MacBook Pro" }
        return "Mac"
    }

    private static func friendlyAppleMobileModelName(for identifier: String) -> String {
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
            "iPad13,18": "iPad (10th generation)", "iPad13,19": "iPad (10th generation)",
            "iPad14,3": "iPad Pro 11-inch", "iPad14,4": "iPad Pro 11-inch",
            "iPad14,5": "iPad Pro 12.9-inch", "iPad14,6": "iPad Pro 12.9-inch",
            "iPad14,8": "iPad Air 11-inch", "iPad14,9": "iPad Air 11-inch",
            "iPad14,10": "iPad Air 13-inch", "iPad14,11": "iPad Air 13-inch",
            "iPad16,3": "iPad Pro 11-inch", "iPad16,4": "iPad Pro 11-inch",
            "iPad16,5": "iPad Pro 13-inch", "iPad16,6": "iPad Pro 13-inch"
        ]
        if let known = models[identifier] { return known }
        if identifier.hasPrefix("iPhone") { return "iPhone (\(identifier))" }
        if identifier.hasPrefix("iPad") { return "iPad (\(identifier))" }
        if identifier.hasPrefix("iPod") { return "iPod touch" }
        return "Apple device"
    }
}


extension Notification.Name {
    static let iumrahBusinessSessionInvalidated = Notification.Name("iumrah.business.security.sessionInvalidated")
    static let iumrahBusinessSecurityNewSession = Notification.Name("iumrah.business.security.newSession")
}
