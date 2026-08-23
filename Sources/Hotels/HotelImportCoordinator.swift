import SwiftUI
import WebKit

@MainActor
final class HotelImportCoordinator: NSObject, ObservableObject, WKNavigationDelegate {
    enum Provider: String, CaseIterable {
        case booking = "Booking"
        case expedia = "Expedia"
        case agoda = "Agoda"

        func searchURL(query: String) -> URL? {
            let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
            switch self {
            case .booking: return URL(string: "https://www.booking.com/searchresults.html?ss=\(encoded)")
            case .expedia: return URL(string: "https://www.expedia.com/Hotel-Search?destination=\(encoded)")
            case .agoda: return URL(string: "https://www.agoda.com/search?textToSearch=\(encoded)")
            }
        }

        var detailHints: [String] {
            switch self {
            case .booking: return ["/hotel/"]
            case .expedia: return ["hotel-information", "/hotel/"]
            case .agoda: return ["/hotel/"]
            }
        }
    }

    enum Stage { case idle, searching, openingHotel, extracting, finished }

    @Published var status = "Готов к импорту"
    @Published var progress: Double = 0
    @Published var currentProvider: Provider?
    @Published var snapshots: [ProviderSnapshot] = []
    @Published var draft: HotelDraft?
    @Published var requiresUserAction = false
    @Published var showSource = false
    @Published var providerErrors: [String: String] = [:]

