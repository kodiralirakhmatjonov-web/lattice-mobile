import Foundation

struct BusinessFlightSyncSnapshotPayload: Encodable {
    let version = 1
    let flights: [BusinessFlightSyncFlight]

    init(offers: [BusinessCuratedFlightOffer]) {
        flights = offers.map(BusinessFlightSyncFlight.init)
    }
}

struct BusinessFlightSyncFlight: Encodable {
    struct Price: Encodable {
        let amount: Double
        let currency: String
    }

    struct Leg: Encodable {
        let airline: String
        let airlineCode: String
        let flightNumber: String
        let origin: String
        let destination: String
        let departureAt: String
        let arrivalAt: String
        let stops: Int
        let cabinClass: String

        enum CodingKeys: String, CodingKey {
            case airline, origin, destination, stops
            case airlineCode = "airline_code"
            case flightNumber = "flight_number"
            case departureAt = "departure_at"
            case arrivalAt = "arrival_at"
            case cabinClass = "cabin_class"
        }

        init(_ leg: BusinessFlightCurationItinerary.Leg) {
            airline = leg.airline
            airlineCode = leg.airlineCode.uppercased()
            flightNumber = leg.flightNumber.uppercased().replacingOccurrences(of: " ", with: "")
            origin = leg.origin.uppercased()
            destination = leg.destination.uppercased()
            departureAt = leg.departureAt
            arrivalAt = leg.arrivalAt
            stops = leg.stops
            cabinClass = leg.cabinClass
        }
    }

    let id: String
    let comparisonKey: String
    let from: String
    let to: String
    let date: String
    let airlineCodes: [String]
    let airlineNames: [String]
    let flightNumbers: [String]
    let offerType: String
    let journeyRole: String
    let fareScope: String?
    let priceType: String?
    let price: Price
    let observedAt: String
    let legs: [Leg]

    enum CodingKeys: String, CodingKey {
        case id, from, to, date, price, legs
        case comparisonKey = "comparison_key"
        case airlineCodes = "airline_codes"
        case airlineNames = "airline_names"
        case flightNumbers = "flight_numbers"
        case offerType = "offer_type"
        case journeyRole = "journey_role"
        case fareScope = "fare_scope"
        case priceType = "price_type"
        case observedAt = "observed_at"
    }

    init(_ offer: BusinessCuratedFlightOffer) {
        let itinerary = offer.itinerary
        let normalizedNumbers = offer.flightNumbers.map {
            $0.uppercased().replacingOccurrences(of: " ", with: "")
        }
        let day = String(offer.outboundDate.prefix(10))
        let primaryFlightNumber = normalizedNumbers.first
            ?? itinerary?.legs.first?.flightNumber.uppercased().replacingOccurrences(of: " ", with: "")
            ?? "UNKNOWN"
        let effectiveOfferType = offer.offerType?.isEmpty == false
            ? offer.offerType!
            : itinerary?.effectiveOfferType ?? "one_way"

        id = offer.id
        if effectiveOfferType == "one_way" {
            comparisonKey = [
                offer.outboundOrigin.uppercased(),
                offer.outboundDestination.uppercased(),
                primaryFlightNumber,
                day
            ].joined(separator: "-")
        } else {
            comparisonKey = offer.publicationIdentity
        }
        from = offer.outboundOrigin.uppercased()
        to = offer.outboundDestination.uppercased()
        date = day
        airlineCodes = offer.airlineCodes.map { $0.uppercased() }
        airlineNames = offer.airlineNames
        flightNumbers = normalizedNumbers
        offerType = effectiveOfferType
        journeyRole = offer.journeyRole?.isEmpty == false
            ? offer.journeyRole!
            : itinerary?.effectiveJourneyRole ?? "outbound"
        fareScope = itinerary?.fareScope
        priceType = itinerary?.priceType
        price = Price(amount: offer.perTravelerFare, currency: offer.currency.uppercased())
        observedAt = offer.observedAt
        legs = itinerary?.legs.map(Leg.init) ?? []
    }
}

struct BusinessFlightSyncAccessResponse: Decodable {
    let ok: Bool
    let readOnly: Bool
    let accessURL: String
    let rotatedAt: String?
}

struct BusinessFlightSyncSnapshotResponse: Decodable {
    let ok: Bool
    let flightCount: Int
    let snapshotUpdatedAt: String?
}

struct BusinessFlightSyncStatusResponse: Decodable {
    let ok: Bool
    let configured: Bool
    let enabled: Bool
    let flightCount: Int
    let snapshotUpdatedAt: String?
    let readOnly: Bool
}

struct BusinessFlightSyncRevokeResponse: Decodable {
    let ok: Bool
    let enabled: Bool
    let revokedAt: String?
}
