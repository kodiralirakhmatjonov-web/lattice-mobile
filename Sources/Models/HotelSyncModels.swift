import Foundation

struct BusinessChatGPTHotelAccessStatusResponse: Codable, Hashable {
    let ok: Bool
    let enabled: Bool
    let readOnly: Bool
    let live: Bool
    let source: String
    let hotelCount: Int
    let primaryHotelCount: Int?
    let makkahCount: Int
    let madinahCount: Int
    let enabledAt: String?
    let disabledAt: String?
    let updatedAt: String?
    let note: String?
}

struct BusinessHotelPriceUpdateItem: Codable, Hashable, Identifiable {
    let hotelID: String
    let hotelName: String?
    let city: String
    let status: String
    let oldNightlyUSD: Double?
    let newNightlyUSD: Double?
    let observedNightlyAmount: Double?
    let observedCurrency: String?
    let provider: String?
    let sourceURL: String?
    let checkedSourceURL: String?
    let observedCheckIn: String?
    let observedCheckOut: String?
    let confidence: String?
    let reason: String?
    let checkedAt: String?

    var id: String { hotelID }

    enum CodingKeys: String, CodingKey {
        case city, status, provider, confidence, reason
        case hotelID = "hotel_id"
        case hotelName = "hotel_name"
        case oldNightlyUSD = "old_nightly_usd"
        case newNightlyUSD = "new_nightly_usd"
        case observedNightlyAmount = "observed_nightly_amount"
        case observedCurrency = "observed_currency"
        case sourceURL = "source_url"
        case checkedSourceURL = "checked_source_url"
        case observedCheckIn = "observed_check_in"
        case observedCheckOut = "observed_check_out"
        case checkedAt = "checked_at"
    }
}

struct BusinessHotelPriceUpdateDocument: Codable, Hashable {
    static let schemaName = "iumrah.hotel-price-update.v3"

    let schema: String
    let version: Int?
    let checkedAt: String?
    let hotels: [BusinessHotelPriceUpdateItem]

    enum CodingKeys: String, CodingKey {
        case schema, version, hotels
        case checkedAt = "checked_at"
    }
}

struct BusinessHotelPricePreviewItem: Hashable, Identifiable {
    let hotelID: String
    let hotelName: String
    let city: String
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
    let schema: String?
    let applied: [String]
    let rejected: [Rejected]
    let appliedCount: Int
    let rejectedCount: Int
}
