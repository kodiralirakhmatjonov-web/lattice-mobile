import Foundation
import SwiftUI

enum BusinessFlightReference {
    private static let airlines: [String: String] = [
        "HY": "Uzbekistan Airways", "HH": "Qanot Sharq", "C6": "Centrum Air", "US": "Silk Avia", "U7": "Tashkent Air",
        "9S": "Air Samarkand", "2U": "Fly Khiva", "TK": "Turkish Airlines", "VF": "AJet",
        "PC": "Pegasus Airlines", "SV": "Saudia", "XY": "flynas", "FZ": "flydubai",
        "G9": "Air Arabia", "J9": "Jazeera Airways", "QR": "Qatar Airways", "J2": "Azerbaijan Airlines",
        "KC": "Air Astana", "FS": "FlyArystan", "SZ": "Somon Air", "W4": "Wizz Air Malta",
        "EK": "Emirates", "EY": "Etihad Airways", "WY": "Oman Air", "GF": "Gulf Air",
        "KU": "Kuwait Airways", "MS": "EgyptAir", "W6": "Wizz Air", "5W": "Wizz Air Abu Dhabi",
        "3L": "Air Arabia Abu Dhabi", "F3": "flyadeal", "RJ": "Royal Jordanian", "OV": "SalamAir",
        "6E": "IndiGo", "PK": "Pakistan International Airlines"
    ]

    static func normalizedFlightNumber(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let compact = rawValue.uppercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard compact.range(of: "^[A-Z0-9]{2}[0-9]{1,4}$", options: .regularExpression) != nil else { return nil }
        let code = String(compact.prefix(2))
        guard airlines[code] != nil else { return nil }
        return "\(code) \(compact.dropFirst(2))"
    }

    static func airlineCode(fromFlightNumber value: String?) -> String? {
        guard let normalized = normalizedFlightNumber(value) else { return nil }
        return String(normalized.prefix(2))
    }

    static func airlineName(code: String?, fallback: String?) -> String {
        if let code, let name = airlines[code.uppercased()] { return name }
        let clean = fallback?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let blocked = ["google flights", "skyscanner", "авиакомпания", "airline", "рейс из генератора"]
        return blocked.contains(clean.lowercased()) || clean.isEmpty ? "Перевозчик не подтверждён" : clean
    }
}

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
