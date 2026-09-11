import Foundation

struct BusinessHotelSyncSnapshotHotel: Codable, Hashable, Identifiable {
    let hotelID: String
    let hotelName: String
    let city: String
    let stars: Int?
    let currentNightlyUSD: Double?
    let currency: String
    let catalogStatus: String
    let priceStatus: String?
    let isManualOverride: Bool
    let provider: String?
    let sourceURL: String?
    let lastPriceFetchedAt: String?

    var id: String { hotelID }

    enum CodingKeys: String, CodingKey {
        case city, stars, currency, provider
        case hotelID = "hotel_id"
        case hotelName = "hotel_name"
        case currentNightlyUSD = "current_nightly_usd"
        case catalogStatus = "catalog_status"
        case priceStatus = "price_status"
        case isManualOverride = "is_manual_override"
        case sourceURL = "source_url"
        case lastPriceFetchedAt = "last_price_fetched_at"
    }

    init(_ hotel: HotelListItem, canonicalCity: String) {
        hotelID = hotel.id
        hotelName = hotel.name
        city = canonicalCity
        stars = hotel.stars
        if let amount = hotel.price?.nightlyUSD, amount.isFinite, amount > 0 {
            currentNightlyUSD = (amount * 100).rounded() / 100
        } else {
            currentNightlyUSD = nil
        }
        currency = "USD"
        catalogStatus = hotel.status
        priceStatus = hotel.price?.status
        isManualOverride = hotel.price?.isManualOverride ?? false
        provider = Self.normalizedProvider(hotel.sourceProvider ?? hotel.price?.provider, sourceURL: hotel.sourceURL ?? hotel.price?.sourceURL)
        sourceURL = hotel.sourceURL ?? hotel.price?.sourceURL
        lastPriceFetchedAt = hotel.price?.fetchedAt
    }

    private static func normalizedProvider(_ value: String?, sourceURL: String?) -> String? {
        let raw = (value ?? "").lowercased()
        if raw.contains("booking") { return "Booking" }
        if raw.contains("expedia") { return "Expedia" }
        if let host = URL(string: sourceURL ?? "")?.host?.lowercased() {
            if host == "booking.com" || host.hasSuffix(".booking.com") { return "Booking" }
            if host == "expedia.com" || host.hasSuffix(".expedia.com") || host.contains("expedia.") { return "Expedia" }
        }
        return nil
    }
}

struct BusinessHotelSyncSnapshotPayload: Codable, Hashable {
    let version: Int
    let city: String
    let generatedAt: String
    let checkIn: String
    let checkOut: String
    let rooms: Int
    let adults: Int
    let children: Int
    let currency: String
    let hotels: [BusinessHotelSyncSnapshotHotel]

    enum CodingKeys: String, CodingKey {
        case version, city, rooms, adults, children, currency, hotels
        case generatedAt = "generated_at"
        case checkIn = "check_in"
        case checkOut = "check_out"
    }
}

struct BusinessHotelSyncAccessResponse: Codable, Hashable {
    let ok: Bool
    let city: String
    let readOnly: Bool
    let accessURL: String
    let rotatedAt: String?
}

struct BusinessHotelSyncSnapshotResponse: Codable, Hashable {
    let ok: Bool
    let city: String
    let readOnly: Bool
    let source: String
    let snapshotID: String
    let hotelCount: Int
    let checkIn: String
    let checkOut: String
    let snapshotUpdatedAt: String?
}

struct BusinessHotelSyncStatusResponse: Codable, Hashable {
    let ok: Bool
    let city: String
    let configured: Bool
    let enabled: Bool
    let readOnly: Bool
    let source: String
    let snapshotID: String?
    let hotelCount: Int
    let checkIn: String?
    let checkOut: String?
    let snapshotUpdatedAt: String?
}

struct BusinessHotelSyncRevokeResponse: Codable, Hashable {
    let ok: Bool
    let city: String
    let enabled: Bool
    let revokedAt: String?
}

struct BusinessHotelPriceUpdateItem: Codable, Hashable, Identifiable {
    let hotelID: String
    let hotelName: String?
    let status: String
    let oldNightlyUSD: Double?
    let newNightlyUSD: Double?
    let observedNightlyAmount: Double?
    let observedCurrency: String?
    let provider: String?
    let sourceURL: String?
    let monitoringURL: String?
    let checkedSourceURL: String?
    let checkIn: String
    let checkOut: String
    let rooms: Int
    let adults: Int
    let currency: String
    let confidence: String?
    let reason: String?
    let checkedAt: String?

    var id: String { hotelID }

    enum CodingKeys: String, CodingKey {
        case status, provider, rooms, adults, currency, confidence, reason
        case hotelID = "hotel_id"
        case hotelName = "hotel_name"
        case oldNightlyUSD = "old_nightly_usd"
        case newNightlyUSD = "new_nightly_usd"
        case observedNightlyAmount = "observed_nightly_amount"
        case observedCurrency = "observed_currency"
        case sourceURL = "source_url"
        case monitoringURL = "monitoring_url"
        case checkedSourceURL = "checked_source_url"
        case checkIn = "check_in"
        case checkOut = "check_out"
        case checkedAt = "checked_at"
    }
}

struct BusinessHotelPriceUpdateDocument: Codable, Hashable {
    static let schemaName = "iumrah.hotel-price-update.v2"

    let schema: String
    let version: Int?
    let snapshotID: String
    let city: String
    let checkIn: String
    let checkOut: String
    let rooms: Int
    let adults: Int
    let currency: String
    let checkedAt: String
    let hotels: [BusinessHotelPriceUpdateItem]

    enum CodingKeys: String, CodingKey {
        case schema, version, city, rooms, adults, currency, hotels
        case snapshotID = "snapshot_id"
        case checkIn = "check_in"
        case checkOut = "check_out"
        case checkedAt = "checked_at"
    }
}

struct BusinessHotelPricePreviewItem: Hashable, Identifiable {
    let hotelID: String
    let hotelName: String
    let status: String
    let oldNightlyUSD: Double?
    let newNightlyUSD: Double?
    let provider: String?
    let observedNightlyAmount: Double?
    let observedCurrency: String?
    let checkedSourceURL: String?
    let confidence: String
    let reviewStatus: String
    let issue: String?
    let selectable: Bool
    let deltaUSD: Double?
    let deltaPercent: Double?

    var id: String { hotelID }
}

struct BusinessHotelPricePreview: Hashable {
    let city: String
    let checkIn: String
    let checkOut: String
    let total: Int
    let changed: Int
    let unchanged: Int
    let conflicts: Int
    let unverified: Int
    let invalid: Int
    let items: [BusinessHotelPricePreviewItem]
}

struct BusinessHotelSyncApplyPayload: Encodable {
    let result: BusinessHotelPriceUpdateDocument
    let hotelIDs: [String]

    enum CodingKeys: String, CodingKey {
        case result
        case hotelIDs = "hotel_ids"
    }
}

struct BusinessHotelSyncApplyResponse: Decodable {
    struct Rejected: Decodable, Hashable {
        let hotelID: String
        let error: String
    }

    let ok: Bool
    let city: String
    let snapshotID: String
    let applied: [String]
    let rejected: [Rejected]
    let appliedCount: Int
    let rejectedCount: Int
}
