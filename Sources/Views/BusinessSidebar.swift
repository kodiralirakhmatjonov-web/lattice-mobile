import SwiftUI
import UIKit

@MainActor
final class BusinessSidebarStore: ObservableObject {
    @Published var isOpen = false
    @Published var route: BusinessSidebarRoute?

    func open() {
        withAnimation(.interactiveSpring(response: 0.38, dampingFraction: 0.88, blendDuration: 0.12)) {
            isOpen = true
        }
    }

    func close() {
        withAnimation(.interactiveSpring(response: 0.36, dampingFraction: 0.90, blendDuration: 0.10)) {
            isOpen = false
        }
    }

    func show(_ route: BusinessSidebarRoute) {
        self.route = route
        close()
    }
}

enum BusinessSidebarRoute: String, Identifiable {
    case profile, sessions, employees, archive, primaryHotels, payments, ziyarats, flights, notifications, esimCenter
    var id: String { rawValue }
}

struct BusinessSidebarButton: View {
    @EnvironmentObject private var sidebar: BusinessSidebarStore

    var body: some View {
        Button { sidebar.open() } label: {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 17, weight: .semibold))
        }
        .accessibilityLabel("Меню")
    }
}

/// Root-level interactive drawer modeled after the ChatGPT iOS sidebar behavior:
/// the sidebar lives underneath while the complete app surface follows the user's finger.
private struct DrawerLeadingEdge: View {
    let progress: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let radius = 31 * progress
            ZStack(alignment: .leading) {
                // These caps reproduce the rounded ChatGPT-like leading corners
                // without masking/clipping the full application hierarchy.
                Circle()
                    .fill(BusinessDesign.background)
                    .frame(width: radius * 2, height: radius * 2)
                    .offset(x: -radius, y: -radius)
                Circle()
                    .fill(BusinessDesign.background)
                    .frame(width: radius * 2, height: radius * 2)
                    .offset(x: -radius, y: proxy.size.height - radius)
            }
        }
    }
}

struct BusinessSidebarHost<Content: View>: View {
    @EnvironmentObject private var auth: AuthStore
    @StateObject private var sidebar = BusinessSidebarStore()
    let content: Content

    @State private var dragTranslation: CGFloat = 0
    @State private var horizontalDragIsActive = false

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    private var screenWidth: CGFloat { UIScreen.main.bounds.width }
    private var drawerWidth: CGFloat { min(390, screenWidth * 0.74) }

    private var contentOffset: CGFloat {
        let base = sidebar.isOpen ? drawerWidth : 0
        return min(drawerWidth, max(0, base + dragTranslation))
    }

    private var openProgress: CGFloat {
        guard drawerWidth > 0 else { return 0 }
        return min(1, max(0, contentOffset / drawerWidth))
    }

    var body: some View {
        ZStack(alignment: .leading) {
            drawerLayer

            appSurface
        }
        .background(BusinessDesign.background.ignoresSafeArea())
        .fullScreenCover(item: $sidebar.route) { route in
            NavigationStack {
                switch route {
                case .profile: ProfileView()
                case .sessions: BusinessSessionsView()
                case .employees: EmployeesView()
                case .archive: ClientArchiveView()
                case .primaryHotels: PrimaryHotelsView()
                case .payments: PaymentsView()
                case .ziyarats: ZiyaratsView()
                case .flights: FlightCurationView()
                case .notifications: NotificationsComposerView()
                case .esimCenter: ESIMCenterView()
                }
            }
        }
    }

    private var drawerLayer: some View {
        drawer
            .frame(width: drawerWidth)
            .frame(maxHeight: .infinity)
            // Tiny parallax keeps the drawer visually anchored underneath the page,
            // rather than making it look like a conventional slide-over panel.
            .offset(x: -18 * (1 - openProgress))
            .opacity(0.82 + (0.18 * openProgress))
            .allowsHitTesting(openProgress > 0.02)
            .accessibilityHidden(openProgress < 0.02)
            .zIndex(2)
    }

