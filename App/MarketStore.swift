import SwiftUI
import ActivityKit
import UIKit
import WidgetKit

func tr(_ chinese: String, _ english: String) -> String {
    Locale.preferredLanguages.first?.hasPrefix("zh") == true ? chinese : english
}

@MainActor final class MarketStore: ObservableObject {
    @Published var catalog: [Instrument] = [Instrument(id: "hl:BTC")]
    @Published var selected: [String] = ["hl:BTC"]
    @Published var quotes: [String: IslandQuote] = [:]
    @Published var history: [String: [Double]] = [:]
    @Published var errors: [String: String] = [:]
    @Published var redUp = UserDefaults.standard.bool(forKey: "redUp") {
        didSet { syncWidgets(force: true) }
    }
    @Published var showPro = false
    @Published var proExpiresAt: Date? = UserDefaults.standard.object(forKey: "verifiedProExpiryV1") as? Date
    private var membershipExpiryTask: Task<Void, Never>?
    private var membershipRefreshTask: Task<Void, Never>?
    @Published var activityRunning = false
    @Published var activityStarting = false
    @Published var lastActivityResult = tr("尚未开启盯盘", "Watching is not active")
    @Published var lastActivityID = "—"
    @Published var lastActivityState = "none"
    @Published var message: String?
    @Published var loading = false
    @Published var catalogLoading = false
    @Published var widgetStockStatus = tr("股票小组件权限将在连接后检查", "Stock widget access is checked when connected")
    @Published var stockNotice: String?
    @Published var catalogNotice: String?
    @Published var connection = tr("等待连接", "Waiting")
    @Published var backgroundStatus = tr("正在检查服务", "Checking service")
    @Published var stocksEnabled = false
    private var lastWidgetWrite = Date.distantPast
    private var lastWidgetReload = Date.distantPast
    private let api = NosceAPI()
    lazy var commerce: CommerceStore = {
        let value = CommerceStore(api: api)
        value.onProfileChange = { [weak self] profile in self?.applyMembership(profile) }
        return value
    }()
    var access: MembershipAccess { MembershipAccess(expiresAt: proExpiresAt) }
    var isPro: Bool { access.isPro }
    var watchlistLimit: Int { access.watchlistLimit }
    var activeSelected: [String] { Array(selected.prefix(watchlistLimit)) }
    var activityIDs: [String] { access.displayIDs(in: selected) }
    var savedInstruments: [Instrument] { selected.map { id in catalog.first { $0.id == id } ?? Instrument(id: id) } }
    private func applyMembership(_ profile: AccountProfile?) {
        let before = access.isPro
        let next = profile?.pro == true ? profile?.expiresAt.map(Date.init(timeIntervalSince1970:)) : nil
        proExpiresAt = next
        UserDefaults.standard.set(next, forKey: "verifiedProExpiryV1")
        scheduleMembershipExpiry()
        if before != access.isPro { Task { await membershipChanged() } }
        else { syncWidgets(force: true) }
    }
    private func scheduleMembershipExpiry() {
        membershipExpiryTask?.cancel()
        if let next = proExpiresAt, next > Date() {
            membershipExpiryTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(max(0, next.timeIntervalSinceNow))) } catch { return }
                guard let self, self.proExpiresAt == next else { return }
                self.proExpiresAt = nil
                UserDefaults.standard.removeObject(forKey: "verifiedProExpiryV1")
                await self.membershipChanged()
                if self.foreground { await self.commerce.refresh() }
            }
        }
    }
    private func membershipChanged() async {
        // End obsolete multi-asset content before applying new access; keep the saved watchlist.
        if activityRunning || activityStarting { await endActivity() }
        syncWidgets(force: true)
        if foreground { startRefreshing() }
    }
    private var streamTask: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var mixedPublicTask: Task<Void, Never>?
    private var presenceTask: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var discoveryTask: Task<Void, Never>?
    private var widgetEntitlementTask: Task<Void, Never>?
    private var widgetAccessTask: Task<Void, Never>?
    private var widgetAccessID = UUID()
    private var widgetAccessSymbols: [String] = []
    private var activityTask: Task<Void, Never>?
    private var tokenTask: Task<Void, Never>?
    private var registrationTask: Task<Void, Never>?
    private var localPublishTask: Task<Void, Never>?
    private var localRevision = 0
    private var pageOrigin = Date()
    private var initialPage = 0
    private var localPublisherID = UUID()
    private var observed: Activity<MarketActivityAttributes>?
    private var registrationBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var latestPushToken: Data?
    private var lastFrameAt = Date.distantPast
    private var foreground = false
    private var generation = UUID()
    private var activityGeneration = UUID()

    init() {
        if let ids = UserDefaults.standard.stringArray(forKey: "selectedServerV1"), !ids.isEmpty {
            selected = Array(NSOrderedSet(array:ids).array.compactMap { $0 as? String }.prefix(8))
        }
        if let data = UserDefaults.standard.data(forKey: "serverCatalogV1"),
           let saved = try? JSONDecoder().decode([Instrument].self, from: data) { catalog = saved }
        for quote in WidgetSnapshotStore.read().quotes where selected.contains(quote.id) { quotes[quote.id] = quote }
        syncActivityState()
        syncWidgets(force: true)
        scheduleMembershipExpiry()
    }
    private func syncWidgets(force: Bool = false) {
        let date = Date()
        guard force || date.timeIntervalSince(lastWidgetWrite) >= 30 else { return }
        let widgetIDs = isPro ? activeSelected : activityIDs
        let items = widgetIDs.map { id -> WidgetWatchItem in
            let item = catalog.first { $0.id == id } ?? Instrument(id: id)
            return WidgetWatchItem(id: item.id, symbol: item.symbol, currency: item.currency)
        }
        let snapshot = WidgetSnapshot(items: items, quotes: islandQuotes, redUp: redUp, savedAt: date, proExpiresAt: proExpiresAt)
        guard WidgetSnapshotStore.write(snapshot) else { return }
        refreshWidgetAccess()
        lastWidgetWrite = date
        if force || date.timeIntervalSince(lastWidgetReload) >= 60 {
            lastWidgetReload = date
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshotStore.kind)
        }
    }
    private func refreshWidgetEntitlement() {
        guard foreground, api.isConfigured, widgetEntitlementTask == nil else { return }
        if let current = WidgetEntitlementAccessStore.read(), current.expiresAt > Date().addingTimeInterval(86400) { return }
        widgetEntitlementTask = Task { [weak self] in
            guard let self else { return }
            defer { self.widgetEntitlementTask = nil }
            if let access = try? await self.api.widgetEntitlementAccess(), !Task.isCancelled {
                WidgetEntitlementAccessStore.write(access)
                WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshotStore.kind)
            }
        }
    }
    private func refreshWidgetAccess() {
        refreshWidgetEntitlement()
        let ids = (isPro ? activeSelected : activityIDs).filter { $0.hasPrefix("stock:") }.sorted()
        if ids.isEmpty {
            widgetAccessTask?.cancel(); widgetAccessTask = nil; widgetAccessID = UUID()
            WidgetStockAccessStore.clear()
            widgetStockStatus = tr("未选择股票", "No stocks selected")
            return
        }
        guard foreground else { return }
        if let saved = WidgetStockAccessStore.read(), Set(saved.symbols) == Set(ids),
           saved.expiresAt > Date().addingTimeInterval(86400) {
            widgetStockStatus = tr("股票小组件可独立检查报价，刷新由 iOS 调度", "Stock widgets can check quotes independently; iOS schedules refreshes")
            return
        }
        if widgetAccessTask != nil && widgetAccessSymbols == ids { return }
        widgetAccessTask?.cancel()
        let job = UUID(); widgetAccessID = job; widgetAccessSymbols = ids
        widgetAccessTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.widgetAccessID == job { self.widgetAccessTask = nil } }
            do {
                let access = try await self.api.widgetStockAccess(symbols: ids)
                guard !Task.isCancelled, self.widgetAccessID == job,
                      (self.isPro ? self.activeSelected : self.activityIDs).filter({ $0.hasPrefix("stock:") }).sorted() == ids else { return }
                guard WidgetStockAccessStore.write(access) else {
                    self.widgetStockStatus = tr("小组件共享空间不可用，请检查 App Group 签名配置", "Widget storage unavailable; check App Group signing")
                    return
                }
                self.widgetStockStatus = tr("股票小组件刷新权限已就绪，刷新由 iOS 调度", "Stock widget refresh access is ready; iOS schedules updates")
                WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshotStore.kind)
            } catch {
                if !Task.isCancelled && self.widgetAccessID == job {
                    self.widgetStockStatus = tr("小组件未取得股票刷新权限，暂时使用 App 快照", "Stock widget access unavailable; using the app snapshot")
                }
            }
        }
    }
    var chosen: [Instrument] { activeSelected.map { id in catalog.first { $0.id == id } ?? Instrument(id: id) } }
    var islandQuotes: [IslandQuote] { activityIDs.compactMap { quotes[$0] } }
    var visibleInstruments: [Instrument] {
        let index = observed?.content.state.pageIndex ?? 0
        return Array(activityIDs.dropFirst(index).prefix(1)).map { id in catalog.first { $0.id == id } ?? Instrument(id: id) }
    }
    func color(_ change: Double?) -> Color {
        MarketPalette.price(IslandQuote.priceTone(change: change, redUp: redUp))
    }
    func toggle(_ item: Instrument) {
        if activityRunning || activityStarting {
            message = tr("请先结束当前盯盘，再更换资产。", "Stop the current watch before changing instruments.")
            return
        }
        if selected.contains(item.id) {
            guard selected.count > 1 else { return }
            selected.removeAll { $0 == item.id }
        } else {
            guard selected.count < watchlistLimit else {
                if !isPro { showPro = true } else { message = tr("Pro 最多关注 8 个资产。", "Pro supports up to 8 instruments.") }
                return
            }
            selected.append(item.id)
        }
        UserDefaults.standard.set(selected, forKey: "selectedServerV1")
        syncWidgets(force: true)
        if foreground { startRefreshing() }
    }
    func moveSelected(from offsets: IndexSet, to destination: Int) {
        guard !activityStarting else { return }
        let next = WatchlistOrder.moving(selected, from: offsets, to: destination)
        guard next != selected else { return }
        let before = Set(activeSelected)
        let after = Set(next.prefix(watchlistLimit))
        // Reordering active assets is safe; replacing an active asset needs a new watch session.
        guard !activityRunning || before == after else {
            message = tr("请先结束盯盘，再将保留的资产移入前三位。", "Stop watching before moving a saved asset into the first three positions.")
            return
        }
        selected = next
        UserDefaults.standard.set(next, forKey: "selectedServerV1")
        pageOrigin = Date(); initialPage = 0
        syncWidgets(force: true)
        if before != after, foreground { startRefreshing() }
        Task { await updateActivity() }
    }
    func moveSelected(_ id: String, before target: String) {
        guard let source = selected.firstIndex(of: id), let targetIndex = selected.firstIndex(of: target), source != targetIndex else { return }
        // Dropping on a card swaps past it in the direction of travel.
        moveSelected(from: IndexSet(integer: source), to: source < targetIndex ? targetIndex + 1 : targetIndex)
    }
    func startRefreshing() {
        stopRefreshing()
        foreground = true
        membershipRefreshTask?.cancel()
        membershipRefreshTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.foreground {
                await self.commerce.refresh()
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
        refreshWidgetAccess()
        syncActivityState()
        scheduleLocalActivityUpdate()
        let generation = self.generation
        if api.isConfigured {
            presenceTask = Task { [weak self] in
                guard let self else { return }
                while !Task.isCancelled, self.foreground, self.generation == generation {
                    do { try await self.api.foregroundHeartbeat() }
                    catch { /* Presence must never interrupt public market data. */ }
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                }
            }
        }
        streamTask = Task { [weak self] in
            guard let self else { return }
            var delay = 1
            while !Task.isCancelled && self.generation == generation {
                self.loading = true
                do {
                    if self.activeSelected.allSatisfy({ $0.hasPrefix("hl:") || $0.hasPrefix("bn:") }) {
                        self.backgroundStatus = self.api.isConfigured ? tr("后台推送将在开启盯盘时检查", "Background push is checked when starting a watch") : tr("后台推送尚未上线", "Background push is not available yet")
                        self.connection = tr("正在直连公开行情…", "Connecting to public market data…")
                        if self.discoveryTask == nil && self.catalog.count <= 1 { self.reloadCatalog() }
                        try await PublicMarketFeed.stream(self.chosen) { [weak self] quote in
                            guard let self, self.generation == generation else { return }
                            self.acceptQuote(quote)
                            self.connection = tr("公开行情 · 实时连接", "Public market data · streaming")
                            self.loading = false
                        }
                        throw URLError(.networkConnectionLost)
                    }
                    let stockIDs = self.activeSelected.filter { $0.hasPrefix("stock:") }
                    guard !stockIDs.isEmpty else { throw ServiceError.unavailable(422) }
                    let publicItems = self.chosen.filter { $0.id.hasPrefix("hl:") || $0.id.hasPrefix("bn:") }
                    self.mixedPublicTask?.cancel()
                    if !publicItems.isEmpty {
                        self.mixedPublicTask = Task { [weak self] in
                            guard let self else { return }
                            while !Task.isCancelled, self.generation == generation {
                                do {
                                    try await PublicMarketFeed.stream(publicItems) { [weak self] quote in
                                        guard let self, self.generation == generation else { return }
                                        self.acceptQuote(quote)
                                    }
                                } catch { if Task.isCancelled { return } }
                                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                            }
                        }
                    }
                    while !Task.isCancelled, self.generation == generation {
                        let frame = try await self.api.stockQuotes(symbols: stockIDs)
                        guard !Task.isCancelled, self.generation == generation else { return }
                        for quote in frame.quotes { self.acceptQuote(quote) }
                        let received = Set(frame.quotes.map(\.id))
                        for id in stockIDs where !received.contains(id) {
                            self.errors[id] = tr("股票报价暂不可用，保留上次报价与时间。", "Stock quote unavailable; previous price and time are preserved.")
                        }
                        self.connection = tr("股票 HTTP 行情 · 15 秒查询", "Stock HTTP snapshots · 15s polling")
                        self.loading = false; delay = 1
                        try await Task.sleep(for: .seconds(max(5, min(30, frame.refreshAfterSeconds ?? 15))))
                    }

                } catch {
                    guard !Task.isCancelled, self.generation == generation else { return }
                    self.connection = error.localizedDescription
                    for id in self.activeSelected { self.errors[id] = tr("连接中断，等待重连；旧报价不会刷新时间。", "Disconnected; retrying. Old quote timestamps are preserved.") }
                }
                self.mixedPublicTask?.cancel(); self.mixedPublicTask = nil
                self.heartbeat?.cancel(); self.heartbeat = nil
                self.socket?.cancel(with: .goingAway, reason: nil); self.socket = nil
                self.loading = false
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                delay = min(delay * 2, 30)
            }
        }
    }
    private func acceptQuote(_ quote: IslandQuote) {
        guard selected.contains(quote.id), !Task.isCancelled else { return }
        if let previous = quotes[quote.id], previous.updatedAt > quote.updatedAt { return }
        let changed = quotes[quote.id]?.updatedAt != quote.updatedAt
        quotes[quote.id] = quote; errors[quote.id] = nil
        if changed {
            history[quote.id,default:[]].append(quote.price)
            history[quote.id] = Array(history[quote.id,default:[]].suffix(90))
        }
        scheduleLocalActivityUpdate()
        syncWidgets()
    }
    func stopRefreshing() {
        foreground = false
        generation = UUID()
        streamTask?.cancel(); streamTask = nil
        discoveryTask?.cancel(); discoveryTask = nil; catalogLoading = false
        mixedPublicTask?.cancel(); mixedPublicTask = nil
        heartbeat?.cancel(); heartbeat = nil
        presenceTask?.cancel(); presenceTask = nil
        membershipRefreshTask?.cancel(); membershipRefreshTask = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        loading = false
        scheduleLocalActivityUpdate()
        syncWidgets(force: true)
        // Preserve real quote expiry on background; entering Home is not a stale market event.
    }
    func reloadCatalog() {
        guard !catalogLoading else { return }
        catalogLoading = true
        let catalogGeneration = generation
        discoveryTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == catalogGeneration { self.catalogLoading = false; self.discoveryTask = nil } }
            if !self.api.isConfigured { await self.reloadPublicCatalog(); return }
            do {
                let (items, enabled) = try await self.api.catalog()
                self.stocksEnabled = enabled
                switch self.api.stockStatus {
                case "restricted": self.stockNotice = tr("当前用户未获个人测试权限。请在后台服务页选择本机对应的用户编号并保存。", "This user is not enabled for personal testing. Select this device's user ID in admin services.")
                case "not_configured": self.stockNotice = tr("美股尚未配置。请在后台服务 → 美股报价中填写 Alpaca Paper 密钥并选择测试用户。", "US stocks are not configured. Save Alpaca Paper keys and a personal test user in admin services.")
                case "unavailable": self.stockNotice = tr("美股目录未能读取，请在后台美股配置中测试连接，并检查密钥与数据权限。", "The US stock catalog is unavailable. Test the Alpaca connection in admin services.")
                default: self.stockNotice = nil
                }

                let retained = self.catalog.filter { $0.id.hasPrefix("hl:") || $0.id.hasPrefix("bn:") }
                self.catalog = items + retained.filter { item in !items.contains(where: { $0.id == item.id }) }
                self.catalogNotice = nil
                if let data = try? JSONEncoder().encode(self.catalog) { UserDefaults.standard.set(data, forKey: "serverCatalogV1") }
                await self.reloadPublicCatalog()
            } catch { self.stockNotice = tr("美股服务连接失败，请确认后台已部署并测试 Alpaca 连接。", "The US stock service could not connect. Check deployment and test Alpaca in admin services."); await self.reloadPublicCatalog() }
        }
    }
    private func reloadPublicCatalog() async {
        // Discover independent sources separately; a blocked Binance endpoint must not hide Hyperliquid.
        var items = catalog.filter { $0.id.hasPrefix("hl:") || $0.id.hasPrefix("bn:") || (stocksEnabled && $0.id.hasPrefix("stock:")) }
        var failed = 0
        func persist() {
            catalog = items.sorted { $0.id < $1.id }
            if let data = try? JSONEncoder().encode(catalog) { UserDefaults.standard.set(data,forKey:"serverCatalogV1") }
        }
        do {
            let dexes = try await PublicMarketFeed.info(["type":"perpDexs"],as:[HLDex?].self)
            for dex in Array(Set([""] + dexes.compactMap { $0?.name })).sorted() {
                guard !Task.isCancelled else { return }
                do {
                    let meta = try await PublicMarketFeed.info(["type":"meta","dex":dex],as:HLMeta.self)
                    guard !Task.isCancelled else { return }
                    items.removeAll { item in
                        guard item.id.hasPrefix("hl:") else { return false }
                        let coin = String(item.id.dropFirst(3))
                        return (coin.contains(":") ? String(coin.split(separator:":")[0]) : "") == dex
                    }
                    items += meta.universe.filter { $0.isDelisted != true }.map { PublicMarketFeed.hlInstrument($0.name,dex:dex) }
                    persist()
                } catch { failed += 1 }
            }
        } catch { failed += 1 }
        guard !Task.isCancelled else { return }
        do {
            let data = try await PublicMarketFeed.get("/fapi/v1/exchangeInfo")
            let exchange = try JSONDecoder().decode(PublicMarketFeed.BinanceExchange.self,from:data)
            guard !Task.isCancelled else { return }
            items.removeAll { $0.id.hasPrefix("bn:") }
            items += exchange.symbols.compactMap(\.instrument)
            persist()
        } catch { failed += 1 }
        guard !Task.isCancelled else { return }
        catalogNotice = failed > 0 ? tr("部分市场连接失败，可重试；其他行情仍可使用。", "Some markets could not connect. Other quotes remain available.") : nil
    }
    private func running(_ activity: Activity<MarketActivityAttributes>) -> Bool {
        activity.activityState == .active || activity.activityState == .stale
    }
    func syncActivityState() {
        let activities = Activity<MarketActivityAttributes>.activities
        if let activity = activities.first(where: running) {
            if activity.content.state.quotes.count > access.islandLimit {
                Task { await endActivity() }; return
            }
            if observed?.id != activity.id { observe(activity) }
            activityRunning = true
            // Recover server-updated content after reopening, without replacing it with an older local quote.
            for quote in activity.content.state.quotes {
                if quotes[quote.id] == nil || quotes[quote.id]!.receivedAt < quote.receivedAt { quotes[quote.id] = quote }
            }
        } else { activityRunning = false }
    }
    private func observe(_ activity: Activity<MarketActivityAttributes>) {
        activityTask?.cancel(); tokenTask?.cancel(); registrationTask?.cancel()
        observed = activity; latestPushToken = activity.pushToken
        pageOrigin = Date(); initialPage = activity.content.state.pageIndex
        let lifecycle = UUID(); activityGeneration = lifecycle
        lastActivityID = activity.id
        lastActivityState = String(describing: activity.activityState)
        if !activity.content.state.foregroundOnly, let token = latestPushToken { register(activity: activity, token: token, lifecycle: lifecycle) }
        tokenTask = Task { [weak self] in
            for await token in activity.pushTokenUpdates {
                guard let self, !Task.isCancelled, self.activityGeneration == lifecycle else { return }
                guard !activity.content.state.foregroundOnly else { continue }
                self.latestPushToken = token
                self.register(activity: activity, token: token, lifecycle: lifecycle)
            }
        }
        activityTask = Task { [weak self] in
            for await state in activity.activityStateUpdates {
                guard let self, !Task.isCancelled, self.activityGeneration == lifecycle else { return }
                self.lastActivityState = String(describing: state)
                self.activityRunning = state == .active || state == .stale
                if !self.activityRunning {
                    self.registrationTask?.cancel(); self.tokenTask?.cancel()
                    try? await self.api.unregister(activityID: activity.id)
                    return
                }
            }
        }
    }
    private func register(activity: Activity<MarketActivityAttributes>, token: Data, lifecycle: UUID) {
        guard !activity.content.state.foregroundOnly else { return }
        registrationTask?.cancel()
        let symbols = activityIDs
        registrationTask = Task { [weak self] in
            guard let self else { return }
            var delay = 1
            while !Task.isCancelled && self.activityGeneration == lifecycle && self.running(activity) {
                do {
                    try await self.api.register(activityID: activity.id, pushToken: token, symbols: symbols, redUp: self.redUp)
                    guard !Task.isCancelled, self.activityGeneration == lifecycle else { return }
                    self.backgroundStatus = tr("后台订阅已登记", "Background subscription registered")
                    self.lastActivityResult = tr("盯盘已开启，后台行情由服务器推送；系统决定送达节奏。", "Watching started. The server sends background updates; iOS controls delivery timing.")
                    self.finishRegistrationBackgroundTask()
                    return
                } catch {
                    guard !Task.isCancelled, self.activityGeneration == lifecycle else { return }
                    self.backgroundStatus = tr("后台订阅未成功，将重试", "Background registration failed; retrying")
                    self.lastActivityResult = error.localizedDescription
                }
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                delay = min(delay * 2, 30)
            }
        }
    }
    func startActivity() async {
        guard !activityStarting else { return }
        activityStarting = true
        defer { activityStarting = false }
        do {
            guard UIApplication.shared.applicationState == .active,
                  ActivityAuthorizationInfo().areActivitiesEnabled else {
                message = tr("请在 App 前台开启盯盘，并允许实时活动。", "Start in the foreground and allow Live Activities."); return
            }
            syncActivityState()
            if activityRunning { return }
            // Creating a real Live Activity does not require APNs. Prefer remote updates
            // only when the operator's server is ready for this build's push environment.
            var remoteUpdates = false
            if api.isConfigured {
                #if DEBUG
                let expected = "development"
                #else
                let expected = "production"
                #endif
                if let status = try? await api.status() {
                    remoteUpdates = status.ready && status.backgroundPush && status.environment == expected
                }
            }
            guard islandQuotes.count == activityIDs.count, islandQuotes.allSatisfy({ !$0.isStale(at: Date()) }) else {
                message = tr("请等待全部已选资产的有效报价。", "Wait for valid quotes for all selected instruments."); return
            }
            let state = MarketActivityAttributes.ContentState(quotes: islandQuotes, redUp: redUp, foregroundOnly: !remoteUpdates)
            finishRegistrationBackgroundTask()
            if remoteUpdates {
                registrationBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Register activity") { [weak self] in
                    Task { @MainActor in self?.finishRegistrationBackgroundTask() }
                }
            }
            let activity = try Activity.request(attributes: MarketActivityAttributes(sessionName: "Nosce Island"),
                content: ActivityContent(state: state, staleDate: state.visibleQuotes.first?.staleAt), pushType: remoteUpdates ? .token : nil)
            observe(activity)
            activityRunning = true
            lastActivityResult = remoteUpdates
                ? tr("灵动岛已开启，正在连接后台更新。", "Dynamic Island started. Connecting background updates.")
                : tr("灵动岛已开启。返回桌面查看；App 离开前台后暂停更新，返回后继续。", "Dynamic Island started. View it on Home; updates pause when the app leaves the foreground and resume when you return.")
            scheduleLocalActivityUpdate()
        } catch { finishRegistrationBackgroundTask(); message = error.localizedDescription; lastActivityResult = error.localizedDescription }
    }
    private func scheduleLocalActivityUpdate() {
        guard let activity = observed, running(activity), activity.content.state.foregroundOnly else { return }
        localRevision += 1
        guard localPublishTask == nil else { return }
        let publisherID = UUID(); localPublisherID = publisherID
        // One serial writer coalesces rapid ticks and preserves background/resume ordering.
        localPublishTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.localPublisherID == publisherID { self.localPublishTask = nil } }
            while !Task.isCancelled, self.observed?.id == activity.id, self.running(activity) {
                if self.foreground {
                    do { try await Task.sleep(for:.seconds(1)) } catch { return }
                }
                guard !Task.isCancelled, self.observed?.id == activity.id else { return }
                let revision = self.localRevision
                let previous = activity.content.state.quotes
                let current = self.activityIDs.compactMap { id -> IslandQuote? in
                    let old = previous.first { $0.id == id }
                    guard let next = self.quotes[id] else { return old }
                    if let old, old.updatedAt > next.updatedAt { return old }
                    return next
                }
                let pageCount = max(1,current.count)
                let elapsed = max(0,Int(Date().timeIntervalSince(self.pageOrigin) / 5))
                let page = self.foreground ? (self.initialPage + elapsed) % pageCount : activity.content.state.pageIndex
                let state = MarketActivityAttributes.ContentState(quotes:current,redUp:self.redUp,foregroundOnly:true,page:page)
                let staleDate = state.visibleQuotes.first?.staleAt
                // Ordinary price ticks never request an alert or an expanded presentation.
                await activity.update(ActivityContent(state:state,staleDate:staleDate), alertConfiguration: nil)
                if revision == self.localRevision && (!self.foreground || current.count <= 1) { return }
            }
        }
    }
    func updateActivity() async {
        guard let activity = observed, running(activity) else { return }
        if activity.content.state.foregroundOnly { scheduleLocalActivityUpdate() }
        else if let token = latestPushToken {
            // Only the server writes remotely updated activities, avoiding competing price timestamps.
            register(activity:activity,token:token,lifecycle:activityGeneration)
        }
    }
    func endActivity() async {
        finishRegistrationBackgroundTask()
        activityGeneration = UUID()
        registrationTask?.cancel(); tokenTask?.cancel(); activityTask?.cancel()
        localPublishTask?.cancel(); localPublishTask = nil
        let activities = Activity<MarketActivityAttributes>.activities
        for activity in activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        observed = nil; latestPushToken = nil
        activityRunning = false; lastActivityState = "ended"
        lastActivityResult = tr("盯盘已结束", "Watching ended")
        // Stop the visible activity immediately, even when the server is unreachable.
        for activity in activities where !activity.content.state.foregroundOnly { try? await api.unregister(activityID: activity.id) }
    }
    func deleteServiceData() async {
        await endActivity()
        do {
            try await api.deleteInstallation()
            widgetAccessTask?.cancel(); widgetAccessID = UUID(); widgetAccessTask = nil
            WidgetStockAccessStore.clear()
            widgetEntitlementTask?.cancel(); widgetEntitlementTask = nil
            WidgetEntitlementAccessStore.clear()
            commerce.clearLocalProfile()
            stopRefreshing(); quotes = [:]; history = [:]
            message = tr("设备服务数据已删除。重新连接会生成新的匿名设备凭证。", "Device service data deleted. Reconnecting creates new anonymous credentials.")
        } catch { message = error.localizedDescription }
    }
    func copyActivityDiagnostics() {
        UIPasteboard.general.string = "Nosce Island 0.6.0\nState: \(lastActivityState)\nService: \(backgroundStatus)\nResult: \(lastActivityResult)"
        message = tr("服务状态已复制。", "Service status copied.")
    }
    private func finishRegistrationBackgroundTask() {
        if registrationBackgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(registrationBackgroundTask)
            registrationBackgroundTask = .invalid
        }
    }
}
