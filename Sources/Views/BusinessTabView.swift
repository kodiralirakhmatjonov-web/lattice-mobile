import SwiftUI

/// Adaptive application shell.
/// - Compact width: keeps the existing iPhone bottom-tab + drawer experience.
/// - Regular width / iPad: uses a persistent split-view sidebar.
/// - Mac Catalyst: always uses the desktop split-view sidebar.
struct BusinessTabView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var usesWorkspaceLayout: Bool {
#if targetEnvironment(macCatalyst)
        true
#else
        horizontalSizeClass == .regular
#endif
    }

    var body: some View {
        if usesWorkspaceLayout {
            BusinessWorkspaceView()
        } else {
            BusinessCompactTabView()
        }
    }
}

private struct BusinessCompactTabView: View {
    var body: some View {
        BusinessSidebarHost {
            TabView {
                NavigationStack { OverviewView() }
                    .tabItem { Label("Обзор", systemImage: "square.grid.2x2.fill") }
                NavigationStack { BookingsView() }
                    .tabItem { Label("Брони", systemImage: "suitcase.rolling.fill") }
                NavigationStack { ChatsView() }
                    .tabItem { Label("Чаты", systemImage: "message.fill") }
                NavigationStack { HotelsView() }
                    .tabItem { Label("Отели", systemImage: "building.2.fill") }
                NavigationStack { FlightCurationView(tabMode: true) }
                    .tabItem { Label("Авиабилеты", systemImage: "airplane") }
            }
            .tint(BusinessDesign.ink)
        }
    }
}

private enum BusinessWorkspaceSection: String, Identifiable, CaseIterable {
    case overview
    case bookings
    case chats
    case hotels
    case flights
    case profile
    case sessions
    case employees
    case archive
    case primaryHotels
    case payments
    case ziyarats
    case notifications
    case esimCenter

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Обзор"
        case .bookings: return "Бронирования"
        case .chats: return "Чаты"
        case .hotels: return "Отели"
        case .flights: return "Авиабилеты"
        case .profile: return "Мой профиль"
        case .sessions: return "Устройства и сеансы"
        case .employees: return "Сотрудники"
        case .archive: return "Архив клиентов"
        case .primaryHotels: return "Primary Hotels"
        case .payments: return "Payments"
        case .ziyarats: return "Ziyarats"
        case .notifications: return "Создать уведомление"
        case .esimCenter: return "eSIM Center"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: return "square.grid.2x2.fill"
        case .bookings: return "suitcase.rolling.fill"
        case .chats: return "message.fill"
        case .hotels: return "building.2.fill"
        case .flights: return "airplane"
        case .profile: return "person.crop.circle"
        case .sessions: return "lock.shield"
        case .employees: return "person.2"
        case .archive: return "archivebox"
        case .primaryHotels: return "building.2.crop.circle"
        case .payments: return "creditcard.and.123"
        case .ziyarats: return "map.fill"
        case .notifications: return "bell.badge.fill"
        case .esimCenter: return "simcard.2.fill"
        }
    }

    static let primary: [BusinessWorkspaceSection] = [
        .overview, .bookings, .chats, .hotels, .flights
    ]

    static let administration: [BusinessWorkspaceSection] = [
        .profile, .sessions, .employees, .archive, .primaryHotels, .payments, .ziyarats, .notifications
    ]
}

private struct BusinessWorkspaceView: View {
    @EnvironmentObject private var auth: AuthStore
    @State private var selection: BusinessWorkspaceSection = .overview
    @StateObject private var compatibilitySidebarStore = BusinessSidebarStore()

    var body: some View {
        NavigationSplitView {
            List {
                Section {
                    ForEach(BusinessWorkspaceSection.primary) { section in
                        workspaceRow(section)
                    }
                }

                Section("Управление") {
                    ForEach(BusinessWorkspaceSection.administration) { section in
                        workspaceRow(section)
                    }
                    if auth.user?.role.lowercased() == "superadmin" {
                        workspaceRow(.esimCenter)
                    }
                }

                Section {
                    Button(role: .destructive) {
                        Task { await auth.logout() }
                    } label: {
                        Label("Выйти", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
            .navigationTitle("iumrah Business")
            .navigationSplitViewColumnWidth(min: 220, ideal: 264, max: 320)
        } detail: {
            NavigationStack {
                workspaceDestination(selection)
            }
            .id(selection)
        }
        .navigationSplitViewStyle(.balanced)
        // Existing destination views contain BusinessSidebarButton in toolbars.
        // Keep the environment object available, while the button itself hides in
        // the persistent-sidebar layout.
        .environmentObject(compatibilitySidebarStore)
        .environment(\.businessUsesPersistentSidebar, true)
        .tint(BusinessDesign.ink)
        .background(BusinessDesign.background.ignoresSafeArea())
    }

    @ViewBuilder
    private func workspaceRow(_ section: BusinessWorkspaceSection) -> some View {
        Button {
            selection = section
        } label: {
            Label(section.title, systemImage: section.systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selection == section ? BusinessDesign.ink : .primary)
        .fontWeight(selection == section ? .semibold : .regular)
    }

    @ViewBuilder
    private func workspaceDestination(_ section: BusinessWorkspaceSection) -> some View {
        switch section {
        case .overview:
            OverviewView()
        case .bookings:
            BookingsView()
        case .chats:
            ChatsView()
        case .hotels:
            HotelsView()
        case .flights:
            FlightCurationView(tabMode: true)
        case .profile:
            ProfileView()
        case .sessions:
            BusinessSessionsView()
        case .employees:
            EmployeesView()
        case .archive:
            ClientArchiveView()
        case .primaryHotels:
            PrimaryHotelsView(tabMode: true)
        case .payments:
            PaymentsView()
        case .ziyarats:
            ZiyaratsView()
        case .notifications:
            NotificationsComposerView()
        case .esimCenter:
            ESIMCenterView()
        }
    }
}
