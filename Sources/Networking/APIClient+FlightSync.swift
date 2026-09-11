import Foundation

extension APIClient {
    func flightSyncStatus() async throws -> BusinessFlightSyncStatusResponse {
        let url = AppConfig.apiBaseURL.appending(path: "/api/admin/hotels/operations/flight-sync")
        let (data, response) = try await perform(from: url)
        try validate(response, data: data)
        return try decoder.decode(BusinessFlightSyncStatusResponse.self, from: data)
    }

    func rotateFlightSyncAccess() async throws -> BusinessFlightSyncAccessResponse {
        var request = URLRequest(url: AppConfig.apiBaseURL.appending(path: "/api/admin/hotels/operations/flight-sync/access"))
        request.httpMethod = "POST"
        let (data, response) = try await perform(request)
        try validate(response, data: data)
        return try decoder.decode(BusinessFlightSyncAccessResponse.self, from: data)
    }

    func saveFlightSyncSnapshot(offers: [BusinessCuratedFlightOffer]) async throws -> BusinessFlightSyncSnapshotResponse {
        var request = URLRequest(url: AppConfig.apiBaseURL.appending(path: "/api/admin/hotels/operations/flight-sync/snapshot"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(BusinessFlightSyncSnapshotPayload(offers: offers))
        let (data, response) = try await perform(request)
        try validate(response, data: data)
        return try decoder.decode(BusinessFlightSyncSnapshotResponse.self, from: data)
    }

    func revokeFlightSyncAccess() async throws -> BusinessFlightSyncRevokeResponse {
        var request = URLRequest(url: AppConfig.apiBaseURL.appending(path: "/api/admin/hotels/operations/flight-sync/access"))
        request.httpMethod = "DELETE"
        let (data, response) = try await perform(request)
        try validate(response, data: data)
        return try decoder.decode(BusinessFlightSyncRevokeResponse.self, from: data)
    }
}
