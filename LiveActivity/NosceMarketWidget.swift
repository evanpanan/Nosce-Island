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
            var selected = WidgetSnapshotStore.read()
            let capability = WidgetEntitlementAccessStore.read()
            let verified = await WidgetEntitlementFetcher.check(capability)
            if let verified { selected.proExpiresAt = verified.proExpiresAt }
            let fetched = await WidgetQuoteFetcher.fetch(selected.widgetItems())
            // The app may change selection while these requests are in flight. Re-read its selection.
            var latest = WidgetSnapshotStore.read()
            if let verified, capability?.token == WidgetEntitlementAccessStore.read()?.token { latest.proExpiresAt = verified.proExpiresAt }
            let cached = await WidgetQuoteCache.shared.quotes(updating: fetched)
            let value = latest.merging(cached)
            // The extension does not write the shared file: the foreground app is its sole writer.
            // This prevents competing writes from reverting the user's current selection.
            let date = Date()
            var entries = [MarketWidgetEntry(date: date, snapshot: value)]
            let boundaries = value.quotes.map(\.staleAt) + [value.proExpiresAt].compactMap { $0 }
            for expiry in Set(boundaries.filter({ $0 > date })).sorted() {
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
    private var items: [WidgetWatchItem] { Array(entry.snapshot.widgetItems(at: entry.date).prefix(limit)) }
    private var premiumLocked: Bool { family != .systemSmall && !entry.snapshot.access(at: entry.date).isPro }
    private var lastCheck: Date? { items.compactMap { entry.snapshot.quote(for: $0.id)?.receivedAt }.min() }
    var body: some View {
        Group { if premiumLocked { upgradePrompt } else { content } }
            .environment(\.colorScheme, .dark)
            .modifier(MarketWidgetBackground())
            .widgetURL(URL(string: premiumLocked ? "nosceisland://membership" : "nosceisland://watch"))
    }
    private var upgradePrompt: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Nosce Island Pro", systemImage: "sparkles").font(.headline).foregroundStyle(MarketPalette.accent)
            Text(widgetText("中、大号小组件需 Pro", "Medium and large widgets need Pro")).font(.subheadline)
            Text(widgetText("免费版支持小号小组件。", "Free includes the small widget."))
                .font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Label(widgetText("查看 Pro", "Explore Pro"), systemImage: "arrow.up.right").font(.caption).foregroundStyle(MarketPalette.accent)
        }
    }
    private var content: some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 8 : 6) {
            HStack(spacing: 5) {
                Image(systemName: "waveform.path").foregroundStyle(MarketPalette.accent)
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
                    Text(quote.formattedPrice).foregroundStyle(changeColor(quote)).font(.system(size: 23, weight: .semibold))
                        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
                    HStack(spacing: 5) {
                        Text(quote.formattedChange).foregroundStyle(changeColor(quote))
                        Text(quote.basis == "mark" ? widgetText("合约", "PERP") : quote.source == "Alpaca · IEX" ? "IEX" : quote.currency).foregroundStyle(.secondary)
                    }.font(.caption2)
                    if quote.source == "Alpaca · IEX" {
                        Text(widgetText("最近成交 ", "Last trade ") + quote.updatedAt.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                    }
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
                Text(rowNote(quote, currency: item.currency))
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 2)
            if let quote {
                if quote.isStale(at: entry.date) {
                    Image(systemName: "clock").font(.system(size: 9))
                        .foregroundStyle(quote.source == "Alpaca · IEX" && entry.date.timeIntervalSince(quote.receivedAt) < 90 ? Color.secondary : Color.orange)
                        .accessibilityLabel(widgetText("查看最近成交与检查时间", "Check trade and refresh times"))
                }
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
            if let date = lastCheck {
                let stale = items.contains { item in entry.snapshot.quote(for: item.id).map { entry.date.timeIntervalSince($0.receivedAt) >= 90 } ?? true }
                Text(stale ? widgetText("上次检查", "Last checked") : widgetText("已检查", "Checked"))
                    .foregroundStyle(stale ? .orange : .secondary)
                Text(date, style: .time).foregroundStyle(.secondary)
            } else { Text(widgetText("打开 App 连接行情", "Open app for quotes")).foregroundStyle(.secondary) }
        }.font(.system(size: 9)).lineLimit(1).minimumScaleFactor(0.7)
    }
    private func rowNote(_ quote: IslandQuote?, currency: String) -> String {
        guard let quote else { return currency }
        if quote.source == "Alpaca · IEX" {
            return "IEX · " + widgetText("成交 ", "Trade ") + quote.updatedAt.formatted(date: .omitted, time: .shortened)
        }
        return quote.basis == "last" ? currency : widgetText("合约", "PERP")
    }
    private func changeColor(_ quote: IslandQuote) -> Color {
        MarketPalette.price(quote.priceTone(redUp: entry.snapshot.redUp))
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

private enum WidgetEntitlementFetcher {
    struct Result { let proExpiresAt: Date? }
    static func check(_ access: WidgetEntitlementAccess?) async -> Result? {
        guard let access, access.valid, let base = access.baseURL else { return nil }
        var request = URLRequest(url: base.appendingPathComponent("v1/widget/entitlement"))
        request.timeoutInterval = 7
        request.setValue("Bearer " + access.token, forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            if http.statusCode == 401 || http.statusCode == 403 { return Result(proExpiresAt: nil) }
            guard http.statusCode == 200 else { return nil }
            struct Payload: Decodable { let proExpiresAt: Double? }
            let value = try JSONDecoder().decode(Payload.self, from: data)
            return Result(proExpiresAt: value.proExpiresAt.map { Date(timeIntervalSince1970: $0) })
        } catch { return nil } // Keep the cached verified expiry during an ordinary network outage.
    }
}
