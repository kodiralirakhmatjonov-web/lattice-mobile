import SwiftUI

enum BusinessDesign {
    static let background = Color(red: 0.957, green: 0.949, blue: 0.937)
    static let ink = Color(red: 0.09, green: 0.09, blue: 0.10)
    static let muted = Color(red: 0.48, green: 0.46, blue: 0.49)
    static let accent = Color(red: 0.96, green: 0.49, blue: 0.19)
    static let softOrange = Color(red: 1.0, green: 0.94, blue: 0.89)
    static let line = Color.black.opacity(0.07)
    static let card = Color.white
}

struct BusinessCardModifier: ViewModifier {
    var radius: CGFloat = 28
    func body(content: Content) -> some View {
        content
            .background(BusinessDesign.card)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(BusinessDesign.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.045), radius: 18, y: 8)
    }
}

extension View {
    func businessCard(radius: CGFloat = 28) -> some View { modifier(BusinessCardModifier(radius: radius)) }
}
