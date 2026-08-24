import Foundation
import SwiftUI

struct ChatsView: View {
    @State private var threads: [ChatThread] = []
    @State private var bookings: [BookingSummary] = []
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var showNewChat = false

    var body: some View {
        List {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
            }

            ForEach(threads) { thread in
                NavigationLink {
                    ChatConversationView(booking: thread.booking)
                } label: {
                    threadRow(thread)
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }

            if threads.isEmpty && !loading {
                ContentUnavailableView(
                    "Чатов пока нет",
                    systemImage: "message",
                    description: Text("Откройте чат из существующей брони или создайте новый диалог.")
                )
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(BusinessDesign.background)
        .navigationTitle("Чаты")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showNewChat = true } label: {
                    Image(systemName: "square.and.pencil")
                }
                .disabled(bookings.isEmpty)
            }
        }
        .overlay { if loading { ProgressView() } }
        .task { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $showNewChat) {
            NavigationStack {
                NewChatBookingPicker(bookings: bookings)
            }
        }
    }

    private func threadRow(_ thread: ChatThread) -> some View {
        HStack(spacing: 13) {
            ZStack {
                Circle().fill(BusinessDesign.secondarySurface)
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.black.opacity(0.72))
            }
            .frame(width: 54, height: 54)

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(thread.booking.id)
                        .font(.subheadline.bold())
                        .lineLimit(1)
                    Spacer()
                    if thread.unreadForStaff {
                        Circle().fill(.black).frame(width: 8, height: 8)
                    }
                }
                Text(thread.lastMessagePreview.isEmpty ? "Нет сообщений" : thread.lastMessagePreview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text("\(thread.booking.originCode) → \(thread.booking.outboundDestination) · \(thread.booking.travelerCount) чел.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 8)
    }

    private func load() async {
        loading = true
        errorMessage = nil
        do {
            async let chatThreadsRequest = APIClient.shared.businessChatThreads()
            async let bookingsRequest = APIClient.shared.bookings()
            let cloudThreads = try await chatThreadsRequest
            let resolvedBookings = try await bookingsRequest
            bookings = resolvedBookings
            let bookingsByID = Dictionary(resolvedBookings.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            threads = cloudThreads.compactMap { cloud in
                guard let booking = bookingsByID[cloud.bookingID] else { return nil }
                return ChatThread(
                    booking: booking,
                    lastMessageAt: cloud.lastMessageAt,
                    lastMessagePreview: cloud.lastMessagePreview,
                    lastSenderType: cloud.lastSenderType,
                    unreadForStaff: cloud.unreadForStaff
                )
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }
}

private struct NewChatBookingPicker: View {
    @Environment(\.dismiss) private var dismiss
    let bookings: [BookingSummary]

    var body: some View {
        List(bookings) { booking in
            NavigationLink {
                ChatConversationView(booking: booking)
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(booking.id).font(.subheadline.bold())
                    Text("\(booking.originCode) → \(booking.outboundDestination) · \(booking.startDate)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 5)
            }
        }
        .navigationTitle("Новый чат")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Готово") { dismiss() }
            }
        }
    }
}

struct ChatConversationView: View {
    let booking: BookingSummary

    @State private var messages: [BusinessChatMessage] = []
    @State private var draft = ""
    @State private var loading = true
    @State private var sending = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    bookingContext

                    if loading && messages.isEmpty {
                        ProgressView().padding(.top, 40)
                    } else if messages.isEmpty {
                        Text("Начните диалог. Сообщения сохраняются в iumrah Business Cloud.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 34)
                            .padding(.top, 36)
                    }

                    ForEach(messages) { message in
                        messageBubble(message)
                            .id(message.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 18)
            }
            .background(Color.white)
            .onChange(of: messages.count) { _, _ in
                guard let last = messages.last else { return }
                withAnimation(.easeOut(duration: 0.22)) { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
        .safeAreaInset(edge: .bottom) { composer }
        .navigationTitle(booking.id)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await reload()
            await poll()
        }
    }

    private var bookingContext: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.2.fill")
            VStack(alignment: .leading, spacing: 2) {
                Text("\(booking.travelerCount) путешественников")
                    .font(.caption.bold())
                Text("\(booking.originCode) → \(booking.outboundDestination) · \(booking.startDate)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(BusinessDesign.secondarySurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder
    private func messageBubble(_ message: BusinessChatMessage) -> some View {
        HStack {
            if message.isStaff { Spacer(minLength: 56) }
            VStack(alignment: message.isStaff ? .trailing : .leading, spacing: 4) {
                Text(message.body)
                    .font(.body)
                    .foregroundStyle(message.isStaff ? .white : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(timeLabel(message.createdAt))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(message.isStaff ? .white.opacity(0.64) : .secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                message.isStaff ? Color.black : BusinessDesign.secondarySurface,
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
            if !message.isStaff { Spacer(minLength: 56) }
        }
    }

    private var composer: some View {
        VStack(spacing: 6) {
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
            }

            HStack(alignment: .bottom, spacing: 10) {
                TextField("Сообщение", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(Color.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 21, style: .continuous))

                Button { send() } label: {
                    Group {
                        if sending {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 17, weight: .bold))
                        }
                    }
                    .frame(width: 42, height: 42)
                    .foregroundStyle(.white)
                    .background(.black, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(8)
            .businessGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .background(.clear)
    }

    private func reload() async {
        do {
            let value = try await APIClient.shared.businessChatMessages(bookingID: booking.id)
            messages = value
            _ = try? await APIClient.shared.markBusinessChatRead(bookingID: booking.id)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }

    private func poll() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !sending else { continue }
            if let value = try? await APIClient.shared.businessChatMessages(bookingID: booking.id), value != messages {
                messages = value
                _ = try? await APIClient.shared.markBusinessChatRead(bookingID: booking.id)
            }
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        sending = true
        errorMessage = nil
        let clientMessageID = UUID().uuidString
        Task { @MainActor in
            do {
                let message = try await APIClient.shared.sendBusinessChatMessage(
                    bookingID: booking.id,
                    body: text,
                    clientMessageID: clientMessageID
                )
                if !messages.contains(where: { $0.id == message.id }) { messages.append(message) }
            } catch {
                draft = text
                errorMessage = error.localizedDescription
            }
            sending = false
        }
    }

    private func timeLabel(_ value: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: value) else { return "" }
        return date.formatted(date: .omitted, time: .shortened)
    }
}
