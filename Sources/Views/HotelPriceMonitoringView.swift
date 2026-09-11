import SwiftUI
import UniformTypeIdentifiers

private struct HotelJSONFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct HotelPriceMonitoringView: View {
    let makkahCount: Int
    let madinahCount: Int

    @State private var exportingCity: String?
    @State private var exportDocument: HotelJSONFileDocument?
    @State private var exportFilename = "iumrah-hotels.json"
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var importedDocument: HotelPriceUpdateDocument?
    @State private var importedFilename: String?
    @State private var preview: HotelPriceJSONPreview?
    @State private var selectedHotelIDs = Set<String>()
    @State private var previewing = false
    @State private var applying = false
    @State private var notice: String?
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                introCard

                Text("Экспорт базы")
                    .font(.title2.bold())

                cityExportCard(
                    city: "Makkah",
                    title: "Makkah",
                    subtitle: "Отели Мекки",
                    count: makkahCount,
                    symbol: "building.2.crop.circle"
                )

                cityExportCard(
                    city: "Madinah",
                    title: "Madinah",
                    subtitle: "Отели Медины",
                    count: madinahCount,
                    symbol: "building.columns.circle"
                )

                importCard

                if let preview {
                    previewSummary(preview)
                    resultControls(preview)
                    ForEach(preview.items) { item in
                        resultRow(item)
                    }
                }

