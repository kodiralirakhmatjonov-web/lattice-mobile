import SwiftUI
import UIKit

struct HotelsView: View {
    @State private var hotels: [HotelListItem] = []
    @State private var loading = false
    @State private var showAdd = false
    @State private var backendUnavailable = false
    @State private var cloudHealth: HotelCloudHealthResponse?
    @State private var backendMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center) {
                    BusinessBrandLogo(width: 142)
                    Spacer()
                    Button { showAdd = true } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .bold))
                            .frame(width: 42, height: 42)
                            .background(.black, in: Circle())
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Hotels")
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .tracking(-1.5)
                    Text("Собственная база iumrah для Makkah и Madinah")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    HotelCountCard(title: "Makkah", count: hotels.filter { $0.city.lowercased().contains("makk") }.count)
                    HotelCountCard(title: "Madinah", count: hotels.filter { $0.city.lowercased().contains("mad") }.count)
                }

                HStack(spacing: 10) {
                    Image(systemName: backendUnavailable ? "exclamationmark.icloud.fill" : "checkmark.icloud.fill")
                        .foregroundStyle(backendUnavailable ? .red : .green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(backendUnavailable ? "Hotels Cloud недоступен" : "Hotels Cloud подключён")
                            .font(.caption.weight(.semibold))
                        if let cloudHealth, !backendUnavailable {
                            Text("D1 · R2 · \(cloudHealth.hotels) отелей")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else if let backendMessage {
                            Text(backendMessage)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer()
                    if loading { ProgressView().controlSize(.small) }
                }
                .padding(14)
                .background(BusinessDesign.secondarySurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("База отелей").font(.title2.bold())
                        Spacer()
                        Text("\(hotels.count)").foregroundStyle(.secondary)
                    }

                    if hotels.isEmpty && !loading {
                        ContentUnavailableView(
                            "Отелей пока нет",
                            systemImage: "building.2",
                            description: Text("Добавьте отель по прямой ссылке Booking или Expedia.")
                        )
                    }

                    ForEach(hotels) { hotel in
                        HStack(spacing: 13) {
                            Group {
                                if let imageURL = AppConfig.absoluteURL(hotel.coverImageURL) {
                                    AsyncImage(url: imageURL) { phase in
                                        if let image = phase.image {
                                            image.resizable().scaledToFill()
                                        } else {
                                            placeholder
                                        }
                                    }
                                } else {
                                    placeholder
                                }
                            }
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                            VStack(alignment: .leading, spacing: 4) {
                                Text(hotel.name)
                                    .font(.subheadline.bold())
                                    .lineLimit(1)
                                HStack(spacing: 5) {
                                    Text(hotel.city)
                                    Text("·")
                                    Text("\(hotel.imageCount) фото")
                                    Text("·")
                                    Text("\(hotel.roomCount) номеров")
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)

                                if let rating = hotel.rating {
                                    HStack(spacing: 4) {
                                        Image(systemName: "star.fill").font(.caption2)
                                        Text(rating.formatted(.number.precision(.fractionLength(1))))
                                        if let count = hotel.reviewCount { Text("· \(count) отзывов") }
                                    }
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text(hotel.status == "published" ? "LIVE" : "DRAFT")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(hotel.status == "published" ? .green : .secondary)
                        }
                        .padding(12)
                        .background(BusinessDesign.tertiarySurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }
                }
                .padding(16)
                .businessCard(radius: 28)
            }
            .padding(.vertical, 14)
        }
        .contentMargins(.horizontal, 18, for: .scrollContent)
        .background(Color.white)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAdd, onDismiss: { Task { await load() } }) {
            AddHotelView()
        }
        .task { await load() }
        .refreshable { await load() }
    }

    @ViewBuilder private var placeholder: some View {
        BusinessDesign.secondarySurface
            .overlay(Image(systemName: "building.2.fill").foregroundStyle(.secondary))
    }

    func load() async {
        loading = true
        backendUnavailable = false
        backendMessage = nil
        do {
            async let healthRequest = APIClient.shared.hotelCloudHealth()
            async let hotelsRequest = APIClient.shared.hotels()
            cloudHealth = try await healthRequest
            hotels = try await hotelsRequest
        } catch {
            backendUnavailable = true
            backendMessage = error.localizedDescription
            cloudHealth = nil
        }
        loading = false
    }
}

