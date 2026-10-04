import SwiftUI

struct EmployeesView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.businessAdaptiveLayout) private var layout
    @Environment(\.businessUsesPersistentSidebar) private var usesPersistentSidebar

    @State private var members: [BusinessTeamMember] = []
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var showAdd = false
    @State private var selectedMember: BusinessTeamMember?

    var body: some View {
        Group {
            if layout.supportsTwoPaneWorkspace {
                desktopWorkspace
            } else {
                compactList
            }
        }
        .background(BusinessDesign.background)
        .navigationTitle("Сотрудники")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !usesPersistentSidebar {
                ToolbarItem(placement: .topBarLeading) { Button("Закрыть") { dismiss() } }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showAdd = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showAdd) {
            NavigationStack {
                TeamMemberEditorView(member: .emptyGuide, creating: true) { created in
                    members.append(created)
                    selectedMember = created
                    showAdd = false
                }
            }
        }
        .overlay { if loading { ProgressView() } }
        .task { await load() }
        .refreshable { await load() }
    }

    private var compactList: some View {
        List {
            listContents(navigates: true)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var desktopWorkspace: some View {
        HStack(spacing: 0) {
            List {
                listContents(navigates: false)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(width: layout.listPaneWidth)

            Divider()

            Group {
                if let selectedMember {
                    TeamMemberEditorView(member: selectedMember) { updated in
                        if let index = members.firstIndex(where: { $0.id == updated.id }) {
                            members[index] = updated
                        }
                        self.selectedMember = updated
                    }
                    .id(selectedMember.id)
                } else {
                    ContentUnavailableView(
                        "Выберите сотрудника",
                        systemImage: "person.2",
                        description: Text("Карточка сотрудника откроется справа, список останется доступен.")
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func listContents(navigates: Bool) -> some View {
        if let errorMessage {
            Text(errorMessage).foregroundStyle(.red)
        }

        ForEach(members) { member in
            if navigates {
                NavigationLink {
                    TeamMemberEditorView(member: member) { updated in
                        if let index = members.firstIndex(where: { $0.id == updated.id }) { members[index] = updated }
                    }
                } label: {
                    employeeRow(member)
                }
                .swipeActions { deleteAction(member) }
            } else {
                Button {
                    selectedMember = member
                } label: {
                    employeeRow(member)
                }
                .buttonStyle(.plain)
                .listRowBackground(
                    selectedMember?.id == member.id
                        ? BusinessDesign.secondarySurface.opacity(0.72)
                        : Color.clear
                )
                .contextMenu {
                    Button("Открыть") { selectedMember = member }
                    if !member.isOwner {
                        Divider()
                        Button("Удалить", role: .destructive) { Task { await delete(member) } }
                    }
                }
            }
        }
    }

    private func employeeRow(_ member: BusinessTeamMember) -> some View {
        HStack(spacing: 13) {
            employeeAvatar(member)
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
            Spacer(minLength: 6)
            if layout.supportsTwoPaneWorkspace && selectedMember?.id == member.id {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(BusinessDesign.ink)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func deleteAction(_ member: BusinessTeamMember) -> some View {
        if !member.isOwner {
            Button(role: .destructive) { Task { await delete(member) } } label: {
                Label("Удалить", systemImage: "trash")
            }
        }
    }

    @ViewBuilder private func employeeAvatar(_ member: BusinessTeamMember) -> some View {
        if let path = member.photoURL, !path.isEmpty {
            BusinessPrivateImage(path: path) {
                avatarPlaceholder(member)
            }
            .frame(width: 50, height: 50)
            .clipped()
            .clipShape(Circle())
        } else {
            avatarPlaceholder(member).frame(width: 50, height: 50).clipShape(Circle())
        }
    }

    private func avatarPlaceholder(_ member: BusinessTeamMember) -> some View {
        Circle()
            .fill(BusinessDesign.secondarySurface)
            .overlay(Text(initials(member)).font(.headline))
    }

    @MainActor private func load() async {
        loading = true
        do {
            members = try await APIClient.shared.businessTeam()
            errorMessage = nil
            if layout.supportsTwoPaneWorkspace {
                if let selectedMember,
                   let refreshed = members.first(where: { $0.id == selectedMember.id }) {
                    self.selectedMember = refreshed
                } else {
                    selectedMember = members.first
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }

    @MainActor private func delete(_ member: BusinessTeamMember) async {
        do {
            try await APIClient.shared.deleteBusinessTeamMember(id: member.id)
            members.removeAll { $0.id == member.id }
            if selectedMember?.id == member.id { selectedMember = members.first }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func initials(_ member: BusinessTeamMember) -> String {
        let value = [member.firstName, member.lastName].filter { !$0.isEmpty }.prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        return value.isEmpty ? "i" : value
    }

    private func roleTitle(_ value: String) -> String {
        switch value {
        case "owner": return "Владелец"
        case "manager": return "Менеджер"
        case "operations": return "Операции"
        default: return "Гид"
        }
    }
}

struct TeamMemberEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State var member: BusinessTeamMember
    var creating = false
    let onSaved: (BusinessTeamMember) -> Void
    @State private var pendingPhotoData: Data?
    @State private var saving = false
    @State private var errorMessage: String?

    var body: some View {
        TeamMemberForm(member: $member, pendingPhotoData: $pendingPhotoData, ownerMode: member.isOwner)
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
            var saved = creating ? try await APIClient.shared.createBusinessTeamMember(member) : try await APIClient.shared.updateBusinessTeamMember(member)
            if let pendingPhotoData {
                saved = try await APIClient.shared.uploadBusinessTeamPhoto(memberID: saved.id, imageData: pendingPhotoData)
                self.pendingPhotoData = nil
            }
            member = saved
            onSaved(saved)
            if creating { dismiss() }
        } catch { errorMessage = error.localizedDescription }
        saving = false
    }
}
