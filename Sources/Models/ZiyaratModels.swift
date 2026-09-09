import Foundation

struct BusinessZiyaratImage: Codable, Identifiable, Hashable {
    let id: String
    let url: String
    let position: Int
    let byteSize: Int?
    let width: Int?
    let height: Int?
}

struct BusinessZiyaratTranslation: Codable, Hashable {
    let title: String
    let shortDescription: String
    let longDescription: String
    let interestingFacts: [String]
    let visitNotes: String

    static let empty = BusinessZiyaratTranslation(
        title: "",
        shortDescription: "",
        longDescription: "",
        interestingFacts: [],
        visitNotes: ""
    )
}

struct BusinessZiyaratPlace: Codable, Identifiable, Hashable {
    let id: String
    let routeID: String
    let slug: String
    let city: String
    let country: String
    let title: String
    let titleArabic: String
    let category: String
    let shortDescription: String
    let longDescription: String
    let interestingFacts: [String]
    let visitNotes: String
    let visitType: String
    let durationMinutes: Int
    let latitude: Double
    let longitude: Double
    let address: String
    let mapLabel: String
    let routeOrder: Int
    let status: String
    let images: [BusinessZiyaratImage]
    let translations: [String: BusinessZiyaratTranslation]?

    func translation(for language: BusinessZiyaratContentLanguage) -> BusinessZiyaratTranslation {
        if let value = translations?[language.rawValue] { return value }
        if language == .english {
            return BusinessZiyaratTranslation(
                title: title,
                shortDescription: shortDescription,
                longDescription: longDescription,
                interestingFacts: interestingFacts,
                visitNotes: visitNotes
            )
        }
        return .empty
    }
}

struct BusinessZiyaratRoute: Codable, Identifiable, Hashable {
    let id: String
    let slug: String
    let city: String
    let country: String
    let title: String
    let subtitle: String
    let transportMode: String
    let status: String
    let estimatedMinutes: Int
    let stopCount: Int
    let places: [BusinessZiyaratPlace]
}

struct BusinessZiyaratCatalogResponse: Codable {
    let ok: Bool
    let routes: [BusinessZiyaratRoute]
}

struct BusinessZiyaratPlaceResponse: Codable {
    let ok: Bool
    let place: BusinessZiyaratPlace
}

struct BusinessZiyaratImageUploadResponse: Codable {
    struct UploadedImage: Codable {
        let id: String
        let url: String
        let position: Int
        let byteSize: Int?
        let width: Int?
        let height: Int?
    }
    let ok: Bool
    let image: UploadedImage?
    let imageID: String?
    let deduplicated: Bool?
}

struct BusinessZiyaratDeleteResponse: Codable {
    let ok: Bool
}

struct BusinessZiyaratPlacePayload: Codable {
    let city: String
    let title: String
    let titleArabic: String
    let category: String
    let shortDescription: String
    let longDescription: String
    let interestingFacts: [String]
    let visitNotes: String
    let visitType: String
    let durationMinutes: Int
    let latitude: Double
    let longitude: Double
    let address: String
    let mapLabel: String
    let routeOrder: Int
    let status: String
    let translations: [String: BusinessZiyaratTranslation]
}

enum BusinessZiyaratContentLanguage: String, CaseIterable, Identifiable {
    case russian = "ru"
    case uzbek = "uz"
    case uzbekCyrillic = "uz-cyrl"
    case english = "en"

    var id: String { rawValue }

    var shortTitle: String {
        switch self {
        case .russian: return "RU"
        case .uzbek: return "UZ"
        case .uzbekCyrillic: return "ЎЗ"
        case .english: return "EN"
        }
    }

    var title: String {
        switch self {
        case .russian: return "Русский"
        case .uzbek: return "O‘zbek"
        case .uzbekCyrillic: return "Ўзбек"
        case .english: return "English"
        }
    }
}

enum BusinessZiyaratCategory: String, CaseIterable, Identifiable {
    case mosque, mountain, cemetery, historical, garden, beach, restaurant, picnic, museum, landmark, other
    var id: String { rawValue }
    var title: String {
        switch self {
        case .mosque: return "Мечеть"
        case .mountain: return "Гора"
        case .cemetery: return "Кладбище"
        case .historical: return "Историческое место"
        case .garden: return "Сад"
        case .beach: return "Море / пляж"
        case .restaurant: return "Ресторан"
        case .picnic: return "Пикник"
        case .museum: return "Музей"
        case .landmark: return "Достопримечательность"
        case .other: return "Другое"
        }
    }
    var symbol: String {
        switch self {
        case .mosque: return "building.columns.fill"
        case .mountain: return "mountain.2.fill"
        case .cemetery: return "leaf.fill"
        case .historical: return "clock.arrow.circlepath"
        case .garden: return "tree.fill"
        case .beach: return "water.waves"
        case .restaurant: return "fork.knife"
        case .picnic: return "basket.fill"
        case .museum: return "building.columns"
        case .landmark: return "mappin.and.ellipse"
        case .other: return "sparkles"
        }
    }
}

enum BusinessZiyaratVisitType: String, CaseIterable, Identifiable {
    case enter, stop, view, pass
    var id: String { rawValue }
    var title: String {
        switch self {
        case .enter: return "Заходим"
        case .stop: return "Остановка"
        case .view: return "Осмотр"
        case .pass: return "Проезжаем"
        }
    }
}
