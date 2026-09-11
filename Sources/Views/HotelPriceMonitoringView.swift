import SwiftUI
import UIKit

struct HotelPriceMonitoringView: View {
    @State private var run: HotelPriceMonitorRun?
    @State private var selectedHotelIDs = Set<String>()
    @State private var selectionRunID: String?
    @State private var loading = false
    @State private var publishing = false
    @State private var linkLoading = false
    @State private var notice: String?
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                introCard
                if let run {
                    statusCard(run)
                    if let items = run.items, !items.isEmpty {
                        controls(items)
                        ForEach(items) { item in
                            priceRow(item)
                        }
                    }
                } else if !loading {
                    ContentUnavailableView(
                        "Мониторинг ещё не запускался",
                        systemImage: "arrow.triangle.2.circlepath",
                        description: Text("Проверка читает свежую цену из закреплённого Expedia/Booking источника и ничего не публикует автоматически.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
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
        .navigationTitle("Мониторинг цен")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadLatest() }
        .refreshable { await refreshCurrent() }
    }

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .fill(BusinessDesign.primaryControl)
                        .frame(width: 52, height: 52)
                    Image(systemName: "waveform.path.ecg.rectangle")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(BusinessDesign.onPrimaryControl)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Price Monitor")
                        .font(.title2.bold())
                    Text("Проверка каталога без автоматической публикации")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Text("Система откроет закреплённый источник каждого опубликованного отеля, сохранит найденные цены как кандидаты и покажет изменения. Production-каталог меняется только после Вашего подтверждения.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                Task { await startMonitor() }
            } label: {
                HStack(spacing: 8) {
                    if loading || run?.isActive == true { ProgressView().tint(BusinessDesign.onPrimaryControl) }
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text(run?.isActive == true ? "Мониторинг выполняется" : "Запустить мониторинг цен")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .foregroundStyle(BusinessDesign.onPrimaryControl)
                .background(BusinessDesign.primaryControl, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(loading || run?.isActive == true)

            Button {
                Task { await copyChatGPTCatalogLink() }
            } label: {
                HStack(spacing: 8) {
                    if linkLoading { ProgressView().controlSize(.small) }
                    Image(systemName: "link")
                    Text("Скопировать доступ к каталогу для ChatGPT")
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(BusinessDesign.secondarySurface, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(linkLoading)
        }
        .padding(16)
        .businessCard(radius: 28)
    }

    private func statusCard(_ run: HotelPriceMonitorRun) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(statusTitle(run.status))
                        .font(.headline)
                    Text("Проверено \(run.checkedHotels) из \(run.totalHotels)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(run.changedHotels) изменений")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.orange.opacity(0.10), in: Capsule())
            }

            ProgressView(value: Double(run.checkedHotels), total: Double(max(run.totalHotels, 1)))
                .tint(BusinessDesign.ink)

            HStack(spacing: 8) {
                metric("Изменено", run.changedHotels)
                metric("Без изменений", run.unchangedHotels)
                metric("Ошибки", run.failedHotels)
            }

            if run.isFinished {
                Button {
                    Task { await copyChatGPTLink(runID: run.id) }
                } label: {
                    HStack(spacing: 8) {
                        if linkLoading { ProgressView().controlSize(.small) }
                        Image(systemName: "link")
                        Text("Скопировать результаты для ChatGPT")
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(BusinessDesign.secondarySurface, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(linkLoading)
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

    private func controls(_ items: [HotelPriceMonitorItem]) -> some View {
        let publishable = items.filter(\.isPublishable)
        return VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("Результаты")
                    .font(.title2.bold())
                Spacer()
                Text("\(selectedHotelIDs.count) выбрано")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button("Все") {
                    selectedHotelIDs = Set(publishable.map(\.hotelID))
                }
                Button("Только изменения") {
                    selectedHotelIDs = Set(publishable.filter(\.hasChanged).map(\.hotelID))
                }
                Button("Снять") { selectedHotelIDs.removeAll() }
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.bordered)

            Button {
                Task { await publishSelected() }
            } label: {
                HStack(spacing: 8) {
                    if publishing { ProgressView().tint(BusinessDesign.onPrimaryControl) }
                    Image(systemName: "checkmark.seal.fill")
                    Text("Опубликовать выбранные цены")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .foregroundStyle(BusinessDesign.onPrimaryControl)
                .background(BusinessDesign.primaryControl, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(publishing || selectedHotelIDs.isEmpty || run?.isActive == true)
        }
        .padding(.top, 4)
    }

    private func priceRow(_ item: HotelPriceMonitorItem) -> some View {
        let selected = selectedHotelIDs.contains(item.hotelID)
        return VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 12) {
                Button {
                    guard item.isPublishable else { return }
                    if selected { selectedHotelIDs.remove(item.hotelID) }
                    else { selectedHotelIDs.insert(item.hotelID) }
                } label: {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(item.isPublishable ? (selected ? BusinessDesign.ink : Color.secondary) : Color.secondary.opacity(0.35))
                }
                .buttonStyle(.plain)
                .disabled(!item.isPublishable)

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
                        if let provider = item.provider { Text("· \(provider)") }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            if item.status == "failed" {
                Text(errorText(item.error))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let candidate = item.candidateNightlyUSD {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let old = item.oldNightlyUSD {
                        Text(money(old))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("—")
                            .foregroundStyle(.secondary)
                    }
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

                if let source = AppConfig.absoluteURL(item.sourceURL) {
                    Link(destination: source) {
                        Label("Открыть источник", systemImage: "safari")
                            .font(.caption.weight(.semibold))
                    }
                }
            }
        }
        .padding(14)
        .background(BusinessDesign.secondarySurface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func statusBadge(_ item: HotelPriceMonitorItem) -> some View {
        let text: String
        let color: Color
        switch item.status {
        case "changed": text = "ИЗМЕНЕНИЕ"; color = .orange
        case "unchanged": text = "БЕЗ ИЗМЕНЕНИЙ"; color = .green
        case "published": text = "ОПУБЛИКОВАНО"; color = .blue
        case "failed": text = "ОШИБКА"; color = .red
        case "checking": text = "ПРОВЕРКА"; color = .secondary
        default: text = item.status.uppercased(); color = .secondary
        }
        return Text(text)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(color.opacity(0.09), in: Capsule())
    }

    @MainActor
    private func loadLatest() async {
        loading = true
        defer { loading = false }
        do {
            let runs = try await APIClient.shared.priceMonitorRuns()
            if let latest = runs.first {
                run = try await APIClient.shared.priceMonitorRun(id: latest.id)
                syncSelectionIfNeeded()
                if run?.isActive == true { await pollRun(id: latest.id) }
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func startMonitor() async {
        loading = true
        notice = nil
        errorMessage = nil
        do {
            let started = try await APIClient.shared.startPriceMonitor()
            run = started
            selectionRunID = nil
            selectedHotelIDs.removeAll()
            loading = false
            await pollRun(id: started.id)
        } catch {
            loading = false
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func pollRun(id: String) async {
        while !Task.isCancelled {
            do {
                let latest = try await APIClient.shared.priceMonitorRun(id: id)
                run = latest
                syncSelectionIfNeeded()
                if !latest.isActive { break }
            } catch {
                errorMessage = error.localizedDescription
                break
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    @MainActor
    private func refreshCurrent() async {
        guard let id = run?.id else { await loadLatest(); return }
        do {
            run = try await APIClient.shared.priceMonitorRun(id: id)
            syncSelectionIfNeeded()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func syncSelectionIfNeeded() {
        guard let run, selectionRunID != run.id, let items = run.items else { return }
        if run.isFinished {
            selectedHotelIDs = Set(items.filter(\.hasChanged).map(\.hotelID))
            selectionRunID = run.id
        }
    }

    @MainActor
    private func publishSelected() async {
        guard let run, !selectedHotelIDs.isEmpty else { return }
        publishing = true
        notice = nil
        errorMessage = nil
        do {
            let updated = try await APIClient.shared.publishPriceMonitor(runID: run.id, hotelIDs: Array(selectedHotelIDs))
            self.run = updated
            selectedHotelIDs.subtract(updated.items?.filter { $0.status == "published" }.map(\.hotelID) ?? [])
            notice = "Опубликовано. Каталог iumrah использует подтверждённые цены выбранных отелей."
        } catch {
            errorMessage = error.localizedDescription
        }
        publishing = false
    }

    @MainActor
    private func copyChatGPTCatalogLink() async {
        linkLoading = true
        notice = nil
        errorMessage = nil
        do {
            let response = try await APIClient.shared.createChatGPTAccessLink()
            UIPasteboard.general.string = response.url
            notice = "Доступ к каталогу скопирован. Отправьте ссылку в этот чат — она только для чтения и действует 30 минут."
        } catch {
            errorMessage = error.localizedDescription
        }
        linkLoading = false
    }

    @MainActor
    private func copyChatGPTLink(runID: String) async {
        linkLoading = true
        notice = nil
        errorMessage = nil
        do {
            let response = try await APIClient.shared.createChatGPTAccessLink(runID: runID)
            UIPasteboard.general.string = response.url
            notice = "Ссылка скопирована. Отправьте её в этот чат — она только для чтения и действует 30 минут."
        } catch {
            errorMessage = error.localizedDescription
        }
        linkLoading = false
    }

    private func statusTitle(_ status: String) -> String {
        switch status {
        case "queued": return "В очереди"
        case "running": return "Проверяем источники"
        case "completed": return "Проверка завершена"
        case "completed_with_errors": return "Завершено с предупреждениями"
        case "failed": return "Мониторинг остановлен"
        default: return status
        }
    }

    private func money(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(0...2)))
    }

    private func deltaText(_ delta: Double, percent: Double?) -> String {
        let sign = delta > 0 ? "+" : ""
        if let percent {
            let pSign = percent > 0 ? "+" : ""
            return "\(sign)\(money(delta)) · \(pSign)\(percent.formatted(.number.precision(.fractionLength(1))))%"
        }
        return "\(sign)\(money(delta))"
    }

    private func errorText(_ code: String?) -> String {
        switch code {
        case "HOTEL_PRICE_SOURCE_MISSING": return "Для отеля не закреплён источник цены."
        case "HOTEL_PRICE_NOT_FOUND_ON_SOURCE": return "Источник открылся, но подтверждаемая цена не найдена."
        case "HOTEL_PRICE_SOURCE_CHALLENGE": return "Источник временно показал защитную проверку."
        case "HOTEL_PRICE_BROWSER_UNAVAILABLE": return "Облачный браузер временно недоступен."
        case "HOTEL_PRICE_SOURCE_PROPERTY_MISMATCH": return "Источник не подтверждает точный объект отеля."
        default: return code ?? "Цена не подтверждена."
        }
    }
}
