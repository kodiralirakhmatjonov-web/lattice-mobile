import Foundation

actor APIClient {
    static let shared = APIClient()

    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = HTTPCookieStorage.shared
        configuration.httpShouldSetCookies = true
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
        decoder = JSONDecoder()
        encoder = JSONEncoder()
    }

    func login(login: String, password: String) async throws -> SessionUser {
        var request = URLRequest(url: AppConfig.apiBaseURL.appending(path: "/api/auth/staff/login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["login": login, "password": password])
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        let result = try decoder.decode(LoginResponse.self, from: data)
        guard result.ok == true, let resolvedLogin = result.login else { throw APIError.server(result.error ?? "LOGIN_FAILED") }
        return SessionUser(login: resolvedLogin, role: result.role ?? "superadmin", displayName: "Super Administrator")
    }

    func sessionUser() async throws -> SessionUser {
        let (data, response) = try await session.data(from: AppConfig.apiBaseURL.appending(path: "/api/auth/staff/session"))
        try validate(response, data: data)
        let value = try decoder.decode(SessionResponse.self, from: data)
        guard let user = value.user else { throw APIError.unauthorized }
        return user
    }

    func logout() async {
        var request = URLRequest(url: AppConfig.apiBaseURL.appending(path: "/api/auth/staff/logout"))
        request.httpMethod = "POST"
        _ = try? await session.data(for: request)
        HTTPCookieStorage.shared.cookies?.forEach { cookie in
            if cookie.domain.contains("iumrah.app") { HTTPCookieStorage.shared.deleteCookie(cookie) }
        }
    }

    func bookings() async throws -> [BookingSummary] {
        let (data, response) = try await session.data(from: AppConfig.apiBaseURL.appending(path: "/api/admin/bookings"))
        try validate(response, data: data)
        return try decoder.decode(BookingsResponse.self, from: data).bookings
    }

    func chats() async throws -> [ChatThread] {
        let (data, response) = try await session.data(from: AppConfig.apiBaseURL.appending(path: "/api/admin/chats"))
        try validate(response, data: data)
        return try decoder.decode(ChatsResponse.self, from: data).threads
    }

    func hotels() async throws -> [HotelListItem] {
        let (data, response) = try await session.data(from: AppConfig.apiBaseURL.appending(path: "/api/admin/hotels"))
        try validate(response, data: data)
        return try decoder.decode(HotelsResponse.self, from: data).hotels
    }

    func hotelCloudHealth() async throws -> HotelCloudHealthResponse {
        let (data, response) = try await session.data(from: AppConfig.apiBaseURL.appending(path: "/api/admin/hotels/health"))
        try validate(response, data: data)
        return try decoder.decode(HotelCloudHealthResponse.self, from: data)
    }

    func saveHotel(_ hotel: HotelDraft) async throws -> HotelListItem? {
        var request = URLRequest(url: AppConfig.apiBaseURL.appending(path: "/api/admin/hotels"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(hotel)
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        return try decoder.decode(HotelSaveResponse.self, from: data).hotel
    }

    func clearHotelImages(hotelID: String) async throws {
        var request = URLRequest(url: AppConfig.apiBaseURL.appending(path: "/api/admin/hotels/\(hotelID)/images"))
        request.httpMethod = "DELETE"
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
    }

    func uploadHotelImage(hotelID: String, candidate: HotelImageCandidate, position: Int) async throws {
        guard let sourceURL = URL(string: candidate.url) else { throw APIError.invalidURL }
        var sourceRequest = URLRequest(url: sourceURL)
        sourceRequest.timeoutInterval = 30
        sourceRequest.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        let (imageData, sourceResponse) = try await session.data(for: sourceRequest)
        guard let http = sourceResponse as? HTTPURLResponse, (200..<300).contains(http.statusCode), !imageData.isEmpty else {
            throw APIError.server("IMAGE_DOWNLOAD_FAILED")
        }
        let optimized = try ImageOptimizer.jpegData(from: imageData)

        var request = URLRequest(url: AppConfig.apiBaseURL.appending(path: "/api/admin/hotels/\(hotelID)/images"))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.setValue(candidate.provider, forHTTPHeaderField: "X-Iumrah-Source")
        request.setValue(candidate.kind.rawValue, forHTTPHeaderField: "X-Iumrah-Category")
        request.setValue(String(position), forHTTPHeaderField: "X-Iumrah-Position")
        request.setValue(candidate.isCover ? "1" : "0", forHTTPHeaderField: "X-Iumrah-Cover")
        request.httpBody = optimized
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
    }

    private func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        if http.statusCode == 401 { throw APIError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw APIError.server(message ?? "HTTP_\(http.statusCode)")
        }
    }
}

enum APIError: LocalizedError {
    case unauthorized
    case invalidURL
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "Сессия администратора истекла. Войдите снова."
        case .invalidURL: return "Некорректная ссылка."
        case .invalidResponse: return "Сервер вернул некорректный ответ."
        case .server(let value): return value
        }
    }
}
