import SwiftUI

struct FlightCurationView: View {
    @Environment(\.dismiss) private var dismiss

    private enum SearchMode: String, CaseIterable, Identifiable {
        case outbound
        case inbound
        case roundTrip

        var id: String { rawValue }

        var title: String {
            switch self {
            case .outbound: return "Туда"
            case .inbound: return "Обратно"
            case .roundTrip: return "Туда-обратно"
            }
        }

        var apiValue: String {
            switch self {
            case .outbound: return "outbound_one_way"
            case .inbound: return "return_one_way"
            case .roundTrip: return "round_trip"
            }
        }
    }

    @State private var searchMode: SearchMode = .roundTrip
    @State private var outboundOrigin = "TAS"
    @State private var outboundDestination = "JED"
    @State private var inboundOrigin = "MED"
    @State private var inboundDestination = "TAS"
    @State private var departureDate = Calendar.current.date(byAdding: .day, value: 21, to: Date()) ?? Date()
    @State private var returnDate = Calendar.current.date(byAdding: .day, value: 28, to: Date()) ?? Date()
    @State private var adults = 1
    @State private var selectedAirlines: Set<String> = ["HY", "C6", "HH", "9S", "2U", "FZ", "XY"]
    @State private var results: [BusinessFlightCurationItinerary] = []
    @State private var published: [BusinessCuratedFlightOffer] = []
    @State private var isSearching = false
    @State private var publishingIDs: Set<String> = []
    @State private var errorMessage: String?
    @State private var hasSearched = false
    @State private var searchDiagnostics: BusinessFlightCurationSearchResponse.Diagnostics?

    private let api = APIClient.shared

    private struct AirlineFilter: Identifiable {
        let code: String
        let name: String
        var id: String { code }
    }

    private let airlines: [AirlineFilter] = [
        .init(code: "HY", name: "Uzbekistan Airways"),
        .init(code: "C6", name: "Centrum Air"),
        .init(code: "HH", name: "Qanot Sharq"),
        .init(code: "9S", name: "Air Samarkand"),
        .init(code: "2U", name: "Fly Khiva"),
        .init(code: "FZ", name: "flydubai"),
        .init(code: "XY", name: "flynas")
    ]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                intro
                routeCard
                airlineFilters
                searchButton

