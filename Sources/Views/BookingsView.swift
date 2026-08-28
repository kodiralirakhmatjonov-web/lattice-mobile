import Foundation
import SwiftUI

private let bookingOperationsChangedNotification = Notification.Name("iumrah.business.bookingOperationsChanged")

private enum BookingListFilter: String, CaseIterable, Identifiable {
    case all, availability, payment, confirmed, ready, inTrip, completed, cancelled
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "Все"
        case .availability: return "Проверка"
        case .payment: return "Оплата и данные"
        case .confirmed: return "Подтверждено"
        case .ready: return "К поездке"
        case .inTrip: return "В поездке"
        case .completed: return "Завершено"
        case .cancelled: return "Отменено"
        }
    }
    func matches(_ status: TripStatus) -> Bool {
        switch self {
        case .all: return true
        case .availability: return status == .availabilityCheck
        case .payment: return status == .paymentPending
        case .confirmed: return status == .bookingConfirmed
        case .ready: return status == .readyToTravel
        case .inTrip: return status == .inTrip
        case .completed: return status == .completed
        case .cancelled: return status == .cancelled
        }
    }
}


struct BookingsView: View {
    @State private var bookings: [BookingSummary] = []
    @State private var loading = true
    @State private var deleting = false
    @State private var error: String?
    @State private var filter: BookingListFilter = .all
    @State private var bookingPendingDelete: BookingSummary?
    @State private var selectedBooking: BookingSummary?

    private var filteredBookings: [BookingSummary] {
        bookings.filter { filter.matches(operationalStatus($0)) }
    }

    var body: some View {
        List {
            Section {
                filterBar
                    .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 8, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            if let error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            if filteredBookings.isEmpty && !loading {
                ContentUnavailableView("Бронирований нет", systemImage: "suitcase.rolling", description: Text("В этой категории сейчас нет поездок."))
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            ForEach(filteredBookings) { booking in
                BookingRow(booking: booking, showsChevron: true)
                    .contentShape(Rectangle())
                    .onTapGesture { selectedBooking = booking }
                    .listRowInsets(EdgeInsets(top: 7, leading: 18, bottom: 7, trailing: 18))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            bookingPendingDelete = booking
                        } label: {
                            Label("Удалить", systemImage: "trash")
                        }
                    }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(BusinessDesign.background)
        .navigationTitle("Бронирования")
        .navigationDestination(item: $selectedBooking) { booking in
            BookingDetailView(bookingID: booking.id)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { BusinessSidebarButton() }
            ToolbarItem(placement: .principal) {
                Image("Logo").resizable().scaledToFit().frame(width: 116, height: 28)
            }
        }
        .overlay {
            if loading || deleting {
                ZStack {
                    Color.white.opacity(deleting ? 0.55 : 0.2).ignoresSafeArea()
                    ProgressView(deleting ? "Удаляю…" : "")
                }
            }
        }
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: bookingOperationsChangedNotification)) { _ in
            Task { await load() }
        }
        .refreshable { await load() }
        .alert("Удалить бронирование?", isPresented: Binding(
            get: { bookingPendingDelete != nil },
            set: { if !$0 { bookingPendingDelete = nil } }
        )) {
            Button("Отмена", role: .cancel) { bookingPendingDelete = nil }
            Button("Удалить полностью", role: .destructive) {
                guard let booking = bookingPendingDelete else { return }
                bookingPendingDelete = nil
                Task { await delete(booking) }
            }
        } message: {
            Text("Бронирование будет полностью удалено из основной базы, iumrah Business, чата и связанных операционных данных. Действие нельзя отменить.")
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(BookingListFilter.allCases) { item in
                    Button {
                        withAnimation(.snappy(duration: 0.24)) { filter = item }
                    } label: {
                        HStack(spacing: 6) {
                            Text(item.title)
                            let count = bookings.filter { item.matches(operationalStatus($0)) }.count
                            if item != .all && count > 0 {
                                Text("\(count)")
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 6)
                                    .frame(height: 20)
                                    .background(filter == item ? Color.white.opacity(0.18) : Color.black.opacity(0.05), in: Capsule())
                            }
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(filter == item ? Color.white : BusinessDesign.ink)
                        .padding(.horizontal, 14)
                        .frame(height: 40)
                        .background(filter == item ? Color.black : BusinessDesign.secondarySurface, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18)
        }
    }

    private func operationalStatus(_ booking: BookingSummary) -> TripStatus {
        if let raw = booking.operationStatus, let value = TripStatus(rawValue: raw) { return value }
        switch booking.status {
        case .availabilityCheck: return .availabilityCheck
        case .paymentPending: return .paymentPending
        case .bookingConfirmed: return .bookingConfirmed
        case .readyToTravel: return .readyToTravel
        case .inTrip: return .inTrip
        case .completed: return .completed
        case .cancelled: return .cancelled
        }
    }

    @MainActor private func load() async {
        if bookings.isEmpty { loading = true }
        error = nil
        do { bookings = try await APIClient.shared.bookings() }
        catch { self.error = error.localizedDescription }
        loading = false
    }

    @MainActor private func delete(_ booking: BookingSummary) async {
        deleting = true
        error = nil
        do {
            try await APIClient.shared.deleteBooking(id: booking.id)
            withAnimation(.snappy) { bookings.removeAll { $0.id == booking.id } }
            NotificationCenter.default.post(name: bookingOperationsChangedNotification, object: booking.id)
        } catch {
            self.error = error.localizedDescription
        }
        deleting = false
    }
}
