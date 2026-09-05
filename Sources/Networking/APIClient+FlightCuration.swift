import Foundation

extension APIClient {
    func searchFlightsForCuration(_ payload: BusinessFlightCurationSearchRequest) async throws -> [BusinessFlightCurationItinerary] {
        var request = URLRequest(url: AppConfig.apiBaseURL.appending(path: "/api/admin/package/flights/curation-search"))
        request.httpMethod = "POST"
        request.timeoutInterval = 35
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(payload)
        let (data, response) = try await perform(request)
        try validate(response, data: data)
        return try decoder.decode(BusinessFlightCurationSearchResponse.self, from: data).itineraries
    }

    func curatedFlights() async throws -> [BusinessCuratedFlightOffer] {
        let url = AppConfig.apiBaseURL.appending(path: "/api/admin/package/flights/curated")
        let (data, response) = try await perform(from: url)
        try validate(response, data: data)
        return try decoder.decode(BusinessCuratedFlightsResponse.self, from: data).offers
    }

    func publishCuratedFlight(_ itinerary: BusinessFlightCurationItinerary, travelerCount: Int, priority: Int = 100) async throws -> BusinessCuratedFlightOffer? {
        var request = URLRequest(url: AppConfig.apiBaseURL.appending(path: "/api/admin/package/flights/curated"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(BusinessCuratedFlightSaveRequest(
            itinerary: itinerary,
            travelerCount: travelerCount,
            published: true,
            priority: priority
        ))
        let (data, response) = try await perform(request)
        try validate(response, data: data)
        struct Envelope: Decodable { let ok: Bool; let offer: BusinessCuratedFlightOffer? }
        return try decoder.decode(Envelope.self, from: data).offer
    }

    func deleteCuratedFlight(id: String) async throws {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        var request = URLRequest(url: AppConfig.apiBaseURL.appending(path: "/api/admin/package/flights/curated/\(encoded)"))
        request.httpMethod = "DELETE"
        let (data, response) = try await perform(request)
        try validate(response, data: data)
        _ = try? decoder.decode(BusinessCuratedFlightDeleteResponse.self, from: data)
    }
}
