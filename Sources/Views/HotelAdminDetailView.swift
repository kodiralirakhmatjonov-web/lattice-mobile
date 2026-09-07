import Foundation
import SwiftUI
import WebKit

struct HotelAdminDetailView: View {
    let hotelID: String
    let onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var hotel: HotelAdminDetail?
    @State private var selectedStars = 3
    @State private var selectedCity = ""
    @State private var loading = true
    @State private var refreshingPrice = false
    @State private var editingManualPrice = false
    @State private var manualPriceText = ""
    @State private var savingManualPrice = false
    @State private var savingStars = false
    @State private var savingCity = false
    @State private var deleting = false
    @State private var showDeleteConfirmation = false
    @State private var errorMessage: String?
    @State private var savedMessage: String?
    @State private var citySavedMessage: String?
    @State private var priceNotice: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let hotel {
                    hero(hotel)
                    cityCard(hotel)
                    priceCard(hotel)
                    starsCard(hotel)
                    sourceCard(hotel)
                    detailsCard(hotel)
                    deleteCard(hotel)
                } else if !loading {
                    ContentUnavailableView(
                        "Отель недоступен",
                        systemImage: "building.2.crop.circle",
                        description: Text(errorMessage ?? "Не удалось загрузить карточку отеля.")
                    )
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
        }
        .background(BusinessDesign.background.ignoresSafeArea())
        .navigationTitle("Отель")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if loading {
                ProgressView()
                    .controlSize(.large)
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .onChange(of: selectedStars) { _, value in
            if hotel?.stars != value { savedMessage = nil }
        }
        .alert("Удалить отель?", isPresented: $showDeleteConfirmation) {
            Button("Отмена", role: .cancel) { }
            Button("Удалить", role: .destructive) {
                Task { await deleteHotel() }
            }
        } message: {
            Text("Отель будет удалён из D1, а связанные изображения — из Hotels Cloud. Это действие нельзя отменить.")
        }
        .alert("Не удалось выполнить действие", isPresented: Binding(
            get: { errorMessage != nil && hotel != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Неизвестная ошибка")
        }
    }

    private func hero(_ hotel: HotelAdminDetail) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Group {
                if let imageURL = coverURL(hotel) {
                    AsyncImage(url: imageURL) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else {
                            heroPlaceholder
                        }
                    }
                } else {
                    heroPlaceholder
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 210)
            .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))

            VStack(alignment: .leading, spacing: 7) {
                Text(hotel.name)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .tracking(-0.8)

                HStack(spacing: 8) {
                    Label(hotel.city, systemImage: "mappin.and.ellipse")
                    if let stars = hotel.stars {
                        Text("·")
                        Text("\(stars)★")
                    }
                    if let rating = hotel.rating {
                        Text("·")
                        Label(rating.formatted(.number.precision(.fractionLength(1))), systemImage: "star.fill")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                statusPill(hotel)
            }
        }
    }

