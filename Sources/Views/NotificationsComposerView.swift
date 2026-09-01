import Foundation
import SwiftUI

struct NotificationsComposerView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var message = ""
    @State private var audience: BusinessNotificationAudience = .all
    @State private var destination: BusinessNotificationDestination = .home
    @State private var destinationBookingID = ""
    @State private var audienceCounts: BusinessNotificationAudienceCounts?
    @State private var history: [BusinessClientNotification] = []
    @State private var isLoading = true
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var successMessage: String?
    @State private var showConfirmation = false

    private var canSend: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (destination != .booking || !destinationBookingID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) &&
        !isSending
    }

    private var selectedAudienceCount: Int {
        audienceCounts?.count(for: audience) ?? 0
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                header
                signalPreview
                copyEditor
                audiencePicker
                destinationPicker
                sendPanel
                historySection
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 44)
        }
        .background(BusinessDesign.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task { await reload() }
        .refreshable { await reload() }
        .confirmationDialog(
            "Отправить iumrah Signal?",
            isPresented: $showConfirmation,
            titleVisibility: .visible
        ) {
            Button("Отправить \(selectedAudienceCount) получателям") {
                Task { await send() }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Push будет отправлен сразу, а карточка останется на главной странице до 14 дней.")
        }
        .alert("iumrah Signal отправлен", isPresented: Binding(
            get: { successMessage != nil },
            set: { if !$0 { successMessage = nil } }
        )) {
            Button("Готово", role: .cancel) {}
        } message: {
            Text(successMessage ?? "")
        }
        .alert("Не удалось отправить", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Создать уведомление")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("iumrah Signal · системное сообщение клиентам")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 42, height: 42)
                    .businessGlass(in: Circle())
            }
            .buttonStyle(.plain)
        }
    }

    private var signalPreview: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Label("iumrah Signal", systemImage: "bell.badge.fill")
                    .font(.caption.weight(.bold))
                    .tracking(0.45)
                Spacer()
                Text("PREVIEW")
                    .font(.caption2.weight(.black))
                    .padding(.horizontal, 9)
                    .frame(height: 22)
                    .background(Color.white.opacity(0.9), in: Capsule())
                    .foregroundStyle(Color(red: 0.055, green: 0.30, blue: 0.18))
            }

            Text(title.isEmpty ? "Важное обновление для вашей поездки" : title)
                .font(.system(size: 21, weight: .bold, design: .rounded))
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(2)

            Text(message.isEmpty ? "Сообщение будет показано как push и как заметная карточка на главной странице iumrah." : message)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.84))
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(3)

            HStack(spacing: 8) {
                Label(destination.title, systemImage: destination.icon)
                    .font(.caption.weight(.semibold))
                Spacer()
                HStack(spacing: 6) {
                    Text("Открыть")
                        .font(.caption.weight(.bold))
                    Image(systemName: "arrow.up.right")
                        .font(.caption.weight(.bold))
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background {
            LinearGradient(
                colors: [
                    Color(red: 0.040, green: 0.255, blue: 0.150),
                    Color(red: 0.090, green: 0.430, blue: 0.235),
                    Color(red: 0.340, green: 0.630, blue: 0.450)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.12), radius: 22, y: 10)
    }

    private var copyEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Сообщение")
                .font(.title3.bold())

            TextField("Заголовок", text: $title, axis: .vertical)
                .font(.headline)
                .padding(15)
                .background(BusinessDesign.secondarySurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .onChange(of: title) { _, value in if value.count > 120 { title = String(value.prefix(120)) } }

            TextEditor(text: $message)
                .font(.body)
                .frame(minHeight: 120)
                .padding(10)
                .scrollContentBackground(.hidden)
                .background(BusinessDesign.secondarySurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .onChange(of: message) { _, value in if value.count > 600 { message = String(value.prefix(600)) } }

            HStack {
                Text("\(title.count)/120")
                Spacer()
                Text("\(message.count)/600")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(18)
        .businessCard(radius: 26)
    }

    private var audiencePicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Кому отправить")
                    .font(.title3.bold())
                Spacer()
                if let audienceCounts {
                    Text("\(audienceCounts.pushCapable) push-ready")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(BusinessNotificationAudience.allCases) { option in
                Button {
                    audience = option
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: audience == option ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 20, weight: .semibold))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(option.title).font(.headline)
                            Text(option.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(audienceCounts?.count(for: option) ?? 0)")
                            .font(.headline.monospacedDigit())
                    }
                    .foregroundStyle(.primary)
                    .padding(14)
                    .background(audience == option ? Color.black.opacity(0.065) : BusinessDesign.secondarySurface,
                                in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(18)
        .businessCard(radius: 26)
    }

    private var destinationPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Куда открыть по нажатию")
                .font(.title3.bold())

            Menu {
                ForEach(BusinessNotificationDestination.allCases) { option in
                    Button {
                        destination = option
                    } label: {
                        Label(option.title, systemImage: option.icon)
                    }
                }
            } label: {
                HStack {
                    Image(systemName: destination.icon)
                    Text(destination.title).font(.headline)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 15)
                .frame(height: 54)
                .background(BusinessDesign.secondarySurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }

            if destination == .booking {
                TextField("Booking ID", text: $destinationBookingID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                    .padding(15)
                    .background(BusinessDesign.secondarySurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                Text("Если поездка недоступна конкретному пользователю, приложение безопасно откроет вкладку «Поездки».")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .businessCard(radius: 26)
    }

    private var sendPanel: some View {
        VStack(spacing: 10) {
            Button {
                showConfirmation = true
            } label: {
                HStack {
                    if isSending { ProgressView().tint(.white) }
                    Text(isSending ? "Отправка…" : "Отправить iumrah Signal")
                    Spacer()
                    Text("\(selectedAudienceCount)")
                        .font(.caption.bold().monospacedDigit())
                        .padding(.horizontal, 9)
                        .frame(height: 26)
                        .background(Color.white.opacity(0.16), in: Capsule())
                }
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 17)
                .frame(height: 58)
                .background(Color.black, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .opacity(canSend ? 1 : 0.35)

            Text("Push отправляется сразу. Карточка iumrah Signal остаётся на главной до 14 дней.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var historySection: some View {
        if isLoading {
            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 28)
        } else if !history.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Последние отправления")
                    .font(.title3.bold())
                ForEach(history.prefix(12)) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title).font(.headline)
                                Text(item.body).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: item.status == "published" ? "checkmark.circle.fill" : "clock.fill")
                                .foregroundStyle(item.status == "published" ? Color.green : Color.secondary)
                        }
                        HStack(spacing: 10) {
                            Label("\(item.matchedDevices)", systemImage: "person.2")
                            Label("\(item.pushSentCount)", systemImage: "bell.fill")
                            Text(item.targetScope)
                            Spacer()
                            Text(item.sentAt.map(shortDate) ?? "—")
                        }
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                    .padding(15)
                    .background(BusinessDesign.secondarySurface, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
                }
            }
            .padding(18)
            .businessCard(radius: 26)
        }
    }

    private func shortDate(_ value: String) -> String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: value) else { return value }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    @MainActor
    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        async let counts = APIClient.shared.clientNotificationAudience()
        async let items = APIClient.shared.clientNotifications()
        do {
            audienceCounts = try await counts
            history = try await items
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func send() async {
        guard canSend else { return }
        isSending = true
        defer { isSending = false }
        do {
            let response = try await APIClient.shared.sendClientNotification(.init(
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                body: message.trimmingCharacters(in: .whitespacesAndNewlines),
                targetScope: audience.rawValue,
                destination: destination.rawValue,
                destinationBookingID: destination == .booking ? destinationBookingID.trimmingCharacters(in: .whitespacesAndNewlines) : nil
            ))
            successMessage = "Опубликовано для \(response.notification.matchedDevices) установок. Push доставлен на \(response.delivery.sent) устройств."
            title = ""
            message = ""
            destinationBookingID = ""
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
