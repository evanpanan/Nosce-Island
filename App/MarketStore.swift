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
    @Published var activityRunning = false
    @Published var activityStarting = false
    @Published var lastActivityResult = tr("尚未开启盯盘", "Watching is not active")
    @Published var lastActivityID = "—"
    @Published var lastActivityState = "none"
    @Published var message: String?
    @Published var loading = false
    @Published var catalogLoading = false
    @Published var catalogNotice: String?
    @Published var connection = tr("等待连接", "Waiting")
    @Published var backgroundStatus = tr("正在检查服务", "Checking service")
    @Published var stocksEnabled = false
    private var lastWidgetWrite = Date.distantPast
    private var lastWidgetReload = Date.distantPast
    private let api = NosceAPI()
    lazy var commerce = CommerceStore(api:api)
    private var streamTask: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var presenceTask: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var discoveryTask: Task<Void, Never>?
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
    }
    private func syncWidgets(force: Bool = false) {
        let date = Date()
        guard force || date.timeIntervalSince(lastWidgetWrite) >= 30 else { return }
        let items = chosen.map { WidgetWatchItem(id: $0.id, symbol: $0.symbol, currency: $0.currency) }
        let snapshot = WidgetSnapshot(items: items, quotes: islandQuotes, redUp: redUp, savedAt: date)
        guard WidgetSnapshotStore.write(snapshot) else { return }
        lastWidgetWrite = date
        if force || date.timeIntervalSince(lastWidgetReload) >= 60 {
            lastWidgetReload = date
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshotStore.kind)
        }
    }
    var chosen: [Instrument] { selected.map { id in catalog.first { $0.id == id } ?? Instrument(id: id) } }
    var islandQuotes: [IslandQuote] { selected.compactMap { quotes[$0] } }
    var visibleInstruments: [Instrument] {
        let index = observed?.content.state.pageIndex ?? 0
        return Array(chosen.dropFirst(index).prefix(1))
    }
    func color(_ change: Double?) -> Color {
        switch IslandQuote.priceTone(change: change, redUp: redUp) {
        case .green: return .green
        case .red: return .red
        case .neutral: return .secondary
        }
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
            guard selected.count < 8 else { message = tr("最多关注 8 个资产，灵动岛逐个轮播。", "Follow up to 8 instruments; the island rotates one at a time."); return }
            selected.append(item.id)
        }
        UserDefaults.standard.set(selected, forKey: "selectedServerV1")
        syncWidgets(force: true)
        if foreground { startRefreshing() }
    }
    func startRefreshing() {
        stopRefreshing()
        foreground = true
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
                    if self.selected.allSatisfy({ $0.hasPrefix("hl:") || $0.hasPrefix("bn:") }) {
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
                    let status = try await self.api.status()
                    guard !Task.isCancelled, self.generation == generation else { return }
                    self.stocksEnabled = status.stocksEnabled
                    self.backgroundStatus = status.backgroundPush ? tr("后台服务已配置", "Background service configured") : tr("后台服务未配置", "Background service not configured")
                    // Catalog also refreshes expired installation credentials before opening a socket.
                    let (items, enabled) = try await self.api.catalog()
                    guard !Task.isCancelled, self.generation == generation else { return }
                    self.catalog = items; self.stocksEnabled = enabled
                    let missing = self.selected.filter { id in !items.contains { $0.id == id } }
                    guard missing.isEmpty else { throw ServiceError.unavailable(422) }
                    let socket = try await self.api.socket(symbols: self.selected)
                    self.socket = socket
                    self.lastFrameAt = Date()
                    self.connection = tr("已连接行情服务", "Connected to market service")
                    self.heartbeat = Task {
                        while !Task.isCancelled {
                            do {
                                try await Task.sleep(for: .seconds(15))
                                if Date().timeIntervalSince(self.lastFrameAt) > 30 { socket.cancel(with: .goingAway, reason: nil); return }
                                try await socket.send(.string("ping"))
                            }
                            catch { socket.cancel(with: .goingAway, reason: nil); return }
                        }
                    }
                    while !Task.isCancelled && self.generation == generation {
                        let message = try await socket.receive()
                        guard !Task.isCancelled, self.generation == generation else { return }
                        let data: Data
                        switch message {
                        case .data(let value): data = value
                        case .string(let value): data = Data(value.utf8)
                        @unknown default: continue
                        }
                        self.lastFrameAt = Date()
                        let frame = try JSONDecoder().decode(StreamFrame.self, from: data)
                        for quote in frame.quotes { self.acceptQuote(quote) }
                        self.loading = false
                        delay = 1
                    }
                } catch {
                    guard !Task.isCancelled, self.generation == generation else { return }
                    self.connection = error.localizedDescription
                    for id in self.selected { self.errors[id] = tr("连接中断，等待重连；旧报价不会刷新时间。", "Disconnected; retrying. Old quote timestamps are preserved.") }
                }
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
        heartbeat?.cancel(); heartbeat = nil
        presenceTask?.cancel(); presenceTask = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        loading = false
        scheduleLocalActivityUpdate()
        syncWidgets(force: true)
        // Server-owned subscriptions continue. App-updated activities explicitly become stale on background.
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
                self.catalog = items; self.stocksEnabled = enabled; self.catalogNotice = nil
                if let data = try? JSONEncoder().encode(items) { UserDefaults.standard.set(data, forKey: "serverCatalogV1") }
            } catch { await self.reloadPublicCatalog() }
        }
    }
    private func reloadPublicCatalog() async {
        // Discover independent sources separately; a blocked Binance endpoint must not hide Hyperliquid.
        var items = catalog.filter { $0.id.hasPrefix("hl:") || $0.id.hasPrefix("bn:") }
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
        let symbols = activity.content.state.quotes.map(\.id)
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
            guard islandQuotes.count == selected.count, islandQuotes.allSatisfy({ !$0.isStale(at: Date()) }) else {
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
                content: ActivityContent(state: state, staleDate: islandQuotes.map(\.staleAt).min()), pushType: remoteUpdates ? .token : nil)
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
        // One serial writer coalesces rapid ticks and preserves pause/resume ordering.
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
                let current = previous.map { old in
                    guard let next = self.quotes[old.id], next.updatedAt >= old.updatedAt else { return old }
                    return next
                }
                let pageCount = max(1,current.count)
                let elapsed = max(0,Int(Date().timeIntervalSince(self.pageOrigin) / 5))
                let page = self.foreground ? (self.initialPage + elapsed) % pageCount : activity.content.state.pageIndex
                let state = MarketActivityAttributes.ContentState(quotes:current,redUp:self.redUp,foregroundOnly:true,page:page)
                let staleDate = self.foreground ? current.map(\.staleAt).max() : Date()
                await activity.update(ActivityContent(state:state,staleDate:staleDate))
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
