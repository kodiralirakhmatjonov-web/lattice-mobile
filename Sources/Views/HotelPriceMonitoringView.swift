import SwiftUI
import UIKit

struct HotelPriceMonitoringView: View {
    @Binding var hotels: [HotelListItem]

    @State private var makkahDate = Self.defaultCheckInDate()
    @State private var madinahDate = Self.defaultCheckInDate()
    @State private var makkahURL: URL?
    @State private var madinahURL: URL?
    @State private var makkahJSON: String?
    @State private var madinahJSON: String?
    @State private var makkahStatus: BusinessHotelSyncStatusResponse?
    @State private var madinahStatus: BusinessHotelSyncStatusResponse?
    @State private var syncingCity: String?
    @State private var revokingCity: String?

    @State private var pastedJSON = ""
    @State private var importedDocument: BusinessHotelPriceUpdateDocument?
    @State private var preview: BusinessHotelPricePreview?
    @State private var selectedHotelIDs = Set<String>()
    @State private var previewing = false
    @State private var applying = false
    @State private var notice: String?
    @State private var errorMessage: String?
    @FocusState private var jsonEditorFocused: Bool

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                introCard

                Text("JSON для ChatGPT")
                    .font(.title2.bold())

                citySyncCard(
                    city: "Makkah",
                    title: "Makkah",
                    date: $makkahDate,
                    url: makkahURL,
                    jsonBody: makkahJSON,
                    status: makkahStatus,
                    symbol: "building.2.crop.circle"
                )

                citySyncCard(
                    city: "Madinah",
                    title: "Madinah",
                    date: $madinahDate,
                    url: madinahURL,
                    jsonBody: madinahJSON,
                    status: madinahStatus,
                    symbol: "building.columns.circle"
                )

