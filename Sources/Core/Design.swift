import SwiftUI

enum BusinessDesign {
    static let background = Color.white
    static let ink = Color(red: 0.055, green: 0.055, blue: 0.06)
    static let muted = Color(red: 0.48, green: 0.48, blue: 0.50)
    static let accent = Color.black
    static let softOrange = Color.black.opacity(0.04)
    static let line = Color.black.opacity(0.07)
    static let card = Color.white
    static let secondarySurface = Color.black.opacity(0.035)
    static let tertiarySurface = Color.black.opacity(0.022)
}

struct BusinessCardModifier: ViewModifier {
    var radius: CGFloat = 28
    func body(content: Content) -> some View {
        content
            .background(BusinessDesign.card)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(BusinessDesign.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.025), radius: 14, y: 6)
    }
}

struct BusinessBrandLogo: View {
    private var width: CGFloat?
    private var height: CGFloat?

    init(width: CGFloat = 154) {
        self.width = width
        self.height = nil
    }

    init(height: CGFloat) {
        self.width = nil
        self.height = height
    }

    var body: some View {
        Image("Logo")
            .resizable()
            .scaledToFit()
            .frame(width: width, height: height)
            .accessibilityLabel("iumrah Business")
    }
}

extension View {
    func businessCard(radius: CGFloat = 28) -> some View { modifier(BusinessCardModifier(radius: radius)) }
}


private struct BusinessGlassModifier<S: Shape>: ViewModifier {
    let shape: S

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Color.white.opacity(0.55), lineWidth: 0.7))
        }
    }
}

extension View {
    func businessGlass<S: Shape>(in shape: S) -> some View {
        modifier(BusinessGlassModifier(shape: shape))
    }
}
