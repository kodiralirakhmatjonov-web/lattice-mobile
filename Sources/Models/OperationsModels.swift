import Foundation

enum TripStatus: String, Codable, CaseIterable, Identifiable {
    case new
    case availabilityCheck = "availability_check"
    case paymentPending = "payment_pending"
    case paid
    case bookingConfirmed = "booking_confirmed"
    case documentsReady = "documents_ready"
    case readyToTravel = "ready_to_travel"
    case inTrip = "in_trip"
    case completed
    case cancelled

    var id: String { rawValue }

    var title: String {
        switch self {
        case .new: return "Новая заявка"
        case .availabilityCheck: return "Проверка наличия"
        case .paymentPending: return "Ожидание оплаты"
        case .paid: return "Оплачено"
        case .bookingConfirmed: return "Бронирование подтверждено"
        case .documentsReady: return "Документы готовы"
        case .readyToTravel: return "Готово к поездке"
        case .inTrip: return "Паломник в поездке"
        case .completed: return "Поездка завершена"
        case .cancelled: return "Отменено"
        }
    }

    var isCompleted: Bool { self == .completed || self == .cancelled }
}

struct BusinessTeamMember: Codable, Identifiable, Hashable {
    let id: String
    var staffLogin: String?
    var firstName: String
    var lastName: String
    var displayName: String
    var roleKind: String
    var roleTitle: String
    var phoneUZ: String
    var phoneSA: String
    var telegram: String
    var whatsapp: String
    var instagram: String
    var bio: String
    var publicSlug: String
    var publicVisible: Bool
    var active: Bool
    var isOwner: Bool

    static var emptyGuide: BusinessTeamMember {
        BusinessTeamMember(
            id: "new", staffLogin: nil, firstName: "", lastName: "", displayName: "",
            roleKind: "guide", roleTitle: "Гид iumrah", phoneUZ: "", phoneSA: "",
            telegram: "", whatsapp: "", instagram: "", bio: "", publicSlug: "",
            publicVisible: true, active: true, isOwner: false
        )
    }
}

struct BusinessTeamMemberPayload: Encodable {
    let firstName: String
    let lastName: String
    let roleKind: String
    let roleTitle: String
    let phoneUZ: String
    let phoneSA: String
    let telegram: String
    let whatsapp: String
    let instagram: String
    let bio: String
    let publicSlug: String
    let publicVisible: Bool
    let active: Bool

    init(_ member: BusinessTeamMember) {
        firstName = member.firstName
        lastName = member.lastName
        roleKind = member.roleKind
        roleTitle = member.roleTitle
        phoneUZ = member.phoneUZ
        phoneSA = member.phoneSA
        telegram = member.telegram
        whatsapp = member.whatsapp
        instagram = member.instagram
        bio = member.bio
        publicSlug = member.publicSlug
        publicVisible = member.publicVisible
        active = member.active
    }
}

struct BusinessTeamMemberResponse: Codable { let ok: Bool; let member: BusinessTeamMember }
struct BusinessTeamResponse: Codable { let ok: Bool; let members: [BusinessTeamMember] }

struct BookingOperation: Codable, Hashable {
    let tripID: String
    let bookingID: String
    let pilgrimID: String
    let status: String
    let paymentStatus: String
    let confirmationNumber: String
    let internalNotes: String
    let startDate: String?
    let endDate: String?
    let createdAt: String
    let updatedAt: String
    let completedAt: String?

    var tripStatus: TripStatus { TripStatus(rawValue: status) ?? .new }
}

struct BookingPricingLine: Codable, Identifiable, Hashable {
    let id: String
    let label: String
    let group: String
    let amount: Double
    let currency: String
}

struct BookingRequestField: Codable, Identifiable, Hashable {
    let id: String
    let label: String
    let group: String
    let value: String
}

struct BookingStatusHistoryItem: Codable, Hashable {
    let oldStatus: String?
    let newStatus: String
    let changedBy: String?
    let createdAt: String
}

struct PilgrimSummary: Codable, Identifiable, Hashable {
    let id: String
    let displayName: String
    let firstName: String
    let lastName: String
    let phone: String
    let email: String
    let totalTrips: Int
    let completedTrips: Int?
    let lastTripAt: String?
}

