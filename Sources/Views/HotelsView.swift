import SwiftUI
import UIKit

struct HotelsView: View {
    @State private var hotels: [HotelListItem] = []
    @State private var loading = false
    @State private var showAdd = false
    @State private var backendUnavailable = false
    @State private var cloudHealth: HotelCloudHealthResponse?
    @State private var backendMessage: String?
    @State private var importJobs: [HotelImportJob] = []
    @State private var importJobsError: String?

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

                if !importJobs.isEmpty || importJobsError != nil {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Импорты").font(.title2.bold())
                            Spacer()
                            let activeCount = importJobs.filter(\.isActive).count
                            if activeCount > 0 {
                                Text("\(activeCount) активных")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let importJobsError {
                            Label(importJobsError, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(Array(importJobs.prefix(10))) { job in
                            importJobCard(job)
                        }
                    }
                    .padding(16)
                    .businessCard(radius: 28)
                }

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
                            Text(hotel.status == "published" ? "LIVE" : (hotel.lifecycleState?.uppercased() ?? "DRAFT"))
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(hotel.status == "published" ? .green : (hotel.lifecycleState == "failed" ? .red : .secondary))
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
        .task {
            await BusinessNotifications.prepare()
            await load()
            await monitorImports()
        }
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
            async let jobsRequest = APIClient.shared.hotelImportJobs()
            cloudHealth = try await healthRequest
            hotels = try await hotelsRequest
            do {
                importJobs = try await jobsRequest
                importJobsError = nil
            } catch {
                importJobsError = "Не удалось получить прогресс импортов: \(error.localizedDescription)"
            }
        } catch {
            backendUnavailable = true
            backendMessage = error.localizedDescription
            cloudHealth = nil
        }
        loading = false
    }

    @MainActor
    private func monitorImports() async {
        while !Task.isCancelled {
            do {
                let jobs = try await APIClient.shared.hotelImportJobs()
                importJobs = jobs
                importJobsError = nil
                await BusinessNotifications.trackActiveHotelImports(jobs)
                await BusinessNotifications.notifyUnseenTerminalJobs(jobs)
            } catch {
                importJobsError = "Прогресс временно недоступен: \(error.localizedDescription)"
            }
            let hasActive = importJobs.contains(where: \.isActive)
            try? await Task.sleep(nanoseconds: UInt64(hasActive ? 2_000_000_000 : 8_000_000_000))
        }
    }

