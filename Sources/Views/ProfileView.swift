import SwiftUI
import UIKit

struct ProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var member: BusinessTeamMember?
    @State private var loading = true
    @State private var saving = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let member {
                TeamMemberForm(member: binding(for: member), ownerMode: true)
            } else if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Профиль недоступен", systemImage: "person.crop.circle.badge.exclamationmark", description: Text(errorMessage ?? "Попробуйте обновить."))
            }
        }
        .background(Color.white)
        .navigationTitle("Мой профиль")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button("Закрыть") { dismiss() } }
            ToolbarItem(placement: .topBarTrailing) {
                Button(saving ? "Сохраняю…" : "Сохранить") { Task { await save() } }
                    .fontWeight(.semibold)
                    .disabled(member == nil || saving)
            }
        }
        .task { await load() }
    }

    private func binding(for value: BusinessTeamMember) -> Binding<BusinessTeamMember> {
        Binding(get: { member ?? value }, set: { member = $0 })
    }

    @MainActor private func load() async {
        do { member = try await APIClient.shared.businessProfile(); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
        loading = false
    }

    @MainActor private func save() async {
        guard let member else { return }
        saving = true
        do { self.member = try await APIClient.shared.saveBusinessProfile(member); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
        saving = false
    }
}

struct TeamMemberForm: View {
    @Binding var member: BusinessTeamMember
    var ownerMode = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                identityCard
                contactsCard
                publicCard
            }
            .padding(18)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var identityCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Основное", icon: "person.text.rectangle")
            field("Имя", text: $member.firstName)
            field("Фамилия", text: $member.lastName)
            if !ownerMode {
                Picker("Роль", selection: $member.roleKind) {
                    Text("Гид").tag("guide")
                    Text("Менеджер").tag("manager")
                    Text("Операции").tag("operations")
                }
                .pickerStyle(.segmented)
            }
            field("Должность", text: $member.roleTitle)
            VStack(alignment: .leading, spacing: 7) {
                Text("Описание").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                TextField("Коротко о себе", text: $member.bio, axis: .vertical)
                    .lineLimit(4...8)
                    .padding(12)
                    .background(BusinessDesign.secondarySurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .padding(17).businessCard(radius: 26)
    }

    private var contactsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Контакты", icon: "phone")
            field("Телефон · Узбекистан", text: $member.phoneUZ, keyboard: .phonePad)
            field("Телефон · Саудовская Аравия", text: $member.phoneSA, keyboard: .phonePad)
            field("Telegram", text: $member.telegram)
            field("WhatsApp", text: $member.whatsapp)
            field("Instagram", text: $member.instagram)
        }
        .padding(17).businessCard(radius: 26)
    }

    private var publicCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Публичный профиль", icon: "globe")
            field("Slug", text: $member.publicSlug)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Toggle("Показывать в клиентском iumrah", isOn: $member.publicVisible)
            if !ownerMode { Toggle("Активный сотрудник", isOn: $member.active) }
            Text("Публичный профиль доступен клиентскому приложению через iumrah Cloud API.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(17).businessCard(radius: 26)
    }

    private func field(_ title: String, text: Binding<String>, keyboard: UIKeyboardType = .default) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            TextField(title, text: text)
                .keyboardType(keyboard)
                .padding(.horizontal, 12)
                .frame(height: 46)
                .background(BusinessDesign.secondarySurface, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
    }

    private func sectionTitle(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon).font(.title3.bold())
    }
}