                if isSearching {
                    ProgressView(searchProgressText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                } else if !results.isEmpty {
                    searchResults
                } else if hasSearched {
                    emptySearchState
                }

                publishedSection
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 36)
        }
        .background(BusinessDesign.background.ignoresSafeArea())
        .navigationTitle("Авиабилеты")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Закрыть") { dismiss() }
            }
        }
        .task { await loadPublished() }
        .onChange(of: searchMode) { _, _ in
            results = []
            hasSearched = false
            searchDiagnostics = nil
        }
        .alert("Не удалось выполнить действие", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Неизвестная ошибка")
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Поиск и публикация рейсов")
                .font(.system(size: 26, weight: .bold))
                .tracking(-0.6)
            Text("Три режима поиска: отдельный рейс туда, отдельный рейс обратно или полный маршрут. В режиме «Туда-обратно» Business отдельно помечает настоящий round-trip Ignav и комбинацию ONE WAY + RETURN, которую собрала система.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 10)
    }

    private var routeCard: some View {
        VStack(spacing: 16) {
            Picker("Тип поиска", selection: $searchMode) {
                ForEach(SearchMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if searchMode == .outbound || searchMode == .roundTrip {
                HStack(spacing: 12) {
                    airportField("Откуда", text: $outboundOrigin)
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                    airportField("Куда", text: $outboundDestination)
                }

                DatePicker("Вылет", selection: $departureDate, in: Date()..., displayedComponents: .date)
            }

            if searchMode == .roundTrip {
                Divider()
            }

            if searchMode == .inbound || searchMode == .roundTrip {
                HStack(spacing: 12) {
                    airportField("Обратно из", text: $inboundOrigin)
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                    airportField("Возврат", text: $inboundDestination)
                }

                DatePicker(
                    searchMode == .inbound ? "Дата" : "Возврат",
                    selection: $returnDate,
                    in: searchMode == .roundTrip ? max(departureDate, Date())... : Date()...,
                    displayedComponents: .date
                )
            }

            Stepper("Паломники: \(adults)", value: $adults, in: 1...9)

            HStack(spacing: 8) {
                Image(systemName: "arrow.trianglehead.branch")
                Text("Только прямые рейсы · 0 пересадок")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }

            if searchMode == .roundTrip {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: isExactReverseRoute ? "checkmark.seal.fill" : "info.circle.fill")
                        .foregroundStyle(isExactReverseRoute ? Color.green : Color.orange)
                    Text(roundTripRouteNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(BusinessDesign.secondarySurface, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            }
        }
        .padding(18)
        .background(.white, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(BusinessDesign.line))
        .onChange(of: departureDate) { _, newValue in
            if returnDate < newValue {
                returnDate = Calendar.current.date(byAdding: .day, value: 7, to: newValue) ?? newValue
            }
        }
    }

    private func airportField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("TAS", text: text)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .onChange(of: text.wrappedValue) { _, value in
                    let clean = String(value.uppercased().filter { $0.isLetter }.prefix(3))
                    if clean != value { text.wrappedValue = clean }
                }
        }
        .padding(.horizontal, 13)
        .frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
        .background(BusinessDesign.secondarySurface, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
    }

    private var airlineFilters: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Авиакомпании")
                .font(.headline)
            Text("Выберите перевозчиков, которых Ignav должен включить в поиск.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 9) {
                    ForEach(airlines) { airline in
                        let selected = selectedAirlines.contains(airline.code)
                        Button {
                            if selected { selectedAirlines.remove(airline.code) }
                            else { selectedAirlines.insert(airline.code) }
                        } label: {
                            HStack(spacing: 8) {
                                BusinessAirlineLogoView(airlineIATA: airline.code, size: 30)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(airline.code).font(.caption.bold())
                                    Text(airline.name).font(.caption2).lineLimit(1)
                                }
                                if selected {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.green)
                                }
                            }
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 10)
                            .frame(height: 48)
                            .background(selected ? Color.green.opacity(0.08) : .white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(selected ? Color.green.opacity(0.24) : BusinessDesign.line))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var searchButton: some View {
        Button {
            Task { await search() }
        } label: {
            HStack {
                Image(systemName: "magnifyingglass")
                Text(searchButtonTitle)
                    .fontWeight(.semibold)
                Spacer()
                if !selectedAirlines.isEmpty {
                    Text("\(selectedAirlines.count)")
                        .font(.caption.bold())
                        .padding(7)
                        .background(.white.opacity(0.18), in: Circle())
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(height: 56)
            .background(Color.black, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!canSearch || isSearching)
        .opacity(canSearch ? 1 : 0.45)
    }

    private var emptySearchState: some View {
        let usable = searchDiagnostics?.usableItinerariesByLeg ?? []
        let raw = searchDiagnostics?.rawItinerariesByLeg ?? []

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "airplane.circle")
                    .font(.title3)
                Text("Подходящих рейсов пока нет")
                    .font(.headline)
            }

            Text(emptySearchDescription)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if searchDiagnostics != nil {
                if searchMode == .roundTrip {
                    let roundTrips = searchDiagnostics?.dedicatedRoundTripCount ?? 0
                    let pairs = searchDiagnostics?.pairedOneWayCount ?? 0
                    Text("Готовых round-trip Ignav: \(roundTrips). Комбинаций ONE WAY + RETURN: \(pairs). Отдельные участки от провайдера: \(raw.map(String.init).joined(separator: " / ")).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Получено от провайдера: \(raw.first ?? 0). Подошло после проверки прямого рейса и авиакомпании: \(usable.first ?? 0).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(BusinessDesign.line))
    }

    private var searchResults: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Результаты")
                    .font(.title3.bold())
                Spacer()
                Text("\(results.count)")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
            }

            if searchMode == .roundTrip, isExactReverseRoute {
                Text("Список отсортирован по полной цене. Смотрите метку на карточке: настоящий тариф туда-обратно Ignav и сумма двух отдельных one-way — разные продукты.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(results.prefix(30)) { itinerary in
                resultCard(itinerary)
            }
        }
    }

    private func resultCard(_ itinerary: BusinessFlightCurationItinerary) -> some View {
        let alreadyPublished = published.contains { offer in
            offer.publicationIdentity == itinerary.publicationIdentity || offer.sourceCandidateID == itinerary.id
        }
        let total = itinerary.price.amount
        let perTraveler = total / Double(max(adults, 1))
        let badge = fareKindLabel(itinerary)
        let badgeColor = fareKindColor(itinerary)

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                BusinessAirlineLogoView(airlineIATA: itinerary.primaryAirlineCode, size: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(itinerary.primaryAirlineName)
                        .font(.headline)
                    Text(itinerary.legs.map(\.flightNumber).filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(money(total, currency: itinerary.price.currency))
                        .font(.headline)
                    Text("\(money(perTraveler, currency: itinerary.price.currency)) / чел.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Label(badge, systemImage: fareKindIcon(itinerary))
                .font(.caption.weight(.bold))
                .foregroundStyle(badgeColor)
                .padding(.horizontal, 10)
                .frame(minHeight: 29)
                .background(badgeColor.opacity(0.10), in: Capsule())

            if itinerary.price.status?.lowercased() == "unverified" {
                Label("Ориентировочная цена Ignav — рейс найден, но тариф ещё не подтверждён при booking lookup.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(itinerary.legs.indices, id: \.self) { index in
                let leg = itinerary.legs[index]
                HStack(spacing: 8) {
                    Text("\(leg.origin) → \(leg.destination)")
                        .font(.subheadline.weight(.semibold))
                    Text(dateTime(leg.departureAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Прямой")
                        .font(.caption.bold())
                        .foregroundStyle(.green)
                }
            }

            Button {
                Task { await publish(itinerary) }
            } label: {
                HStack {
                    Image(systemName: alreadyPublished ? "checkmark.circle.fill" : "plus.circle.fill")
                    Text(alreadyPublished ? "Уже опубликовано" : "Опубликовать в iumrah")
                    Spacer()
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(alreadyPublished ? Color.secondary : Color.primary)
                .padding(.horizontal, 14)
                .frame(height: 46)
                .background(BusinessDesign.secondarySurface, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(alreadyPublished || publishingIDs.contains(itinerary.id))
        }
        .padding(17)
        .background(.white, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(BusinessDesign.line))
    }

    private var publishedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Опубликованные рейсы")
                    .font(.title3.bold())
                Spacer()
                if !published.isEmpty {
                    Text("\(published.count)")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                }
            }

            if published.isEmpty {
                Text("Пока ничего не опубликовано. Выберите подходящий результат — он появится в клиентском блоке актуальных рейсов.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(17)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            } else {
                ForEach(published) { offer in
                    HStack(spacing: 12) {
                        BusinessAirlineLogoView(airlineIATA: offer.airlineCodes.first, size: 42)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(offer.airlineNames.first ?? offer.airlineCodes.first ?? "Рейс")
                                .font(.subheadline.weight(.semibold))
                            Text(publishedKindLabel(offer))
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(publishedKindColor(offer))
                            Text("\(offer.outboundOrigin) → \(offer.outboundDestination) · \(displayDate(offer.outboundDate))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let inboundDate = offer.inboundDate,
                               let inboundOrigin = offer.inboundOrigin,
                               let inboundDestination = offer.inboundDestination {
                                Text("\(inboundOrigin) → \(inboundDestination) · \(displayDate(inboundDate))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(money(offer.perTravelerFare, currency: offer.currency))
                                .font(.subheadline.bold())
                            Text("себестоимость / чел.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Button(role: .destructive) {
                            Task { await delete(offer) }
                        } label: {
                            Image(systemName: "trash")
                                .frame(width: 36, height: 36)
                                .background(Color.red.opacity(0.08), in: Circle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(15)
                    .background(.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(BusinessDesign.line))
                }
            }
        }
    }

    private var canSearch: Bool {
        guard !selectedAirlines.isEmpty else { return false }
        switch searchMode {
        case .outbound:
            return outboundOrigin.count == 3 && outboundDestination.count == 3
        case .inbound:
            return inboundOrigin.count == 3 && inboundDestination.count == 3
        case .roundTrip:
            return [outboundOrigin, outboundDestination, inboundOrigin, inboundDestination].allSatisfy { $0.count == 3 }
                && departureDate <= returnDate
        }
    }

    private var isExactReverseRoute: Bool {
        outboundOrigin == inboundDestination && outboundDestination == inboundOrigin
    }

    private var roundTripRouteNote: String {
        if isExactReverseRoute {
            return "Маршрут зеркальный. Business сравнит настоящий round-trip тариф Ignav с нашей суммой ONE WAY + RETURN."
        }
        return "Это open-jaw маршрут. У Ignav нет единого round-trip тарифа для разных аэропортов возврата, поэтому здесь будет только чётко помеченная комбинация ONE WAY + RETURN."
    }

    private var searchButtonTitle: String {
        switch searchMode {
        case .outbound: return "Найти рейсы туда"
        case .inbound: return "Найти рейсы обратно"
        case .roundTrip: return "Сравнить туда-обратно"
        }
    }

    private var searchProgressText: String {
        switch searchMode {
        case .outbound: return "Ищем прямые рейсы туда…"
        case .inbound: return "Ищем прямые рейсы обратно…"
        case .roundTrip: return "Сравниваем варианты туда-обратно…"
        }
    }

    private var emptySearchDescription: String {
        switch searchMode {
        case .outbound:
            return "Ignav не вернул подходящий прямой рейс \(outboundOrigin) → \(outboundDestination) на выбранную дату."
        case .inbound:
            return "Ignav не вернул подходящий прямой рейс \(inboundOrigin) → \(inboundDestination) на выбранную дату."
        case .roundTrip:
            return "Для \(outboundOrigin) → \(outboundDestination) и \(inboundOrigin) → \(inboundDestination) подходящего полного варианта пока нет."
        }
    }

    @MainActor
    private func search() async {
        guard canSearch else { return }
        isSearching = true
        errorMessage = nil
        defer { isSearching = false }

        let legs: [BusinessFlightCurationSearchRequest.Leg]
        switch searchMode {
        case .outbound:
            legs = [
                .init(origin: outboundOrigin, destination: outboundDestination, departureDate: Self.apiDay.string(from: departureDate), maxStops: 0)
            ]
        case .inbound:
            legs = [
                .init(origin: inboundOrigin, destination: inboundDestination, departureDate: Self.apiDay.string(from: returnDate), maxStops: 0)
            ]
        case .roundTrip:
            legs = [
                .init(origin: outboundOrigin, destination: outboundDestination, departureDate: Self.apiDay.string(from: departureDate), maxStops: 0),
                .init(origin: inboundOrigin, destination: inboundDestination, departureDate: Self.apiDay.string(from: returnDate), maxStops: 0)
            ]
        }

        let request = BusinessFlightCurationSearchRequest(
            legs: legs,
            adults: adults,
            children: 0,
            infantsInSeat: 0,
            infantsOnLap: 0,
            cabinClass: "economy",
            airlinesInclude: selectedAirlines.sorted(),
            allowSelfTransfer: false,
            curationMode: searchMode.apiValue
        )

        do {
            let response = try await api.searchFlightsForCuration(request)
            results = response.itineraries
            searchDiagnostics = response.diagnostics
            hasSearched = true
        } catch {
            results = []
            searchDiagnostics = nil
            hasSearched = false
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func loadPublished() async {
        do { published = try await api.curatedFlights() }
        catch { errorMessage = error.localizedDescription }
    }

    @MainActor
    private func publish(_ itinerary: BusinessFlightCurationItinerary) async {
        publishingIDs.insert(itinerary.id)
        defer { publishingIDs.remove(itinerary.id) }
        do {
            _ = try await api.publishCuratedFlight(itinerary, travelerCount: adults)
            published = try await api.curatedFlights()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func delete(_ offer: BusinessCuratedFlightOffer) async {
        do {
            try await api.deleteCuratedFlight(id: offer.id)
            published.removeAll { $0.id == offer.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func fareKindLabel(_ itinerary: BusinessFlightCurationItinerary) -> String {
        switch itinerary.effectiveOfferType {
        case "round_trip":
            return "ТУДА-ОБРАТНО · ЕДИНЫЙ ТАРИФ IGNAV"
        case "paired_one_way":
            return "ONE WAY + RETURN · СУММА 2 БИЛЕТОВ"
        default:
            return itinerary.effectiveJourneyRole == "return" ? "ONE WAY · ОБРАТНО" : "ONE WAY · ТУДА"
        }
    }

    private func fareKindIcon(_ itinerary: BusinessFlightCurationItinerary) -> String {
        switch itinerary.effectiveOfferType {
        case "round_trip": return "arrow.left.arrow.right.circle.fill"
        case "paired_one_way": return "plus.circle.fill"
        default: return "arrow.right.circle.fill"
        }
    }

    private func fareKindColor(_ itinerary: BusinessFlightCurationItinerary) -> Color {
        switch itinerary.effectiveOfferType {
        case "round_trip": return .green
        case "paired_one_way": return .orange
        default: return .blue
        }
    }

    private func publishedKindLabel(_ offer: BusinessCuratedFlightOffer) -> String {
        let type = offer.offerType ?? offer.itinerary?.effectiveOfferType ?? "paired_one_way"
        let role = offer.journeyRole ?? offer.itinerary?.effectiveJourneyRole ?? "complete"
        switch type {
        case "round_trip": return "ТУДА-ОБРАТНО · IGNAV"
        case "paired_one_way": return "ONE WAY + RETURN"
        default: return role == "return" ? "ONE WAY · ОБРАТНО" : "ONE WAY · ТУДА"
        }
    }

    private func publishedKindColor(_ offer: BusinessCuratedFlightOffer) -> Color {
        let type = offer.offerType ?? offer.itinerary?.effectiveOfferType ?? "paired_one_way"
        switch type {
        case "round_trip": return .green
        case "paired_one_way": return .orange
        default: return .blue
        }
    }

    private func money(_ value: Double, currency: String) -> String {
        let code = currency.uppercased()
        if code == "USD" { return "$\(Int(value.rounded()))" }
        return "\(Int(value.rounded())) \(code)"
    }

    private func dateTime(_ iso: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: iso) else { return iso }
        return Self.displayDateTime.string(from: date)
    }

    private func displayDate(_ apiDate: String) -> String {
        guard let date = Self.apiDay.date(from: apiDate) else { return apiDate }
        return Self.displayDay.string(from: date)
    }

    private static let apiDay: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let displayDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMM"
        return f
    }()

    private static let displayDateTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMM, HH:mm"
        return f
    }()
}
