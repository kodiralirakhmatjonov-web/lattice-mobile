import Foundation

struct SessionUser: Codable {
    let login: String
    let role: String
    let displayName: String
}

struct SessionResponse: Codable {
    let authenticated: Bool
    let user: SessionUser?
}

struct LoginResponse: Codable {
    let ok: Bool?
    let role: String?
    let login: String?
    let error: String?
}

enum BookingStatus: String, Codable {
    case availabilityCheck = "AVAILABILITY_CHECK"
    case paymentPending = "PAYMENT_PENDING"
    case bookingConfirmed = "BOOKING_CONFIRMED"
    case readyToTravel = "READY_TO_TRAVEL"
    case completed = "COMPLETED"

    var shortLabel: String {
        switch self {
        case .availabilityCheck: return "Наличие"
        case .paymentPending: return "Оплата"
        case .bookingConfirmed: return "Бронь"
        case .readyToTravel: return "Поездка"
        case .completed: return "Готово"
        }
    }
}

struct BookingSummary: Codable, Identifiable {
    let id: String
    let status: BookingStatus
    let createdAt: String
    let updatedAt: String
    let lang: String
    let planId: String
    let totalUsd: Double
    let perPilgrimUsd: Double
    let travelerCount: Int
    let rooms: Int
    let originCode: String
    let outboundDestination: String
    let returnOrigin: String
    let startDate: String
    let endDate: String
    let flightName: String
    let makkahHotel: String
    let madinahHotel: String
}

struct BookingsResponse: Codable { let bookings: [BookingSummary] }

struct ChatThread: Codable, Identifiable {
    var id: String { booking.id }
    let booking: BookingSummary
    let lastMessageAt: String
    let lastMessagePreview: String
    let lastSenderType: String?
    let unreadForStaff: Bool
}

struct ChatsResponse: Codable { let threads: [ChatThread] }
