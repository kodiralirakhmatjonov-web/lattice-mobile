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

    func businessChatThreads() async throws -> [BusinessChatThreadSummary] {
        let (data, response) = try await session.data(from: AppConfig.apiBaseURL.appending(path: "/api/admin/hotels/chats"))
        try validate(response, data: data)
        return try decoder.decode(BusinessChatThreadsResponse.self, from: data).threads
    }

    func businessChatMessages(bookingID: String) async throws -> [BusinessChatMessage] {
        let url = AppConfig.apiBaseURL.appending(path: "/api/admin/hotels/chats/\(bookingID)/messages")
        let (data, response) = try await session.data(from: url)
        try validate(response, data: data)
        return try decoder.decode(BusinessChatMessagesResponse.self, from: data).messages
    }

    func sendBusinessChatMessage(bookingID: String, body: String, clientMessageID: String) async throws -> BusinessChatMessage {
        var request = URLRequest(url: AppConfig.apiBaseURL.appending(path: "/api/admin/hotels/chats/\(bookingID)/messages"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(SendBusinessChatMessagePayload(body: body, clientMessageID: clientMessageID))
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        return try decoder.decode(BusinessChatMessageResponse.self, from: data).message
    }

    func markBusinessChatRead(bookingID: String) async throws {
        var request = URLRequest(url: AppConfig.apiBaseURL.appending(path: "/api/admin/hotels/chats/\(bookingID)/read"))
        request.httpMethod = "POST"
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
    }

    func registerPushDevice(token: String, environment: String = "production") async throws -> PushDeviceRegistrationResponse {
        var request = URLRequest(url: AppConfig.apiBaseURL.appending(path: "/api/admin/hotels/push/devices"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(PushDeviceRegistrationPayload(deviceToken: token, environment: environment))
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        return try decoder.decode(PushDeviceRegistrationResponse.self, from: data)
    }

    func pushStatus() async throws -> PushStatusResponse {
        let (data, response) = try await session.data(from: AppConfig.apiBaseURL.appending(path: "/api/admin/hotels/push/status"))
        try validate(response, data: data)
        return try decoder.decode(PushStatusResponse.self, from: data)
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

    func checkHotelSourceDuplicate(_ sourceURL: String) async throws -> HotelDuplicate? {
        var request = URLRequest(url: AppConfig.apiBaseURL.appending(path: "/api/admin/hotels/dedupe"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(HotelSourceDuplicatePayload(sourceURL: sourceURL))
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        return try decoder.decode(HotelDuplicateResponse.self, from: data).duplicate
    }

    func checkHotelDuplicate(_ hotel: HotelDraft) async throws -> HotelDuplicate? {
        var request = URLRequest(url: AppConfig.apiBaseURL.appending(path: "/api/admin/hotels/dedupe"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(hotel)
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        return try decoder.decode(HotelDuplicateResponse.self, from: data).duplicate
    }

    func startHotelImport(
        _ hotel: HotelDraft,
        publishWhenComplete: Bool,
        idempotencyKey: String,
        allowPossibleDuplicate: Bool = false
    ) async throws -> HotelImportJob {
        var request = URLRequest(url: AppConfig.apiBaseURL.appending(path: "/api/admin/hotels/import-jobs"))
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        request.httpBody = try encoder.encode(
            HotelImportStartPayload(
                hotel: hotel,
                images: hotel.selectedImages,
                publishWhenComplete: publishWhenComplete,
                idempotencyKey: idempotencyKey,
                allowPossibleDuplicate: allowPossibleDuplicate
            )
        )
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 409,
           let conflict = try? decoder.decode(HotelImportConflictResponse.self, from: data),
           let duplicate = conflict.duplicate {
            if conflict.error == "POSSIBLE_DUPLICATE" { throw APIError.possibleDuplicate(duplicate) }
            throw APIError.hotelAlreadyExists(duplicate)
        }
        try validate(response, data: data)
        return try decoder.decode(HotelImportJobResponse.self, from: data).job
    }

    func hotelImportJob(id: String) async throws -> HotelImportJob {
        let url = AppConfig.apiBaseURL.appending(path: "/api/admin/hotels/import-jobs/\(id)")
        let (data, response) = try await session.data(from: url)
        try validate(response, data: data)
        return try decoder.decode(HotelImportJobResponse.self, from: data).job
    }

    func hotelImportJobs(activeOnly: Bool = false) async throws -> [HotelImportJob] {
        var components = URLComponents(url: AppConfig.apiBaseURL.appending(path: "/api/admin/hotels/import-jobs"), resolvingAgainstBaseURL: false)!
        if activeOnly { components.queryItems = [URLQueryItem(name: "active", value: "1")] }
        let (data, response) = try await session.data(from: components.url!)
        try validate(response, data: data)
        return try decoder.decode(HotelImportJobsResponse.self, from: data).jobs
    }

    func activeHotelImportJobs() async throws -> [HotelImportJob] {
        try await hotelImportJobs(activeOnly: true)
    }

    func retryHotelImportJob(id: String) async throws -> HotelImportJob {
        var request = URLRequest(url: AppConfig.apiBaseURL.appending(path: "/api/admin/hotels/import-jobs/\(id)/retry"))
        request.httpMethod = "POST"
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        return try decoder.decode(HotelImportJobResponse.self, from: data).job
    }

    func saveHotel(_ hotel: HotelDraft, allowPossibleDuplicate: Bool = false) async throws -> HotelListItem? {
        var request = URLRequest(url: AppConfig.apiBaseURL.appending(path: "/api/admin/hotels"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if allowPossibleDuplicate { request.setValue("1", forHTTPHeaderField: "X-Iumrah-Allow-Possible-Duplicate") }
        request.httpBody = try encoder.encode(hotel)
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 409,
           let conflict = try? decoder.decode(HotelImportConflictResponse.self, from: data),
           let duplicate = conflict.duplicate {
            if conflict.error == "POSSIBLE_DUPLICATE" { throw APIError.possibleDuplicate(duplicate) }
            throw APIError.hotelAlreadyExists(duplicate)
        }
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
        sourceRequest.timeoutInterval = 45
        sourceRequest.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        sourceRequest.setValue("image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        sourceRequest.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        sourceRequest.setValue(candidate.sourcePageURL, forHTTPHeaderField: "Referer")

        let (imageData, sourceResponse) = try await session.data(for: sourceRequest)
        guard let http = sourceResponse as? HTTPURLResponse, (200..<300).contains(http.statusCode), !imageData.isEmpty else {
            throw APIError.server("IMAGE_DOWNLOAD_FAILED")
        }
        let optimized = try ImageOptimizer.jpegData(from: imageData)

        var request = URLRequest(url: AppConfig.apiBaseURL.appending(path: "/api/admin/hotels/\(hotelID)/images"))
        request.httpMethod = "POST"
        request.timeoutInterval = 75
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.setValue(candidate.provider, forHTTPHeaderField: "X-Iumrah-Source")
        request.setValue(candidate.kind.rawValue, forHTTPHeaderField: "X-Iumrah-Category")
        request.setValue(candidate.sourcePageURL, forHTTPHeaderField: "X-Iumrah-Source-URL")
        if let label = candidate.label { request.setValue(String(label.prefix(480)), forHTTPHeaderField: "X-Iumrah-Label") }
        if let room = candidate.roomName { request.setValue(String(room.prefix(220)), forHTTPHeaderField: "X-Iumrah-Room") }
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
    case possibleDuplicate(HotelDuplicate)
    case hotelAlreadyExists(HotelDuplicate)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "Сессия администратора истекла. Войдите снова."
        case .invalidURL: return "Некорректная ссылка."
        case .invalidResponse: return "Сервер вернул некорректный ответ."
        case .possibleDuplicate(let hotel): return "Возможно, этот отель уже есть в базе: \(hotel.name)."
        case .hotelAlreadyExists(let hotel): return "Этот отель уже есть в базе: \(hotel.name)."
        case .server(let value): return value
        }
    }
}
