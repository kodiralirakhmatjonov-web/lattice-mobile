import Foundation
import SwiftUI

struct BusinessAirlineLogoView: View {
    let airlineIATA: String?
    var size: CGFloat = 42

    private var code: String? {
        let value = airlineIATA?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
        guard value.range(of: "^[A-Z0-9]{2}$", options: .regularExpression) != nil else { return nil }
        return value
    }

    private var logoURL: URL? {
        guard let code else { return nil }
        return URL(string: "https://www.gstatic.com/flights/airline_logos/70px/\(code).png")
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(Color.white)
            if let logoURL {
                AsyncImage(url: logoURL) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFit().padding(size * 0.14)
                    } else {
                        fallback
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .strokeBorder(Color.black.opacity(0.06), lineWidth: 0.7)
        }
    }

    private var fallback: some View {
        Text(code ?? "✈")
            .font(.system(size: size * 0.28, weight: .bold, design: .rounded))
            .foregroundStyle(.primary)
    }
}
