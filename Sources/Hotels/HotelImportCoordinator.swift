import Foundation
import SwiftUI
import WebKit

@MainActor
final class HotelImportCoordinator: NSObject, ObservableObject, WKNavigationDelegate {
    enum Provider: String, CaseIterable, Codable {
        case booking = "Booking"
        case expedia = "Expedia"

        static func detect(from url: URL) -> Provider? {
            let host = (url.host ?? "").lowercased()
            if host == "booking.com" || host.hasSuffix(".booking.com") { return .booking }
            if host == "expe.onelink.me" || host.hasSuffix(".expe.onelink.me") { return .expedia }
            if host.contains("expedia.") || host == "expedia.com" || host.hasSuffix(".expedia.com") { return .expedia }
            return nil
        }

        func isShareRedirectURL(_ url: URL) -> Bool {
            let host = (url.host ?? "").lowercased()
            switch self {
            case .booking:
                let path = url.path.lowercased()
                return path.hasPrefix("/share-") || path.hasPrefix("/share/") || path.hasPrefix("/share_")
            case .expedia:
                return host == "expe.onelink.me" || host.hasSuffix(".expe.onelink.me")
            }
        }

        func isProviderContentURL(_ url: URL) -> Bool {
            let host = (url.host ?? "").lowercased()
            switch self {
            case .booking:
                return host == "booking.com" || host.hasSuffix(".booking.com")
            case .expedia:
                return host.contains("expedia.") || host == "expedia.com" || host.hasSuffix(".expedia.com")
            }
        }

        func isLikelyHotelDetailURL(_ url: URL) -> Bool {
            switch self {
            case .booking:
                // Booking share/app-interstitial URLs often carry the real hotel URL inside
                // a query parameter. Looking at absoluteString therefore produced false
                // positives and allowed the "View this property in the app" shell to be
                // imported as a hotel. The path itself must be the property path.
                let path = url.path.lowercased()
                return path.hasPrefix("/hotel/")
            case .expedia:
                let value = url.absoluteString.lowercased()
                return value.contains("hotel-information") || value.contains(".hotel-information") || value.contains("/hotel/")
            }
        }

        var sourceIcon: String {
            switch self {
            case .booking: return "b.circle.fill"
            case .expedia: return "e.circle.fill"
            }
        }
    }

    enum Stage {
        case idle
        case loading
        case warming
        case extracting
        case finished
        case failed
    }

    @Published var status = "Вставьте ссылку на конкретный отель"
    @Published var progress: Double = 0
    @Published var currentProvider: Provider?
    @Published var draft: HotelDraft?
    @Published var requiresUserAction = false
    @Published var showSource = false
    @Published var failureMessage: String?
    @Published var sourceURL: URL?
    @Published var duplicateCandidate: HotelDuplicate?
    @Published var roomRecoveryRunning = false

    let webView: WKWebView
    private var stage: Stage = .idle
    private var extractionStarted = false
    private var completionReported = false
    private var isRoomProbeNavigation = false
    private var bookingResolutionInFlight = false

    var onCompleted: ((HotelDraft) -> Void)?
    var onFailed: ((String) -> Void)?

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.userContentController.addUserScript(
            WKUserScript(
                source: Self.networkCaptureBootstrapScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )

        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.customUserAgent = Self.mobileSafariUserAgent
    }

    func start(sourceURL rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalized = Self.normalizedHotelURL(trimmed), let provider = Provider.detect(from: normalized) else {
            fail("Поддерживаются только прямые ссылки на конкретный отель в Booking или Expedia.")
            return
        }
        guard provider.isShareRedirectURL(normalized) || provider.isLikelyHotelDetailURL(normalized) else {
            fail("Это похоже не на карточку отеля. Откройте конкретный отель в \(provider.rawValue) и скопируйте ссылку его страницы.")
            return
        }

        stage = .loading
        extractionStarted = false
        completionReported = false
        bookingResolutionInFlight = false
        webView.customUserAgent = Self.userAgent(for: provider)
        sourceURL = normalized
        currentProvider = provider
        draft = nil
        failureMessage = nil
        duplicateCandidate = nil
        requiresUserAction = false
        showSource = false
        progress = 0.05
        status = "Проверяем, не добавлен ли этот отель раньше…"

        Task {
            do {
                if let duplicate = try await APIClient.shared.checkHotelSourceDuplicate(normalized.absoluteString) {
                    if duplicate.isDefinitive {
                        fail("Этот отель уже есть в базе: \(duplicate.name). Повторный импорт отключён.")
                        return
                    }
                    duplicateCandidate = duplicate
                }
            } catch {
                // A temporary dedupe-check failure must not block reading the source.
            }

            status = provider.isShareRedirectURL(normalized)
                ? "Открываем ссылку \(provider.rawValue) и переходим к карточке отеля…"
                : "Открываем карточку \(provider.rawValue)…"
            progress = 0.08

            var request = URLRequest(url: normalized, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 45)
            request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
            request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
            webView.load(request)
        }
    }

    func retryRoomRecovery() {
        guard !roomRecoveryRunning, var candidate = draft, let provider = currentProvider, let propertyURL = sourceURL else { return }
        roomRecoveryRunning = true
        Task {
            defer { roomRecoveryRunning = false }
            status = "Повторно получаем типы номеров…"
            var rooms = candidate.rooms
            let browserRooms = await recoverRoomsInBrowser(provider: provider, propertyURL: propertyURL)
            rooms = Self.mergeRooms(rooms, browserRooms)
            candidate.rooms = rooms
            candidate.dataQuality["rooms"] = rooms.isEmpty ? "missing-needs-review" : "confirmed:\(rooms.count)"
            draft = candidate
            status = rooms.isEmpty ? "Типы номеров пока не подтверждены." : "Найдено типов номеров: \(rooms.count)"
        }
    }

    func continueAfterVerification() {
        requiresUserAction = false
        showSource = false
        extractionStarted = false
        Task { await beginExtractionIfPossible() }
    }

    func reloadSource() {
        webView.reload()
    }

    func setCover(_ imageID: UUID) {
        guard var value = draft else { return }
        for index in value.images.indices { value.images[index].isCover = value.images[index].id == imageID }
        if let index = value.images.firstIndex(where: { $0.id == imageID }) { value.images[index].selected = true }
        draft = value
    }

    func toggleImage(_ imageID: UUID) {
        guard var value = draft, let index = value.images.firstIndex(where: { $0.id == imageID }) else { return }
        value.images[index].selected.toggle()
        if value.images[index].isCover && !value.images[index].selected { value.images[index].isCover = false }
        if !value.images.contains(where: { $0.isCover && $0.selected }), let first = value.images.firstIndex(where: \.selected) {
            value.images[first].isCover = true
        }
        draft = value
    }

    func selectAllTrustedImages() {
        guard var value = draft else { return }
        for index in value.images.indices { value.images[index].selected = value.images[index].kind.trusted }
        if !value.images.contains(where: { $0.isCover && $0.selected }), let first = value.images.firstIndex(where: \.selected) {
            value.images[first].isCover = true
        }
        draft = value
    }

