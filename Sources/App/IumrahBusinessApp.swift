import SwiftUI

@main
struct IumrahBusinessApp: App {
    @UIApplicationDelegateAdaptor(BusinessAppDelegate.self) private var appDelegate
    @StateObject private var auth = AuthStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(auth)
                .preferredColorScheme(.light)
                .task { await BusinessNotifications.prepare() }
        }
    }
}
