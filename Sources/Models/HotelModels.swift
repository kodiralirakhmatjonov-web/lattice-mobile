import Foundation

enum HotelImageKind: String, Codable, CaseIterable, Hashable {
    case exterior
    case room
    case bathroom
    case lobby
    case restaurant
    case amenity
    case view
    case gallery
    case other

    var title: String {
        switch self {
        case .exterior: return "Отель"
        case .room: return "Номера"
        case .bathroom: return "Ванные"
        case .lobby: return "Лобби"
        case .restaurant: return "Рестораны"
        case .amenity: return "Удобства"
        case .view: return "Виды"
        case .gallery: return "Галерея"
        case .other: return "Не определено"
        }
    }

    var trusted: Bool { self != .other }
}

struct ProviderImageMetadata: Codable, Hashable {
    let url: String
    let label: String?
    let kind: HotelImageKind
    let roomHint: String?
}

struct ProviderRoomSnapshot: Codable, Identifiable, Hashable {
    let id: UUID
    let name: String
    let maxGuests: Int?
    let sizeM2: Double?
    let beds: String?
    let view: String?
    let description: String?
    let amenities: [String]

    init(
        id: UUID = UUID(),
        name: String,
        maxGuests: Int? = nil,
        sizeM2: Double? = nil,
        beds: String? = nil,
        view: String? = nil,
        description: String? = nil,
        amenities: [String] = []
    ) {
        self.id = id
        self.name = name
        self.maxGuests = maxGuests
        self.sizeM2 = sizeM2
        self.beds = beds
        self.view = view
        self.description = description
        self.amenities = amenities
    }
}

struct ProviderSnapshot: Codable, Identifiable, Hashable {
    let id: UUID
    let provider: String
    let sourceURL: String
    let name: String?
    let city: String?
    let country: String?
    let address: String?
    let description: String?
    let propertyType: String?
    let stars: Int?
    let rating: Double?
    let ratingScale: Double?
    let reviewCount: Int?
    let latitude: Double?
    let longitude: Double?
    let checkIn: String?
    let checkOut: String?
    let images: [String]
    let imageMetadata: [ProviderImageMetadata]?
    let amenities: [String]
    let rooms: [ProviderRoomSnapshot]
    let roomNames: [String]
    let policies: [String]

    init(
        id: UUID = UUID(),
        provider: String,
        sourceURL: String,
        name: String?,
        city: String?,
        country: String?,
        address: String?,
        description: String?,
        propertyType: String?,
        stars: Int?,
        rating: Double?,
        ratingScale: Double?,
        reviewCount: Int?,
        latitude: Double?,
        longitude: Double?,
        checkIn: String?,
        checkOut: String?,
        images: [String],
        imageMetadata: [ProviderImageMetadata]? = nil,
        amenities: [String],
        rooms: [ProviderRoomSnapshot] = [],
        roomNames: [String] = [],
        policies: [String] = []
    ) {
        self.id = id
        self.provider = provider
        self.sourceURL = sourceURL
        self.name = name
        self.city = city
        self.country = country
        self.address = address
        self.description = description
        self.propertyType = propertyType
        self.stars = stars
        self.rating = rating
        self.ratingScale = ratingScale
        self.reviewCount = reviewCount
        self.latitude = latitude
        self.longitude = longitude
        self.checkIn = checkIn
        self.checkOut = checkOut
        self.images = images
        self.imageMetadata = imageMetadata
        self.amenities = amenities
        self.rooms = rooms
        self.roomNames = roomNames
        self.policies = policies
    }
}

struct HotelImageCandidate: Codable, Identifiable, Hashable {
    let id: UUID
    let url: String
    let provider: String
    let sourcePageURL: String
    var selected: Bool
    var isCover: Bool
    var kind: HotelImageKind
    var label: String?
    var roomName: String?

    init(
        id: UUID = UUID(),
        url: String,
        provider: String,
        sourcePageURL: String,
        selected: Bool = true,
        isCover: Bool = false,
        kind: HotelImageKind = .gallery,
        label: String? = nil,
        roomName: String? = nil
    ) {
        self.id = id
        self.url = url
        self.provider = provider
        self.sourcePageURL = sourcePageURL
        self.selected = selected
        self.isCover = isCover
        self.kind = kind
        self.label = label
        self.roomName = roomName
    }
}

struct HotelRoomDraft: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var maxGuests: Int?
    var sizeM2: Double?
    var beds: String?
    var view: String?
    var description: String?
    var amenities: [String]

    init(
        id: UUID = UUID(),
        name: String,
        maxGuests: Int? = nil,
        sizeM2: Double? = nil,
        beds: String? = nil,
        view: String? = nil,
        description: String? = nil,
        amenities: [String] = []
    ) {
        self.id = id
        self.name = name
        self.maxGuests = maxGuests
        self.sizeM2 = sizeM2
        self.beds = beds
        self.view = view
        self.description = description
        self.amenities = amenities
    }
}

struct HotelDraft: Codable, Identifiable {
    var id: String
    var name: String
    var city: String
    var country: String
    var propertyType: String?
    var stars: Int?
    var rating: Double?
    var ratingScale: Double?
    var reviewCount: Int?
    var address: String
    var description: String
    var latitude: Double?
    var longitude: Double?
    var checkIn: String?
    var checkOut: String?
    var amenities: [String]
    var policies: [String]
    var rooms: [HotelRoomDraft]
    var images: [HotelImageCandidate]
    var sources: [ProviderSnapshot]
    var status: String

    static func empty(name: String = "", city: String = "Makkah") -> HotelDraft {
        HotelDraft(
            id: "IUM-HOTEL-\(UUID().uuidString.prefix(10).uppercased())",
            name: name,
            city: city,
            country: "Saudi Arabia",
            propertyType: nil,
            stars: nil,
            rating: nil,
            ratingScale: nil,
            reviewCount: nil,
            address: "",
            description: "",
            latitude: nil,
            longitude: nil,
            checkIn: nil,
            checkOut: nil,
            amenities: [],
            policies: [],
            rooms: [],
            images: [],
            sources: [],
            status: "draft"
        )
    }

    var selectedImages: [HotelImageCandidate] { images.filter(\.selected) }
    var selectedRoomImages: [HotelImageCandidate] { selectedImages.filter { $0.kind == .room || $0.kind == .bathroom } }
    var selectedTrustedImages: [HotelImageCandidate] { selectedImages.filter { $0.kind.trusted } }
    var suspiciousSelectedImages: [HotelImageCandidate] { selectedImages.filter { $0.kind == .other } }
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
    let rating: Double?
    let reviewCount: Int?
}

struct HotelsResponse: Codable { let hotels: [HotelListItem] }
struct HotelSaveResponse: Codable { let ok: Bool; let hotel: HotelListItem? }

struct HotelCloudHealthResponse: Codable {
    let ok: Bool
    let database: String
    let storage: String
    let hotels: Int
}
