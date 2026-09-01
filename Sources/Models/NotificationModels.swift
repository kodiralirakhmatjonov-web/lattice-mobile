import Foundation

enum BusinessNotificationAudience: String, CaseIterable, Identifiable, Codable {
    case all
    case authenticated
    case guest
    case hasTrip = "has_trip"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "Все пользователи"
        case .authenticated: return "Авторизованные"
        case .guest: return "Гости"
        case .hasTrip: return "Создали поездку"
        }
    }

    var subtitle: String {
        switch self {
        case .all: return "Все зарегистрированные установки iumrah"
        case .authenticated: return "Пользователи, вошедшие в iumrah Account"
        case .guest: return "Пользователи без активного аккаунта"
        case .hasTrip: return "Пользователи, у которых есть хотя бы одна поездка"
        }
    }
}

enum BusinessNotificationDestination: String, CaseIterable, Identifiable, Codable {
    case home
    case hotels
    case bookings
    case care
    case account
    case booking

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Главная"
        case .hotels: return "Отели"
        case .bookings: return "Поездки"
        case .care: return "iumrah Care"
        case .account: return "Account"
        case .booking: return "Конкретная поездка"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .hotels: return "building.2.fill"
        case .bookings: return "suitcase.fill"
        case .care: return "heart.fill"
        case .account: return "person.crop.circle.fill"
        case .booking: return "doc.text.fill"
        }
    }
}

struct BusinessNotificationAudienceCounts: Decodable {
    let all: Int
    let authenticated: Int
    let guest: Int
    let hasTrip: Int
    let pushCapable: Int

    func count(for audience: BusinessNotificationAudience) -> Int {
        switch audience {
        case .all: return all
        case .authenticated: return authenticated
        case .guest: return guest
        case .hasTrip: return hasTrip
        }
    }
}

struct BusinessNotificationAudienceResponse: Decodable {
    let ok: Bool
    let audience: BusinessNotificationAudienceCounts
}

struct BusinessClientNotification: Decodable, Identifiable {
    let id: String
    let title: String
    let body: String
    let targetScope: String
    let destination: String
    let destinationBookingID: String?
    let createdBy: String
    let status: String
    let matchedDevices: Int
    let pushSentCount: Int
    let pushFailedCount: Int
    let createdAt: String
    let sentAt: String?
    let expiresAt: String
}

struct BusinessClientNotificationsResponse: Decodable {
    let ok: Bool
    let notifications: [BusinessClientNotification]
}

struct BusinessClientNotificationPayload: Encodable {
    let title: String
    let body: String
    let targetScope: String
    let destination: String
    let destinationBookingID: String?
}

struct BusinessClientNotificationDelivery: Decodable {
    let sent: Int
    let attempted: Int
    let pushReady: Bool
}

struct BusinessClientNotificationSendResponse: Decodable {
    let ok: Bool
    let notification: BusinessClientNotification
    let delivery: BusinessClientNotificationDelivery
}
