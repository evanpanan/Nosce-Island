import Foundation
import Security
import CryptoKit

struct ServerStatus: Decodable {
    let ready: Bool
    let backgroundPush: Bool
    let marketCatalog: Bool
    let stocksEnabled: Bool
    let environment: String
}
struct CatalogPage: Decodable {
    let instruments: [Instrument]
    let nextOffset: Int?
    let stocksEnabled: Bool
}
struct StreamFrame: Decodable { let quotes: [IslandQuote] }

enum ServiceError: LocalizedError {
    case configuration, unavailable(Int), credentials
    var errorDescription: String? {
        switch self {
        case .configuration: return tr("行情服务暂不可用，请稍后重试。", "Market data is temporarily unavailable. Please try again later.")
        case .credentials: return tr("无法安全保存设备凭证。", "Could not securely save device credentials.")
        case .unavailable(let code): return tr("行情服务暂不可用（\(code)），请稍后重试。", "The market service is unavailable (\(code)). Please retry later.")
        }
    }
}

@MainActor final class NosceAPI {
    var isConfigured: Bool { (try? base) != nil }
    private var registration: Task<String, Error>?
    private var token: String?
    private var base: URL {
        get throws {
            guard let raw = Bundle.main.object(forInfoDictionaryKey: "NosceAPIBaseURL") as? String,
                  let url = URL(string: raw), url.scheme == "https", let host = url.host,
                  !host.hasSuffix(".invalid"), !raw.contains("$("),
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                  url.path.isEmpty || url.path == "/" else { throw ServiceError.configuration }
            return url
        }
    }
    private var keychainQuery: [String: Any] {
        get throws {
            let hostHash = SHA256.hash(data: Data(try base.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
            return [kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "NosceIsland") + ".service." + hostHash,
                    kSecAttrAccount as String: "installation"]
        }
    }
    private func readToken() throws -> String? {
        var query = try keychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw ServiceError.credentials }
        return String(data: data, encoding: .utf8)
    }
    private func saveToken(_ value: String) throws {
        let query = try keychainQuery
        let values: [String: Any] = [kSecValueData as String: Data(value.utf8),
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ServiceError.credentials }
        token = value
    }
    private func forgetToken() throws {
        SecItemDelete(try keychainQuery as CFDictionary)
        token = nil
    }
    private func credentials() async throws -> String {
        if let token { return token }
        if let saved = try readToken() { token = saved; return saved }
        if let registration { return try await registration.value }
        let requestURL = try base.appendingPathComponent("v1/installations")
        let task = Task<String, Error> {
            var request = URLRequest(url: requestURL)
            request.httpMethod = "POST"
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 201 else {
                throw ServiceError.unavailable((response as? HTTPURLResponse)?.statusCode ?? 0)
            }
            struct Installation: Decodable { let token: String }
            return try JSONDecoder().decode(Installation.self, from: data).token
        }
        registration = task
        defer { registration = nil }
        let value = try await task.value
        try saveToken(value)
        return value
    }
    private func request(_ path: String, method: String = "GET", body: Data? = nil, allow503: Bool = false) async throws -> Data {
        for attempt in 0..<2 {
            var request = URLRequest(url: try base.appendingPathComponent(path))
            request.timeoutInterval = 15
            request.httpMethod = method
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("Bearer " + (try await credentials()), forHTTPHeaderField: "Authorization")
            if let body { request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 && attempt == 0 { try forgetToken(); continue }
            guard (200..<300).contains(status) || (allow503 && status == 503) else { throw ServiceError.unavailable(status) }
            return data
        }
        throw ServiceError.unavailable(401)
    }
    func status() async throws -> ServerStatus {
        try JSONDecoder().decode(ServerStatus.self, from: await request("readyz", allow503: true))
    }
    func foregroundHeartbeat() async throws {
        _ = try await request("v1/presence", method: "POST")
    }
    func catalog() async throws -> ([Instrument], Bool) {
        var offset: Int? = 0
        var result: [Instrument] = []
        var stocks = false
        while let next = offset {
            // Query is assembled separately; appendingPathComponent must not escape '?'.
            var components = URLComponents(url: try base.appendingPathComponent("v1/catalog"), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "offset", value: String(next))]
            var req = URLRequest(url: components.url!)
            req.setValue("Bearer " + (try await credentials()), forHTTPHeaderField: "Authorization")
            req.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 { try forgetToken(); throw ServiceError.unavailable(401) }
            guard status == 200 else { throw ServiceError.unavailable(status) }
            let page = try JSONDecoder().decode(CatalogPage.self, from: data)
            result += page.instruments
            stocks = page.stocksEnabled
            offset = page.nextOffset
            if let offset, offset <= next { throw ServiceError.unavailable(502) }
            if result.count > 100000 { throw ServiceError.unavailable(502) }
        }
        return (result, stocks)
    }
    func stockQuotes(symbols: [String]) async throws -> StreamFrame {
        struct Selection: Encodable { let symbols: [String] }
        return try JSONDecoder().decode(StreamFrame.self, from: await request("v1/quotes", method: "POST",
            body: JSONEncoder().encode(Selection(symbols: symbols))))
    }
    func socket(symbols: [String]) async throws -> URLSessionWebSocketTask {
        var components = URLComponents(url: try base.appendingPathComponent("v1/stream"), resolvingAgainstBaseURL: false)!
        components.scheme = "wss"
        components.queryItems = [URLQueryItem(name: "symbols", value: symbols.joined(separator: ","))]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer " + (try await credentials()), forHTTPHeaderField: "Authorization")
        let socket = URLSession.shared.webSocketTask(with: request)
        socket.resume()
        return socket
    }
    func register(activityID: String, pushToken: Data, symbols: [String], redUp: Bool) async throws {
        #if DEBUG
        let environment = "development"
        #else
        let environment = "production"
        #endif
        let body: [String: Any] = ["activity_id": activityID,
            "push_token": pushToken.map { String(format: "%02x", $0) }.joined(),
            "environment": environment, "symbols": symbols, "red_up": redUp]
        _ = try await request("v1/sessions", method: "POST", body: JSONSerialization.data(withJSONObject: body))
    }
    func unregister(activityID: String) async throws {
        _ = try await request("v1/sessions/" + activityID, method: "DELETE")
    }
    func deleteInstallation() async throws {
        _ = try await request("v1/installation", method: "DELETE")
        try forgetToken()
    }
    func profile() async throws -> AccountProfile {
        try JSONDecoder().decode(AccountProfile.self,from:await request("v1/me"))
    }
    func linkAppStore(_ signed: String) async throws -> AccountProfile {
        let body = try JSONSerialization.data(withJSONObject:["signed_app_transaction":signed])
        return try JSONDecoder().decode(AccountProfile.self,from:await request("v1/app-store/identity",method:"POST",body:body))
    }
    func submitPurchase(_ signed: String) async throws -> AccountProfile {
        let body = try JSONSerialization.data(withJSONObject:["signed_transaction":signed])
        return try JSONDecoder().decode(AccountProfile.self,from:await request("v1/purchases",method:"POST",body:body))
    }

}

