import Foundation

extension APIClient {
    func esimAccessBalance() async throws -> ESIMAccessBalance {
        let url = AppConfig.apiBaseURL.appending(path: "/api/admin/hotels/operations/esim-access/balance")
        let (data, response) = try await perform(from: url)
        try validate(response, data: data)
        return try decoder.decode(ESIMAccessBalanceResponse.self, from: data).balance
    }

    func esimAccessPackages(countryCode: String = "SA") async throws -> [ESIMAccessPackage] {
        var components = URLComponents(
            url: AppConfig.apiBaseURL.appending(path: "/api/admin/hotels/operations/esim-access/packages"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "country", value: countryCode.uppercased())]
        guard let url = components.url else { throw APIError.invalidURL }
        let (data, response) = try await perform(from: url)
        try validate(response, data: data)
        return try decoder.decode(ESIMAccessPackagesResponse.self, from: data).packages
    }

    func esimAccessInventory() async throws -> [ESIMAccessInventoryProfile] {
        let url = AppConfig.apiBaseURL.appending(path: "/api/admin/hotels/operations/esim-access/inventory")
        let (data, response) = try await perform(from: url)
        try validate(response, data: data)
        return try decoder.decode(ESIMAccessInventoryResponse.self, from: data).profiles
    }

    func purchaseESIMAccess(
        packageCode: String,
        clientRequestID: String,
        expectedPriceRaw: Double
    ) async throws -> ESIMAccessPurchaseResponse {
        var request = URLRequest(url: AppConfig.apiBaseURL.appending(path: "/api/admin/hotels/operations/esim-access/orders"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(
            ESIMAccessPurchasePayload(
                packageCode: packageCode,
                clientRequestID: clientRequestID,
                expectedPriceRaw: expectedPriceRaw
            )
        )
        let (data, response) = try await perform(request)
        try validate(response, data: data)
        return try decoder.decode(ESIMAccessPurchaseResponse.self, from: data)
    }

    func refreshESIMAccessInventory(id: String) async throws -> ESIMAccessInventoryProfile {
        var request = URLRequest(
            url: AppConfig.apiBaseURL.appending(path: "/api/admin/hotels/operations/esim-access/inventory/\(id)/refresh")
        )
        request.httpMethod = "POST"
        let (data, response) = try await perform(request)
        try validate(response, data: data)
        return try decoder.decode(ESIMAccessPurchaseResponse.self, from: data).profile
    }

    func assignESIMAccessInventory(
        id: String,
        bookingID: String,
        travelerPosition: Int?
    ) async throws -> ESIMAccessAssignResponse {
        var request = URLRequest(
            url: AppConfig.apiBaseURL.appending(path: "/api/admin/hotels/operations/esim-access/inventory/\(id)/assign")
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(
            ESIMAccessAssignPayload(bookingID: bookingID, travelerPosition: travelerPosition)
        )
        let (data, response) = try await perform(request)
        try validate(response, data: data)
        return try decoder.decode(ESIMAccessAssignResponse.self, from: data)
    }
}
