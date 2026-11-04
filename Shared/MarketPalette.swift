import SwiftUI

/// Brand palette shared by the app, Live Activities and Home Screen widgets.
enum MarketPalette {
    static let accent = Color("BrandAccent")
    static let loss = Color("MarketLoss")
    static func price(_ tone: QuotePriceTone) -> Color {
        switch tone {
        case .green: return accent
        case .red: return loss
        case .neutral: return .secondary
        }
    }
}
