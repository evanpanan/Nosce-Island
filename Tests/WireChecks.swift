import Foundation

@main struct WireChecks {
    static func main() throws {
        let decoder = JSONDecoder()
        let fixtureDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        for name in ["snapshot-native.json", "snapshot-xyz.json"] {
            let snapshot = try decoder.decode(HLSnapshot.self, from: Data(contentsOf: fixtureDirectory.appendingPathComponent(name)))
            precondition(!snapshot.meta.universe.isEmpty)
            precondition(snapshot.meta.universe.count == snapshot.contexts.count)
            precondition(snapshot.contexts.allSatisfy { $0.price != nil })
        }
        for name in ["stream-BTC.json", "stream-xyz-TSLA.json"] {
            let message = try decoder.decode(HLMessage.self, from: Data(contentsOf: fixtureDirectory.appendingPathComponent(name)))
            precondition(message.channel == "activeAssetCtx" && message.data?.ctx.price != nil)
        }
        let numeric = try decoder.decode(HLContext.self, from: Data(#"{"markPx":110,"prevDayPx":"100"}"#.utf8))
        precondition(abs((numeric.change ?? 0) - 10) < 0.000001)
        let zero = try decoder.decode(HLContext.self, from: Data(#"{"markPx":"110","prevDayPx":"0"}"#.utf8))
        precondition(zero.change == nil)
        let missing = try decoder.decode(HLContext.self, from: Data(#"{"markPx":"110"}"#.utf8))
        precondition(missing.change == nil)
        let ack = try decoder.decode(HLMessage.self, from: Data(#"{"channel":"subscriptionResponse","data":{"type":"activeAssetCtx","coin":"BTC"}}"#.utf8))
        precondition(ack.data == nil)
        for invalid in [#"{"markPx":"NaN"}"#, #"{"markPx":"Infinity"}"#] {
            do {
                _ = try decoder.decode(HLContext.self, from: Data(invalid.utf8))
                fatalError("Non-finite price must be rejected")
            } catch is DecodingError { }
        }
        do {
            _ = try decoder.decode(HLSnapshot.self, from: Data(#"[{"universe":[{"name":"BTC"}]},[]]"#.utf8))
            fatalError("Mismatched context/universe arrays must be rejected")
        } catch is DecodingError { }
        let native = HLInstrument(id: "BTC")
        let stock = HLInstrument(id: "xyz:TSLA")
        precondition(native.crypto && native.dex.isEmpty)
        precondition(stock.symbol == "TSLA" && stock.dex == "xyz" && !stock.crypto)
        precondition(HLInstrument(id: "xyz:BABA") != HLInstrument(id: "flx:BABA"))
        print("Wire checks passed: live REST + WebSocket fixtures, numeric validation, acknowledgements, namespacing.")
    }
}
