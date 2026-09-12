import Foundation

extension APIClient {
    func hotelSyncStatus(city: String) async throws -> BusinessHotelSyncStatusResponse {
        guard let canonical = hotelSyncCanonicalCity(city) else { throw APIError.server("HOTEL_SYNC_INVALID_CITY") }
        let slug = canonical.lowercased()
        let url = AppConfig.apiBaseURL.appending(path: "/api/admin/hotels/operations/hotel-sync/\(slug)")
        let (data, response) = try await perform(from: url)
        try validate(response, data: data)
        return try decoder.decode(BusinessHotelSyncStatusResponse.self, from: data)
    }

    func rotateHotelSyncAccess(city: String) async throws -> BusinessHotelSyncAccessResponse {
        guard let canonical = hotelSyncCanonicalCity(city) else { throw APIError.server("HOTEL_SYNC_INVALID_CITY") }
        var request = URLRequest(url: AppConfig.apiBaseURL.appending(path: "/api/admin/hotels/operations/hotel-sync/\(canonical.lowercased())/access"))
        request.httpMethod = "POST"
        let (data, response) = try await perform(request)
        try validate(response, data: data)
        return try decoder.decode(BusinessHotelSyncAccessResponse.self, from: data)
    }

    func revokeHotelSyncAccess(city: String) async throws -> BusinessHotelSyncRevokeResponse {
        guard let canonical = hotelSyncCanonicalCity(city) else { throw APIError.server("HOTEL_SYNC_INVALID_CITY") }
        var request = URLRequest(url: AppConfig.apiBaseURL.appending(path: "/api/admin/hotels/operations/hotel-sync/\(canonical.lowercased())/access"))
        request.httpMethod = "DELETE"
        let (data, response) = try await perform(request)
        try validate(response, data: data)
        return try decoder.decode(BusinessHotelSyncRevokeResponse.self, from: data)
    }

    /// Reads the exact public Hotel Sync payload that ChatGPT sees. The UI copies this body
    /// directly, so the operator no longer has to paste an intermediate read-only URL into
    /// ChatGPT. We still keep the token internally because the backend uses it to expose the
    /// same immutable snapshot contract as Flight Sync.
    func hotelSyncReadOnlyBody(from accessURL: URL) async throws -> String {
        var request = URLRequest(url: accessURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/json,text/plain;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError.server("HOTEL_SYNC_READ_ONLY_FETCH_FAILED")
        }
        guard !data.isEmpty,
              (try? JSONSerialization.jsonObject(with: data)) != nil,
              let text = String(data: data, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APIError.server("HOTEL_SYNC_INVALID_READ_ONLY_BODY")
        }
        return text
    }

    func saveHotelSyncSnapshot(city: String, checkIn: Date, hotels: [HotelListItem]) async throws -> BusinessHotelSyncSnapshotResponse {
        guard let canonicalCity = hotelSyncCanonicalCity(city) else { throw APIError.server("HOTEL_SYNC_INVALID_CITY") }
        let calendar = Calendar(identifier: .gregorian)
        let normalizedCheckIn = calendar.startOfDay(for: checkIn)
        guard let checkOut = calendar.date(byAdding: .day, value: 1, to: normalizedCheckIn) else {
            throw APIError.server("HOTEL_SYNC_INVALID_DATE")
        }

        let selected = hotels
            .filter { hotelSyncCanonicalCity($0.city) == canonicalCity }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard !selected.isEmpty else { throw APIError.server("HOTEL_SYNC_EMPTY_CITY") }

        let payload = BusinessHotelSyncSnapshotPayload(
            version: 2,
            city: canonicalCity,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            checkIn: hotelSyncDateString(normalizedCheckIn),
            checkOut: hotelSyncDateString(checkOut),
            rooms: 1,
            adults: 2,
            children: 0,
            currency: "USD",
            hotels: selected.map { BusinessHotelSyncSnapshotHotel($0, canonicalCity: canonicalCity) }
        )

        var request = URLRequest(url: AppConfig.apiBaseURL.appending(path: "/api/admin/hotels/operations/hotel-sync/\(canonicalCity.lowercased())/snapshot"))
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(payload)
        let (data, response) = try await perform(request)
        try validate(response, data: data)
        return try decoder.decode(BusinessHotelSyncSnapshotResponse.self, from: data)
    }

