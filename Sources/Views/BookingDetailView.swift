import SwiftUI

struct BookingDetailView: View {
    let bookingID: String

    @State private var detail: BookingDetailResponse?
    @State private var loading = true
    @State private var saving = false
    @State private var errorMessage: String?
    @State private var status: TripStatus = .new
    @State private var paymentStatus = ""
    @State private var confirmationNumber = ""
    @State private var internalNotes = ""
    @State private var showPricing = false
    @State private var editingFlight: BookingFlightDirection?
    @State private var editingHotelCity: String?
    @State private var showGuidePicker = false

    var body: some View {
        ScrollView {
            if let detail {
                VStack(alignment: .leading, spacing: 16) {
                    hero(detail)
                    operationsCard(detail)

                    sectionTitle("Перелёты", subtitle: "Рейс можно заменить только после проверки AeroDataBox.")
                    flightCard(.outbound, detail: detail)
                    flightCard(.return, detail: detail)

                    sectionTitle("Размещение", subtitle: "Операционные изменения применяются только к этой поездке.")
                    hotelCard(city: "Makkah", detail: detail)
                    if !detail.booking.madinahHotel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || detail.assignment?.madinahHotel != nil {
                        hotelCard(city: "Madinah", detail: detail)
                    }

                    guideCard(detail)
                    tripCard(detail.booking)
                    pricingCard(detail)
                    technicalCard(detail)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 34)
            } else if loading {
                ProgressView().padding(.top, 70)
            } else {
                ContentUnavailableView("Бронь недоступна", systemImage: "suitcase.rolling", description: Text(errorMessage ?? "Не удалось загрузить данные."))
                    .padding(.top, 60)
            }
        }
        .background(Color.white)
        .navigationTitle("Бронирование")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if saving { ProgressView().controlSize(.small) }
                else { Button("Сохранить") { Task { await save() } }.fontWeight(.semibold).disabled(detail?.operation == nil) }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $editingFlight) { direction in
            if let detail {
                FlightEditorSheet(
                    bookingID: bookingID,
                    direction: direction,
                    current: savedFlight(direction, detail: detail),
                    fallbackDate: direction == .outbound ? detail.booking.startDate : detail.booking.endDate
                ) { _ in
                    editingFlight = nil
                    Task { await load() }
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { editingHotelCity != nil },
            set: { if !$0 { editingHotelCity = nil } }
        )) {
            if let detail, let city = editingHotelCity {
                HotelAssignmentPicker(bookingID: bookingID, city: city, assignment: detail.assignment) {
                    editingHotelCity = nil
                    Task { await load() }
                }
            }
        }
        .sheet(isPresented: $showGuidePicker) {
            if let detail {
                NavigationStack {
                    GuideAssignmentPicker(bookingID: bookingID, assignment: detail.assignment) {
                        showGuidePicker = false
                        Task { await load() }
                    }
                }
            }
        }
        .alert("Не удалось выполнить действие", isPresented: Binding(get: { errorMessage != nil && detail != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func sectionTitle(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title2.bold())
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    private func hero(_ detail: BookingDetailResponse) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(detail.booking.clientName ?? detail.pilgrim?.displayName ?? "Паломник")
                        .font(.system(size: 30, weight: .bold, design: .rounded)).tracking(-1)
                    Text(detail.pilgrim?.id ?? detail.booking.pilgrimID ?? bookingID)
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                Text(detail.booking.totalUsd, format: .currency(code: "USD").precision(.fractionLength(0)))
                    .font(.title3.bold()).monospacedDigit()
            }
            HStack(spacing: 8) {
                statusBadge(status)
                Label("\(detail.booking.travelerCount)", systemImage: "person.2.fill")
                Label("\(detail.booking.rooms)", systemImage: "bed.double.fill")
            }
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }
        .padding(18).businessCard(radius: 28)
    }

    private func operationsCard(_ detail: BookingDetailResponse) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Управление поездкой", systemImage: "slider.horizontal.3").font(.title2.bold())
            Picker("Статус поездки", selection: $status) {
                ForEach(TripStatus.allCases) { item in Text(item.title).tag(item) }
            }
            .pickerStyle(.menu)

            labeledField("Статус оплаты", text: $paymentStatus, placeholder: "Например: оплачено полностью")
            labeledField("Номер бронирования / подтверждения", text: $confirmationNumber, placeholder: "Confirmation number")

            VStack(alignment: .leading, spacing: 7) {
                Text("Внутренняя заметка").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                TextField("Только для iumrah Business", text: $internalNotes, axis: .vertical)
                    .lineLimit(3...6)
                    .padding(12)
                    .background(BusinessDesign.secondarySurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }

            if !detail.statusHistory.isEmpty {
                DisclosureGroup("История статусов") {
                    VStack(spacing: 9) {
                        ForEach(Array(detail.statusHistory.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .top) {
                                Text(TripStatus(rawValue: item.newStatus)?.title ?? item.newStatus).font(.caption.weight(.semibold))
                                Spacer()
                                Text(shortDate(item.createdAt)).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.top, 8)
                }
                .font(.subheadline.weight(.semibold))
            }
        }
        .padding(18).businessCard(radius: 28)
    }

    private func flightCard(_ direction: BookingFlightDirection, detail: BookingDetailResponse) -> some View {
        let flight = savedFlight(direction, detail: detail)
        let origin = direction == .outbound ? detail.booking.originCode : detail.booking.returnOrigin
        let destination = direction == .outbound ? detail.booking.outboundDestination : detail.booking.originCode
        let fallbackDate = direction == .outbound ? detail.booking.startDate : detail.booking.endDate

        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(direction.title).font(.title2.bold())
                    Text(flight?.airlineName.nonEmpty ?? "Рейс ещё не подтверждён")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Изменить") { editingFlight = direction }
                    .font(.subheadline.bold())
                    .padding(.horizontal, 14).frame(height: 38)
                    .background(BusinessDesign.secondarySurface, in: Capsule())
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(flight?.departureAirportIATA.nonEmpty ?? origin).font(.system(size: 26, weight: .bold, design: .rounded))
                    Text(flight?.departureAirportName.nonEmpty ?? "Отправление").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Image(systemName: "airplane").font(.title3).foregroundStyle(.secondary)
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(flight?.arrivalAirportIATA.nonEmpty ?? destination).font(.system(size: 26, weight: .bold, design: .rounded))
                    Text(flight?.arrivalAirportName.nonEmpty ?? "Прибытие").font(.caption).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.trailing)
                }
            }

