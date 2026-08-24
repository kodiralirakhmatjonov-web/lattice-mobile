import Foundation

enum HotelImageKind: String, Codable, CaseIterable, Hashable {
    case exterior
    case room
    case bathroom
    case lobby
    case restaurant
    case breakfast
    case gym
    case spa
    case pool
    case lounge
    case facility
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
        case .breakfast: return "Завтрак"
        case .gym: return "Фитнес"
        case .spa: return "Спа"
        case .pool: return "Бассейн"
        case .lounge: return "Лаунж"
        case .facility: return "Инфраструктура"
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
    let smoking: String?
    let accessibility: [String]
    let category: String?
    let bathroom: [String]

    init(
        id: UUID = UUID(),
        name: String,
        maxGuests: Int? = nil,
        sizeM2: Double? = nil,
        beds: String? = nil,
        view: String? = nil,
        description: String? = nil,
        amenities: [String] = [],
        smoking: String? = nil,
        accessibility: [String] = [],
        category: String? = nil,
        bathroom: [String] = []
    ) {
        self.id = id
        self.name = name
        self.maxGuests = maxGuests
        self.sizeM2 = sizeM2
        self.beds = beds
        self.view = view
        self.description = description
        self.amenities = amenities
        self.smoking = smoking
        self.accessibility = accessibility
        self.category = category
        self.bathroom = bathroom
    }
}

struct ProviderNearbyPlace: Codable, Hashable, Identifiable {
    let id: UUID
    let name: String
    let distanceText: String?
    let distanceMeters: Double?
    let durationMinutes: Int?
    let travelMode: String?

    init(id: UUID = UUID(), name: String, distanceText: String? = nil, distanceMeters: Double? = nil, durationMinutes: Int? = nil, travelMode: String? = nil) {
        self.id = id
        self.name = name
        self.distanceText = distanceText
        self.distanceMeters = distanceMeters
        self.durationMinutes = durationMinutes
        self.travelMode = travelMode
    }
}

struct ProviderFact: Codable, Hashable, Identifiable {
    let id: UUID
    let group: String
    let label: String
    let value: String

    init(id: UUID = UUID(), group: String, label: String, value: String) {
        self.id = id
        self.group = group
        self.label = label
        self.value = value
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
    let brand: String?
    let chain: String?
    let postalCode: String?
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
    let providerHotelID: String?
    let canonicalURL: String?
    let googleMapsURL: String?
    let nearby: [ProviderNearbyPlace]?
    let facts: [ProviderFact]?
    let fees: [ProviderFact]?
    let services: [String]?
    let highlights: [String]?
    let importantInformation: [String]?
    let food: [ProviderFact]?
    let parkingTransport: [ProviderFact]?
    let accessibility: [String]?
    let rawIdentity: [String: String]?

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
        brand: String? = nil,
        chain: String? = nil,
        postalCode: String? = nil,
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
        policies: [String] = [],
        providerHotelID: String? = nil,
        canonicalURL: String? = nil,
        googleMapsURL: String? = nil,
        nearby: [ProviderNearbyPlace]? = nil,
        facts: [ProviderFact]? = nil,
        fees: [ProviderFact]? = nil,
        services: [String]? = nil,
        highlights: [String]? = nil,
        importantInformation: [String]? = nil,
        food: [ProviderFact]? = nil,
        parkingTransport: [ProviderFact]? = nil,
        accessibility: [String]? = nil,
        rawIdentity: [String: String]? = nil
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
        self.brand = brand
        self.chain = chain
        self.postalCode = postalCode
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
        self.providerHotelID = providerHotelID
        self.canonicalURL = canonicalURL
        self.googleMapsURL = googleMapsURL
        self.nearby = nearby
        self.facts = facts
        self.fees = fees
        self.services = services
        self.highlights = highlights
        self.importantInformation = importantInformation
        self.food = food
        self.parkingTransport = parkingTransport
        self.accessibility = accessibility
        self.rawIdentity = rawIdentity
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
    var smoking: String?
    var accessibility: [String]
    var category: String?
    var bathroom: [String]

    init(
        id: UUID = UUID(),
        name: String,
        maxGuests: Int? = nil,
        sizeM2: Double? = nil,
        beds: String? = nil,
        view: String? = nil,
        description: String? = nil,
        amenities: [String] = [],
        smoking: String? = nil,
        accessibility: [String] = [],
        category: String? = nil,
        bathroom: [String] = []
    ) {
        self.id = id
        self.name = name
        self.maxGuests = maxGuests
        self.sizeM2 = sizeM2
        self.beds = beds
        self.view = view
        self.description = description
        self.amenities = amenities
        self.smoking = smoking
        self.accessibility = accessibility
        self.category = category
        self.bathroom = bathroom
    }
}

struct HotelDraft: Codable, Identifiable {
    var id: String
    var name: String
    var city: String
    var country: String
    var propertyType: String?
    var brand: String?
    var chain: String?
    var postalCode: String?
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
    var googleMapsURL: String?
    var nearby: [ProviderNearbyPlace]
    var facts: [ProviderFact]
    var fees: [ProviderFact]
    var services: [String]
    var highlights: [String]
    var importantInformation: [String]
    var food: [ProviderFact]
    var parkingTransport: [ProviderFact]
    var accessibility: [String]
    var dataQuality: [String: String]
    var lifecycleState: String
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
            brand: nil,
            chain: nil,
            postalCode: nil,
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
            googleMapsURL: nil,
            nearby: [],
            facts: [],
            fees: [],
            services: [],
            highlights: [],
            importantInformation: [],
            food: [],
            parkingTransport: [],
            accessibility: [],
            dataQuality: [:],
            lifecycleState: "draft",
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
    let lifecycleState: String?
    let coverImageURL: String?
    let imageCount: Int
    let roomCount: Int
    let updatedAt: String
    let rating: Double?
    let reviewCount: Int?
}

struct HotelsResponse: Codable { let hotels: [HotelListItem] }
struct HotelSaveResponse: Codable { let ok: Bool; let hotel: HotelListItem? }

struct HotelDuplicate: Codable, Identifiable {
    let id: String
    let name: String
    let city: String
    let address: String?
    let latitude: Double?
    let longitude: Double?
    let brand: String?
    let chain: String?
    let provider: String?
    let sourceURL: String?
    let match: String
    let certainty: String?
    let confidence: Double?

