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
    private var query = ""
    private var city = "Makkah"
    private var providerIndex = 0
    private var stage: Stage = .idle
    private var continuationRequested = false

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
        query = "\(name) \(city)"
        self.city = city
        providerIndex = 0; snapshots = []; providerErrors = [:]; draft = nil
        requiresUserAction = false; showSource = false; progress = 0
        loadCurrentProvider()
    }

    func continueAfterVerification() {
        requiresUserAction = false
        showSource = false
        continuationRequested = true
        stage = .extracting
        Task { await extractCurrentPage() }
    }

    func skipCurrentProvider() {
        providerErrors[currentProvider?.rawValue ?? "Unknown"] = "Skipped"
        advanceProvider()
    }

    func setCover(_ imageID: UUID) {
        guard var value = draft else { return }
        for index in value.images.indices { value.images[index].isCover = value.images[index].id == imageID }
        draft = value
    }

    func toggleImage(_ imageID: UUID) {
        guard var value = draft, let index = value.images.firstIndex(where: { $0.id == imageID }) else { return }
        value.images[index].selected.toggle()
        if value.images[index].isCover && !value.images[index].selected { value.images[index].isCover = false }
        if !value.images.contains(where: { $0.isCover && $0.selected }), let first = value.images.firstIndex(where: \.selected) { value.images[first].isCover = true }
        draft = value
    }

    private func loadCurrentProvider() {
        guard providerIndex < Provider.allCases.count else {
            stage = .finished; progress = 1
            draft = HotelNormalizer.makeDraft(query: query.replacingOccurrences(of: " \(city)", with: ""), city: city, snapshots: snapshots)
            status = "Импорт завершён. Проверьте карточку."
            return
        }
        let provider = Provider.allCases[providerIndex]
        currentProvider = provider
        stage = .searching
        status = "\(provider.rawValue): ищем точный отель…"
        progress = Double(providerIndex) / Double(Provider.allCases.count)
        guard let url = provider.searchURL(query: query) else { providerErrors[provider.rawValue] = "Invalid URL"; advanceProvider(); return }
        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 35))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task {
            let blocked = await detectVerification()
            if blocked {
                requiresUserAction = true; showSource = true
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
        if isDetailURL(webView.url, provider: provider) { stage = .extracting; await extractCurrentPage(); return }
        stage = .openingHotel
        let tokenJSON = (try? String(data: JSONSerialization.data(withJSONObject: query.lowercased().split(separator: " ").map(String.init)), encoding: .utf8)) ?? "[]"
        let hintJSON = (try? String(data: JSONSerialization.data(withJSONObject: provider.detailHints), encoding: .utf8)) ?? "[]"
        let script = """
        (() => {
          const tokens = \(tokenJSON);
          const hints = \(hintJSON);
          const links = [...document.querySelectorAll('a[href]')];
          let best = null, bestScore = -1;
          for (const a of links) {
            const href = (a.href || '').toLowerCase();
            if (!hints.some(h => href.includes(h))) continue;
            const text = ((a.innerText || '') + ' ' + (a.getAttribute('aria-label') || '')).toLowerCase();
            let score = 0;
            for (const t of tokens) if (t.length > 2 && text.includes(t)) score += 3;
            if (href.includes('makkah') || href.includes('mecca') || href.includes('madinah') || href.includes('medina')) score += 1;
            if (score > bestScore) { bestScore = score; best = a.href; }
          }
          return best;
        })();
        """
        do {
            let value = try await webView.evaluateJavaScript(script)
            if let href = value as? String, let url = URL(string: href) {
                status = "\(provider.rawValue): открываем карточку…"
                webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 35))
            } else {
                providerErrors[provider.rawValue] = "Hotel result not found"
                advanceProvider()
            }
        } catch { failCurrent(error.localizedDescription) }
    }

    private func extractCurrentPage() async {
        guard let provider = currentProvider, let sourceURL = webView.url?.absoluteString else { advanceProvider(); return }
        status = "\(provider.rawValue): собираем данные и фотографии…"
        stage = .extracting
        let providerName = provider.rawValue.replacingOccurrences(of: "'", with: "")
        let script = Self.extractionScript(provider: providerName, sourceURL: sourceURL)
        do {
            let raw = try await webView.evaluateJavaScript(script)
            guard let json = raw as? String, let data = json.data(using: .utf8) else { throw APIError.server("EMPTY_EXTRACT") }
            let snapshot = try JSONDecoder().decode(ProviderSnapshot.self, from: data)
            snapshots.append(snapshot)
            advanceProvider()
        } catch { failCurrent(error.localizedDescription) }
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
        continuationRequested = false
        loadCurrentProvider()
    }

    private static func extractionScript(provider: String, sourceURL: String) -> String {
        let escapedProvider = provider.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        let escapedURL = sourceURL.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        return """
        (() => {
          const uniq = arr => [...new Set(arr.filter(Boolean).map(v => String(v).trim()).filter(Boolean))];
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

          const images = [];
          const addImage = value => {
            if (!value) return;
            if (typeof value === 'string') images.push(value);
            else if (Array.isArray(value)) value.forEach(addImage);
            else if (typeof value === 'object') addImage(value.url || value.contentUrl);
          };
          addImage(hotel.image);
          addImage(meta('og:image','property'));
          for (const img of [...document.images]) {
            const values = [img.currentSrc, img.src, img.dataset?.src, img.dataset?.lazySrc, img.getAttribute('data-original')];
            for (const v of values) if (v && /^https?:/i.test(v)) images.push(v);
            const srcset = img.srcset || img.getAttribute('data-srcset') || '';
            for (const part of srcset.split(',')) {
              const url = part.trim().split(/\\s+/)[0];
              if (/^https?:/i.test(url)) images.push(url);
            }
          }

          const body = (document.body?.innerText || '').replace(/\\s+/g,' ');
          const lower = body.toLowerCase();
          const amenityMap = [
            ['Wi‑Fi',['free wifi','wi-fi','wifi']], ['Завтрак',['breakfast','завтрак']], ['Ресторан',['restaurant','ресторан']],
            ['Фитнес-зал',['fitness center','fitness centre','gym','фитнес']], ['Бассейн',['swimming pool','pool','бассейн']],
            ['Парковка',['parking','парковка']], ['Трансфер',['airport shuttle','shuttle service','трансфер']],
            ['Room service',['room service']], ['24/7 reception',['24-hour front desk','24 hour front desk','круглосуточная стойка']],
            ['Family rooms',['family rooms','семейные номера']], ['Non-smoking rooms',['non-smoking rooms','номера для некурящих']],
            ['Accessibility',['facilities for disabled guests','wheelchair accessible','доступность']], ['Laundry',['laundry','прачечная']]
          ];
          const amenities = amenityMap.filter(([, keys]) => keys.some(k => lower.includes(k))).map(([name]) => name);

          const roomRegex = /(room|suite|king|twin|triple|quad|family|deluxe|superior|standard|executive|studio|номер|люкс)/i;
          const roomNames = [];
          const nodes = [...document.querySelectorAll('h2,h3,h4,[role="heading"],button,span,strong')];
          for (const el of nodes) {
            const t = (el.innerText || '').replace(/\\s+/g,' ').trim();
            if (t.length >= 4 && t.length <= 90 && roomRegex.test(t) && !/book|select|choose|reserve|availability|price/i.test(t)) roomNames.push(t);
            if (roomNames.length > 80) break;
          }

          const result = {
            id: crypto.randomUUID(), provider: '\(escapedProvider)', sourceURL: '\(escapedURL)', name, address, description,
            stars, rating, latitude, longitude, images: uniq(images).slice(0,120), amenities: uniq(amenities), roomNames: uniq(roomNames).slice(0,40)
          };
          return JSON.stringify(result);
        })();
        """
    }
}
