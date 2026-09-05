import SwiftUI
import UIKit

@MainActor
final class BusinessSidebarStore: ObservableObject {
    @Published var isOpen = false
    @Published var route: BusinessSidebarRoute?

    func open() { withAnimation(.snappy(duration: 0.3)) { isOpen = true } }
    func close() { withAnimation(.snappy(duration: 0.3)) { isOpen = false } }
    func show(_ route: BusinessSidebarRoute) {
        self.route = route
        close()
    }
}

enum BusinessSidebarRoute: String, Identifiable {
    case profile, sessions, employees, archive, primaryHotels, flights, notifications, esimCenter
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

struct BusinessSidebarHost<Content: View>: View {
    @EnvironmentObject private var auth: AuthStore
    @StateObject private var sidebar = BusinessSidebarStore()
    let content: Content

    @State private var dragOffset: CGFloat = 0

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    private let drawerWidth: CGFloat = min(350, UIScreen.main.bounds.width * 0.86)

    var body: some View {
        ZStack(alignment: .leading) {
            content
                .environmentObject(sidebar)
                .allowsHitTesting(!sidebar.isOpen)
                .scaleEffect(sidebar.isOpen ? 0.985 : 1, anchor: .trailing)

            if sidebar.isOpen {
                Color.black.opacity(0.16)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture { sidebar.close() }
            }

            drawer
                .frame(width: drawerWidth)
                .offset(x: sidebar.isOpen ? min(0, dragOffset) : -drawerWidth + max(0, dragOffset))
                .shadow(color: .black.opacity(sidebar.isOpen ? 0.12 : 0), radius: 28, x: 10)
        }
        .background(Color.white)
        .simultaneousGesture(
            DragGesture(minimumDistance: 12, coordinateSpace: .global)
                .onChanged { value in
                    if sidebar.isOpen {
                        dragOffset = min(0, value.translation.width)
                    } else if value.startLocation.x < 26, value.translation.width > 0 {
                        dragOffset = min(drawerWidth, value.translation.width)
                    }
                }
                .onEnded { value in
                    defer { dragOffset = 0 }
                    if sidebar.isOpen {
                        if value.translation.width < -70 { sidebar.close() }
                    } else if value.startLocation.x < 26, value.translation.width > 70 {
                        sidebar.open()
                    }
                }
        )
        .fullScreenCover(item: $sidebar.route) { route in
            NavigationStack {
                switch route {
                case .profile: ProfileView()
                case .sessions: BusinessSessionsView()
                case .employees: EmployeesView()
                case .archive: ClientArchiveView()
                case .primaryHotels: PrimaryHotelsView()
                case .flights: FlightCurationView()
                case .notifications: NotificationsComposerView()
                case .esimCenter: ESIMCenterView()
                }
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
            sidebarButton("Авиабилеты", icon: "airplane", route: .flights)
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
        .background(.ultraThinMaterial)
        .overlay(alignment: .trailing) { Rectangle().fill(Color.black.opacity(0.06)).frame(width: 0.5) }
        .ignoresSafeArea(edges: .bottom)
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