struct BookingDetailResponse: Codable {
    let ok: Bool
    let booking: BookingSummary
    let operation: BookingOperation?
    let pilgrim: PilgrimSummary?
    let pricingLines: [BookingPricingLine]
    let requestFields: [BookingRequestField]
    let statusHistory: [BookingStatusHistoryItem]
    let flights: [BookingFlight]?
    let assignment: BookingAssignment?
}

struct BookingOperationUpdatePayload: Encodable {
    let status: String
    let paymentStatus: String
    let confirmationNumber: String
    let internalNotes: String
}

struct PilgrimsResponse: Codable { let ok: Bool; let pilgrims: [PilgrimSummary] }
struct PilgrimDetailResponse: Codable { let ok: Bool; let pilgrim: PilgrimSummary; let trips: [BookingOperation] }

struct PrimaryHotelAssignment: Codable, Identifiable {
    var id: String { "\(city)-\(stars)-\(position)" }
    let city: String
    let stars: Int
    let position: Int
    let hotel: HotelListItem
}

struct PrimaryHotelsResponse: Codable { let ok: Bool; let assignments: [PrimaryHotelAssignment] }
struct PrimaryHotelsUpdatePayload: Encodable { let city: String; let stars: Int; let hotelIDs: [String] }

enum BookingFlightDirection: String, Codable, CaseIterable, Identifiable {
    case outbound
    case `return`

    var id: String { rawValue }
    var title: String { self == .outbound ? "Рейс туда" : "Рейс обратно" }
}

struct BookingFlight: Codable, Identifiable, Hashable {
    var id: String { direction }
    let direction: String
    let flightNumber: String
    let callSign: String
    let airlineName: String
    let airlineIATA: String
    let airlineICAO: String
    let departureAirportIATA: String
    let departureAirportICAO: String
    let departureAirportName: String
    let arrivalAirportIATA: String
    let arrivalAirportICAO: String
    let arrivalAirportName: String
    let scheduledDepartureLocal: String
    let scheduledDepartureUTC: String
    let scheduledArrivalLocal: String
    let scheduledArrivalUTC: String
    let departureTerminal: String
    let arrivalTerminal: String
    let departureGate: String
    let arrivalGate: String
    let status: String
    let verificationProvider: String
    let verifiedAt: String?
    let lastCheckedAt: String?
}

struct FlightVerificationCandidate: Codable, Identifiable, Hashable {
    let id: String
    let flightNumber: String
    let callSign: String
    let airlineName: String
    let airlineIATA: String
    let airlineICAO: String
    let departureAirportIATA: String
    let departureAirportICAO: String
    let departureAirportName: String
    let arrivalAirportIATA: String
    let arrivalAirportICAO: String
    let arrivalAirportName: String
    let scheduledDepartureLocal: String
    let scheduledDepartureUTC: String
    let scheduledArrivalLocal: String
    let scheduledArrivalUTC: String
    let departureTerminal: String
    let arrivalTerminal: String
    let departureGate: String
    let arrivalGate: String
    let status: String
    let lastUpdatedUTC: String
}

struct FlightVerificationResponse: Codable {
    let ok: Bool
    let provider: String
    let verificationKey: String
    let cached: Bool
    let checkedAt: String
    let candidates: [FlightVerificationCandidate]
}

struct FlightVerificationPayload: Encodable {
    let flightNumber: String
    let dateLocal: String
    let force: Bool
}

struct SaveVerifiedFlightPayload: Encodable {
    let verificationKey: String
    let candidateID: String
}

struct BookingFlightResponse: Codable {
    let ok: Bool
    let flight: BookingFlight
}

struct BookingAssignment: Codable {
    let makkahHotelID: String?
    let madinahHotelID: String?
    let guideID: String?
    let makkahHotel: HotelListItem?
    let madinahHotel: HotelListItem?
    let guide: BusinessTeamMember?
    let guideIsPrimary: Bool
}

struct BookingAssignmentPayload: Encodable {
    let makkahHotelID: String?
    let madinahHotelID: String?
    let guideID: String?
}

struct BookingAssignmentResponse: Codable {
    let ok: Bool
    let assignment: BookingAssignment
}

struct BookingDeleteResponse: Codable {
    let ok: Bool
    let deletedBookingID: String
}
