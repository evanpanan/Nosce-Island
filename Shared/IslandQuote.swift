import Foundation

struct IslandQuote: Codable, Hashable, Identifiable {
    var id: String
    var symbol: String
    var price: Double
    var change: Double?
    var currency: String
    var updatedAt: Date
    var receivedAt: Date
    var source: String
    var basis: String
    var delaySeconds: Int
    var marketState: String
    var staleAt: Date {
        let transport = receivedAt.addingTimeInterval(90)
        if marketState == "closed" { return transport }
        return min(transport, updatedAt.addingTimeInterval(Double(delaySeconds + 90)))
    }
    func isStale(at date: Date) -> Bool { date >= staleAt || updatedAt > date.addingTimeInterval(5) }
    var formattedPrice: String {
        currency == "USDT" ? price.formatted(.number.precision(.fractionLength(price < 1 ? 4 : 2))) + " USDT" : price.formatted(.currency(code: currency).precision(.fractionLength(price < 1 ? 4 : 2)))
    }
    var formattedChange: String {
        guard let change else { return "—" }
        return String(format: "%+.2f%%", change)
    }
    var statusLabel: String {
        let zh = Locale.preferredLanguages.first?.hasPrefix("zh") == true
        let delay = delaySeconds > 0 ? (zh ? "延迟 \(delaySeconds) 秒" : "Delayed \(delaySeconds)s") : (zh ? "实时源" : "Live source")
        if marketState == "closed" { return zh ? "休市 · \(delay)" : "Closed · \(delay)" }
        return delay
    }
}

extension IslandQuote {
    private enum CodingKeys: String, CodingKey {
        case id, symbol, price, change, currency, updatedAt, receivedAt, source, basis, delaySeconds, marketState
        case legacySynthetic = "demo"
    }
    private static func parseDate(_ string: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        if let date = formatter.date(from: string) { return date }
        throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid ISO-8601 quote time"))
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decodeIfPresent(Bool.self, forKey: .legacySynthetic) != true else {
            throw DecodingError.dataCorruptedError(forKey: .legacySynthetic, in: values, debugDescription: "Synthetic quote rejected")
        }
        id = try values.decode(String.self, forKey: .id)
        symbol = try values.decode(String.self, forKey: .symbol)
        price = try values.decode(Double.self, forKey: .price)
        change = try values.decodeIfPresent(Double.self, forKey: .change)
        currency = try values.decode(String.self, forKey: .currency)
        updatedAt = try Self.parseDate(values.decode(String.self, forKey: .updatedAt))
        receivedAt = try Self.parseDate(values.decode(String.self, forKey: .receivedAt))
        source = try values.decode(String.self, forKey: .source)
        basis = try values.decode(String.self, forKey: .basis)
        delaySeconds = try values.decode(Int.self, forKey: .delaySeconds)
        marketState = try values.decode(String.self, forKey: .marketState)
        guard price.isFinite, price > 0, change.map({ $0.isFinite }) ?? true,
              ["USD", "HKD", "USDT"].contains(currency), ["mark", "last"].contains(basis),
              ["open", "closed", "unknown"].contains(marketState), (0...86400).contains(delaySeconds),
              (id.hasPrefix("hl:") && source == "Hyperliquid" && basis == "mark" && currency == "USD") ||
              (id.hasPrefix("stock:") && (source.hasPrefix("Twelve Data · ") || (source == "Alpaca · IEX" && currency == "USD" && delaySeconds == 0)) && basis == "last") ||
              (id.hasPrefix("bn:") && source == "Binance Futures" && basis == "mark") else {
            throw DecodingError.dataCorruptedError(forKey: .price, in: values, debugDescription: "Invalid market quote")
        }
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id); try values.encode(symbol, forKey: .symbol)
        try values.encode(price, forKey: .price); try values.encodeIfPresent(change, forKey: .change)
        try values.encode(currency, forKey: .currency)
        let formatter = ISO8601DateFormatter()
        try values.encode(formatter.string(from: updatedAt), forKey: .updatedAt)
        try values.encode(formatter.string(from: receivedAt), forKey: .receivedAt)
        try values.encode(source, forKey: .source); try values.encode(basis, forKey: .basis)
        try values.encode(delaySeconds, forKey: .delaySeconds); try values.encode(marketState, forKey: .marketState)
    }
}

/// Market direction and the user's color convention are independent of quote freshness.
/// A stale quote keeps its direction color; warning icons and timestamps communicate age.
enum QuotePriceTone: Equatable { case green, red, neutral }

extension IslandQuote {
    static func priceTone(change: Double?, redUp: Bool) -> QuotePriceTone {
        guard let change, change.isFinite, change != 0 else { return .neutral }
        return (change > 0) != redUp ? .green : .red
    }
    func priceTone(redUp: Bool) -> QuotePriceTone { Self.priceTone(change: change, redUp: redUp) }
}
