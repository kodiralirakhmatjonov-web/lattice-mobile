import Foundation

enum HotelNormalizer {
    static func makeDraft(query: String, city: String, snapshots: [ProviderSnapshot]) -> HotelDraft {
        var draft = HotelDraft.empty(name: query, city: city)
        draft.sources = snapshots

        let priority = ["Booking", "Expedia", "Agoda"]
        let ordered = snapshots.sorted { (priority.firstIndex(of: $0.provider) ?? 99) < (priority.firstIndex(of: $1.provider) ?? 99) }

        let canonicalName = ordered.compactMap(\.name).first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? query
        draft.name = canonicalName
        draft.id = stableHotelID(name: canonicalName, city: city)
        draft.address = ordered.compactMap(\.address).first(where: { !$0.isEmpty }) ?? ""
        draft.description = ordered.compactMap(\.description).first(where: { !$0.isEmpty }) ?? ""
        draft.stars = ordered.compactMap(\.stars).first
        draft.latitude = ordered.compactMap(\.latitude).first
        draft.longitude = ordered.compactMap(\.longitude).first
        draft.amenities = unique(ordered.flatMap(\.amenities)).sorted()
        draft.rooms = roomDrafts(from: ordered.flatMap(\.roomNames))

        var seen = Set<String>()
        var images: [HotelImageCandidate] = []

        for snapshot in ordered {
            let metadata = snapshot.imageMetadata ?? snapshot.images.map {
                ProviderImageMetadata(url: $0, label: nil, kind: .other, roomHint: nil)
            }

            for item in metadata {
                guard let url = normalizedURL(item.url) else { continue }
                let key = dedupeKey(url)
                guard seen.insert(key).inserted else { continue }

                images.append(
                    HotelImageCandidate(
                        url: url,
                        provider: snapshot.provider,
                        selected: false,
                        isCover: false,
                        kind: item.kind,
                        label: cleanOptional(item.label),
                        roomName: cleanOptional(item.roomHint)
                    )
                )
                if images.count >= 72 { break }
            }
            if images.count >= 72 { break }
        }

        images.sort { lhs, rhs in
            let lp = imagePriority(lhs.kind)
            let rp = imagePriority(rhs.kind)
            if lp != rp { return lp < rp }
            let lProvider = priority.firstIndex(of: lhs.provider) ?? 99
            let rProvider = priority.firstIndex(of: rhs.provider) ?? 99
            return lProvider < rProvider
        }

        // Auto-select only images that look like actual hotel media. Generic/unknown images
        // stay visible for manual review but are never selected automatically.
        var selectedCount = 0
        var perKind: [HotelImageKind: Int] = [:]
        let caps: [HotelImageKind: Int] = [
            .exterior: 6,
            .room: 10,
            .lobby: 3,
            .restaurant: 3,
            .amenity: 4,
            .other: 0
        ]

        for index in images.indices {
            let kind = images[index].kind
            let used = perKind[kind, default: 0]
            let cap = caps[kind, default: 0]
            if kind.trusted && used < cap && selectedCount < 24 {
                images[index].selected = true
                perKind[kind] = used + 1
                selectedCount += 1
            }
        }

        if let coverIndex = images.firstIndex(where: { $0.selected && $0.kind == .exterior })
            ?? images.firstIndex(where: { $0.selected && $0.kind == .lobby })
            ?? images.firstIndex(where: { $0.selected }) {
            images[coverIndex].isCover = true
        }

        draft.images = images
        return draft
    }

    private static func roomDrafts(from values: [String]) -> [HotelRoomDraft] {
        let rooms = unique(values)
            .filter { value in
                let lower = value.lowercased()
                guard value.count >= 4 && value.count <= 120 else { return false }
                let blocked = ["room service", "meeting room", "prayer room", "laundry room", "locker room", "non-smoking rooms", "family rooms", "guest rooms"]
                if ["room", "rooms", "suite", "suites", "accommodation", "номер", "номера"].contains(lower) { return false }
                return !blocked.contains(where: { lower.contains($0) })
            }
            .prefix(32)
        return rooms.map { HotelRoomDraft(name: $0) }
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>(); var result: [String] = []
        for value in values {
            let clean = value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard clean.count >= 2 else { continue }
            let key = clean.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
            if seen.insert(key).inserted { result.append(clean) }
        }
        return result
    }

    private static func normalizedURL(_ value: String) -> String? {
        guard value.hasPrefix("http"), let url = URL(string: value), let host = url.host, !host.isEmpty else { return nil }
        let lower = value.lowercased()
        let blocked = [
            "logo", "sprite", "avatar", "favicon", "placeholder", "tracking", "pixel.",
            "country-flag", "/flags/", "flag-icon", "payment", "googleusercontent.com/profile",
            "mapstatic", "maps.googleapis", "qr-code", "social-icon"
        ]
        if blocked.contains(where: { lower.contains($0) }) { return nil }
        return value
    }

    private static func dedupeKey(_ value: String) -> String {
        guard let url = URL(string: value) else { return value.lowercased() }
        let host = url.host?.lowercased() ?? ""
        return host + url.path.lowercased()
    }

    private static func imagePriority(_ kind: HotelImageKind) -> Int {
        switch kind {
        case .exterior: return 0
        case .room: return 1
        case .lobby: return 2
        case .restaurant: return 3
        case .amenity: return 4
        case .other: return 9
        }
    }

    private static func cleanOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : String(clean.prefix(220))
    }

    private static func stableHotelID(name: String, city: String) -> String {
        let raw = "\(city)-\(name)"
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .uppercased()
        let slug = raw
            .replacingOccurrences(of: "[^A-Z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let short = String(slug.prefix(88))
        return "IUM-HOTEL-\(short.isEmpty ? UUID().uuidString.prefix(8) : Substring(short))"
    }
}
