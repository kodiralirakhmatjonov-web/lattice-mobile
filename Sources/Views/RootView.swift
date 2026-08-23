import SwiftUI

struct RootView: View {
    @EnvironmentObject private var auth: AuthStore

    var body: some View {
        ZStack {
            BusinessDesign.background.ignoresSafeArea()
            switch auth.state {
            case .checking: LaunchView()
            case .signedOut: LoginView()
            case .signedIn: BusinessTabView()
            }
        }
    }
}

private struct LaunchView: View {
    @State private var pulse = false
    var body: some View {
        VStack(spacing: 18) {
            BusinessBrandLogo(height: 62)
                .frame(maxWidth: 300)
            Capsule()
                .fill(BusinessDesign.ink.opacity(0.85))
                .frame(width: pulse ? 72 : 28, height: 3)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
        }
        .onAppear { pulse = true }
    }
}
