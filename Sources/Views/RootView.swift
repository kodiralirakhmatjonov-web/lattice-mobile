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
        VStack(spacing: 14) {
            Text("i")
                .font(.system(size: 42, weight: .black, design: .serif))
                .foregroundStyle(.white)
                .frame(width: 66, height: 66)
                .background(BusinessDesign.ink, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            Text("IUMRAH BUSINESS")
                .font(.system(size: 12, weight: .bold))
                .tracking(1.4)
            Capsule()
                .fill(BusinessDesign.accent)
                .frame(width: pulse ? 72 : 28, height: 3)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
        }
        .onAppear { pulse = true }
    }
}
