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
        let (data, response) = try await session.data(from: AppConfig.apiBaseURL.appending(path: "/api/admin/hotels/operations/bookings"))
        try validate(response, data: data)
        return try decoder.decode(BookingsResponse.self, from: data).bookings
    }

    func businessProfile() async throws -> BusinessTeamMember {
        let url = AppConfig.apiBaseURL.appending(path: "/api/admin/hotels/operations/me")
        let (data, response) = try await session.data(from: url)
        try validate(response, data: data)
        return try decoder.decode(BusinessTeamMemberResponse.self, from: data).member
    }

    func saveBusinessProfile(_ member: BusinessTeamMember) async throws -> BusinessTeamMember {
        var request = URLRequest(url: AppConfig.apiBaseURL.appending(path: "/api/admin/hotels/operations/me"))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(BusinessTeamMemberPayload(member))
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        return try decoder.decode(BusinessTeamMemberResponse.self, from: data).member
    }

    func businessTeam() async throws -> [BusinessTeamMember] {
        let url = AppConfig.apiBaseURL.appending(path: "/api/admin/hotels/operations/team")
        let (data, response) = try await session.data(from: url)
        try validate(response, data: data)
        return try decoder.decode(BusinessTeamResponse.self, from: data).members
    }

    func createBusinessTeamMember(_ member: BusinessTeamMember) async throws -> BusinessTeamMember {
        var request = URLRequest(url: AppConfig.apiBaseURL.appending(path: "/api/admin/hotels/operations/team"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(BusinessTeamMemberPayload(member))
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        return try decoder.decode(BusinessTeamMemberResponse.self, from: data).member
    }

    func updateBusinessTeamMember(_ member: BusinessTeamMember) async throws -> BusinessTeamMember {
        var request = URLRequest(url: AppConfig.apiBaseURL.appending(path: "/api/admin/hotels/operations/team/\(member.id)"))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(BusinessTeamMemberPayload(member))
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        return try decoder.decode(BusinessTeamMemberResponse.self, from: data).member
    }

    func uploadBusinessTeamPhoto(memberID: String, imageData: Data) async throws -> BusinessTeamMember {
        let optimized = try ImageOptimizer.jpegData(from: imageData, maxDimension: 1200, quality: 0.80, targetBytes: 500_000)
        var request = URLRequest(url: AppConfig.apiBaseURL.appending(path: "/api/admin/hotels/operations/team/\(memberID)/photo"))
        request.httpMethod = "POST"
        request.timeoutInterval = 75
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.httpBody = optimized
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        return try decoder.decode(BusinessTeamMemberResponse.self, from: data).member
    }

    func deleteBusinessTeamPhoto(memberID: String) async throws -> BusinessTeamMember {
        var request = URLRequest(url: AppConfig.apiBaseURL.appending(path: "/api/admin/hotels/operations/team/\(memberID)/photo"))
        request.httpMethod = "DELETE"
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        return try decoder.decode(BusinessTeamMemberResponse.self, from: data).member
    }

    func deleteBusinessTeamMember(id: String) async throws {
        var request = URLRequest(url: AppConfig.apiBaseURL.appending(path: "/api/admin/hotels/operations/team/\(id)"))
        request.httpMethod = "DELETE"
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
    }

    func bookingDetail(id: String) async throws -> BookingDetailResponse {
        let url = AppConfig.apiBaseURL.appending(path: "/api/admin/hotels/operations/bookings/\(id)")
        let (data, response) = try await session.data(from: url)
        try validate(response, data: data)
        return try decoder.decode(BookingDetailResponse.self, from: data)
    }

    func updateBookingOperation(id: String, status: TripStatus, paymentStatus: String, confirmationNumber: String, internalNotes: String) async throws -> BookingDetailResponse {
        var request = URLRequest(url: AppConfig.apiBaseURL.appending(path: "/api/admin/hotels/operations/bookings/\(id)"))
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(BookingOperationUpdatePayload(status: status.rawValue, paymentStatus: paymentStatus, confirmationNumber: confirmationNumber, internalNotes: internalNotes))
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        return try decoder.decode(BookingDetailResponse.self, from: data)
    }

    func savePaymentInstructions(bookingID: String, payload: BusinessPaymentInstructionsPayload) async throws -> BusinessCheckout {
        var request = URLRequest(url: AppConfig.apiBaseURL.appending(path: "/api/admin/hotels/operations/bookings/\(bookingID)/payment"))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(payload)
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        struct Envelope: Decodable { let ok: Bool; let checkout: BusinessCheckout }
        return try decoder.decode(Envelope.self, from: data).checkout
    }

    func uploadPaymeQR(bookingID: String, data: Data, contentType: String = "image/jpeg") async throws {
        var request = URLRequest(url: AppConfig.apiBaseURL.appending(path: "/api/admin/hotels/operations/bookings/\(bookingID)/payment-qr"))
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let (body, response) = try await session.data(for: request)
        try validate(response, data: body)
    }

    func uploadTravelDocument(bookingID: String, kind: String, title: String, data: Data, contentType: String) async throws {
        var components = URLComponents(url: AppConfig.apiBaseURL.appending(path: "/api/admin/hotels/operations/bookings/\(bookingID)/documents"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "kind", value: kind), URLQueryItem(name: "title", value: title)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let (body, response) = try await session.data(for: request)
        try validate(response, data: body)
    }

    func privateMedia(path: String) async throws -> Data {
        let url: URL
        if let direct = URL(string: path), direct.scheme != nil { url = direct }
        else { url = AppConfig.apiBaseURL.appending(path: path) }
        let (data, response) = try await session.data(from: url)
        try validate(response, data: data)
        return data
    }

    func deleteBooking(id: String) async throws {
        var request = URLRequest(url: AppConfig.apiBaseURL.appending(path: "/api/admin/hotels/operations/bookings/\(id)"))
        request.httpMethod = "DELETE"
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        _ = try? decoder.decode(BookingDeleteResponse.self, from: data)
    }

    func verifyFlight(number: String, dateLocal: String, force: Bool = false) async throws -> FlightVerificationResponse {
        var request = URLRequest(url: AppConfig.apiBaseURL.appending(path: "/api/admin/hotels/operations/flight-verify"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(FlightVerificationPayload(flightNumber: number, dateLocal: dateLocal, force: force))
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        return try decoder.decode(FlightVerificationResponse.self, from: data)
    }

    func saveVerifiedFlight(bookingID: String, direction: BookingFlightDirection, verificationKey: String, candidateID: String) async throws -> BookingFlight {
        var request = URLRequest(url: AppConfig.apiBaseURL.appending(path: "/api/admin/hotels/operations/bookings/\(bookingID)/flights/\(direction.rawValue)"))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(SaveVerifiedFlightPayload(verificationKey: verificationKey, candidateID: candidateID))
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        return try decoder.decode(BookingFlightResponse.self, from: data).flight
    }

    func updateBookingAssignment(bookingID: String, makkahHotelID: String?, madinahHotelID: String?, guideID: String?) async throws -> BookingAssignment {
        var request = URLRequest(url: AppConfig.apiBaseURL.appending(path: "/api/admin/hotels/operations/bookings/\(bookingID)/assignments"))
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(BookingAssignmentPayload(makkahHotelID: makkahHotelID, madinahHotelID: madinahHotelID, guideID: guideID))
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        return try decoder.decode(BookingAssignmentResponse.self, from: data).assignment
    }

    func pilgrims(archiveOnly: Bool = false, query: String? = nil) async throws -> [PilgrimSummary] {
        var components = URLComponents(url: AppConfig.apiBaseURL.appending(path: "/api/admin/hotels/operations/pilgrims"), resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = []
        if archiveOnly { items.append(URLQueryItem(name: "archive", value: "1")) }
        if let query, !query.isEmpty { items.append(URLQueryItem(name: "q", value: query)) }
        components.queryItems = items.isEmpty ? nil : items
        let (data, response) = try await session.data(from: components.url!)
        try validate(response, data: data)
        return try decoder.decode(PilgrimsResponse.self, from: data).pilgrims
    }

    func pilgrimDetail(id: String) async throws -> PilgrimDetailResponse {
        let url = AppConfig.apiBaseURL.appending(path: "/api/admin/hotels/operations/pilgrims/\(id)")
        let (data, response) = try await session.data(from: url)
        try validate(response, data: data)
        return try decoder.decode(PilgrimDetailResponse.self, from: data)
    }

    func primaryHotels(city: String? = nil) async throws -> [PrimaryHotelAssignment] {
        var components = URLComponents(url: AppConfig.apiBaseURL.appending(path: "/api/admin/hotels/operations/primary-hotels"), resolvingAgainstBaseURL: false)!
        if let city { components.queryItems = [URLQueryItem(name: "city", value: city)] }
        let (data, response) = try await session.data(from: components.url!)
        try validate(response, data: data)
        return try decoder.decode(PrimaryHotelsResponse.self, from: data).assignments
    }

    func savePrimaryHotels(city: String, stars: Int, hotelIDs: [String]) async throws -> [PrimaryHotelAssignment] {
        var request = URLRequest(url: AppConfig.apiBaseURL.appending(path: "/api/admin/hotels/operations/primary-hotels"))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(PrimaryHotelsUpdatePayload(city: city, stars: stars, hotelIDs: hotelIDs))
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        return try decoder.decode(PrimaryHotelsResponse.self, from: data).assignments
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

    func sendBusinessChatImage(bookingID: String, data: Data) async throws -> BusinessChatMessage {
        var request = URLRequest(url: AppConfig.apiBaseURL.appending(path: "/api/admin/hotels/chats/\(bookingID)/attachments"))
        request.httpMethod = "POST"
        request.timeoutInterval = 75
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let (responseData, response) = try await session.data(for: request)
        try validate(response, data: responseData)
        return try decoder.decode(BusinessChatMessageResponse.self, from: responseData).message
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

    func recoverSourceRooms(sourceURL: String) async throws -> SourceRoomRecoveryResponse {
        var request = URLRequest(url: AppConfig.apiBaseURL.appending(path: "/api/admin/hotels/source-rooms"))
        request.httpMethod = "POST"
        request.timeoutInterval = 35
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(SourceRoomRecoveryPayload(sourceURL: sourceURL))
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        return try decoder.decode(SourceRoomRecoveryResponse.self, from: data)
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

    func cancelHotelImportJob(id: String) async throws -> HotelImportJob {
        var request = URLRequest(url: AppConfig.apiBaseURL.appending(path: "/api/admin/hotels/import-jobs/\(id)/cancel"))
        request.httpMethod = "POST"
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        return try decoder.decode(HotelImportJobResponse.self, from: data).job
    }

    func deleteHotelImportJob(id: String) async throws {
        var request = URLRequest(url: AppConfig.apiBaseURL.appending(path: "/api/admin/hotels/import-jobs/\(id)"))
        request.httpMethod = "DELETE"
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
    }

    func deleteHotel(id: String) async throws {
        var request = URLRequest(url: AppConfig.apiBaseURL.appending(path: "/api/admin/hotels/\(id)"))
        request.httpMethod = "DELETE"
        request.timeoutInterval = 45
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
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
        case .server(let value):
            switch value {
            case "PAYMENT_INSTRUCTIONS_REQUIRED": return "Сначала сохраните хотя бы один способ оплаты: Visa, PayMe или Humo."
            case "IUMRAH_ACCOUNT_REQUIRED": return "Паломник ещё не активировал свой iumrah ID и пароль."
            case "TRAVELER_DATA_INCOMPLETE": return "Не все анкеты паломников заполнены полностью и с паспортом."
            case "PAYMENT_RECEIPT_REQUIRED": return "Паломник ещё не прикрепил чек оплаты."
            case "TRAVEL_DOCUMENT_REQUIRED": return "Перед статусом «Готово к поездке» загрузите хотя бы один документ поездки."
            case "INVALID_STATUS_TRANSITION": return "Этот переход статуса недоступен из текущего состояния поездки."
            default: return value
            }
        }
    }
}