struct Instrument: Codable, Identifiable, Hashable {
    let id: String
    let symbol: String
    let name: String
    let market: String
    let currency: String
    let provider: String
    let exchange: String
    let delaySeconds: Int
    let region: String
    let settlementCurrency: String
    enum CodingKeys: String, CodingKey {
        case id, symbol, name, market, currency, provider, exchange
        case delaySeconds = "delay_seconds"
        case region
        case settlementCurrency = "settlement_currency"
    }
    init(id: String) {
        self.id = id
        symbol = String(id.split(separator: ":").last ?? Substring(id))
        name = id
        market = "Crypto"; currency = "USD"; provider = "hyperliquid"; exchange = ""; delaySeconds = 0
        region = "Global"; settlementCurrency = ""
    }
    init(publicID: String, symbol: String, market: String, currency: String, provider: String, region: String = "Global", settlement: String = "") {
        id = publicID; self.symbol = symbol; name = symbol; self.market = market
        self.currency = currency; self.provider = provider; self.region = region
        settlementCurrency = settlement; exchange = ""; delaySeconds = 0
    }
    var typeLabel: String {
        switch market {
        case "US": return tr("美股", "US stock")
        case "HK": return tr("港股", "HK stock")
        case "Contracts": return provider == "binance" ? tr("币安股票相关合约", "Binance equity perpetual") : tr("HIP-3 合约", "HIP-3 contract")
        default: return tr("加密永续合约", "Crypto perpetual")
        }
    }
}


