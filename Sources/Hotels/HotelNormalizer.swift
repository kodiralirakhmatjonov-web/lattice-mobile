import Foundation

enum HotelNormalizer {
    static func makeDraft(snapshot: ProviderSnapshot) -> HotelDraft {
        let resolvedName = clean(snapshot.name) ?? "Hotel"
        let resolvedCity = canonicalCity(snapshot.city, address: snapshot.address, sourceURL: snapshot.sourceURL)
        var draft = HotelDraft.empty(name: resolvedName, city: resolvedCity)

        draft.id = stableHotelID(snapshot: snapshot)
        draft.country = clean(snapshot.country) ?? "Saudi Arabia"
        draft.propertyType = clean(snapshot.propertyType)
        draft.brand = clean(snapshot.brand)
        draft.chain = clean(snapshot.chain)
        draft.postalCode = clean(snapshot.postalCode)
        draft.stars = snapshot.stars
        draft.rating = snapshot.rating
        draft.ratingScale = snapshot.ratingScale
        draft.reviewCount = snapshot.reviewCount
        draft.address = clean(snapshot.address) ?? ""
        draft.description = cleanLong(snapshot.description) ?? ""
        draft.latitude = snapshot.latitude
        draft.longitude = snapshot.longitude
        draft.checkIn = clean(snapshot.checkIn)
        draft.checkOut = clean(snapshot.checkOut)
        draft.amenities = canonicalAmenities(snapshot.amenities).prefix(180).map { $0 }
        draft.policies = unique(snapshot.policies).filter(isSafeHumanText).prefix(120).map { $0 }
        draft.googleMapsURL = clean(snapshot.googleMapsURL)
        draft.nearby = cleanNearby(snapshot.nearby ?? []).prefix(100).map { $0 }
        draft.facts = cleanFacts(snapshot.facts ?? []).prefix(180).map { $0 }
        draft.fees = cleanFacts(snapshot.fees ?? []).prefix(100).map { $0 }
        draft.services = unique(snapshot.services ?? []).filter(isSafeHumanText).prefix(180).map { $0 }
        draft.highlights = unique(snapshot.highlights ?? []).filter(isSafeHumanText).prefix(120).map { $0 }
        draft.importantInformation = unique(snapshot.importantInformation ?? []).filter(isSafeHumanText).prefix(160).map { $0 }
        draft.food = cleanFacts(snapshot.food ?? []).prefix(160).map { $0 }
        draft.parkingTransport = cleanFacts(snapshot.parkingTransport ?? []).prefix(160).map { $0 }
        draft.accessibility = unique(snapshot.accessibility ?? []).filter(isSafeHumanText).prefix(120).map { $0 }
        draft.dataQuality = qualitySummary(snapshot)
        draft.lifecycleState = "draft"
        draft.sources = [snapshot]

        if !snapshot.rooms.isEmpty {
            draft.rooms = snapshot.rooms.filter { plausibleRoomName($0.name) }.prefix(100).map { room in
                HotelRoomDraft(
                    name: clean(room.name) ?? room.name,
                    maxGuests: room.maxGuests,
                    sizeM2: room.sizeM2,
                    beds: clean(room.beds),
                    view: clean(room.view),
                    description: cleanLong(room.description),
                    amenities: unique(room.amenities).prefix(60).map { $0 },
                    smoking: clean(room.smoking),
                    accessibility: unique(room.accessibility).prefix(40).map { $0 },
                    category: clean(room.category),
                    bathroom: unique(room.bathroom).prefix(40).map { $0 }
                )
            }
        } else {
            draft.rooms = unique(snapshot.roomNames).filter(plausibleRoomName).prefix(100).map { HotelRoomDraft(name: $0) }
        }

        var seen = Set<String>()
        var images: [HotelImageCandidate] = []
        let metadata = snapshot.imageMetadata ?? snapshot.images.map {
            ProviderImageMetadata(url: $0, label: nil, kind: .gallery, roomHint: nil)
        }

        for item in metadata {
            guard let url = normalizedURL(item.url) else { continue }
            let key = dedupeKey(url)
            guard seen.insert(key).inserted else { continue }

            images.append(
                HotelImageCandidate(
                    url: url,
                    provider: snapshot.provider,
                    sourcePageURL: snapshot.sourceURL,
                    selected: item.kind.trusted,
                    isCover: false,
                    kind: item.kind,
                    label: clean(item.label),
                    roomName: clean(item.roomHint)
                )
            )
            if images.count >= 240 { break }
        }

        images.sort { lhs, rhs in
            let lp = imagePriority(lhs.kind)
            let rp = imagePriority(rhs.kind)
            if lp != rp { return lp < rp }
            return (lhs.label ?? "") < (rhs.label ?? "")
        }

        if let coverIndex = images.firstIndex(where: { $0.selected && $0.kind == .exterior })
            ?? images.firstIndex(where: { $0.selected && $0.kind == .view })
            ?? images.firstIndex(where: { $0.selected && $0.kind == .lobby })
            ?? images.firstIndex(where: { $0.selected }) {
            images[coverIndex].isCover = true
        }

        draft.images = images
        return draft
    }

