import SwiftUI
import UIKit

@MainActor
final class BusinessSidebarStore: ObservableObject {
    @Published var isOpen = false
    @Published var route: BusinessSidebarRoute?

    func open() {
        withAnimation(.interactiveSpring(response: 0.36, dampingFraction: 0.88, blendDuration: 0.10)) {
            isOpen = true
        }
    }

    func close() {
        withAnimation(.interactiveSpring(response: 0.34, dampingFraction: 0.90, blendDuration: 0.08)) {
            isOpen = false
        }
    }

    func show(_ route: BusinessSidebarRoute) {
        // Present the destination immediately. The full-screen destination owns its
        // own hit-testing and the drawer is reset underneath for the return trip.
        self.route = route
        isOpen = false
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

/// Root drawer with the same interaction model as ChatGPT on iPhone:
/// the drawer is a stationary, opaque surface underneath the application,
/// while the complete application surface follows the user's horizontal drag.
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
    private var drawerWidth: CGFloat { min(326, screenWidth * 0.76) }

    private var contentOffset: CGFloat {
        let restingOffset = sidebar.isOpen ? drawerWidth : 0
        return min(drawerWidth, max(0, restingOffset + dragTranslation))
    }

    private var openProgress: CGFloat {
        guard drawerWidth > 0 else { return 0 }
        return min(1, max(0, contentOffset / drawerWidth))
    }

    var body: some View {
        ZStack(alignment: .leading) {
            // Always opaque. Never animate opacity on the drawer itself: doing so
            // makes the screen underneath visible through menu rows.
            drawerLayer
                .zIndex(0)

            appSurface
                .zIndex(1)
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
        ZStack(alignment: .leading) {
            // Dedicated solid backdrop extending through status/home-indicator areas.
            BusinessDesign.background
                .ignoresSafeArea()

            drawerContent
        }
        .frame(width: drawerWidth)
        .frame(maxHeight: .infinity)
        // The drawer only becomes interactive once it is intentionally open.
        // During an interactive drag, the moving app surface owns the gesture.
        .allowsHitTesting(sidebar.isOpen && !horizontalDragIsActive)
        .accessibilityHidden(!sidebar.isOpen)
    }

    private var appSurface: some View {
        // IMPORTANT: all overlays/gestures that belong to the app surface are added
        // BEFORE offset. This guarantees their hit region travels with the page and
        // never remains invisibly on top of the revealed drawer.
        content
            .environmentObject(sidebar)
            .background(BusinessDesign.background)
            .overlay {
                if sidebar.isOpen && !horizontalDragIsActive {
                    // Transparent interaction layer only over the MOVED app surface.
                    // It prevents accidental interaction with the page and closes the
                    // drawer on tap, just like ChatGPT.
                    Rectangle()
                        .fill(Color.black.opacity(0.0001))
                        .contentShape(Rectangle())
                        .onTapGesture { sidebar.close() }
                }
            }
            .simultaneousGesture(drawerGesture)
            // No root frame and no clipShape here. Navigation bars, status-area
            // content and the TabView keep their original full-height geometry.
            .shadow(
                color: .black.opacity(0.14 * openProgress),
                radius: 26 * openProgress,
                x: -8,
                y: 0
            )
            .offset(x: contentOffset)
    }

    private var drawerGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                let dx = value.translation.width
                let dy = value.translation.height

                if !horizontalDragIsActive {
                    // Lock only after the gesture is clearly horizontal. This keeps
                    // vertical ScrollViews and Lists responsive.
                    let isHorizontal = abs(dx) > max(10, abs(dy) * 1.20)

                    // Opening may begin from the left or the center of the page,
                    // matching the demonstrated ChatGPT gesture.
                    let mayOpenFromHere = value.startLocation.x <= screenWidth * 0.78
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
                let projectedOffset = min(
                    drawerWidth,
                    max(0, (sidebar.isOpen ? drawerWidth : 0) + predicted)
                )

                let fastOpen = predicted > value.translation.width + 24
                let fastClose = predicted < value.translation.width - 24

                let shouldOpen: Bool
                if sidebar.isOpen {
                    shouldOpen = !(projectedOffset < drawerWidth * 0.58 || fastClose)
                } else {
                    shouldOpen = projectedOffset > drawerWidth * 0.34 || fastOpen
                }

                dragTranslation = 0
                horizontalDragIsActive = false

                withAnimation(.interactiveSpring(response: 0.36, dampingFraction: 0.88, blendDuration: 0.10)) {
                    sidebar.isOpen = shouldOpen
                }
            }
    }

    private var drawerContent: some View {
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

            Spacer(minLength: 12)

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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func sidebarButton(_ title: String, icon: String, route: BusinessSidebarRoute) -> some View {
        Button { sidebar.show(route) } label: {
            HStack(spacing: 13) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 28)
                Text(title)
                    .font(.body.weight(.semibold))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 18)
            .frame(height: 54)
            .background(
                BusinessDesign.secondarySurface,
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }
}