// Public foreground quotes are independent of Nosce's APNs and purchase services.
// No credentials, fake quotes, local timers pretending to be live, or user setup.
@MainActor enum PublicMarketFeed {
    static func info<T: Decodable>(_ body: [String:String], as type: T.Type) async throws -> T {
        var request = URLRequest(url:URL(string:"https://api.hyperliquid.xyz/info")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject:body)
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 12
        let (data,response) = try await URLSession.shared.data(for:request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(type,from:data)
    }
    static func get(_ path: String) async throws -> Data {
        var request = URLRequest(url:URL(string:"https://fapi.binance.com" + path)!)
        request.timeoutInterval = 12; request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data,response) = try await URLSession.shared.data(for:request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }
    static func hlInstrument(_ name: String, dex: String) -> Instrument {
        let coin = dex.isEmpty || name.contains(":") ? name : dex + ":" + name
        // HIP-3 can include stocks, commodities and other contracts. Do not infer an exchange-stock listing.
        return Instrument(publicID:"hl:" + coin,symbol:String(coin.split(separator:":").last ?? Substring(coin)),
            market:dex.isEmpty ? "Crypto" : "Contracts",currency:"USD",provider:"hyperliquid")
    }
    struct BinanceExchange: Decodable {
        struct Asset: Decodable {
            let symbol: String; let baseAsset: String; let status: String; let contractType: String
            let quoteAsset: String; let underlyingType: String?; let marginAsset: String?
            var instrument: Instrument? {
                guard status == "TRADING", contractType == "PERPETUAL", quoteAsset == "USDT",
                      let kind = underlyingType, ["COIN","EQUITY","HK_EQUITY"].contains(kind) else { return nil }
                let number = String(symbol.dropFirst(2).dropLast(4))
                let hk = kind == "HK_EQUITY" && symbol.hasPrefix("HK") && !number.isEmpty && number.allSatisfy(\.isNumber)
                return Instrument(publicID:"bn:" + symbol,symbol:baseAsset,market:kind == "COIN" ? "Crypto" : "Contracts",
                    currency:hk ? "HKD" : "USDT",provider:"binance",region:kind == "HK_EQUITY" ? "HK" : kind == "EQUITY" ? "US" : "Global",settlement:marginAsset ?? "USDT")
            }
        }
        let symbols: [Asset]
    }
    struct BinanceMark: Decodable {
        let symbol: String; let markPrice: String; let time: Double
    }
    static func binanceQuote(_ item: Instrument, symbol: String, price: String, milliseconds: Double) -> IslandQuote? {
        let received = Date(), timestamp = Date(timeIntervalSince1970:milliseconds / 1000)
        guard item.id == "bn:" + symbol, let price = Double(price), price.isFinite, price > 0,
              milliseconds.isFinite, milliseconds > 0, timestamp <= received.addingTimeInterval(5) else { return nil }
        return IslandQuote(id:item.id,symbol:item.symbol,price:price,change:nil,currency:item.currency,
            updatedAt:timestamp,receivedAt:received,source:"Binance Futures",basis:"mark",delaySeconds:0,marketState:"open")
    }
    static func hlQuote(_ coin: String, context: HLContext) -> IslandQuote? {
        guard let price = context.price else { return nil }
        let received = Date()
        return IslandQuote(id:"hl:" + coin,symbol:String(coin.split(separator:":").last ?? Substring(coin)),
            price:price,change:context.change,currency:"USD",updatedAt:received,receivedAt:received,
            source:"Hyperliquid",basis:"mark",delaySeconds:0,marketState:"open")
    }
    static func stream(_ items: [Instrument], accept: @escaping @MainActor (IslandQuote) -> Void) async throws {
        let hl = items.filter { $0.id.hasPrefix("hl:") }
        let bn = items.filter { $0.id.hasPrefix("bn:") }
        guard hl.count + bn.count == items.count else { throw ServiceError.unavailable(422) }
        try await withThrowingTaskGroup(of:Void.self) { group in
            if !hl.isEmpty { group.addTask { try await hyperliquid(hl,accept:accept) } }
            if !bn.isEmpty { group.addTask { try await binance(bn,accept:accept) } }
            defer { group.cancelAll() }
            try await group.next()
        }
    }
    private static func hyperliquid(_ items: [Instrument], accept: @escaping @MainActor (IslandQuote) -> Void) async throws {
        let coins = items.map { String($0.id.dropFirst(3)) }
        let dexes = Set(coins.map { $0.contains(":") ? String($0.split(separator:":")[0]) : "" })
        for dex in dexes.sorted() {
            if let snapshot = try? await info(["type":"metaAndAssetCtxs","dex":dex],as:HLSnapshot.self) {
                try Task.checkCancellation()
                for (asset,context) in zip(snapshot.meta.universe,snapshot.contexts) where asset.isDelisted != true {
                    let coin = String(hlInstrument(asset.name,dex:dex).id.dropFirst(3))
                    if coins.contains(coin), let quote = hlQuote(coin,context:context) { accept(quote) }
                }
            }
        }
        try Task.checkCancellation()
        let ws = URLSession.shared.webSocketTask(with:URL(string:"wss://api.hyperliquid.xyz/ws")!)
        ws.resume()
        try await withTaskCancellationHandler(operation: {
            defer { ws.cancel(with:.goingAway,reason:nil) }
            for coin in coins {
                let body: [String:Any] = ["method":"subscribe","subscription":["type":"activeAssetCtx","coin":coin]]
                try await ws.send(.string(String(decoding:try JSONSerialization.data(withJSONObject:body),as:UTF8.self)))
            }
            var lastQuote = Dictionary(uniqueKeysWithValues:coins.map { ($0,Date()) })
            let heartbeat = Task { @MainActor in
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for:.seconds(10))
                        if lastQuote.values.contains(where:{ Date().timeIntervalSince($0) > 35 }) {
                            ws.cancel(with:.goingAway,reason:nil); return
                        }
                        try await ws.send(.string("{\"method\":\"ping\"}"))
                    } catch { ws.cancel(with:.goingAway,reason:nil); return }
                }
            }
            defer { heartbeat.cancel() }
            while !Task.isCancelled {
                let frame = try await ws.receive()
                try Task.checkCancellation()
                let data = bytes(frame)
                let message = try JSONDecoder().decode(HLMessage.self,from:data)
                if let payload = message.data, coins.contains(payload.coin),let quote = hlQuote(payload.coin,context:payload.ctx) {
                    lastQuote[payload.coin] = Date(); accept(quote)
                }
            }
        },onCancel:{ ws.cancel(with:.goingAway,reason:nil) })
    }
    private static func binance(_ items: [Instrument], accept: @escaping @MainActor (IslandQuote) -> Void) async throws {
        for item in items {
            let symbol = String(item.id.dropFirst(3))
            if let data = try? await get("/fapi/v1/premiumIndex?symbol=" + symbol),
               let mark = try? JSONDecoder().decode(BinanceMark.self,from:data),
               let quote = binanceQuote(item,symbol:mark.symbol,price:mark.markPrice,milliseconds:mark.time) { accept(quote) }
            try Task.checkCancellation()
        }
        let streams = items.map { String($0.id.dropFirst(3)).lowercased() + "@markPrice@1s" }.joined(separator:"/")
        let ws = URLSession.shared.webSocketTask(with:URL(string:"wss://fstream.binance.com/market/stream?streams=" + streams)!)
        ws.resume()
        try await withTaskCancellationHandler(operation: {
            defer { ws.cancel(with:.goingAway,reason:nil) }
            var lastQuote = Dictionary(uniqueKeysWithValues:items.map { ($0.id,Date()) })
            let watchdog = Task { @MainActor in
                while !Task.isCancelled {
                    do { try await Task.sleep(for:.seconds(10)) } catch { return }
                    if lastQuote.values.contains(where:{ Date().timeIntervalSince($0) > 35 }) {
                        ws.cancel(with:.goingAway,reason:nil); return
                    }
                }
            }
            defer { watchdog.cancel() }
            while !Task.isCancelled {
                let message = try await ws.receive()
                try Task.checkCancellation()
                guard let body = try JSONSerialization.jsonObject(with:bytes(message)) as? [String:Any] else { continue }
                let value = body["data"] as? [String:Any] ?? body
                guard let symbol = value["s"] as? String,let price = value["p"] as? String,
                      let stamp = value["E"] as? Double,let item = items.first(where:{ $0.id == "bn:" + symbol }),
                      let quote = binanceQuote(item,symbol:symbol,price:price,milliseconds:stamp) else { continue }
                lastQuote[item.id] = Date(); accept(quote)
            }
        },onCancel:{ ws.cancel(with:.goingAway,reason:nil) })
    }
    private static func bytes(_ message: URLSessionWebSocketTask.Message) -> Data {
        switch message {
        case .data(let data):return data
        case .string(let text):return Data(text.utf8)
        @unknown default:return Data()
        }
    }
}