private struct HotelCountCard: View {
    let title: String
    let count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption2.bold())
                .tracking(1.5)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text("\(count)")
                .font(.system(size: 38, weight: .bold, design: .rounded))
                .tracking(-1.5)
            Text("hotels")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 126, alignment: .leading)
        .businessCard(radius: 26)
    }
}

private struct AddHotelView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var sourceURL = ""
    @State private var importRequest: ImportRequest?

    struct ImportRequest: Identifiable {
        let id = UUID()
        let url: String
    }

    private var detectedProvider: HotelImportCoordinator.Provider? {
        var text = sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.lowercased().hasPrefix("http") { text = "https://\(text)" }
        guard let url = URL(string: text) else { return nil }
        return HotelImportCoordinator.Provider.detect(from: url)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    BusinessBrandLogo(width: 132)
                        .padding(.top, 6)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Добавить отель")
                            .font(.system(size: 38, weight: .bold, design: .rounded))
                            .tracking(-1.4)
                        Text("Вставьте прямую ссылку на страницу конкретного отеля. Importer не будет искать похожие варианты — он прочитает только эту карточку.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("ССЫЛКА НА ОТЕЛЬ")
                            .font(.caption2.bold())
                            .tracking(1.5)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 10) {
                            Image(systemName: "link")
                                .foregroundStyle(.secondary)
                            TextField("booking.com/hotel/…", text: $sourceURL, axis: .vertical)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                                .lineLimit(1...3)
                            Button {
                                if let value = UIPasteboard.general.string { sourceURL = value }
                            } label: {
                                Image(systemName: "doc.on.clipboard")
                                    .foregroundStyle(.primary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 15)
                        .padding(.vertical, 14)
                        .background(BusinessDesign.secondarySurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                        if let provider = detectedProvider {
                            Label("Источник: \(provider.rawValue)", systemImage: provider.sourceIcon)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        } else if !sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Label("Нужна ссылка Booking или Expedia", systemImage: "exclamationmark.circle")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.red)
                        }
                    }
                    .padding(16)
                    .businessCard(radius: 26)

                    VStack(alignment: .leading, spacing: 12) {
                        importFeature("photo.stack", "Фотографии", "Только медиа конкретной карточки отеля")
                        importFeature("bed.double", "Номера", "Типы номеров, кровати, вместимость, площадь и вид — если источник их показывает")
                        importFeature("star", "Рейтинг", "Звёзды, оценка и количество отзывов без копирования комментариев")
                        importFeature("list.bullet.rectangle", "Данные", "Адрес, описание, удобства, check-in/out и правила")
                    }
                    .padding(16)
                    .businessCard(radius: 26)

                    Button {
                        let clean = sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !clean.isEmpty, detectedProvider != nil else { return }
                        importRequest = ImportRequest(url: clean)
                    } label: {
                        Label("Импортировать эту карточку", systemImage: "arrow.down.doc.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.black)
                    .disabled(sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || detectedProvider == nil)
                }
                .padding(.vertical, 18)
            }
            .contentMargins(.horizontal, 18, for: .scrollContent)
            .background(Color.white)
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Закрыть") { dismiss() }
                }
            }
            .fullScreenCover(item: $importRequest) { request in
                HotelImportSessionView(sourceURL: request.url)
            }
        }
    }

    private func importFeature(_ symbol: String, _ title: String, _ subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 30, height: 30)
                .background(BusinessDesign.secondarySurface, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.bold())
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
