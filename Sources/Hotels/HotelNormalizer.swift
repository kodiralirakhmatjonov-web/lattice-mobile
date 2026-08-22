import Foundation

enum HotelNormalizer {
    static func makeDraft(query: String, city: String, snapshots: [ProviderSnapshot]) -> HotelDraft {
        var draft = HotelDraft.empty(name: query, city: city)
        draft.sources = snapshots

        let priority = ["Booking", "Expedia", "Agoda"]
        let ordered = snapshots.sorted { (priority.firstIndex(of: $0.provider) ?? 99) < (priority.firstIndex(of: $1.provider) ?? 99) }
        draft.name = ordered.compactMap(\.name).first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? query
        draft.address = ordered.compactMap(\.address).first(where: { !$0.isEmpty }) ?? ""
        draft.description = ordered.compactMap(\.description).first(where: { !$0.isEmpty }) ?? ""
        draft.stars = ordered.compactMap(\.stars).first
        draft.latitude = ordered.compactMap(\.latitude).first
        draft.longitude = ordered.compactMap(\.longitude).first
        draft.amenities = unique(ordered.flatMap(\.amenities)).sorted()
        draft.rooms = unique(ordered.flatMap(\.roomNames)).prefix(24).map { HotelRoomDraft(name: $0) }

        var seen = Set<String>()
        var images: [HotelImageCandidate] = []
        for snapshot in ordered {
            for raw in snapshot.images {
                guard let url = normalizedURL(raw), !seen.contains(url) else { continue }
                seen.insert(url)
                images.append(HotelImageCandidate(url: url, provider: snapshot.provider, selected: images.count < 24, isCover: images.isEmpty))
                if images.count >= 60 { break }
            }
            if images.count >= 60 { break }
        }
        draft.images = images
        return draft
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>(); var result: [String] = []
        for value in values {
            let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard clean.count >= 2 else { continue }
            let key = clean.lowercased()
            if seen.insert(key).inserted { result.append(clean) }
        }
        return result
    }

    private static func normalizedURL(_ value: String) -> String? {
        guard value.hasPrefix("http"), let url = URL(string: value), let host = url.host, !host.isEmpty else { return nil }
        let blocked = ["logo", "icon", "sprite", "avatar", "map"]
        if blocked.contains(where: { value.lowercased().contains($0) }) { return nil }
        return value
    }
}
