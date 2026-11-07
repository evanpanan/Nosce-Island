import WidgetKit
import SwiftUI
import ActivityKit
import UIKit

@main struct NosceWidgets: WidgetBundle {
    var body: some Widget {
        NosceMarketWidget()
        NosceLiveActivity()
    }
}
struct NosceLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MarketActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label { Text("NOSCE ISLAND") } icon: { Image(systemName:"waveform.path").frame(width:16,height:16) }.font(.caption2.bold()).foregroundStyle(MarketPalette.accent)
                    Spacer()
                    status(context)
                }
                ForEach(context.state.visibleQuotes) { quote in row(quote, redUp: context.state.redUp) }
                Text(updateNote(context))
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(16)
                .environment(\.colorScheme, .dark)
                .activityBackgroundTint(Color(red: 0.045, green: 0.06, blue: 0.065))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(URL(string: "nosceisland://watch"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label { Text("NOSCE") } icon: { Image(systemName:"waveform.path").frame(width:16,height:16) }.font(.caption.bold()).foregroundStyle(MarketPalette.accent).environment(\.colorScheme, .dark)
                }
                DynamicIslandExpandedRegion(.trailing) { status(context) }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 10) {
                        ForEach(context.state.visibleQuotes) { quote in row(quote, redUp: context.state.redUp) }
                        Text(updateNote(context))
                            .font(.caption2).foregroundStyle(.secondary)
                    }.padding(.vertical, 6)
                }
            } compactLeading: {
                if let quote = context.state.visibleQuotes.first {
                    HStack(spacing: 2) {
                        IslandAssetLogo(quote: quote, size: 12)
                        if context.isStale || quote.isStale(at: Date()) {
                            Image(systemName: "clock").font(.system(size: 8)).foregroundStyle(.orange)
                        }
                        Text(quote.symbol)
                            .font(.system(size: 10, weight: .semibold))
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }.frame(width: compactSymbolWidth(quote, warning: context.isStale || quote.isStale(at: Date())), alignment: .leading)
                        .accessibilityLabel(quote.symbol)
                }
            } compactTrailing: {
                if let quote = context.state.visibleQuotes.first {
                    Text(quote.compactPrice)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .foregroundStyle(priceColor(quote, redUp: context.state.redUp))
                        .frame(width: compactPriceWidth(quote), alignment: .trailing)
                        .environment(\.colorScheme, .dark)
                        .accessibilityLabel(quote.symbol + " " + quote.formattedPrice)
                }
            } minimal: {
                if context.isStale {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                } else if let quote = context.state.visibleQuotes.first {
                    IslandAssetLogo(quote: quote, size: 18)
                }
            }
            .widgetURL(URL(string: "nosceisland://watch"))
            .keylineTint(MarketPalette.accent)
        }
    }
    // Reserve only the space the current text needs, rather than the widest possible quote.
    // iOS still chooses the overall Island dimensions and presentation.
    private func compactSymbolWidth(_ quote: IslandQuote, warning: Bool) -> CGFloat {
        let font = UIFont.systemFont(ofSize: 10, weight: .semibold)
        let width = (quote.symbol as NSString).size(withAttributes: [.font: font]).width
        return min(54, max(28, ceil(width) + 14 + (warning ? 10 : 0)))
    }
    private func compactPriceWidth(_ quote: IslandQuote) -> CGFloat {
        let font = UIFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        let width = (quote.compactPrice as NSString).size(withAttributes: [.font: font]).width
        return min(68, max(24, ceil(width) + 1))
    }
    private func priceColor(_ quote: IslandQuote, redUp: Bool) -> Color {
        MarketPalette.price(quote.priceTone(redUp: redUp), darkSurface: true)
    }
    private func local(_ zh: String, _ en: String) -> String {
        Locale.preferredLanguages.first?.hasPrefix("zh") == true ? zh : en
    }
    private func updateNote(_ context: ActivityViewContext<MarketActivityAttributes>) -> String {
        let note = context.state.foregroundOnly
            ? local("前台更新 · 返回 App 获取最新报价", "App updates · open app for latest quote")
            : local("行情由服务器更新 · 注意报价状态", "Server updates · check quote status")
        let group = context.state.pageCount > 1
            ? " · \(context.state.pageIndex + 1)/\(context.state.pageCount)" : ""
        return note + group
    }
    private func status(_ context: ActivityViewContext<MarketActivityAttributes>) -> some View {
        return Text(context.isStale ? local("报价待刷新", "QUOTE OUTDATED") : context.state.foregroundOnly ? local("App 行情", "APP FEED") : local("服务器行情", "SERVER FEED"))
            .font(.caption2.bold()).foregroundStyle(context.isStale ? .orange : .secondary)
    }
    private func row(_ quote: IslandQuote, redUp: Bool) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    IslandAssetLogo(quote: quote, size: 20)
                    Text(quote.symbol).font(.headline)
                }
                Text((quote.basis == "mark" ? local("合约 · ", "PERP · ") : quote.currency + " · ") + (quote.isStale(at:Date()) ? local("已过期", "STALE") : quote.statusLabel) + " · " + quote.updatedAt.formatted(date: .omitted, time: .standard))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Text(quote.formattedPrice).font(.headline.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.6)
                .foregroundStyle(priceColor(quote, redUp: redUp))
            if quote.change != nil {
                Text(quote.formattedChange).font(.caption.monospacedDigit())
                    .foregroundStyle(priceColor(quote, redUp: redUp))
            }
        }
    }
}

/// Local bundled marks are available offline in the widget extension as well as the app.
private struct IslandAssetLogo: View {
    let quote: IslandQuote
    let size: CGFloat
    private var assetName: String? {
        let symbol = quote.symbol.uppercased()
        if quote.id.hasPrefix("stock:") {
            let stocks = ["XMAX", "AAPL", "TSLA", "NVDA", "MSFT", "GOOG", "GOOGL", "AMZN", "META"]
            return stocks.contains(symbol) ? "Asset-" + (symbol == "GOOG" ? "GOOGL" : symbol) : nil
        }
        var base = symbol
        if quote.id.hasPrefix("bn:"), base.hasSuffix("USDT") { base = String(base.dropLast(4)) }
        let coins = ["BTC", "ETH", "SOL", "BNB", "XRP", "DOGE", "ADA", "AVAX", "LINK", "USDT", "USDC"]
        return coins.contains(base) ? "Asset-" + base : nil
    }
    var body: some View {
        Group {
            if let name = assetName {
                Image(name).renderingMode(.original).resizable().scaledToFit().background(Color.white)
            } else {
                Text(String(quote.symbol.prefix(1)))
                    .font(.system(size: size * 0.65, weight: .semibold))
                    .frame(width: size, height: size).background(Color.gray.opacity(0.3))
            }
        }.frame(width: size, height: size).clipShape(Circle()).accessibilityHidden(true)
    }
}
