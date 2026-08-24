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
                return false
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
            if isShareRedirectURL(url) { return true }
            let value = url.absoluteString.lowercased()
            switch self {
            case .booking:
                return value.contains("/hotel/")
            case .expedia:
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

    let webView: WKWebView
    private var stage: Stage = .idle
    private var extractionStarted = false
    private var completionReported = false

    var onCompleted: ((HotelDraft) -> Void)?
    var onFailed: ((String) -> Void)?

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false

        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Mobile/15E148 Safari/604.1"
    }

    func start(sourceURL rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalized = Self.normalizedHotelURL(trimmed), let provider = Provider.detect(from: normalized) else {
            fail("Поддерживаются только прямые ссылки на конкретный отель в Booking или Expedia.")
            return
        }
        guard provider.isLikelyHotelDetailURL(normalized) else {
            fail("Это похоже не на карточку отеля. Откройте конкретный отель в \(provider.rawValue) и скопируйте ссылку его страницы.")
            return
        }

        stage = .loading
        extractionStarted = false
        completionReported = false
        sourceURL = normalized
        currentProvider = provider
        draft = nil
        failureMessage = nil
        requiresUserAction = false
        showSource = false
        progress = 0.05
        status = "Проверяем, не добавлен ли этот отель раньше…"

        Task {
            do {
                if let duplicate = try await APIClient.shared.checkHotelSourceDuplicate(normalized.absoluteString) {
                    fail("Этот отель уже есть в базе: \(duplicate.name). Повторный импорт отключён.")
                    return
                }
            } catch {
                // A temporary dedupe-check failure must not block reading the source.
            }

            status = provider.isShareRedirectURL(normalized)
                ? "Открываем ссылку Expedia и переходим к карточке отеля…"
                : "Открываем карточку \(provider.rawValue)…"
            progress = 0.08
            var request = URLRequest(url: normalized, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 45)
            request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
            request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
            webView.load(request)
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
        fail(error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
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
        guard provider.isProviderContentURL(currentURL) else {
            if provider.isShareRedirectURL(sourceURL ?? currentURL) {
                status = "Переходим из ссылки Expedia к карточке отеля…"
                progress = max(progress, 0.12)
            }
            return
        }
        guard provider.isLikelyHotelDetailURL(currentURL) else {
            fail("Ссылка открылась в Expedia, но не на карточке конкретного отеля. Откройте нужный отель и скопируйте его ссылку ещё раз.")
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

        _ = try? await webView.evaluateJavaScript(Self.initializeMediaCaptureScript(provider: provider))
        await captureVisibleMedia(provider: provider)

        let pageFractions: [Double] = [0.0, 0.12, 0.24, 0.38, 0.52, 0.68, 0.82, 0.94, 1.0]
        for (index, fraction) in pageFractions.enumerated() {
            let script = "window.scrollTo(0, Math.max(0, (document.documentElement.scrollHeight - window.innerHeight) * \(fraction)));"
            _ = try? await webView.evaluateJavaScript(script)
            try? await Task.sleep(nanoseconds: 120_000_000)
            await captureVisibleMedia(provider: provider)
            progress = 0.22 + (Double(index + 1) / Double(pageFractions.count)) * 0.20
        }

        status = "Открываем полную галерею отеля…"
        let openedGallery = ((try? await webView.evaluateJavaScript(Self.openGalleryScript())) as? Bool) == true
        if openedGallery {
            try? await Task.sleep(nanoseconds: 650_000_000)
            await captureVisibleMedia(provider: provider)
            let galleryFractions: [Double] = [0.0, 0.08, 0.16, 0.24, 0.32, 0.40, 0.48, 0.56, 0.64, 0.72, 0.80, 0.88, 0.94, 1.0]
            for (index, fraction) in galleryFractions.enumerated() {
                _ = try? await webView.evaluateJavaScript(Self.scrollGalleryScript(fraction: fraction))
                try? await Task.sleep(nanoseconds: 130_000_000)
                await captureVisibleMedia(provider: provider)
                progress = 0.42 + (Double(index + 1) / Double(galleryFractions.count)) * 0.24
            }
            _ = try? await webView.evaluateJavaScript(Self.closeGalleryScript())
            try? await Task.sleep(nanoseconds: 350_000_000)
            _ = try? await webView.evaluateJavaScript("window.scrollTo(0, document.documentElement.scrollHeight * 0.72);")
            try? await Task.sleep(nanoseconds: 220_000_000)
        }

        stage = .extracting
        progress = 0.72
        status = "Читаем номера, рейтинг, удобства и правила…"

        do {
            let source = currentURL.absoluteString
            let raw = try await webView.evaluateJavaScript(Self.extractionScript(provider: provider, sourceURL: source))
            guard let json = raw as? String, let data = json.data(using: .utf8) else {
                throw APIError.server("EMPTY_HOTEL_EXTRACT")
            }
            let snapshot = try JSONDecoder().decode(ProviderSnapshot.self, from: data)
            guard let name = snapshot.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                throw APIError.server("Не удалось прочитать название отеля с этой страницы.")
            }

            let candidate = HotelNormalizer.makeDraft(snapshot: snapshot)
            status = "Проверяем отель по всей базе iumrah…"
            progress = 0.94
            if let duplicate = try await APIClient.shared.checkHotelDuplicate(candidate) {
                fail("Этот отель уже есть в базе: \(duplicate.name). Expedia/Booking не создадут вторую карточку.")
                return
            }

            draft = candidate
            progress = 1
            stage = .finished
            status = "Готово: \(name)"
            if !completionReported {
                completionReported = true
                onCompleted?(candidate)
            }
        } catch {
            fail("Не удалось полностью разобрать карточку отеля: \(error.localizedDescription)")
        }
    }

    private func captureVisibleMedia(provider: Provider) async {
        _ = try? await webView.evaluateJavaScript(Self.captureVisibleMediaScript(provider: provider))
    }

    private func detectVerification() async -> Bool {
        do {
            let value = try await webView.evaluateJavaScript("""
            (() => {
              const t = (document.body?.innerText || '').toLowerCase();
              return [
                'captcha', 'verify you are human', 'are you a robot', 'security check',
                'unusual traffic', 'проверка безопасности', 'подтвердите, что вы человек'
              ].some(x => t.includes(x));
            })();
            """)
            return (value as? Bool) == true
        } catch {
            return false
        }
    }

    private func fail(_ message: String) {
        stage = .failed
        failureMessage = message
        status = message
        progress = 0
        extractionStarted = false
        if !completionReported {
            completionReported = true
            onFailed?(message)
        }
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

    private static func providerPhotoPredicate(_ provider: Provider) -> String {
        switch provider {
        case .booking:
            return "host.endsWith('bstatic.com') && path.includes('/xdata/images/hotel/')"
        case .expedia:
            return "(host.includes('trvl-media.com') || host.includes('expedia.com')) && (path.includes('/lodging/') || path.includes('/hotelimages/'))"
        }
    }

    private static func initializeMediaCaptureScript(provider: Provider) -> String {
        let predicate = providerPhotoPredicate(provider)
        return """
        (() => {
          window.__iumrahHotelMedia = window.__iumrahHotelMedia || {};
          window.__iumrahProviderName = '\(provider.rawValue)';
          window.__iumrahIsHotelPhoto = raw => {
            try {
              const u = new URL(String(raw || ''), location.href);
              const host = u.hostname.toLowerCase();
              const path = u.pathname.toLowerCase();
              return \(predicate);
            } catch (_) { return false; }
          };
          return true;
        })();
        """
    }

    private static func captureVisibleMediaScript(provider: Provider) -> String {
        let predicate = providerPhotoPredicate(provider)
        return """
        (() => {
          window.__iumrahHotelMedia = window.__iumrahHotelMedia || {};
          const clean = s => String(s || '').replace(/\\s+/g, ' ').trim();
          const isAllowed = raw => {
            try {
              const u = new URL(String(raw || ''), location.href);
              const host = u.hostname.toLowerCase();
              const path = u.pathname.toLowerCase();
              return \(predicate);
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
          const text = el => String(el.innerText || el.getAttribute('aria-label') || '').replace(/\\s+/g, ' ').trim().toLowerCase();
          const nodes = [...document.querySelectorAll('button,a,[role="button"]')];
          const preferred = nodes.filter(el => {
            const t = text(el);
            const marker = `${el.getAttribute('data-testid') || ''} ${el.getAttribute('data-stid') || ''}`.toLowerCase();
            return marker.includes('gallery') || marker.includes('photo') || /all photos|show all photos|view all photos|see all photos|все фото|все фотографии/.test(t);
          });
          const target = preferred.find(el => el.offsetParent !== null) || preferred[0];
          if (!target) return false;
          try { target.click(); return true; } catch (_) { return false; }
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

          const allJSON = [];
          const walkJSON = value => {
            if (!value) return;
            if (Array.isArray(value)) { value.forEach(walkJSON); return; }
            if (typeof value !== 'object') return;
            allJSON.push(value);
            for (const child of Object.values(value)) if (child && typeof child === 'object') walkJSON(child);
          };
          for (const node of document.querySelectorAll('script[type="application/ld+json"]')) {
            try { walkJSON(JSON.parse(node.textContent || 'null')); } catch (_) {}
          }
          const typeText = value => Array.isArray(value) ? value.join(' ') : String(value || '');
          const hotel = allJSON.find(x => /hotel|lodgingbusiness|resort|accommodation/i.test(typeText(x?.['@type']))) || {};
          const canonicalURL = (() => {
            try {
              const raw = document.querySelector('link[rel=\\"canonical\\"]')?.href || hotel.url || sourceURL;
              return raw ? new URL(String(raw), location.href).toString() : sourceURL;
            } catch (_) { return sourceURL; }
          })();
          const providerHotelID = (() => {
            const identifier = hotel.identifier;
            if (typeof identifier === 'string' || typeof identifier === 'number') return clean(identifier);
            if (identifier && typeof identifier === 'object') return clean(identifier.value || identifier.name || identifier['@id'] || '') || null;
            const raw = `${canonicalURL} ${sourceURL}`;
            const patterns = [/(?:hotelid|hotel_id|propertyid|property_id)[=/:.-]+([0-9A-Za-z_-]{4,})/i, /\\.h([0-9]{4,})\\./i, /\\/hotel\\/[^/]+\\/([^/?#]+?)(?:\\.html)?(?:[?#]|$)/i];
            for (const pattern of patterns) { const match = raw.match(pattern); if (match) return clean(match[1]); }
            return null;
          })();

          const titleCandidates = [
            hotel.name,
            document.querySelector('[data-testid="title"]')?.innerText,
            document.querySelector('h1')?.innerText,
            meta('og:title','property'),
            document.title
          ];
          let name = titleCandidates.map(clean).find(Boolean) || null;
          if (name) name = name.replace(/\\s*[|–—-]\\s*(booking\\.com|expedia).*$/i, '').trim();

          let address = null;
          let city = null;
          let country = null;
          if (typeof hotel.address === 'string') {
            address = clean(hotel.address);
          } else if (hotel.address && typeof hotel.address === 'object') {
            const a = hotel.address;
            city = clean(a.addressLocality || a.addressRegion || '') || null;
            country = clean(typeof a.addressCountry === 'object' ? (a.addressCountry.name || a.addressCountry['@id']) : a.addressCountry) || null;
            address = clean([a.streetAddress, a.addressLocality, a.addressRegion, typeof a.addressCountry === 'object' ? a.addressCountry.name : a.addressCountry].filter(Boolean).join(', ')) || null;
          }
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

          const bodyText = clean(document.body?.innerText || '');
          if (rating == null) {
            const m10 = bodyText.match(/(?:scored|rated|rating|оценка)\\s*([0-9](?:[.,][0-9])?)\\s*(?:\\/\\s*10)?/i) || bodyText.match(/([0-9](?:[.,][0-9])?)\\s*\\/\\s*10/i);
            const m5 = bodyText.match(/([0-5](?:[.,][0-9])?)\\s*\\/\\s*5/i);
            if (m10) { rating = Number(m10[1].replace(',', '.')); ratingScale = 10; }
            else if (m5) { rating = Number(m5[1].replace(',', '.')); ratingScale = 5; }
          }
          if (ratingScale == null && rating != null) ratingScale = rating > 5 ? 10 : 5;
          if (reviewCount == null) {
            const m = bodyText.match(/([0-9][0-9,.\\s]*)\\s+(?:reviews|review|отзыв|отзывов|bewertungen|avis)\\b/i);
            reviewCount = m ? integerFrom(m[1]) : null;
          }

          let stars = integerFrom(hotel.starRating?.ratingValue);
          if (stars == null) {
            const propertyClass = bodyText.match(/property\\s+class\\s*:?\\s*([1-5])(?:\\.0)?\\b/i);
            if (propertyClass) stars = Number(propertyClass[1]);
          }
          if (stars == null) {
            const starEl = [...document.querySelectorAll('[aria-label]')].find(el => /[1-5](?:\\.0)?\\s*(?:out of 5|star|stars)/i.test(el.getAttribute('aria-label') || ''));
            const m = (starEl?.getAttribute('aria-label') || bodyText).match(/(?:^|[^0-9.])([1-5])(?:\\.0)?\\s*(?:out of 5|star|stars|звезд|звезды|звезда)\\b/i);
            stars = m ? Number(m[1]) : null;
          }

          let latitude = numberFrom(hotel.geo?.latitude);
          let longitude = numberFrom(hotel.geo?.longitude);
          if (latitude == null || longitude == null) {
            const geoMeta = document.querySelector('meta[property=\\"place:location:latitude\\"]')?.content;
            const lngMeta = document.querySelector('meta[property=\\"place:location:longitude\\"]')?.content;
            latitude = latitude ?? numberFrom(geoMeta);
            longitude = longitude ?? numberFrom(lngMeta);
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
          const addAmenity = value => {
            const t = clean(value);
            if (!t || t.length < 2 || t.length > 100) return;
            if (/reviews?|guest review|room type|availability|price|select|reserve|booking|expedia/i.test(t)) return;
            amenities.push(t);
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
            for (const el of document.querySelectorAll(selector)) {
              const t = clean(el.innerText || el.textContent || '');
              if (t.length <= 100) addAmenity(t);
            }
          }
          const commonAmenityMap = [
            ['Free WiFi', ['free wifi','free wi-fi']], ['Wi‑Fi', ['wifi','wi-fi']], ['Breakfast', ['breakfast']],
            ['Restaurant', ['restaurant']], ['Restaurants', ['restaurants']], ['Bar and lounge', ['bar and lounge','bar/lounge','lounge bar']],
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
          const roomKeyword = /(room|suite|king|queen|twin|triple|quad|family|deluxe|superior|classic|standard|executive|studio|premier|номер|люкс|غرفة|جناح)/i;
          const blockedRoom = /(how much|parking|breakfast|restaurant|front desk|concierge|room service|meeting room|prayer room|laundry room|locker room|non-smoking rooms|family rooms|guest rooms|choose your room|select room|room amenities|frequently asked|question|answer|policy|check[ -]?in|check[ -]?out)/i;
          const addRoom = (rawName, container) => {
            const roomName = clean(rawName);
            if (!roomName || roomName.length < 4 || roomName.length > 180 || roomName.endsWith('?') || roomName.endsWith('؟') || roomName.split(/\\s+/).length > 24 || !roomKeyword.test(roomName) || blockedRoom.test(roomName)) return;
            const key = roomName.toLowerCase();
            if (roomSeen.has(key)) return;
            roomSeen.add(key);

            const context = clean(container?.innerText || container?.textContent || '').slice(0, 2500);
            const bedMatch = context.match(/(?:[0-9]+\\s*)?(?:king|queen|twin|double|single)\\s*(?:bed|beds)|[0-9]+\\s*(?:twin|double|single)\\s*beds?/i);
            const guestMatch = context.match(/(?:sleeps?|guests?|adults?)\\s*[:]?\\s*([0-9]+)/i);
            const metricSize = context.match(/([0-9]{1,4}(?:[.,][0-9]+)?)\\s*(?:m²|m2|sq\\.?\\s*m|square metres?)/i);
            const feetSize = context.match(/([0-9]{2,5})\\s*(?:ft²|sq\\.?\\s*ft|square feet)/i);
            let sizeM2 = metricSize ? Number(metricSize[1].replace(',', '.')) : null;
            if (sizeM2 == null && feetSize) sizeM2 = Math.round(Number(feetSize[1]) * 0.092903 * 10) / 10;
            const viewMatch = context.match(/(?:landmark|city|kaaba|kabba|haram|mountain|courtyard|sea|garden)\\s+view|view\\s+of\\s+[^,.|]{2,80}/i);

            const roomAmenities = [];
            const roomAmenityMap = [
              ['Private bathroom','private bathroom'], ['Air conditioning','air conditioning'], ['Flat-screen TV','flat-screen tv'],
              ['Minibar','minibar'], ['Free WiFi','free wifi'], ['Tea/Coffee maker','tea/coffee maker'], ['Soundproofing','soundproof'],
              ['Bathtub','bathtub'], ['Shower','shower'], ['Safe','safe'], ['Desk','desk'], ['Seating area','seating area']
            ];
            const lc = context.toLowerCase();
            for (const [label, token] of roomAmenityMap) if (lc.includes(token)) roomAmenities.push(label);

            roomCandidates.push({
              id: crypto.randomUUID(),
              name: roomName,
              maxGuests: guestMatch ? Number(guestMatch[1]) : null,
              sizeM2: Number.isFinite(sizeM2) ? sizeM2 : null,
              beds: bedMatch ? clean(bedMatch[0]) : null,
              view: viewMatch ? clean(viewMatch[0]) : null,
              description: context && context !== roomName ? context.slice(0, 1200) : null,
              amenities: uniq(roomAmenities)
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
          const policies = [];
          const addPolicy = value => {
            const t = clean(value);
            if (t && t.length >= 4 && t.length <= 450) policies.push(t);
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

          const rawLines = String(document.body?.innerText || '').split(/\\n+/).map(clean).filter(Boolean);
          const nearby = [];
          const nearbySeen = new Set();
          const addNearby = (rawName, rawDistance, rawDuration, rawMode) => {
            let placeName = clean(rawName);
            if (!placeName || placeName.length < 2 || placeName.length > 140) return;
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
            const key = placeName.toLowerCase();
            if (nearbySeen.has(key)) return;
            nearbySeen.add(key);
            nearby.push({ id: crypto.randomUUID(), name: placeName, distanceText, distanceMeters, durationMinutes: Number.isFinite(durationMinutes) ? Math.round(durationMinutes) : null, travelMode });
          };

          for (let i = 0; i < rawLines.length; i += 1) {
            const line = rawLines[i];
            const duration = line.match(/(?:^|\\s)([0-9]{1,3})\\s*(?:min|mins|minute|minutes)\\s*(walk|walking|drive|driving|by car)?\\b/i);
            const distance = line.match(/([0-9]+(?:[.,][0-9]+)?)\\s*(km|m|mi|mile|miles)\\b/i);
            if (duration || distance) {
              const stripped = clean(line.replace(/(?:[0-9]{1,3})\\s*(?:min|mins|minute|minutes)\\s*(?:walk|walking|drive|driving|by car)?/ig, '').replace(/[0-9]+(?:[.,][0-9]+)?\\s*(?:km|m|mi|mile|miles)\\b/ig, '').replace(/^[-–—·•\\s]+|[-–—·•\\s]+$/g, ''));
              const previous = i > 0 ? rawLines[i - 1] : '';
              const next = i + 1 < rawLines.length ? rawLines[i + 1] : '';
              const candidate = stripped.length >= 3 ? stripped : (previous.length >= 3 && previous.length <= 120 ? previous : next);
              addNearby(candidate, distance ? distance[0] : null, duration ? duration[1] : null, duration ? (duration[2] || 'walk') : null);
            }
          }

          const nearbySelectors = [
            '[data-stid*="location"] li','[data-testid*="location"] li','[data-stid*="poi"]','[data-testid*="poi"]',
            '[data-stid*="neighborhood"] li','[data-testid*="neighborhood"] li','section li'
          ];
          for (const selector of nearbySelectors) {
            for (const el of document.querySelectorAll(selector)) {
              const text = clean(el.innerText || el.textContent || '');
              if (!/(?:[0-9]{1,3}\\s*(?:min|minute)|[0-9]+(?:[.,][0-9]+)?\\s*(?:km|m|mi|mile))\\b/i.test(text)) continue;
              const duration = text.match(/([0-9]{1,3})\\s*(?:min|mins|minute|minutes)\\s*(walk|walking|drive|driving|by car)?/i);
              const distance = text.match(/([0-9]+(?:[.,][0-9]+)?)\\s*(km|m|mi|mile|miles)\\b/i);
              const candidate = clean(text.replace(duration?.[0] || '', '').replace(distance?.[0] || '', '').replace(/^[-–—·•\\s]+|[-–—·•\\s]+$/g, ''));
              addNearby(candidate, distance ? distance[0] : null, duration ? duration[1] : null, duration ? (duration[2] || 'walk') : null);
            }
          }

          const facts = [];
          const factSeen = new Set();
          const addFact = (group, label, value) => {
            const g = clean(group) || 'Property';
            const l = clean(label);
            const v = clean(value);
            if (!l || !v || l.length > 160 || v.length > 900) return;
            if (/guest reviews?|reviews from|see all reviews|verified reviews|write a review/i.test(`${g} ${l}`)) return;
            const key = `${g}|${l}|${v}`.toLowerCase();
            if (factSeen.has(key)) return;
            factSeen.add(key);
            facts.push({ id: crypto.randomUUID(), group: g, label: l, value: v });
          };

          const sectionKeywords = /(about|property|amenit|facilit|service|parking|breakfast|food|drink|restaurant|bar|accessib|important|policy|policies|house rules|location|area|transport|internet|family|business|cleaning|reception|front desk|wellness|safety|security)/i;
          for (const section of document.querySelectorAll('section, [data-stid], [data-testid]')) {
            const heading = clean(section.querySelector('h1,h2,h3,h4,[role="heading"]')?.innerText || '');
            if (!heading || !sectionKeywords.test(heading) || /review/i.test(heading)) continue;
            const rows = [...section.querySelectorAll('li,[role="listitem"],dt,dd,p')].slice(0, 80);
            for (const row of rows) {
              const text = clean(row.innerText || row.textContent || '');
              if (text.length < 2 || text.length > 320 || /review/i.test(text)) continue;
              const parts = text.split(/\\s{2,}|:\\s+/).map(clean).filter(Boolean);
              if (parts.length >= 2) addFact(heading, parts[0], parts.slice(1).join(' · '));
              else addFact(heading, text, 'Yes');
            }
          }

          const fees = [];
          const feeSeen = new Set();
          const addFee = text => {
            const v = clean(text);
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
            if (/restaurant|breakfast|dining|buffet|food|cafe|coffee|ресторан|مطعم/.test(t)) return 'restaurant';
            if (/pool|spa|gym|fitness|meeting|ballroom|terrace|parking|business center|бассейн|مسبح/.test(t)) return 'amenity';
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
              return \(predicate);
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

          if (imageMetadata.length && !imageMetadata.some(x => x.kind === 'exterior')) imageMetadata[0].kind = 'exterior';
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
            services: uniq(services).slice(0, 240)
          };
          return JSON.stringify(result);
        })();
        """
    }
}
