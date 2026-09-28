import Foundation

extension APIClient {
    func chatGPTHotelAccessStatus() async throws -> BusinessChatGPTHotelAccessStatusResponse {
        let url = AppConfig.apiBaseURL.appending(path: "/api/admin/hotels/operations/chatgpt-hotels")
        let (data, response) = try await perform(from: url)
        try validate(response, data: data)
        return try decoder.decode(BusinessChatGPTHotelAccessStatusResponse.self, from: data)
    }

    func setChatGPTHotelAccess(enabled: Bool) async throws -> BusinessChatGPTHotelAccessStatusResponse {
        var request = URLRequest(url: AppConfig.apiBaseURL.appending(path: "/api/admin/hotels/operations/chatgpt-hotels/access"))
        request.httpMethod = enabled ? "POST" : "DELETE"
        let (data, response) = try await perform(request)
        try validate(response, data: data)
        return try decoder.decode(BusinessChatGPTHotelAccessStatusResponse.self, from: data)
    }

    func chatGPTHotelLiveJSON(city: String? = nil) async throws -> String {
        let baseURL = AppConfig.apiBaseURL.appending(path: "/api/admin/hotels/operations/chatgpt-hotels/body")
        let url: URL
        if let city, !city.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
                throw APIError.server("CHATGPT_HOTEL_INVALID_EXPORT_URL")
            }
            components.queryItems = [URLQueryItem(name: "city", value: city)]
            guard let filteredURL = components.url else {
                throw APIError.server("CHATGPT_HOTEL_INVALID_EXPORT_URL")
            }
            url = filteredURL
        } else {
            url = baseURL
        }
        let (data, response) = try await perform(from: url)
        try validate(response, data: data)
        guard !data.isEmpty,
              (try? JSONSerialization.jsonObject(with: data)) != nil,
              let text = String(data: data, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APIError.server("CHATGPT_HOTEL_INVALID_BODY")
        }
        return text
    }

    func previewHotelChatGPTUpdate(
        _ document: BusinessHotelPriceUpdateDocument,
        currentHotels: [HotelListItem],
        primaryHotelIDs: Set<String> = []
    ) async throws -> BusinessHotelPricePreview {
        guard document.schema == BusinessHotelPriceUpdateDocument.schemaName else {
            throw APIError.server("CHATGPT_HOTEL_UNSUPPORTED_UPDATE_SCHEMA")
        }
        guard !document.hotels.isEmpty else {
            throw APIError.server("CHATGPT_HOTEL_EMPTY_RESULT")
        }

        // Direct JSON pricing mode: hotel_id + a usable price are enough.
        // provider/source/property/confidence/old_nightly_usd are informational only
        // and never block an operator-confirmed update.
        let currentByID = Dictionary(uniqueKeysWithValues: currentHotels.map { ($0.id, $0) })
        let items = document.hotels.map { update -> BusinessHotelPricePreviewItem in
            guard let hotel = currentByID[update.hotelID] else {
                return chatGPTHotelPreviewItem(update, name: update.hotelName ?? update.hotelID, reviewStatus: "invalid", issue: "HOTEL_NOT_FOUND", selectable: false)
            }
            // Primary Hotels stay manual-only, but this JSON import is an explicit
            // operator action. The server persists their selected value into
            // hotel_price_overrides instead of the automatic provider cache.
            _ = primaryHotelIDs.contains(update.hotelID)

            guard let next = chatGPTHotelEffectivePriceUSD(update) else {
                return chatGPTHotelPreviewItem(update, hotel: hotel, reviewStatus: "invalid", issue: "NO_USABLE_PRICE", selectable: false)
            }

            if let current = chatGPTHotelRoundedPrice(hotel.price?.nightlyUSD), abs(current - next) < 0.01 {
                return chatGPTHotelPreviewItem(update, hotel: hotel, reviewStatus: "unchanged", issue: nil, selectable: false)
            }

            return chatGPTHotelPreviewItem(update, hotel: hotel, reviewStatus: "ready", issue: nil, selectable: true)
        }

        return BusinessHotelPricePreview(
            total: items.count,
            changed: items.filter { $0.reviewStatus == "ready" }.count,
            unchanged: items.filter { $0.reviewStatus == "unchanged" }.count,
            conflicts: 0,
            unverified: 0,
            invalid: items.filter { $0.reviewStatus == "invalid" }.count,
            items: items
        )
    }

    func applyHotelChatGPTUpdate(
        _ document: BusinessHotelPriceUpdateDocument,
        selectedHotelIDs: Set<String>
    ) async throws -> BusinessHotelSyncApplyResponse {
        var request = URLRequest(url: AppConfig.apiBaseURL.appending(path: "/api/admin/hotels/operations/chatgpt-hotels/apply"))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(BusinessHotelSyncApplyPayload(result: document, hotelIDs: Array(selectedHotelIDs).sorted()))
        let (data, response) = try await perform(request)
        try validate(response, data: data)
        return try decoder.decode(BusinessHotelSyncApplyResponse.self, from: data)
    }

    private func chatGPTHotelCanonicalCity(_ value: String?) -> String? {
        let raw = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        if raw.contains("makkah") || raw.contains("mecca") || raw.contains("مكة") { return "Makkah" }
        if raw.contains("madinah") || raw.contains("medina") || raw.contains("المدينة") { return "Madinah" }
        return nil
    }

    private func chatGPTHotelEffectivePriceUSD(_ update: BusinessHotelPriceUpdateItem) -> Double? {
        if let direct = chatGPTHotelRoundedPrice(update.newNightlyUSD) { return direct }
        guard let observed = chatGPTHotelRoundedPrice(update.observedNightlyAmount) else { return nil }
        switch (update.observedCurrency ?? "USD").uppercased() {
        case "SAR": return chatGPTHotelRoundedPrice(observed / 3.75)
        case "USD", "": return observed
        default: return nil
        }
    }

    private func chatGPTHotelRoundedPrice(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0, value < 100_000 else { return nil }
        return (value * 100).rounded() / 100
    }

    private func chatGPTHotelPricesMatch(_ lhs: Double?, _ rhs: Double?) -> Bool {
        let a = chatGPTHotelRoundedPrice(lhs)
        let b = chatGPTHotelRoundedPrice(rhs)
        if a == nil && b == nil { return true }
        guard let a, let b else { return false }
        return abs(a - b) < 0.01
    }

    private func chatGPTHotelProvider(_ value: String?, sourceURL: String?) -> String? {
        let raw = (value ?? "").lowercased()
        if raw.contains("booking") { return "Booking" }
        if raw.contains("expedia") { return "Expedia" }
        if let host = URL(string: sourceURL ?? "")?.host?.lowercased() {
            if host == "booking.com" || host.hasSuffix(".booking.com") { return "Booking" }
            if host == "expedia.com" || host.hasSuffix(".expedia.com") || host.contains("expedia.") { return "Expedia" }
        }
        return nil
    }

    private func chatGPTHotelPropertyIdentity(_ sourceURL: String?, provider: String?) -> String? {
        guard let raw = sourceURL, let url = URL(string: raw) else { return nil }
        let resolvedProvider = chatGPTHotelProvider(provider, sourceURL: raw)
        if resolvedProvider == "Booking" {
            let ns = url.path as NSString
            let regex = try? NSRegularExpression(pattern: #"^/hotel/([^/]+)/([^/?#]+?)(?:\.html)?/?$"#, options: [.caseInsensitive])
            if let match = regex?.firstMatch(in: url.path, range: NSRange(location: 0, length: ns.length)), match.numberOfRanges > 2 {
                let country = ns.substring(with: match.range(at: 1)).lowercased()
                var slug = ns.substring(with: match.range(at: 2)).lowercased()
                slug = slug.replacingOccurrences(of: #"\.(?:[a-z]{2}(?:-[a-z]{2})?)$"#, with: "", options: .regularExpression)
                return "booking:path:\(country)|\(slug)"
            }
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let id = components.queryItems?.first(where: { $0.name == "app_hotel_id" || $0.name == "hotel_id" })?.value,
               !id.isEmpty { return "booking:id:\(id)" }
            return nil
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

    private func chatGPTHotelSameProperty(_ lhs: String?, _ rhs: String?, provider: String?) -> Bool {
        guard let a = chatGPTHotelPropertyIdentity(lhs, provider: provider), let b = chatGPTHotelPropertyIdentity(rhs, provider: provider) else { return false }
        return a == b
    }

    private func chatGPTHotelPreviewItem(
        _ update: BusinessHotelPriceUpdateItem,
        hotel: HotelListItem? = nil,
        name: String? = nil,
        reviewStatus: String,
        issue: String?,
        selectable: Bool
    ) -> BusinessHotelPricePreviewItem {
        let oldPrice = chatGPTHotelRoundedPrice(update.oldNightlyUSD)
        let newPrice = chatGPTHotelEffectivePriceUSD(update)
        let current = chatGPTHotelRoundedPrice(hotel?.price?.nightlyUSD)
        let baseline = current ?? oldPrice
        let delta = (baseline != nil && newPrice != nil) ? ((newPrice! - baseline!) * 100).rounded() / 100 : nil
        let percent = (baseline ?? 0) > 0 && delta != nil ? ((delta! / baseline!) * 10_000).rounded() / 100 : nil
        return BusinessHotelPricePreviewItem(
            hotelID: update.hotelID,
            hotelName: hotel?.name ?? name ?? update.hotelName ?? update.hotelID,
            city: chatGPTHotelCanonicalCity(hotel?.city ?? update.city) ?? update.city,
            status: update.status,
            oldNightlyUSD: oldPrice,
            newNightlyUSD: newPrice,
            provider: chatGPTHotelProvider(update.provider, sourceURL: update.sourceURL),
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
