import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit

struct BookingCheckoutAdminCard: View {
    let bookingID: String
    let status: TripStatus
    let checkout: BusinessCheckout?
    let onReload: () -> Void

    @State private var visaCard = ""
    @State private var visaHolder = ""
    @State private var humoCard = ""
    @State private var humoHolder = ""
    @State private var instructions = ""
    @State private var paymePhoto: PhotosPickerItem?
    @State private var saving = false
    @State private var error: String?
    @State private var showDocumentImporter = false
    @State private var documentKind = "visa"
    @State private var imagePreview: BusinessImagePreview?
    @State private var previewLoadingID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "creditcard.and.123")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .background(BusinessDesign.secondarySurface, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Оплата и данные паломников")
                        .font(.title3.bold())
                    Text("Реквизиты этой поездки, iumrah ID и готовность анкет.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            if let checkout {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        readinessPill(title: "Iumrah ID \(checkout.iumrahID)", ready: checkout.accountActive, icon: "person.crop.circle.badge.checkmark")
                        readinessPill(title: "Анкеты \(checkout.travelers.filter(\.completed).count)/\(checkout.travelers.count)", ready: checkout.allTravelersComplete, icon: "person.text.rectangle")
                        readinessPill(title: "Чек \(checkout.receipts.isEmpty ? "—" : "✓")", ready: !checkout.receipts.isEmpty, icon: "doc.text.image")
                    }
                    VStack(spacing: 8) {
                        HStack(spacing: 8) {
                            readinessPill(title: "Iumrah ID \(checkout.iumrahID)", ready: checkout.accountActive, icon: "person.crop.circle.badge.checkmark")
                            readinessPill(title: "Анкеты \(checkout.travelers.filter(\.completed).count)/\(checkout.travelers.count)", ready: checkout.allTravelersComplete, icon: "person.text.rectangle")
                        }
                        readinessPill(title: "Чек \(checkout.receipts.isEmpty ? "—" : "✓")", ready: !checkout.receipts.isEmpty, icon: "doc.text.image")
                    }
                }

                travelerSummary(checkout)

                if status == .availabilityCheck || status == .paymentPending {
                    paymentEditor(checkout)
                } else {
                    paymentSummary(checkout)
                }

                if !checkout.receipts.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Чеки оплаты").font(.headline)
                        ForEach(checkout.receipts) { receipt in
                            Button {
                                Task { await openPrivateImage(path: receipt.mediaURL, id: "receipt-\(receipt.id)", title: "Чек · \(paymentMethod(receipt.paymentMethod))") }
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "doc.text.image.fill")
                                        .frame(width: 38, height: 38)
                                        .background(BusinessDesign.secondarySurface, in: RoundedRectangle(cornerRadius: 12))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(paymentMethod(receipt.paymentMethod)).font(.subheadline.bold()).foregroundStyle(.primary)
                                        Text(receipt.reviewStatus == "approved" ? "Проверен" : receipt.reviewStatus == "rejected" ? "Отклонён" : "Ожидает проверки")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if previewLoadingID == "receipt-\(receipt.id)" { ProgressView() }
                                    else { Image(systemName: "arrow.up.right").font(.caption.bold()).foregroundStyle(.tertiary) }
                                }
                                .padding(11)
                                .background(BusinessDesign.secondarySurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Divider()
                documentsSection(checkout)
            } else {
                Text("Checkout появится после синхронизации поездки.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(18)
        .businessCard(radius: 28)
        .onAppear { loadDraft() }
        .onChange(of: checkout?.payment) { _, _ in loadDraft() }
        .onChange(of: paymePhoto) { _, item in
            guard let item else { return }
            Task { await uploadQR(item) }
        }
        .sheet(item: $imagePreview) { preview in
            NavigationStack {
                ScrollView([.horizontal, .vertical]) {
                    Image(uiImage: preview.image)
                        .resizable()
                        .scaledToFit()
                        .padding(16)
                }
                .background(Color.black.opacity(0.96))
                .navigationTitle(preview.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { imagePreview = nil } } }
            }
        }
        .fileImporter(
            isPresented: $showDocumentImporter,
            allowedContentTypes: [.pdf, .jpeg, .png],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task { await uploadDocument(url) }
        }
    }

    private func travelerSummary(_ checkout: BusinessCheckout) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Паломники")
                .font(.headline)

            ForEach(checkout.travelers) { traveler in
                VStack(alignment: .leading, spacing: 11) {
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: traveler.completed ? "checkmark.circle.fill" : "person.crop.circle.badge.exclamationmark")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(traveler.completed ? .green : .secondary)
                            .frame(width: 40, height: 40)
                            .background(Color.white.opacity(0.82), in: RoundedRectangle(cornerRadius: 13, style: .continuous))

                        VStack(alignment: .leading, spacing: 3) {
                            let fullName = [traveler.firstName, traveler.middleName, traveler.lastName]
                                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                                .joined(separator: " ")
                            Text(fullName.isEmpty ? "Паломник \(traveler.position)" : fullName)
                                .font(.subheadline.bold())
                                .lineLimit(2)

                            Text("Паломник \(traveler.position) · \(travelerTypeTitle(traveler.travelerType))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 8)

                        if let path = traveler.passportMediaURL {
                            Button {
                                Task {
                                    await openPrivateImage(
                                        path: path,
                                        id: "passport-\(traveler.position)",
                                        title: "Паспорт · \(traveler.position)"
                                    )
                                }
                            } label: {
                                Group {
                                    if previewLoadingID == "passport-\(traveler.position)" {
                                        ProgressView()
                                    } else {
                                        Image(systemName: "passport.fill")
                                            .font(.system(size: 15, weight: .semibold))
                                    }
                                }
                                .frame(width: 40, height: 40)
                                .background(Color.white, in: Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Открыть паспорт паломника \(traveler.position)")
                        }
                    }

                    HStack(spacing: 6) {
                        Image(systemName: traveler.completed ? "checkmark.seal.fill" : "clock.fill")
                            .foregroundStyle(traveler.completed ? .green : .secondary)
                        Text(traveler.completed ? "Анкета заполнена" : "Ожидает данные и паспорт")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(traveler.completed ? .primary : .secondary)
                    }

                    if traveler.completed {
                        Divider().opacity(0.55)

                        VStack(spacing: 8) {
                            travelerDetailRow("Дата рождения", value: traveler.dateOfBirth)
                            travelerDetailRow("Гражданство", value: traveler.nationality)
                            travelerDetailRow("Паспорт", value: traveler.passportNumber)
                            travelerDetailRow("Действует до", value: traveler.passportExpiryDate)
                            travelerDetailRow("Телефон", value: traveler.phone)
                        }
                    }
                }
                .padding(13)
                .background(BusinessDesign.secondarySurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
    }

    private func travelerDetailRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value.isEmpty ? "—" : value)
                .font(.caption.weight(.semibold))
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
    }

    private func travelerTypeTitle(_ raw: String) -> String {
        switch raw.lowercased() {
        case "child": return "ребёнок"
        case "infant": return "младенец"
        default: return "взрослый"
        }
    }

    @ViewBuilder
    private func paymentEditor(_ checkout: BusinessCheckout) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Реквизиты для клиента").font(.headline)
            if status == .availabilityCheck {
                Label("Сначала сохраните хотя бы один способ оплаты. После этого можно перевести поездку в «Оплата и данные».", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .background(BusinessDesign.secondarySurface, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            }

            paymentField(title: "Visa · номер карты", text: $visaCard, icon: "creditcard")
            paymentField(title: "Visa · получатель", text: $visaHolder, icon: "person")

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("PayMe QR").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    PhotosPicker(selection: $paymePhoto, matching: .images) {
                        HStack {
                            Image(systemName: checkout.payment.hasPaymeQR ? "checkmark.circle.fill" : "qrcode.viewfinder")
                            Text(checkout.payment.hasPaymeQR ? "QR загружен · заменить" : "Загрузить QR")
                            Spacer()
                        }
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .frame(height: 48)
                        .background(BusinessDesign.secondarySurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }

            paymentField(title: "Humo · номер карты", text: $humoCard, icon: "creditcard")
            paymentField(title: "Humo · получатель", text: $humoHolder, icon: "person")

            VStack(alignment: .leading, spacing: 7) {
                Text("Инструкция паломнику").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                TextField("Например: после оплаты прикрепите чек ниже", text: $instructions, axis: .vertical)
                    .lineLimit(2...5)
                    .padding(13)
                    .background(BusinessDesign.secondarySurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }

            Button {
                Task { await savePayment() }
            } label: {
                HStack {
                    if saving { ProgressView().tint(.white) }
                    Image(systemName: "checkmark")
                    Text("Сохранить реквизиты")
                    Spacer()
                }
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(height: 52)
                .background(Color.black, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(saving)
        }
    }

    private func paymentSummary(_ checkout: BusinessCheckout) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Реквизиты").font(.headline)
            compactRow("Visa", checkout.payment.visaCardNumber)
            compactRow("PayMe", checkout.payment.hasPaymeQR ? "QR загружен" : "—")
            compactRow("Humo", checkout.payment.humoCardNumber)
        }
    }

    private func documentsSection(_ checkout: BusinessCheckout) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Документы поездки").font(.headline)
                    Text("Виза, ваучер или другой PDF появится в Beta.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }

            if !checkout.documents.isEmpty {
                ForEach(checkout.documents) { document in
                    HStack {
                        Image(systemName: document.contentType == "application/pdf" ? "doc.richtext.fill" : "photo.fill")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(document.title).font(.subheadline.bold())
                            Text(documentKindTitle(document.documentKind)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
            }

            if status == .bookingConfirmed || status == .readyToTravel {
                Picker("Тип", selection: $documentKind) {
                    Text("Виза").tag("visa")
                    Text("Ваучер").tag("voucher")
                    Text("Страховка").tag("insurance")
                    Text("Билет").tag("ticket")
                    Text("Другое").tag("other")
                }
                .pickerStyle(.segmented)

                Button {
                    showDocumentImporter = true
                } label: {
                    Label("Добавить PDF / изображение", systemImage: "plus.circle.fill")
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(BusinessDesign.secondarySurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func readinessPill(title: String, ready: Bool, icon: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: ready ? "checkmark.circle.fill" : icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(ready ? .green : .secondary)
            Text(title).font(.caption2.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(BusinessDesign.secondarySurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func paymentField(title: String, text: Binding<String>, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundStyle(.secondary)
                TextField(title, text: text).textInputAutocapitalization(.never)
            }
            .padding(.horizontal, 13).frame(height: 48)
            .background(BusinessDesign.secondarySurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func compactRow(_ title: String, _ value: String) -> some View {
        HStack { Text(title).foregroundStyle(.secondary); Spacer(); Text(value.isEmpty ? "—" : value).fontWeight(.semibold).textSelection(.enabled) }
            .font(.subheadline)
    }

    private func loadDraft() {
        guard let p = checkout?.payment else { return }
        visaCard = p.visaCardNumber; visaHolder = p.visaHolder
        humoCard = p.humoCardNumber; humoHolder = p.humoHolder
        instructions = p.instructions
    }

    @MainActor private func savePayment() async {
        saving = true; error = nil
        do {
            _ = try await APIClient.shared.savePaymentInstructions(
                bookingID: bookingID,
                payload: BusinessPaymentInstructionsPayload(visaCardNumber: visaCard, visaHolder: visaHolder, humoCardNumber: humoCard, humoHolder: humoHolder, instructions: instructions)
            )
            onReload()
        } catch { self.error = error.localizedDescription }
        saving = false
    }

    @MainActor private func uploadQR(_ item: PhotosPickerItem) async {
        saving = true; error = nil
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { throw URLError(.cannotDecodeContentData) }
            let contentType = item.supportedContentTypes.first?.preferredMIMEType ?? "image/jpeg"
            try await APIClient.shared.uploadPaymeQR(bookingID: bookingID, data: data, contentType: contentType)
            onReload()
        } catch { self.error = error.localizedDescription }
        saving = false
    }

    @MainActor private func uploadDocument(_ url: URL) async {
        saving = true; error = nil
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let contentType = url.pathExtension.lowercased() == "pdf" ? "application/pdf" : url.pathExtension.lowercased() == "png" ? "image/png" : "image/jpeg"
            let title = documentKindTitle(documentKind)
            try await APIClient.shared.uploadTravelDocument(bookingID: bookingID, kind: documentKind, title: title, data: data, contentType: contentType)
            onReload()
        } catch { self.error = error.localizedDescription }
        saving = false
    }

    @MainActor private func openPrivateImage(path: String, id: String, title: String) async {
        previewLoadingID = id; error = nil
        defer { previewLoadingID = nil }
        do {
            let data = try await APIClient.shared.privateMedia(path: path)
            guard let image = UIImage(data: data) else { throw URLError(.cannotDecodeContentData) }
            imagePreview = BusinessImagePreview(id: id, title: title, image: image)
        } catch { self.error = error.localizedDescription }
    }

    private func paymentMethod(_ value: String) -> String {
        switch value { case "visa": return "Visa"; case "payme": return "PayMe"; case "humo": return "Humo"; default: return "Оплата" }
    }
    private func documentKindTitle(_ value: String) -> String {
        switch value { case "visa": return "Виза"; case "voucher": return "Ваучер"; case "insurance": return "Страховка"; case "ticket": return "Билет"; default: return "Документ поездки" }
    }
}

private struct BusinessImagePreview: Identifiable {
    let id: String
    let title: String
    let image: UIImage
}
