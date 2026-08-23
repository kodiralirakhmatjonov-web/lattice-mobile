import SwiftUI

struct HotelReviewView: View {
    @ObservedObject var coordinator: HotelImportCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var publishing = false
    @State private var publishStatus: String?

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    var body: some View {
        ScrollView {
            if let draft = coordinator.draft {
                LazyVStack(alignment: .leading, spacing: 16) {
                    hotelHero(draft)
                    sourceCard(draft)
                    hotelFacts(draft)
                    gallery(draft)
                    rooms(draft)
                    amenities(draft)
                    policies(draft)
                    publishBlock(draft)
                }
                .padding(.vertical, 14)
            }
        }
        .contentMargins(.horizontal, 18, for: .scrollContent)
        .scrollIndicators(.hidden)
        .background(Color.white)
        .navigationTitle("Проверка отеля")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private func hotelHero(_ draft: HotelDraft) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let cover = draft.images.first(where: { $0.isCover && $0.selected }), let url = URL(string: cover.url) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        ZStack {
                            BusinessDesign.secondarySurface
                            ProgressView()
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 232)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(draft.name)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .tracking(-1.1)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    if let stars = draft.stars {
                        Label("\(stars)★", systemImage: "star.fill")
                    }
                    if let rating = draft.rating {
                        let scale = draft.ratingScale ?? (rating > 5 ? 10 : 5)
                        Label("\(rating.formatted(.number.precision(.fractionLength(1)))) / \(Int(scale))", systemImage: "hand.thumbsup.fill")
                    }
                    if let reviews = draft.reviewCount {
                        Text("\(reviews.formatted()) отзывов")
                    }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

                Text([draft.city, draft.country].filter { !$0.isEmpty }.joined(separator: ", "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if !draft.address.isEmpty {
                    Text(draft.address)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .businessCard(radius: 28)
    }

    @ViewBuilder private func sourceCard(_ draft: HotelDraft) -> some View {
        if let source = draft.sources.first {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: coordinator.currentProvider?.sourceIcon ?? "link.circle.fill")
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(source.provider)
                            .font(.headline)
                        Text("Прямая карточка отеля")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                }

                if let url = URL(string: source.sourceURL) {
                    Link(destination: url) {
                        HStack(spacing: 6) {
                            Text(url.host ?? source.sourceURL)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    }
                }

                Text("Importer использовал только эту страницу. Поиск похожих отелей и смешивание данных из других карточек отключены.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .businessCard(radius: 26)
        }
    }

    @ViewBuilder private func hotelFacts(_ draft: HotelDraft) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Данные отеля")
                .font(.title2.bold())

            if let propertyType = draft.propertyType {
                factRow("building.2", "Тип", propertyType)
            }
            if let stars = draft.stars {
                factRow("star", "Категория", "\(stars) звёзд")
            }
            if let rating = draft.rating {
                let scale = draft.ratingScale ?? (rating > 5 ? 10 : 5)
                let reviews = draft.reviewCount.map { " · \($0.formatted()) отзывов" } ?? ""
                factRow("hand.thumbsup", "Рейтинг", "\(rating.formatted(.number.precision(.fractionLength(1)))) / \(Int(scale))\(reviews)")
            }
            if let checkIn = draft.checkIn { factRow("arrow.right.circle", "Check-in", checkIn) }
            if let checkOut = draft.checkOut { factRow("arrow.left.circle", "Check-out", checkOut) }

            if !draft.description.isEmpty {
                Divider()
                Text(draft.description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .businessCard(radius: 26)
    }

    private func factRow(_ symbol: String, _ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .frame(width: 24)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private func gallery(_ draft: HotelDraft) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Фотографии")
                        .font(.title2.bold())
                    Text("\(draft.images.count) найдено · \(draft.selectedImages.count) выбрано")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button("Выбрать все") { coordinator.selectAllTrustedImages() }
                    Button("Снять выбор") { coordinator.deselectAllImages() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                }
            }

            Text("Здесь только фотографии, которые принадлежат hotel-media CDN конкретной страницы Booking/Expedia. Логотипы сайта, флаги, аватары и рекомендации других отелей не импортируются.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            ForEach(photoKinds(for: draft), id: \.self) { kind in
                let items = draft.images.filter { $0.kind == kind }
                if !items.isEmpty {
                    imageSection(kind.title, images: items)
                }
            }
        }
        .padding(14)
        .businessCard(radius: 28)
    }

    private func photoKinds(for draft: HotelDraft) -> [HotelImageKind] {
        let order: [HotelImageKind] = [.exterior, .view, .room, .bathroom, .lobby, .restaurant, .amenity, .gallery, .other]
        return order.filter { kind in draft.images.contains(where: { $0.kind == kind }) }
    }

    private func imageSection(_ title: String, images: [HotelImageCandidate]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text("\(images.count)").font(.caption).foregroundStyle(.secondary)
            }
            imageGrid(images)
        }
    }

