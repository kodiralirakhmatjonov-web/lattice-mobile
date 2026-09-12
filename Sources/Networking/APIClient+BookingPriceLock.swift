import Foundation

extension APIClient {
    /// Restarts the booking price lock and returns a freshly reloaded booking detail.
    ///
    /// The production booking API has existed under both the operations-prefixed
    /// route and the legacy admin booking route during the timer rollout. We try
    /// the current iumrah Business route first and only fall back on 404/405.
    /// This keeps the admin screen compatible without changing any other APIClient code.
    func restartBookingPriceLock(id: String) async throws -> BookingDetailResponse {
        let encodedID = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        let paths = [
            "/api/admin/hotels/operations/bookings/\(encodedID)/price-lock/restart",
            "/api/admin/bookings/\(encodedID)/price-lock/restart"
        ]

        var lastFailure: APIError = .server("PRICE_LOCK_RESTART_NOT_AVAILABLE")

        for (index, path) in paths.enumerated() {
            var request = URLRequest(url: AppConfig.apiBaseURL.appending(path: path))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "duration_minutes": 30
            ])

            let (data, response) = try await perform(request)
            guard let http = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }

            if (200..<300).contains(http.statusCode) {
                // Do not depend on the restart endpoint's response envelope. The
                // booking detail endpoint is already the canonical model consumed
                // by BookingDetailView, so reload it after the mutation succeeds.
                return try await bookingDetail(id: id)
            }

            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            lastFailure = .server(message ?? "HTTP_\(http.statusCode)")

            // Only route-shape failures are eligible for legacy fallback. Business
            // errors such as invalid state/booking should be surfaced immediately.
            if index == 0 && (http.statusCode == 404 || http.statusCode == 405) {
                continue
            }

            if http.statusCode == 401 {
                throw APIError.unauthorized
            }
            throw lastFailure
        }

        throw lastFailure
    }
}
