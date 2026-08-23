import SwiftUI

struct HotelImportSessionView: View {
    let hotelName: String
    let city: String
    @StateObject private var coordinator = HotelImportCoordinator()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                ImportWebView(webView: coordinator.webView)
                    .opacity(coordinator.showSource ? 1 : 0.015)
                    .allowsHitTesting(coordinator.showSource)
                    .ignoresSafeArea(edges: .bottom)

                if !coordinator.showSource {
                    BusinessDesign.background.ignoresSafeArea()
                    VStack(spacing: 18) {
                        Spacer()
                        BusinessBrandLogo(height: 48)
                            .padding(.horizontal, 42)
                        Image(systemName: "building.2.crop.circle.fill")
                            .font(.system(size: 54)).foregroundStyle(BusinessDesign.ink)
                        Text(coordinator.currentProvider?.rawValue ?? "iumrah Importer")
                            .font(.caption.bold()).tracking(2).foregroundStyle(.secondary)
                        Text(coordinator.status)
                            .font(.system(size: 28, weight: .bold)).tracking(-1).multilineTextAlignment(.center)
                            .padding(.horizontal, 22)
                        ProgressView(value: coordinator.progress).tint(BusinessDesign.accent).padding(.horizontal, 38)
                        HStack(spacing: 8) {
                            ForEach(HotelImportCoordinator.Provider.allCases, id: \.rawValue) { p in
                                Text(p.rawValue).font(.caption2.bold()).padding(.horizontal, 10).frame(height: 30)
                                    .background(coordinator.snapshots.contains(where: { $0.provider == p.rawValue }) ? Color.green.opacity(0.13) : Color.black.opacity(0.04), in: Capsule())
                            }
                        }
                        Spacer()
                        if coordinator.requiresUserAction {
                            Button("Открыть проверку") { coordinator.showSource = true }
                                .font(.headline).frame(maxWidth: .infinity).frame(height: 54).foregroundStyle(.white).background(BusinessDesign.ink, in: Capsule()).padding(.horizontal, 18)
                            Button("Пропустить источник") { coordinator.skipCurrentProvider() }.font(.subheadline.bold()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle(coordinator.showSource ? (coordinator.currentProvider?.rawValue ?? "Источник") : "Импорт")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Закрыть") { dismiss() } }
                if coordinator.showSource {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button { coordinator.webView.reload() } label: { Image(systemName: "arrow.clockwise") }
                        Button("Продолжить") { coordinator.continueAfterVerification() }
                    }
                }
            }
            .navigationDestination(isPresented: Binding(get: { coordinator.draft != nil }, set: { _ in })) {
                HotelReviewView(coordinator: coordinator)
            }
            .onAppear { if coordinator.currentProvider == nil { coordinator.start(name: hotelName, city: city) } }
        }
    }
}