            Divider()

            HStack(alignment: .top, spacing: 12) {
                flightMetric("Рейс", flight?.flightNumber.nonEmpty ?? "—")
                flightMetric("Дата", displayFlightDate(flight?.scheduledDepartureLocal, fallback: fallbackDate))
                flightMetric("Терминал", flight?.departureTerminal.nonEmpty ?? "—")
            }

            if let flight {
                HStack(spacing: 7) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    Text("Проверено AeroDataBox")
                    if !flight.status.isEmpty { Text("· \(flight.status)") }
                }
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 7) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    Text("Введите номер рейса и дату — система проверит существование рейса перед сохранением.")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(18).businessCard(radius: 28)
    }

    private func flightMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).font(.caption2.bold()).tracking(1).foregroundStyle(.secondary)
            Text(value).font(.subheadline.bold()).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func hotelCard(city: String, detail: BookingDetailResponse) -> some View {
        let assigned = city == "Makkah" ? detail.assignment?.makkahHotel : detail.assignment?.madinahHotel
        let fallback = city == "Makkah" ? detail.booking.makkahHotel : detail.booking.madinahHotel
        return HStack(spacing: 14) {
            if let assigned, let url = AppConfig.absoluteURL(assigned.coverImageURL) {
                AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { BusinessDesign.secondarySurface }
                    .frame(width: 82, height: 82).clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(BusinessDesign.secondarySurface)
                    .frame(width: 82, height: 82)
                    .overlay(Image(systemName: "building.2.fill").font(.title2).foregroundStyle(.secondary))
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Отель · \(city)").font(.caption.bold()).foregroundStyle(.secondary)
                Text(assigned?.name ?? (fallback.isEmpty ? "Не выбран" : fallback)).font(.headline).lineLimit(2)
                if let assigned {
                    Text("\(assigned.stars ?? 0)★ · \(assigned.roomCount) типов номеров").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Изменить") { editingHotelCity = city }
                .font(.caption.bold()).padding(.horizontal, 12).frame(height: 36)
                .background(BusinessDesign.secondarySurface, in: Capsule())
        }
        .padding(18).businessCard(radius: 28)
    }

    private func guideCard(_ detail: BookingDetailResponse) -> some View {
        let guide = detail.assignment?.guide
        return HStack(spacing: 14) {
            Circle().fill(BusinessDesign.secondarySurface).frame(width: 70, height: 70)
                .overlay(Text(guideInitials(guide)).font(.title3.bold()))
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text("Гид").font(.caption.bold()).foregroundStyle(.secondary)
                    if detail.assignment?.guideIsPrimary == true {
                        Text("Рекомендует iumrah").font(.caption2.bold()).padding(.horizontal, 8).frame(height: 23).background(Color.black, in: Capsule()).foregroundStyle(.white)
                    }
                }
                Text(guide?.displayName ?? "Гид не назначен").font(.headline)
                if let title = guide?.roleTitle, !title.isEmpty { Text(title).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            Button("Изменить") { showGuidePicker = true }
                .font(.caption.bold()).padding(.horizontal, 12).frame(height: 36)
                .background(BusinessDesign.secondarySurface, in: Capsule())
        }
        .padding(18).businessCard(radius: 28)
    }

    private func tripCard(_ booking: BookingSummary) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Поездка", systemImage: "map.fill").font(.title2.bold())
            detailRow("Маршрут", "\(booking.originCode) → \(booking.outboundDestination) → \(booking.originCode)")
            detailRow("Даты", "\(booking.startDate) – \(booking.endDate)")
            detailRow("Паломников", "\(booking.travelerCount)")
            detailRow("Комнат", "\(booking.rooms)")
            detailRow("Тариф", booking.planId)
            detailRow("На человека", booking.perPilgrimUsd.formatted(.currency(code: "USD")))
        }
        .padding(18).businessCard(radius: 28)
    }

    private func pricingCard(_ detail: BookingDetailResponse) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.3)) { showPricing.toggle() }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "eye.slash.fill").frame(width: 38, height: 38).background(BusinessDesign.secondarySurface, in: Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Цена под капотом").font(.title2.bold()).foregroundStyle(.primary)
                        Text("Внутренний расчёт · клиент его не видит").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: showPricing ? "chevron.up" : "chevron.down").font(.caption.bold()).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            if showPricing {
                Divider().padding(.vertical, 14)
                if detail.pricingLines.isEmpty {
                    detailRow("Итого клиенту", detail.booking.totalUsd.formatted(.currency(code: "USD")))
                    detailRow("На паломника", detail.booking.perPilgrimUsd.formatted(.currency(code: "USD")))
                    Text("Для этой старой заявки клиентский генератор ещё не передал детальный pricingSnapshot. После подключения клиентского repo здесь появятся себестоимость, комиссии и маржа по каждому компоненту.")
                        .font(.caption).foregroundStyle(.secondary).padding(.top, 10)
                } else {
                    let groups = groupedPricing(detail.pricingLines)
                    ForEach(Array(groups.enumerated()), id: \.offset) { index, entry in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(entry.0.uppercased()).font(.caption2.bold()).tracking(1.2).foregroundStyle(.secondary)
                            ForEach(entry.1) { line in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(line.label).font(.subheadline)
                                    Spacer(minLength: 12)
                                    Text(line.amount, format: .currency(code: line.currency).precision(.fractionLength(0...2)))
                                        .font(.subheadline.bold()).monospacedDigit()
                                }
                            }
                        }
                        if index < groups.count - 1 { Divider().padding(.vertical, 8) }
                    }
                }
            }
        }
        .padding(18).businessCard(radius: 28)
    }

    private func technicalCard(_ detail: BookingDetailResponse) -> some View {
        DisclosureGroup {
            VStack(spacing: 9) {
                ForEach(detail.requestFields.prefix(80)) { field in
                    HStack(alignment: .top, spacing: 12) {
                        Text(field.label).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        Text(field.value).multilineTextAlignment(.trailing).frame(maxWidth: .infinity, alignment: .trailing).textSelection(.enabled)
                    }
                    .font(.caption)
                }
            }
            .padding(.top, 12)
        } label: {
            Label("Технические данные заявки", systemImage: "doc.text.magnifyingglass").font(.headline)
        }
        .padding(18).businessCard(radius: 28)
    }

    private func savedFlight(_ direction: BookingFlightDirection, detail: BookingDetailResponse) -> BookingFlight? {
        detail.flights?.first { $0.direction == direction.rawValue }
    }

    private func displayFlightDate(_ value: String?, fallback: String) -> String {
        guard let value, !value.isEmpty else { return fallback }
        let prefix = String(value.prefix(10))
        return prefix.isEmpty ? fallback : prefix
    }

    private func guideInitials(_ member: BusinessTeamMember?) -> String {
        guard let member else { return "i" }
        let values = [member.firstName, member.lastName].filter { !$0.isEmpty }
        let initials = values.prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        return initials.isEmpty ? "i" : initials
    }

    private func groupedPricing(_ lines: [BookingPricingLine]) -> [(String, [BookingPricingLine])] {
        Dictionary(grouping: lines, by: \.group).sorted { $0.key < $1.key }
    }

    private func labeledField(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .padding(.horizontal, 12).frame(height: 46)
                .background(BusinessDesign.secondarySurface, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value.isEmpty ? "—" : value).multilineTextAlignment(.trailing).fontWeight(.semibold)
        }
        .font(.subheadline)
    }

    private func statusBadge(_ status: TripStatus) -> some View {
        Text(status.title).padding(.horizontal, 10).padding(.vertical, 6).background(BusinessDesign.secondarySurface, in: Capsule())
    }

    private func shortDate(_ value: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        return date?.formatted(.dateTime.day().month(.abbreviated).hour().minute()) ?? value
    }

    @MainActor private func load() async {
        loading = true
        do {
            let value = try await APIClient.shared.bookingDetail(id: bookingID)
            detail = value
            if let operation = value.operation {
                status = operation.tripStatus
                paymentStatus = operation.paymentStatus
                confirmationNumber = operation.confirmationNumber
                internalNotes = operation.internalNotes
            }
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
        loading = false
    }

    @MainActor private func save() async {
        saving = true
        do {
            detail = try await APIClient.shared.updateBookingOperation(id: bookingID, status: status, paymentStatus: paymentStatus, confirmationNumber: confirmationNumber, internalNotes: internalNotes)
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
        saving = false
    }
}

private struct FlightEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let bookingID: String
    let direction: BookingFlightDirection
    let current: BookingFlight?
    let fallbackDate: String
    let onSaved: (BookingFlight) -> Void

    @State private var flightNumber = ""
    @State private var date = Date()
    @State private var verification: FlightVerificationResponse?
    @State private var selectedCandidateID: String?
    @State private var verifying = false
    @State private var saving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(direction.title).font(.largeTitle.bold())
                        Text("Введите номер и дату. Изменение нельзя подтвердить, пока AeroDataBox не найдёт этот рейс.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("НОМЕР РЕЙСА").font(.caption2.bold()).tracking(1.4).foregroundStyle(.secondary)
                        TextField("Например HY 721", text: $flightNumber)
                            .textInputAutocapitalization(.characters).autocorrectionDisabled()
                            .font(.title3.bold()).padding(.horizontal, 14).frame(height: 54)
                            .background(BusinessDesign.secondarySurface, in: RoundedRectangle(cornerRadius: 17, style: .continuous))

                        DatePicker("Дата вылета", selection: $date, displayedComponents: .date)
                            .datePickerStyle(.compact).fontWeight(.semibold)
                    }
                    .padding(18).businessCard(radius: 26)

                    Button {
                        Task { await verify() }
                    } label: {
                        HStack { if verifying { ProgressView().tint(.white) }; Text(verifying ? "Проверяем…" : "Проверить рейс") }
                            .font(.headline).frame(maxWidth: .infinity).frame(height: 56).background(Color.black, in: Capsule()).foregroundStyle(.white)
                    }
                    .buttonStyle(.plain).disabled(verifying || flightNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if let verification {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Label("Рейс найден", systemImage: "checkmark.seal.fill").foregroundStyle(.green).font(.headline)
                                Spacer()
                                Text(verification.cached ? "Кэш" : "AeroDataBox").font(.caption.bold()).foregroundStyle(.secondary)
                            }
                            ForEach(verification.candidates) { candidate in
                                Button { selectedCandidateID = candidate.id } label: {
                                    candidateCard(candidate, selected: selectedCandidateID == candidate.id)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    if let errorMessage {
                        Text(errorMessage).font(.footnote).foregroundStyle(.red).padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Color.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
                    }

                    if let verification, selectedCandidateID != nil {
                        Button {
                            Task { await save(verification) }
                        } label: {
                            HStack { if saving { ProgressView().tint(.white) }; Text(saving ? "Сохраняю…" : "Подтвердить изменение") }
                                .font(.headline).frame(maxWidth: .infinity).frame(height: 58).background(Color.green, in: Capsule()).foregroundStyle(.white)
                        }
                        .buttonStyle(.plain).disabled(saving)
                    }
                }
                .padding(18)
            }
            .background(Color.white)
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Закрыть") { dismiss() } }
            }
            .onAppear { prepare() }
        }
    }

    private func candidateCard(_ candidate: FlightVerificationCandidate, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(candidate.flightNumber).font(.title3.bold()).foregroundStyle(.primary)
                    Text(candidate.airlineName.isEmpty ? "Авиакомпания" : candidate.airlineName).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.title2).foregroundStyle(selected ? .green : .secondary)
            }
            HStack {
                Text(candidate.departureAirportIATA.nonEmpty ?? candidate.departureAirportICAO).font(.title2.bold())
                Spacer(); Image(systemName: "airplane").foregroundStyle(.secondary); Spacer()
                Text(candidate.arrivalAirportIATA.nonEmpty ?? candidate.arrivalAirportICAO).font(.title2.bold())
            }
            HStack {
                Text(String(candidate.scheduledDepartureLocal.prefix(16))).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !candidate.status.isEmpty { Text(candidate.status).font(.caption.bold()).foregroundStyle(.secondary) }
            }
        }
        .padding(16)
        .background(selected ? Color.green.opacity(0.07) : BusinessDesign.secondarySurface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(selected ? Color.green.opacity(0.45) : Color.clear, lineWidth: 1))
    }

    private func prepare() {
        if flightNumber.isEmpty { flightNumber = current?.flightNumber ?? "" }
        let source = current?.scheduledDepartureLocal.nonEmpty ?? fallbackDate
        if let parsed = parseDate(source) { date = parsed }
    }

    private func parseDate(_ value: String) -> Date? {
        let raw = String(value.prefix(10))
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: raw)
    }

    @MainActor private func verify() async {
        verifying = true; errorMessage = nil; verification = nil; selectedCandidateID = nil
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        do {
            let value = try await APIClient.shared.verifyFlight(number: flightNumber, dateLocal: formatter.string(from: date))
            verification = value
            if value.candidates.count == 1 { selectedCandidateID = value.candidates[0].id }
        } catch { errorMessage = friendlyFlightError(error) }
        verifying = false
    }

    @MainActor private func save(_ verification: FlightVerificationResponse) async {
        guard let selectedCandidateID else { return }
        saving = true; errorMessage = nil
        do {
            let value = try await APIClient.shared.saveVerifiedFlight(bookingID: bookingID, direction: direction, verificationKey: verification.verificationKey, candidateID: selectedCandidateID)
            onSaved(value); dismiss()
        } catch { errorMessage = friendlyFlightError(error) }
        saving = false
    }

    private func friendlyFlightError(_ error: Error) -> String {
        let text = error.localizedDescription
        if text.contains("FLIGHT_NOT_FOUND") { return "Рейс с таким номером в выбранную дату не найден." }
        if text.contains("AERODATABOX_QUOTA_EXCEEDED") { return "Лимит AeroDataBox на этот месяц исчерпан." }
        if text.contains("AERODATABOX_NOT_CONFIGURED") || text.contains("AERODATABOX_AUTH_FAILED") { return "AeroDataBox ещё не подключён к Cloudflare Worker." }
        return text
    }
}

