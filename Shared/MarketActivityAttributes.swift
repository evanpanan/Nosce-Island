import ActivityKit
import Foundation

struct MarketActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var quotes: [IslandQuote]
        var redUp: Bool
        var foregroundOnly: Bool
        var page: Int? = nil
        var pageCount: Int { max(1,(quotes.count + 1) / 2) }
        var pageIndex: Int { max(0,page ?? 0) % pageCount }
        var visibleQuotes: [IslandQuote] { Array(quotes.dropFirst(pageIndex * 2).prefix(2)) }
    }
    var sessionName: String
}
