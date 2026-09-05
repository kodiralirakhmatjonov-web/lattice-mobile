import Foundation

struct BusinessFlightCurationSearchRequest: Encodable {
    struct Leg: Encodable {
        let origin: String
        let destination: String
        let departureDate: String
        let maxStops: Int

        enum CodingKeys: String, CodingKey {
            case origin, destination
            case departureDate = "departure_date"
            case maxStops = "max_stops"
        }
    }

    let legs: [Leg]
    let adults: Int
    let children: Int
    let infantsInSeat: Int
    let infantsOnLap: Int
    let cabinClass: String
    let airlinesInclude: [String]
    let allowSelfTransfer: Bool

    enum CodingKeys: String, CodingKey {
        case legs, adults, children
        case infantsInSeat = "infants_in_seat"
        case infantsOnLap = "infants_on_lap"
        case cabinClass = "cabin_class"
        case airlinesInclude = "airlines_include"
        case allowSelfTransfer = "allow_self_transfer"
    }
}

struct BusinessFlightCurationSearchResponse: Decodable {
    let ok: Bool
    let observedAt: String?
    let itineraries: [BusinessFlightCurationItinerary]

    enum CodingKeys: String, CodingKey {
        case ok, itineraries
        case observedAt = "observed_at"
    }
}

struct BusinessFlightCurationItinerary: Codable, Identifiable, Hashable {
    struct Price: Codable, Hashable {
        let amount: Double
        let currency: String
        let status: String?
    }

    struct Leg: Codable, Hashable {
        let airline: String
        let flightNumber: String
        let airlineCode: String
        let origin: String
        let destination: String
        let departureAt: String
        let arrivalAt: String
        let durationMinutes: Int
        let stops: Int
        let cabinClass: String

        enum CodingKeys: String, CodingKey {
            case airline, origin, destination, stops
            case flightNumber = "flight_number"
            case airlineCode = "airline_code"
            case departureAt = "departure_at"
            case arrivalAt = "arrival_at"
            case durationMinutes = "duration_minutes"
            case cabinClass = "cabin_class"
        }
    }

    let id: String
    let source: String?
    let sourceName: String?
    let observedAt: String
    let fareScope: String?
    let price: Price
    let legs: [Leg]
    let cabinClass: String
    let ignavId: String?

    enum CodingKeys: String, CodingKey {
        case id, source, price, legs
        case sourceName = "source_name"
        case observedAt = "observed_at"
        case fareScope = "fare_scope"
        case cabinClass = "cabin_class"
        case ignavId = "ignav_id"
    }

    var primaryAirlineCode: String? { legs.first?.airlineCode }
    var primaryAirlineName: String { legs.first?.airline ?? "Авиакомпания" }
}

struct BusinessCuratedFlightOffer: Decodable, Identifiable, Hashable {
    let id: String
    let sourceCandidateID: String
    let outboundOrigin: String
    let outboundDestination: String
    let inboundOrigin: String?
    let inboundDestination: String?
    let outboundDate: String
    let inboundDate: String?
    let airlineCodes: [String]
    let airlineNames: [String]
    let flightNumbers: [String]
    let itinerary: BusinessFlightCurationItinerary?
    let totalFare: Double
    let perTravelerFare: Double
    let currency: String
    let travelerCount: Int
    let observedAt: String
    let published: Bool
    let priority: Int
}

struct BusinessCuratedFlightsResponse: Decodable {
    let ok: Bool
    let offers: [BusinessCuratedFlightOffer]
}

struct BusinessCuratedFlightSaveRequest: Encodable {
    let itinerary: BusinessFlightCurationItinerary
    let travelerCount: Int
    let published: Bool
    let priority: Int
}

private struct BusinessCuratedFlightSaveResponse: Decodable {
    let ok: Bool
    let offer: BusinessCuratedFlightOffer?
}

struct BusinessCuratedFlightDeleteResponse: Decodable {
    let ok: Bool
    let deletedID: String?
}
