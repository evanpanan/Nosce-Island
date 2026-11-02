import Foundation

struct HLInstrument: Codable, Identifiable, Hashable {
    let id: String
    var symbol: String { String(id.split(separator: ":").last ?? Substring(id)) }
    var dex: String { id.contains(":") ? String(id.split(separator: ":")[0]) : "" }
    var crypto: Bool { dex.isEmpty }
    var market: String { crypto ? "Crypto" : "HIP-3" }
    var name: String { id }
    var currency: String { "USD" }
    static let seeds = ["BTC", "ETH", "SOL", "HYPE", "xyz:AAPL", "xyz:TSLA", "xyz:NVDA", "xyz:BABA"].map { HLInstrument(id: $0) }
}

struct HLMeta: Decodable {
    struct Asset: Decodable { let name: String; let isDelisted: Bool? }
    let universe: [Asset]
}
struct HLDex: Decodable { let name: String }
struct HLNumber: Decodable {
    let value: Double
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self), let number = Double(string), number.isFinite {
            value = number
        } else if let number = try? container.decode(Double.self), number.isFinite {
            value = number
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid finite price")
        }
    }
}
struct HLContext: Decodable {
    let markPx: HLNumber
    let prevDayPx: HLNumber?
    var price: Double? { markPx.value > 0 ? markPx.value : nil }
    var change: Double? {
        guard let price, let previous = prevDayPx?.value, previous > 0 else { return nil }
        let result = (price / previous - 1) * 100
        return result.isFinite ? result : nil
    }
}
struct HLSnapshot: Decodable {
    let meta: HLMeta
    let contexts: [HLContext]
    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        meta = try container.decode(HLMeta.self)
        contexts = try container.decode([HLContext].self)
        guard meta.universe.count == contexts.count else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Universe/context count mismatch")
        }
    }
}
struct HLMessage: Decodable {
    struct Payload: Decodable { let coin: String; let ctx: HLContext }
    let channel: String
    let data: Payload?
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        channel = try container.decode(String.self, forKey: .channel)
        data = channel == "activeAssetCtx" ? try container.decode(Payload.self, forKey: .data) : nil
    }
    private enum Keys: String, CodingKey { case channel, data }
}
