import Foundation

enum AppConfig {
    static let apiBaseURL = URL(string: "https://iumrah.app")!
    static let appName = "iumrah Business"
    static let buildChannel = "TestFlight"

    static func absoluteURL(_ value: String?) -> URL? {
        guard let value, !value.isEmpty else { return nil }
        if let direct = URL(string: value), direct.scheme != nil { return direct }
        return URL(string: value, relativeTo: apiBaseURL)?.absoluteURL
    }
}
