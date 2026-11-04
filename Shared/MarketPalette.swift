import SwiftUI

/// Brand palette shared by the app, Live Activities and Home Screen widgets.
enum MarketPalette {
    static let accent = Color("BrandAccent")
    static let loss = Color("MarketLoss")
    static func price(_ tone: QuotePriceTone, darkSurface: Bool = false) -> Color {
        switch tone {
        case .green: return darkSurface ? Color(red: 0.529412, green: 0.960784, blue: 0.815686) : accent
        case .red: return darkSurface ? Color(red: 0.949020, green: 0.545098, blue: 0.596078) : loss
        case .neutral: return .secondary
        }
    }
}
