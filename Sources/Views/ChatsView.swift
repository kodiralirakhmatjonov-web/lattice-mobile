import Foundation
import PhotosUI
import SwiftUI
import UIKit

private enum ChatFilter: String, CaseIterable, Identifiable {
    case new = "Новые"
    case active = "В процессе"
    case completed = "Завершённые"
    var id: String { rawValue }
}

struct ChatsView: View {
    @State private var threads: [ChatThread] = []
    @State private var bookings: [BookingSummary] = []
    @State private var filter: ChatFilter = .new
    @State private var loading = true
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Чаты")
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .tracking(-1.4)
                    Text("Один чат = одна поездка")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                filterBar

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.secondary)
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(BusinessDesign.secondarySurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                }

                if filteredThreads.isEmpty && !loading {
                    ContentUnavailableView(emptyTitle, systemImage: "message", description: Text(emptySubtitle))
                        .frame(maxWidth: .infinity).padding(.vertical, 42)
                } else {
                    ForEach(filteredThreads) { thread in
                        NavigationLink { ChatConversationView(booking: thread.booking) } label: { ThreadCard(thread: thread) }
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
            ToolbarItem(placement: .topBarLeading) { BusinessSidebarButton() }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { NewChatBookingPicker(bookings: bookings) } label: { Image(systemName: "square.and.pencil") }
                    .disabled(bookings.isEmpty)
            }
        }
        .overlay { if loading { ProgressView() } }
        .task { await load() }
        .refreshable { await load() }
    }

    private var filterBar: some View {
        HStack(spacing: 7) {
            ForEach(ChatFilter.allCases) { item in
                Button { withAnimation(.snappy(duration: 0.25)) { filter = item } } label: {
                    HStack(spacing: 6) {
                        Text(item.rawValue)
                        if item == .new {
                            let count = threads.filter(\.unreadForStaff).count
                            if count > 0 { Text("\(count)").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2).background(item == filter ? Color.white.opacity(0.22) : Color.black.opacity(0.06), in: Capsule()) }
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(item == filter ? .white : .primary)
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .background(item == filter ? Color.black : BusinessDesign.secondarySurface, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    private var filteredThreads: [ChatThread] {
        switch filter {
        case .new: return threads.filter(\.unreadForStaff)
        case .active: return threads.filter { !isCompleted($0.booking) }
        case .completed: return threads.filter { isCompleted($0.booking) }
        }
    }

    private func isCompleted(_ booking: BookingSummary) -> Bool {
        if let raw = booking.operationStatus, let status = TripStatus(rawValue: raw) { return status.isCompleted }
        return booking.status == .completed
    }

    private var emptyTitle: String { filter == .new ? "Новых сообщений нет" : filter == .active ? "Активных чатов нет" : "Завершённых чатов нет" }
    private var emptySubtitle: String { filter == .new ? "Непрочитанные сообщения появятся здесь." : "Чаты автоматически группируются по статусу поездки." }

    @MainActor private func load() async {
        loading = true; errorMessage = nil
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
                return ChatThread(booking: booking, lastMessageAt: cloud.lastMessageAt, lastMessagePreview: cloud.lastMessagePreview, lastSenderType: cloud.lastSenderType, unreadForStaff: cloud.unreadForStaff)
            }
            if threads.filter(\.unreadForStaff).isEmpty, filter == .new { filter = .active }
        } catch is CancellationError { return }
        catch { errorMessage = error.localizedDescription }
        loading = false
    }
}

private struct ThreadCard: View {
    let thread: ChatThread
    var body: some View {
        HStack(spacing: 13) {
            ZStack {
                Circle().fill(BusinessDesign.secondarySurface)
                Text(initials).font(.headline.weight(.bold))
            }
            .frame(width: 54, height: 54)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(thread.booking.clientName ?? "Паломник")
                        .font(.subheadline.bold()).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(chatTime(thread.lastMessageAt)).font(.caption2).foregroundStyle(.tertiary)
                }
                Text(thread.lastMessagePreview.isEmpty ? "Нет сообщений" : thread.lastMessagePreview)
                    .font(.subheadline).foregroundStyle(thread.unreadForStaff ? .primary : .secondary)
                    .fontWeight(thread.unreadForStaff ? .semibold : .regular).lineLimit(2)
                HStack(spacing: 5) {
                    Text(thread.booking.pilgrimID.map { "ID \($0)" } ?? "ID —").monospaced()
                    Text("·")
                    Text("\(thread.booking.originCode) → \(thread.booking.outboundDestination)")
                    if thread.unreadForStaff { Spacer(); Circle().fill(.black).frame(width: 8, height: 8) }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(BusinessDesign.tertiarySurface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(BusinessDesign.line, lineWidth: 1))
    }

    private var initials: String {
        let name = thread.booking.clientName ?? "P"
        return name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }
}

private struct NewChatBookingPicker: View {
    let bookings: [BookingSummary]
    var body: some View {
        List(bookings) { booking in
            NavigationLink { ChatConversationView(booking: booking) } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(booking.clientName ?? "Паломник").font(.subheadline.bold())
                    Text("\(booking.pilgrimID.map { "ID \($0)" } ?? "ID —") · \(booking.originCode) → \(booking.outboundDestination) · \(booking.startDate)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Новый чат")
    }
}

struct ChatConversationView: View {
    let booking: BookingSummary
    @State private var messages: [BusinessChatMessage] = []
    @State private var draft = ""
    @State private var loading = true
    @State private var sending = false
    @State private var errorMessage: String?
    @State private var selectedPhoto: PhotosPickerItem?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 9) {
                    bookingContext
                    if loading && messages.isEmpty { ProgressView().padding(.top, 42) }
                    else if messages.isEmpty {
                        ContentUnavailableView("Начните диалог", systemImage: "bubble.left.and.bubble.right", description: Text("Сообщения и фотографии сохраняются в iumrah Cloud."))
                            .padding(.top, 34)
                    }
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        if shouldShowDate(at: index) { dateSeparator(message.createdAt) }
                        messageBubble(message).id(message.id)
                    }
                }
                .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 18)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color.white)
            .onChange(of: messages.count) { _, _ in
                guard let last = messages.last else { return }
                withAnimation(.easeOut(duration: 0.22)) { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
        .safeAreaInset(edge: .bottom) { composer }
        .navigationTitle(booking.clientName ?? "Паломник")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { BookingDetailView(bookingID: booking.id) } label: { Image(systemName: "info.circle") }
            }
        }
        .task { await reload(); await poll() }
        .onChange(of: selectedPhoto) { _, item in if let item { Task { await sendPhoto(item) } } }
    }

    private var bookingContext: some View {
        NavigationLink { BookingDetailView(bookingID: booking.id) } label: {
            HStack(spacing: 11) {
                ZStack { Circle().fill(.black); Image(systemName: "suitcase.rolling.fill").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white) }.frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(booking.pilgrimID.map { "ID \($0)" } ?? "ID —") · \(booking.travelerCount) чел.").font(.caption.bold())
                    Text("\(booking.startDate) – \(booking.endDate)").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(); Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
            }
            .padding(12).background(BusinessDesign.secondarySurface, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
        }
        .buttonStyle(.plain).foregroundStyle(.primary)
    }

    @ViewBuilder private func messageBubble(_ message: BusinessChatMessage) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.isStaff { Spacer(minLength: 64) }
            VStack(alignment: message.isStaff ? .trailing : .leading, spacing: 4) {
                if !message.isStaff {
                    Text(booking.clientName ?? "Паломник")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
                if message.isImage, let url = AppConfig.absoluteURL(message.attachmentURL) {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image { image.resizable().scaledToFill() }
                        else if phase.error != nil { Color.black.opacity(0.05).overlay(Image(systemName: "photo.badge.exclamationmark")) }
                        else { ProgressView() }
                    }
                    .frame(width: 220, height: 190)
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 22, bottomLeadingRadius: message.isStaff ? 22 : 7, bottomTrailingRadius: message.isStaff ? 7 : 22, topTrailingRadius: 22, style: .continuous))
                } else {
                    Text(message.body)
                        .font(.body).foregroundStyle(message.isStaff ? .white : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(message.isStaff ? Color.black : BusinessDesign.secondarySurface,
                                    in: UnevenRoundedRectangle(topLeadingRadius: 21, bottomLeadingRadius: message.isStaff ? 21 : 6, bottomTrailingRadius: message.isStaff ? 6 : 21, topTrailingRadius: 21, style: .continuous))
                }
                Text(timeLabel(message.createdAt)).font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary).padding(.horizontal, 4)
            }
            if !message.isStaff { Spacer(minLength: 64) }
        }
        .frame(maxWidth: .infinity)
    }

    private var composer: some View {
        VStack(spacing: 6) {
            if let errorMessage { Text(errorMessage).font(.caption2).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10) }
            HStack(alignment: .bottom, spacing: 8) {
                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    Image(systemName: "plus").font(.system(size: 18, weight: .semibold)).frame(width: 42, height: 42).background(Color.white.opacity(0.72), in: Circle())
                }
                .disabled(sending)
                TextField("Сообщение", text: $draft, axis: .vertical)
                    .lineLimit(1...5).textFieldStyle(.plain)
                    .padding(.horizontal, 15).padding(.vertical, 11)
                    .background(Color.white.opacity(0.74), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                Button { send() } label: {
                    Group { if sending { ProgressView().tint(.white) } else { Image(systemName: "arrow.up").font(.system(size: 17, weight: .bold)) } }
                        .frame(width: 43, height: 43).foregroundStyle(.white).background(.black, in: Circle())
                }
                .buttonStyle(.plain).disabled(sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
            }
            .padding(8).businessGlass(in: RoundedRectangle(cornerRadius: 29, style: .continuous))
        }
        .padding(.horizontal, 10).padding(.top, 5).padding(.bottom, 6)
    }

    @MainActor private func reload() async {
        do { messages = try await APIClient.shared.businessChatMessages(bookingID: booking.id); _ = try? await APIClient.shared.markBusinessChatRead(bookingID: booking.id); errorMessage = nil }
        catch is CancellationError { return }
        catch { errorMessage = error.localizedDescription }
        loading = false
    }

    @MainActor private func poll() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled, !sending else { continue }
            if let value = try? await APIClient.shared.businessChatMessages(bookingID: booking.id), value != messages {
                messages = value; _ = try? await APIClient.shared.markBusinessChatRead(bookingID: booking.id)
            }
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""; sending = true; errorMessage = nil
        Task { @MainActor in
            do {
                let message = try await APIClient.shared.sendBusinessChatMessage(bookingID: booking.id, body: text, clientMessageID: UUID().uuidString)
                if !messages.contains(where: { $0.id == message.id }) { messages.append(message) }
            } catch { draft = text; errorMessage = error.localizedDescription }
            sending = false
        }
    }

    @MainActor private func sendPhoto(_ item: PhotosPickerItem) async {
        sending = true; errorMessage = nil; selectedPhoto = nil
        do {
            guard let raw = try await item.loadTransferable(type: Data.self), let optimized = chatJPEG(raw) else { throw APIError.server("Не удалось подготовить фотографию") }
            let message = try await APIClient.shared.sendBusinessChatImage(bookingID: booking.id, data: optimized)
            if !messages.contains(where: { $0.id == message.id }) { messages.append(message) }
        } catch { errorMessage = error.localizedDescription }
        sending = false
    }

    private func chatJPEG(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let maxSide: CGFloat = 1600
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let size = CGSize(width: max(1, image.size.width * scale), height: max(1, image.size.height * scale))
        let renderer = UIGraphicsImageRenderer(size: size)
        let rendered = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        return rendered.jpegData(compressionQuality: 0.78)
    }

    private func shouldShowDate(at index: Int) -> Bool {
        guard index >= 0, index < messages.count else { return false }
        if index == 0 { return true }
        guard let current = parseISO(messages[index].createdAt), let previous = parseISO(messages[index - 1].createdAt) else { return false }
        return !Calendar.current.isDate(current, inSameDayAs: previous)
    }

    private func dateSeparator(_ value: String) -> some View {
        Text(parseISO(value)?.formatted(.dateTime.day().month(.wide).year()) ?? value)
            .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(BusinessDesign.secondarySurface, in: Capsule()).padding(.vertical, 6)
    }
}

private func parseISO(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
}

private func timeLabel(_ value: String) -> String {
    parseISO(value)?.formatted(date: .omitted, time: .shortened) ?? ""
}

private func chatTime(_ value: String) -> String {
    guard let date = parseISO(value) else { return "" }
    if Calendar.current.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
    return date.formatted(.dateTime.day().month(.abbreviated))
}
