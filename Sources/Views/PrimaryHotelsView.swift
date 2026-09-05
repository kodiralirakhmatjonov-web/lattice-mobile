import SwiftUI

struct PrimaryHotelsView: View {
    var tabMode = false
    @Environment(\.dismiss) private var dismiss
    @State private var city = "Makkah"
    @State private var hotels: [HotelListItem] = []
    @State private var assignments: [PrimaryHotelAssignment] = []
    @State private var loading = true
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Город", selection: $city) {
                    Text("Makkah").tag("Makkah")
                    Text("Madinah").tag("Madinah")
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 5) {
                    Text("Primary Hotels").font(.largeTitle.bold())
                    Text("До 3 рекомендуемых iumrah отелей на каждую категорию генератора. Фактическая звёздность отеля может отличаться от категории — например, 1★ отель можно назначить в 3★.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }

                if let errorMessage { Text(errorMessage).font(.footnote).foregroundStyle(.red) }

                ForEach(1...5, id: \.self) { stars in
                    NavigationLink {
                        PrimaryHotelCategoryPicker(city: city, stars: stars, hotels: availableHotels(for: stars), selectedIDs: selectedIDs(for: stars)) {
                            Task { await load() }
                        }
                    } label: {
                        categoryCard(stars)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(18)
        }
        .background(Color.white)
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if tabMode { BusinessSidebarButton() } else { Button("Закрыть") { dismiss() } }
            }
        }
        .overlay { if loading { ProgressView() } }
        .task { await load() }
        .onChange(of: city) { _, _ in Task { await load() } }
    }

    private func selectedIDs(for stars: Int) -> [String] {
        assignments.filter { $0.city.caseInsensitiveCompare(city) == .orderedSame && $0.stars == stars }.sorted { $0.position < $1.position }.map { $0.hotel.id }
    }

    private func availableHotels(for stars: Int) -> [HotelListItem] {
        _ = stars
        return hotels.filter {
            $0.city.caseInsensitiveCompare(city) == .orderedSame && $0.status == "published"
        }
    }

    private func categoryCard(_ stars: Int) -> some View {
        let selected = assignments.filter { $0.city.caseInsensitiveCompare(city) == .orderedSame && $0.stars == stars }.sorted { $0.position < $1.position }
        return VStack(alignment: .leading, spacing: 12) {
            HStack { Text(String(repeating: "★", count: stars)).font(.headline); Spacer(); Text("\(selected.count)/3").foregroundStyle(.secondary); Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary) }
            if selected.isEmpty { Text("Не настроено").foregroundStyle(.secondary) }
            else {
                ForEach(selected) { item in
                    HStack(spacing: 10) {
                        if let url = AppConfig.absoluteURL(item.hotel.coverImageURL) {
                            AsyncImage(url: url) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                BusinessDesign.secondarySurface
                            }
                            .frame(width: 46, height: 46)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        Text(item.hotel.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                        Spacer()
                    }
                }
            }
        }
        .padding(16).businessCard(radius: 26)
    }

    @MainActor private func load() async {
        loading = true
        do {
            async let hotelRequest = APIClient.shared.hotels()
            async let primaryRequest = APIClient.shared.primaryHotels(city: city)
            hotels = try await hotelRequest
            assignments = try await primaryRequest
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
        loading = false
    }
}

private struct PrimaryHotelCategoryPicker: View {
    let city: String
    let stars: Int
    let hotels: [HotelListItem]
    @State var selectedIDs: [String]
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                ForEach(hotels) { hotel in
                    Button { toggle(hotel.id) } label: {
                        HStack(spacing: 12) {
                            if let url = AppConfig.absoluteURL(hotel.coverImageURL) {
                                AsyncImage(url: url) { image in
                                    image.resizable().scaledToFill()
                                } placeholder: {
                                    BusinessDesign.secondarySurface
                                }
                                .frame(width: 54, height: 54)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(hotel.name).font(.headline).foregroundStyle(.primary)
                                HStack(spacing: 6) {
                                    if let actualStars = hotel.stars {
                                        Text("\(actualStars)★")
                                    } else {
                                        Text("Без звёзд")
                                    }
                                    Text("·")
                                    Text("\(hotel.roomCount) номеров")
                                    Text("·")
                                    Text("\(hotel.imageCount) фото")
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: selectedIDs.contains(hotel.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(selectedIDs.contains(hotel.id) ? .black : .secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            } header: { Text("Выберите до 3 отелей") }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
        }
        .navigationTitle("\(city) · \(stars)★")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Сохранить") { Task { await save() } }.fontWeight(.semibold).disabled(saving) } }
    }

    private func toggle(_ id: String) {
        if let index = selectedIDs.firstIndex(of: id) { selectedIDs.remove(at: index) }
        else if selectedIDs.count < 3 { selectedIDs.append(id) }
    }

    @MainActor private func save() async {
        saving = true
        do { _ = try await APIClient.shared.savePrimaryHotels(city: city, stars: stars, hotelIDs: selectedIDs); onSaved(); dismiss() }
        catch { errorMessage = error.localizedDescription }
        saving = false
    }
}