private struct HotelAssignmentPicker: View {
    @Environment(\.dismiss) private var dismiss
    let bookingID: String
    let city: String
    let assignment: BookingAssignment?
    let onSaved: () -> Void
    @State private var hotels: [HotelListItem] = []
    @State private var loading = true
    @State private var savingID: String?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                ForEach(hotels.filter { $0.city.caseInsensitiveCompare(city) == .orderedSame && $0.status == "published" }) { hotel in
                    Button { Task { await select(hotel) } } label: {
                        HStack(spacing: 12) {
                            if let url = AppConfig.absoluteURL(hotel.coverImageURL) {
                                AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { BusinessDesign.secondarySurface }
                                    .frame(width: 62, height: 62).clipShape(RoundedRectangle(cornerRadius: 16))
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(hotel.name).font(.headline).foregroundStyle(.primary)
                                Text("\(hotel.stars ?? 0)★ · \(hotel.roomCount) типов номеров").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if savingID == hotel.id { ProgressView() }
                            else if (city == "Makkah" ? assignment?.makkahHotelID : assignment?.madinahHotelID) == hotel.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                        }
                    }.buttonStyle(.plain)
                }
            }
            .listStyle(.plain).navigationTitle("Отель · \(city)").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Закрыть") { dismiss() } } }
            .overlay { if loading { ProgressView() } }
            .task { await load() }
        }
    }

    @MainActor private func load() async {
        loading = true
        do { hotels = try await APIClient.shared.hotels() } catch { errorMessage = error.localizedDescription }
        loading = false
    }

    @MainActor private func select(_ hotel: HotelListItem) async {
        savingID = hotel.id
        do {
            _ = try await APIClient.shared.updateBookingAssignment(
                bookingID: bookingID,
                makkahHotelID: city == "Makkah" ? hotel.id : assignment?.makkahHotelID,
                madinahHotelID: city == "Madinah" ? hotel.id : assignment?.madinahHotelID,
                guideID: assignment?.guideID
            )
            onSaved(); dismiss()
        } catch { errorMessage = error.localizedDescription }
        savingID = nil
    }
}