    private func imageGrid(_ images: [HotelImageCandidate]) -> some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(images) { image in
                ZStack(alignment: .topTrailing) {
                    AsyncImage(url: URL(string: image.url)) { phase in
                        if let loaded = phase.image {
                            loaded.resizable().scaledToFill()
                        } else {
                            ZStack {
                                BusinessDesign.secondarySurface
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 132)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .opacity(image.selected ? 1 : 0.28)

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
                            .background(.black.opacity(0.74), in: Capsule())
                            .foregroundStyle(.white)
                            .padding(8)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    }
                }
                .contextMenu {
                    Button("Сделать обложкой") { coordinator.setCover(image.id) }
                }
            }
        }
    }

    @ViewBuilder private func rooms(_ draft: HotelDraft) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Номера").font(.title2.bold())
                Spacer()
                Text("\(draft.rooms.count)").foregroundStyle(.secondary)
            }

            if draft.rooms.isEmpty {
                ContentUnavailableView(
                    "Номера не найдены",
                    systemImage: "bed.double",
                    description: Text("Эта страница не показала структурированный список типов номеров. Данные не будут придуманы автоматически.")
                )
            } else {
                ForEach(draft.rooms) { room in
                    roomCard(room)
                }
            }
        }
        .padding(14)
        .businessCard(radius: 28)
    }

    private func roomCard(_ room: HotelRoomDraft) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: "bed.double.fill")
                    .font(.title3)
                    .frame(width: 30, height: 30)
                    .background(BusinessDesign.secondarySurface, in: Circle())
                Text(room.name)
                    .font(.subheadline.bold())
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }

            let details = [
                room.maxGuests.map { "до \($0) гостей" },
                room.sizeM2.map { "\($0.formatted(.number.precision(.fractionLength(0...1)))) м²" },
                room.beds,
                room.view
            ].compactMap { $0 }

            if !details.isEmpty {
                Text(details.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !room.amenities.isEmpty {
                Text(room.amenities.prefix(8).joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(13)
        .background(BusinessDesign.secondarySurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder private func amenities(_ draft: HotelDraft) -> some View {
        if !draft.amenities.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Удобства").font(.title2.bold())
                FlowLayout(spacing: 7) {
                    ForEach(draft.amenities, id: \.self) { item in
                        Text(item)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 8)
                            .background(BusinessDesign.secondarySurface, in: Capsule())
                    }
                }
            }
            .padding(14)
            .businessCard(radius: 28)
        }
    }

    @ViewBuilder private func policies(_ draft: HotelDraft) -> some View {
        if !draft.policies.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Правила").font(.title2.bold())
                ForEach(draft.policies, id: \.self) { policy in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "checkmark.circle")
                            .foregroundStyle(.secondary)
                            .padding(.top, 1)
                        Text(policy)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(14)
            .businessCard(radius: 28)
        }
    }

    @ViewBuilder private func publishBlock(_ draft: HotelDraft) -> some View {
        let canPublish = !draft.sources.isEmpty && draft.selectedTrustedImages.count >= 4 && !draft.rooms.isEmpty

        VStack(spacing: 12) {
            if let publishStatus {
                Text(publishStatus)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if !canPublish {
                Text("Карточка будет сохранена как черновик, пока у неё нет минимум 4 фотографий и распознанных типов номеров.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                publishing = true
                publishStatus = "Сохраняем данные отеля…"
                Task {
                    do {
                        var cloudDraft = draft
                        cloudDraft.status = "draft"
                        _ = try await APIClient.shared.saveHotel(cloudDraft)

                        publishStatus = "Обновляем медиатеку в R2…"
                        try await APIClient.shared.clearHotelImages(hotelID: cloudDraft.id)

                        let selected = cloudDraft.selectedImages
                        var uploaded = 0
                        var failed = 0
                        for (index, image) in selected.enumerated() {
                            publishStatus = "Фото \(index + 1) из \(selected.count)"
                            do {
                                try await APIClient.shared.uploadHotelImage(hotelID: cloudDraft.id, candidate: image, position: index)
                                uploaded += 1
                            } catch {
                                failed += 1
                            }
                        }

                        if failed == 0 && canPublish {
                            cloudDraft.status = "published"
                            _ = try await APIClient.shared.saveHotel(cloudDraft)
                            publishStatus = "Готово. Отель опубликован · \(uploaded) фото в R2."
                        } else if failed == 0 {
                            publishStatus = "Готово. Черновик сохранён · \(uploaded) фото в R2."
                        } else {
                            publishStatus = "Данные сохранены как черновик. Фото: \(uploaded) загружено, \(failed) не удалось."
                        }
                    } catch {
                        publishStatus = "Ошибка Hotels Cloud: \(error.localizedDescription)"
                    }
                    publishing = false
                }
            } label: {
                HStack {
                    if publishing { ProgressView().tint(.white) }
                    Text(publishing ? "Сохраняем…" : (canPublish ? "Добавить в iumrah Hotels" : "Сохранить черновик"))
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
            }
            .buttonStyle(.borderedProminent)
            .tint(.black)
            .disabled(publishing || draft.sources.isEmpty || draft.selectedImages.isEmpty)

            Button("Закрыть") { dismiss() }
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .businessCard(radius: 28)
    }
}

struct FlowLayout<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: () -> Content

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 110), spacing: spacing)],
            alignment: .leading,
            spacing: spacing
        ) {
            content()
        }
    }
}
