import SwiftUI

struct ClientArchiveView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var pilgrims: [PilgrimSummary] = []
    @State private var search = ""
    @State private var loading = true
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            ForEach(filtered) { pilgrim in
                NavigationLink { PilgrimDetailView(pilgrimID: pilgrim.id) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(pilgrim.displayName).font(.headline)
                            Spacer()
                            Text(pilgrim.id).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 10) {
                            Label("\(pilgrim.completedTrips ?? 0) завершено", systemImage: "checkmark.circle")
                            if !pilgrim.phone.isEmpty { Label(pilgrim.phone, systemImage: "phone") }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 5)
                }
            }
        }
        .listStyle(.plain).scrollContentBackground(.hidden).background(Color.white)
        .navigationTitle("Архив клиентов")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Имя, телефон или ID")
        .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Закрыть") { dismiss() } } }
        .overlay { if loading { ProgressView() } }
        .task { await load() }
        .refreshable { await load() }
    }

    private var filtered: [PilgrimSummary] {
        guard !search.isEmpty else { return pilgrims }
        let q = search.lowercased()
        return pilgrims.filter { $0.displayName.lowercased().contains(q) || $0.phone.lowercased().contains(q) || $0.email.lowercased().contains(q) || $0.id.lowercased().contains(q) }
    }

    @MainActor private func load() async {
        loading = true
        do { pilgrims = try await APIClient.shared.pilgrims(archiveOnly: true); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
        loading = false
    }
}

private struct PilgrimDetailView: View {
    let pilgrimID: String
    @State private var detail: PilgrimDetailResponse?
    @State private var loading = true

    var body: some View {
        ScrollView {
            if let detail {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(detail.pilgrim.displayName).font(.largeTitle.bold())
                        Text(detail.pilgrim.id).font(.subheadline.monospaced()).foregroundStyle(.secondary)
                        if !detail.pilgrim.phone.isEmpty { Label(detail.pilgrim.phone, systemImage: "phone") }
                        if !detail.pilgrim.email.isEmpty { Label(detail.pilgrim.email, systemImage: "envelope") }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(18).businessCard(radius: 28)

                    Text("Поездки").font(.title2.bold())
                    ForEach(detail.trips, id: \.tripID) { trip in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack { Text(trip.bookingID).font(.headline); Spacer(); Text(trip.tripStatus.title).font(.caption.bold()) }
                            Text([trip.startDate, trip.endDate].compactMap { $0 }.joined(separator: " – ")).font(.caption).foregroundStyle(.secondary)
                            if !trip.confirmationNumber.isEmpty { Text("Подтверждение: \(trip.confirmationNumber)").font(.caption) }
                        }
                        .padding(14).businessCard(radius: 22)
                    }
                }
                .padding(18)
            } else if loading { ProgressView().padding(.top, 60) }
        }
        .background(Color.white).navigationTitle("Паломник").navigationBarTitleDisplayMode(.inline)
        .task { detail = try? await APIClient.shared.pilgrimDetail(id: pilgrimID); loading = false }
    }
}