    func previewHotelChatGPTUpdate(
        _ document: BusinessHotelPriceUpdateDocument,
        currentHotels: [HotelListItem]
    ) async throws -> BusinessHotelPricePreview {
        guard document.schema == BusinessHotelPriceUpdateDocument.schemaName else {
            throw APIError.server("HOTEL_SYNC_UNSUPPORTED_UPDATE_SCHEMA")
        }
        guard let expectedCity = hotelSyncCanonicalCity(document.city) else {
            throw APIError.server("HOTEL_SYNC_INVALID_UPDATE_CITY")
        }
        guard document.rooms == 1, document.adults == 2, document.currency.uppercased() == "USD" else {
            throw APIError.server("HOTEL_SYNC_INVALID_OCCUPANCY")
        }
        guard hotelSyncValidDate(document.checkIn), hotelSyncValidDate(document.checkOut) else {
            throw APIError.server("HOTEL_SYNC_INVALID_UPDATE_DATE")
        }

        let status = try await hotelSyncStatus(city: expectedCity)
        guard status.enabled,
              status.snapshotID == document.snapshotID,
              status.checkIn == document.checkIn,
              status.checkOut == document.checkOut else {
            throw APIError.server("HOTEL_SYNC_SNAPSHOT_CHANGED")
        }

        let currentByID = Dictionary(uniqueKeysWithValues: currentHotels.map { ($0.id, $0) })
        let items = document.hotels.map { update -> BusinessHotelPricePreviewItem in
            guard let hotel = currentByID[update.hotelID] else {
                return hotelSyncPreviewItem(update, name: update.hotelName ?? update.hotelID, reviewStatus: "invalid", issue: "HOTEL_NOT_FOUND", selectable: false)
            }

            let currentCity = hotelSyncCanonicalCity(hotel.city)
            let currentPrice = hotelSyncRoundedPrice(hotel.price?.nightlyUSD)
            let currentSource = hotel.sourceURL ?? hotel.price?.sourceURL
            let currentProvider = hotelSyncProvider(hotel.sourceProvider ?? hotel.price?.provider, sourceURL: currentSource)
            let updateProvider = hotelSyncProvider(update.provider, sourceURL: update.sourceURL)
            let statusValue = update.status.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

            if currentCity != expectedCity {
                return hotelSyncPreviewItem(update, hotel: hotel, reviewStatus: "conflict", issue: "CITY_MISMATCH", selectable: false)
            }
            if !hotelSyncPricesMatch(currentPrice, update.oldNightlyUSD) {
                return hotelSyncPreviewItem(update, hotel: hotel, reviewStatus: "conflict", issue: "PRICE_CHANGED_AFTER_SNAPSHOT", selectable: false)
            }
            if currentProvider == nil || updateProvider != currentProvider || !hotelSyncSameProperty(currentSource, update.sourceURL, provider: currentProvider) {
                return hotelSyncPreviewItem(update, hotel: hotel, reviewStatus: "conflict", issue: "SOURCE_CHANGED_AFTER_SNAPSHOT", selectable: false)
            }
            if update.checkIn != document.checkIn || update.checkOut != document.checkOut || update.rooms != 1 || update.adults != 2 || update.currency.uppercased() != "USD" {
                return hotelSyncPreviewItem(update, hotel: hotel, reviewStatus: "invalid", issue: "DATES_OR_OCCUPANCY_MISMATCH", selectable: false)
            }

            if statusValue == "unchanged" {
                return hotelSyncPreviewItem(update, hotel: hotel, reviewStatus: "unchanged", issue: nil, selectable: false)
            }
            if statusValue == "unverified" {
                return hotelSyncPreviewItem(update, hotel: hotel, reviewStatus: "unverified", issue: update.reason ?? "PRICE_NOT_VERIFIED", selectable: false)
            }
            guard statusValue == "changed" else {
                return hotelSyncPreviewItem(update, hotel: hotel, reviewStatus: "invalid", issue: "INVALID_RESULT_STATUS", selectable: false)
            }
            guard (update.confidence ?? "").lowercased() == "high" else {
                return hotelSyncPreviewItem(update, hotel: hotel, reviewStatus: "invalid", issue: "LOW_CONFIDENCE", selectable: false)
            }
            guard let next = hotelSyncRoundedPrice(update.newNightlyUSD), next >= 15, next <= 5000 else {
                return hotelSyncPreviewItem(update, hotel: hotel, reviewStatus: "invalid", issue: "INVALID_NEW_PRICE", selectable: false)
            }
            guard let checked = update.checkedSourceURL,
                  hotelSyncSameProperty(currentSource, checked, provider: currentProvider) else {
                return hotelSyncPreviewItem(update, hotel: hotel, reviewStatus: "invalid", issue: "CHECKED_SOURCE_NOT_VERIFIED", selectable: false)
            }
            guard hotelSyncURLContainsDates(checked, provider: currentProvider, checkIn: document.checkIn, checkOut: document.checkOut) else {
                return hotelSyncPreviewItem(update, hotel: hotel, reviewStatus: "invalid", issue: "CHECKED_SOURCE_DATES_NOT_VERIFIED", selectable: false)
            }
            return hotelSyncPreviewItem(update, hotel: hotel, reviewStatus: "ready", issue: nil, selectable: true)
        }

        return BusinessHotelPricePreview(
            city: expectedCity,
            checkIn: document.checkIn,
            checkOut: document.checkOut,
            total: items.count,
            changed: items.filter { $0.reviewStatus == "ready" }.count,
            unchanged: items.filter { $0.reviewStatus == "unchanged" }.count,
            conflicts: items.filter { $0.reviewStatus == "conflict" }.count,
            unverified: items.filter { $0.reviewStatus == "unverified" }.count,
            invalid: items.filter { $0.reviewStatus == "invalid" }.count,
            items: items
        )
    }

