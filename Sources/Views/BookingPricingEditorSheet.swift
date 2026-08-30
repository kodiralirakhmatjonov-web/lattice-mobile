import Foundation
import SwiftUI

struct BookingPricingEditorSheet: View {
    let bookingID: String
    let report: BookingPricingReport
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var amounts: [String: String]
    @State private var markupPercent: String
    @State private var feePercent: String
    @State private var saving = false
    @State private var errorMessage: String?

    init(bookingID: String, report: BookingPricingReport, onSaved: @escaping () -> Void) {
        self.bookingID = bookingID
        self.report = report
        self.onSaved = onSaved
        _amounts = State(initialValue: Dictionary(uniqueKeysWithValues: report.components.map { ($0.code, Self.number($0.supplierCostUsd)) }))
        _markupPercent = State(initialValue: Self.number(report.totals.markupRate * 100))
        _feePercent = State(initialValue: Self.number(report.totals.paymentFeeRate * 100))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Цена пакета")
                        .font(.system(size: 31, weight: .bold, design: .rounded))
                    Text("Измените себестоимость любого компонента. Итог пересчитывается сразу и после сохранения синхронизируется с бронированием паломника.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 0) {
                    ForEach(Array(report.components.enumerated()), id: \.element.code) { index, component in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(component.label).font(.subheadline.weight(.semibold))
                                Text(component.code).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                            }
                            Spacer(minLength: 12)
                            HStack(spacing: 5) {
                                Text("$").foregroundStyle(.secondary)
                                TextField("0", text: binding(for: component.code))
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 105)
                            }
                            .font(.headline.monospacedDigit())
                        }
                        .padding(.vertical, 14)
                        if index < report.components.count - 1 { Divider() }
                    }
                }
                .padding(.horizontal, 16)
                .businessCard(radius: 26)

                VStack(spacing: 12) {
                    percentRow("Наценка", text: $markupPercent)
                    Divider()
                    percentRow("Комиссия оплаты", text: $feePercent)
                }
                .padding(16)
                .businessCard(radius: 26)

                VStack(alignment: .leading, spacing: 11) {
                    totalRow("Себестоимость", supplierTotal)
                    totalRow("Расчёт до округления", calculatedSelling)
                    Divider()
                    totalRow("Итого клиенту", publicTotal, emphasized: true)
                    totalRow("На паломника", publicPerPilgrim, emphasized: true)
                    Text("\(travelerCount) паломник(а) · округление по $5 на человека")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(18)
                .businessCard(radius: 28)

                if let errorMessage {
                    Text(errorMessage).font(.footnote).foregroundStyle(.red)
                }

                Button {
                    Task { await save() }
                } label: {
                    HStack {
                        if saving { ProgressView().tint(.white) }
                        Text("Сохранить новую цену")
                        Spacer()
                        Image(systemName: "checkmark")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.black)
                .controlSize(.large)
                .disabled(saving || parsedComponents == nil)
            }
            .padding(18)
            .padding(.bottom, 24)
        }
        .background(Color.white)
        .navigationTitle("Редактор цены")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button("Закрыть") { dismiss() } }
        }
    }

    private var travelerCount: Int {
        max(1, report.context.travelers.adults + report.context.travelers.children + report.context.travelers.infants)
    }

    private var markupRate: Double { max(0, (Double(markupPercent.replacingOccurrences(of: ",", with: ".")) ?? 0) / 100) }
    private var feeRate: Double { min(0.49, max(0, (Double(feePercent.replacingOccurrences(of: ",", with: ".")) ?? 0) / 100)) }
    private var supplierTotal: Double { parsedComponents?.reduce(0) { $0 + $1.supplierCostUsd } ?? 0 }
    private var calculatedSelling: Double { (supplierTotal * (1 + markupRate)) / max(0.51, 1 - feeRate) }
    private var publicPerPilgrim: Double { max(5, (calculatedSelling / Double(travelerCount) / 5).rounded() * 5) }
    private var publicTotal: Double { publicPerPilgrim * Double(travelerCount) }

    private var parsedComponents: [BookingPricingComponent]? {
        var output: [BookingPricingComponent] = []
        for component in report.components {
            let raw = (amounts[component.code] ?? "").replacingOccurrences(of: ",", with: ".")
            guard let value = Double(raw), value >= 0 else { return nil }
            output.append(.init(code: component.code, label: component.label, supplierCostUsd: value))
        }
        return output
    }

    private func binding(for code: String) -> Binding<String> {
        Binding(get: { amounts[code] ?? "" }, set: { amounts[code] = $0 })
    }

    private func percentRow(_ title: String, text: Binding<String>) -> some View {
        HStack {
            Text(title).font(.subheadline.weight(.semibold))
            Spacer()
            TextField("0", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
            Text("%").foregroundStyle(.secondary)
        }
    }

    private func totalRow(_ title: String, _ value: Double, emphasized: Bool = false) -> some View {
        HStack {
            Text(title).font(emphasized ? .headline : .subheadline)
            Spacer()
            Text(value, format: .currency(code: report.currency).precision(.fractionLength(0...2)))
                .font(emphasized ? .headline : .subheadline)
                .fontWeight(.bold)
                .monospacedDigit()
        }
    }

    @MainActor
    private func save() async {
        guard let components = parsedComponents else { return }
        saving = true
        defer { saving = false }
        do {
            _ = try await APIClient.shared.saveBookingPricing(
                bookingID: bookingID,
                components: components,
                markupRate: markupRate,
                paymentFeeRate: feeRate
            )
            errorMessage = nil
            onSaved()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static func number(_ value: Double) -> String {
        if value.rounded() == value { return String(Int(value)) }
        return String(format: "%.2f", value)
    }
}
