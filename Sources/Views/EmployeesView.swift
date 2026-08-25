import SwiftUI

struct EmployeesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var members: [BusinessTeamMember] = []
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var showAdd = false

    var body: some View {
        List {
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            ForEach(members) { member in
                NavigationLink {
                    TeamMemberEditorView(member: member) { updated in
                        if let index = members.firstIndex(where: { $0.id == updated.id }) { members[index] = updated }
                    }
                } label: {
                    HStack(spacing: 13) {
                        Circle()
                            .fill(BusinessDesign.secondarySurface)
                            .frame(width: 50, height: 50)
                            .overlay(Text(initials(member)).font(.headline))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(member.displayName).font(.headline)
                            Text(member.roleTitle.isEmpty ? roleTitle(member.roleKind) : member.roleTitle)
                                .font(.caption).foregroundStyle(.secondary)
                            HStack(spacing: 6) {
                                Circle().fill(member.active ? Color.green : Color.gray).frame(width: 7, height: 7)
                                Text(member.publicVisible ? "Публичный" : "Скрытый")
                            }
                            .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .swipeActions {
                    if !member.isOwner {
                        Button(role: .destructive) { Task { await delete(member) } } label: { Label("Удалить", systemImage: "trash") }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.white)
        .navigationTitle("Сотрудники")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button("Закрыть") { dismiss() } }
            ToolbarItem(placement: .topBarTrailing) { Button { showAdd = true } label: { Image(systemName: "plus") } }
        }
        .sheet(isPresented: $showAdd) {
            NavigationStack {
                TeamMemberEditorView(member: .emptyGuide, creating: true) { created in
                    members.append(created)
                    showAdd = false
                }
            }
        }
        .overlay { if loading { ProgressView() } }
        .task { await load() }
        .refreshable { await load() }
    }

    @MainActor private func load() async {
        loading = true
        do { members = try await APIClient.shared.businessTeam(); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
        loading = false
    }

    @MainActor private func delete(_ member: BusinessTeamMember) async {
        do { try await APIClient.shared.deleteBusinessTeamMember(id: member.id); members.removeAll { $0.id == member.id } }
        catch { errorMessage = error.localizedDescription }
    }

    private func initials(_ member: BusinessTeamMember) -> String {
        let parts = [member.firstName, member.lastName].filter { !$0.isEmpty }
        return parts.prefix(2).compactMap(\.first).map(String.init).joined().uppercased().isEmpty ? "i" : parts.prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }

    private func roleTitle(_ value: String) -> String {
        switch value { case "owner": return "Владелец"; case "manager": return "Менеджер"; case "operations": return "Операции"; default: return "Гид" }
    }
}

struct TeamMemberEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State var member: BusinessTeamMember
    var creating = false
    let onSaved: (BusinessTeamMember) -> Void
    @State private var saving = false
    @State private var errorMessage: String?

    var body: some View {
        TeamMemberForm(member: $member, ownerMode: member.isOwner)
            .navigationTitle(creating ? "Новый сотрудник" : "Сотрудник")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if creating { ToolbarItem(placement: .topBarLeading) { Button("Отмена") { dismiss() } } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(saving ? "Сохраняю…" : "Сохранить") { Task { await save() } }
                        .fontWeight(.semibold).disabled(saving)
                }
            }
            .alert("Не удалось сохранить", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
    }

    @MainActor private func save() async {
        saving = true
        do {
            let saved = creating ? try await APIClient.shared.createBusinessTeamMember(member) : try await APIClient.shared.updateBusinessTeamMember(member)
            onSaved(saved)
            if creating { dismiss() }
            member = saved
        } catch { errorMessage = error.localizedDescription }
        saving = false
    }
}