    func applyHotelChatGPTUpdate(
        _ document: BusinessHotelPriceUpdateDocument,
        selectedHotelIDs: Set<String>
    ) async throws -> BusinessHotelSyncApplyResponse {
        var request = URLRequest(url: AppConfig.apiBaseURL.appending(path: "/api/admin/hotels/operations/hotel-sync/apply"))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(BusinessHotelSyncApplyPayload(result: document, hotelIDs: Array(selectedHotelIDs).sorted()))
        let (data, response) = try await perform(request)
        try validate(response, data: data)
        return try decoder.decode(BusinessHotelSyncApplyResponse.self, from: data)
    }

    private func hotelSyncCanonicalCity(_ value: String?) -> String? {
        let raw = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        if raw.contains("makkah") || raw.contains("mecca") || raw.contains("مكة") { return "Makkah" }
        if raw.contains("madinah") || raw.contains("medina") || raw.contains("المدينة") { return "Madinah" }
        return nil
    }

    private func hotelSyncDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func hotelSyncValidDate(_ value: String) -> Bool {
        guard value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return false }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter.date(from: value) != nil
    }

    private func hotelSyncRoundedPrice(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0, value < 100_000 else { return nil }
        return (value * 100).rounded() / 100
    }

    private func hotelSyncPricesMatch(_ lhs: Double?, _ rhs: Double?) -> Bool {
        let a = hotelSyncRoundedPrice(lhs)
        let b = hotelSyncRoundedPrice(rhs)
        if a == nil && b == nil { return true }
        guard let a, let b else { return false }
        return abs(a - b) < 0.01
    }

    private func hotelSyncProvider(_ value: String?, sourceURL: String?) -> String? {
        let raw = (value ?? "").lowercased()
        if raw.contains("booking") { return "Booking" }
        if raw.contains("expedia") { return "Expedia" }
        if let host = URL(string: sourceURL ?? "")?.host?.lowercased() {
            if host == "booking.com" || host.hasSuffix(".booking.com") { return "Booking" }
            if host == "expedia.com" || host.hasSuffix(".expedia.com") || host.contains("expedia.") { return "Expedia" }
        }
        return nil
    }

    private func hotelSyncPropertyIdentity(_ sourceURL: String?, provider: String?) -> String? {
        guard let raw = sourceURL, let url = URL(string: raw) else { return nil }
        let resolvedProvider = hotelSyncProvider(provider, sourceURL: raw)
        if resolvedProvider == "Booking" {
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let id = components.queryItems?.first(where: { $0.name == "app_hotel_id" || $0.name == "hotel_id" })?.value,
               !id.isEmpty { return "booking:id:\(id)" }
            let path = url.path.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return path.contains("/hotel/") || path.hasPrefix("hotel/") ? "booking:path:\(path)" : nil
        }
        if resolvedProvider == "Expedia" {
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let id = components.queryItems?.first(where: { $0.name == "expediaPropertyId" || $0.name == "propertyId" })?.value,
               !id.isEmpty { return "expedia:id:\(id)" }
            let ns = url.path as NSString
            let regex = try? NSRegularExpression(pattern: #"\.h([0-9]{4,})\.Hotel-Information"#, options: [.caseInsensitive])
            if let match = regex?.firstMatch(in: url.path, range: NSRange(location: 0, length: ns.length)), match.numberOfRanges > 1 {
                return "expedia:id:\(ns.substring(with: match.range(at: 1)))"
            }
        }
        return nil
    }

    private func hotelSyncSameProperty(_ lhs: String?, _ rhs: String?, provider: String?) -> Bool {
        guard let a = hotelSyncPropertyIdentity(lhs, provider: provider), let b = hotelSyncPropertyIdentity(rhs, provider: provider) else { return false }
        return a == b
    }

    private func hotelSyncURLContainsDates(_ rawURL: String, provider: String?, checkIn: String, checkOut: String) -> Bool {
        guard let url = URL(string: rawURL), let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        let values = Dictionary(grouping: components.queryItems ?? [], by: \.name).mapValues { $0.last?.value ?? "" }
        let resolvedProvider = hotelSyncProvider(provider, sourceURL: rawURL)
        if resolvedProvider == "Booking" { return values["checkin"] == checkIn && values["checkout"] == checkOut }
        if resolvedProvider == "Expedia" {
            return (values["chkin"] == checkIn && values["chkout"] == checkOut) || (values["startDate"] == checkIn && values["endDate"] == checkOut)
        }
        return false
    }

    private func hotelSyncPreviewItem(
        _ update: BusinessHotelPriceUpdateItem,
        hotel: HotelListItem? = nil,
        name: String? = nil,
        reviewStatus: String,
        issue: String?,
        selectable: Bool
    ) -> BusinessHotelPricePreviewItem {
        let oldPrice = hotelSyncRoundedPrice(update.oldNightlyUSD)
        let newPrice = hotelSyncRoundedPrice(update.newNightlyUSD)
        let current = hotelSyncRoundedPrice(hotel?.price?.nightlyUSD)
        let baseline = current ?? oldPrice
        let delta = (baseline != nil && newPrice != nil) ? ((newPrice! - baseline!) * 100).rounded() / 100 : nil
        let percent = (baseline ?? 0) > 0 && delta != nil ? ((delta! / baseline!) * 10_000).rounded() / 100 : nil
        return BusinessHotelPricePreviewItem(
            hotelID: update.hotelID,
            hotelName: hotel?.name ?? name ?? update.hotelName ?? update.hotelID,
            status: update.status,
            oldNightlyUSD: oldPrice,
            newNightlyUSD: newPrice,
            provider: hotelSyncProvider(update.provider, sourceURL: update.sourceURL),
            observedNightlyAmount: update.observedNightlyAmount,
            observedCurrency: update.observedCurrency,
            checkedSourceURL: update.checkedSourceURL,
            confidence: (update.confidence ?? "none").lowercased(),
            reviewStatus: reviewStatus,
            issue: issue,
            selectable: selectable,
            deltaUSD: delta,
            deltaPercent: percent
        )
    }
}
