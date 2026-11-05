import Foundation

final class WidgetFixtureProtocol: URLProtocol {
    static var fixture: Data = Data()
    static var failBinance = false
    static var stockData = Data()
    static var stockRequests = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url?.host == "widget-fixture.test" {
            Self.stockRequests += 1
            precondition(request.url?.path == "/v1/widget/quotes")
            precondition(request.httpMethod == "POST")
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-widget-only-token")
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.stockData)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let hl = request.url?.host == "api.hyperliquid.xyz"
        let status = !hl && Self.failBinance ? 503 : 200
        let body = hl ? Self.fixture : Data("{\"symbol\":\"ETHUSDT\",\"markPrice\":\"123.45\",\"time\":\(Int(Date().timeIntervalSince1970 * 1000))}".utf8)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

@main struct WidgetChecks {
    static func main() async throws {
        let order = ["BTC", "ETH", "SOL", "SAVED"]
        precondition(WatchlistOrder.moving(order, from: IndexSet(integer: 0), to: 3) == ["ETH", "SOL", "BTC", "SAVED"])
        precondition(WatchlistOrder.moving(order, from: IndexSet(integer: 2), to: 0) == ["SOL", "BTC", "ETH", "SAVED"])
        precondition(WatchlistOrder.moving(order, from: IndexSet([0, 2]), to: 4) == ["ETH", "SAVED", "BTC", "SOL"])
        precondition(WatchlistOrder.moving(order, from: IndexSet(integer: 1), to: 2) == order)
        precondition(WatchlistOrder.moving(order, from: IndexSet(integer: 8), to: 0) == order)
        precondition(WatchlistOrder.moving(order, from: IndexSet(integer: 1), to: 8) == order)
        let now = Date()
        precondition(MembershipAccess(expiresAt: nil, at: now).watchlistLimit == 3)
        precondition(MembershipAccess(expiresAt: now.addingTimeInterval(60), at: now).islandLimit == 8)
        precondition(MembershipAccess(expiresAt: now, at: now).islandLimit == 1)
        let btc = WidgetWatchItem(id: "hl:BTC", symbol: "BTC", currency: "USD")
        let eth = WidgetWatchItem(id: "bn:ETHUSDT", symbol: "ETH", currency: "USDT")
        let old = IslandQuote(id: btc.id, symbol: btc.symbol, price: 100, change: nil, currency: "USD",
            updatedAt: now.addingTimeInterval(-200), receivedAt: now.addingTimeInterval(-200),
            source: "Hyperliquid", basis: "mark", delaySeconds: 0, marketState: "open")
        let fresh = IslandQuote(id: btc.id, symbol: btc.symbol, price: 101, change: 1, currency: "USD",
            updatedAt: now, receivedAt: now, source: "Hyperliquid", basis: "mark", delaySeconds: 0, marketState: "open")
        let snapshot = WidgetSnapshot(items: [btc], quotes: [fresh], redUp: true, savedAt: now)
        precondition(snapshot.merging([old]).quote(for: btc.id) == fresh)
        precondition(snapshot.merging([]).quote(for: btc.id)?.updatedAt == fresh.updatedAt)
        precondition(old.isStale(at: now) && !fresh.isStale(at: now))
        let changedSelection = WidgetSnapshot(items: [eth], quotes: [], redUp: false, savedAt: now)
        precondition(changedSelection.merging([fresh]).quotes.isEmpty)
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(snapshot))
        precondition(decoded.items == [btc] && decoded.redUp)
        var premium = WidgetSnapshot(items: [btc, eth], quotes: [fresh], redUp: false, savedAt: now, proExpiresAt: now.addingTimeInterval(60))
        precondition(premium.widgetItems(at: now).count == 2)
        precondition(premium.widgetItems(at: now.addingTimeInterval(61)).count == 1)
        premium.proExpiresAt = nil
        precondition(premium.widgetItems(at: now).count == 1)
        // Old app snapshots decode as Free rather than accidentally unlocking Pro.
        let legacy = try JSONDecoder().decode(WidgetSnapshot.self, from: Data(#"{"items":[],"quotes":[],"redUp":false,"savedAt":0}"#.utf8))
        precondition(!legacy.access(at: now).isPro)
        WidgetFixtureProtocol.fixture = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WidgetFixtureProtocol.self]
        let session = URLSession(configuration: config)
        let quotes = await WidgetQuoteFetcher.fetch([btc, eth], session: session)
        precondition(Set(quotes.map(\.id)) == Set([btc.id, eth.id]))
        precondition(quotes.first { $0.id == eth.id }?.price == 123.45)
        WidgetFixtureProtocol.failBinance = true
        let partial = await WidgetQuoteFetcher.fetch([btc, eth], session: session)
        precondition(partial.count == 1 && partial[0].id == btc.id)
        let stock = WidgetWatchItem(id: "stock:NASDAQ:AAPL", symbol: "AAPL", currency: "USD")
        let latestTrade = IslandQuote(id: stock.id, symbol: stock.symbol, price: 100, change: 1, currency: "USD",
            updatedAt: now.addingTimeInterval(-600), receivedAt: now, source: "Alpaca · IEX", basis: "last",
            delaySeconds: 0, marketState: "open")
        struct StockFrame: Encodable { let quotes: [IslandQuote] }
        WidgetFixtureProtocol.stockData = try JSONEncoder().encode(StockFrame(quotes: [latestTrade]))
        let access = WidgetStockAccess(origin: "https://widget-fixture.test", token: "fixture-widget-only-token",
            symbols: [stock.id], expiresAt: now.addingTimeInterval(600))
        precondition(access.valid(at: now))
        let stockQuotes = await WidgetQuoteFetcher.fetch([stock], session: session, stockAccess: access)
        precondition(stockQuotes.count == 1 && WidgetFixtureProtocol.stockRequests == 1)
        precondition(stockQuotes[0].updatedAt < now.addingTimeInterval(-599))
        precondition(stockQuotes[0].receivedAt > now.addingTimeInterval(-1))
        let expired = WidgetStockAccess(origin: access.origin, token: access.token, symbols: access.symbols,
            expiresAt: now.addingTimeInterval(-1))
        precondition(!expired.valid(at: now))
        let expiredQuotes = await WidgetQuoteFetcher.fetch([stock], session: session, stockAccess: expired)
        precondition(expiredQuotes.isEmpty)
        precondition(WidgetFixtureProtocol.stockRequests == 1)
        let denied = WidgetWatchItem(id: "stock:NYSE:IBM", symbol: "IBM", currency: "USD")
        let deniedQuotes = await WidgetQuoteFetcher.fetch([denied], session: session, stockAccess: access)
        precondition(deniedQuotes.isEmpty)
        precondition(WidgetFixtureProtocol.stockRequests == 1)
        session.invalidateAndCancel()
        print("Widget checks passed: truthful timestamps, stale states, quote merge, selection races, HTTP snapshots and partial provider failure")
    }
}
