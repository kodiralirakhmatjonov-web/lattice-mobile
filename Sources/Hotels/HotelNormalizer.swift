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
        draft.amenities = unique(snapshot.amenities).prefix(180).map { $0 }
        draft.policies = unique(snapshot.policies).prefix(120).map { $0 }
        draft.googleMapsURL = clean(snapshot.googleMapsURL)
        draft.nearby = Array((snapshot.nearby ?? []).prefix(100))
        draft.facts = Array((snapshot.facts ?? []).prefix(180))
        draft.fees = Array((snapshot.fees ?? []).prefix(100))
        draft.services = unique(snapshot.services ?? []).prefix(180).map { $0 }
        draft.highlights = unique(snapshot.highlights ?? []).prefix(120).map { $0 }
        draft.importantInformation = unique(snapshot.importantInformation ?? []).prefix(160).map { $0 }
        draft.food = Array((snapshot.food ?? []).prefix(160))
        draft.parkingTransport = Array((snapshot.parkingTransport ?? []).prefix(160))
        draft.accessibility = unique(snapshot.accessibility ?? []).prefix(120).map { $0 }
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
