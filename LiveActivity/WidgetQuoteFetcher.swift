import Foundation

/// A bounded HTTP snapshot, not a background WebSocket or fabricated future price timeline.
enum WidgetQuoteFetcher {
    static func fetch(_ items: [WidgetWatchItem], session: URLSession = .shared, stockAccess: WidgetStockAccess? = WidgetStockAccessStore.read()) async -> [IslandQuote] {
        let hl = items.filter { $0.id.hasPrefix("hl:") }
        let dexes = Set(hl.map { item -> String in
            let coin = String(item.id.dropFirst(3))
            return coin.contains(":") ? String(coin.split(separator: ":")[0]) : ""
        })
        return await withTaskGroup(of: [IslandQuote].self) { group in
            for dex in dexes { group.addTask { await hyperliquid(hl, dex: dex, session: session) } }
            for item in items where item.id.hasPrefix("bn:") {
                group.addTask {
                    if let quote = await binance(item, session: session) { return [quote] }
                    return []
                }
            }
            if let access = stockAccess, access.valid() {
                group.addTask { await stocks(items, access: access, session: session) }
            }
            var result: [IslandQuote] = []
            for await batch in group { result += batch }
            return result
        }
    }
    private struct StockFrame: Decodable { let quotes: [IslandQuote] }
    private static func stocks(_ items: [WidgetWatchItem], access: WidgetStockAccess, session: URLSession) async -> [IslandQuote] {
        let ids = items.map(\.id).filter { access.symbols.contains($0) && $0.hasPrefix("stock:") }
        guard !ids.isEmpty, let base = access.baseURL else { return [] }
        do {
            var request = URLRequest(url: base.appendingPathComponent("v1/widget/quotes"))
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: ["symbols": ids])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer " + access.token, forHTTPHeaderField: "Authorization")
            request.cachePolicy = .reloadIgnoringLocalCacheData; request.timeoutInterval = 12
            let result = try JSONDecoder().decode(StockFrame.self, from: try await data(request, session: session))
            return result.quotes.filter { ids.contains($0.id) && $0.source == "Alpaca · IEX" }
        } catch { return [] }
    }
    private static func data(_ request: URLRequest, session: URLSession) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 2_097_152 else {
            throw URLError(.badServerResponse)
        }
        return data
    }
    private static func hyperliquid(_ items: [WidgetWatchItem], dex: String, session: URLSession) async -> [IslandQuote] {
        do {
            let observed = Date()
            var request = URLRequest(url: URL(string: "https://api.hyperliquid.xyz/info")!)
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: ["type": "metaAndAssetCtxs", "dex": dex])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.cachePolicy = .reloadIgnoringLocalCacheData; request.timeoutInterval = 7
            let snapshot = try JSONDecoder().decode(HLSnapshot.self, from: try await data(request, session: session))
            let wanted = Set(items.map(\.id))
            return zip(snapshot.meta.universe, snapshot.contexts).compactMap { asset, context in
                let coin = dex.isEmpty || asset.name.contains(":") ? asset.name : dex + ":" + asset.name
                let id = "hl:" + coin
                guard wanted.contains(id), asset.isDelisted != true, let price = context.price else { return nil }
                return IslandQuote(id: id, symbol: String(coin.split(separator: ":").last ?? Substring(coin)),
                    price: price, change: context.change, currency: "USD", updatedAt: observed, receivedAt: Date(),
                    source: "Hyperliquid", basis: "mark", delaySeconds: 0, marketState: "open")
            }
        } catch { return [] }
    }
    private struct BinanceMark: Decodable { let symbol: String; let markPrice: String; let time: Double }
    private static func binance(_ item: WidgetWatchItem, session: URLSession) async -> IslandQuote? {
        do {
            let symbol = String(item.id.dropFirst(3))
            guard !symbol.isEmpty, symbol.count <= 40, symbol.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else { return nil }
            var url = URLComponents(string: "https://fapi.binance.com/fapi/v1/premiumIndex")!
            url.queryItems = [URLQueryItem(name: "symbol", value: symbol)]
            var request = URLRequest(url: url.url!)
            request.cachePolicy = .reloadIgnoringLocalCacheData; request.timeoutInterval = 7
            let mark = try JSONDecoder().decode(BinanceMark.self, from: try await data(request, session: session))
            let received = Date(), timestamp = Date(timeIntervalSince1970: mark.time / 1000)
            guard mark.symbol == symbol, let price = Double(mark.markPrice), price.isFinite, price > 0,
                  mark.time.isFinite, mark.time > 0, timestamp <= received.addingTimeInterval(5) else { return nil }
            return IslandQuote(id: item.id, symbol: item.symbol, price: price, change: nil, currency: item.currency,
                updatedAt: timestamp, receivedAt: received, source: "Binance Futures", basis: "mark",
                delaySeconds: 0, marketState: "open")
        } catch { return nil }
    }
}