    let webView: WKWebView
    private var requestedName = ""
    private var searchQuery = ""
    private var city = "Makkah"
    private var providerIndex = 0
    private var stage: Stage = .idle
    private var warmedProviders = Set<Provider>()

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
    }

    func start(name: String, city: String) {
        requestedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.city = city
        searchQuery = Self.searchQuery(name: requestedName, city: city)
        providerIndex = 0
        snapshots = []
        providerErrors = [:]
        draft = nil
        warmedProviders = []
        requiresUserAction = false
        showSource = false
        progress = 0
        loadCurrentProvider()
    }

    func continueAfterVerification() {
        requiresUserAction = false
        showSource = false
        stage = .extracting
        Task { await extractCurrentPage() }
    }

    func skipCurrentProvider() {
        providerErrors[currentProvider?.rawValue ?? "Unknown"] = "Источник пропущен"
        advanceProvider()
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

    private func loadCurrentProvider() {
        guard providerIndex < Provider.allCases.count else {
            stage = .finished
            progress = 1
            draft = HotelNormalizer.makeDraft(query: requestedName, city: city, snapshots: snapshots)
            status = snapshots.isEmpty
                ? "Точный отель не подтверждён ни одним источником."
                : "Импорт завершён. Проверьте карточку перед сохранением."
            return
        }

        let provider = Provider.allCases[providerIndex]
        currentProvider = provider
        stage = .searching
        status = "\(provider.rawValue): ищем именно «\(requestedName)»…"
        progress = Double(providerIndex) / Double(Provider.allCases.count)

        guard let url = provider.searchURL(query: searchQuery) else {
            providerErrors[provider.rawValue] = "Некорректный URL поиска"
            advanceProvider()
            return
        }
        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 35))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task {
            let blocked = await detectVerification()
            if blocked {
                requiresUserAction = true
                showSource = true
                status = "\(currentProvider?.rawValue ?? "Источник") просит подтверждение. Пройдите его и нажмите «Продолжить»."
                return
            }
            switch stage {
            case .searching: await openBestHotelResult()
            case .openingHotel, .extracting: await extractCurrentPage()
            default: break
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failCurrent(error.localizedDescription) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failCurrent(error.localizedDescription) }

    private func openBestHotelResult() async {
        guard let provider = currentProvider else { return }
        if isDetailURL(webView.url, provider: provider) {
            stage = .extracting
            await extractCurrentPage()
            return
        }

        stage = .openingHotel
        let tokens = Self.identityTokens(requestedName, city: city)
        let tokenJSON = Self.jsonString(tokens)
        let hintJSON = Self.jsonString(provider.detailHints)
        let cityJSON = Self.jsonString(Self.cityTokens(city))

        let script = """
        (() => {
          const core = \(tokenJSON);
          const hints = \(hintJSON);
          const cityTokens = \(cityJSON);
          const norm = s => String(s || '').normalize('NFKD').toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
          const links = [...document.querySelectorAll('a[href]')];
          let best = null;
          let bestScore = -1;

          for (const a of links) {
            const hrefRaw = a.href || '';
            const href = hrefRaw.toLowerCase();
            if (!hints.some(h => href.includes(h))) continue;

            const text = norm((a.innerText || '') + ' ' + (a.getAttribute('aria-label') || '') + ' ' + hrefRaw);
            let matched = 0;
            for (const token of core) if (token.length > 2 && text.includes(token)) matched += 1;

            const needed = core.length <= 1 ? 1 : Math.min(2, core.length);
            if (matched < needed) continue;

            let score = matched * 25;
            if (matched === core.length) score += 45;
            if (cityTokens.some(t => text.includes(t))) score += 4;
            if ((a.innerText || '').trim().length > 3) score += 2;

            if (score > bestScore) {
              bestScore = score;
              best = hrefRaw;
            }
          }
          return best;
        })();
        """

        do {
            let value = try await webView.evaluateJavaScript(script)
            if let href = value as? String, let url = URL(string: href) {
                status = "\(provider.rawValue): нашли совпадение, открываем карточку…"
                webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 35))
            } else {
                providerErrors[provider.rawValue] = "Точный результат не найден"
                advanceProvider()
            }
        } catch { failCurrent(error.localizedDescription) }
    }

    private func extractCurrentPage() async {
        guard let provider = currentProvider, let sourceURL = webView.url?.absoluteString else {
            advanceProvider(); return
        }

        status = "\(provider.rawValue): проверяем отель и собираем медиатеку…"
        stage = .extracting

        if !warmedProviders.contains(provider) {
            await warmLazyMedia()
            warmedProviders.insert(provider)
        }

        let providerName = provider.rawValue.replacingOccurrences(of: "'", with: "")
        let script = Self.extractionScript(provider: providerName, sourceURL: sourceURL)
        do {
            let raw = try await webView.evaluateJavaScript(script)
            guard let json = raw as? String, let data = json.data(using: .utf8) else { throw APIError.server("EMPTY_EXTRACT") }
            let snapshot = try JSONDecoder().decode(ProviderSnapshot.self, from: data)

            guard Self.isLikelySameHotel(expected: requestedName, candidate: snapshot.name ?? "", city: city) else {
                let found = snapshot.name?.trimmingCharacters(in: .whitespacesAndNewlines)
                providerErrors[provider.rawValue] = found?.isEmpty == false ? "Другой отель: \(found!)" : "Название отеля не подтверждено"
                advanceProvider()
                return
            }

            snapshots.append(snapshot)
            advanceProvider()
        } catch { failCurrent(error.localizedDescription) }
    }

    private func warmLazyMedia() async {
        // Hotel galleries commonly lazy-load room photos only after scrolling. We warm the
        // page in small steps, then return to the top before extracting the DOM.
        let steps = [0.0, 0.18, 0.36, 0.54, 0.72, 0.9, 1.0]
        for fraction in steps {
            let script = "window.scrollTo(0, Math.max(0, (document.body.scrollHeight - window.innerHeight) * \(fraction)));"
            _ = try? await webView.evaluateJavaScript(script)
            try? await Task.sleep(nanoseconds: 170_000_000)
        }
        _ = try? await webView.evaluateJavaScript("window.scrollTo(0,0);")
        try? await Task.sleep(nanoseconds: 120_000_000)
    }

    private func detectVerification() async -> Bool {
        do {
            let value = try await webView.evaluateJavaScript("""
            (() => {
              const t = (document.body?.innerText || '').toLowerCase();
              return ['captcha','verify you are human','are you a robot','security check','unusual traffic','проверка безопасности'].some(x => t.includes(x));
            })();
            """)
            return (value as? Bool) == true
        } catch { return false }
    }

    private func isDetailURL(_ url: URL?, provider: Provider) -> Bool {
        guard let text = url?.absoluteString.lowercased() else { return false }
        return provider.detailHints.contains(where: { text.contains($0) })
    }

    private func failCurrent(_ message: String) {
        if let provider = currentProvider { providerErrors[provider.rawValue] = message }
        advanceProvider()
    }

    private func advanceProvider() {
        providerIndex += 1
        loadCurrentProvider()
    }

    private static func searchQuery(name: String, city: String) -> String {
        let normalizedName = normalized(name)
        let alreadyContainsCity = cityTokens(city).contains(where: { normalizedName.contains($0) })
        return alreadyContainsCity ? name : "\(name) \(city)"
    }

    private static func normalized(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cityTokens(_ city: String) -> [String] {
        let normalizedCity = normalized(city)
        if normalizedCity.contains("mad") || normalizedCity.contains("med") { return ["madinah", "medina", "al madinah"] }
        return ["makkah", "mecca", "makkah al mukarramah"]
    }

    private static func identityTokens(_ value: String, city: String) -> [String] {
        let stop = Set([
            "hotel", "hotels", "resort", "resorts", "by", "the", "and", "at", "in", "of",
            "makkah", "mecca", "madinah", "medina", "saudi", "arabia", "ksa"
        ] + cityTokens(city))
        let raw = normalized(value).split(separator: " ").map(String.init)
        let filtered = raw.filter { $0.count > 2 && !stop.contains($0) }
        var seen = Set<String>()
        return filtered.filter { seen.insert($0).inserted }
    }

    private static func isLikelySameHotel(expected: String, candidate: String, city: String) -> Bool {
        let candidateNorm = normalized(candidate)
        guard !candidateNorm.isEmpty else { return false }
        let core = identityTokens(expected, city: city)
        guard !core.isEmpty else { return normalized(expected) == candidateNorm }
        let matches = core.filter { candidateNorm.contains($0) }.count
        if core.count == 1 { return matches == 1 }
        let needed = min(2, core.count)
        return matches >= needed && Double(matches) / Double(core.count) >= 0.5
    }

    private static func jsonString(_ value: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value), let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    private static func extractionScript(provider: String, sourceURL: String) -> String {
        let escapedProvider = provider.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        let escapedURL = sourceURL.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        return """
        (() => {
          const uniq = arr => [...new Set(arr.filter(Boolean).map(v => String(v).trim()).filter(Boolean))];
          const clean = s => String(s || '').replace(/\\s+/g, ' ').trim();
          const lower = s => clean(s).toLowerCase();

          const jsonld = [];
          for (const node of document.querySelectorAll('script[type="application/ld+json"]')) {
            try {
              const parsed = JSON.parse(node.textContent || 'null');
              const walk = x => {
                if (!x) return;
                if (Array.isArray(x)) return x.forEach(walk);
                if (typeof x === 'object') { jsonld.push(x); Object.values(x).forEach(walk); }
              };
              walk(parsed);
            } catch (_) {}
          }

          const isHotel = x => {
            const type = x && x['@type'];
            const list = Array.isArray(type) ? type : [type];
            return list.some(v => /hotel|lodgingbusiness|resort/i.test(String(v || '')));
          };
          const hotel = jsonld.find(isHotel) || {};
          const meta = (name, prop) => document.querySelector(`meta[${prop}="${name}"]`)?.content || null;
          const h1 = document.querySelector('h1')?.innerText?.trim() || null;
          const name = hotel.name || h1 || meta('og:title','property') || document.title || null;
          const description = hotel.description || meta('description','name') || meta('og:description','property') || null;

          let address = null;
          if (typeof hotel.address === 'string') address = hotel.address;
          else if (hotel.address && typeof hotel.address === 'object') {
            address = [hotel.address.streetAddress, hotel.address.addressLocality, hotel.address.addressRegion, hotel.address.addressCountry].filter(Boolean).join(', ');
          }

          const rating = Number(hotel.aggregateRating?.ratingValue || 0) || null;
          const starText = (document.body?.innerText || '').match(/([1-5])\\s*(?:star|stars|звезд|звезды|звезда)/i);
          const stars = Number(hotel.starRating?.ratingValue || starText?.[1] || 0) || null;
          const latitude = Number(hotel.geo?.latitude || 0) || null;
          const longitude = Number(hotel.geo?.longitude || 0) || null;

          const body = (document.body?.innerText || '').replace(/\\s+/g,' ');
          const bodyLower = body.toLowerCase();
          const amenityMap = [
            ['Wi‑Fi',['free wifi','wi-fi','wifi']], ['Завтрак',['breakfast','завтрак']], ['Ресторан',['restaurant','ресторан']],
            ['Фитнес-зал',['fitness center','fitness centre','gym','фитнес']], ['Бассейн',['swimming pool','pool','бассейн']],
            ['Парковка',['parking','парковка']], ['Трансфер',['airport shuttle','shuttle service','трансфер']],
            ['Room service',['room service']], ['24/7 reception',['24-hour front desk','24 hour front desk','круглосуточная стойка']],
            ['Family rooms',['family rooms','семейные номера']], ['Non-smoking rooms',['non-smoking rooms','номера для некурящих']],
            ['Accessibility',['facilities for disabled guests','wheelchair accessible','доступность']], ['Laundry',['laundry','прачечная']]
          ];
          const amenities = amenityMap.filter(([, keys]) => keys.some(k => bodyLower.includes(k))).map(([label]) => label);

          const roomNames = [];
          const addRoom = value => {
            const t = clean(value);
            if (!t || t.length < 4 || t.length > 120) return;
            const l = t.toLowerCase();
            if (/room service|meeting room|prayer room|laundry room|locker room|non-smoking rooms|family rooms|guest rooms/.test(l)) return;
            if (/^(rooms?|suites?|accommodation|номер|номера)$/i.test(t)) return;
            if (!/(room|suite|king|twin|triple|quad|family|deluxe|superior|standard|executive|studio|номер|люкс|غرفة|جناح)/i.test(t)) return;
            roomNames.push(t);
          };

          const offerWalk = value => {
            if (!value) return;
            if (Array.isArray(value)) return value.forEach(offerWalk);
            if (typeof value !== 'object') return;
            addRoom(value.name);
            addRoom(value.itemOffered?.name);
            addRoom(value.itemOffered?.description);
            Object.values(value).forEach(v => {
              if (v && typeof v === 'object') offerWalk(v);
            });
          };
          offerWalk(hotel.makesOffer);
          offerWalk(hotel.offers);
          offerWalk(hotel.containsPlace);

          const roomSelectors = [
            '[data-testid*="room"] h2','[data-testid*="room"] h3','[data-testid*="room"] h4',
            '[data-stid*="room"] h2','[data-stid*="room"] h3','[data-stid*="room"] h4',
            '[class*="room"] h2','[class*="room"] h3','[class*="room"] h4',
            '[class*="Room"] h2','[class*="Room"] h3','[class*="Room"] h4',
            'table h3','table h4','[role="heading"]'
          ];
          for (const selector of roomSelectors) {
            for (const el of document.querySelectorAll(selector)) addRoom(el.innerText || el.textContent);
          }
          const uniqueRooms = uniq(roomNames).slice(0, 48);

          const media = [];
          const seenMedia = new Set();
          const badMedia = /(logo|sprite|avatar|favicon|placeholder|tracking|pixel|country.?flag|flag.?icon|\\/flags\\/|payment|mapstatic|maps\\.google|qr.?code|social.?icon|language.?flag|profile.?photo|\\.svg(?:\\?|$)|illustration|vector|help.?center|customer.?service|support.?agent|turkey|türkiye|russia|united.?states|united.?kingdom|germany|france|italy|spain|china|japan|india|brazil)/i;
          const roomWords = /(room|suite|bed|bedroom|bathroom|king|twin|deluxe|superior|standard|executive|studio|guest room|номер|люкс|غرفة|جناح)/i;
          const exteriorWords = /(exterior|facade|façade|entrance|building|front of hotel|hotel exterior|наруж|фасад|مدخل|واجهة)/i;
          const lobbyWords = /(lobby|reception|front desk|foyer|лобби|ресепш|استقبال)/i;
          const restaurantWords = /(restaurant|breakfast|dining|buffet|food|cafe|coffee|ресторан|завтрак|буфет|مطعم|إفطار)/i;
          const amenityWords = /(pool|spa|gym|fitness|meeting|ballroom|terrace|parking|shuttle|business center|бассейн|спа|фитнес|قاعة|مسبح)/i;

          const classify = text => {
            if (roomWords.test(text)) return 'room';
            if (exteriorWords.test(text)) return 'exterior';
            if (lobbyWords.test(text)) return 'lobby';
            if (restaurantWords.test(text)) return 'restaurant';
            if (amenityWords.test(text)) return 'amenity';
            return 'other';
          };

          const roomHintFor = text => {
            const l = lower(text);
            for (const room of uniqueRooms) {
              const tokens = lower(room).split(' ').filter(t => t.length > 3);
              if (tokens.length && tokens.filter(t => l.includes(t)).length >= Math.min(2, tokens.length)) return room;
            }
            return null;
          };

          const addMediaURL = (url, label = '', forcedKind = null, priority = 5, trustedContainer = false, width = 0, height = 0) => {
            if (!url || !/^https?:/i.test(url)) return;
            const context = clean(label);
            const combined = `${url} ${context}`;
            if (badMedia.test(combined)) return;
            const w = Number(width || 0), h = Number(height || 0);
            if (!trustedContainer && w > 0 && h > 0 && (w < 420 || h < 240)) return;

            let kind = forcedKind || classify(combined);
            if (!trustedContainer && kind === 'other' && !(w >= 700 && h >= 400)) return;

            const key = (() => { try { const u = new URL(url); return (u.host + u.pathname).toLowerCase(); } catch (_) { return url.toLowerCase(); } })();
            if (seenMedia.has(key)) return;
            seenMedia.add(key);
            media.push({ url, label: context || null, kind, roomHint: kind === 'room' ? roomHintFor(context) : null, priority });
          };

          const addStructuredImage = value => {
            if (!value) return;
            if (typeof value === 'string') return addMediaURL(value, 'Hotel gallery', null, 0, true, 1200, 800);
            if (Array.isArray(value)) return value.forEach(addStructuredImage);
            if (typeof value === 'object') {
              addMediaURL(value.url || value.contentUrl, value.caption || value.name || 'Hotel gallery', null, 0, true, value.width || 1200, value.height || 800);
            }
          };
          // og:image is usually the property cover and is safe to treat as the exterior/hero.
          addMediaURL(meta('og:image','property'), 'Hotel cover', 'exterior', 0, true, 1200, 800);

          const gallerySelectors = [
            '[data-testid="property-gallery"] img','[data-testid*="gallery"] img','[data-testid*="photo"] img',
            '[data-stid*="gallery"] img','[data-stid*="media"] img','[data-selenium*="gallery"] img',
            '[class*="gallery"] img','[class*="Gallery"] img','[class*="photo-grid"] img','[class*="PhotoGrid"] img'
          ];

          const extractImage = (img, trustedContainer, priority) => {
            const figure = img.closest('figure');
            const labelled = img.closest('[aria-label]');
            const roomParent = img.closest('[data-testid*="room"],[data-stid*="room"],[class*="room"],[class*="Room"]');
            const caption = figure?.querySelector('figcaption')?.innerText || '';
            const roomText = roomParent ? clean(roomParent.innerText || '').slice(0, 180) : '';
            const label = clean([img.alt, img.title, labelled?.getAttribute('aria-label'), caption, roomText].filter(Boolean).join(' '));
            const values = [img.currentSrc, img.src, img.dataset?.src, img.dataset?.lazySrc, img.getAttribute('data-original')];
            for (const v of values) addMediaURL(v, label, roomParent ? 'room' : null, priority, trustedContainer, img.naturalWidth || img.width, img.naturalHeight || img.height);
            const srcset = img.srcset || img.getAttribute('data-srcset') || '';
            for (const part of srcset.split(',')) {
              const u = part.trim().split(/\\s+/)[0];
              addMediaURL(u, label, roomParent ? 'room' : null, priority, trustedContainer, img.naturalWidth || img.width, img.naturalHeight || img.height);
            }
          };

          for (const selector of gallerySelectors) {
            for (const img of document.querySelectorAll(selector)) extractImage(img, true, 1);
          }
          // Structured-data photos are a fallback. DOM gallery photos above win when they
          // share the same URL because their alt/caption context is richer for classification.
          addStructuredImage(hotel.image);

          // Fallback: large images inside the main property content only. Tiny UI artwork,
          // country flags, avatars and generic site chrome are deliberately rejected.
          for (const img of document.querySelectorAll('main img, article img, [role="main"] img')) extractImage(img, false, 4);

          media.sort((a,b) => a.priority - b.priority || (a.kind === 'other') - (b.kind === 'other'));
          const imageMetadata = media.slice(0, 90).map(({url,label,kind,roomHint}) => ({url,label,kind,roomHint}));
          const images = imageMetadata.map(x => x.url);

          const result = {
            id: crypto.randomUUID(), provider: '\(escapedProvider)', sourceURL: '\(escapedURL)', name, address, description,
            stars, rating, latitude, longitude, images, imageMetadata, amenities: uniq(amenities), roomNames: uniqueRooms
          };
          return JSON.stringify(result);
        })();
        """
    }
}
