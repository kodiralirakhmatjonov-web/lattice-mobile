import SwiftUI

struct HotelsView: View {
    @State private var hotels: [HotelListItem] = []
    @State private var loading = false
    @State private var showAdd = false
    @State private var backendUnavailable = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                HStack(spacing: 10) {
                    HotelCountCard(title: "Makkah", count: hotels.filter { $0.city.lowercased().contains("makk") }.count)
                    HotelCountCard(title: "Madinah", count: hotels.filter { $0.city.lowercased().contains("mad") }.count)
                }
                if backendUnavailable {
                    Text("Hotel API ещё не установлен на iumrah.app. Сначала примените backend patch из второго ZIP.")
                        .font(.footnote).foregroundStyle(.orange).padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text("База отелей").font(.title2.bold()); Spacer(); if loading { ProgressView() } }
                    if hotels.isEmpty && !loading {
                        ContentUnavailableView("Отелей пока нет", systemImage: "building.2", description: Text("Добавьте первый отель через Importer."))
                    }
                    ForEach(hotels) { hotel in
                        HStack(spacing: 12) {
                            Group {
                                if let imageURL = AppConfig.absoluteURL(hotel.coverImageURL) {
                                    AsyncImage(url: imageURL) { phase in
                                        if let image = phase.image { image.resizable().scaledToFill() }
                                        else { Color.black.opacity(0.05).overlay(Image(systemName: "building.2.fill").foregroundStyle(.secondary)) }
                                    }
                                } else {
                                    Color.black.opacity(0.05).overlay(Image(systemName: "building.2.fill").foregroundStyle(.secondary))
                                }
                            }
                            .frame(width: 58, height: 58).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(hotel.name).font(.subheadline.bold()).lineLimit(1)
                                Text("\(hotel.city) · \(hotel.imageCount) фото · \(hotel.roomCount) комнат").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(hotel.status.uppercased()).font(.system(size: 8, weight: .black)).foregroundStyle(.secondary)
                        }
                        .padding(12).background(Color.black.opacity(0.025), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }
                }
                .padding(16).businessCard(radius: 30)
            }
            .padding(16)
        }
        .background(BusinessDesign.background)
        .navigationTitle("Отели")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { showAdd = true } label: { Image(systemName: "plus.circle.fill").font(.title3) } } }
        .sheet(isPresented: $showAdd, onDismiss: { Task { await load() } }) { AddHotelView() }
        .task { await load() }
        .refreshable { await load() }
    }

    func load() async {
        loading = true; backendUnavailable = false
        do { hotels = try await APIClient.shared.hotels() }
        catch { backendUnavailable = true }
        loading = false
    }
}

private struct HotelCountCard: View {
    let title: String; let count: Int
    var body: some View {
        VStack(alignment: .leading) {
            Text(title.uppercased()).font(.caption2.bold()).tracking(1.5).foregroundStyle(.secondary)
            Spacer()
            Text("\(count)").font(.system(size: 38, weight: .bold)).tracking(-2)
            Text("hotels").font(.caption).foregroundStyle(.secondary)
        }
        .padding(18).frame(maxWidth: .infinity, minHeight: 125, alignment: .leading).businessCard(radius: 26)
    }
}

private struct AddHotelView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var hotelName = ""
    @State private var city = "Makkah"
    @State private var importRequest: ImportRequest?

    struct ImportRequest: Identifiable { let id = UUID(); let name: String; let city: String }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Text("Новый отель").font(.system(size: 38, weight: .bold)).tracking(-1.8)
                Text("Введите точное или привычное название. iumrah последовательно проверит Booking, Expedia и Agoda на устройстве.")
                    .font(.subheadline).foregroundStyle(.secondary)
                TextField("Например, voco Makkah", text: $hotelName)
                    .padding(.horizontal, 18).frame(height: 58).background(.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                Picker("Город", selection: $city) { Text("Makkah").tag("Makkah"); Text("Madinah").tag("Madinah") }
                    .pickerStyle(.segmented)
                Button {
                    let clean = hotelName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !clean.isEmpty else { return }
                    importRequest = ImportRequest(name: clean, city: city)
                } label: {
                    Label("Найти и импортировать", systemImage: "sparkle.magnifyingglass")
                        .font(.headline).frame(maxWidth: .infinity).frame(height: 56).foregroundStyle(.white).background(BusinessDesign.ink, in: Capsule())
                }.disabled(hotelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer()
            }
            .padding(18).background(BusinessDesign.background)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Закрыть") { dismiss() } } }
            .fullScreenCover(item: $importRequest) { request in HotelImportSessionView(hotelName: request.name, city: request.city) }
        }
    }
}
