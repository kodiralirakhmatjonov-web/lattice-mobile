import Foundation
import SwiftUI

struct ChatsView: View {
    @State private var threads: [ChatThread] = []
    @State private var bookings: [BookingSummary] = []
    @State private var loading = true
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Чаты")
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .tracking(-1.4)
                    Text("Переписка по бронированиям")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(BusinessDesign.secondarySurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                }

                if threads.isEmpty && !loading {
                    ContentUnavailableView(
                        "Чатов пока нет",
                        systemImage: "message",
                        description: Text("Создайте диалог по существующему бронированию.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 42)
                } else {
                    ForEach(threads) { thread in
                        NavigationLink {
                            ChatConversationView(booking: thread.booking)
                        } label: {
                            ThreadCard(thread: thread)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 14)
        }
        .contentMargins(.horizontal, 18, for: .scrollContent)
        .scrollIndicators(.hidden)
        .background(Color.white)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    NewChatBookingPicker(bookings: bookings)
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .disabled(bookings.isEmpty)
            }
        }
        .overlay { if loading { ProgressView() } }
        .task { await load() }
        .refreshable { await load() }
    }

    @MainActor
    private func load() async {
        loading = true
        errorMessage = nil
        do {
            async let chatThreadsRequest = APIClient.shared.businessChatThreads()
            async let bookingsRequest = APIClient.shared.bookings()
            let cloudThreads = try await chatThreadsRequest
            let resolvedBookings = try await bookingsRequest
            guard !Task.isCancelled else { return }
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
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }
}

private struct ThreadCard: View {
    let thread: ChatThread

    var body: some View {
        HStack(spacing: 13) {
            ZStack {
                Circle().fill(BusinessDesign.secondarySurface)
                Image(systemName: "person.fill")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.72))
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(thread.booking.id)
                        .font(.subheadline.bold())
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(chatTime(thread.lastMessageAt))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Text(thread.lastMessagePreview.isEmpty ? "Нет сообщений" : thread.lastMessagePreview)
                    .font(.subheadline)
                    .foregroundStyle(thread.unreadForStaff ? .primary : .secondary)
                    .fontWeight(thread.unreadForStaff ? .semibold : .regular)
                    .lineLimit(2)

                HStack(spacing: 5) {
                    Text("\(thread.booking.originCode) → \(thread.booking.outboundDestination)")
                    Text("·")
                    Text("\(thread.booking.travelerCount) чел.")
                    if thread.unreadForStaff {
                        Spacer()
                        Text("NEW")
                            .font(.system(size: 9, weight: .black))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .foregroundStyle(.white)
                            .background(.black, in: Capsule())
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BusinessDesign.tertiarySurface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(BusinessDesign.line, lineWidth: 1))
    }

    private func chatTime(_ value: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: value) else { return "" }
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

private struct NewChatBookingPicker: View {
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
                .padding(.vertical, 6)
            }
        }
        .listStyle(.plain)
        .navigationTitle("Новый чат")
        .navigationBarTitleDisplayMode(.inline)
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
                        ProgressView().padding(.top, 42)
                    } else if messages.isEmpty {
                        ContentUnavailableView(
                            "Начните диалог",
                            systemImage: "bubble.left.and.bubble.right",
                            description: Text("Сообщения сохраняются в iumrah Business Cloud.")
                        )
                        .padding(.top, 34)
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
            .scrollDismissesKeyboard(.interactively)
            .background(Color.white)
            .onChange(of: messages.count) { _, _ in
                guard let last = messages.last else { return }
                withAnimation(.easeOut(duration: 0.22)) { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
        .safeAreaInset(edge: .bottom) { composer }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(booking.id).font(.subheadline.bold())
                    Text("\(booking.originCode) → \(booking.outboundDestination)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task {
            await reload()
            await poll()
        }
    }

    private var bookingContext: some View {
        HStack(spacing: 11) {
            ZStack {
                Circle().fill(.black)
                Image(systemName: "suitcase.rolling.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(booking.travelerCount) путешественников · \(booking.rooms) комнат")
                    .font(.caption.bold())
                Text("\(booking.startDate) – \(booking.endDate)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(BusinessDesign.secondarySurface, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
    }

    @ViewBuilder
    private func messageBubble(_ message: BusinessChatMessage) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.isStaff { Spacer(minLength: 62) }

            VStack(alignment: message.isStaff ? .trailing : .leading, spacing: 4) {
                if !message.isStaff, let sender = message.senderName, !sender.isEmpty {
                    Text(sender)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }

                Text(message.body)
                    .font(.body)
                    .foregroundStyle(message.isStaff ? .white : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        message.isStaff ? Color.black : BusinessDesign.secondarySurface,
                        in: UnevenRoundedRectangle(
                            topLeadingRadius: 21,
                            bottomLeadingRadius: message.isStaff ? 21 : 6,
                            bottomTrailingRadius: message.isStaff ? 6 : 21,
                            topTrailingRadius: 21,
                            style: .continuous
                        )
                    )

                Text(timeLabel(message.createdAt))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
            }

            if !message.isStaff { Spacer(minLength: 62) }
        }
        .frame(maxWidth: .infinity)
    }

    private var composer: some View {
        VStack(spacing: 6) {
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
            }

            HStack(alignment: .bottom, spacing: 9) {
                TextField("Сообщение", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 11)
                    .background(Color.white.opacity(0.74), in: RoundedRectangle(cornerRadius: 22, style: .continuous))

                Button { send() } label: {
                    Group {
                        if sending {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 17, weight: .bold))
                        }
                    }
                    .frame(width: 43, height: 43)
                    .foregroundStyle(.white)
                    .background(.black, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
            }
            .padding(8)
            .businessGlass(in: RoundedRectangle(cornerRadius: 29, style: .continuous))
        }
        .padding(.horizontal, 12)
        .padding(.top, 5)
        .padding(.bottom, 8)
    }

    @MainActor private func reload() async {
        do {
            let value = try await APIClient.shared.businessChatMessages(bookingID: booking.id)
            messages = value
            _ = try? await APIClient.shared.markBusinessChatRead(bookingID: booking.id)
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }

    @MainActor private func poll() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled, !sending else { continue }
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