                if let notice {
                    Label(notice, systemImage: "checkmark.circle.fill")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.green)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.red)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }
            .padding(.vertical, 14)
        }
        .contentMargins(.horizontal, 18, for: .scrollContent)
        .scrollIndicators(.hidden)
        .background(BusinessDesign.background)
        .navigationTitle("Обновление цен")
        .navigationBarTitleDisplayMode(.inline)
        .fileExporter(
            isPresented: $showExporter,
            document: exportDocument,
            contentType: .json,
            defaultFilename: exportFilename
        ) { result in
            switch result {
            case .success:
                notice = "JSON сохранён. Загрузите этот файл в наш чат ChatGPT для проверки цен."
                errorMessage = nil
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
            exportDocument = nil
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else {
                if case .failure(let error) = result { errorMessage = error.localizedDescription }
                return
            }
            Task { await importResult(from: url) }
        }
    }

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .fill(BusinessDesign.primaryControl)
                        .frame(width: 52, height: 52)
                    Image(systemName: "arrow.left.arrow.right.document.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(BusinessDesign.onPrimaryControl)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("JSON Price Update")
                        .font(.title2.bold())
                    Text("iumrah Business → ChatGPT → iumrah Business")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Text("Экспортируйте Makkah или Madinah в JSON, загрузите файл в ChatGPT, а затем импортируйте полученный JSON с результатами. Никакой Cloudflare Browser-проверки и автоматической публикации: цена меняется только после Вашего подтверждения.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                stepPill("1", "Экспорт")
                stepPill("2", "Проверка")
                stepPill("3", "Импорт")
            }
        }
        .padding(16)
        .businessCard(radius: 28)
    }

    private func stepPill(_ number: String, _ title: String) -> some View {
        HStack(spacing: 6) {
            Text(number)
                .font(.caption2.bold())
                .frame(width: 20, height: 20)
                .background(BusinessDesign.primaryControl, in: Circle())
                .foregroundStyle(BusinessDesign.onPrimaryControl)
            Text(title)
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(BusinessDesign.secondarySurface, in: Capsule())
    }

    private func cityExportCard(city: String, title: String, subtitle: String, count: Int, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(BusinessDesign.secondarySurface)
                        .frame(width: 50, height: 50)
                    Image(systemName: symbol)
                        .font(.system(size: 20, weight: .semibold))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                    Text("\(count) отелей · полный городской JSON + source URL")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Button {
                Task { await export(city: city) }
            } label: {
                HStack(spacing: 8) {
                    if exportingCity == city {
                        ProgressView().tint(BusinessDesign.onPrimaryControl)
                    } else {
                        Image(systemName: "square.and.arrow.up")
                    }
                    Text(exportingCity == city ? "Формируем JSON…" : "Экспорт JSON")
                        .fontWeight(.semibold)
                    Spacer()
                    Image(systemName: "doc.text")
                }
                .padding(.horizontal, 16)
                .frame(height: 50)
                .foregroundStyle(BusinessDesign.onPrimaryControl)
                .background(BusinessDesign.primaryControl, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(exportingCity != nil || previewing || applying)
        }
        .padding(16)
        .businessCard(radius: 26)
    }

    private var importCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Результат ChatGPT")
                        .font(.title2.bold())
                    Text(importedFilename ?? "Импортируйте JSON после проверки цен")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                if previewing { ProgressView() }
            }

            Button {
                showImporter = true
            } label: {
                Label("Импортировать JSON от ChatGPT", systemImage: "square.and.arrow.down")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(BusinessDesign.secondarySurface, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .disabled(previewing || applying)

            Text("Сначала будет только предпросмотр. Данные из файла не меняют D1, пока Вы не выберете изменения и не нажмёте «Обновить выбранные цены».")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .businessCard(radius: 28)
    }

    private func previewSummary(_ preview: HotelPriceJSONPreview) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Предпросмотр")
                        .font(.headline)
                    Text("\(preview.city) · \(preview.total) отелей")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(preview.changed) изменений")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.orange.opacity(0.10), in: Capsule())
            }

            HStack(spacing: 8) {
                metric("Изменено", preview.changed)
                metric("Без изменений", preview.unchanged)
                metric("Проверить", preview.conflicts + preview.unverified + preview.invalid)
            }
        }
        .padding(16)
        .businessCard(radius: 26)
    }

    private func metric(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(value)")
                .font(.headline.monospacedDigit())
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(BusinessDesign.tertiarySurface, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    }

    private func resultControls(_ preview: HotelPriceJSONPreview) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("Изменения")
                    .font(.title2.bold())
                Spacer()
                Text("\(selectedHotelIDs.count) выбрано")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button("Все изменения") {
                    selectedHotelIDs = Set(preview.items.filter(\.selectable).map(\.hotelID))
                }
                Button("Снять") {
                    selectedHotelIDs.removeAll()
                }
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.bordered)

            Button {
                Task { await applySelected() }
            } label: {
                HStack(spacing: 8) {
                    if applying { ProgressView().tint(BusinessDesign.onPrimaryControl) }
                    Image(systemName: "checkmark.seal.fill")
                    Text(applying ? "Обновляем D1…" : "Обновить выбранные цены")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .foregroundStyle(BusinessDesign.onPrimaryControl)
                .background(BusinessDesign.primaryControl, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(applying || selectedHotelIDs.isEmpty || importedDocument == nil)
        }
        .padding(.top, 2)
    }

    private func resultRow(_ item: HotelPriceJSONPreviewItem) -> some View {
        let selected = selectedHotelIDs.contains(item.hotelID)
        return VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 12) {
                Button {
                    guard item.selectable else { return }
                    if selected { selectedHotelIDs.remove(item.hotelID) }
                    else { selectedHotelIDs.insert(item.hotelID) }
                } label: {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(item.selectable ? (selected ? BusinessDesign.ink : Color.secondary) : Color.secondary.opacity(0.35))
                }
                .buttonStyle(.plain)
                .disabled(!item.selectable)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(item.hotelName)
                            .font(.subheadline.bold())
                            .lineLimit(2)
                        Spacer(minLength: 8)
                        statusBadge(item)
                    }
                    HStack(spacing: 6) {
                        if let stars = item.stars { Text("\(stars)★") }
                        if let city = item.city { Text(city) }
                        if let provider = item.currentProvider ?? item.provider { Text("· \(provider)") }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            if let current = item.currentNightlyUSD, let candidate = item.newNightlyUSD {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(money(current))
                        .foregroundStyle(.secondary)
                    Image(systemName: "arrow.right")
                        .font(.caption.bold())
                        .foregroundStyle(.tertiary)
                    Text(money(candidate))
                        .font(.title3.bold())
                        .monospacedDigit()
                    Spacer()
                    if let delta = item.deltaUSD, abs(delta) >= 0.01 {
                        Text(deltaText(delta, percent: item.deltaPercent))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(delta > 0 ? .orange : .green)
                    }
                }
            }

            if let issue = item.issue {
                Label(issueText(issue), systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let reason = item.reason, item.reviewStatus == "unverified" || item.reviewStatus == "needs_review" {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let source = AppConfig.absoluteURL(item.currentSourceURL ?? item.sourceURL) {
                Link(destination: source) {
                    Label("Открыть источник", systemImage: "safari")
                        .font(.caption.weight(.semibold))
                }
            }
        }
        .padding(14)
        .background(BusinessDesign.secondarySurface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func statusBadge(_ item: HotelPriceJSONPreviewItem) -> some View {
        let text: String
        let color: Color
        switch item.reviewStatus {
        case "ready": text = "ИЗМЕНЕНИЕ"; color = .orange
        case "unchanged": text = "БЕЗ ИЗМЕНЕНИЙ"; color = .green
        case "applied": text = "ОБНОВЛЕНО"; color = .blue
        case "conflict": text = "КОНФЛИКТ"; color = .red
        case "unverified": text = "НЕ ПОДТВЕРЖДЕНО"; color = .secondary
        case "needs_review": text = "ПРОВЕРИТЬ"; color = .orange
        default: text = "ОШИБКА"; color = .red
        }
        return Text(text)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(color.opacity(0.09), in: Capsule())
    }

    @MainActor
    private func export(city: String) async {
        exportingCity = city
        notice = nil
        errorMessage = nil
        defer { exportingCity = nil }
        do {
            let document = try await APIClient.shared.hotelPriceJSONExport(city: city)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(document)
            exportFilename = "iumrah-hotels-\(city.lowercased())-\(dateStamp()).json"
            exportDocument = HotelJSONFileDocument(data: data)
            showExporter = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func importResult(from url: URL) async {
        previewing = true
        notice = nil
        errorMessage = nil
        defer { previewing = false }

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .nameKey])
            if let size = values.fileSize, size > 5_000_000 {
                throw PriceJSONUIError.invalidFile("JSON слишком большой. Максимум 5 MB.")
            }
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            let document = try decoder.decode(HotelPriceUpdateDocument.self, from: data)
            guard document.schema == "iumrah.hotel-price-update.v1" else {
                throw PriceJSONUIError.invalidFile("Это не iumrah hotel-price-update JSON.")
            }
            let verifiedPreview = try await APIClient.shared.previewHotelPriceJSON(document)
            importedDocument = document
            importedFilename = values.name ?? url.lastPathComponent
            preview = verifiedPreview
            selectedHotelIDs = Set(verifiedPreview.items.filter(\.selectable).map(\.hotelID))
            notice = "JSON проверен. Ничего ещё не опубликовано — выберите изменения ниже."
        } catch {
            importedDocument = nil
            preview = nil
            selectedHotelIDs.removeAll()
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func applySelected() async {
        guard let document = importedDocument, !selectedHotelIDs.isEmpty else { return }
        applying = true
        notice = nil
        errorMessage = nil
        defer { applying = false }

        do {
            let response = try await APIClient.shared.applyHotelPriceJSON(document, hotelIDs: Array(selectedHotelIDs))
            preview = response.preview
            selectedHotelIDs.removeAll()
            notice = "Обновлено \(response.applied) цен в D1. Клиентский каталог теперь использует подтверждённые значения."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func money(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(0...2)))
    }

    private func deltaText(_ delta: Double, percent: Double?) -> String {
        let sign = delta > 0 ? "+" : ""
        let usd = "\(sign)\(money(delta))"
        guard let percent else { return usd }
        let percentSign = percent > 0 ? "+" : ""
        return "\(usd) · \(percentSign)\(percent.formatted(.number.precision(.fractionLength(0...1))))%"
    }

    private func issueText(_ issue: String) -> String {
        switch issue {
        case "PRICE_CHANGED_AFTER_EXPORT": return "Цена в базе изменилась после экспорта. Повторно экспортируйте этот город перед обновлением."
        case "SOURCE_CHANGED": return "Источник отеля изменился после экспорта. Эта цена заблокирована от автоматического применения."
        case "LOW_CONFIDENCE": return "Низкая уверенность проверки. Цена не будет применена автоматически."
        case "PRICE_NOT_VERIFIED": return "Источник не подтвердил цену."
        case "HOTEL_NOT_FOUND": return "Отель больше не найден в базе."
        case "HOTEL_NOT_PUBLISHED": return "Отель больше не опубликован."
        case "CITY_MISMATCH": return "Город отеля не совпадает с экспортом."
        default: return issue.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func dateStamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}

private enum PriceJSONUIError: LocalizedError {
    case invalidFile(String)

    var errorDescription: String? {
        switch self {
        case .invalidFile(let message): return message
        }
    }
}