private struct GuideAssignmentPicker: View {
    @Environment(\.dismiss) private var dismiss
    let bookingID: String
    let assignment: BookingAssignment?
    let onSaved: () -> Void
    @State private var guides: [BusinessTeamMember] = []
    @State private var loading = true
    @State private var savingID: String?
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            ForEach(guides.filter { $0.roleKind == "guide" && $0.active }) { guide in
                Button { Task { await select(guide) } } label: {
                    HStack(spacing: 12) {
                        Circle().fill(BusinessDesign.secondarySurface).frame(width: 56, height: 56)
                            .overlay(Text(initials(guide)).font(.headline))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(guide.displayName).font(.headline).foregroundStyle(.primary)
                            Text(guide.roleTitle.isEmpty ? "Гид iumrah" : guide.roleTitle).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if savingID == guide.id { ProgressView() }
                        else if assignment?.guideID == guide.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                    }
                }.buttonStyle(.plain)
            }
        }
        .listStyle(.plain).navigationTitle("Выбрать гида").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Закрыть") { dismiss() } } }
        .overlay { if loading { ProgressView() } }
        .task { await load() }
    }

    @MainActor private func load() async {
        loading = true
        do { guides = try await APIClient.shared.businessTeam() } catch { errorMessage = error.localizedDescription }
        loading = false
    }

    @MainActor private func select(_ guide: BusinessTeamMember) async {
        savingID = guide.id
        do {
            _ = try await APIClient.shared.updateBookingAssignment(bookingID: bookingID, makkahHotelID: assignment?.makkahHotelID, madinahHotelID: assignment?.madinahHotelID, guideID: guide.id)
            onSaved(); dismiss()
        } catch { errorMessage = error.localizedDescription }
        savingID = nil
    }

    private func initials(_ guide: BusinessTeamMember) -> String {
        let pieces = [guide.firstName, guide.lastName].filter { !$0.isEmpty }
        let result = pieces.prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        return result.isEmpty ? "i" : result
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
