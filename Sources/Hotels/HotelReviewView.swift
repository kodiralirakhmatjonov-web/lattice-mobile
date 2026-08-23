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
                    importQuality(draft)
                    sourceStatus(draft)
                    gallery(draft)
                    rooms(draft)
                    amenities(draft)
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
                    else { ZStack { BusinessDesign.secondarySurface; ProgressView() } }
                }
                .frame(height: 235)
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            }
            Text(draft.name).font(.system(size: 31, weight: .bold)).tracking(-1.2)
            HStack(spacing: 9) {
                if let stars = draft.stars { Text(String(repeating: "★", count: min(max(stars, 1), 5))).foregroundStyle(BusinessDesign.ink) }
                Text(draft.city).foregroundStyle(.secondary)
            }.font(.subheadline)
            if !draft.address.isEmpty { Text(draft.address).font(.footnote).foregroundStyle(.secondary) }
        }
        .padding(16).businessCard(radius: 30)
    }

    @ViewBuilder private func importQuality(_ draft: HotelDraft) -> some View {
        let verified = draft.sources.count
        let rooms = draft.rooms.count
        let roomPhotos = draft.images.filter { $0.kind == .room }.count
        let reviewPhotos = draft.images.filter { $0.kind == .other }.count

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: verified > 0 ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(verified > 0 ? .green : .orange)
                Text(verified > 0 ? "Отель подтверждён" : "Точный отель не подтверждён")
                    .font(.headline)
                Spacer()
                Text("\(verified)/3").font(.caption.bold()).foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                qualityPill("\(rooms) типов номеров", systemImage: "bed.double.fill")
                qualityPill("\(roomPhotos) фото номеров", systemImage: "photo.fill")
            }

            if reviewPhotos > 0 {
                Text("\(reviewPhotos) сомнительных изображений отделены в «Проверить» и не выбраны автоматически.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if rooms == 0 || roomPhotos == 0 {
                Text("Источник не дал достаточно структурированных данных по номерам. Сохранять можно, но карточка останется черновиком до ручной проверки.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(16).businessCard(radius: 26)
    }

    private func qualityPill(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.bold())
            .padding(.horizontal, 11)
            .frame(height: 32)
            .background(BusinessDesign.secondarySurface, in: Capsule())
    }

    @ViewBuilder private func sourceStatus(_ draft: HotelDraft) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ИСТОЧНИКИ").font(.caption2.bold()).tracking(1.8).foregroundStyle(.secondary)
            ForEach(HotelImportCoordinator.Provider.allCases, id: \.rawValue) { provider in
                let source = draft.sources.first(where: { $0.provider == provider.rawValue })
                let accepted = source != nil
                HStack(spacing: 10) {
                    Image(systemName: accepted ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(accepted ? .green : .secondary)
                    Text(provider.rawValue).font(.subheadline.bold())
                    Spacer()
                    Text(source?.name ?? coordinator.providerErrors[provider.rawValue] ?? "Нет данных")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .padding(16).businessCard(radius: 26)
    }

    @ViewBuilder private func gallery(_ draft: HotelDraft) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Фотографии").font(.title2.bold())
                Spacer()
                Text("\(draft.selectedImages.count) выбрано").font(.caption).foregroundStyle(.secondary)
            }

            Text("Importer отделяет фотографии отеля и номеров от служебных картинок сайта. Неясные изображения не выбираются автоматически.")
                .font(.footnote).foregroundStyle(.secondary)

            ForEach([HotelImageKind.exterior, .room, .lobby, .restaurant, .amenity], id: \.self) { kind in
                let items = draft.images.filter { $0.kind == kind }
                if !items.isEmpty { imageSection(kind.title, images: items) }
            }

            let uncertain = draft.images.filter { $0.kind == .other }
            if !uncertain.isEmpty {
                DisclosureGroup {
                    imageGrid(uncertain)
                        .padding(.top, 8)
                } label: {
                    HStack {
                        Text("Проверить вручную").font(.headline)
                        Spacer()
                        Text("\(uncertain.count)").font(.caption.bold()).foregroundStyle(.secondary)
                    }
                }
                Text("Флаги, аватары, иконки и мелкие элементы сайта отбрасываются ещё до этого списка. Здесь остаются только крупные изображения, которые Importer не смог уверенно классифицировать.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16).businessCard(radius: 30)
    }

    @ViewBuilder private func imageSection(_ title: String, images: [HotelImageCandidate]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text("\(images.count)").font(.caption.bold()).foregroundStyle(.secondary)
            }
            imageGrid(images)
        }
    }

    private func imageGrid(_ images: [HotelImageCandidate]) -> some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(images) { image in
                ZStack(alignment: .topTrailing) {
                    AsyncImage(url: URL(string: image.url)) { phase in
                        if let value = phase.image { value.resizable().scaledToFill() }
                        else { BusinessDesign.secondarySurface.overlay(ProgressView()) }
                    }
                    .frame(height: 128)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .opacity(image.selected ? 1 : 0.32)

                    Button { coordinator.toggleImage(image.id) } label: {
                        Image(systemName: image.selected ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.68))
                    }
                    .padding(8)

                    if image.isCover {
                        Text("COVER")
                            .font(.system(size: 8, weight: .black))
                            .padding(.horizontal, 7)
                            .frame(height: 20)
                            .background(.black.opacity(0.72), in: Capsule())
                            .foregroundStyle(.white)
                            .padding(8)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    } else if image.kind == .room, let room = image.roomName, !room.isEmpty {
                        Text(room)
                            .font(.system(size: 8, weight: .bold))
                            .lineLimit(1)
                            .padding(.horizontal, 7)
                            .frame(height: 20)
                            .background(.black.opacity(0.72), in: Capsule())
                            .foregroundStyle(.white)
                            .padding(8)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    }
                }
                .contextMenu { Button("Сделать обложкой") { coordinator.setCover(image.id) } }
            }
        }
    }

    @ViewBuilder private func rooms(_ draft: HotelDraft) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("Номера").font(.title2.bold()); Spacer(); Text("\(draft.rooms.count)").foregroundStyle(.secondary) }
            Text("Это типы номеров, которые Importer реально распознал на страницах подтверждённых источников.")
                .font(.footnote).foregroundStyle(.secondary)

            ForEach(draft.rooms.prefix(24)) { room in
                let related = draft.images.filter { image in
                    guard image.kind == .room else { return false }
                    guard let hint = image.roomName?.lowercased() else { return false }
                    return hint == room.name.lowercased()
                }.count
                HStack(spacing: 12) {
                    Image(systemName: "bed.double.fill").foregroundStyle(BusinessDesign.ink)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(room.name).font(.subheadline.bold())
                        if related > 0 { Text("\(related) фото связано").font(.caption2).foregroundStyle(.secondary) }
                    }
                    Spacer()
                }
                .padding(12)
                .background(BusinessDesign.secondarySurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }

            if draft.rooms.isEmpty {
                Text("Типы номеров не распознаны. Importer не будет придумывать их автоматически.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(16).businessCard(radius: 30)
    }

    @ViewBuilder private func amenities(_ draft: HotelDraft) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Удобства").font(.title2.bold())
            FlowLayout(spacing: 7) {
                ForEach(draft.amenities, id: \.self) { item in
                    Text(item).font(.caption.bold()).padding(.horizontal, 11).frame(height: 32)
                        .background(BusinessDesign.secondarySurface, in: Capsule())
                }
            }
        }
        .padding(16).businessCard(radius: 30)
    }

    @ViewBuilder private func publishBlock(_ draft: HotelDraft) -> some View {
        let canPublish = !draft.sources.isEmpty && draft.selectedTrustedImages.count >= 4 && draft.suspiciousSelectedImages.isEmpty
        let hasRoomData = !draft.rooms.isEmpty && !draft.selectedRoomImages.isEmpty

        VStack(spacing: 12) {
            if let publishStatus { Text(publishStatus).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center) }

            if !canPublish {
                Text("Для публикации нужен подтверждённый источник, минимум 4 нормальные фотографии и ни одной выбранной фотографии из «Проверить».")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            } else if !hasRoomData {
                Text("Карточка будет сохранена в D1/R2 как черновик: номера или фотографии номеров пока не подтверждены.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }

            Button {
                publishing = true
                publishStatus = "Сохраняем карточку…"
                Task {
                    do {
                        var cloudDraft = draft
                        let publishAfterUpload = canPublish && hasRoomData
                        cloudDraft.status = "draft"
                        publishStatus = "D1: сохраняем карточку…"
                        _ = try await APIClient.shared.saveHotel(cloudDraft)
                        publishStatus = "R2: обновляем медиатеку…"
                        try await APIClient.shared.clearHotelImages(hotelID: cloudDraft.id)

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

                        if failed == 0 && publishAfterUpload {
                            cloudDraft.status = "published"
                            publishStatus = "D1: публикуем отель…"
                            _ = try await APIClient.shared.saveHotel(cloudDraft)
                            publishStatus = "Готово. Отель опубликован: D1 + R2 (\(uploaded) фото)."
                        } else if failed == 0 {
                            publishStatus = "Готово. Отель сохранён как черновик: D1 + R2 (\(uploaded) фото). Проверьте номера перед публикацией."
                        } else {
                            publishStatus = "Отель сохранён в D1 как черновик. R2: \(uploaded) фото загружено, \(failed) не удалось."
                        }
                    } catch { publishStatus = "Ошибка Hotels Cloud: \(error.localizedDescription)" }
                    publishing = false
                }
            } label: {
                HStack {
                    if publishing { ProgressView().tint(.white) }
                    Text(publishing ? "Сохраняем…" : (canPublish && hasRoomData ? "Добавить отель" : "Сохранить черновик"))
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .foregroundStyle(.white)
                .background(BusinessDesign.ink, in: Capsule())
            }
            .disabled(publishing || draft.sources.isEmpty || draft.selectedImages.isEmpty)

            Button("Закрыть") { dismiss() }.font(.subheadline.bold()).foregroundStyle(.secondary)
        }
        .padding(16).businessCard(radius: 30)
    }
}

struct FlowLayout<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: () -> Content
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: spacing)], alignment: .leading, spacing: spacing) { content() }
    }
}
