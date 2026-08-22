import SwiftUI

struct ChatsView: View {
    @State private var threads: [ChatThread] = []
    @State private var loading = true

    var body: some View {
        List(threads) { thread in
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(thread.booking.id).font(.subheadline.bold())
                    Spacer()
                    if thread.unreadForStaff { Circle().fill(BusinessDesign.accent).frame(width: 9, height: 9) }
                }
                Text(thread.lastMessagePreview.isEmpty ? "Нет сообщений" : thread.lastMessagePreview)
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                Text("\(thread.booking.originCode) → \(thread.booking.outboundDestination)")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 8)
        }
        .listStyle(.plain).scrollContentBackground(.hidden).background(BusinessDesign.background)
        .navigationTitle("Чаты")
        .overlay { if loading { ProgressView() } }
        .task { await load() }
        .refreshable { await load() }
    }

    func load() async {
        loading = true
        threads = (try? await APIClient.shared.chats()) ?? []
        loading = false
    }
}