    private var appSurface: some View {
        content
            .environmentObject(sidebar)
            // Keep the original TabView/NavigationStack layout untouched. Explicit
            // screen-sized frames or a root clip here crop the top/bottom safe areas.
            .background(BusinessDesign.background)
            .overlay(alignment: .leading) {
                // Visual-only rounded leading edge. It does not clip the root view,
                // so the status bar and tab bar retain their original geometry.
                if openProgress > 0.001 {
                    DrawerLeadingEdge(progress: openProgress)
                        .allowsHitTesting(false)
                }
            }
            .shadow(
                color: .black.opacity(0.10 * openProgress),
                radius: 30 * openProgress,
                x: -8,
                y: 0
            )
            .offset(x: contentOffset)
            // The drag recognizer belongs only to the moving app surface. The drawer
            // itself has no competing gesture recognizer, so all sidebar buttons tap normally.
            .simultaneousGesture(drawerGesture)
            .overlay {
                if sidebar.isOpen && !horizontalDragIsActive {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture { sidebar.close() }
                }
            }
            .zIndex(1)
    }

    private var drawerGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                let dx = value.translation.width
                let dy = value.translation.height

                if !horizontalDragIsActive {
                    // Do not steal vertical scrolling. When closed, ChatGPT-style opening
                    // is intentionally allowed from most of the left/center part of the page,
                    // not only from a tiny edge hit target.
                    let isHorizontal = abs(dx) > max(10, abs(dy) * 1.18)
                    let mayOpenFromHere = value.startLocation.x <= screenWidth * 0.72
                    let opening = !sidebar.isOpen && dx > 0 && mayOpenFromHere
                    let closing = sidebar.isOpen && dx < 0

                    guard isHorizontal && (opening || closing) else { return }
                    horizontalDragIsActive = true
                }

                guard horizontalDragIsActive else { return }

                if sidebar.isOpen {
                    dragTranslation = max(-drawerWidth, min(0, dx))
                } else {
                    dragTranslation = min(drawerWidth, max(0, dx))
                }
            }
            .onEnded { value in
                guard horizontalDragIsActive else {
                    dragTranslation = 0
                    return
                }

                let predicted = value.predictedEndTranslation.width
                let current = contentOffset
                let projected = min(drawerWidth, max(0, (sidebar.isOpen ? drawerWidth : 0) + predicted))
                let openingVelocityIntent = predicted > value.translation.width + 22
                let closingVelocityIntent = predicted < value.translation.width - 22

                let shouldOpen: Bool
                if sidebar.isOpen {
                    shouldOpen = !(projected < drawerWidth * 0.58 || closingVelocityIntent)
                } else {
                    shouldOpen = projected > drawerWidth * 0.32 || openingVelocityIntent || current > drawerWidth * 0.42
                }

                dragTranslation = 0
                horizontalDragIsActive = false

                withAnimation(.interactiveSpring(response: 0.38, dampingFraction: 0.88, blendDuration: 0.12)) {
                    sidebar.isOpen = shouldOpen
                }
            }
    }

    private var drawer: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                BusinessBrandLogo(width: 138)
                Text(auth.user?.displayName ?? "iumrah Business")
                    .font(.title3.bold())
                Text(auth.user?.login ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 22)
            .padding(.top, 22)
            .padding(.bottom, 24)

            sidebarButton("Мой профиль", icon: "person.crop.circle", route: .profile)
            sidebarButton("Устройства и сеансы", icon: "lock.shield", route: .sessions)
            sidebarButton("Сотрудники", icon: "person.2", route: .employees)
            sidebarButton("Архив клиентов", icon: "archivebox", route: .archive)
            sidebarButton("Primary Hotels", icon: "building.2.crop.circle", route: .primaryHotels)
            sidebarButton("Payments", icon: "creditcard.and.123", route: .payments)
            sidebarButton("Ziyarats", icon: "map.fill", route: .ziyarats)
            if auth.user?.role.lowercased() == "superadmin" {
                sidebarButton("eSIM Center", icon: "simcard.2.fill", route: .esimCenter)
            }
            sidebarButton("Создать уведомление", icon: "bell.badge.fill", route: .notifications)

            Spacer()

            Button(role: .destructive) {
                Task { await auth.logout() }
            } label: {
                Label("Выйти", systemImage: "rectangle.portrait.and.arrow.right")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .frame(height: 52)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.bottom, 18)
        }
        .frame(maxHeight: .infinity)
        .background(BusinessDesign.background.ignoresSafeArea())
    }

    private func sidebarButton(_ title: String, icon: String, route: BusinessSidebarRoute) -> some View {
        Button { sidebar.show(route) } label: {
            HStack(spacing: 13) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 28)
                Text(title).font(.body.weight(.semibold))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 18)
            .frame(height: 54)
            .background(BusinessDesign.secondarySurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }
}
