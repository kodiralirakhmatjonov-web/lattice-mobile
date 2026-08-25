import SwiftUI

@MainActor
final class OverviewStore: ObservableObject {
    @Published var bookings: [BookingSummary] = []
    @Published var unreadChats = 0
    @Published var loading = false

    func reload() async {
        loading = true
        async let bookingsTask = APIClient.shared.bookings()
        async let chatsTask = APIClient.shared.businessChatThreads()
        bookings = (try? await bookingsTask) ?? []
        unreadChats = ((try? await chatsTask) ?? []).filter(\.unreadForStaff).count
        loading = false
    }
}

struct OverviewView: View {
    @EnvironmentObject private var auth: AuthStore
    @StateObject private var store = OverviewStore()

    var checking: Int { store.bookings.filter { operationalStatus($0) == .new || operationalStatus($0) == .availabilityCheck }.count }
    var payment: Int { store.bookings.filter { operationalStatus($0) == .paymentPending }.count }
    var active: Int { store.bookings.filter { [.paid, .bookingConfirmed, .documentsReady, .readyToTravel, .inTrip].contains(operationalStatus($0)) }.count }

    private func operationalStatus(_ booking: BookingSummary) -> TripStatus {
        if let raw = booking.operationStatus, let value = TripStatus(rawValue: raw) { return value }
        switch booking.status {
        case .availabilityCheck: return .availabilityCheck
        case .paymentPending: return .paymentPending
        case .bookingConfirmed: return .bookingConfirmed
        case .readyToTravel: return .readyToTravel
        case .completed: return .completed
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                BusinessBrandLogo(width: 150)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 14) {
                    Text("BOOKING OPERATIONS").font(.caption2.bold()).tracking(2.2).foregroundStyle(.white.opacity(0.52))
                    Text(checking == 0 ? "Очередь подтверждений чистая." : "\(checking) заявок ждут подтверждения.")
                        .font(.system(size: 38, weight: .bold)).tracking(-1.9).foregroundStyle(.white)
                    Text("Мобильный центр управления iumrah. Данные бронирований берутся из текущей D1 базы.")
                        .font(.subheadline).foregroundStyle(.white.opacity(0.62))
                    HStack { Image(systemName: "checkmark.shield.fill"); Text("SUPERADMIN").font(.caption2.bold()).tracking(1.5) }
                        .foregroundStyle(Color.orange).padding(.top, 10)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(26)
                .background(
                    LinearGradient(colors: [Color.black, Color(red: 0.11, green: 0.11, blue: 0.12)], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 36, style: .continuous)
                )

                HStack(spacing: 10) {
                    StatCard(title: "ВСЕГО", value: store.bookings.count, subtitle: "заявок")
                    StatCard(title: "НАЛИЧИЕ", value: checking, subtitle: "проверить", attention: true)
                }
                HStack(spacing: 10) {
                    StatCard(title: "ОПЛАТА", value: payment, subtitle: "ожидают")
                    StatCard(title: "В РАБОТЕ", value: active, subtitle: "активных")
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack { Text("Последние заявки").font(.title2.bold()); Spacer(); if store.loading { ProgressView() } }
                    ForEach(store.bookings.prefix(5)) { booking in
                        NavigationLink {
                            BookingDetailView(bookingID: booking.id)
                        } label: {
                            BookingRow(booking: booking)
                        }
                        .buttonStyle(.plain)
                    }
                    if store.bookings.isEmpty && !store.loading { Text("Заявок пока нет.").foregroundStyle(.secondary).padding(.vertical, 30).frame(maxWidth: .infinity) }
                }
                .padding(18).businessCard(radius: 30)
            }
            .padding(16)
        }
        .background(BusinessDesign.background)
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { BusinessSidebarButton() }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Обновить") { Task { await store.reload() } }
                    Button("Выйти", role: .destructive) { Task { await auth.logout() } }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .task { await store.reload() }
        .refreshable { await store.reload() }
    }
}

private struct StatCard: View {
    let title: String; let value: Int; let subtitle: String; var attention = false
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.caption2.bold()).tracking(1.5).foregroundStyle(.secondary)
            Spacer(minLength: 10)
            Text("\(value)").font(.system(size: 40, weight: .bold)).tracking(-2).foregroundStyle(attention ? BusinessDesign.accent : BusinessDesign.ink)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
        .padding(18).frame(maxWidth: .infinity, minHeight: 130, alignment: .leading)
        .background(attention ? BusinessDesign.softOrange : .white, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(BusinessDesign.line))
    }
}

struct BookingRow: View {
    let booking: BookingSummary
    private var statusLabel: String {
        if let raw = booking.operationStatus, let status = TripStatus(rawValue: raw) { return status.title }
        return booking.status.shortLabel
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(statusLabel).font(.caption2.bold()).lineLimit(1).padding(.horizontal, 9).frame(height: 25).background(BusinessDesign.softOrange, in: Capsule()).foregroundStyle(BusinessDesign.accent)
                Spacer()
                Text(booking.totalUsd, format: .currency(code: "USD").precision(.fractionLength(0))).font(.headline)
            }
            Text(booking.clientName ?? booking.id).font(.subheadline.bold())
            if let pilgrimID = booking.pilgrimID {
                Text("\(pilgrimID) · \(booking.id)").font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
            HStack {
                Label("\(booking.originCode) → \(booking.outboundDestination)", systemImage: "airplane")
                Spacer()
                Label("\(booking.travelerCount)", systemImage: "person.2.fill")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14).background(Color.black.opacity(0.025), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
