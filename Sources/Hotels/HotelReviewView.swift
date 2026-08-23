import SwiftUI

struct HotelReviewView: View {
    @ObservedObject var coordinator: HotelImportCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var publishing = false
    @State private var publishStatus: String?

    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        ScrollView {
            if let draft = coordinator.draft {
                VStack(alignment: .leading, spacing: 18) {
                    hotelHero(draft)
                    sourceStatus(draft)
                    gallery(draft)
                    amenities(draft)
                    rooms(draft)
                    publishBlock(draft)
                }
                .padding(16)
            }
        }
        .background(BusinessDesign.background)
        .navigationTitle("Проверка отеля")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private func hotelHero(_ draft: HotelDraft) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let cover = draft.images.first(where: { $0.isCover && $0.selected }), let url = URL(string: cover.url) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() }
                    else { ZStack { Color.black.opacity(0.05); ProgressView() } }
                }
                .frame(height: 235).clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            }
            Text(draft.name).font(.system(size: 31, weight: .bold)).tracking(-1.2)
            HStack(spacing: 9) {
                if let stars = draft.stars { Text(String(repeating: "★", count: min(max(stars, 1), 5))).foregroundStyle(BusinessDesign.accent) }
                Text(draft.city).foregroundStyle(.secondary)
            }.font(.subheadline)
            if !draft.address.isEmpty { Text(draft.address).font(.footnote).foregroundStyle(.secondary) }
        }
        .padding(16).businessCard(radius: 30)
    }

    @ViewBuilder private func sourceStatus(_ draft: HotelDraft) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ИСТОЧНИКИ").font(.caption2.bold()).tracking(1.8).foregroundStyle(.secondary)
            ForEach(HotelImportCoordinator.Provider.allCases, id: \.rawValue) { provider in
                HStack {
                    Image(systemName: draft.sources.contains(where: { $0.provider == provider.rawValue }) ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(draft.sources.contains(where: { $0.provider == provider.rawValue }) ? .green : .orange)
                    Text(provider.rawValue).font(.subheadline.bold())
                    Spacer()
                    Text(draft.sources.first(where: { $0.provider == provider.rawValue })?.name ?? coordinator.providerErrors[provider.rawValue] ?? "Нет данных")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(16).businessCard(radius: 26)
    }

    @ViewBuilder private func gallery(_ draft: HotelDraft) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Фотографии").font(.title2.bold()); Spacer(); Text("\(draft.selectedImages.count) выбрано").font(.caption).foregroundStyle(.secondary) }
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(draft.images) { image in
                    ZStack(alignment: .topTrailing) {
                        AsyncImage(url: URL(string: image.url)) { phase in
                            if let value = phase.image { value.resizable().scaledToFill() }
                            else { Color.black.opacity(0.05).overlay(ProgressView()) }
                        }
                        .frame(height: 128).clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .opacity(image.selected ? 1 : 0.35)
                        Button { coordinator.toggleImage(image.id) } label: {
                            Image(systemName: image.selected ? "checkmark.circle.fill" : "circle")
                                .font(.title3).symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.65))
                        }.padding(8)
                        if image.isCover {
                            Text("COVER").font(.system(size: 8, weight: .black)).padding(.horizontal, 7).frame(height: 20).background(.black.opacity(0.72), in: Capsule()).foregroundStyle(.white).padding(8).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        }
                    }
                    .contextMenu { Button("Сделать обложкой") { coordinator.setCover(image.id) } }
                }
            }
        }
        .padding(16).businessCard(radius: 30)
    }

    @ViewBuilder private func amenities(_ draft: HotelDraft) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Удобства").font(.title2.bold())
            FlowLayout(spacing: 7) {
                ForEach(draft.amenities, id: \.self) { item in Text(item).font(.caption.bold()).padding(.horizontal, 11).frame(height: 32).background(Color.black.opacity(0.045), in: Capsule()) }
            }
        }
        .padding(16).businessCard(radius: 30)
    }

    @ViewBuilder private func rooms(_ draft: HotelDraft) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("Комнаты").font(.title2.bold()); Spacer(); Text("\(draft.rooms.count)").foregroundStyle(.secondary) }
            ForEach(draft.rooms.prefix(16)) { room in
                HStack { Image(systemName: "bed.double.fill").foregroundStyle(BusinessDesign.accent); Text(room.name).font(.subheadline.bold()); Spacer() }
                    .padding(12).background(Color.black.opacity(0.03), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            if draft.rooms.isEmpty { Text("Типы комнат не распознаны автоматически — можно добавить позже.").font(.footnote).foregroundStyle(.secondary) }
        }
        .padding(16).businessCard(radius: 30)
    }

    @ViewBuilder private func publishBlock(_ draft: HotelDraft) -> some View {
        VStack(spacing: 12) {
            if let publishStatus { Text(publishStatus).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center) }
            Button {
                publishing = true; publishStatus = "Сохраняем карточку…"
                Task {
                    do {
                        var cloudDraft = draft
                        cloudDraft.status = "draft"
                        publishStatus = "D1: сохраняем карточку…"
                        _ = try await APIClient.shared.saveHotel(cloudDraft)

                        let selected = cloudDraft.selectedImages
                        var uploaded = 0
                        var failed = 0
                        for (index, image) in selected.enumerated() {
                            publishStatus = "R2: фотография \(index + 1) / \(selected.count)"
                            do {
                                try await APIClient.shared.uploadHotelImage(hotelID: cloudDraft.id, candidate: image, position: index)
                                uploaded += 1
                            } catch {
                                failed += 1
                            }
                        }

                        if failed == 0 {
                            cloudDraft.status = "published"
                            publishStatus = "D1: публикуем отель…"
                            _ = try await APIClient.shared.saveHotel(cloudDraft)
                            publishStatus = "Готово. Отель полностью сохранён: D1 + R2 (\(uploaded) фото)."
                        } else {
                            publishStatus = "Отель сохранён в D1 как черновик. R2: \(uploaded) фото загружено, \(failed) не удалось. Публичная база его пока не показывает."
                        }
                    } catch { publishStatus = "Ошибка Hotels Cloud: \(error.localizedDescription)" }
                    publishing = false
                }
            } label: {
                HStack { if publishing { ProgressView().tint(.white) }; Text(publishing ? "Публикуем…" : "Publish Hotel") }
                    .font(.headline).frame(maxWidth: .infinity).frame(height: 56).foregroundStyle(.white).background(BusinessDesign.ink, in: Capsule())
            }.disabled(publishing)
            Button("Закрыть") { dismiss() }.font(.subheadline.bold()).foregroundStyle(.secondary)
        }
        .padding(16).businessCard(radius: 30)
    }
}

struct FlowLayout<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: () -> Content
    var body: some View { LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: spacing)], alignment: .leading, spacing: spacing) { content() } }
}
