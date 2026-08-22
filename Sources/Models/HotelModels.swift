import Foundation

struct ProviderSnapshot: Codable, Identifiable, Hashable {
    let id: UUID
    let provider: String
    let sourceURL: String
    let name: String?
    let address: String?
    let description: String?
    let stars: Int?
    let rating: Double?
    let latitude: Double?
    let longitude: Double?
    let images: [String]
    let amenities: [String]
    let roomNames: [String]

    init(
        id: UUID = UUID(), provider: String, sourceURL: String, name: String?, address: String?,
        description: String?, stars: Int?, rating: Double?, latitude: Double?, longitude: Double?,
        images: [String], amenities: [String], roomNames: [String]
    ) {
        self.id = id; self.provider = provider; self.sourceURL = sourceURL; self.name = name
        self.address = address; self.description = description; self.stars = stars; self.rating = rating
        self.latitude = latitude; self.longitude = longitude; self.images = images
        self.amenities = amenities; self.roomNames = roomNames
    }
}

struct HotelImageCandidate: Codable, Identifiable, Hashable {
    let id: UUID
    let url: String
    let provider: String
    var selected: Bool
    var isCover: Bool

    init(id: UUID = UUID(), url: String, provider: String, selected: Bool = true, isCover: Bool = false) {
        self.id = id; self.url = url; self.provider = provider; self.selected = selected; self.isCover = isCover
    }
}

struct HotelRoomDraft: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var maxGuests: Int?
    var sizeM2: Double?
    var beds: String?
    var view: String?

    init(id: UUID = UUID(), name: String, maxGuests: Int? = nil, sizeM2: Double? = nil, beds: String? = nil, view: String? = nil) {
        self.id = id; self.name = name; self.maxGuests = maxGuests; self.sizeM2 = sizeM2; self.beds = beds; self.view = view
    }
}

struct HotelDraft: Codable, Identifiable {
    var id: String
    var name: String
    var city: String
    var stars: Int?
    var address: String
    var description: String
    var latitude: Double?
    var longitude: Double?
    var amenities: [String]
    var rooms: [HotelRoomDraft]
    var images: [HotelImageCandidate]
    var sources: [ProviderSnapshot]
    var status: String

    static func empty(name: String, city: String) -> HotelDraft {
        HotelDraft(
            id: "IUM-\(city.uppercased().prefix(3))-\(UUID().uuidString.prefix(8).uppercased())",
            name: name, city: city, stars: nil, address: "", description: "", latitude: nil, longitude: nil,
            amenities: [], rooms: [], images: [], sources: [], status: "draft"
        )
    }

    var selectedImages: [HotelImageCandidate] { images.filter(\.selected) }
}

struct HotelListItem: Codable, Identifiable {
    let id: String
    let name: String
    let city: String
    let stars: Int?
    let status: String
    let coverImageURL: String?
    let imageCount: Int
    let roomCount: Int
    let updatedAt: String
}

struct HotelsResponse: Codable { let hotels: [HotelListItem] }
struct HotelSaveResponse: Codable { let ok: Bool; let hotel: HotelListItem? }
