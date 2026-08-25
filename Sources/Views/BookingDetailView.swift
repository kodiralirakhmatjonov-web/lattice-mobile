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

    var body: some View {
        ScrollView {
            if let detail {
                VStack(alignment: .leading, spacing: 16) {
                    hero(detail)
                    operationsCard(detail)
                    itineraryCard(detail.booking)
                    pricingCard(detail)
                    requestDetailsCard(detail)
                }
                .padding(18)
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
    }

    private func hero(_ detail: BookingDetailResponse) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(detail.booking.clientName ?? detail.pilgrim?.displayName ?? "Паломник")
                        .font(.system(size: 30, weight: .bold, design: .rounded)).tracking(-1)
                    Text(detail.pilgrim?.id ?? detail.booking.pilgrimID ?? bookingID)
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                Text(detail.booking.totalUsd, format: .currency(code: "USD").precision(.fractionLength(0)))
                    .font(.title3.bold())
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
            Picker("Статус", selection: $status) {
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

            if let operation = detail.operation {
                HStack {
                    Text("Trip ID").foregroundStyle(.secondary)
                    Spacer()
                    Text(operation.tripID).font(.caption.monospaced()).textSelection(.enabled)
                }
                .font(.caption)
            }
            if !detail.statusHistory.isEmpty {
                DisclosureGroup("История статусов") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(detail.statusHistory.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .top) {
                                Text(TripStatus(rawValue: item.newStatus)?.title ?? item.newStatus)
                                    .font(.caption.weight(.semibold))
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

    private func itineraryCard(_ booking: BookingSummary) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Что выбрал пользователь", systemImage: "map").font(.title2.bold())
            detailRow("Маршрут", "\(booking.originCode) → \(booking.outboundDestination)")
            detailRow("Обратно", booking.returnOrigin)
            detailRow("Даты", "\(booking.startDate) – \(booking.endDate)")
            detailRow("Рейс", booking.flightName)
            detailRow("Makkah", booking.makkahHotel)
            detailRow("Madinah", booking.madinahHotel)
            detailRow("Паломников", "\(booking.travelerCount)")
            detailRow("Комнат", "\(booking.rooms)")
            detailRow("На человека", booking.perPilgrimUsd.formatted(.currency(code: "USD")))
        }
        .padding(18).businessCard(radius: 28)
    }

    private func pricingCard(_ detail: BookingDetailResponse) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Pricing under the hood", systemImage: "sum").font(.title2.bold())
            Text("Снимок расчёта прикреплён к этой поездке. Клиент его не видит.")
                .font(.caption).foregroundStyle(.secondary)

            if detail.pricingLines.isEmpty {
                detailRow("Итого", detail.booking.totalUsd.formatted(.currency(code: "USD")))
                detailRow("На паломника", detail.booking.perPilgrimUsd.formatted(.currency(code: "USD")))
                Text("Текущая заявка не передала детальный pricingSnapshot. Новому клиентскому приложению нужно отправлять его при создании брони.")
                    .font(.caption).foregroundStyle(.secondary)
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
                    if index < groups.count - 1 { Divider() }
                }
            }
        }
        .padding(18).businessCard(radius: 28)
    }

    private func requestDetailsCard(_ detail: BookingDetailResponse) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Все данные заявки", systemImage: "doc.text.magnifyingglass").font(.title2.bold())
            Text("Исходный booking snapshot хранится один раз внутри Trip ID, чтобы не разбрасывать данные по D1.")
                .font(.caption).foregroundStyle(.secondary)

            let groups = groupedFields(detail.requestFields)
            ForEach(Array(groups.enumerated()), id: \.offset) { _, entry in
                DisclosureGroup(entry.0) {
                    VStack(spacing: 9) {
                        ForEach(entry.1) { field in
                            HStack(alignment: .top, spacing: 12) {
                                Text(field.label).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                                Text(field.value).multilineTextAlignment(.trailing).frame(maxWidth: .infinity, alignment: .trailing).textSelection(.enabled)
                            }
                            .font(.caption)
                        }
                    }
                    .padding(.top, 9)
                }
                .font(.subheadline.weight(.semibold))
                Divider()
            }
        }
        .padding(18).businessCard(radius: 28)
    }

    private func groupedPricing(_ lines: [BookingPricingLine]) -> [(String, [BookingPricingLine])] {
        Dictionary(grouping: lines, by: \.group).sorted { $0.key < $1.key }
    }

    private func groupedFields(_ fields: [BookingRequestField]) -> [(String, [BookingRequestField])] {
        Dictionary(grouping: fields, by: \.group).sorted { $0.key < $1.key }
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
