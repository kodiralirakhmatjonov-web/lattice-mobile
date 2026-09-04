import Foundation

struct ESIMAccessBalance: Codable, Hashable {
    let rawAmount: Double
    let amountUSD: Double
    let currencyCode: String
}

struct ESIMAccessBalanceResponse: Codable {
    let ok: Bool
    let balance: ESIMAccessBalance
}

struct ESIMAccessPackage: Codable, Identifiable, Hashable {
    var id: String { packageCode }

    let packageCode: String
    let slug: String
    let name: String
    let priceRaw: Double
    let priceUSD: Double
    let retailPriceRaw: Double?
    let retailPriceUSD: Double?
    let currencyCode: String
    let volumeBytes: Double
    let duration: Int
    let durationUnit: String
    let locationCode: String
    let speed: String
    let supportsTopUp: Bool
    let activeType: Int?
    let networkNames: [String]

    var volumeGB: Double { volumeBytes / 1_073_741_824 }

    var dataLabel: String {
        if volumeGB >= 1 {
            let rounded = volumeGB.rounded()
            return abs(volumeGB - rounded) < 0.01 ? "\(Int(rounded)) GB" : String(format: "%.1f GB", volumeGB)
        }
        let mb = volumeBytes / 1_048_576
        return "\(Int(mb.rounded())) MB"
    }

    var durationLabel: String {
        let unit = durationUnit.uppercased()
        if unit.contains("DAY") { return "\(duration) дн." }
        return "\(duration) \(durationUnit)"
    }
}

struct ESIMAccessPackagesResponse: Codable {
    let ok: Bool
    let countryCode: String
    let packages: [ESIMAccessPackage]
}

struct ESIMAccessInventoryProfile: Codable, Identifiable, Hashable {
    let id: String
    let clientRequestID: String
    let transactionID: String
    let orderNo: String?
    let esimTranNo: String?
    let packageCode: String
    let packageName: String
    let countryCode: String
    let priceUSD: Double
    let currencyCode: String
    let volumeBytes: Double
    let duration: Int?
    let durationUnit: String?
    let iccid: String?
    let lpaString: String?
    let smdpAddress: String?
    let activationCode: String?
    let qrCodeURL: String?
    let shortURL: String?
    let smdpStatus: String?
    let esimStatus: String?
    let totalVolumeBytes: Double
    let usedVolumeBytes: Double
    let remainingVolumeBytes: Double
    let expiresAt: String?
    let purchaseStatus: String
    let assignedBookingID: String?
    let assignedBookingEsimID: String?
    let assignedTravelerPosition: Int?
    let createdBy: String?
    let createdAt: String
    let updatedAt: String

    var isProvisioned: Bool { !(iccid ?? "").isEmpty }
    var isAssigned: Bool { !(assignedBookingID ?? "").isEmpty }
    var totalGB: Double { totalVolumeBytes / 1_073_741_824 }
    var usedGB: Double { usedVolumeBytes / 1_073_741_824 }
    var remainingGB: Double { remainingVolumeBytes / 1_073_741_824 }

    var displayStatus: String {
        if isAssigned { return "Передана паломнику" }
        if isProvisioned { return "Готова к выдаче" }
        switch purchaseStatus.lowercased() {
        case "failed": return "Ошибка покупки"
        case "purchased", "provisioning": return "Выпускается"
        default: return purchaseStatus
        }
    }
}

struct ESIMAccessInventoryResponse: Codable {
    let ok: Bool
    let profiles: [ESIMAccessInventoryProfile]
}

struct ESIMAccessPurchasePayload: Encodable {
    let packageCode: String
    let clientRequestID: String
    let expectedPriceRaw: Double
}

struct ESIMAccessPurchaseResponse: Codable {
    let ok: Bool
    let profile: ESIMAccessInventoryProfile
    let balance: ESIMAccessBalance?
}

struct ESIMAccessAssignPayload: Encodable {
    let bookingID: String
    let travelerPosition: Int?
}

struct ESIMAccessAssignResponse: Codable {
    let ok: Bool
    let profile: ESIMAccessInventoryProfile
    let esim: BookingESIMProfile
}