    @ViewBuilder
    private func importJobCard(_ job: HotelImportJob) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.hotelName).font(.subheadline.bold()).lineLimit(1)
                    Text(importStatusText(job))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(job.status == "failed" ? .red : .secondary)
                }
                Spacer()
                if job.isActive {
                    Text("\(job.progress)%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else if job.status == "failed" {
                    Button("Повторить") {
                        Task {
                            if let retried = try? await APIClient.shared.retryHotelImportJob(id: job.id) {
                                await BusinessNotifications.hotelImportStarted(retried)
                                if let jobs = try? await APIClient.shared.hotelImportJobs() { importJobs = jobs }
                            }
                        }
                    }
                    .font(.caption.bold())
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

            if job.isActive {
                ProgressView(value: Double(job.progress), total: 100).tint(.black)
            }
            Text(importStageDetail(job))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            if let warning = job.warning, !warning.isEmpty {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = job.error, job.status == "failed" {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(12)
        .background(BusinessDesign.secondarySurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func importStatusText(_ job: HotelImportJob) -> String {
        switch job.status {
        case "queued": return "В очереди"
        case "running": return "Фоновая загрузка"
        case "completed": return job.stage == "completed_with_warnings" ? "Готово · с предупреждением" : (job.publishWhenComplete ? "Готово · опубликован" : "Готово · черновик")
        case "failed": return "Ошибка · можно повторить"
        default: return job.status
        }
    }

    private func importStageDetail(_ job: HotelImportJob) -> String {
        let stage: String
        switch job.stage {
        case "queued", "retry_queued": stage = "ожидает серверную очередь"
        case "preparing_media": stage = "подготавливаем фотографии"
        case "downloading_image": stage = "скачиваем исходную фотографию"
        case "optimizing_image": stage = "сжимаем фотографию"
        case "saving_to_r2": stage = "сохраняем в R2"
        case "media_progress": stage = "обрабатываем следующие фотографии"
        case "image_retry_exhausted": stage = "одна фотография недоступна, продолжаем"
        case "completed": stage = "импорт завершён"
        case "completed_with_warnings": stage = "импорт завершён с предупреждением"
        case "integrity_failed": stage = "проверка целостности не пройдена"
        case "start_failed": stage = "не удалось запустить Cloudflare Workflow"
        default: stage = job.stage.replacingOccurrences(of: "_", with: " ")
        }
        var parts = ["\(job.storedImages)/\(job.totalImages) фото", stage]
        if let current = job.currentImage, current > 0, job.isActive {
            parts.append("№\(current) из \(job.totalImages)")
        }
        if let label = job.currentImageLabel, !label.isEmpty, job.isActive { parts.append(label) }
        if let mode = job.compressionMode, !mode.isEmpty {
            parts.append(mode == "provider-sized-fallback-v1" ? "provider-compressed" : "WebP")
        }
        if (job.retryCount ?? 0) > 0 { parts.append("retry \(job.retryCount ?? 0)") }
        return parts.joined(separator: " · ")
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
    @State private var sourceURLs = Array(repeating: "", count: 4)
    @State private var importRequest: ImportRequest?
    @State private var duplicateMessages: [Int: String] = [:]
    @State private var duplicateTasks: [Int: Task<Void, Never>] = [:]

    struct ImportRequest: Identifiable {
        let id = UUID()
        let urls: [String]
    }

    private var validURLs: [String] {
        sourceURLs.enumerated().compactMap { index, raw in
            guard duplicateMessages[index] == nil else { return nil }
            let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return provider(for: clean) == nil ? nil : clean
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Добавить отели")
                            .font(.system(size: 38, weight: .bold, design: .rounded))
                            .tracking(-1.4)
                        Text("До четырёх прямых ссылок Booking или Expedia. Importer читает их строго по очереди и никогда не смешивает карточки.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 13) {
                        ForEach(sourceURLs.indices, id: \.self) { index in
                            hotelURLField(index: index)
                        }
                    }
                    .padding(16)
                    .businessCard(radius: 26)

                    VStack(alignment: .leading, spacing: 12) {
                        importFeature("doc.text.magnifyingglass", "Полная карточка", "Рейтинг, отзывы числом, описание, сервисы, правила, сборы и все доступные property details")
                        importFeature("mappin.and.ellipse", "Локация", "Координаты, Google Maps и расстояния/время до Каабы и других мест, если источник их показывает")
                        importFeature("photo.stack", "Фотографии", "Только hotel-media конкретной страницы; загрузка в R2 после подтверждения идёт уже на Cloudflare")
                        importFeature("bed.double", "Номера", "FAQ, парковка и другие посторонние строки больше не могут попасть в список номеров")
                    }
                    .padding(16)
                    .businessCard(radius: 26)

                    Button {
                        guard !validURLs.isEmpty else { return }
                        importRequest = ImportRequest(urls: validURLs)
                    } label: {
                        Label("Подготовить \(validURLs.count) \(validURLs.count == 1 ? "отель" : "отеля")", systemImage: "arrow.down.doc.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.black)
                    .disabled(validURLs.isEmpty)
                }
                .padding(.vertical, 18)
            }
            .contentMargins(.horizontal, 18, for: .scrollContent)
            .background(Color.white)
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    BusinessBrandLogo(width: 118)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Закрыть") { dismiss() }
                }
            }
            .fullScreenCover(item: $importRequest) { request in
                HotelBatchImportView(sourceURLs: request.urls)
            }
        }
    }

    @ViewBuilder
    private func hotelURLField(index: Int) -> some View {
        let value = sourceURLs[index]
        let detected = provider(for: value)

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("ССЫЛКА \(index + 1)")
                    .font(.caption2.bold())
                    .tracking(1.4)
                    .foregroundStyle(.secondary)
                Spacer()
                if let detected {
                    Label(detected.rawValue, systemImage: detected.sourceIcon)
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                Image(systemName: "link")
                    .foregroundStyle(.secondary)
                TextField(index == 0 ? "Вставьте ссылку отеля" : "Ещё одна ссылка — необязательно", text: $sourceURLs[index], axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .lineLimit(1...3)
                    .onChange(of: sourceURLs[index]) { _, newValue in
                        scheduleDuplicateCheck(index: index, value: newValue)
                    }
                Button {
                    if let pasted = UIPasteboard.general.string {
                        sourceURLs[index] = pasted
                        scheduleDuplicateCheck(index: index, value: pasted)
                    }
                } label: {
                    Image(systemName: "doc.on.clipboard")
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(BusinessDesign.secondarySurface, in: RoundedRectangle(cornerRadius: 17, style: .continuous))

            if let message = duplicateMessages[index] {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && detected == nil {
                Label("Нужна ссылка Booking или Expedia", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func scheduleDuplicateCheck(index: Int, value: String) {
        duplicateTasks[index]?.cancel()
        duplicateMessages[index] = nil
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard provider(for: clean) != nil else { return }
        duplicateTasks[index] = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            do {
                if let duplicate = try await APIClient.shared.checkHotelSourceDuplicate(clean) {
                    await MainActor.run {
                        duplicateMessages[index] = "Уже в базе: \(duplicate.name)"
                    }
                }
            } catch {
                // Full identity dedupe is repeated after the property page is read.
            }
        }
    }

    private func provider(for rawValue: String) -> HotelImportCoordinator.Provider? {
        var text = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.lowercased().hasPrefix("http://") && !text.lowercased().hasPrefix("https://") { text = "https://\(text)" }
        guard let url = URL(string: text) else { return nil }
        return HotelImportCoordinator.Provider.detect(from: url)
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
