import SwiftUI

struct BusinessTabView: View {
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
                NavigationStack { PrimaryHotelsView(tabMode: true) }
                    .tabItem { Label("Primary", systemImage: "star.square.fill") }
            }
            .tint(BusinessDesign.ink)
        }
    }
}