    private func cityCard(_ hotel: HotelAdminDetail) -> some View {
        let current = canonicalManagedCity(hotel.city)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Город")
                        .font(.title2.bold())
                    Text("Сохраняется в D1 и сразу используется клиентским каталогом и Primary Hotels.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if current == nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            if current == nil {
                Label("Город не распознан. Выберите Makkah или Madinah вручную.", systemImage: "mappin.slash")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            }

            Picker("Город", selection: $selectedCity) {
                Text("Мекка").tag("Makkah")
                Text("Медина").tag("Madinah")
            }
            .pickerStyle(.segmented)

            if let citySavedMessage {
                Label(citySavedMessage, systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            }

            Button {
                Task { await saveCity() }
            } label: {
                HStack {
                    if savingCity { ProgressView() }
                    Text(savingCity ? "Сохраняю…" : "Сохранить город")
                    Spacer()
                    Image(systemName: "checkmark")
                }
                .font(.headline)
                .padding(.horizontal, 16)
                .frame(height: 50)
                .background(BusinessDesign.secondarySurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .disabled(savingCity || selectedCity.isEmpty || selectedCity == current)
        }
        .padding(17)
        .businessCard(radius: 28)
    }

    private func priceCard(_ hotel: HotelAdminDetail) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .firstTextBaseline) {
                Text("Цена")
                    .font(.title2.bold())
                Spacer()
                if let price = hotel.price {
                    Text(priceStatus(price))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(price.status == "failed" ? Color.orange : (price.isManualOverride == true ? BusinessDesign.accent : Color.secondary))
                }
            }

            if let price = hotel.price, let nightly = price.nightlyUSD, price.hasUsablePrice {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(nightly.formatted(.currency(code: "USD").precision(.fractionLength(0))))
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text("/ ночь")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if price.isManualOverride == true {
                        Text("Ручная цена · сохранена в D1")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(BusinessDesign.accent)
                        if let sourceNightly = price.sourceNightlyUSD {
                            Text("Последняя цена источника: \(sourceNightly.formatted(.currency(code: "USD").precision(.fractionLength(0))))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        if let provider = price.provider ?? hotel.sources.first?.provider {
                            Text(provider.capitalized)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let fetchedAt = price.fetchedAt {
                            Text("Последнее обновление: \(compactDate(fetchedAt))")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            } else if hotel.price?.status == "pending" {
                Label("Цена обновляется", systemImage: "arrow.clockwise")
                    .foregroundStyle(.secondary)
            } else {
                Label("Актуальная цена пока недоступна", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }

            if editingManualPrice {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Цена за одну ночь · USD")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Text("$")
                            .font(.title2.bold())
                        TextField("173", text: $manualPriceText)
                            .keyboardType(.decimalPad)
                            .font(.title2.monospacedDigit())
                            .textFieldStyle(.plain)
                        Button(savingManualPrice ? "Сохраняю…" : "Сохранить") {
                            Task { await saveManualPrice() }
                        }
                        .fontWeight(.semibold)
                        .disabled(savingManualPrice || parsedManualPrice == nil)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 54)
                    .background(BusinessDesign.secondarySurface, in: RoundedRectangle(cornerRadius: 17, style: .continuous))

                    Text("Ручное значение становится текущей ценой в D1 и сразу используется клиентским каталогом.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Button {
                if !editingManualPrice {
                    manualPriceText = editablePrice(hotel.price?.nightlyUSD)
                }
                withAnimation(.easeInOut(duration: 0.2)) { editingManualPrice.toggle() }
            } label: {
                Label(editingManualPrice ? "Скрыть ручное изменение" : "Изменить цену вручную", systemImage: "pencil")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(BusinessDesign.secondarySurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)

            if let priceNotice {
                Label(priceNotice, systemImage: "clock.arrow.circlepath")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }

            Button {
                Task { await refreshPrice() }
            } label: {
                HStack {
                    if refreshingPrice {
                        ProgressView().tint(BusinessDesign.onPrimaryControl)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text(refreshingPrice ? "Читаем источник…" : "Обновить из источника")
                    Spacer()
                }
                .font(.headline)
                .foregroundStyle(BusinessDesign.onPrimaryControl)
                .padding(.horizontal, 16)
                .frame(height: 52)
                .background(BusinessDesign.primaryControl, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(refreshingPrice || savingManualPrice)
        }
        .padding(18)
        .businessCard(radius: 28)
    }

    private func starsCard(_ hotel: HotelAdminDetail) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Звёздность")
                    .font(.title2.bold())
                Text("Изменение сохраняется в D1. Клиентский каталог получает это значение из той же записи отеля.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Picker("Звёзды", selection: $selectedStars) {
                ForEach(1...5, id: \.self) { stars in
                    Text("\(stars)★").tag(stars)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                if let savedMessage {
                    Label(savedMessage, systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                }
                Spacer()
                Button("Сохранить") {
                    Task { await saveStars() }
                }
                .fontWeight(.semibold)
                .disabled(savingStars || selectedStars == hotel.stars)
            }
        }
        .padding(17)
        .businessCard(radius: 28)
    }

    @ViewBuilder
    private func sourceCard(_ hotel: HotelAdminDetail) -> some View {
        if let source = preferredSource(hotel), let url = URL(string: source.url) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Источник")
                    .font(.title2.bold())

                HStack(spacing: 12) {
                    Image(systemName: "link.circle.fill")
                        .font(.title2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(source.provider)
                            .font(.headline)
                        Text("Источник цены и карточки отеля")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                Link(destination: url) {
                    Label("Открыть источник", systemImage: "arrow.up.right.square")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(BusinessDesign.secondarySurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
            }
            .padding(17)
            .businessCard(radius: 28)
        }
    }

    private func detailsCard(_ hotel: HotelAdminDetail) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("Карточка отеля")
                .font(.title2.bold())

            detailRow("Город", hotel.city)
            detailRow("Страна", hotel.country)
            detailRow("Номеров", "\(hotel.rooms.count)")
            detailRow("Фотографий", "\(hotel.images.count)")
            if !hotel.address.isEmpty {
                detailRow("Адрес", hotel.address)
            }
            if let reviewCount = hotel.reviewCount {
                detailRow("Отзывы", reviewCount.formatted())
            }
            detailRow("Статус", hotel.status == "published" ? "Опубликован" : hotel.status.capitalized)
        }
        .padding(17)
        .businessCard(radius: 28)
    }

    private func deleteCard(_ hotel: HotelAdminDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Управление")
                .font(.title2.bold())
            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                HStack {
                    if deleting {
                        ProgressView().tint(.red)
                    } else {
                        Image(systemName: "trash")
                    }
                    Text(deleting ? "Удаляем…" : "Удалить отель")
                    Spacer()
                }
                .font(.headline)
                .padding(.horizontal, 16)
                .frame(height: 52)
                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(deleting)
        }
        .padding(17)
        .businessCard(radius: 28)
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 14)
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }

    @ViewBuilder
    private var heroPlaceholder: some View {
        BusinessDesign.secondarySurface
            .overlay {
                Image(systemName: "building.2.fill")
                    .font(.system(size: 42))
                    .foregroundStyle(.secondary)
            }
    }

    private func statusPill(_ hotel: HotelAdminDetail) -> some View {
        Text(hotel.status == "published" ? "LIVE" : (hotel.lifecycleState?.uppercased() ?? hotel.status.uppercased()))
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(hotel.status == "published" ? Color.green : Color.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background((hotel.status == "published" ? Color.green : Color.gray).opacity(0.09), in: Capsule())
    }

    private func coverURL(_ hotel: HotelAdminDetail) -> URL? {
        let path = hotel.images.first(where: \.isCover)?.url ?? hotel.images.first?.url
        return AppConfig.absoluteURL(path)
    }

    private func preferredSource(_ hotel: HotelAdminDetail) -> (provider: String, url: String)? {
        if let url = hotel.price?.sourceURL, !url.isEmpty {
            return (hotel.price?.provider?.capitalized ?? hotel.sources.first?.provider.capitalized ?? "Источник", url)
        }
        if let source = hotel.sources.first, !source.sourceURL.isEmpty {
            return (source.provider.capitalized, source.sourceURL)
        }
        return nil
    }

    private func priceStatus(_ price: HotelCachedPrice) -> String {
        switch price.status {
        case "manual": return "Ручная цена"
        case "fresh": return "Актуально"
        case "stale": return "Нужно обновить"
        case "pending": return "Обновляется"
        case "failed": return "Ошибка"
        default: return price.status.capitalized
        }
    }

    private func compactDate(_ raw: String) -> String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: raw) else { return raw }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    @MainActor
    private func load() async {
        loading = hotel == nil
        defer { loading = false }
        do {
            let detail = try await APIClient.shared.hotelDetail(id: hotelID)
            hotel = detail
            selectedStars = detail.stars ?? 3
            selectedCity = canonicalManagedCity(detail.city) ?? ""
            if !editingManualPrice { manualPriceText = editablePrice(detail.price?.nightlyUSD) }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func refreshPrice() async {
        refreshingPrice = true
        defer { refreshingPrice = false }
        do {
            let response: HotelPriceResponse
            if let currentHotel = hotel, let source = preferredSource(currentHotel),
               source.provider.lowercased().contains("booking"),
               let sourceURL = URL(string: source.url) {
                do {
                    // Booking blocks server-side datacenter refreshes with HTTP 429. Read the
                    // live rate in a private WKWebView on this iPhone, then persist only that
                    // verified price snapshot back to the existing D1 price cache. Expedia
                    // keeps its current server refresh path unchanged.
                    let reader = BookingLivePriceReader()
                    let live = try await reader.read(sourceURL: sourceURL)
                    response = try await APIClient.shared.saveBrowserHotelPrice(
                        id: hotelID,
                        sourceURL: live.sourceURL.absoluteString,
                        price: live.price
                    )
                } catch {
                    // Keep the existing server fallback as a safety net for Booking. The
                    // backend preserves the last accepted price if Booking is temporarily
                    // unavailable, so a refresh failure never makes the hotel unusable.
                    response = try await APIClient.shared.refreshHotelPrice(id: hotelID)
                }
            } else {
                response = try await APIClient.shared.refreshHotelPrice(id: hotelID)
            }

            let latest = try await APIClient.shared.hotelDetail(id: hotelID)
            hotel = latest
            manualPriceText = editablePrice(latest.price?.nightlyUSD)
            editingManualPrice = false
            if let warning = response.error, !warning.isEmpty {
                savedMessage = nil
                // Do not interrupt the operator with a raw provider error. The last good
                // D1 price remains active and the scheduled retry continues in background.
                priceNotice = latest.price?.hasUsablePrice == true
                    ? "Последняя рабочая цена сохранена. Автообновление повторится позже."
                    : "Booking пока не вернул новую цену. Повторите обновление чуть позже."
            } else {
                priceNotice = nil
                savedMessage = "Цена обновлена из источника"
            }
            onChanged()
            errorMessage = nil
        } catch {
            if let latest = try? await APIClient.shared.hotelDetail(id: hotelID) {
                hotel = latest
                manualPriceText = editablePrice(latest.price?.nightlyUSD)
                if preferredSource(latest)?.provider.lowercased().contains("booking") == true {
                    // Booking may rate-limit both the device browser and the server on a
                    // particular attempt. Never expose transport/provider codes to the
                    // operator and never invalidate the last accepted D1 price.
                    errorMessage = nil
                    priceNotice = latest.price?.hasUsablePrice == true
                        ? "Booking временно не отдал новую цену. Последняя рабочая цена остаётся активной; автообновление повторится позже."
                        : "Booking временно не отдал цену. Повторите обновление чуть позже."
                } else {
                    errorMessage = error.localizedDescription
                }
            } else {
                errorMessage = "Не удалось обновить цену. Повторите попытку чуть позже."
            }
        }
    }

    private var parsedManualPrice: Double? {
        let normalized = manualPriceText
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value >= 1, value <= 10_000 else { return nil }
        return value
    }

    private func editablePrice(_ value: Double?) -> String {
        guard let value else { return "" }
        if value.rounded() == value { return String(Int(value)) }
        return String(format: "%.2f", value)
    }

    @MainActor
    private func saveManualPrice() async {
        guard let value = parsedManualPrice else { return }
        savingManualPrice = true
        defer { savingManualPrice = false }
        do {
            _ = try await APIClient.shared.setManualHotelPrice(id: hotelID, nightlyUSD: value)
            let latest = try await APIClient.shared.hotelDetail(id: hotelID)
            hotel = latest
            manualPriceText = editablePrice(latest.price?.nightlyUSD)
            editingManualPrice = false
            savedMessage = "Ручная цена сохранена в базе"
            onChanged()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func canonicalManagedCity(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value == "makkah" || value == "mecca" { return "Makkah" }
        if value == "madinah" || value == "medina" { return "Madinah" }
        return nil
    }

    @MainActor
    private func saveCity() async {
        guard selectedCity == "Makkah" || selectedCity == "Madinah" else { return }
        savingCity = true
        citySavedMessage = nil
        defer { savingCity = false }
        do {
            let updated = try await APIClient.shared.updateHotelCity(id: hotelID, city: selectedCity)
            hotel = updated
            selectedCity = canonicalManagedCity(updated.city) ?? selectedCity
            citySavedMessage = "Город сохранён в базе"
            onChanged()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func saveStars() async {
        guard (1...5).contains(selectedStars) else { return }
        savingStars = true
        savedMessage = nil
        defer { savingStars = false }
        do {
            let updated = try await APIClient.shared.updateHotelStars(id: hotelID, stars: selectedStars)
            hotel = updated
            selectedStars = updated.stars ?? selectedStars
            savedMessage = "Сохранено в базе"
            onChanged()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func deleteHotel() async {
        deleting = true
        defer { deleting = false }
        do {
            try await APIClient.shared.deleteHotel(id: hotelID)
            onChanged()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct BookingLivePriceResult {
    let sourceURL: URL
    let price: ProviderPriceSnapshot
}

@MainActor
private final class BookingLivePriceReader: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<BookingLivePriceResult, Error>?
    private var webView: WKWebView?
    private var timeoutTask: Task<Void, Never>?
    private var evaluating = false

    func read(sourceURL: URL) async throws -> BookingLivePriceResult {
        guard continuation == nil else {
            throw NSError(domain: "iumrah.booking-price", code: 1, userInfo: [NSLocalizedDescriptionKey: "BOOKING_PRICE_READER_BUSY"])
        }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Safari/605.1.15"
        self.webView = webView

        let preparedURL = Self.preparedURL(sourceURL)
        var request = URLRequest(url: preparedURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("selected_currency=USD", forHTTPHeaderField: "Cookie")

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            self.timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 28_000_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.finish(.failure(NSError(
                        domain: "iumrah.booking-price",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "BOOKING_PRICE_TIMEOUT"]
                    )))
                }
            }
            webView.load(request)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard continuation != nil, !evaluating else { return }
        evaluating = true
        Task { [weak self, weak webView] in
            guard let self, let webView else { return }
            try? await Task.sleep(nanoseconds: 900_000_000)
            _ = try? await webView.evaluateJavaScript(Self.preparePageScript)
            try? await Task.sleep(nanoseconds: 950_000_000)

            if let result = await self.extract(from: webView) {
                self.finish(.success(result))
                return
            }

            _ = try? await webView.evaluateJavaScript("""
            (() => {
              const target = document.querySelector('#hprt-table')
                || document.querySelector('[data-testid="availability-table"]')
                || document.querySelector('[data-testid*="availability"]');
              if (target) target.scrollIntoView({ block: 'start' });
              else window.scrollTo(0, document.documentElement.scrollHeight * 0.55);
              return !!target;
            })();
            """)
            try? await Task.sleep(nanoseconds: 1_250_000_000)

            if let result = await self.extract(from: webView) {
                self.finish(.success(result))
            } else {
                self.finish(.failure(NSError(
                    domain: "iumrah.booking-price",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "BOOKING_LIVE_PRICE_NOT_FOUND"]
                )))
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    private func extract(from webView: WKWebView) async -> BookingLivePriceResult? {
        let javascriptValue = try? await webView.evaluateJavaScript(Self.extractPriceScript)
        guard let raw = javascriptValue as? String,
              let data = raw.data(using: .utf8),
              let price = try? JSONDecoder().decode(ProviderPriceSnapshot.self, from: data),
              price.isUsable,
              let resolvedURL = webView.url else { return nil }
        return BookingLivePriceResult(sourceURL: resolvedURL, price: price)
    }

    private func finish(_ result: Result<BookingLivePriceResult, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        evaluating = false
        timeoutTask?.cancel()
        timeoutTask = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        continuation.resume(with: result)
    }

    private static func preparedURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = components.queryItems ?? []

        func set(_ name: String, _ value: String, onlyIfMissing: Bool = false) {
            if let index = items.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                if !onlyIfMissing { items[index] = URLQueryItem(name: name, value: value) }
            } else {
                items.append(URLQueryItem(name: name, value: value))
            }
        }

        set("selected_currency", "USD")
        set("changed_currency", "1")
        set("group_adults", "2", onlyIfMissing: true)
        set("group_children", "0", onlyIfMissing: true)
        set("no_rooms", "1", onlyIfMissing: true)

        let hasCheckIn = items.contains { $0.name.caseInsensitiveCompare("checkin") == .orderedSame && !($0.value ?? "").isEmpty }
        let hasCheckOut = items.contains { $0.name.caseInsensitiveCompare("checkout") == .orderedSame && !($0.value ?? "").isEmpty }
        if !hasCheckIn || !hasCheckOut {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let start = calendar.startOfDay(for: Date()).addingTimeInterval(86_400)
            let end = start.addingTimeInterval(86_400)
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            if !hasCheckIn { set("checkin", formatter.string(from: start)) }
            if !hasCheckOut { set("checkout", formatter.string(from: end)) }
        }

        components.queryItems = items
        return components.url ?? url
    }

    private static let preparePageScript = #"""
    (() => {
      const clean = value => String(value || '').replace(/\s+/g, ' ').trim();
      const buttons = [...document.querySelectorAll('button,a,[role="button"]')];
      const availability = buttons.find(el => /see availability|show prices|check availability|view prices/i.test(clean(`${el.innerText || ''} ${el.getAttribute?.('aria-label') || ''}`)));
      if (availability && availability.offsetParent !== null) {
        try { availability.scrollIntoView({ block: 'center' }); availability.click(); } catch (_) {}
      }
      const table = document.querySelector('#hprt-table') || document.querySelector('[data-testid="availability-table"]');
      if (table) table.scrollIntoView({ block: 'start' });
      return true;
    })();
    """#

    private static let extractPriceScript = #"""
    (() => {
      const clean = value => String(value || '').replace(/\s+/g, ' ').trim();
      const parseAmount = raw => {
        let text = clean(raw).replace(/[\u00a0\u202f\s]/g, '').replace(/[^0-9.,]/g, '');
        if (!text) return null;
        const comma = text.lastIndexOf(',');
        const dot = text.lastIndexOf('.');
        if (comma >= 0 && dot >= 0) {
          if (dot > comma) text = text.replace(/,/g, '');
          else text = text.replace(/\./g, '').replace(',', '.');
        } else if (comma >= 0) {
          const after = text.length - comma - 1;
          text = (after === 1 || after === 2) ? text.replace(',', '.') : text.replace(/,/g, '');
        } else if (dot >= 0) {
          const after = text.length - dot - 1;
          if (after !== 1 && after !== 2) text = text.replace(/\./g, '');
        }
        const amount = Number(text);
        return Number.isFinite(amount) && amount > 0 ? amount : null;
      };
      const currencyFor = text => {
        const value = String(text || '').toUpperCase();
        if (/US\$|USD/.test(value) || /(^|[^A-Z])\$\s*[0-9]/.test(value)) return 'USD';
        if (/SAR|(^|[^A-Z])SR\b|ر\.?س\.?/.test(value)) return 'SAR';
        if (/AED|د\.?إ\.?/.test(value)) return 'AED';
        return null;
      };
      const moneyFrom = text => {
        const value = clean(text);
        const patterns = [
          /(?:US\$|USD|\$|SAR|SR|ر\.?س\.?|AED|د\.?إ\.?)\s*([0-9][0-9.,\s]*)/i,
          /([0-9][0-9.,\s]*)\s*(?:US\$|USD|\$|SAR|SR|ر\.?س\.?|AED|د\.?إ\.?)/i
        ];
        for (const pattern of patterns) {
          const match = value.match(pattern);
          if (!match) continue;
          const amount = parseAmount(match[1]);
          const currency = currencyFor(match[0]);
          if (amount && currency) return { amount, currency };
        }
        return null;
      };
      const hidden = el => {
        const style = window.getComputedStyle?.(el);
        const rect = el.getBoundingClientRect?.();
        return !!(style && (style.display === 'none' || style.visibility === 'hidden')) || !!(rect && rect.width === 0 && rect.height === 0);
      };
      const selectors = [
        '#hprt-table [data-testid="price-and-discounted-price"]',
        '[data-testid="availability-table"] [data-testid="price-and-discounted-price"]',
        '[data-testid="price-and-discounted-price"]',
        '#hprt-table [data-testid="price-for-x-nights"]',
        '[data-testid="price-for-x-nights"]',
        '#hprt-table .prco-valign-middle-helper',
        '.bui-price-display__value'
      ];
      const candidates = [];
      let order = 0;
      for (const selector of selectors) {
        for (const el of document.querySelectorAll(selector)) {
          if (hidden(el) || el.closest('s,del')) continue;
          const context = clean(el.innerText || el.textContent || '');
          const money = moneyFrom(context);
          if (!money || money.amount < 10) continue;
          let roomName = null;
          let node = el;
          for (let depth = 0; node && depth < 7; depth += 1, node = node.parentElement) {
            const heading = clean(node.querySelector?.('[data-testid="room-name"],h2,h3,h4,[role="heading"]')?.innerText || '');
            if (heading && heading.length <= 180) { roomName = heading; break; }
          }
          let score = 100 - order;
          if (selector.includes('price-and-discounted-price')) score += 30;
          if (el.closest('#hprt-table,[data-testid="availability-table"]')) score += 25;
          if (/member|genius|sign in|reward/i.test(context)) score -= 5;
          candidates.push({ ...money, roomName, score, order: order++ });
        }
        if (candidates.length) break;
      }
      if (!candidates.length) return null;
      candidates.sort((a,b) => b.score - a.score || a.order - b.order || a.amount - b.amount);
      const chosen = candidates[0];
      const query = new URL(location.href).searchParams;
      const checkIn = query.get('checkin');
      const checkOut = query.get('checkout');
      let nights = 1;
      if (checkIn && checkOut) {
        const a = Date.parse(`${checkIn}T00:00:00Z`);
        const b = Date.parse(`${checkOut}T00:00:00Z`);
        const rawNights = Math.round((b - a) / 86400000);
        if (Number.isFinite(rawNights) && rawNights > 0 && rawNights <= 30) nights = rawNights;
      }
      return JSON.stringify({
        amount: chosen.amount,
        currency: chosen.currency,
        totalAmount: null,
        totalCurrency: null,
        priceBasis: nights === 1 ? 'nightly' : 'stay_total',
        checkIn: checkIn || null,
        checkOut: checkOut || null,
        nights,
        adults: Math.max(1, Number(query.get('group_adults')) || 2),
        rooms: Math.max(1, Number(query.get('no_rooms')) || 1),
        roomName: chosen.roomName || null,
        method: 'booking-ios-live-browser-v1',
        confidence: 0.995
      });
    })();
    """#
}
