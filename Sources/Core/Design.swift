import SwiftUI

enum BusinessDesign {
    // iumrah Business now uses a clean white system surface. Accent is reserved for
    // status/attention details only — never as a page background.
    static let background = Color.white
    static let ink = Color(red: 0.06, green: 0.06, blue: 0.07)
    static let muted = Color(red: 0.48, green: 0.48, blue: 0.50)
    static let accent = Color(red: 0.96, green: 0.49, blue: 0.19)
    static let softOrange = Color.black.opacity(0.045)
    static let line = Color.black.opacity(0.065)
    static let card = Color.white
    static let secondarySurface = Color.black.opacity(0.032)
}

struct BusinessCardModifier: ViewModifier {
    var radius: CGFloat = 28
    func body(content: Content) -> some View {
        content
            .background(BusinessDesign.card)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(BusinessDesign.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.035), radius: 16, y: 7)
    }
}

struct BusinessBrandLogo: View {
    var height: CGFloat = 44

    var body: some View {
        Image("Logo")
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: height, alignment: .leading)
            .accessibilityLabel("iumrah Business")
    }
}

extension View {
    func businessCard(radius: CGFloat = 28) -> some View { modifier(BusinessCardModifier(radius: radius)) }
}
