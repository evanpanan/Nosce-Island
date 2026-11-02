import WidgetKit
import SwiftUI
import ActivityKit

@main struct NosceWidgets: WidgetBundle {
    var body: some Widget { NosceLiveActivity() }
}
struct NosceLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MarketActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label { Text("NOSCE ISLAND") } icon: { Image(systemName:"waveform.path").frame(width:16,height:16) }.font(.caption2.bold()).foregroundStyle(.mint)
                    Spacer()
                    status(context)
                }
                ForEach(context.state.visibleQuotes) { quote in row(quote, redUp: context.state.redUp) }
                Text(updateNote(context))
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(16)
                .activityBackgroundTint(Color(red: 0.045, green: 0.06, blue: 0.065))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(URL(string: "nosceisland://watch"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label { Text("NOSCE") } icon: { Image(systemName:"waveform.path").frame(width:16,height:16) }.font(.caption.bold()).foregroundStyle(.mint)
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
                HStack(spacing:3) {
                    if context.isStale {
                        Image(systemName:"exclamationmark.circle").foregroundStyle(.orange).font(.system(size:9))
                    }
                    VStack(alignment:.leading,spacing:1) {
                        ForEach(context.state.visibleQuotes) { quote in
                            Text((quote.isStale(at:Date()) ? "! " : "") + quote.symbol)
                                .font(.system(size:context.state.visibleQuotes.count > 1 ? 9 : 11,weight:.semibold))
                                .lineLimit(1).minimumScaleFactor(0.7)
                        }
                    }
                }
            } compactTrailing: {
                VStack(alignment:.trailing,spacing:1) {
                    ForEach(context.state.visibleQuotes) { quote in
                        Text(quote.formattedPrice)
                            .font(.system(size:context.state.visibleQuotes.count > 1 ? 9 : 11,weight:.medium,design:.monospaced))
                            .lineLimit(1).minimumScaleFactor(0.55)
                            .foregroundStyle(context.isStale || quote.isStale(at:Date()) ? .orange : .white)
                    }
                }
            } minimal: {
                if context.isStale {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                } else {
                    Image(systemName:"waveform.path").frame(width:18,height:18)
                }
            }
            .widgetURL(URL(string: "nosceisland://watch"))
            .keylineTint(.mint)
        }
    }
    private func local(_ zh: String, _ en: String) -> String {
        Locale.preferredLanguages.first?.hasPrefix("zh") == true ? zh : en
    }
    private func updateNote(_ context: ActivityViewContext<MarketActivityAttributes>) -> String {
        let note = context.state.foregroundOnly
            ? local("App 离开前台后暂停更新 · 返回 App 继续", "Updates pause outside the app · return to resume")
            : local("行情由服务器更新 · 注意报价状态", "Server updates · check quote status")
        let group = context.state.pageCount > 1
            ? " · \(context.state.pageIndex + 1)/\(context.state.pageCount)" : ""
        return note + group
    }
    private func status(_ context: ActivityViewContext<MarketActivityAttributes>) -> some View {
        return Text(context.isStale ? local("更新已暂停", "UPDATES PAUSED") : context.state.foregroundOnly ? local("App 行情", "APP FEED") : local("服务器行情", "SERVER FEED"))
            .font(.caption2.bold()).foregroundStyle(context.isStale ? .orange : .secondary)
    }
    private func row(_ quote: IslandQuote, redUp: Bool) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(quote.symbol).font(.headline)
                Text((quote.basis == "mark" ? local("合约 · ", "PERP · ") : quote.currency + " · ") + (quote.isStale(at:Date()) ? local("已过期", "STALE") : quote.statusLabel) + " · " + quote.updatedAt.formatted(date: .omitted, time: .standard))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Text(quote.formattedPrice).font(.headline.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.6)
            if let change = quote.change {
                Text(quote.formattedChange).font(.caption.monospacedDigit())
                    .foregroundStyle((change >= 0) != redUp ? .mint : .red)
            }
        }
    }
}