                resultImportCard

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
        .scrollDismissesKeyboard(.interactively)
        .background(BusinessDesign.background)
        .navigationTitle("Hotel Sync")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Готово") { jsonEditorFocused = false }
                    .fontWeight(.semibold)
            }
        }
        .task { await loadSyncState() }
    }

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .fill(BusinessDesign.primaryControl)
                        .frame(width: 52, height: 52)
                    Image(systemName: "arrow.triangle.2.circlepath.icloud.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(BusinessDesign.onPrimaryControl)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("ChatGPT Hotel Sync")
                        .font(.title2.bold())
                    Text("Каталог приложения → JSON → ChatGPT → подтверждение")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Text("Одним нажатием iumrah Business фиксирует текущий каталог и даты, получает серверный Hotel Sync JSON и сразу копирует весь JSON body. Ссылку больше не нужно переносить в ChatGPT вручную.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                stepPill("1", "Снимок")
                stepPill("2", "JSON")
                stepPill("3", "ChatGPT")
                stepPill("4", "Применить")
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
            Text(title).font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(BusinessDesign.secondarySurface, in: Capsule())
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func citySyncCard(
        city: String,
        title: String,
        date: Binding<Date>,
        url: URL?,
        jsonBody: String?,
        status: BusinessHotelSyncStatusResponse?,
        symbol: String
    ) -> some View {
        let cityHotels = hotelsForCity(city)
        return VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(BusinessDesign.secondarySurface)
                        .frame(width: 50, height: 50)
                    Image(systemName: symbol)
                        .font(.system(size: 20, weight: .semibold))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text("\(cityHotels.count) отелей · текущий список приложения")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let status, status.enabled {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

            DatePicker(
                "Дата проверки цены",
                selection: date,
                in: Self.minimumCheckInDate()...,
                displayedComponents: .date
            )
            .datePickerStyle(.compact)
            .font(.subheadline.weight(.semibold))

            HStack(spacing: 7) {
                Label("2 взрослых", systemImage: "person.2.fill")
                Text("·")
                Label("1 номер", systemImage: "bed.double.fill")
                Text("· 1 ночь · USD")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text("Дата фиксируется внутри snapshot. Цена из другой даты не пройдёт предпросмотр и не сможет обновить каталог.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                Task { await syncAndCopy(city: city, date: date.wrappedValue) }
            } label: {
                HStack(spacing: 8) {
                    if syncingCity == city {
                        ProgressView().tint(BusinessDesign.onPrimaryControl)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    Text(syncingCity == city ? "Готовим JSON…" : "Синхронизировать и скопировать JSON")
                        .fontWeight(.semibold)
                    Spacer()
                    Image(systemName: "doc.on.doc")
                }
                .padding(.horizontal, 16)
                .frame(height: 50)
                .foregroundStyle(BusinessDesign.onPrimaryControl)
                .background(BusinessDesign.primaryControl, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(syncingCity != nil || applying || previewing || cityHotels.isEmpty)

            if url != nil || jsonBody != nil {
                VStack(alignment: .leading, spacing: 11) {
                    HStack(spacing: 8) {
                        Image(systemName: jsonBody == nil ? "clock" : "checkmark.circle.fill")
                            .foregroundStyle(jsonBody == nil ? .secondary : .green)
                        Text(jsonBody == nil ? "Snapshot сохранён" : "JSON готов для ChatGPT")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        if let updatedAt = status?.snapshotUpdatedAt {
                            Text(formatTimestamp(updatedAt))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let jsonBody {
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(jsonBody)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 160)

                        Button {
                            UIPasteboard.general.string = jsonBody
                            notice = "JSON \(city) скопирован. Вставьте его прямо в ChatGPT."
                            errorMessage = nil
                        } label: {
                            HStack {
                                Label("Скопировать JSON", systemImage: "doc.on.doc.fill")
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Text("\(jsonBody.utf8.count / 1024) KB")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 14)
                            .frame(height: 46)
                        }
                        .buttonStyle(.plain)
                        .background(BusinessDesign.secondarySurface, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                    } else {
                        Text("Нажмите синхронизацию ещё раз, чтобы получить и скопировать полный JSON body.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Label("Read-only доступ активен", systemImage: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(role: .destructive) {
                            Task { await revoke(city: city) }
                        } label: {
                            if revokingCity == city {
                                ProgressView().frame(width: 36, height: 36)
                            } else {
                                Image(systemName: "link.badge.minus")
                                    .font(.system(size: 14, weight: .semibold))
                                    .frame(width: 36, height: 36)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(13)
                .background(Color.green.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
        .padding(16)
        .businessCard(radius: 26)
    }

    private var resultImportCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Результат ChatGPT")
                    .font(.title2.bold())
                Text("Вставьте iumrah.hotel-price-update.v2 JSON из ChatGPT")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $pastedJSON)
                    .focused($jsonEditorFocused)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 180)
                    .padding(10)
                    .scrollContentBackground(.hidden)
                    .background(BusinessDesign.secondarySurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                if pastedJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("{\n  \"schema\": \"iumrah.hotel-price-update.v2\",\n  ...\n}")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 18)
                        .allowsHitTesting(false)
                }
            }

            HStack(spacing: 10) {
                Text(pastedJSON.isEmpty ? "Вставьте ответ ChatGPT" : "\(pastedJSON.utf8.count) bytes")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if jsonEditorFocused {
                    Button { jsonEditorFocused = false } label: {
                        Label("Скрыть клавиатуру", systemImage: "keyboard.chevron.compact.down")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                }
                if !pastedJSON.isEmpty {
                    Button("Очистить") {
                        pastedJSON = ""
                        importedDocument = nil
                        preview = nil
                        selectedHotelIDs.removeAll()
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }

            Button {
                jsonEditorFocused = false
                Task { await parseAndPreview() }
            } label: {
                HStack {
                    if previewing { ProgressView() }
                    Label("Проверить JSON", systemImage: "checkmark.shield")
                        .font(.headline)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .frame(height: 50)
                .background(BusinessDesign.secondarySurface, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .disabled(previewing || applying || pastedJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Text("Обновление разрешается только для high-confidence результата с тем же snapshot, hotel ID, property, датами и текущей исходной ценой.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .businessCard(radius: 28)
    }

    private func previewSummary(_ preview: BusinessHotelPricePreview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Предпросмотр").font(.title2.bold())
                    Text("\(preview.city) · \(preview.checkIn) → \(preview.checkOut)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(preview.total)").font(.headline.monospacedDigit())
            }
            HStack(spacing: 8) {
                summaryPill("Изменено", preview.changed, .green)
                summaryPill("Без изменений", preview.unchanged, .secondary)
                summaryPill("Не проверено", preview.unverified, .orange)
            }
            HStack(spacing: 8) {
                summaryPill("Конфликт", preview.conflicts, .red)
                summaryPill("Ошибка", preview.invalid, .red)
            }
        }
        .padding(16)
        .businessCard(radius: 26)
    }

    private func summaryPill(_ title: String, _ count: Int, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Text("\(count)").font(.caption.bold().monospacedDigit())
            Text(title).font(.caption2.weight(.medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(color.opacity(0.08), in: Capsule())
    }

    private func resultControls(_ preview: BusinessHotelPricePreview) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button("Все изменения") {
                    selectedHotelIDs = Set(preview.items.filter(\.selectable).map(\.hotelID))
                }
                .buttonStyle(.bordered)
                Button("Снять выбор") { selectedHotelIDs.removeAll() }
                    .buttonStyle(.bordered)
                Spacer()
                Text("\(selectedHotelIDs.count) выбрано")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Button {
                Task { await applySelected() }
            } label: {
                HStack {
                    if applying { ProgressView().tint(BusinessDesign.onPrimaryControl) }
                    Text(applying ? "Обновляем…" : "Обновить выбранные цены")
                        .fontWeight(.semibold)
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                }
                .padding(.horizontal, 16)
                .frame(height: 52)
                .foregroundStyle(BusinessDesign.onPrimaryControl)
                .background(BusinessDesign.primaryControl, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(selectedHotelIDs.isEmpty || applying || previewing)
        }
        .padding(15)
        .businessCard(radius: 24)
    }

    private func resultRow(_ item: BusinessHotelPricePreviewItem) -> some View {
        let selected = selectedHotelIDs.contains(item.hotelID)
        return Button {
            guard item.selectable else { return }
            if selected { selectedHotelIDs.remove(item.hotelID) }
            else { selectedHotelIDs.insert(item.hotelID) }
        } label: {
            VStack(alignment: .leading, spacing: 11) {
                HStack(alignment: .top, spacing: 11) {
                    Image(systemName: selected ? "checkmark.circle.fill" : (item.selectable ? "circle" : "minus.circle"))
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(selected ? .green : .secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.hotelName)
                            .font(.headline)
                            .multilineTextAlignment(.leading)
                        Text(item.hotelID)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    statusBadge(item)
                }

                if let old = item.oldNightlyUSD, let new = item.newNightlyUSD, item.status.lowercased() == "changed" {
                    HStack(spacing: 8) {
                        Text(Self.usd(old)).foregroundStyle(.secondary)
                        Image(systemName: "arrow.right").font(.caption.bold()).foregroundStyle(.tertiary)
                        Text(Self.usd(new)).fontWeight(.bold)
                        if let percent = item.deltaPercent {
                            Text(String(format: "%+.1f%%", percent))
                                .font(.caption.bold().monospacedDigit())
                                .foregroundStyle(percent > 0 ? .orange : .green)
                        }
                    }
                    .font(.subheadline.monospacedDigit())
                }

                if let observed = item.observedNightlyAmount, let currency = item.observedCurrency, currency.uppercased() != "USD" {
                    Text("Источник: \(formatMoney(observed, currency: currency))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let issue = item.issue {
                    Text(issueText(issue))
                        .font(.caption)
                        .foregroundStyle(item.reviewStatus == "unverified" ? .orange : .red)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(BusinessDesign.secondarySurface, in: RoundedRectangle(cornerRadius: 21, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .disabled(!item.selectable)
    }

    private func statusBadge(_ item: BusinessHotelPricePreviewItem) -> some View {
        let value: (String, Color) = {
            switch item.reviewStatus {
            case "ready": return ("Готово", .green)
            case "unchanged": return ("Без изменений", .secondary)
            case "unverified": return ("Не подтверждено", .orange)
            case "conflict": return ("Конфликт", .red)
            case "applied": return ("Обновлено", .green)
            default: return ("Ошибка", .red)
            }
        }()
        return Text(value.0)
            .font(.caption2.bold())
            .foregroundStyle(value.1)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(value.1.opacity(0.08), in: Capsule())
    }

    @MainActor
    private func loadSyncState() async {
        let storedMakkahURL = BusinessSessionVault.hotelSyncAccessURL(city: "Makkah")
        let storedMadinahURL = BusinessSessionVault.hotelSyncAccessURL(city: "Madinah")
        makkahURL = storedMakkahURL
        madinahURL = storedMadinahURL

        async let makkah = try? APIClient.shared.hotelSyncStatus(city: "Makkah")
        async let madinah = try? APIClient.shared.hotelSyncStatus(city: "Madinah")
        makkahStatus = await makkah
        madinahStatus = await madinah

        if let storedMakkahURL, makkahStatus?.enabled == true {
            makkahJSON = try? await APIClient.shared.hotelSyncReadOnlyBody(from: storedMakkahURL)
        } else {
            makkahJSON = nil
        }
        if let storedMadinahURL, madinahStatus?.enabled == true {
            madinahJSON = try? await APIClient.shared.hotelSyncReadOnlyBody(from: storedMadinahURL)
        } else {
            madinahJSON = nil
        }
    }

    @MainActor
    private func syncAndCopy(city: String, date: Date) async {
        syncingCity = city
        notice = nil
        errorMessage = nil
        defer { syncingCity = nil }
        do {
            // Keep the proven Flight Sync token/snapshot architecture: every explicit
            // sync rotates to a fresh read-only access URL and stores a fresh snapshot.
            // The only UI difference is that we copy the resulting JSON body, not the URL.
            let access = try await APIClient.shared.rotateHotelSyncAccess(city: city)
            guard let accessURL = URL(string: access.accessURL) else {
                throw APIError.server("HOTEL_SYNC_INVALID_ACCESS_URL")
            }
            try BusinessSessionVault.setHotelSyncAccessURL(accessURL, city: city)

            let snapshot = try await APIClient.shared.saveHotelSyncSnapshot(city: city, checkIn: date, hotels: hotels)

            // Keep the same read-only token architecture as Flight Sync, but remove an
            // unnecessary manual step for the operator: read the public feed immediately
            // and copy the exact JSON body that ChatGPT would receive from the URL.
            let jsonBody = try await APIClient.shared.hotelSyncReadOnlyBody(from: accessURL)
            if city == "Makkah" {
                makkahURL = accessURL
                makkahJSON = jsonBody
            } else {
                madinahURL = accessURL
                madinahJSON = jsonBody
            }
            UIPasteboard.general.string = jsonBody
            notice = "\(city): \(snapshot.hotelCount) отелей на \(snapshot.checkIn). JSON скопирован — вставьте его прямо в ChatGPT."

            if let status = try? await APIClient.shared.hotelSyncStatus(city: city) {
                if city == "Makkah" {
                    makkahStatus = status
                } else {
                    madinahStatus = status
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func revoke(city: String) async {
        revokingCity = city
        defer { revokingCity = nil }
        do {
            _ = try await APIClient.shared.revokeHotelSyncAccess(city: city)
            BusinessSessionVault.clearHotelSyncAccessURL(city: city)
            if city == "Makkah" { makkahURL = nil; makkahJSON = nil; makkahStatus = nil }
            else { madinahURL = nil; madinahJSON = nil; madinahStatus = nil }
            notice = "Ссылка \(city) отключена."
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func parseAndPreview() async {
        jsonEditorFocused = false
        previewing = true
        notice = nil
        errorMessage = nil
        defer { previewing = false }
        do {
            let json = extractJSONObject(from: pastedJSON)
            guard let data = json.data(using: .utf8) else { throw APIError.server("INVALID_JSON") }
            let document = try JSONDecoder().decode(BusinessHotelPriceUpdateDocument.self, from: data)
            let freshHotels = try await APIClient.shared.hotels()
            hotels = freshHotels
            let resolved = try await APIClient.shared.previewHotelChatGPTUpdate(document, currentHotels: freshHotels)
            importedDocument = document
            preview = resolved
            selectedHotelIDs = Set(resolved.items.filter(\.selectable).map(\.hotelID))
            notice = resolved.changed == 0 ? "JSON проверен. Подтверждённых изменений нет." : "JSON проверен. Ничего ещё не опубликовано."
        } catch {
            importedDocument = nil
            preview = nil
            selectedHotelIDs.removeAll()
            errorMessage = "Не удалось проверить JSON: \(error.localizedDescription)"
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
            let freshHotels = try await APIClient.shared.hotels()
            hotels = freshHotels
            let freshPreview = try await APIClient.shared.previewHotelChatGPTUpdate(document, currentHotels: freshHotels)
            let allowed = Set(freshPreview.items.filter(\.selectable).map(\.hotelID))
            let finalSelection = selectedHotelIDs.intersection(allowed)
            guard !finalSelection.isEmpty else { throw APIError.server("HOTEL_SYNC_SELECTION_NO_LONGER_VALID") }

            let response = try await APIClient.shared.applyHotelChatGPTUpdate(document, selectedHotelIDs: finalSelection)
            hotels = try await APIClient.shared.hotels()
            if response.appliedCount > 0 {
                notice = "Обновлено цен: \(response.appliedCount). Каталог уже перечитан с новыми значениями."
            }
            if response.rejectedCount > 0 {
                let first = response.rejected.first?.error ?? "HOTEL_SYNC_REJECTED"
                errorMessage = "Не применено: \(response.rejectedCount). \(issueText(first))"
            }
            selectedHotelIDs.removeAll()
            preview = nil
            importedDocument = nil
            pastedJSON = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func hotelsForCity(_ city: String) -> [HotelListItem] {
        hotels.filter { canonicalCity($0.city) == city }
    }

    private func canonicalCity(_ value: String) -> String? {
        let raw = value.lowercased().replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        if raw.contains("makkah") || raw.contains("mecca") || raw.contains("مكة") { return "Makkah" }
        if raw.contains("madinah") || raw.contains("medina") || raw.contains("المدينة") { return "Madinah" }
        return nil
    }

    private func extractJSONObject(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = trimmed.firstIndex(of: "{"), let last = trimmed.lastIndex(of: "}"), first <= last {
            return String(trimmed[first...last])
        }
        return trimmed
    }

    private func issueText(_ issue: String) -> String {
        switch issue {
        case "PRICE_CHANGED_AFTER_SNAPSHOT", "HOTEL_SYNC_PRICE_CHANGED_AFTER_SNAPSHOT": return "Цена изменилась после создания ссылки. Синхронизируйте город ещё раз."
        case "SOURCE_CHANGED_AFTER_SNAPSHOT", "HOTEL_SYNC_SOURCE_CHANGED_AFTER_SNAPSHOT": return "Источник отеля изменился после snapshot."
        case "DATES_OR_OCCUPANCY_MISMATCH", "HOTEL_SYNC_DATES_OR_OCCUPANCY_MISMATCH": return "Не совпадают дата, номер или число гостей."
        case "CHECKED_SOURCE_DATES_NOT_VERIFIED", "HOTEL_SYNC_CHECKED_SOURCE_DATES_MISMATCH": return "В проверенной ссылке не подтверждены точные даты snapshot."
        case "CHECKED_SOURCE_NOT_VERIFIED", "HOTEL_SYNC_SOURCE_NOT_VERIFIED": return "Не подтверждён точный источник отеля."
        case "HOTEL_SYNC_PROPERTY_MISMATCH": return "Проверена другая гостиница/property."
        case "HOTEL_SYNC_SNAPSHOT_CHANGED": return "Snapshot уже изменился. Повторите проверку по новой ссылке."
        case "LOW_CONFIDENCE": return "Недостаточная уверенность проверки."
        case "PRICE_NOT_VERIFIED": return "Цена не подтверждена источником."
        case "INVALID_NEW_PRICE", "HOTEL_SYNC_INVALID_NEW_PRICE": return "Новая цена некорректна."
        case "HOTEL_NOT_FOUND": return "Отель больше не найден в текущем каталоге."
        case "CITY_MISMATCH": return "Город не совпадает."
        default: return issue.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func formatTimestamp(_ value: String) -> String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: value) else { return value }
        let output = DateFormatter()
        output.locale = Locale(identifier: "ru_RU")
        output.timeZone = TimeZone(identifier: "Asia/Tashkent")
        output.dateFormat = "dd.MM HH:mm"
        return output.string(from: date)
    }

    private func formatMoney(_ value: Double, currency: String) -> String {
        if currency.uppercased() == "USD" { return Self.usd(value) }
        return "\(String(format: "%.2f", value)) \(currency.uppercased())"
    }

    private static func usd(_ value: Double) -> String {
        "$" + String(format: value.rounded() == value ? "%.0f" : "%.2f", value)
    }

    private static func minimumCheckInDate() -> Date {
        Calendar.current.startOfDay(for: Date())
    }

    private static func defaultCheckInDate() -> Date {
        Calendar.current.date(byAdding: .day, value: 20, to: minimumCheckInDate()) ?? minimumCheckInDate()
    }
}
