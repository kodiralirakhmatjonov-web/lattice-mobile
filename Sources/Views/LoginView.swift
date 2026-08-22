import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var auth: AuthStore
    @State private var login = ""
    @State private var password = ""
    @State private var working = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Image("Logo")
                        .resizable().scaledToFit().frame(width: 150, height: 44)
                    Spacer()
                    Label("Secure", systemImage: "lock.fill")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 13).frame(height: 42)
                        .background(.white, in: Capsule())
                }

                Spacer(minLength: 48)
                Text("IUMRAH BUSINESS")
                    .font(.caption2.weight(.bold)).tracking(2.6).foregroundStyle(.secondary)
                Text("Центр\nуправления.")
                    .font(.system(size: 52, weight: .bold))
                    .tracking(-2.7)
                    .padding(.top, 12)
                Text("Бронирования, чаты и собственная база отелей iumrah — с iPhone.")
                    .font(.system(size: 16)).foregroundStyle(.secondary)
                    .padding(.top, 14)

                VStack(spacing: 12) {
                    TextField("Логин", text: $login)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 18).frame(height: 58)
                        .background(Color.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    SecureField("Пароль", text: $password)
                        .padding(.horizontal, 18).frame(height: 58)
                        .background(Color.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    if let error = auth.errorMessage {
                        Text(error).font(.footnote).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button {
                        working = true
                        Task { await auth.login(login: login, password: password); working = false }
                    } label: {
                        HStack { if working { ProgressView().tint(.white) }; Text(working ? "Входим…" : "Войти") }
                            .font(.headline).frame(maxWidth: .infinity).frame(height: 56)
                            .foregroundStyle(.white).background(BusinessDesign.ink, in: Capsule())
                    }
                    .disabled(login.isEmpty || password.isEmpty || working)
                }
                .padding(18).businessCard(radius: 30).padding(.top, 34)
            }
            .padding(20)
            .frame(minHeight: UIScreen.main.bounds.height - 30, alignment: .top)
        }
    }
}