    var isDefinitive: Bool { certainty == nil || certainty == "definitive" }
    var isPossible: Bool { certainty == "possible" }
}

struct HotelDuplicateResponse: Codable {
    let ok: Bool
    let duplicate: HotelDuplicate?
}

struct HotelImportJob: Codable, Identifiable {
    let id: String
    let hotelID: String
    let hotelName: String
    let sourceProvider: String?
    let sourceURL: String?
    let status: String
    let stage: String
    let progress: Int
    let totalImages: Int
    let storedImages: Int
    let failedImages: Int
    let publishWhenComplete: Bool
    let error: String?
    let createdAt: String
    let startedAt: String?
    let completedAt: String?
    let updatedAt: String
    let retryCount: Int?
    let snapshotHash: String?
    let possibleDuplicate: HotelDuplicate?
    let currentImage: Int?
    let currentImageLabel: String?
    let warning: String?
    let compressionMode: String?
    let heartbeatAt: String?
    let lastErrorCode: String?
    let cancelRequestedAt: String?

    var isActive: Bool { status == "queued" || status == "running" }
    var isCompleted: Bool { status == "completed" }

    private enum CodingKeys: String, CodingKey {
        case id, hotelID, hotelName, sourceProvider, sourceURL, status, stage, progress
        case totalImages, storedImages, failedImages, publishWhenComplete, error, createdAt
        case startedAt, completedAt, updatedAt, retryCount, snapshotHash, possibleDuplicate
        case currentImage, currentImageLabel, warning, compressionMode, heartbeatAt
        case lastErrorCode, cancelRequestedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        hotelID = try container.decodeIfPresent(String.self, forKey: .hotelID) ?? ""
        hotelName = try container.decodeIfPresent(String.self, forKey: .hotelName) ?? "Hotel"
        sourceProvider = try container.decodeIfPresent(String.self, forKey: .sourceProvider)
        sourceURL = try container.decodeIfPresent(String.self, forKey: .sourceURL)
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? "failed"
        stage = try container.decodeIfPresent(String.self, forKey: .stage) ?? status
        progress = try container.decodeIfPresent(Int.self, forKey: .progress) ?? 0
        totalImages = try container.decodeIfPresent(Int.self, forKey: .totalImages) ?? 0
        storedImages = try container.decodeIfPresent(Int.self, forKey: .storedImages) ?? 0
        failedImages = try container.decodeIfPresent(Int.self, forKey: .failedImages) ?? 0
        publishWhenComplete = try container.decodeIfPresent(Bool.self, forKey: .publishWhenComplete) ?? false
        error = try container.decodeIfPresent(String.self, forKey: .error)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        startedAt = try container.decodeIfPresent(String.self, forKey: .startedAt)
        completedAt = try container.decodeIfPresent(String.self, forKey: .completedAt)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt) ?? createdAt
        retryCount = try container.decodeIfPresent(Int.self, forKey: .retryCount)
        snapshotHash = try container.decodeIfPresent(String.self, forKey: .snapshotHash)
        possibleDuplicate = try container.decodeIfPresent(HotelDuplicate.self, forKey: .possibleDuplicate)
        currentImage = try container.decodeIfPresent(Int.self, forKey: .currentImage)
        currentImageLabel = try container.decodeIfPresent(String.self, forKey: .currentImageLabel)
        warning = try container.decodeIfPresent(String.self, forKey: .warning)
        compressionMode = try container.decodeIfPresent(String.self, forKey: .compressionMode)
        heartbeatAt = try container.decodeIfPresent(String.self, forKey: .heartbeatAt)
        lastErrorCode = try container.decodeIfPresent(String.self, forKey: .lastErrorCode)
        cancelRequestedAt = try container.decodeIfPresent(String.self, forKey: .cancelRequestedAt)
    }
}



struct SourceRoomRecoveryResponse: Codable {
    let ok: Bool
    let provider: String
    let sourceURL: String
    let roomCount: Int
    let rooms: [HotelRoomDraft]
    let method: String
}

struct SourceRoomRecoveryPayload: Encodable {
    let sourceURL: String
}

struct HotelImportJobResponse: Codable { let ok: Bool; let job: HotelImportJob }
struct HotelImportConflictResponse: Codable { let ok: Bool?; let error: String; let duplicate: HotelDuplicate? }
struct HotelImportJobsResponse: Codable { let ok: Bool; let jobs: [HotelImportJob] }

struct HotelImportStartPayload: Encodable {
    let hotel: HotelDraft
    let images: [HotelImageCandidate]
    let publishWhenComplete: Bool
    let idempotencyKey: String
    let allowPossibleDuplicate: Bool
}

struct HotelSourceDuplicatePayload: Encodable {
    let sourceURL: String
}

struct HotelCloudHealthResponse: Codable {
    let ok: Bool
    let database: String
    let storage: String
    let hotels: Int
}
