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

enum BookingStatus: String, Codable, Hashable {
    case new = "NEW"
    case availabilityCheck = "AVAILABILITY_CHECK"
    case paymentPending = "PAYMENT_PENDING"
    case paid = "PAID"
    case bookingConfirmed = "BOOKING_CONFIRMED"
    case documentsReady = "DOCUMENTS_READY"
    case readyToTravel = "READY_TO_TRAVEL"
    case inTrip = "IN_TRIP"
    case completed = "COMPLETED"
    case cancelled = "CANCELLED"

    var shortLabel: String {
        switch self {
        case .new: return "Новая"
        case .availabilityCheck: return "Наличие"
        case .paymentPending: return "Оплата"
        case .paid: return "Оплачено"
        case .bookingConfirmed: return "Бронь"
        case .documentsReady: return "Документы"
        case .readyToTravel: return "Поездка"
        case .inTrip: return "В поездке"
        case .completed: return "Готово"
        case .cancelled: return "Отменено"
        }
    }
}

struct BookingSummary: Codable, Identifiable, Hashable {
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
    let clientName: String?
    let pilgrimID: String?
    let tripID: String?
    let operationStatus: String?
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

struct BusinessChatThreadSummary: Codable, Identifiable, Hashable {
    var id: String { bookingID }
    let bookingID: String
    let lastMessageAt: String
    let lastMessagePreview: String
    let lastSenderType: String?
    let unreadForStaff: Bool
}

struct BusinessChatThreadsResponse: Codable {
    let ok: Bool
    let threads: [BusinessChatThreadSummary]
}

struct BusinessChatMessage: Codable, Identifiable, Hashable {
    let id: String
    let bookingID: String
    let senderType: String
    let senderName: String?
    let body: String
    let messageType: String?
    let attachmentID: String?
    let attachmentURL: String?
    let createdAt: String
    let readByStaff: Bool

    var isStaff: Bool { senderType == "staff" }
    var isImage: Bool { messageType == "image" && attachmentURL != nil }
}

struct BusinessChatMessagesResponse: Codable {
    let ok: Bool
    let bookingID: String
    let messages: [BusinessChatMessage]
}

struct BusinessChatMessageResponse: Codable {
    let ok: Bool
    let message: BusinessChatMessage
}

struct SendBusinessChatMessagePayload: Encodable {
    let body: String
    let clientMessageID: String
}

struct PushDeviceRegistrationPayload: Encodable {
    let deviceToken: String
    let environment: String
}

struct PushDeviceRegistrationResponse: Codable {
    let ok: Bool
    let ready: Bool?
}

struct PushStatusResponse: Codable {
    let ok: Bool
    let configured: Bool
    let devices: Int
}
