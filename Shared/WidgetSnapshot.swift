import Foundation

/// Public market data only. Never store installation tokens, purchases or login credentials here.
struct WidgetWatchItem: Codable, Hashable, Identifiable {
    let id: String
    let symbol: String
    let currency: String
}

struct WidgetSnapshot: Codable {
    var items: [WidgetWatchItem]
    var quotes: [IslandQuote]
    var redUp: Bool
    var savedAt: Date

    static var empty: WidgetSnapshot {
        WidgetSnapshot(items: ["BTC", "ETH", "SOL"].map {
            WidgetWatchItem(id: "hl:" + $0, symbol: $0, currency: "USD")
        }, quotes: [], redUp: false, savedAt: .distantPast)
    }
    func quote(for id: String) -> IslandQuote? { quotes.first { $0.id == id } }
    /// A late widget request must not replace newer foreground quotes or a changed watchlist.
    func merging(_ incoming: [IslandQuote]) -> WidgetSnapshot {
        var copy = self
        copy.quotes = items.compactMap { item in
            let old = quote(for: item.id)
            guard let next = incoming.first(where: { $0.id == item.id }) else { return old }
            if let old, old.updatedAt > next.updatedAt { return old }
            return next
        }
        copy.savedAt = Date()
        return copy
    }
}

enum WidgetSnapshotStore {
    static let kind = "NosceMarketWidget"
    private static let filename = "market-widget-v1.json"
    static var fileURL: URL? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "NosceWidgetAppGroup") as? String,
              group.hasPrefix("group."), !group.contains("$("),
              let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
        return directory.appendingPathComponent(filename)
    }
    static func read() -> WidgetSnapshot {
        guard let url = fileURL, let data = try? Data(contentsOf: url), data.count < 262_144,
              let value = try? JSONDecoder().decode(WidgetSnapshot.self, from: data),
              !value.items.isEmpty, value.items.count <= 8,
              Set(value.items.map(\.id)).count == value.items.count else { return .empty }
        return value
    }
    @discardableResult static func write(_ value: WidgetSnapshot) -> Bool {
        guard let url = fileURL, let data = try? JSONEncoder().encode(value) else { return false }
        do {
            #if os(iOS)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: url, options: .atomic)
            #endif
            return true
        } catch { return false }
    }
}

/// Separate protected capability: only reads selected stock snapshots; never an Alpaca or installation key.
struct WidgetStockAccess: Codable {
    let origin: String
    let token: String
    let symbols: [String]
    let expiresAt: Date
    var baseURL: URL? {
        guard let url = URL(string: origin), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else { return nil }
        return url
    }
    func valid(at date: Date = Date()) -> Bool {
        baseURL != nil && expiresAt > date && !token.isEmpty && token.count < 256 &&
        !symbols.isEmpty && symbols.count <= 8 && Set(symbols).count == symbols.count &&
        symbols.allSatisfy { $0.hasPrefix("stock:") && $0.count <= 128 }
    }
}

enum WidgetStockAccessStore {
    private static var url: URL? {
        WidgetSnapshotStore.fileURL?.deletingLastPathComponent().appendingPathComponent("widget-stock-access-v1.json")
    }
    static func read() -> WidgetStockAccess? {
        guard let url, let data = try? Data(contentsOf: url), data.count < 8192,
              let value = try? JSONDecoder().decode(WidgetStockAccess.self, from: data), value.valid() else { return nil }
        return value
    }
    @discardableResult static func write(_ value: WidgetStockAccess) -> Bool {
        guard value.valid(), let url, let data = try? JSONEncoder().encode(value) else { return false }
        do {
            #if os(iOS)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: url, options: .atomic)
            #endif
            return true
        } catch { return false }
    }
    static func clear() { if let url { try? FileManager.default.removeItem(at: url) } }
}
