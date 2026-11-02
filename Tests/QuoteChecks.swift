import Foundation

@main struct QuoteChecks {
    static func main() throws {
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let data = try Data(contentsOf: url)
        struct Frame: Decodable { var quotes: [IslandQuote] }
        let frame = try JSONDecoder().decode(Frame.self, from: data)
        precondition(frame.quotes.count == 1)
        let quote = frame.quotes[0]
        precondition(quote.id == "hl:BTC" && quote.currency == "USD" && quote.basis == "mark")
        precondition(quote.staleAt.timeIntervalSince(quote.receivedAt) <= 90)
        let roundtrip = try JSONDecoder().decode(IslandQuote.self, from: JSONEncoder().encode(quote))
        precondition(roundtrip == quote)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(quote)) as! [String: Any]
        object["demo"] = true
        do {
            _ = try JSONDecoder().decode(IslandQuote.self, from: JSONSerialization.data(withJSONObject: object))
            fatalError("Legacy synthetic content must not decode as genuine data")
        } catch is DecodingError { }
        object.removeValue(forKey: "demo")
        object["price"] = -1
        do {
            _ = try JSONDecoder().decode(IslandQuote.self, from: JSONSerialization.data(withJSONObject: object))
            fatalError("Nonpositive market quote must be rejected")
        } catch is DecodingError { }
        print("Server/iOS quote contract checks passed")
    }
}
