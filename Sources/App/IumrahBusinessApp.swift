import SwiftUI

@main
struct IumrahBusinessApp: App {
    @UIApplicationDelegateAdaptor(BusinessAppDelegate.self) private var appDelegate
    @StateObject private var auth = AuthStore()
    @StateObject private var navigation = BusinessNavigationStore()

    var body: some Scene {
        WindowGroup {
            BusinessAdaptiveLayoutHost {
                RootView()
                    .background {
                        BusinessPlatformWindowConfiguration()
                    }
            }
            .environmentObject(auth)
            .environmentObject(navigation)
            .task { await BusinessNotifications.prepare() }
        }
        .commands {
            BusinessNavigationCommands(navigation: navigation)
        }
    }
}