    private static func canonicalCity(_ city: String?, address: String?, sourceURL: String) -> String {
        let joined = [city, address, sourceURL].compactMap { $0 }.joined(separator: " ")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        if joined.contains("madinah") || joined.contains("medina") || joined.contains("al madinah") { return "Madinah" }
        if joined.contains("makkah") || joined.contains("mecca") || joined.contains("makkah al mukarramah") { return "Makkah" }
        return clean(city) ?? "Makkah"
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            let cleaned = value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard cleaned.count >= 2 else { continue }
            let key = cleaned.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
            if seen.insert(key).inserted { result.append(cleaned) }
        }
        return result
    }


    private static func isSafeHumanText(_ value: String) -> Bool {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        let lower = text.lowercased()
        let noiseTokens = [
            "\\\"", "__typename", "agencybusinessmodels", "availability_group",
            "bedroomfilter", "bed_type_group", "startdate", "trip-type",
            "shoppingproductcontent", "egdsplaintext"
        ]
        if noiseTokens.contains(where: lower.contains) { return false }
        if text.contains("{") && (text.contains("\"") || text.contains(":")) { return false }
        if text.contains("[") && text.contains("\"") { return false }
        if lower.contains("see all about this property") && lower.contains("explore the area") { return false }
        if lower.contains("free wififree cribs") || lower.contains("breakfast for a feerestaurant") { return false }
        return true
    }

    private static func canonicalAmenities(_ values: [String]) -> [String] {
        var result: [String] = []
        var seen = Set<String>()

        func canonical(_ raw: String) -> String? {
            guard isSafeHumanText(raw) else { return nil }
            let text = raw.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = text.lowercased()
            if lower.contains("free wifi") || lower.contains("free wi-fi") { return "Free WiFi" }
            if lower.contains("wifi") || lower.contains("wi-fi") { return "Wi‑Fi" }
            if lower.contains("restaurant") { return "Restaurant" }
            if lower.contains("coffee shop") || lower.contains("cafe") || lower.contains("café") { return "Coffee shop" }
            if lower.contains("24-hour front desk") || lower.contains("24 hour front desk") { return "24-hour front desk" }
            if lower.contains("fitness center") || lower.contains("fitness centre") || lower == "gym" { return "Fitness center" }
            if lower.contains("swimming pool") || lower.contains("outdoor pool") || lower.contains("indoor pool") { return "Swimming pool" }
            if lower.contains("airport shuttle") || lower.contains("shuttle service") { return "Airport shuttle" }
            if lower.contains("valet parking") { return "Valet parking" }
            if lower.contains("luggage storage") || lower.contains("baggage storage") { return "Luggage storage" }
            return text
        }

        for value in values {
            guard let item = canonical(value), item.count >= 2 else { continue }
            let key = item.lowercased()
            if key == "wi‑fi", seen.contains("free wifi") { continue }
            if key == "free wifi" {
                result.removeAll { $0.lowercased() == "wi‑fi" }
                seen.remove("wi‑fi")
            }
            if seen.insert(key).inserted { result.append(item) }
        }
        return result
    }

    private static func cleanFacts(_ values: [ProviderFact]) -> [ProviderFact] {
        var seen = Set<String>()
        var result: [ProviderFact] = []
        for fact in values {
            guard isSafeHumanText(fact.group),
                  isSafeHumanText(fact.label),
                  isSafeHumanText(fact.value) else { continue }
            let key = "\(fact.group)|\(fact.label)|\(fact.value)".lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(fact)
        }
        return result
    }

    private static func cleanNearby(_ values: [ProviderNearbyPlace]) -> [ProviderNearbyPlace] {
        var seen = Set<String>()
        var result: [ProviderNearbyPlace] = []

        for place in values {
            guard isSafeHumanText(place.name) else { continue }
            var name = place.name.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if let range = name.range(of: " Place, ", options: .caseInsensitive) {
                let first = String(name[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let second = String(name[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if first.caseInsensitiveCompare(second) == .orderedSame {
                    name = first
                }
            }

            let key = "\(name.lowercased())|\(place.durationMinutes ?? -1)|\(place.distanceText ?? "")"
            guard seen.insert(key).inserted else { continue }
            result.append(
                ProviderNearbyPlace(
                    id: place.id,
                    name: name,
                    distanceText: place.distanceText,
                    distanceMeters: place.distanceMeters,
                    durationMinutes: place.durationMinutes,
                    travelMode: place.travelMode
                )
            )
        }
        return result
    }

    private static func normalizedURL(_ value: String) -> String? {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil else { return nil }
        return url.absoluteString
    }

    private static func dedupeKey(_ value: String) -> String {
        guard let url = URL(string: value) else { return value.lowercased() }
        let host = url.host?.lowercased() ?? ""
        var path = url.path.lowercased()
        path = path.replacingOccurrences(of: #"/(?:max|square|smart)[0-9x_-]+/"#, with: "/SIZE/", options: .regularExpression)
        return host + path
    }

    private static func imagePriority(_ kind: HotelImageKind) -> Int {
        switch kind {
        case .exterior: return 0
        case .view: return 1
        case .room: return 2
        case .bathroom: return 3
        case .lobby: return 4
        case .restaurant: return 5
        case .breakfast: return 6
        case .lounge: return 7
        case .pool: return 8
        case .spa: return 9
        case .gym: return 10
        case .facility: return 11
        case .amenity: return 12
        case .gallery: return 13
        case .other: return 99
        }
    }

    private static func plausibleRoomName(_ value: String) -> Bool {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 4, text.count <= 220 else { return false }
        let lower = text.lowercased()
        let blocked = [
            "how much", "parking", "breakfast", "restaurant", "front desk", "concierge",
            "room service", "meeting room", "prayer room", "laundry room", "locker room",
            "choose your room", "select room", "room amenities", "frequently asked", "check-in", "check-out"
        ]
        if blocked.contains(where: lower.contains) || text.hasSuffix("?") { return false }
        let markers = ["room", "suite", "studio", "apartment", "villa", "king", "queen", "twin", "double", "triple", "quad", "deluxe", "superior", "classic", "standard", "executive", "premier", "номер", "люкс", "غرفة", "جناح"]
        return markers.contains(where: lower.contains)
    }

    private static func qualitySummary(_ snapshot: ProviderSnapshot) -> [String: String] {
        var result: [String: String] = [:]
        result["identity"] = (snapshot.name != nil && snapshot.address != nil) ? "complete" : "partial"
        result["geo"] = (snapshot.latitude != nil && snapshot.longitude != nil) ? "source" : "missing"
        result["rooms"] = snapshot.rooms.isEmpty ? "missing" : "structured"
        result["media"] = (snapshot.imageMetadata?.isEmpty == false) ? "classified" : "partial"
        result["nearby"] = (snapshot.nearby?.isEmpty == false) ? "structured" : "missing"
        result["propertyContent"] = ((snapshot.facts?.isEmpty == false) || !(snapshot.amenities.isEmpty)) ? "structured" : "partial"
        return result
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(600))
    }

    private static func cleanLong(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(12_000))
    }

    private static func stableHotelID(snapshot: ProviderSnapshot) -> String {
        let provider = snapshot.provider
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .uppercased()
            .replacingOccurrences(of: "[^A-Z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if let sourceID = clean(snapshot.providerHotelID) {
            let normalizedSourceID = sourceID
                .uppercased()
                .replacingOccurrences(of: "[^A-Z0-9._:-]+", with: "-", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            if !normalizedSourceID.isEmpty {
                return String("IUM-HOTEL-\(provider)-\(normalizedSourceID)".prefix(120))
            }
        }
        // Never derive identity from name+city alone: two distinct physical hotels
        // may legitimately share a similar name. Server-side duplicate matching is
        // responsible for physical-property identity.
        return "IUM-HOTEL-\(provider)-\(UUID().uuidString)"
    }
}
