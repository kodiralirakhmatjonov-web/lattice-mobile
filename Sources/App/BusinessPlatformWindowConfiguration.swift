import SwiftUI
import UIKit

/// Catalyst-only desktop window policy. iPhone/iPad remain fully system-managed.
struct BusinessPlatformWindowConfiguration: View {
    var body: some View {
        #if targetEnvironment(macCatalyst)
        BusinessMacWindowConfigurator()
            .frame(width: 0, height: 0)
        #else
        EmptyView()
        #endif
    }
}

#if targetEnvironment(macCatalyst)
private struct BusinessMacWindowConfigurator: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        WindowPolicyViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    private final class WindowPolicyViewController: UIViewController {
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            applyPolicy()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            applyPolicy()
        }

        private func applyPolicy() {
            guard let restrictions = view.window?.windowScene?.sizeRestrictions else { return }
            restrictions.minimumSize = CGSize(width: 980, height: 680)
        }
    }
}
#endif
