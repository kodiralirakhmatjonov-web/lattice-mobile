import SwiftUI

@MainActor
final class AuthStore: ObservableObject {
    enum State { case checking, signedOut, signedIn }

    @Published var state: State = .checking
    @Published var user: SessionUser?
    @Published var errorMessage: String?

    init() {
        Task { await restore() }
    }

    func restore() async {
        do {
            user = try await APIClient.shared.sessionUser()
            state = .signedIn
            await BusinessNotifications.registerCurrentDeviceIfPossible()
        } catch {
            state = .signedOut
        }
    }

    func login(login: String, password: String) async {
        errorMessage = nil
        do {
            user = try await APIClient.shared.login(login: login, password: password)
            state = .signedIn
            await BusinessNotifications.registerCurrentDeviceIfPossible()
        } catch {
            errorMessage = error.localizedDescription
            state = .signedOut
        }
    }

    func logout() async {
        await APIClient.shared.logout()
        user = nil
        state = .signedOut
    }
}