    func deselectAllImages() {
        guard var value = draft else { return }
        for index in value.images.indices {
            value.images[index].selected = false
            value.images[index].isCover = false
        }
        draft = value
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { await beginExtractionIfPossible() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if isRoomProbeNavigation { return }
        fail(error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if isRoomProbeNavigation { return }
        fail(error.localizedDescription)
    }

    private func beginExtractionIfPossible() async {
        guard !extractionStarted, stage != .finished, stage != .failed else { return }
        guard let provider = currentProvider else { return }

        if await detectVerification() {
            requiresUserAction = true
            showSource = true
            stage = .loading
            status = "\(provider.rawValue) просит проверку. Пройдите её на открытой странице и нажмите «Продолжить»."
            return
        }

        guard let currentURL = webView.url else { return }

        // Booking may finish navigation on a Share-* / app-install interstitial even though
        // the real property URL is embedded in the DOM, scripts or query parameters. Resolve
        // that destination before any extraction. This is Booking-only by design.
        if provider == .booking, !provider.isLikelyHotelDetailURL(currentURL) {
            await resolveBookingDestination(from: currentURL)
            return
        }

        if provider.isShareRedirectURL(currentURL) {
            status = "Переходим из ссылки \(provider.rawValue) к карточке отеля…"
            progress = max(progress, 0.12)
            return
        }
        guard provider.isProviderContentURL(currentURL) else {
            if provider.isShareRedirectURL(sourceURL ?? currentURL) {
                status = "Переходим из ссылки \(provider.rawValue) к карточке отеля…"
                progress = max(progress, 0.12)
            }
            return
        }
        guard provider.isLikelyHotelDetailURL(currentURL) else {
            fail("Ссылка открылась в \(provider.rawValue), но не на карточке конкретного отеля. Откройте нужный отель и скопируйте его ссылку ещё раз.")
            return
        }
        extractionStarted = true
        sourceURL = currentURL
        await warmAndExtract(provider: provider, currentURL: currentURL)
    }

    private func warmAndExtract(provider: Provider, currentURL: URL) async {
        stage = .warming
        progress = 0.22
        status = "Собираем все фотографии именно этой карточки…"

        _ = try? await webView.evaluateJavaScript(Self.initializeMediaCaptureScript(provider: provider, sourceURL: currentURL.absoluteString))
        await captureVisibleMedia(provider: provider, sourceURL: currentURL)

        // Warm the exact property page so lazy property sections are available, but do not
        // harvest arbitrary page images while scrolling. Expedia places recommendations,
        // nearby cards and ads on the same document; media is captured only from the exact
        // property gallery / room section below.
        let pageFractions: [Double] = [0.0, 0.18, 0.36, 0.54, 0.72, 0.88]
        for (index, fraction) in pageFractions.enumerated() {
            let script = "window.scrollTo(0, Math.max(0, (document.documentElement.scrollHeight - window.innerHeight) * \(fraction)));"
            _ = try? await webView.evaluateJavaScript(script)
            try? await Task.sleep(nanoseconds: 120_000_000)
            progress = 0.22 + (Double(index + 1) / Double(pageFractions.count)) * 0.16
        }

        // Always return to the property hero before opening the main hotel gallery. This
        // prevents a generic "View all photos" search from selecting a recommended hotel
        // or a room card farther down the page.
        _ = try? await webView.evaluateJavaScript("window.scrollTo(0, 0);")
        try? await Task.sleep(nanoseconds: 220_000_000)
        await captureVisibleMedia(provider: provider, sourceURL: currentURL)

        status = "Открываем полную галерею именно этого отеля…"
        let openedGallery = ((try? await webView.evaluateJavaScript(Self.openGalleryScript())) as? Bool) == true
        if openedGallery {
            try? await Task.sleep(nanoseconds: 650_000_000)
            await captureVisibleMedia(provider: provider, sourceURL: currentURL)
            let galleryFractions: [Double] = [0.0, 0.08, 0.16, 0.24, 0.32, 0.40, 0.48, 0.56, 0.64, 0.72, 0.80, 0.88, 0.94, 1.0]
            for (index, fraction) in galleryFractions.enumerated() {
                _ = try? await webView.evaluateJavaScript(Self.scrollGalleryScript(fraction: fraction))
                try? await Task.sleep(nanoseconds: 130_000_000)
                await captureVisibleMedia(provider: provider, sourceURL: currentURL)
                progress = 0.42 + (Double(index + 1) / Double(galleryFractions.count)) * 0.24
            }
            _ = try? await webView.evaluateJavaScript(Self.closeGalleryScript())
            try? await Task.sleep(nanoseconds: 350_000_000)
            _ = try? await webView.evaluateJavaScript("window.scrollTo(0, document.documentElement.scrollHeight * 0.72);")
            try? await Task.sleep(nanoseconds: 220_000_000)
        }

        status = "Открываем список типов номеров…"
        progress = 0.68
        let revealedRooms = ((try? await webView.evaluateJavaScript(Self.revealRoomsScript())) as? Bool) == true
        if revealedRooms {
            try? await Task.sleep(nanoseconds: 1_350_000_000)
        }
        for fraction in [0.0, 0.30, 0.62, 1.0] {
            _ = try? await webView.evaluateJavaScript(Self.scrollRoomsScript(fraction: fraction))
            try? await Task.sleep(nanoseconds: 260_000_000)
            await captureVisibleMedia(provider: provider, sourceURL: currentURL)
        }

        stage = .extracting
        progress = 0.76
        status = "Читаем типы номеров, рейтинг, удобства и правила…"

        do {
            let source = currentURL.absoluteString
            let raw = try await webView.evaluateJavaScript(Self.extractionScript(provider: provider, sourceURL: source))
            guard let json = raw as? String, let data = json.data(using: .utf8) else {
                throw APIError.server("EMPTY_HOTEL_EXTRACT")
            }
            let snapshot = try JSONDecoder().decode(ProviderSnapshot.self, from: data)

            // URL identity is authoritative. Expedia embeds recommendation hotels in the same
            // page/application state, so a mismatching property ID must fail closed rather
            // than create a mixed hotel object.
            if provider == .expedia, let expectedID = Self.propertyID(from: currentURL, provider: provider) {
                guard snapshot.providerHotelID == expectedID else {
                    throw APIError.server("SOURCE_PROPERTY_ID_MISMATCH: ожидали Expedia property \(expectedID), получили \(snapshot.providerHotelID ?? "нет ID").")
                }
                if let canonical = snapshot.canonicalURL, !canonical.isEmpty,
                   !Self.isSameProperty(canonical, as: currentURL, provider: provider) {
                    throw APIError.server("SOURCE_CANONICAL_PROPERTY_MISMATCH")
                }
            }

            guard let name = snapshot.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                throw APIError.server("Не удалось прочитать название отеля с этой страницы.")
            }
            guard !Self.isChallengeIdentity(name), !(await detectVerification()) else {
                requiresUserAction = true
                showSource = true
                extractionStarted = false
                stage = .loading
                status = "Expedia открыла защитную страницу вместо карточки отеля. Пройдите проверку и нажмите «Продолжить»."
                return
            }
            if provider == .booking, Self.isBookingInterstitialIdentity(name) {
                throw APIError.server("BOOKING_APP_INTERSTITIAL: Booking открыл экран приложения вместо карточки отеля.")
            }

            var candidate = HotelNormalizer.makeDraft(snapshot: snapshot)

            // The exact imported source page is the only authority. Room recovery may re-read
            // THIS SAME URL in an isolated WKWebView, but it must never add dates, change host,
            // search by hotel name, or contribute a price from another page/context.
            let initialPrice = candidate.importedPrice
            if candidate.rooms.count < 4 {
                status = "Уточняем типы номеров с этой же страницы…"
                progress = 0.86
                let browserRooms = await recoverRoomsInBrowser(provider: provider, propertyURL: currentURL)
                if !browserRooms.isEmpty {
                    candidate.rooms = Self.mergeRooms(candidate.rooms, browserRooms)
                }
            }

            if candidate.rooms.isEmpty {
                candidate.dataQuality["rooms"] = "missing-needs-review"
            } else {
                candidate.dataQuality["rooms"] = "confirmed:\(candidate.rooms.count)"
            }
            candidate.dataQuality["price"] = candidate.importedPrice == nil ? "missing-unavailable" : "confirmed-live"

            status = "Проверяем отель по всей базе iumrah…"
            progress = 0.94
            if let duplicate = try await APIClient.shared.checkHotelDuplicate(candidate) {
                if duplicate.isDefinitive {
                    fail("Этот отель уже есть в базе: \(duplicate.name). Expedia/Booking не создадут вторую карточку.")
                    return
                }
                duplicateCandidate = duplicate
            } else {
                duplicateCandidate = nil
            }

            draft = candidate
            progress = 1
            stage = .finished
            if candidate.importedPrice == nil {
                status = "Карточка получена, но цена не подтверждена — публикация будет недоступна."
            } else {
                status = candidate.rooms.isEmpty ? "Карточка получена. Номера требуют повторной проверки." : "Готово: \(name)"
            }
            if !completionReported {
                completionReported = true
                onCompleted?(candidate)
            }
        } catch {
            fail("Не удалось полностью разобрать карточку отеля: \(error.localizedDescription)")
        }
    }

    private func captureVisibleMedia(provider: Provider, sourceURL: URL) async {
        _ = try? await webView.evaluateJavaScript(Self.captureVisibleMediaScript(provider: provider, sourceURL: sourceURL.absoluteString))
    }

    private static func mergeRooms(_ primary: [HotelRoomDraft], _ recovered: [HotelRoomDraft]) -> [HotelRoomDraft] {
        var output: [HotelRoomDraft] = []
        var keys = Set<String>()
        for room in primary + recovered {
            let name = room.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let key = [
                name.lowercased(),
                room.beds?.lowercased() ?? "",
                room.maxGuests.map(String.init) ?? "",
                room.sizeM2.map { String(format: "%.1f", $0) } ?? "",
                room.view?.lowercased() ?? ""
            ].joined(separator: "|")
            guard keys.insert(key).inserted else { continue }
            output.append(room)
            if output.count >= 140 { break }
        }
        return output
    }

    private func recoverRoomsInBrowser(provider: Provider, propertyURL: URL) async -> [HotelRoomDraft] {
        var recovered: [HotelRoomDraft] = []

        // Exact-source only: this auxiliary WebView may re-open the same URL solely to
        // expose room cards. It never mutates query parameters and never contributes price.
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.userContentController.addUserScript(
            WKUserScript(
                source: Self.networkCaptureBootstrapScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        let roomWebView = WKWebView(frame: .zero, configuration: config)
        roomWebView.customUserAgent = Self.userAgent(for: provider)

        status = "Уточняем номера с исходной страницы…"
        progress = 0.88
        var request = URLRequest(url: propertyURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        roomWebView.load(request)

        guard await waitForRoomProbeLoad(roomWebView, provider: provider, timeoutSeconds: 20),
              !(await detectVerification(in: roomWebView)) else {
            roomWebView.stopLoading()
            return recovered
        }

        _ = try? await roomWebView.evaluateJavaScript(Self.revealRoomsScript())
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        for fraction in [0.0, 0.22, 0.48, 0.74, 1.0] {
            _ = try? await roomWebView.evaluateJavaScript(Self.scrollRoomsScript(fraction: fraction))
            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        if let pageURL = roomWebView.url,
           provider.isProviderContentURL(pageURL),
           Self.isSameProperty(pageURL, as: propertyURL, provider: provider),
           !(await detectVerification(in: roomWebView)),
           let raw = try? await roomWebView.evaluateJavaScript(Self.extractionScript(provider: provider, sourceURL: propertyURL.absoluteString)),
           let json = raw as? String,
           let data = json.data(using: .utf8),
           let snapshot = try? JSONDecoder().decode(ProviderSnapshot.self, from: data),
           !Self.isChallengeIdentity(snapshot.name) {
            if provider != .expedia
                || Self.propertyID(from: propertyURL, provider: provider) == snapshot.providerHotelID {
                recovered = HotelNormalizer.makeDraft(snapshot: snapshot).rooms
            }
        }

        roomWebView.stopLoading()
        return recovered
    }

    private func waitForRoomProbeLoad(_ targetWebView: WKWebView, provider: Provider, timeoutSeconds: Double) async -> Bool {
        let iterations = max(1, Int(timeoutSeconds / 0.25))
        for _ in 0..<iterations {
            if !targetWebView.isLoading, let url = targetWebView.url, provider.isProviderContentURL(url) {
                let state = (try? await targetWebView.evaluateJavaScript("document.readyState")) as? String
                if state == "complete" || state == "interactive" { return true }
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    private func detectVerification() async -> Bool {
        await detectVerification(in: webView)
    }

    private func detectVerification(in targetWebView: WKWebView) async -> Bool {
        do {
            let value = try await targetWebView.evaluateJavaScript("""
            (() => {
              const t = (document.body?.innerText || '').toLowerCase();
              const title = String(document.title || '').toLowerCase();
              const h1 = String(document.querySelector('h1')?.innerText || '').toLowerCase();
              const challenge = [
                'captcha', 'verify you are human', 'are you a robot', 'security check',
                'unusual traffic', 'bot or not', 'robot check', 'access denied',
                'проверка безопасности', 'подтвердите, что вы человек'
              ];
              return challenge.some(x => t.includes(x) || title.includes(x) || h1.includes(x));
            })();
            """)
            return (value as? Bool) == true
        } catch {
            return false
        }
    }

    private static func isChallengeIdentity(_ value: String?) -> Bool {
        let text = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return false }
        return [
            "bot or not", "verify you are human", "are you a robot", "security check",
            "robot check", "access denied", "captcha"
        ].contains { text.contains($0) }
    }

    private func resolveBookingDestination(from currentURL: URL) async {
        guard !bookingResolutionInFlight, stage != .finished, stage != .failed else { return }
        bookingResolutionInFlight = true
        status = "Booking перенаправляет на точную карточку отеля…"
        progress = max(progress, 0.12)

        for attempt in 0..<14 {
            if let pageURL = webView.url, Provider.booking.isLikelyHotelDetailURL(pageURL) {
                bookingResolutionInFlight = false
                sourceURL = pageURL
                await beginExtractionIfPossible()
                return
            }

            if let raw = try? await webView.evaluateJavaScript(Self.bookingDestinationScript),
               let value = raw as? String,
               let resolved = Self.bookingHotelURLCandidate(from: value, baseURL: webView.url ?? currentURL) {
                bookingResolutionInFlight = false
                sourceURL = resolved
                var request = URLRequest(url: resolved, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 45)
                request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
                request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
                webView.load(request)
                return
            }

            if attempt == 4 || attempt == 9 {
                progress = min(0.18, progress + 0.02)
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        // Last Booking-only fallback: resolve the Share-* HTTP chain outside the WebView.
        // This bypasses the mobile app-promotion shell when Booking returns the real hotel
        // location in redirects or in the interstitial HTML.
        let fallbackURL = sourceURL ?? currentURL
        if let resolved = await Self.resolveBookingShareURL(fallbackURL) {
            bookingResolutionInFlight = false
            sourceURL = resolved
            var request = URLRequest(url: resolved, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 45)
            request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
            request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
            webView.load(request)
            return
        }

        bookingResolutionInFlight = false
        fail("Booking не отдал прямую карточку отеля из этой Share-ссылки. Попробуйте ещё раз: importer больше не будет принимать экран «Посмотрите это жилье в приложении» за отель.")
    }

    private static func resolveBookingShareURL(_ url: URL) async -> URL? {
        guard Provider.booking.isProviderContentURL(url) else { return nil }
        if Provider.booking.isLikelyHotelDetailURL(url) { return url }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue(bookingDesktopSafariUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let finalURL = response.url ?? url
            return Provider.booking.isLikelyHotelDetailURL(finalURL) ? finalURL : nil
        } catch {
            return nil
        }
    }

    private static func bookingHotelURLCandidate(from rawValue: String, baseURL: URL) -> URL? {
        let normalized = rawValue
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "\\u002F", with: "/", options: .caseInsensitive)
            .replacingOccurrences(of: "\\u003A", with: ":", options: .caseInsensitive)

        func validated(_ raw: String) -> URL? {
            var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            for suffix in ["&quot;", "&#34;", "&#39;"] {
                if let range = value.range(of: suffix) { value = String(value[..<range.lowerBound]) }
            }
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'<>),];"))
            guard !value.isEmpty else { return nil }

            let decoded = value.removingPercentEncoding ?? value
            let candidate: URL?
            if decoded.hasPrefix("//") {
                candidate = URL(string: "https:\(decoded)")
            } else if decoded.hasPrefix("/") {
                candidate = URL(string: decoded, relativeTo: baseURL)?.absoluteURL
            } else {
                candidate = URL(string: decoded, relativeTo: baseURL)?.absoluteURL
            }
            guard let candidate else { return nil }
            let host = (candidate.host ?? "").lowercased()
            guard host == "booking.com" || host.hasSuffix(".booking.com") else { return nil }
            guard Provider.booking.isLikelyHotelDetailURL(candidate) else { return nil }
            return candidate
        }

        // A direct URL can be passed here by the JavaScript resolver.
        if normalized.count < 8_192, let direct = validated(normalized) { return direct }

        let variants = [normalized, normalized.removingPercentEncoding ?? normalized]
        let patterns = [
            #"https?://(?:[A-Za-z0-9-]+\.)*booking\.com/hotel/[^\s\"'<>\\]+"#,
            #"//(?:[A-Za-z0-9-]+\.)*booking\.com/hotel/[^\s\"'<>\\]+"#,
            #"/hotel/[A-Za-z]{2}/[^\s\"'<>\\]+"#
        ]

        for value in variants {
            for pattern in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
                let range = NSRange(value.startIndex..<value.endIndex, in: value)
                for match in regex.matches(in: value, options: [], range: range).prefix(40) {
                    guard let swiftRange = Range(match.range, in: value) else { continue }
                    if let candidate = validated(String(value[swiftRange])) { return candidate }
                }
            }
        }
        return nil
    }

    private static let bookingDestinationScript = #"""
    (() => {
      const isHotel = raw => {
        try {
          let value = String(raw || '').trim()
            .replace(/&amp;/g, '&')
            .replace(/\\u002f/ig, '/')
            .replace(/\\u003a/ig, ':')
            .replace(/\\\//g, '/');
          for (let i = 0; i < 3; i += 1) {
            try {
              const decoded = decodeURIComponent(value);
              if (decoded === value) break;
              value = decoded;
            } catch (_) { break; }
          }
          const u = new URL(value, location.href);
          const host = u.hostname.toLowerCase();
          if (!(host === 'booking.com' || host.endsWith('.booking.com'))) return null;
          if (!u.pathname.toLowerCase().startsWith('/hotel/')) return null;
          u.hash = '';
          return u.toString();
        } catch (_) { return null; }
      };

      const candidates = [
        location.href,
        document.querySelector('link[rel="canonical"]')?.href,
        document.querySelector('meta[property="og:url"]')?.content,
        document.querySelector('meta[name="twitter:url"]')?.content
      ].filter(Boolean);

      for (const el of document.querySelectorAll('a[href],link[href],form[action],[data-url],[data-href],[data-link],[data-target-url],meta[content]')) {
        for (const attr of ['href','action','data-url','data-href','data-link','data-target-url','content']) {
          const value = el.getAttribute?.(attr);
          if (value) candidates.push(value);
        }
      }

      const inspect = raw => {
        const direct = isHotel(raw);
        if (direct) return direct;
        try {
          const u = new URL(String(raw || ''), location.href);
          for (const [, value] of u.searchParams) {
            const nested = isHotel(value);
            if (nested) return nested;
          }
        } catch (_) {}
        return null;
      };

      for (const raw of candidates) {
        const found = inspect(raw);
        if (found) return found;
      }

      const source = String(document.documentElement?.innerHTML || '')
        .replace(/\\u002f/ig, '/')
        .replace(/\\u003a/ig, ':')
        .replace(/\\\//g, '/');
      const absolute = source.match(/https?:\/\/(?:[A-Za-z0-9-]+\.)*booking\.com\/hotel\/[^\s"'<>\\]+/ig) || [];
      for (const raw of absolute.slice(0, 80)) {
        const found = inspect(raw);
        if (found) return found;
      }
      const relative = source.match(/\/hotel\/[A-Za-z]{2}\/[^\s"'<>\\]+/ig) || [];
      for (const raw of relative.slice(0, 80)) {
        const found = inspect(raw);
        if (found) return found;
      }
      return null;
    })();
    """#

    private static let mobileSafariUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Mobile/15E148 Safari/604.1"
    private static let bookingDesktopSafariUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Safari/605.1.15"

    private static func userAgent(for provider: Provider) -> String {
        provider == .booking ? bookingDesktopSafariUserAgent : mobileSafariUserAgent
    }

    private static func isBookingInterstitialIdentity(_ value: String?) -> Bool {
        let text = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return false }
        return [
            "view this property in the app",
            "see this property in the app",
            "open this property in the app",
            "посмотрите это жилье в приложении",
            "посмотреть это жилье в приложении",
            "откройте это жилье в приложении"
        ].contains { text.contains($0) }
    }

    private func fail(_ message: String) {
        stage = .failed
        failureMessage = message
        status = message
        progress = 0
        extractionStarted = false
        bookingResolutionInFlight = false
        if !completionReported {
            completionReported = true
            onFailed?(message)
        }
    }

    private static let networkCaptureBootstrapScript = #"""
    (() => {
      if (window.__iumrahNetworkCaptureInstalled) return;
      window.__iumrahNetworkCaptureInstalled = true;
      window.__iumrahJSONResponses = window.__iumrahJSONResponses || [];
      const keep = value => {
        try {
          if (!value || typeof value !== 'object') return;
          const json = JSON.stringify(value);
          if (!json || json.length > 4000000) return;
          if (!/(room|suite|bed|occupancy|unit|accommodation|property|hotel)/i.test(json.slice(0, 600000))) return;
          window.__iumrahJSONResponses.push(value);
          if (window.__iumrahJSONResponses.length > 36) window.__iumrahJSONResponses.shift();
        } catch (_) {}
      };
      const captureResponse = async response => {
        try {
          const url = String(response?.url || '');
          if (!/(expedia|travelscape|booking|bstatic)/i.test(url)) return;
          const contentType = String(response.headers?.get?.('content-type') || '');
          if (!/json|graphql/i.test(contentType) && !/graphql|api|search|room|availability/i.test(url)) return;
          const text = await response.clone().text();
          if (!text || text.length > 4000000) return;
          keep(JSON.parse(text));
        } catch (_) {}
      };
      try {
        const originalFetch = window.fetch;
        if (originalFetch) {
          window.fetch = async function(...args) {
            const response = await originalFetch.apply(this, args);
            captureResponse(response);
            return response;
          };
        }
      } catch (_) {}
      try {
        const originalOpen = XMLHttpRequest.prototype.open;
        const originalSend = XMLHttpRequest.prototype.send;
        XMLHttpRequest.prototype.open = function(method, url, ...rest) {
          this.__iumrahURL = String(url || '');
          return originalOpen.call(this, method, url, ...rest);
        };
        XMLHttpRequest.prototype.send = function(...args) {
          this.addEventListener('load', function() {
            try {
              if (!/(expedia|travelscape|booking|bstatic)/i.test(this.__iumrahURL || '')) return;
              const type = String(this.getResponseHeader('content-type') || '');
              if (!/json|graphql/i.test(type) && !/graphql|api|search|room|availability/i.test(this.__iumrahURL || '')) return;
              const text = String(this.responseText || '');
              if (!text || text.length > 4000000) return;
              keep(JSON.parse(text));
            } catch (_) {}
          });
          return originalSend.apply(this, args);
        };
      } catch (_) {}
    })();
    """#

    private static func revealRoomsScript() -> String {
        """
        (() => {
          const clean = el => String(el?.innerText || el?.textContent || el?.getAttribute?.('aria-label') || '').replace(/\\s+/g, ' ').trim();
          const nodes = [...document.querySelectorAll('button,a,[role="button"],[aria-controls]')];
          const patterns = /show all rooms|view all rooms|see all rooms|room options|available rooms|choose your room|select a room|rooms and rates|all room types|показать все номера|все номера/i;
          const target = nodes.find(el => patterns.test(clean(el)) && el.offsetParent !== null)
            || nodes.find(el => patterns.test(clean(el)));
          if (target) {
            try { target.scrollIntoView({ block: 'center' }); target.click(); return true; } catch (_) {}
          }
          const headings = [...document.querySelectorAll('h1,h2,h3,[role="heading"]')];
          const heading = headings.find(el => /room options|available rooms|choose your room|rooms and rates|room types|номера/i.test(clean(el)));
          if (heading) { try { heading.scrollIntoView({ block: 'start' }); return true; } catch (_) {} }
          return false;
        })();
        """
    }

    private static func scrollRoomsScript(fraction: Double) -> String {
        """
        (() => {
          const clean = el => String(el?.innerText || el?.textContent || '').replace(/\\s+/g, ' ').trim();
          const roots = [...document.querySelectorAll('[role="dialog"],section,article,main')]
            .filter(el => /room options|available rooms|choose your room|rooms and rates|showing \\d+ of \\d+ rooms/i.test(clean(el).slice(0, 1600)))
            .sort((a,b) => (b.scrollHeight || 0) - (a.scrollHeight || 0));
          const target = roots[0];
          if (target && target.scrollHeight > target.clientHeight + 200) {
            target.scrollTop = Math.max(0, target.scrollHeight - target.clientHeight) * \(fraction);
          } else if (target) {
            const rect = target.getBoundingClientRect();
            window.scrollTo(0, window.scrollY + rect.top - 90 + Math.max(0, target.scrollHeight - window.innerHeight) * \(fraction));
          }
          return !!target;
        })();
        """
    }

    private static func normalizedHotelURL(_ value: String) -> URL? {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.lowercased().hasPrefix("http://") && !text.lowercased().hasPrefix("https://") {
            text = "https://\(text)"
        }
        guard var components = URLComponents(string: text), let host = components.host, !host.isEmpty else { return nil }
        components.fragment = nil
        if components.scheme == "http" { components.scheme = "https" }
        return components.url
    }

    private static func propertyID(from url: URL, provider: Provider) -> String? {
        guard provider == .expedia else { return nil }
        if let explicit = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { ["expediaPropertyId", "propertyId"].contains($0.name) })?.value,
           explicit.range(of: #"^[0-9]{4,}$"#, options: .regularExpression) != nil {
            return explicit
        }

        let path = url.path
        guard let regex = try? NSRegularExpression(pattern: #"\.h([0-9]{4,})\.Hotel-Information"#, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)),
              let range = Range(match.range(at: 1), in: path) else { return nil }
        return String(path[range])
    }

    private static func isSameProperty(_ candidateURL: URL, as expectedURL: URL, provider: Provider) -> Bool {
        guard provider == .expedia else { return provider.isProviderContentURL(candidateURL) }
        guard let expectedID = propertyID(from: expectedURL, provider: provider) else { return false }
        return propertyID(from: candidateURL, provider: provider) == expectedID
    }

    private static func isSameProperty(_ candidateURLString: String, as expectedURL: URL, provider: Provider) -> Bool {
        guard let candidateURL = URL(string: candidateURLString) else { return false }
        return isSameProperty(candidateURL, as: expectedURL, provider: provider)
    }

    private static func providerPhotoPredicate(_ provider: Provider) -> String {
        switch provider {
        case .booking:
            return "host.endsWith('bstatic.com') && path.includes('/xdata/images/hotel/')"
        case .expedia:
            // Expedia property photos encode the exact lodging property ID in the path.
            return "host.includes('trvl-media.com') && path.includes('/lodging/')"
        }
    }

    private static func initializeMediaCaptureScript(provider: Provider, sourceURL: String) -> String {
        let predicate = providerPhotoPredicate(provider)
        let escapedSource = sourceURL
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        return """
        (() => {
          const provider = '\(provider.rawValue)';
          const sourceURL = '\(escapedSource)';
          const propertyIDFromURL = raw => {
            try {
              const u = new URL(String(raw || ''), location.href);
              const explicit = u.searchParams.get('expediaPropertyId') || u.searchParams.get('propertyId');
              if (explicit && /^[0-9]{4,}$/.test(explicit)) return explicit;
              const match = u.pathname.match(/\\.h([0-9]{4,})\\.Hotel-Information/i);
              return match ? match[1] : null;
            } catch (_) { return null; }
          };
          const expectedPropertyID = provider === 'Expedia'
            ? (propertyIDFromURL(location.href) || propertyIDFromURL(sourceURL))
            : null;

          // A new import owns a fresh media store. Never carry media across an Expedia SPA
          // navigation or a reused importer slot.
          window.__iumrahHotelMedia = {};
          window.__iumrahProviderName = provider;
          window.__iumrahExpectedPropertyID = expectedPropertyID;
          window.__iumrahMediaAnchor = `${provider}|${expectedPropertyID || location.pathname}`;
          window.__iumrahIsHotelPhoto = raw => {
            try {
              const u = new URL(String(raw || ''), location.href);
              const host = u.hostname.toLowerCase();
              const path = u.pathname.toLowerCase();
              const baseAllowed = \(predicate);
              if (!baseAllowed) return false;
              if (provider === 'Expedia') {
                if (!expectedPropertyID) return false;
                return path.includes(`/${expectedPropertyID}/`);
              }
              return true;
            } catch (_) { return false; }
          };
          return { expectedPropertyID, anchor: window.__iumrahMediaAnchor };
        })();
        """
    }

    private static func captureVisibleMediaScript(provider: Provider, sourceURL: String) -> String {
        let predicate = providerPhotoPredicate(provider)
        let escapedSource = sourceURL
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        return """
        (() => {
          const provider = '\(provider.rawValue)';
          const sourceURL = '\(escapedSource)';
          window.__iumrahHotelMedia = window.__iumrahHotelMedia || {};
          const clean = s => String(s || '').replace(/\\s+/g, ' ').trim();
          const propertyIDFromURL = raw => {
            try {
              const u = new URL(String(raw || ''), location.href);
              const explicit = u.searchParams.get('expediaPropertyId') || u.searchParams.get('propertyId');
              if (explicit && /^[0-9]{4,}$/.test(explicit)) return explicit;
              const match = u.pathname.match(/\\.h([0-9]{4,})\\.Hotel-Information/i);
              return match ? match[1] : null;
            } catch (_) { return null; }
          };
          const expectedPropertyID = window.__iumrahExpectedPropertyID
            || (provider === 'Expedia' ? (propertyIDFromURL(location.href) || propertyIDFromURL(sourceURL)) : null);
          const isAllowed = raw => {
            try {
              const u = new URL(String(raw || ''), location.href);
              const host = u.hostname.toLowerCase();
              const path = u.pathname.toLowerCase();
              const baseAllowed = \(predicate);
              if (!baseAllowed) return false;
              if (provider === 'Expedia') {
                if (!expectedPropertyID) return false;
                // Hard property boundary. Expedia photos from another hotel have another
                // lodging property ID segment and are rejected even if they are on this page.
                return path.includes(`/${expectedPropertyID}/`);
              }
              return true;
            } catch (_) { return false; }
          };
          const normalize = raw => {
            try {
              const u = new URL(String(raw || ''), location.href);
              u.hash = '';
              return u.toString().replace(/&amp;/g, '&');
            } catch (_) { return null; }
          };
          const quality = raw => {
            const s = String(raw || '');
            const m = s.match(/(?:max|square|smart)(\\d+)(?:x(\\d+))?/i);
            if (m) return Number(m[1] || 0) * Number(m[2] || m[1] || 0);
            const w = s.match(/[?&](?:w|width)=(\\d+)/i);
            return w ? Number(w[1]) * Number(w[1]) : 0;
          };
          const keyFor = raw => {
            try {
              const u = new URL(raw);
              return (u.hostname + u.pathname.replace(/\\/(?:max|square|smart)[0-9x_-]+\\//ig, '/SIZE/')).toLowerCase();
            } catch (_) { return raw.toLowerCase(); }
          };
          const labelFor = img => {
            const figure = img.closest('figure');
            const labelled = img.closest('[aria-label]');
            const room = img.closest('[data-testid*="room"],[data-stid*="room"],tr[class*="room"],[class*="Room"]');
            const caption = figure?.querySelector('figcaption')?.innerText || '';
            const roomText = room ? clean(room.innerText || '').slice(0, 220) : '';
            return clean([img.alt, img.title, labelled?.getAttribute('aria-label'), caption, roomText].filter(Boolean).join(' ')).slice(0, 500);
          };
          const isBlockedContext = img => {
            let container = img;
            for (let depth = 0; container && depth < 10; depth += 1, container = container.parentElement) {
              const marker = clean(`${container.getAttribute?.('data-testid') || ''} ${container.getAttribute?.('data-stid') || ''} ${typeof container.className === 'string' ? container.className : ''}`).toLowerCase();
              if (/(recommend|similar|related|search-result|property-card|other-property|nearby-property|cross-sell|upsell|sponsored|advert)/i.test(marker)) return true;
              if (/^(SECTION|ARTICLE|LI)$/.test(container.tagName || '')) {
                const heading = clean(container.querySelector?.('h1,h2,h3,h4,[role="heading"]')?.innerText || '').toLowerCase();
                if (/(similar properties|you may also like|other properties|recommended|more places to stay|popular properties nearby|sponsored)/i.test(heading)) return true;
              }
            }
            const link = img.closest('a[href*="/hotel/"],a[href*="Hotel-Information"],a[href*="hotel-information"]');
            if (link) {
              try {
                const target = new URL(link.href, location.href);
                if (provider === 'Expedia' && expectedPropertyID) {
                  const linkedPropertyID = propertyIDFromURL(target.href);
                  if (linkedPropertyID && linkedPropertyID !== expectedPropertyID) return true;
                } else if (target.pathname !== location.pathname && !location.pathname.includes(target.pathname) && !target.pathname.includes(location.pathname)) {
                  return true;
                }
              } catch (_) {}
            }
            return false;
          };
          const add = (raw, label) => {
            if (!raw || !isAllowed(raw)) return;
            const url = normalize(raw);
            if (!url) return;
            const key = keyFor(url);
            const q = quality(url);
            const previous = window.__iumrahHotelMedia[key];
            if (!previous || q >= Number(previous.quality || 0)) {
              window.__iumrahHotelMedia[key] = { url, label: clean(label).slice(0, 500) || null, quality: q };
            }
          };

          for (const img of document.querySelectorAll('img')) {
            if (isBlockedContext(img)) continue;
            const label = labelFor(img);
            [img.currentSrc, img.src, img.dataset?.src, img.dataset?.lazySrc, img.getAttribute('data-original')].forEach(v => add(v, label));
            const srcset = img.srcset || img.getAttribute('data-srcset') || '';
            for (const part of srcset.split(',')) add(part.trim().split(/\\s+/)[0], label);
          }

          const og = document.querySelector('meta[property="og:image"]')?.content;
          add(og, 'Hotel cover');
          return Object.keys(window.__iumrahHotelMedia).length;
        })();
        """
    }

    private static func openGalleryScript() -> String {
        """
        (() => {
          const clean = value => String(value || '').replace(/\\s+/g, ' ').trim();
          const text = el => clean(`${el.innerText || ''} ${el.getAttribute?.('aria-label') || ''}`).toLowerCase();
          const headings = [...document.querySelectorAll('h1,h2,h3,[role="heading"]')];
          const roomHeading = headings.find(el => /room options|available rooms|choose your room|rooms and rates|room types/i.test(clean(el.innerText || el.textContent || '')));
          const roomTop = roomHeading ? roomHeading.getBoundingClientRect().top + window.scrollY : Number.POSITIVE_INFINITY;

          const blocked = el => {
            const t = text(el);
            if (/view all photos for|more details for|view prices for/i.test(t)) return true;
            let node = el;
            for (let depth = 0; node && depth < 9; depth += 1, node = node.parentElement) {
              const marker = clean(`${node.getAttribute?.('data-testid') || ''} ${node.getAttribute?.('data-stid') || ''} ${typeof node.className === 'string' ? node.className : ''}`).toLowerCase();
              if (/(recommend|similar|related|property-card|other-property|cross-sell|upsell|room-card)/i.test(marker)) return true;
              const heading = clean(node.querySelector?.('h1,h2,h3,h4,[role="heading"]')?.innerText || '').toLowerCase();
              if (/(you may also like|similar properties|recommended|more places to stay)/i.test(heading)) return true;
            }
            return false;
          };

          const candidates = [...document.querySelectorAll('button,a,[role="button"]')]
            .filter(el => {
              if (blocked(el)) return false;
              const marker = `${el.getAttribute('data-testid') || ''} ${el.getAttribute('data-stid') || ''}`.toLowerCase();
              const t = text(el);
              const photoSignal = marker.includes('gallery') || marker.includes('photo') || /all photos|show all photos|see all photos|photo gallery|^\\d+\\+$/.test(t);
              if (!photoSignal) return false;
              const top = el.getBoundingClientRect().top + window.scrollY;
              return top < roomTop;
            })
            .sort((a, b) => (a.getBoundingClientRect().top + window.scrollY) - (b.getBoundingClientRect().top + window.scrollY));

          const target = candidates.find(el => el.offsetParent !== null) || candidates[0];
          if (!target) return false;
          try { target.scrollIntoView({ block: 'center' }); target.click(); return true; } catch (_) { return false; }
        })();
        """
    }

    private static func closeGalleryScript() -> String {
        """
        (() => {
          const dialogs = [...document.querySelectorAll('[role="dialog"]')];
          const root = dialogs[dialogs.length - 1] || document;
          const buttons = [...root.querySelectorAll('button,[role="button"]')];
          const target = buttons.find(el => {
            const text = String(el.getAttribute('aria-label') || el.innerText || '').toLowerCase();
            const marker = String(el.getAttribute('data-stid') || el.getAttribute('data-testid') || '').toLowerCase();
            return /close|dismiss|закрыть/.test(text) || marker.includes('close');
          });
          if (!target) { document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' })); return false; }
          target.click();
          return true;
        })();
        """
    }

    private static func scrollGalleryScript(fraction: Double) -> String {
        """
        (() => {
          const candidates = [...document.querySelectorAll('[role="dialog"], [role="dialog"] *, [data-testid*="gallery"], [data-stid*="gallery"], body, html')]
            .filter(el => el && el.scrollHeight > el.clientHeight + 250 && el.querySelectorAll && el.querySelectorAll('img').length >= 2)
            .sort((a,b) => b.scrollHeight - a.scrollHeight);
          const target = candidates[0] || document.scrollingElement || document.documentElement;
          const max = Math.max(0, target.scrollHeight - target.clientHeight);
          if (target === document.body || target === document.documentElement || target === document.scrollingElement) {
            window.scrollTo(0, max * \(fraction));
          } else {
            target.scrollTop = max * \(fraction);
          }
          return { images: target.querySelectorAll ? target.querySelectorAll('img').length : 0, max };
        })();
        """
    }

    private static func extractionScript(provider: Provider, sourceURL: String) -> String {
        let escapedURL = sourceURL
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let predicate = providerPhotoPredicate(provider)

        return """
        (() => {
          const provider = '\(provider.rawValue)';
          const sourceURL = '\(escapedURL)';
          const clean = s => String(s || '').replace(/\\s+/g, ' ').trim();
          const lower = s => clean(s).toLowerCase();
          const structuredNoise = value => {
            const t = clean(value);
            if (!t) return true;
            if (/(?:\\\\\"|__typename|agencyBusinessModels|availability_group|bedroomFilter|bed_type_group|startDate|trip-Type|ShoppingProductContent|EGDSPlainText)/i.test(t)) return true;
            if (/[{[]/.test(t) && /["':]/.test(t)) return true;
            if ((t.match(/\\\"/g) || []).length >= 2) return true;
            if (/(?:See all about this property.*Explore the area|Free WiFiFree cribs|breakfast for a feeRestaurant|Children and extra bedsChildren)/i.test(t)) return true;
            return false;
          };
          const safeText = (value, max = 1200) => {
            const t = clean(value);
            if (!t || structuredNoise(t)) return null;
            return t.slice(0, max);
          };
          const uniq = arr => {
            const seen = new Set();
            const out = [];
            for (const value of arr || []) {
              const v = clean(value);
              if (!v) continue;
              const key = v.toLowerCase();
              if (!seen.has(key)) { seen.add(key); out.push(v); }
            }
            return out;
          };
          const numberFrom = value => {
            if (value == null) return null;
            const n = Number(String(value).replace(/,/g, '.').replace(/[^0-9.]/g, ''));
            return Number.isFinite(n) ? n : null;
          };
          const integerFrom = value => {
            if (value == null) return null;
            const digits = String(value).replace(/[^0-9]/g, '');
            const n = Number(digits);
            return Number.isFinite(n) && digits ? Math.trunc(n) : null;
          };
          const meta = (name, prop) => document.querySelector(`meta[${prop}="${name}"]`)?.content || null;

          // Provider pages expose useful property data in JSON-LD and embedded app state.
          // Walk it with strict budgets so recommendation/search trees cannot dominate extraction.
          const allJSON = [];
          const seenJSON = new WeakSet();
          let jsonBudget = 28000;
          const walkJSON = (value, depth = 0) => {
            if (!value || jsonBudget <= 0 || depth > 18) return;
            if (Array.isArray(value)) {
              for (const child of value.slice(0, 600)) walkJSON(child, depth + 1);
              return;
            }
            if (typeof value !== 'object' || seenJSON.has(value)) return;
            seenJSON.add(value);
            jsonBudget -= 1;
            allJSON.push(value);
            for (const child of Object.values(value).slice(0, 500)) if (child && typeof child === 'object') walkJSON(child, depth + 1);
          };
          const parseJSONScript = node => {
            const text = node?.textContent || '';
            if (!text || text.length > 6000000) return;
            try { walkJSON(JSON.parse(text)); } catch (_) {}
          };
          document.querySelectorAll('script[type="application/ld+json"]').forEach(parseJSONScript);
          document.querySelectorAll('script#__NEXT_DATA__,script[type="application/json"],script[id*="state" i],script[id*="apollo" i],script[id*="app" i]').forEach(parseJSONScript);
          for (const key of ['__NEXT_DATA__','__INITIAL_STATE__','__APOLLO_STATE__','__STATE__']) {
            try { walkJSON(window[key]); } catch (_) {}
          }
          try { walkJSON(window.__iumrahJSONResponses || []); } catch (_) {}
          const typeText = value => Array.isArray(value) ? value.join(' ') : String(value || '');
          const visibleH1 = clean(
            provider === 'Booking'
              ? (document.querySelector('[data-testid="title"]')?.innerText || document.querySelector('h1')?.innerText || '')
              : (document.querySelector('h1')?.innerText || '')
          );
          const canonicalHint = document.querySelector('link[rel=\"canonical\"]')?.href || location.href || sourceURL;
          const identifierValue = candidate => {
            if (candidate == null) return null;
            if (typeof candidate === 'string' || typeof candidate === 'number') return clean(candidate) || null;
            if (typeof candidate === 'object') return clean(candidate.value || candidate.id || candidate.name || candidate['@id'] || '') || null;
            return null;
          };
          const propertyIDFromURL = raw => {
            try {
              const u = new URL(String(raw || ''), location.href);
              const explicit = u.searchParams.get('expediaPropertyId') || u.searchParams.get('propertyId');
              if (explicit && /^[0-9]{4,}$/.test(explicit)) return explicit;
              const match = u.pathname.match(/\\.h([0-9]{4,})\\.Hotel-Information/i);
              return match ? match[1] : null;
            } catch (_) { return null; }
          };
          const expectedPropertyID = provider === 'Expedia'
            ? (propertyIDFromURL(location.href) || propertyIDFromURL(canonicalHint) || propertyIDFromURL(sourceURL))
            : null;
          const candidatePropertyID = candidate => {
            if (!candidate || typeof candidate !== 'object') return null;
            const direct = identifierValue(candidate.expediaPropertyId)
              || identifierValue(candidate.propertyId)
              || identifierValue(candidate.propertyID)
              || identifierValue(candidate.hotelId)
              || identifierValue(candidate.hotelID)
              || identifierValue(candidate.lodgingId)
              || identifierValue(candidate.lodgingID)
              || identifierValue(candidate.identifier);
            if (direct && /^[0-9]{4,}$/.test(direct)) return direct;
            const rawURL = clean(candidate.url || candidate.canonicalUrl || candidate.canonicalURL || candidate.webUrl || candidate.href || '');
            return propertyIDFromURL(rawURL);
          };
          const sameIdentityName = (a, b) => {
            const normalize = value => lower(value).replace(/[^a-z0-9\\u0400-\\u04ff\\u0600-\\u06ff]+/g, ' ').replace(/\\s+/g, ' ').trim();
            const aa = normalize(a);
            const bb = normalize(b);
            if (!aa || !bb) return false;
            if (aa === bb) return true;
            const short = aa.length < bb.length ? aa : bb;
            const long = aa.length < bb.length ? bb : aa;
            return short.length >= 12 && long.includes(short);
          };
          const hotelScore = candidate => {
            if (!candidate || typeof candidate !== 'object') return -9999;
            const type = typeText(candidate['@type'] || candidate.__typename || candidate.type);
            const candidateName = clean(candidate.name || candidate.propertyName || candidate.title || '');
            const candidateID = candidatePropertyID(candidate);
            const rawURL = clean(candidate.url || candidate.canonicalUrl || candidate.canonicalURL || candidate.webUrl || '');
            const rawURLID = propertyIDFromURL(rawURL);

            // Expedia pages contain full recommendation/search trees for other hotels. Any
            // explicit property identity that disagrees with the exact .h<id> URL is rejected.
            if (expectedPropertyID && candidateID && candidateID !== expectedPropertyID) return -9999;
            if (expectedPropertyID && rawURLID && rawURLID !== expectedPropertyID) return -9999;

            const hasAddress = !!(candidate.address || candidate.location?.address);
            const hasGeo = !!(candidate.geo || candidate.coordinates || candidate.latitude || candidate.longitude);
            const hasHotelType = /hotel|lodgingbusiness|resort|accommodation|property/i.test(type);
            let score = hasHotelType ? 12 : 0;
            if (candidateID && expectedPropertyID && candidateID === expectedPropertyID) score += 140;
            if (rawURLID && expectedPropertyID && rawURLID === expectedPropertyID) score += 100;
            if (candidateName) score += 2;
            if (visibleH1 && candidateName && sameIdentityName(visibleH1, candidateName)) score += 45;
            if (hasAddress) score += 5;
            if (hasGeo) score += 4;
            if (candidate.aggregateRating || candidate.reviewsSummary) score += 3;
            if (rawURL && canonicalHint && (rawURL.includes(location.pathname) || canonicalHint.includes(rawURL))) score += 8;
            if (/recommend|similar|searchresult|crosssell|upsell/i.test(type)) score -= 80;
            return score;
          };
          const bestHotel = allJSON.reduce((best, item) => hotelScore(item) > hotelScore(best) ? item : best, {}) || {};
          const bestHotelID = candidatePropertyID(bestHotel);
          const bestHotelName = clean(bestHotel.name || bestHotel.propertyName || bestHotel.title || '');
          const identitySafe = !expectedPropertyID
            || bestHotelID === expectedPropertyID
            || (!bestHotelID && sameIdentityName(bestHotelName, visibleH1));
          const hotel = identitySafe ? bestHotel : {};

          const canonicalURL = (() => {
            const choices = [
              document.querySelector('link[rel=\"canonical\"]')?.href,
              location.href,
              hotel.url,
              hotel.canonicalUrl,
              hotel.canonicalURL,
              sourceURL
            ].filter(Boolean);
            for (const raw of choices) {
              try {
                const absolute = new URL(String(raw), location.href).toString();
                if (!expectedPropertyID || propertyIDFromURL(absolute) === expectedPropertyID) return absolute;
              } catch (_) {}
            }
            return sourceURL;
          })();
          const providerHotelID = (() => {
            if (expectedPropertyID) return expectedPropertyID;
            const direct = identifierValue(hotel.propertyId)
              || identifierValue(hotel.propertyID)
              || identifierValue(hotel.hotelId)
              || identifierValue(hotel.hotelID)
              || identifierValue(hotel.identifier);
            if (direct && direct.length >= 3 && direct.length <= 140) return direct;
            const raw = `${canonicalURL} ${sourceURL}`;
            const patterns = [/(?:hotelid|hotel_id|propertyid|property_id)[=/:.-]+([0-9A-Za-z_-]{4,})/i, /\\.h([0-9]{4,})\\./i, /\\/hotel\\/[^/]+\\/([^/?#]+?)(?:\\.html)?(?:[?#]|$)/i];
            for (const pattern of patterns) { const match = raw.match(pattern); if (match) return clean(match[1]); }
            return null;
          })();

          // Visible property identity wins. Embedded app-state is used only to enrich the
          // same URL-anchored hotel, never to rename the requested property.
          const titleCandidates = provider === 'Booking'
            ? [
                document.querySelector('[data-testid="title"]')?.innerText,
                hotel.name,
                meta('og:title','property'),
                visibleH1,
                document.title
              ]
            : [
                visibleH1,
                document.querySelector('[data-testid="title"]')?.innerText,
                meta('og:title','property'),
                hotel.name,
                document.title
              ];
          let name = titleCandidates.map(clean).find(Boolean) || null;
          if (name) name = name.replace(/\\s*[|–—-]\\s*(booking\\.com|expedia).*$/i, '').trim();

          let address = null;
          let city = null;
          let country = null;
          let postalCode = null;
          const structuredAddress = hotel.address || hotel.location?.address || null;
          if (typeof structuredAddress === 'string') {
            address = clean(structuredAddress);
          } else if (structuredAddress && typeof structuredAddress === 'object') {
            const a = structuredAddress;
            city = clean(a.addressLocality || a.city || a.addressRegion || '') || null;
            country = clean(typeof a.addressCountry === 'object' ? (a.addressCountry.name || a.addressCountry['@id']) : (a.addressCountry || a.country)) || null;
            postalCode = clean(a.postalCode || a.zip || a.zipCode || '') || null;
            address = clean([a.streetAddress || a.addressLine, a.addressLocality || a.city, a.addressRegion, postalCode, typeof a.addressCountry === 'object' ? a.addressCountry.name : (a.addressCountry || a.country)].filter(Boolean).join(', ')) || null;
          }
          const brand = (() => {
            const value = hotel.brand || hotel.hotelBrand || hotel.propertyBrand;
            return clean(typeof value === 'object' ? (value.name || value.value || value['@id']) : value) || null;
          })();
          const chain = (() => {
            const value = hotel.parentOrganization || hotel.chain || hotel.hotelChain || hotel.brand;
            return clean(typeof value === 'object' ? (value.name || value.value || value['@id']) : value) || null;
          })();
          if (!address) {
            address = clean(
              document.querySelector('[data-testid="address"]')?.innerText ||
              document.querySelector('[data-stid*="address"]')?.innerText ||
              document.querySelector('[data-testid*="location"]')?.innerText || ''
            ) || null;
          }
          const addressLower = lower(address || '');
          if (!city) {
            if (/makkah|mecca/.test(addressLower)) city = 'Makkah';
            else if (/madinah|medina/.test(addressLower)) city = 'Madinah';
          }
          if (!country && /saudi arabia|saudi/.test(addressLower)) country = 'Saudi Arabia';
          if (!postalCode && address) {
            const postalMatch = address.match(/(?:^|[^0-9])([0-9]{5})(?:[^0-9]|$)/);
            if (postalMatch) postalCode = postalMatch[1];
          }

          const description = clean(
            hotel.description ||
            meta('description','name') ||
            meta('og:description','property') ||
            document.querySelector('[data-testid*="description"]')?.innerText ||
            document.querySelector('[data-stid*="description"]')?.innerText || ''
          ) || null;

          const propertyTypeRaw = typeText(hotel['@type']);
          const propertyType = /resort/i.test(propertyTypeRaw) ? 'Resort' : /hotel/i.test(propertyTypeRaw) ? 'Hotel' : clean(propertyTypeRaw) || 'Hotel';

          let rating = numberFrom(hotel.aggregateRating?.ratingValue);
          let ratingScale = numberFrom(hotel.aggregateRating?.bestRating);
          let reviewCount = integerFrom(hotel.aggregateRating?.reviewCount ?? hotel.aggregateRating?.ratingCount);

          const fullBodyText = clean(document.body?.innerText || '');
          if (rating == null) {
            const m10 = fullBodyText.match(/(?:scored|rated|rating|оценка)\\s*([0-9](?:[.,][0-9])?)\\s*(?:\\/\\s*10)?/i) || fullBodyText.match(/([0-9](?:[.,][0-9])?)\\s*\\/\\s*10/i);
            const m5 = fullBodyText.match(/([0-5](?:[.,][0-9])?)\\s*\\/\\s*5/i);
            if (m10) { rating = Number(m10[1].replace(',', '.')); ratingScale = 10; }
            else if (m5) { rating = Number(m5[1].replace(',', '.')); ratingScale = 5; }
          }
          if (ratingScale == null && rating != null) ratingScale = rating > 5 ? 10 : 5;
          if (reviewCount == null) {
            const m = fullBodyText.match(/([0-9][0-9,.\\s]*)\\s+(?:reviews|review|отзыв|отзывов|bewertungen|avis)\\b/i);
            reviewCount = m ? integerFrom(m[1]) : null;
          }

          let stars = integerFrom(hotel.starRating?.ratingValue);
          if (stars == null) {
            const propertyClass = fullBodyText.match(/property\\s+class\\s*:?\\s*([1-5])(?:\\.0)?\\b/i);
            if (propertyClass) stars = Number(propertyClass[1]);
          }
          if (stars == null) {
            const starEl = [...document.querySelectorAll('[aria-label]')].find(el => /[1-5](?:\\.0)?\\s*(?:out of 5|star|stars)/i.test(el.getAttribute('aria-label') || ''));
            const m = (starEl?.getAttribute('aria-label') || fullBodyText).match(/(?:^|[^0-9.])([1-5])(?:\\.0)?\\s*(?:out of 5|star|stars|звезд|звезды|звезда)\\b/i);
            stars = m ? Number(m[1]) : null;
          }

          // Do not let guest-review prose leak into facilities, policies, fees or room/property facts.
          const propertyRoot = document.body?.cloneNode(true);
          if (propertyRoot?.querySelectorAll) {
            // Detached clones otherwise expose embedded React/GraphQL JSON through textContent.
            for (const node of propertyRoot.querySelectorAll('script,style,noscript,template,svg,canvas,[hidden],[aria-hidden="true"]')) node.remove();
            for (const node of propertyRoot.querySelectorAll('[data-stid*="review" i],[data-testid*="review" i],[id*="review" i],nav,footer')) node.remove();
            for (const node of propertyRoot.querySelectorAll('[data-stid*="recommend" i],[data-testid*="recommend" i],[data-stid*="similar" i],[data-testid*="similar" i],[data-stid*="search-result" i],[data-testid*="search-result" i]')) node.remove();
            for (const section of propertyRoot.querySelectorAll('section,article')) {
              const heading = clean(section.querySelector('h1,h2,h3,h4,[role="heading"]')?.innerText || '');
              if (/^(guest )?reviews?|verified reviews?|opiniones|bewertungen|avis$/i.test(heading)) { section.remove(); continue; }
              if (/(similar properties|you may also like|other properties|recommended|more places to stay|popular properties nearby|related properties)/i.test(heading)) section.remove();
            }
          }
          const bodyText = clean(propertyRoot?.innerText || propertyRoot?.textContent || document.body?.innerText || '');

          let latitude = numberFrom(hotel.geo?.latitude ?? hotel.latitude ?? hotel.location?.latitude ?? hotel.coordinates?.latitude);
          let longitude = numberFrom(hotel.geo?.longitude ?? hotel.longitude ?? hotel.location?.longitude ?? hotel.coordinates?.longitude);
          if (latitude == null || longitude == null) {
            const geoMeta = document.querySelector('meta[property=\\"place:location:latitude\\"]')?.content;
            const lngMeta = document.querySelector('meta[property=\\"place:location:longitude\\"]')?.content;
            latitude = latitude ?? numberFrom(geoMeta);
            longitude = longitude ?? numberFrom(lngMeta);
          }
          if (latitude == null || longitude == null) {
            try {
              const params = new URL(sourceURL).searchParams;
              const latLong = clean(params.get('latLong') || params.get('latlong') || '');
              const pair = latLong.match(/(-?[0-9]{1,2}(?:\\.[0-9]+)?)[,\\s]+(-?[0-9]{1,3}(?:\\.[0-9]+)?)/);
              if (pair) {
                latitude = latitude ?? numberFrom(pair[1]);
                longitude = longitude ?? numberFrom(pair[2]);
              }
            } catch (_) {}
          }
          const googleMapsURL = (() => {
            const explicit = [...document.querySelectorAll('a[href]')].map(a => a.href).find(h => /google\\.[^/]+\\/maps|maps\\.google/i.test(h || ''));
            if (explicit) return explicit;
            const query = latitude != null && longitude != null ? `${latitude},${longitude}` : (address || name || '');
            return query ? `https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(query)}` : null;
          })();
          let checkIn = clean(hotel.checkinTime || hotel.checkInTime || '') || null;
          let checkOut = clean(hotel.checkoutTime || hotel.checkOutTime || '') || null;
          if (!checkIn) {
            const m = bodyText.match(/check[ -]?in\\s*(?:(?:start|from)\\s+time|start|from|time)?\\s*:?\\s*([0-9]{1,2}:[0-9]{2}(?:\\s*[ap]m)?|[0-9]{1,2}(?:\\s*[ap]m))/i);
            if (m) checkIn = clean(m[1]);
          }
          if (!checkOut) {
            const m = bodyText.match(/check[ -]?out\\s*(?:before|until|time)?\\s*:?\\s*([0-9]{1,2}:[0-9]{2}(?:\\s*[ap]m)?|[0-9]{1,2}(?:\\s*[ap]m))/i);
            if (m) checkOut = clean(m[1]);
          }

          const amenities = [];
          const canonicalAmenity = value => {
            const t = safeText(value, 100);
            if (!t) return null;
            const l = lower(t);
            const pairs = [
              [/free wi[- ]?fi|complimentary wi[- ]?fi/, 'Free WiFi'],
              [/wi[- ]?fi|wireless internet/, 'Wi‑Fi'],
              [/24[- ]hour front desk|24 hour front desk/, '24-hour front desk'],
              [/restaurants?/, 'Restaurant'],
              [/coffee shop|café|cafe/, 'Coffee shop'],
              [/fitness cent(?:er|re)|\\bgym\\b/, 'Fitness center'],
              [/swimming pool|outdoor pool|indoor pool/, 'Swimming pool'],
              [/airport shuttle|shuttle service/, 'Airport shuttle'],
              [/valet parking/, 'Valet parking'],
              [/luggage storage|baggage storage/, 'Luggage storage'],
              [/business cent(?:er|re)/, 'Business center'],
              [/facilities for disabled guests|wheelchair accessible/, 'Accessibility']
            ];
            for (const [pattern, label] of pairs) if (pattern.test(l)) return label;
            return t;
          };
          const addAmenity = value => {
            const t = canonicalAmenity(value);
            if (!t || t.length < 2 || t.length > 100) return;
            if (/reviews?|guest review|room type|availability|price|select|reserve|booking|expedia/i.test(t)) return;
            const key = t.toLowerCase();
            if (key === 'wi‑fi' && amenities.some(x => x.toLowerCase() === 'free wifi')) return;
            if (key === 'free wifi') {
              for (let i = amenities.length - 1; i >= 0; i -= 1) if (amenities[i].toLowerCase() === 'wi‑fi') amenities.splice(i, 1);
            }
            if (!amenities.some(x => x.toLowerCase() === key)) amenities.push(t);
          };
          const featureValues = hotel.amenityFeature;
          const featureWalk = value => {
            if (!value) return;
            if (Array.isArray(value)) { value.forEach(featureWalk); return; }
            if (typeof value === 'object') { if (value.name) addAmenity(value.name); return; }
            addAmenity(value);
          };
          featureWalk(featureValues);
          const amenitySelectors = [
            '[data-testid*="facilit"] li','[data-testid*="amenit"] li','[data-testid*="popular-facilit"] *',
            '[data-stid*="amenit"] li','[data-stid*="amenit"] span','[class*="facility"] li','[class*="Facility"] li'
          ];
          for (const selector of amenitySelectors) {
            for (const el of (propertyRoot?.querySelectorAll(selector) || [])) {
              const t = clean(el.innerText || el.textContent || '');
              if (t.length <= 100) addAmenity(t);
            }
          }
          const commonAmenityMap = [
            ['Free WiFi', ['free wifi','free wi-fi']], ['Wi‑Fi', ['wifi','wi-fi']], ['Breakfast', ['breakfast']],
            ['Restaurant', ['restaurant','restaurants']], ['Bar and lounge', ['bar and lounge','bar/lounge','lounge bar']],
            ['Coffee shop', ['coffee shop','cafe','café']], ['Room service', ['room service']], ['Family rooms', ['family rooms']],
            ['Non-smoking rooms', ['non-smoking rooms']], ['24-hour front desk', ['24-hour front desk','24 hour front desk']],
            ['Concierge', ['concierge']], ['Luggage storage', ['luggage storage','baggage storage']], ['Tour desk', ['tour desk']],
            ['Parking', ['parking']], ['Valet parking', ['valet parking']], ['Airport shuttle', ['airport shuttle','shuttle service']],
            ['Fitness center', ['fitness center','fitness centre','gym']], ['Swimming pool', ['swimming pool','outdoor pool','indoor pool']],
            ['Spa', ['spa and wellness','spa']], ['Laundry', ['laundry']], ['Dry cleaning', ['dry cleaning']], ['Housekeeping', ['housekeeping']],
            ['Garden', ['garden']], ['Terrace', ['terrace']], ['Elevator', ['elevator','lift']], ['Business center', ['business center','business centre']],
            ['Meeting rooms', ['meeting rooms','meeting room']], ['Facilities for disabled guests', ['facilities for disabled guests','wheelchair accessible']],
            ['Air conditioning', ['air conditioning']], ['Security', ['24-hour security','security']], ['ATM', ['atm','cash machine']]
          ];
          const lowerBody = bodyText.toLowerCase();
          for (const [label, keys] of commonAmenityMap) if (keys.some(k => lowerBody.includes(k))) addAmenity(label);

          const roomCandidates = [];
          const roomSeen = new Set();
          const scalarFrom = (object, paths) => {
            for (const path of paths) {
              let value = object;
              for (const part of path.split('.')) value = value && typeof value === 'object' ? value[part] : null;
              if (value != null && (typeof value === 'string' || typeof value === 'number')) {
                const text = safeText(value, 300);
                if (text) return text;
              }
            }
            return null;
          };
          const collectNamedValues = (value, keyPattern, depth = 0, out = []) => {
            if (!value || depth > 5 || out.length >= 24) return out;
            if (Array.isArray(value)) {
              for (const child of value.slice(0, 30)) collectNamedValues(child, keyPattern, depth + 1, out);
              return out;
            }
            if (typeof value !== 'object') return out;
            for (const [key, child] of Object.entries(value).slice(0, 80)) {
              if (keyPattern.test(key)) {
                if (typeof child === 'string' || typeof child === 'number') {
                  const text = safeText(child, 180);
                  if (text) out.push(text);
                } else if (child && typeof child === 'object') {
                  const text = safeText(child.name || child.label || child.value || child.description, 180);
                  if (text) out.push(text);
                }
              }
              if (child && typeof child === 'object') collectNamedValues(child, keyPattern, depth + 1, out);
            }
            return out;
          };
          const roomKeyword = /(room|suite|king|queen|twin|triple|quad|family|deluxe|superior|classic|standard|executive|studio|premier|номер|люкс|غرفة|جناح)/i;
          const blockedRoom = /(how much|parking|breakfast|restaurant|front desk|concierge|room service|meeting room|prayer room|laundry room|locker room|non-smoking rooms|family rooms|guest rooms|choose your room|select room|room amenities|frequently asked|question|answer|policy|check[ -]?in|check[ -]?out)/i;
          const addRoom = (rawName, container, structured = null) => {
            const roomName = safeText(rawName, 180);
            if (!roomName || roomName.length < 4 || roomName.length > 180 || roomName.endsWith('?') || roomName.endsWith('؟') || roomName.split(/\\s+/).length > 24 || !roomKeyword.test(roomName) || blockedRoom.test(roomName)) return;
            const key = roomName.toLowerCase();
            if (roomSeen.has(key)) return;
            roomSeen.add(key);

            const rawContext = clean(container?.innerText || container?.textContent || '').slice(0, 2500);
            const context = structuredNoise(rawContext) ? '' : rawContext;
            const roomContext = clean(`${roomName} ${context}`);
            const bedMatch = roomContext.match(/(?:[0-9]+\\s*)?(?:king|queen|twin|double|single)\\s*(?:bed|beds)|[0-9]+\\s*(?:twin|double|single)\\s*beds?/i);
            const guestMatch = context.match(/(?:sleeps?|guests?|adults?)\\s*[:]?\\s*([0-9]+)/i);
            const metricSize = context.match(/([0-9]{1,4}(?:[.,][0-9]+)?)\\s*(?:m²|m2|sq\\.?\\s*m|square metres?)/i);
            const feetSize = context.match(/([0-9]{2,5})\\s*(?:ft²|sq\\.?\\s*ft|square feet)/i);
            const structuredGuests = structured ? integerFrom(
              scalarFrom(structured, ['maxGuests','maxOccupancy','occupancy.max','occupancy.maxGuests','sleeps','capacity','maxPersons'])
            ) : null;
            const structuredSize = structured ? numberFrom(
              scalarFrom(structured, ['sizeM2','area.squareMeters','area.value','roomSize.value','size.value'])
            ) : null;
            const structuredBeds = structured ? uniq(collectNamedValues(structured, /bed|bedding/i)).slice(0, 4).join(' · ') : '';
            let sizeM2 = structuredSize ?? (metricSize ? Number(metricSize[1].replace(',', '.')) : null);
            if (sizeM2 == null && feetSize) sizeM2 = Math.round(Number(feetSize[1]) * 0.092903 * 10) / 10;
            const viewMatch = roomContext.match(/(?:partial\\s+)?(?:landmark|city|kaaba|kabba|haram|mountain|courtyard|sea|garden)\\s+view|view\\s+of\\s+[^,.|]{2,80}/i);

            const roomAmenities = [];
            const roomAmenityMap = [
              ['Private bathroom','private bathroom'], ['Air conditioning','air conditioning'], ['Flat-screen TV','flat-screen tv'],
              ['Minibar','minibar'], ['Free WiFi','free wifi'], ['Tea/Coffee maker','tea/coffee maker'], ['Soundproofing','soundproof'],
              ['Bathtub','bathtub'], ['Shower','shower'], ['Safe','safe'], ['Desk','desk'], ['Seating area','seating area']
            ];
            const lc = context.toLowerCase();
            for (const [label, token] of roomAmenityMap) if (lc.includes(token)) roomAmenities.push(label);

            const smoking = /non[- ]smoking|smoke[- ]free/i.test(context) ? 'Non-smoking' : /smoking (?:is )?allowed|smoking room/i.test(context) ? 'Smoking allowed' : null;
            const roomAccessibility = uniq([
              /wheelchair accessible/i.test(context) ? 'Wheelchair accessible' : '',
              /accessible bathroom|roll-in shower/i.test(context) ? 'Accessible bathroom' : '',
              /grab bars?/i.test(context) ? 'Grab bars' : ''
            ]);
            const bathroom = uniq([
              /private bathroom/i.test(context) ? 'Private bathroom' : '',
              /bathtub|bath tub/i.test(context) ? 'Bathtub' : '',
              /shower/i.test(context) ? 'Shower' : '',
              /bidet/i.test(context) ? 'Bidet' : '',
              /toiletries|free toiletries/i.test(context) ? 'Toiletries' : '',
              /hair ?dryer/i.test(context) ? 'Hair dryer' : ''
            ]);
            const categoryMatch = roomName.match(/(standard|superior|deluxe|executive|premier|classic|family|studio|suite|junior suite|presidential|royal)/i);
            roomCandidates.push({
              id: crypto.randomUUID(),
              name: roomName,
              maxGuests: structuredGuests ?? (guestMatch ? Number(guestMatch[1]) : null),
              sizeM2: Number.isFinite(sizeM2) ? sizeM2 : null,
              beds: structuredBeds || (bedMatch ? clean(bedMatch[0]) : null),
              view: viewMatch ? clean(viewMatch[0]) : null,
              description: context && context !== roomName ? context.slice(0, 1200) : null,
              amenities: uniq(roomAmenities),
              smoking,
              accessibility: roomAccessibility,
              category: categoryMatch ? clean(categoryMatch[1]) : null,
              bathroom
            });
          };

          const roomSelectors = provider === 'Booking' ? [
            '[data-testid="room-name"]','[data-testid*="room-name"]','a.hprt-roomtype-link','.hprt-roomtype-icon-link',
            '#hprt-table h3','#hprt-table h4','#hprt-table [role="heading"]','table h3','table h4'
          ] : [
            '[data-stid*="room"] h2','[data-stid*="room"] h3','[data-stid*="room"] h4',
            '[data-testid*="room"] h2','[data-testid*="room"] h3','[data-testid*="room"] h4',
            '[aria-label*="room"] h3','[data-stid*="room"] [role="heading"]','[data-testid*="room"] [role="heading"]'
          ];
          for (const selector of roomSelectors) {
            for (const el of document.querySelectorAll(selector)) {
              const container = el.closest('tr,[data-testid*="room"],[data-stid*="room"],article,section,li') || el.parentElement;
              addRoom(el.innerText || el.textContent, container);
            }
          }

          // Expedia exposes stable, human-readable room names in action labels even
          // when the visual room card hierarchy changes. Examples include
          // "View all photos for Classic Twin Room, 2 Twin Beds" and
          // "More details for Junior Suite Kaaba View".
          for (const el of document.querySelectorAll('button,a,[role="button"],[aria-label]')) {
            const actionText = clean([el.getAttribute?.('aria-label'), el.innerText, el.textContent].filter(Boolean).join(' '));
            const matches = [
              actionText.match(/view all photos for\\s+(.+?)(?:$|\\s+image:)/i),
              actionText.match(/more details(?:\\s+more details)? for\\s+(.+)$/i),
              actionText.match(/view prices(?:\\s+for)?\\s+(.+)$/i)
            ].filter(Boolean);
            for (const match of matches) {
              const container = el.closest('[data-stid*="room"],[data-testid*="room"],article,section,li,div') || el.parentElement;
              addRoom(match[1], container);
            }
          }

          // DOM-independent fallback. A room-name line must be followed nearby by
          // concrete sellable-room evidence (beds, occupancy, size, price/details).
          const roomLines = String(propertyRoot?.innerText || document.body?.innerText || '').split(/\\n+/).map(clean).filter(Boolean);
          for (let i = 0; i < roomLines.length; i += 1) {
            let candidate = roomLines[i];
            let strongRoomAction = false;
            const photoPrefix = candidate.match(/^view all photos for\\s+(.+)$/i);
            if (photoPrefix) { candidate = photoPrefix[1]; strongRoomAction = true; }
            const detailPrefix = candidate.match(/^more details(?:\\s+more details)? for\\s+(.+)$/i);
            if (detailPrefix) { candidate = detailPrefix[1]; strongRoomAction = true; }
            if (!roomKeyword.test(candidate) || blockedRoom.test(candidate)) continue;
            const contextLines = roomLines.slice(i + 1, Math.min(roomLines.length, i + 14));
            const contextText = contextLines.join(' · ');
            const evidence = /\\b(?:sleeps?|guests?)\\s*\\d+|\\b\\d+\\s*(?:king|queen|twin|double|single)\\s*beds?|\\d+\\s*(?:sq\\.?\\s*ft|ft²|m²)|more details|view prices|free wi[- ]?fi/i.test(contextText);
            if (!strongRoomAction && !evidence) continue;
            const synthetic = { innerText: [candidate, ...contextLines].join('\\n'), textContent: [candidate, ...contextLines].join('\\n') };
            addRoom(candidate, synthetic);
          }

          // Provider markup changes frequently. Room cards are still recognizable by
          // property-specific "Room options" sections and occupancy/bed/size context.
          for (const section of document.querySelectorAll('section,article')) {
            const heading = clean(section.querySelector('h1,h2,[role="heading"]')?.innerText || '');
            if (!/(room options|available rooms|choose your room|select a room|rooms and rates|room types|номера)/i.test(heading)) continue;
            for (const el of section.querySelectorAll('h2,h3,h4,[role="heading"]')) {
              const text = clean(el.innerText || el.textContent || '');
              if (text === heading) continue;
              let container = el.parentElement;
              let context = '';
              for (let depth = 0; container && depth < 9; depth += 1, container = container.parentElement) {
                const candidateContext = clean(container.innerText || container.textContent || '');
                if (candidateContext.length > 2800) continue;
                if (/(sleeps?|guests?|beds?|sq\\.?\\s*ft|ft²|m²|view prices|more details|free wi[- ]?fi)/i.test(candidateContext)) {
                  context = candidateContext;
                  break;
                }
              }
              if (!context) continue;
              addRoom(text, container || el.parentElement);
            }
          }

          // Embedded app-state contains recommendation trees too. For Expedia, structured
          // room objects are accepted only when the object itself carries the exact property
          // ID from the requested .h<id> URL. Unscoped JSON is never allowed to invent rooms.
          for (const item of allJSON) {
            if (!item || typeof item !== 'object' || Array.isArray(item)) continue;
            if (provider === 'Expedia') {
              if (!expectedPropertyID) continue;
              const itemPropertyID = candidatePropertyID(item);
              if (itemPropertyID !== expectedPropertyID) continue;
            }
            const type = lower(typeText(item['@type'] || item.__typename || item.type || item.contentType || ''));
            const keys = Object.keys(item).join(' ').toLowerCase();
            const roomSignal = /room|suite|unit|accommodation/.test(type) ||
              /(roomtypename|roomtype|room_name|roomname|unitname|bedgroup|bedding|occupancy|maxoccupancy|sleeps|roomsize)/.test(keys);
            if (!roomSignal) continue;
            const candidateName = safeText(
              item.roomTypeName || item.roomName || item.unitName || item.displayName || item.name || item.title || item.heading,
              180
            );
            if (candidateName) addRoom(candidateName, null, item);
          }

          const offerWalk = value => {
            if (!value) return;
            if (Array.isArray(value)) { value.forEach(offerWalk); return; }
            if (typeof value !== 'object') return;
            const offered = value.itemOffered;
            if (offered?.name) addRoom(offered.name, null);
            if (/room|suite/i.test(typeText(value['@type'])) && value.name) addRoom(value.name, null);
            Object.values(value).forEach(child => { if (child && typeof child === 'object') offerWalk(child); });
          };
          offerWalk(hotel.makesOffer);
          offerWalk(hotel.offers);
          offerWalk(hotel.containsPlace);

          const roomNames = roomCandidates.map(r => r.name);

          // Price is extracted by the same verified browser session that produced the
          // hotel identity, rooms and media. We intentionally prefer the first normal
          // sellable room rate (Double/Twin/Standard when identifiable) and keep the
          // provider's explicit total separately when it is present.
          const priceQuery = new URL(location.href).searchParams;
          const quoteCheckIn = provider === 'Booking' ? priceQuery.get('checkin') : priceQuery.get('chkin');
          const quoteCheckOut = provider === 'Booking' ? priceQuery.get('checkout') : priceQuery.get('chkout');
          const quoteNights = (() => {
            if (!quoteCheckIn || !quoteCheckOut) return 1;
            const a = Date.parse(`${quoteCheckIn}T00:00:00Z`);
            const b = Date.parse(`${quoteCheckOut}T00:00:00Z`);
            const value = Math.round((b - a) / 86400000);
            return Number.isFinite(value) && value > 0 && value <= 30 ? value : 1;
          })();
          const normalizeMoneyCurrency = value => {
            const token = clean(value).toUpperCase().replace(/\\s+/g, '');
            if (token === 'SAR' || token === 'SR' || token.includes('ر.س')) return 'SAR';
            if (token === 'AED' || token.includes('د.إ')) return 'AED';
            if (token === 'USD' || token === 'US$' || token === '$') return 'USD';
            return null;
          };
          const parseMoneyAmount = value => {
            let text = clean(value).replace(/[\\u00a0\\u202f\\s]/g, '').replace(/[^0-9.,]/g, '');
            if (!text) return null;
            const comma = text.lastIndexOf(',');
            const dot = text.lastIndexOf('.');
            if (comma >= 0 && dot >= 0) {
              if (dot > comma) text = text.replace(/,/g, '');
              else text = text.replace(/\\./g, '').replace(',', '.');
            } else if (comma >= 0) {
              const after = text.length - comma - 1;
              text = (after === 1 || after === 2) ? text.replace(',', '.') : text.replace(/,/g, '');
            } else if (dot >= 0) {
              const after = text.length - dot - 1;
              if (after !== 1 && after !== 2) text = text.replace(/\\./g, '');
            }
            const amount = Number(text);
            return Number.isFinite(amount) && amount > 0 ? amount : null;
          };
          const moneyValues = value => {
            const text = clean(value);
            const values = [];
            const before = /(?:US\\$|USD|\\$|SAR|SR|ر\\.?س\\.?|AED|د\\.?إ\\.?)\\s*([0-9][0-9.,\\s]*)/gi;
            const after = /([0-9][0-9.,\\s]*)\\s*(US\\$|USD|\\$|SAR|SR|ر\\.?س\\.?|AED|د\\.?إ\\.?)/gi;
            let match;
            while ((match = before.exec(text)) !== null && values.length < 12) {
              const token = match[0].slice(0, match[0].indexOf(match[1]));
              const amount = parseMoneyAmount(match[1]);
              const currency = normalizeMoneyCurrency(token);
              if (amount && currency) values.push({ amount, currency, index: match.index });
            }
            while ((match = after.exec(text)) !== null && values.length < 12) {
              const amount = parseMoneyAmount(match[1]);
              const currency = normalizeMoneyCurrency(match[2]);
              if (amount && currency) values.push({ amount, currency, index: match.index });
            }
            values.sort((a, b) => a.index - b.index);
            const uniqueMoney = [];
            const seenMoney = new Set();
            for (const item of values) {
              const key = `${item.currency}:${item.amount}:${item.index}`;
              if (!seenMoney.has(key)) { seenMoney.add(key); uniqueMoney.push(item); }
            }
            return uniqueMoney;
          };
          const priceCandidates = [];
          const preferredRoomPattern = /(double|twin|standard|classic)/i;
          const excludedPriceAncestor = el => {
            for (let node = el; node && node !== document.body; node = node.parentElement) {
              const marker = `${node.getAttribute?.('data-stid') || ''} ${node.getAttribute?.('data-testid') || ''} ${node.id || ''} ${node.className || ''}`;
              const heading = clean(node.querySelector?.('h1,h2,h3,[role="heading"]')?.innerText || '');
              if (/(recommend|similar|related|other-property|cross-sell|upsell|search-result)/i.test(marker)) return true;
              if (/(similar properties|you may also like|other properties|recommended|more places to stay)/i.test(heading)) return true;
            }
            return false;
          };
          const roomNameForPrice = el => {
            let node = el;
            for (let depth = 0; node && depth < 8; depth += 1, node = node.parentElement) {
              const marker = `${node.getAttribute?.('data-stid') || ''} ${node.getAttribute?.('data-testid') || ''} ${node.className || ''}`;
              if (!/(room|rate|offer|unit|availability|hprt)/i.test(marker) && depth < 2) continue;
              const heading = clean(node.querySelector?.('h2,h3,h4,[role="heading"],[data-testid*="room-name"]')?.innerText || '');
              if (heading && roomKeyword.test(heading) && !blockedRoom.test(heading)) return heading.slice(0, 180);
              const text = clean(node.innerText || node.textContent || '');
              const known = roomNames.find(name => text.toLowerCase().includes(name.toLowerCase()));
              if (known) return known;
            }
            return null;
          };
          const addPriceElement = (el, baseScore, method) => {
            if (!el || excludedPriceAncestor(el)) return;
            const rect = el.getBoundingClientRect?.();
            const style = window.getComputedStyle?.(el);
            if (style && (style.display === 'none' || style.visibility === 'hidden')) return;
            if (rect && rect.width === 0 && rect.height === 0) return;
            let node = el;
            let context = clean(el.innerText || el.textContent || '');
            for (let depth = 0; node && depth < 5 && context.length < 80; depth += 1, node = node.parentElement) {
              const candidate = clean(node.innerText || node.textContent || '');
              if (candidate.length > context.length && candidate.length <= 700) context = candidate;
            }
            if (!context || context.length > 900 || !/(SAR|SR|ر\\.?س\\.?|AED|د\\.?إ\\.?|USD|US\\$|\\$)/i.test(context)) return;
            if (/(deposit|parking|breakfast fee|airport shuttle|taxi|damage deposit)/i.test(context) && !/(room|suite|night|total|reserve|select)/i.test(context)) return;
            const money = moneyValues(context).filter(item => item.amount >= 15 && item.amount <= 100000);
            if (!money.length) return;
            const totalIndex = context.toLowerCase().indexOf('total');
            let baseValues = money;
            let total = null;
            if (totalIndex >= 0) {
              const afterTotal = money.filter(item => item.index >= totalIndex);
              if (afterTotal.length) total = afterTotal[afterTotal.length - 1];
              const beforeTotal = money.filter(item => item.index < totalIndex);
              if (beforeTotal.length) baseValues = beforeTotal;
            }
            const sameCurrency = baseValues.filter(item => item.currency === baseValues[0].currency);
            const base = (sameCurrency.length ? sameCurrency : baseValues).reduce((best, item) => item.amount < best.amount ? item : best);
            const roomName = roomNameForPrice(el);
            let score = baseScore;
            if (roomName) score += 18;
            if (roomName && preferredRoomPattern.test(roomName)) score += 35;
            if (/per\\s+night|\\/\\s*night|nightly/i.test(context)) score += 20;
            if (/taxes? and fees included|includes taxes? & fees/i.test(context)) score += 3;
            if (/member price|sign in|reward/i.test(context)) score -= 4;
            const basis = (/per\\s+night|\\/\\s*night|nightly/i.test(context) || quoteNights === 1) ? 'nightly' : (/total/i.test(context) ? 'stay_total' : 'nightly');
            priceCandidates.push({
              amount: base.amount,
              currency: base.currency,
              totalAmount: total?.amount || null,
              totalCurrency: total?.currency || null,
              priceBasis: basis,
              checkIn: quoteCheckIn || null,
              checkOut: quoteCheckOut || null,
              nights: quoteNights,
              adults: 2,
              rooms: 1,
              roomName,
              method,
              confidence: Math.max(0.5, Math.min(0.995, score / 100)),
              score,
              domIndex: [...document.querySelectorAll('*')].indexOf(el)
            });
          };
          const priceSelectors = provider === 'Booking' ? [
            '[data-testid="price-and-discounted-price"]','[data-testid="price-for-x-nights"]','[data-testid*="price"]',
            '.prco-valign-middle-helper','.bui-price-display__value','#hprt-table .prco-valign-middle-helper'
          ] : [
            '[data-stid*="price-lockup"]','[data-stid*="price"]','[data-testid*="price"]',
            '[class*="uitk-lockup-price"]','[class*="price-lockup"]'
          ];
          for (const selector of priceSelectors) {
            for (const el of document.querySelectorAll(selector)) addPriceElement(el, 72, `${provider.toLowerCase()}-dom-price`);
          }
          if (!priceCandidates.length) {
            for (const el of document.querySelectorAll('span,div,p,strong')) {
              const text = clean(el.innerText || el.textContent || '');
              if (text.length < 3 || text.length > 120) continue;
              if (!/(SAR|SR|ر\\.?س\\.?|AED|د\\.?إ\\.?|USD|US\\$|\\$)/i.test(text)) continue;
              addPriceElement(el, 52, `${provider.toLowerCase()}-visible-money`);
              if (priceCandidates.length >= 80) break;
            }
          }
          priceCandidates.sort((a, b) => {
            if (b.score !== a.score) return b.score - a.score;
            if (a.domIndex !== b.domIndex) return a.domIndex - b.domIndex;
            return a.amount - b.amount;
          });
          const price = priceCandidates.length ? (() => {
            const bestScore = priceCandidates[0].score;
            const best = priceCandidates.filter(item => item.score >= bestScore - 3);
            const preferred = best.filter(item => preferredRoomPattern.test(item.roomName || ''));
            const pool = preferred.length ? preferred : best;
            pool.sort((a, b) => a.domIndex - b.domIndex || a.amount - b.amount);
            const chosen = pool[0];
            const { score, domIndex, ...publicPrice } = chosen;
            return publicPrice;
          })() : null;

          const policies = [];
          const addPolicy = value => {
            const t = safeText(value, 450);
            if (t && t.length >= 4 && t.length <= 450 && !/(see all|learn more|property cla$)/i.test(t)) policies.push(t);
          };
          if (checkIn) addPolicy(`Check-in: ${checkIn}`);
          if (checkOut) addPolicy(`Check-out: ${checkOut}`);
          const policyPatterns = [
            /pets?[^.]{0,180}(?:allowed|not allowed|request)[^.]{0,80}/ig,
            /children[^.]{0,220}/ig,
            /no age restriction[^.]{0,140}/ig,
            /smoking[^.]{0,160}/ig,
            /accepted payment methods?[^.]{0,180}/ig
          ];
          for (const pattern of policyPatterns) {
            const matches = bodyText.match(pattern) || [];
            matches.slice(0, 3).forEach(addPolicy);
          }

          const rawLines = String(propertyRoot?.innerText || propertyRoot?.textContent || '').split(/\\n+/).map(clean).filter(Boolean);
          const nearby = [];
          const nearbySeen = new Set();
          const addNearby = (rawName, rawDistance, rawDuration, rawMode) => {
            let placeName = safeText(rawName, 140);
            if (!placeName || placeName.length < 2 || placeName.length > 140) return;
            const repeatedPlace = placeName.match(/^(.+?)\\s+Place,\\s+(.+)$/i);
            if (repeatedPlace && lower(repeatedPlace[1]) === lower(repeatedPlace[2])) placeName = clean(repeatedPlace[1]);
            if (/reviews?|check availability|see all|show all|sign in|price|room|breakfast|parking$/i.test(placeName)) return;
            const distanceText = clean(rawDistance) || null;
            const durationMinutes = rawDuration == null ? null : Number(rawDuration);
            const travelMode = clean(rawMode) || null;
            let distanceMeters = null;
            if (distanceText) {
              const m = distanceText.match(/([0-9]+(?:[.,][0-9]+)?)\\s*(km|m|mi|mile|miles)\\b/i);
              if (m) {
                const amount = Number(m[1].replace(',', '.'));
                const unit = m[2].toLowerCase();
                distanceMeters = unit === 'km' ? amount * 1000 : (unit === 'mi' || unit.startsWith('mile')) ? amount * 1609.344 : amount;
              }
            }
            const key = `${placeName.toLowerCase()}|${distanceText || ''}|${durationMinutes || ''}`;
            if (nearbySeen.has(key)) return;
            nearbySeen.add(key);
            nearby.push({ id: crypto.randomUUID(), name: placeName, distanceText, distanceMeters, durationMinutes: Number.isFinite(durationMinutes) ? Math.round(durationMinutes) : null, travelMode });
          };
          const parseNearbyElement = el => {
            const text = clean(el?.innerText || el?.textContent || '');
            if (!text || text.length > 320 || !/(?:[0-9]{1,3}\\s*(?:min|mins|minute|minutes)|[0-9]+(?:[.,][0-9]+)?\\s*(?:km|m|mi|mile|miles))\\b/i.test(text)) return;
            const duration = text.match(/([0-9]{1,3})\\s*(?:min|mins|minute|minutes)\\s*(walk|walking|drive|driving|by car)?/i);
            const distance = text.match(/([0-9]+(?:[.,][0-9]+)?)\\s*(km|m|mi|mile|miles)\\b/i);
            const candidate = clean(text.replace(duration?.[0] || '', '').replace(distance?.[0] || '', '').replace(/^[-–—·•\\s]+|[-–—·•\\s]+$/g, ''));
            addNearby(candidate, distance ? distance[0] : null, duration ? duration[1] : null, duration ? (duration[2] || 'walk') : null);
          };
          const nearbySelectors = [
            '[data-stid*="location"] li','[data-testid*="location"] li','[data-stid*="poi"]','[data-testid*="poi"]',
            '[data-stid*="neighborhood"] li','[data-testid*="neighborhood"] li','[data-stid*="area"] li','[data-testid*="area"] li'
          ];
          for (const selector of nearbySelectors) for (const el of document.querySelectorAll(selector)) parseNearbyElement(el);
          for (const section of document.querySelectorAll('section')) {
            const heading = clean(section.querySelector('h1,h2,h3,h4,[role="heading"]')?.innerText || '');
            if (!/(explore the area|what(?:’|')?s nearby|nearby|location|around this property|neighborhood|getting around|местоположение|рядом)/i.test(heading)) continue;
            [...section.querySelectorAll('li,[role="listitem"],p')].slice(0, 80).forEach(parseNearbyElement);
          }
          const sacredOrTransport = /(kaaba|kabaa|kabba|great mosque of makkah|masjid al[- ]haram|clock towers?|abraj al bait|masjid an[- ]nabawi|prophet(?:’|')?s mosque|airport|railway station|train station|haramain)/i;
          for (const line of rawLines) if (sacredOrTransport.test(line)) parseNearbyElement({ innerText: line });

          const facts = [];
          const factSeen = new Set();
          const addFact = (group, label, value) => {
            const g = safeText(group, 120) || 'Property';
            const l = safeText(label, 160);
            const v = safeText(value, 900);
            if (!l || !v || l.length > 160 || v.length > 900) return;
            if (/guest reviews?|reviews from|see all reviews|verified reviews|write a review|see all about this property|explore the area|view in a map/i.test(`${g} ${l} ${v}`)) return;
            const key = `${g}|${l}|${v}`.toLowerCase();
            if (factSeen.has(key)) return;
            factSeen.add(key);
            facts.push({ id: crypto.randomUUID(), group: g, label: l, value: v });
          };

          const sectionKeywords = /(about|property|amenit|facilit|service|parking|breakfast|food|drink|restaurant|bar|accessib|important|policy|policies|house rules|location|area|transport|internet|family|business|cleaning|reception|front desk|wellness|safety|security)/i;
          for (const section of (propertyRoot?.querySelectorAll('section, [data-stid], [data-testid]') || [])) {
            const heading = clean(section.querySelector('h1,h2,h3,h4,[role="heading"]')?.innerText || '');
            if (!heading || !sectionKeywords.test(heading) || /review/i.test(heading)) continue;
            const rows = [...section.querySelectorAll('li,[role="listitem"],dt,dd,p')].slice(0, 80);
            for (const row of rows) {
              const text = safeText(row.innerText || row.textContent || '', 320);
              if (!text || text.length < 2 || text.length > 320 || /review/i.test(text)) continue;
              const parts = text.split(/\\s{2,}|:\\s+/).map(clean).filter(Boolean);
              if (parts.length >= 2) addFact(heading, parts[0], parts.slice(1).join(' · '));
              else addFact(heading, text, 'Yes');
            }
          }

          const propertyStatements = [
            /breakfast[^.\\n]{0,100}(?:fee|available|included|buffet|continental|daily)/ig,
            /(?:free )?parking[^.\\n]{0,120}/ig,
            /[0-9]+ restaurants?[^.\\n]{0,100}/ig,
            /airport shuttle[^.\\n]{0,100}/ig,
            /free wi[- ]?fi[^.\\n]{0,80}/ig
          ];
          for (const pattern of propertyStatements) {
            for (const match of (bodyText.match(pattern) || []).slice(0, 8)) {
              const text = safeText(match, 180);
              if (!text) continue;
              if (/breakfast|restaurant/i.test(text)) addFact('Food & drink', text, 'Yes');
              else if (/parking|shuttle/i.test(text)) addFact('Parking & transport', text, 'Yes');
              else addFact('Property highlights', text, 'Yes');
            }
          }

          const factText = fact => clean(`${fact.group}: ${fact.label}${fact.value && fact.value !== 'Yes' ? ` · ${fact.value}` : ''}`);
          const highlights = uniq(facts.filter(f => /(about|highlight|popular|top amenit|property)/i.test(f.group)).map(factText)).slice(0, 60);
          const importantInformation = uniq(facts.filter(f => /(important|policy|policies|house rules|deposit|fee|check-in|check-out)/i.test(`${f.group} ${f.label}`)).map(factText)).slice(0, 100);
          const food = facts.filter(f => /(breakfast|restaurant|food|drink|bar|lounge|cafe|café|dining|buffet)/i.test(`${f.group} ${f.label} ${f.value}`)).slice(0, 100);
          const parkingTransport = facts.filter(f => /(parking|valet|shuttle|transfer|airport|transport|taxi|car hire|car rental|train|station)/i.test(`${f.group} ${f.label} ${f.value}`)).slice(0, 100);
          const accessibility = uniq(facts.filter(f => /(accessib|wheelchair|disabled|lift|elevator|grab bar|roll-in)/i.test(`${f.group} ${f.label} ${f.value}`)).map(factText)).slice(0, 100);

          const fees = [];
          const feeSeen = new Set();
          const addFee = text => {
            const v = safeText(text, 500);
            if (!v || v.length < 4 || v.length > 500 || !/(fee|charge|cost|sar|usd|per day|per night|deposit|parking)/i.test(v)) return;
            if (/room price|price per|total price|taxes and fees included|availability/i.test(v)) return;
            const key = v.toLowerCase();
            if (feeSeen.has(key)) return;
            feeSeen.add(key);
            fees.push({ id: crypto.randomUUID(), group: 'Fees', label: 'Fee', value: v });
          };
          rawLines.forEach(addFee);

          const services = [];
          const serviceTokens = [
            ['24-hour front desk', /24[- ]hour front desk/i], ['Concierge', /concierge/i], ['Luggage storage', /luggage|baggage storage/i],
            ['Room service', /room service/i], ['Laundry', /laundry/i], ['Dry cleaning', /dry cleaning/i], ['Housekeeping', /housekeeping/i],
            ['Airport shuttle', /airport shuttle|shuttle service/i], ['Valet parking', /valet parking/i], ['Business center', /business cent(?:er|re)/i],
            ['Meeting rooms', /meeting rooms?/i], ['Tour desk', /tour desk/i], ['Currency exchange', /currency exchange/i], ['ATM', /\\batm\\b|cash machine/i]
          ];
          for (const [label, pattern] of serviceTokens) if (pattern.test(bodyText)) services.push(label);

          const classify = label => {
            const t = lower(label);
            if (/bathroom|bath|shower|toilet|vanity|حمام/.test(t)) return 'bathroom';
            if (/bedroom|bed | beds|room interior|guest room|suite|king room|twin room|номер|люкс|غرفة|جناح/.test(t)) return 'room';
            if (/lobby|reception|front desk|foyer|лобби|استقبال/.test(t)) return 'lobby';
            if (/breakfast|buffet|morning meal/.test(t)) return 'breakfast';
            if (/gym|fitness|workout/.test(t)) return 'gym';
            if (/spa|sauna|steam room|massage|wellness/.test(t)) return 'spa';
            if (/pool|swimming|бассейн|مسبح/.test(t)) return 'pool';
            if (/lounge|bar lounge|club lounge/.test(t)) return 'lounge';
            if (/restaurant|dining|food|cafe|coffee|ресторан|مطعم/.test(t)) return 'restaurant';
            if (/meeting|ballroom|terrace|parking|business center|garden|playground/.test(t)) return 'facility';
            if (/kaaba|kabba|haram|landmark view|city view|view from|вид на|إطلالة/.test(t)) return 'view';
            if (/exterior|facade|façade|entrance|building|front of hotel|hotel exterior|фасад|واجهة/.test(t)) return 'exterior';
            return 'gallery';
          };
          const roomHintFor = label => {
            const l = lower(label);
            let best = null;
            let bestScore = 0;
            for (const room of roomNames) {
              const tokens = lower(room).split(' ').filter(t => t.length > 3);
              const score = tokens.filter(t => l.includes(t)).length;
              if (score > bestScore && score >= Math.min(2, tokens.length || 2)) { best = room; bestScore = score; }
            }
            return best;
          };

          const captured = Object.values(window.__iumrahHotelMedia || {});
          const imageMetadata = [];
          const imageSeen = new Set();
          const isAllowed = raw => {
            try {
              const u = new URL(String(raw || ''), location.href);
              const host = u.hostname.toLowerCase();
              const path = u.pathname.toLowerCase();
              const baseAllowed = \(predicate);
              if (!baseAllowed) return false;
              if (provider === 'Expedia') {
                if (!expectedPropertyID) return false;
                return path.includes(`/${expectedPropertyID}/`);
              }
              return true;
            } catch (_) { return false; }
          };
          for (const item of captured) {
            if (!item?.url || !isAllowed(item.url)) continue;
            let key;
            try {
              const u = new URL(item.url);
              key = (u.hostname + u.pathname.replace(/\\/(?:max|square|smart)[0-9x_-]+\\//ig, '/SIZE/')).toLowerCase();
            } catch (_) { key = String(item.url).toLowerCase(); }
            if (imageSeen.has(key)) continue;
            imageSeen.add(key);
            const label = clean(item.label || '');
            const kind = classify(label);
            imageMetadata.push({ url: item.url, label: label || null, kind, roomHint: kind === 'room' ? roomHintFor(label) : null });
            if (imageMetadata.length >= 240) break;
          }

          const images = imageMetadata.map(x => x.url);

          const result = {
            id: crypto.randomUUID(),
            provider,
            sourceURL,
            name,
            city,
            country,
            address,
            description,
            propertyType,
            brand,
            chain,
            postalCode,
            stars,
            rating,
            ratingScale,
            reviewCount,
            latitude,
            longitude,
            checkIn,
            checkOut,
            images,
            imageMetadata,
            amenities: uniq(amenities).slice(0, 220),
            rooms: roomCandidates.slice(0, 140),
            roomNames: uniq(roomNames).slice(0, 140),
            policies: uniq(policies).slice(0, 220),
            providerHotelID,
            canonicalURL,
            googleMapsURL,
            nearby: nearby.slice(0, 180),
            facts: facts.slice(0, 360),
            fees: fees.slice(0, 180),
            services: uniq(services).slice(0, 240),
            highlights,
            importantInformation,
            food,
            parkingTransport,
            accessibility,
            price,
            rawIdentity: {
              provider,
              providerHotelID: providerHotelID || '',
              canonicalURL: canonicalURL || '',
              schemaType: typeText(hotel['@type'] || hotel.__typename || hotel.type),
              extractionStrategy: 'jsonld+embedded-state+scoped-dom-v3'
            }
          };
          return JSON.stringify(result);
        })();
        """
    }
}
