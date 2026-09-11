import Foundation

extension APIClient {
    func hotelSyncStatus(city: String) async throws -> BusinessHotelSyncStatusResponse {
        let slug = try hotelSyncCitySlug(city)
        let url = AppConfig.apiBaseURL.appending(path: "/api/admin/hotels/operations/hotel-sync/\(slug)")
        let (data, response) = try await perform(from: url)
        try validate(response, data: data)
        return try decoder.decode(BusinessHotelSyncStatusResponse.self, from: data)
    }

    func rotateHotelSyncAccess(city: String) async throws -> BusinessHotelSyncAccessResponse {
        let slug = try hotelSyncCitySlug(city)
        var request = URLRequest(url: AppConfig.apiBaseURL.appending(path: "/api/admin/hotels/operations/hotel-sync/\(slug)/access"))
        request.httpMethod = "POST"
        let (data, response) = try await perform(request)
        try validate(response, data: data)
        return try decoder.decode(BusinessHotelSyncAccessResponse.self, from: data)
    }

    func revokeHotelSyncAccess(city: String) async throws -> BusinessHotelSyncRevokeResponse {
        let slug = try hotelSyncCitySlug(city)
        var request = URLRequest(url: AppConfig.apiBaseURL.appending(path: "/api/admin/hotels/operations/hotel-sync/\(slug)/access"))
        request.httpMethod = "DELETE"
        let (data, response) = try await perform(request)
        try validate(response, data: data)
        return try decoder.decode(BusinessHotelSyncRevokeResponse.self, from: data)
    }

    func saveHotelSyncSnapshot(city: String, checkIn: Date) async throws -> BusinessHotelSyncSnapshotResponse {
        let canonicalCity = try hotelSyncCanonicalCity(city)
        let slug = try hotelSyncCitySlug(city)
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.startOfDay(for: checkIn)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else {
            throw APIError.server("INVALID_MONITORING_DATE")
        }
        let checkInText = hotelSyncDateString(start)
        let checkOutText = hotelSyncDateString(end)

        let catalog = try await hotels()
        let selected = catalog
            .filter { (try? hotelSyncCanonicalCity($0.city)) == canonicalCity }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let snapshotID = "hotel-sync-\(slug)-\(UUID().uuidString.lowercased())"
        let monitoring = BusinessHotelSyncMonitoring(
            checkIn: checkInText,
            checkOut: checkOutText,
            rooms: 1,
            adults: 2,
            children: 0,
            currency: "USD",
            priceBasis: "nightly"
        )
        let syncHotels = selected.map { hotel in
            let source = hotel.sourceURL ?? hotel.price?.sourceURL
            let provider = normalizedHotelSyncProvider(hotel.sourceProvider ?? hotel.price?.provider, sourceURL: source)
            return BusinessHotelSyncHotel(
                hotelID: hotel.id,
                hotelName: hotel.name,
                city: canonicalCity,
                stars: hotel.stars,
                currentNightlyUSD: roundedHotelSyncPrice(hotel.price?.nightlyUSD),
                currency: "USD",
                catalogStatus: hotel.status,
                priceStatus: hotel.price?.status,
                isManualOverride: hotel.price?.isManualOverride ?? false,
                provider: provider,
                sourceURL: source,
                monitoringURL: hotelMonitoringURL(sourceURL: source, provider: provider, checkIn: checkInText, checkOut: checkOutText),
                lastPriceFetchedAt: hotel.price?.fetchedAt
            )
        }

        let payload = BusinessHotelSyncSnapshotPayload(
            city: canonicalCity,
            snapshotID: snapshotID,
            monitoring: monitoring,
            hotels: syncHotels
        )

        var request = URLRequest(url: AppConfig.apiBaseURL.appending(path: "/api/admin/hotels/operations/hotel-sync/\(slug)/snapshot"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(payload)
        let (data, response) = try await perform(request)
        try validate(response, data: data)
        return try decoder.decode(BusinessHotelSyncSnapshotResponse.self, from: data)
    }

    func setVerifiedHotelPrice(id: String, payload: HotelVerifiedPriceUpdatePayload) async throws -> HotelPriceResponse {
        var request = URLRequest(url: AppConfig.apiBaseURL.appending(path: "/api/admin/hotels/\(id)/price/verified"))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(payload)
        let (data, response) = try await perform(request)
        try validate(response, data: data)
        return try decoder.decode(HotelPriceResponse.self, from: data)
    }

    private func hotelSyncCanonicalCity(_ value: String) throws -> String {
        let raw = value.lowercased().replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        if raw.contains("makkah") || raw.contains("mecca") || raw.contains("مكة") { return "Makkah" }
        if raw.contains("madinah") || raw.contains("medina") || raw.contains("المدينة") { return "Madinah" }
        throw APIError.server("INVALID_HOTEL_SYNC_CITY")
    }

    private func hotelSyncCitySlug(_ value: String) throws -> String {
        switch try hotelSyncCanonicalCity(value) {
        case "Makkah": return "makkah"
        case "Madinah": return "madinah"
        default: throw APIError.server("INVALID_HOTEL_SYNC_CITY")
        }
    }

    private func hotelSyncDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func roundedHotelSyncPrice(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0, value <= 10_000 else { return nil }
        return (value * 100).rounded() / 100
    }

    private func normalizedHotelSyncProvider(_ value: String?, sourceURL: String?) -> String? {
        let raw = (value ?? "").lowercased()
        if raw.contains("booking") { return "Booking" }
        if raw.contains("expedia") { return "Expedia" }
        if let host = URL(string: sourceURL ?? "")?.host?.lowercased() {
            if host == "booking.com" || host.hasSuffix(".booking.com") { return "Booking" }
            if host == "expedia.com" || host.hasSuffix(".expedia.com") || host.contains("expedia.") { return "Expedia" }
        }
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    private func hotelMonitoringURL(sourceURL: String?, provider: String?, checkIn: String, checkOut: String) -> String? {
        guard let sourceURL, var components = URLComponents(string: sourceURL) else { return sourceURL }
        var items = components.queryItems ?? []

        func remove(_ names: Set<String>) {
            items.removeAll { names.contains($0.name.lowercased()) }
        }
        func put(_ name: String, _ value: String) {
            items.append(URLQueryItem(name: name, value: value))
        }

        switch provider {
        case "Booking":
            remove(["checkin", "checkout", "group_adults", "group_children", "no_rooms", "req_adults", "req_children", "room1", "selected_currency", "cur_currency", "lang"])
            put("checkin", checkIn)
            put("checkout", checkOut)
            put("group_adults", "2")
            put("group_children", "0")
            put("no_rooms", "1")
            put("req_adults", "2")
            put("req_children", "0")
            put("room1", "A,A")
            put("selected_currency", "USD")
            put("cur_currency", "USD")
            put("lang", "en-us")
        case "Expedia":
            remove(["startdate", "enddate", "chkin", "chkout", "rm1", "currency", "top_cur", "langid", "locale"])
            put("chkin", checkIn)
            put("chkout", checkOut)
            put("rm1", "a2")
            put("currency", "USD")
            put("top_cur", "USD")
            put("langid", "1033")
            put("locale", "en_US")
        default:
            return sourceURL
        }

        components.queryItems = items
        return components.url?.absoluteString ?? sourceURL
    }
}
