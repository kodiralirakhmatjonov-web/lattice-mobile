import SwiftUI
import UIKit

struct HotelPriceMonitoringView: View {
    let makkahCount: Int
    let madinahCount: Int

    @State private var makkahURL: URL?
    @State private var madinahURL: URL?
    @State private var makkahStatus: BusinessHotelSyncStatusResponse?
    @State private var madinahStatus: BusinessHotelSyncStatusResponse?
    @State private var makkahDate: Date
    @State private var madinahDate: Date
    @State private var busyCity: String?
    @State private var jsonText = ""
    @State private var importedDocument: HotelPriceUpdateDocument?
    @State private var preview: HotelPriceJSONPreview?
    @State private var selectedHotelIDs = Set<String>()
    @State private var previewing = false
    @State private var applying = false
    @State private var notice: String?
    @State private var errorMessage: String?

    init(makkahCount: Int, madinahCount: Int) {
        self.makkahCount = makkahCount
        self.madinahCount = madinahCount
        let calendar = Calendar.current
        let base = calendar.startOfDay(for: Date())
        let defaultDate = calendar.date(byAdding: .day, value: 30, to: base) ?? base
        _makkahDate = State(initialValue: defaultDate)
        _madinahDate = State(initialValue: defaultDate)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                introCard

                Text("Доступ ChatGPT")
                    .font(.title2.bold())

                citySyncCard(
                    city: "Makkah",
                    title: "Makkah",
                    subtitle: "Отели Мекки",
                    count: makkahCount,
                    symbol: "building.2.crop.circle",
                    date: $makkahDate,
                    url: makkahURL,
                    status: makkahStatus
                )

                citySyncCard(
                    city: "Madinah",
                    title: "Madinah",
                    subtitle: "Отели Медины",
                    count: madinahCount,
                    symbol: "building.columns.circle",
                    date: $madinahDate,
                    url: madinahURL,
                    status: madinahStatus
                )

                jsonInputCard

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
        .task {
            makkahURL = BusinessSessionVault.hotelSyncAccessURL(city: "Makkah")
            madinahURL = BusinessSessionVault.hotelSyncAccessURL(city: "Madinah")
            await refreshStatus(city: "Makkah")
            await refreshStatus(city: "Madinah")
        }
    }

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .fill(BusinessDesign.primaryControl)
                        .frame(width: 52, height: 52)
                    Image(systemName: "link.badge.plus")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(BusinessDesign.onPrimaryControl)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("ChatGPT Price Sync")
                        .font(.title2.bold())
                    Text("Makkah и Madinah работают отдельно")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Text("iumrah Business публикует только read-only снимок отелей выбранного города: текущую цену, точный источник и ссылку на этот же отель с фиксированной датой. ChatGPT проверяет каждый источник по одному и возвращает JSON. Google-поиск — только резерв для поиска той же страницы, не источник финальной цены.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                stepPill("1", "Ссылка")
                stepPill("2", "Проверка")
                stepPill("3", "JSON")
                stepPill("4", "Обновление")
            }
        }
        .padding(16)
        .businessCard(radius: 28)
    }

    private func stepPill(_ number: String, _ title: String) -> some View {
        HStack(spacing: 5) {
            Text(number)
                .font(.caption2.bold())
                .frame(width: 20, height: 20)
                .background(BusinessDesign.primaryControl, in: Circle())
                .foregroundStyle(BusinessDesign.onPrimaryControl)
            Text(title)
                .font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(BusinessDesign.secondarySurface, in: Capsule())
    }

    private func citySyncCard(
        city: String,
        title: String,
        subtitle: String,
        count: Int,
        symbol: String,
        date: Binding<Date>,
        url: URL?,
        status: BusinessHotelSyncStatusResponse?
    ) -> some View {
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
                    Text("\(count) отелей · отдельная read-only ссылка")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()

                if url != nil {
                    Menu {
                        Button("Создать новую ссылку", systemImage: "arrow.clockwise") {
                            Task { await createAccess(city: city, date: date.wrappedValue) }
                        }
                        Button("Отключить доступ", systemImage: "link.badge.minus", role: .destructive) {
                            Task { await revokeAccess(city: city) }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.title3)
                    }
                    .disabled(busyCity != nil)
                }
            }

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Дата проверки")
                        .font(.caption.weight(.semibold))
                    Text("1 ночь · 2 взрослых · 1 номер · USD")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                DatePicker("", selection: date, in: Date()..., displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.compact)
            }

            if let status, let checkIn = status.checkIn, let checkOut = status.checkOut {
                HStack(spacing: 7) {
                    Image(systemName: "calendar.badge.checkmark")
                        .foregroundStyle(.green)
                    Text("В ссылке сейчас: \(checkIn) → \(checkOut) · \(status.hotelCount) отелей")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            if let url {
                Text(url.absoluteString)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)

                HStack(spacing: 10) {
                    Button {
                        Task { await syncSnapshot(city: city, date: date.wrappedValue) }
                    } label: {
                        HStack(spacing: 7) {
                            if busyCity == city {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                            }
                            Text("Синхронизировать")
                        }
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(BusinessDesign.secondarySurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(busyCity != nil)

                    Button {
                        UIPasteboard.general.string = url.absoluteString
                        notice = "Ссылка \(title) скопирована. Отправьте её в ChatGPT."
                        errorMessage = nil
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .frame(width: 44, height: 44)
                            .background(BusinessDesign.secondarySurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up")
                            .frame(width: 44, height: 44)
                            .background(BusinessDesign.secondarySurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Button {
                    Task { await createAccess(city: city, date: date.wrappedValue) }
                } label: {
                    HStack {
                        if busyCity == city {
                            ProgressView().tint(BusinessDesign.onPrimaryControl)
                        } else {
                            Image(systemName: "link.badge.plus")
                        }
                        Text("Подключить ChatGPT")
                        Spacer()
                        Image(systemName: "chevron.right")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(BusinessDesign.onPrimaryControl)
                    .padding(.horizontal, 15)
                    .frame(height: 48)
                    .background(BusinessDesign.primaryControl, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(busyCity != nil)
            }
        }
        .padding(16)
        .businessCard(radius: 26)
    }

    private var jsonInputCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("JSON от ChatGPT")
                        .font(.title2.bold())
                    Text("Вставьте результат проверки сюда")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if previewing { ProgressView() }
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $jsonText)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 190)
                    .padding(8)
                    .scrollContentBackground(.hidden)
                    .background(BusinessDesign.secondarySurface, in: RoundedRectangle(cornerRadius: 17, style: .continuous))

                if jsonText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("{\n  \"schema\": \"iumrah.hotel-price-update.v2\",\n  ...\n}")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 16)
                        .allowsHitTesting(false)
                }
            }

            HStack(spacing: 10) {
                Button {
                    if let value = UIPasteboard.general.string { jsonText = value }
                } label: {
                    Label("Вставить", systemImage: "doc.on.clipboard")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(BusinessDesign.secondarySurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    jsonText = ""
                    importedDocument = nil
                    preview = nil
                    selectedHotelIDs.removeAll()
                } label: {
                    Label("Очистить", systemImage: "xmark")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(BusinessDesign.secondarySurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            Button {
                Task { await previewPastedJSON() }
            } label: {
                HStack(spacing: 8) {
                    if previewing { ProgressView().tint(BusinessDesign.onPrimaryControl) }
                    Image(systemName: "checkmark.shield")
                    Text(previewing ? "Проверяем JSON…" : "Показать предпросмотр")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .foregroundStyle(BusinessDesign.onPrimaryControl)
                .background(BusinessDesign.primaryControl, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(previewing || applying || jsonText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Text("Приложение принимает только v2: тот же snapshot ID, тот же город, те же даты, 2 взрослых / 1 номер, тот же отель и прямой provider URL. Если ChatGPT не подтвердил цену непосредственно на Expedia/Booking, строка не сможет обновить каталог.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .businessCard(radius: 26)
    }

    private func previewSummary(_ preview: HotelPriceJSONPreview) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Предпросмотр")
                        .font(.title2.bold())
                    Text("\(preview.city) · \(preview.checkIn) → \(preview.checkOut)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(preview.changed) изменений")
                    .font(.caption.bold())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.orange.opacity(0.10), in: Capsule())
            }

            HStack(spacing: 8) {
                metric("Изменено", preview.changed)
                metric("Без изменений", preview.unchanged)
                metric("Не подтверждено", preview.unverified)
            }
            HStack(spacing: 8) {
                metric("Конфликты", preview.conflicts)
                metric("Невалидно", preview.invalid)
                metric("Всего", preview.total)
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
                .minimumScaleFactor(0.7)
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
                Button("Все подтверждённые") {
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
                    Text(applying ? "Обновляем цены…" : "Обновить выбранные цены")
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
                        if let provider = item.currentProvider ?? item.provider { Text(provider) }
                        if let checkIn = item.checkIn { Text("· \(checkIn)") }
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
            } else if let evidence = item.evidence, !evidence.isEmpty {
                Text(evidence)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let reason = item.reason, item.reviewStatus == "unverified" || item.reviewStatus == "needs_review" {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let source = AppConfig.absoluteURL(item.checkedSourceURL ?? item.currentSourceURL ?? item.sourceURL) {
                Link(destination: source) {
                    Label("Открыть проверенный источник", systemImage: "safari")
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
    private func createAccess(city: String, date: Date) async {
        busyCity = city
        notice = nil
        errorMessage = nil
        defer { busyCity = nil }
        do {
            let access = try await APIClient.shared.rotateHotelSyncAccess(city: city)
            guard let url = URL(string: access.accessURL) else { throw PriceJSONUIError.invalidJSON("Сервер вернул некорректную ссылку.") }
            try BusinessSessionVault.setHotelSyncAccessURL(url, city: city)
            setURL(url, city: city)
            _ = try await APIClient.shared.saveHotelSyncSnapshot(city: city, checkIn: date)
            await refreshStatus(city: city)
            notice = "\(city) подключён. Снимок синхронизирован; скопируйте ссылку и отправьте её в ChatGPT."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func syncSnapshot(city: String, date: Date) async {
        busyCity = city
        notice = nil
        errorMessage = nil
        defer { busyCity = nil }
        do {
            let result = try await APIClient.shared.saveHotelSyncSnapshot(city: city, checkIn: date)
            await refreshStatus(city: city)
            notice = "\(city): \(result.hotelCount) отелей синхронизировано на \(result.checkIn) → \(result.checkOut)."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func revokeAccess(city: String) async {
        busyCity = city
        notice = nil
        errorMessage = nil
        defer { busyCity = nil }
        do {
            _ = try await APIClient.shared.revokeHotelSyncAccess(city: city)
            BusinessSessionVault.clearHotelSyncAccessURL(city: city)
            setURL(nil, city: city)
            await refreshStatus(city: city)
            notice = "Read-only доступ \(city) отключён."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func refreshStatus(city: String) async {
        do {
            let status = try await APIClient.shared.hotelSyncStatus(city: city)
            if city == "Makkah" { makkahStatus = status }
            else { madinahStatus = status }
        } catch {
            if city == "Makkah" { makkahStatus = nil }
            else { madinahStatus = nil }
        }
    }

    @MainActor
    private func setURL(_ url: URL?, city: String) {
        if city == "Makkah" { makkahURL = url }
        else { madinahURL = url }
    }

    @MainActor
    private func previewPastedJSON() async {
        previewing = true
        notice = nil
        errorMessage = nil
        defer { previewing = false }

        do {
            let trimmed = jsonText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = trimmed.data(using: .utf8), data.count <= 5_000_000 else {
                throw PriceJSONUIError.invalidJSON("JSON слишком большой или повреждён.")
            }
            let document = try JSONDecoder().decode(HotelPriceUpdateDocument.self, from: data)
            guard document.schema == "iumrah.hotel-price-update.v2" else {
                throw PriceJSONUIError.invalidJSON("Нужен schema iumrah.hotel-price-update.v2.")
            }
            let verifiedPreview = try await APIClient.shared.previewHotelPriceJSON(document)
            importedDocument = document
            preview = verifiedPreview
            selectedHotelIDs = Set(verifiedPreview.items.filter(\.selectable).map(\.hotelID))
            notice = "JSON проверен. Цена ещё не изменена — подтвердите выбранные строки ниже."
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
            notice = "Обновлено \(response.applied) цен. Неподтверждённые и конфликтные строки не были изменены."
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
        let pSign = percent > 0 ? "+" : ""
        return "\(usd) · \(pSign)\(percent.formatted(.number.precision(.fractionLength(0...1))))%"
    }

    private func issueText(_ issue: String) -> String {
        switch issue {
        case "HOTEL_NOT_FOUND": return "Отель больше не найден в каталоге."
        case "CITY_CHANGED": return "Город отеля изменился после снимка."
        case "PRICE_CHANGED_AFTER_SNAPSHOT": return "Цена в iumrah Business уже изменилась после снимка."
        case "SOURCE_CHANGED_AFTER_SNAPSHOT": return "Источник отеля изменился после снимка."
        case "PROVIDER_MISMATCH": return "Provider не совпадает с источником отеля."
        case "DATES_NOT_VERIFIED": return "ChatGPT проверил другую дату."
        case "OCCUPANCY_NOT_VERIFIED": return "Проверено другое число гостей или номеров."
        case "DIRECT_SOURCE_NOT_VERIFIED": return "Нет подтверждения цены с прямой страницы этого же отеля."
        case "HIGH_CONFIDENCE_REQUIRED": return "Для обновления требуется прямое подтверждение с confidence high."
        case "INVALID_NEW_PRICE": return "Новая цена отсутствует или некорректна."
        case "SOURCE_NOT_VERIFIED": return "Источник не дал подтверждаемую цену."
        default: return issue
        }
    }
}

private enum PriceJSONUIError: LocalizedError {
    case invalidJSON(String)

    var errorDescription: String? {
        switch self {
        case .invalidJSON(let message): return message
        }
    }
}
