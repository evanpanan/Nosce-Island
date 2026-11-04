import SwiftUI
import WidgetKit

private func widgetText(_ zh: String, _ en: String) -> String {
    Locale.preferredLanguages.first?.hasPrefix("zh") == true ? zh : en
}

struct MarketWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}
struct MarketWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> MarketWidgetEntry { .init(date: Date(), snapshot: .empty) }
    func getSnapshot(in context: Context, completion: @escaping (MarketWidgetEntry) -> Void) {
        completion(.init(date: Date(), snapshot: WidgetSnapshotStore.read()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<MarketWidgetEntry>) -> Void) {
        Task {
            let selected = WidgetSnapshotStore.read()
            let fetched = await WidgetQuoteFetcher.fetch(selected.items)
            // The app may change selection while these requests are in flight. Re-read its selection.
            let latest = WidgetSnapshotStore.read()
            let cached = await WidgetQuoteCache.shared.quotes(updating: fetched)
            let value = latest.merging(cached)
            // The extension does not write the shared file: the foreground app is its sole writer.
            // This prevents competing writes from reverting the user's current selection.
            let date = Date()
            var entries = [MarketWidgetEntry(date: date, snapshot: value)]
            for expiry in Set(value.quotes.map(\.staleAt).filter({ $0 > date })).sorted() {
                entries.append(MarketWidgetEntry(date: expiry.addingTimeInterval(1), snapshot: value))
            }
            completion(Timeline(entries: entries, policy: .after(date.addingTimeInterval(15 * 60))))
        }
    }
}
struct NosceMarketWidget: Widget {
    let kind = WidgetSnapshotStore.kind
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: MarketWidgetProvider()) { entry in
            MarketWidgetView(entry: entry)
        }
        .configurationDisplayName("Nosce Island")
        .description(LocalizedStringKey(widgetText("小、中、大三种行情快照，跟随 App 自选。", "Small, medium and large market snapshots from your watchlist.")))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
struct MarketWidgetView: View {
    let entry: MarketWidgetEntry
    @Environment(\.widgetFamily) private var family
    private var limit: Int { family == .systemSmall ? 1 : family == .systemMedium ? 3 : 8 }
    private var items: [WidgetWatchItem] { Array(entry.snapshot.items.prefix(limit)) }
    private var lastUpdate: Date? { items.compactMap { entry.snapshot.quote(for: $0.id)?.updatedAt }.min() }
    var body: some View {
        content
            .environment(\.colorScheme, .dark)
            .modifier(MarketWidgetBackground())
            .widgetURL(URL(string: "nosceisland://watch"))
    }
    private var content: some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 8 : 6) {
            HStack(spacing: 5) {
                Image(systemName: "waveform.path").foregroundStyle(.mint)
                Text("NOSCE ISLAND").font(.system(size: 10, weight: .semibold))
                Spacer(minLength: 0)
                if family != .systemSmall { Text(widgetText("行情快照", "SNAPSHOT")).font(.system(size: 9)).foregroundStyle(.secondary) }
            }
            if family == .systemSmall { small } else {
                ForEach(items) { item in widgetRow(item) }
                if family == .systemLarge { Spacer(minLength: 0) }
            }
            footer
        }
    }
    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let item = items.first {
                Text(item.symbol).font(.title2.bold()).lineLimit(1).minimumScaleFactor(0.7)
                if let quote = entry.snapshot.quote(for: item.id) {
                    Text(quote.formattedPrice).foregroundStyle(changeColor(quote)).font(.system(size: 23, weight: .semibold, design: .rounded))
                        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
                    HStack(spacing: 5) {
                        Text(quote.formattedChange).foregroundStyle(changeColor(quote))
                        Text(quote.basis == "mark" ? widgetText("合约", "PERP") : quote.currency).foregroundStyle(.secondary)
                    }.font(.caption2)
                } else {
                    Text("—").font(.title.bold())
                    Text(widgetText("等待行情", "Awaiting quote")).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
    private func widgetRow(_ item: WidgetWatchItem) -> some View {
        let quote = entry.snapshot.quote(for: item.id)
        return HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.symbol).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(quote?.basis == "last" ? item.currency : widgetText("合约", "PERP"))
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 2)
            if let quote {
                if quote.isStale(at: entry.date) { Image(systemName: "clock").font(.system(size: 9)).foregroundStyle(.orange).accessibilityLabel(widgetText("旧报价", "Old quote")) }
                VStack(alignment: .trailing, spacing: 1) {
                    Text(quote.formattedPrice).foregroundStyle(changeColor(quote)).font(.system(size: 12, weight: .medium)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                    Text(quote.formattedChange).font(.system(size: 10)).monospacedDigit().foregroundStyle(changeColor(quote))
                }
            } else { Text("—").font(.caption).foregroundStyle(.secondary) }
        }
        .frame(maxHeight: .infinity)
    }
    private var footer: some View {
        HStack(spacing: 3) {
            if let date = lastUpdate {
                let stale = items.contains { item in entry.snapshot.quote(for: item.id).map { $0.isStale(at: entry.date) } ?? true }
                Text(stale ? widgetText("旧快照", "Old snapshot") : widgetText("更新于", "Updated"))
                    .foregroundStyle(stale ? .orange : .secondary)
                Text(date, style: .time).foregroundStyle(.secondary)
            } else { Text(widgetText("打开 App 连接行情", "Open app for quotes")).foregroundStyle(.secondary) }
        }.font(.system(size: 9)).lineLimit(1).minimumScaleFactor(0.7)
    }
    private func changeColor(_ quote: IslandQuote) -> Color {
        switch quote.priceTone(redUp: entry.snapshot.redUp) {
        case .green: return .green
        case .red: return .red
        case .neutral: return .secondary
        }
    }
}
private struct MarketWidgetBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOSApplicationExtension 17.0, *) {
            content.containerBackground(for: .widget) { Color(red: 0.045, green: 0.06, blue: 0.065) }
        } else {
            content.padding(14).background(Color(red: 0.045, green: 0.06, blue: 0.065))
        }
    }
}

/// Extension-private last successful results survive network failures without writing app preferences.
private actor WidgetQuoteCache {
    static let shared = WidgetQuoteCache()
    func quotes(updating incoming: [IslandQuote]) -> [IslandQuote] {
        let key = "nosce-widget-quotes-v1"
        let data = UserDefaults.standard.data(forKey: key)
        var previous: [IslandQuote] = []
        if let data, data.count < 262_144 { previous = (try? JSONDecoder().decode([IslandQuote].self, from: data)) ?? [] }
        var values: [String: IslandQuote] = [:]
        for quote in previous + incoming {
            if let old = values[quote.id], old.updatedAt > quote.updatedAt { continue }
            values[quote.id] = quote
        }
        let kept = Array(values.values.sorted { $0.updatedAt > $1.updatedAt }.prefix(16))
        if let encoded = try? JSONEncoder().encode(kept) { UserDefaults.standard.set(encoded, forKey: key) }
        return kept
    }
}
