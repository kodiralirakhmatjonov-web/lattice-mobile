import SwiftUI

struct BookingsView: View {
    @State private var bookings: [BookingSummary] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(.red) }
            ForEach(bookings) { booking in
                NavigationLink {
                    BookingDetailView(bookingID: booking.id)
                } label: {
                    BookingRow(booking: booking)
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain).scrollContentBackground(.hidden).background(BusinessDesign.background)
        .navigationTitle("Бронирования")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { BusinessSidebarButton() }
            ToolbarItem(placement: .principal) {
                Image("Logo").resizable().scaledToFit().frame(width: 116, height: 28)
            }
        }
        .overlay { if loading { ProgressView() } }
        .task { await load() }
        .refreshable { await load() }
    }

    func load() async {
        loading = true; error = nil
        do { bookings = try await APIClient.shared.bookings() } catch { self.error = error.localizedDescription }
        loading = false
    }
}
