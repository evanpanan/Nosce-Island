import SwiftUI
import StoreKit
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject var store: MarketStore
    @EnvironmentObject var commerce: CommerceStore
    @State private var tab = 0
    @AppStorage("appearanceV1") private var appearance = "dark"
    @State private var search = ""
    @State private var market = "All"
    @State private var draggedAsset: String?
    @State private var dropTarget: String?
    
    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { dashboard }
                .tabItem { Label(tr("盯盘", "Watch"), systemImage: "waveform.path") }.tag(0)
            NavigationStack { instruments }
                .tabItem { Label(tr("自选", "Watchlist"), systemImage: "star") }.tag(1)
            NavigationStack { settings }
                .tabItem { Label(tr("设置", "Settings"), systemImage: "slider.horizontal.3") }.tag(2)
        }
        .onOpenURL { url in
            if url.scheme == "nosceisland", url.host == "watch" { tab = 0 }
            if url.scheme == "nosceisland", url.host == "membership" { store.showPro = true }
        }
        .sheet(isPresented: $store.showPro) {
            ProMembershipView()
        }
        .tint(MarketPalette.accent)
        .task { store.startRefreshing(); await commerce.start() }
        .alert(tr("提示", "Notice"), isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) {
            Button(tr("知道了", "OK")) { store.message = nil }
        } message: { Text(store.message ?? "") }
    }
    private var dashboard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    HStack(spacing: 8) { Image("WaveMark").resizable().scaledToFit().frame(width: 28, height: 28); Text("NOSCE ISLAND").font(.caption.bold()).tracking(2) }
                    Spacer()
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—").font(.caption2.monospaced()).foregroundStyle(.secondary)
                }.foregroundStyle(MarketPalette.accent)
                VStack(alignment: .leading, spacing: 8) {
                    Text(tr("行情，抬眼即见。", "Markets. At a glance.")).font(.largeTitle.bold())
                    Text(tr("无强制广告 · 无付费倒计时", "No forced ads. No paid countdown."))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                HStack {
                    Text(tr("正在关注", "Your watch")).font(.title3.bold())
                    Spacer()
                    Button { tab = 1 } label: { Image(systemName: "plus.circle").font(.title3) }
                        .accessibilityLabel(tr("添加资产", "Add instrument"))
                }
                if !store.isPro {
                    Button(tr("查看 Pro 多资产权益", "Explore Pro multi-asset watching")) { store.showPro = true }.font(.caption)
                }
                Text(store.connection).font(.caption).foregroundStyle(.secondary)
                if store.chosen.count > 1 {
                    Text(store.isPro ? tr("长按卡片拖动排序 · 按顺序轮播", "Hold and drag to reorder · rotate in list order") : tr("长按卡片拖动排序 · 免费版展示第一位", "Hold and drag to reorder · Free shows the first asset"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(store.chosen) { item in
                    quoteCard(item)
                        .overlay(alignment: .topTrailing) {
                            Image(systemName: "line.3.horizontal").font(.caption2)
                                .foregroundStyle(.tertiary).padding(7).accessibilityHidden(true)
                        }
                        .overlay(RoundedRectangle(cornerRadius: 20).stroke(dropTarget == item.id ? MarketPalette.accent : .clear, lineWidth: 2))
                        .onDrag { draggedAsset = item.id; return NSItemProvider(object: item.id as NSString) }
                        .onDrop(of: [UTType.text], isTargeted: Binding(get: { dropTarget == item.id }, set: { dropTarget = $0 ? item.id : nil })) { providers in
                            guard let source = draggedAsset,
                                  let provider = providers.first, provider.canLoadObject(ofClass: NSString.self) else { return false }
                            provider.loadObject(ofClass: NSString.self) { value, _ in
                                guard let payload = value as? String, payload == source else { return }
                                Task { @MainActor in store.moveSelected(source, before: item.id) }
                            }
                            draggedAsset = nil; dropTarget = nil
                            return true
                        }
                        .accessibilityAction(named: Text(tr("向上移动", "Move up"))) { moveAsset(item.id, by: -1) }
                        .accessibilityAction(named: Text(tr("向下移动", "Move down"))) { moveAsset(item.id, by: 1) }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Label(tr("行情来源与更新状态", "Market source and update status"), systemImage: "info.circle").font(.subheadline.bold())
                    Text(tr("币安与 Hyperliquid 显示永续合约标记价；独立股票报价仅在授权数据源启用时提供。App 内行情直接连接数据源；灵动岛后台持续更新需要上线推送服务。延迟、休市和过期状态会单独标明。", "Binance and Hyperliquid show perpetual mark prices. Exchange stock quotes require an enabled licensed feed. In-app quotes connect directly to the source. Background island updates require the push service. Delays, closed markets and stale prices are labelled."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                    .background(MarketPalette.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
                Button {
                    Task { if store.activityRunning { await store.endActivity() } else { await store.startActivity() } }
                } label: {
                    Label(store.activityRunning ? tr("结束盯盘", "Stop watching") : tr("显示到灵动岛", "Show on Dynamic Island"),
                          systemImage: store.activityRunning ? "stop.circle" : "waveform.path")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 19)
                }.buttonStyle(.borderedProminent).tint(store.activityRunning ? .gray : MarketPalette.accent).foregroundStyle(colorScheme == .light ? .white : .black)
                    .disabled(store.activityStarting)
                Text(store.lastActivityResult).font(.caption).foregroundStyle(.secondary)
                if store.activityRunning {
                    Text(tr("请返回桌面或切换到其他 App 查看；系统决定实时活动的显示位置。", "Return to Home or another app to check; iOS controls presentation."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(tr("实时活动受 iOS 管理，单次最长 8 小时；本版不人为缩短。", "iOS manages Live Activities, with an 8-hour maximum per session. No shorter app-imposed timer."))
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(20)
        }.background(Color(uiColor: .systemGroupedBackground)).toolbar(.hidden, for: .navigationBar)
    }
    private func quoteCard(_ item: Instrument) -> some View {
        let quote = store.quotes[item.id]
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.symbol).font(.headline)
                    Text(item.name + " · " + item.typeLabel + (item.exchange.isEmpty ? "" : " · " + item.exchange)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(quote?.formattedPrice ?? "—").font(.title3.monospacedDigit().bold()).foregroundStyle(store.color(quote?.change))
                    Text((quote?.formattedChange ?? "—") + " · " + (quote?.basis == "last" ? tr("日涨跌", "DAY") : "24h")).font(.caption.monospacedDigit()).foregroundStyle(store.color(quote?.change))
                }
            }
            if let points = store.history[item.id], points.count > 1 {
                Sparkline(values: points).stroke(quote?.change == nil ? MarketPalette.accent : store.color(quote?.change), style: StrokeStyle(lineWidth: 2, lineCap: .round)).frame(height: 44)
                Text(tr("本次打开期间采样", "Samples since opening")).font(.caption2).foregroundStyle(.secondary)
            }
            if !item.settlementCurrency.isEmpty && item.settlementCurrency != item.currency {
                Text(item.currency + tr(" 计价 · ", " price · ") + item.settlementCurrency + tr(" 结算", " settlement"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let error = store.errors[item.id] {
                Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
            }
            if let quote {
                TimelineView(.periodic(from: .now, by: 5)) { context in
                    HStack {
                        Circle().fill(quote.isStale(at: context.date) ? .orange : MarketPalette.accent).frame(width: 5, height: 5)
                        Text(quote.source + " · " + quote.statusLabel + " · " + quote.updatedAt.formatted(date: .omitted, time: .standard))
                            .font(.caption2).foregroundStyle(.secondary)
                        if quote.isStale(at: context.date) { Text(tr("过期", "STALE")).font(.caption2.bold()).foregroundStyle(.orange) }
                    }
                }
            } else if store.loading { ProgressView().controlSize(.small) } else { Text(tr("暂时没有有效报价，正在重连。", "No valid quote yet. Reconnecting.")).font(.caption).foregroundStyle(.secondary) }
        }.padding(18).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }
    // Keep each section independently type-checked; the catalog can contain thousands of assets.
    private var instruments: some View {
        List {
            marketPickerSection
            catalogStatusSection
            selectedAssetsSection
            availableAssetsSection
        }
        .navigationTitle(tr("自选行情", "Watchlist"))
        .searchable(text: $search, prompt: tr("搜索代码或英文名称", "Symbol or name"))
        .toolbar { ToolbarItem(placement: .navigationBarTrailing) { EditButton().disabled(store.activityStarting) } }
    }
    private var marketPickerSection: some View {
        Section {
            Picker(tr("市场", "Market"), selection: $market) {
                Text(tr("全部", "All")).tag("All")
                Text(tr("加密", "Crypto")).tag("Crypto")
                Text(tr("合约", "Perps")).tag("Contracts")
                Text(tr("美股", "US")).tag("US")
            }.pickerStyle(.segmented)
        }
    }
    private var stockMarketIsEmpty: Bool {
        guard market == "US", store.stockNotice == nil else { return false }
        return !store.catalog.contains { $0.market == market }
    }
    private var catalogStatusSection: some View {
        Section {
            Text(tr("直接搜索并添加想看的资产。名称下方标明报价类型与来源。", "Search and add an asset. The quote type and source appear below its name."))
                .font(.caption).foregroundStyle(.secondary)
            if store.catalogLoading { ProgressView(tr("正在加载市场…", "Loading markets…")) }
            if let notice = store.catalogNotice { Text(notice).font(.caption).foregroundStyle(.orange) }
            if market == "US", let notice = store.stockNotice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            if stockMarketIsEmpty {
                Text(tr("该市场的股票数据尚未开放；合约报价不作为股票报价展示。", "Stock data for this market is not available yet. Contract prices are not exchange stock quotes."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button(tr("刷新市场列表", "Reload markets")) { store.reloadCatalog() }
                .disabled(store.catalogLoading)
        }
    }
    private func moveAsset(_ id: String, by delta: Int) {
        guard let index = store.activeSelected.firstIndex(of: id) else { return }
        let target = index + delta
        guard store.activeSelected.indices.contains(target) else { return }
        store.moveSelected(from: IndexSet(integer: index), to: delta > 0 ? target + 1 : target)
    }
    private var selectedAssetsSection: some View {
        Section {
            ForEach(store.savedInstruments) { item in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.symbol).font(.headline).foregroundStyle(.primary)
                        Text(assetDescription(item)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        if !store.activeSelected.contains(item.id) {
                            Text(tr("已保留 · Pro 启用", "Saved · needs Pro")).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 4)
                    Button { store.toggle(item) } label: { Image(systemName: "minus.circle").padding(.vertical, 8) }
                        .buttonStyle(.borderless)
                        .disabled(store.activityRunning || store.activityStarting || store.selected.count == 1)
                        .accessibilityLabel(item.symbol + tr("，移除", ", remove"))
                }.padding(.vertical, 4)
            }
            .onMove { store.moveSelected(from: $0, to: $1) }
            .moveDisabled(store.activityStarting)
        } header: { Text(tr("我的自选", "My watchlist")) }
          footer: { Text(tr("点击编辑，拖动右侧把手排序。顺序自动保存；免费版显示第一位，Pro 按顺序轮播，小组件同序。", "Tap Edit, then drag a handle. Order is saved. Free shows the first asset; Pro rotates in order. Widgets follow the same order.")) }
    }
    private var matchingAssets: [Instrument] {
        store.catalog.filter { item in
            guard market == "All" || item.market == market else { return false }
            guard !search.isEmpty else { return true }
            let terms = [item.id, item.symbol, item.name].joined(separator: " ")
            return terms.localizedCaseInsensitiveContains(search)
        }
    }
    private var availableAssetsSection: some View {
        let matches = matchingAssets
        return Section(store.isPro ? tr("Pro · 最多 8 个自选与轮播", "Pro · up to 8 watchlist and island assets") : tr("免费版 · 最多 3 个自选 / 单资产盯盘", "Free · 3 watchlist assets / one island asset")) {
            if matches.isEmpty {
                emptySearchHint
            } else {
                ForEach(matches) { item in assetSelectionButton(item) }
            }
        }
    }
    private var emptySearchHint: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tr("当前市场没有匹配结果。美股请切换到美股市场，使用股票代码，例如 AAPL、TSLA、NVDA。", "No matches in this market. For US stocks, select US and search a ticker such as AAPL, TSLA or NVDA."))
                .font(.caption).foregroundStyle(.secondary)
            if market != "US" {
                Button(tr("查看美股列表", "Browse US stocks")) { market = "US"; search = "" }
            }
            Button(tr("清除搜索并查看全部", "Clear search and show all")) { market = "All"; search = "" }
        }
    }
    private func assetDescription(_ item: Instrument) -> String {
        let parts = [item.name, item.typeLabel, item.exchange]
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
    private func assetSelectionButton(_ item: Instrument) -> some View {
        let selected = store.selected.contains(item.id)
        let selectionText = selected ? tr(" 已选择", " selected") : tr(" 添加", " add")
        return Button { store.toggle(item) } label: {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.symbol).font(.headline).foregroundStyle(.primary)
                    Text(assetDescription(item)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "plus.circle")
            }.padding(.vertical, 6)
        }
        .accessibilityLabel(Text(item.symbol + selectionText))
    }
    private var settings: some View {
        Form {
            membershipSection
            Section(tr("显示", "Display")) {
                Picker(tr("外观", "Appearance"), selection: $appearance) {
                    Text(tr("跟随系统", "System")).tag("system")
                    Text(tr("深色", "Dark")).tag("dark")
                    Text(tr("浅色", "Light")).tag("light")
                }
                Toggle(tr("红涨绿跌", "Red for gains"), isOn: $store.redUp)
                    .onChange(of: store.redUp) { value in
                        UserDefaults.standard.set(value, forKey: "redUp")
                        Task { await store.updateActivity() }
                    }
                LabeledContent(tr("语言", "Language"), value: tr("跟随系统", "System"))
                LabeledContent(tr("币种", "Currency"), value: tr("按品种 USD / HKD / USDT", "Native USD / HKD / USDT"))
            }
            Section(tr("主屏幕小组件", "Home Screen widgets")) {
                Text(store.widgetStockStatus).font(.caption).foregroundStyle(.secondary)
                Label(tr("小号 · 单个自选", "Small · one instrument"), systemImage: "square")
                Label(tr("Pro 中号 · 最多三个自选", "Pro medium · up to three instruments"), systemImage: "rectangle")
                Label(tr("Pro 大号 · 最多八个自选", "Pro large · up to eight instruments"), systemImage: "rectangle.portrait")
                Text(tr("长按主屏幕，添加 Nosce Island 小组件并选择尺寸。内容跟随自选顺序与涨跌颜色；点击小组件返回 App。", "Touch and hold the Home Screen, add Nosce Island, then choose a size. Widgets follow watchlist order and gain/loss colors. Tap a widget to open the app."))
                    .font(.caption).foregroundStyle(.secondary)
                Text(tr("小组件由 iOS 调度刷新，显示报价时间与过期状态，不保证逐秒更新。", "iOS schedules widget refreshes. Quote times and stale status are shown; updates are not guaranteed every second."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(tr("个人美股测试", "Personal US stock testing")) {
                if let user = commerce.profile?.userId {
                    Text(user).font(.caption.monospaced()).textSelection(.enabled)
                    ShareLink(item: user) { Label(tr("分享测试用户编号", "Share test user ID"), systemImage: "square.and.arrow.up") }
                } else {
                    Button(tr("获取测试用户编号", "Load test user ID")) { Task { await commerce.refresh() } }
                }
                Text(tr("Alpaca 免费 IEX 仅供指定用户个人测试；是单一交易所报价，可能与全市场价格不同。退出 App 后不保证继续更新，股票小组件读取 App 保存的报价。", "Free Alpaca IEX is restricted to personal testing. Single-exchange prices can differ from consolidated prices. Updates are not guaranteed after leaving the app; stock widgets use quotes saved by the app."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(tr("数据管理", "Data management")) {
                Button(tr("删除设备服务数据", "Delete device service data"), role: .destructive) { Task { await store.deleteServiceData() } }
            }
            Section {
                Text("Nosce Island · " + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")).font(.subheadline.bold())
                Text(tr("合约：币安 / Hyperliquid 标记价，无同口径参考价时不显示涨跌幅。独立股票：按标注的数据源展示；Alpaca IEX 涨跌以 IEX 前一交易日日线收盘价为参考。币安和股票保留上游报价时间；Hyperliquid 显示服务器接收时间。", "Perpetuals: Binance / Hyperliquid mark prices; change is unavailable without a matching reference. Stocks use the labelled source; Alpaca IEX changes use the previous IEX daily close. Binance and stocks preserve upstream timestamps; Hyperliquid uses server receipt time."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.navigationTitle(tr("设置", "Settings"))

    }
    private var membershipSection: some View {
        Section {
            Button { store.showPro = true } label: {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("NOSCE ISLAND").font(.caption2.bold()).tracking(2).foregroundStyle(.secondary)
                            Text(store.isPro ? "Pro" : tr("免费版", "Free")).font(.title.bold()).foregroundStyle(.primary)
                        }
                        Spacer()
                        Image(systemName: store.isPro ? "sparkles" : "waveform.path")
                            .font(.title2).foregroundStyle(MarketPalette.accent)
                            .frame(width: 48, height: 48).background(MarketPalette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
                    }
                    Text(store.isPro ? tr("8 个自选 · 多资产轮播 · 全尺寸小组件", "8 assets · Island rotation · all widget sizes") : tr("3 个自选 · 单资产盯盘 · 小号小组件", "3 assets · single-asset Island · small widget"))
                        .font(.subheadline).foregroundStyle(.secondary)
                    HStack {
                        Text(store.isPro ? tr("查看会员与订阅", "Membership & subscription") : tr("探索 Pro，让关注更从容", "Explore more with Pro")).font(.subheadline.bold())
                        Spacer(); Image(systemName: "arrow.up.right").font(.subheadline)
                    }.foregroundStyle(MarketPalette.accent)
                }.padding(.vertical, 10)
            }.buttonStyle(.plain)
        } header: { Text(tr("会员", "Membership")) }
          footer: { Text(tr("免注册 · 免登录 · 无强制广告", "No registration · No app sign-in · No forced ads")) }
    }

}

struct ProMembershipView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var store: MarketStore
    @EnvironmentObject private var commerce: CommerceStore
    @State private var annual = true
    @State private var loading = true
    private var monthly: Product? { commerce.products.first { $0.subscription?.subscriptionPeriod.unit == .month } }
    private var yearly: Product? { commerce.products.first { $0.subscription?.subscriptionPeriod.unit == .year } }
    private var selectedProduct: Product? { annual ? yearly : monthly }
    private var purchaseReady: Bool { commerce.profile?.purchaseEnabled == true && selectedProduct != nil }
    private var surface: Color { Color(uiColor: .secondarySystemGroupedBackground) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    introduction
                    comparison
                    subscriptionOptions
                    purchaseControls
                    details
                }.padding(24)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(tr("会员", "Membership"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(tr("完成", "Done")) { dismiss() } } }
        }
        .tint(MarketPalette.accent)
        .task {
            await commerce.refresh()
            if yearly == nil, monthly != nil { annual = false }
            loading = false
        }
    }
    private var introduction: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image("WaveMark").resizable().scaledToFit().frame(width: 28, height: 28)
                Text("NOSCE ISLAND").font(.caption.bold()).tracking(2)
                Spacer()
                Text(store.isPro ? tr("已启用 PRO", "PRO ACTIVE") : "PRO")
                    .font(.caption2.bold()).padding(.horizontal, 10).padding(.vertical, 6)
                    .background(MarketPalette.accent.opacity(0.12), in: Capsule())
            }.foregroundStyle(MarketPalette.accent)
            Text(tr("更多关注，\n一眼尽览。", "More to follow.\nLess to open."))
                .font(.system(size: 34, weight: .bold, design: .rounded)).tracking(-1).fixedSize(horizontal: false, vertical: true)
            Text(tr("将你的自选，带到灵动岛与主屏幕。", "Bring your watchlist to the Island and Home Screen."))
                .font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Image(systemName: "waveform.path").foregroundStyle(MarketPalette.accent)
                Text("BTC").font(.subheadline.bold())
                Spacer()
                Text("ETH").foregroundStyle(.secondary)
                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                Text("SOL").foregroundStyle(.secondary)
            }.padding(20).background(surface, in: Capsule())
                .accessibilityLabel(tr("多资产轮播示意，非实时行情", "Multi-asset rotation illustration, not live quotes"))
            if store.isPro, let expiry = store.proExpiresAt {
                Label(tr("当前权益有效至 ", "Active through ") + expiry.formatted(date: .abbreviated, time: .omitted), systemImage: "checkmark.seal")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var comparison: some View {
        VStack(spacing: 0) {
            HStack {
                Text(tr("选择适合你的关注方式", "Your way to follow")).font(.subheadline.bold())
                Spacer()
                Text(tr("免费", "Free")).font(.caption).frame(width: 58)
                Text("Pro").font(.caption.bold()).foregroundStyle(MarketPalette.accent).frame(width: 72)
            }.padding(.bottom, 18)
            benefitRow(tr("自选资产", "Watchlist"), free: tr("3 个", "3"), pro: tr("8 个", "8"))
            Divider().padding(.vertical, 14)
            benefitRow(tr("灵动岛 / 锁屏", "Island / Lock Screen"), free: tr("单资产", "Single"), pro: tr("最多 8 个轮播", "Rotate 8"))
            Divider().padding(.vertical, 14)
            benefitRow(tr("桌面小组件", "Widgets"), free: tr("小号", "Small"), pro: tr("小 · 中 · 大", "S · M · L"))
        }.padding(20).background(surface, in: RoundedRectangle(cornerRadius: 24))
    }
    private func benefitRow(_ title: String, free: String, pro: String) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Text(title).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
            Text(free).font(.caption).foregroundStyle(.secondary).frame(width: 58)
            Text(pro).font(.caption.bold()).foregroundStyle(MarketPalette.accent).multilineTextAlignment(.center).frame(width: 72)
        }.fixedSize(horizontal: false, vertical: true)
    }
    private var subscriptionOptions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(store.isPro ? tr("订阅方案", "Subscription plans") : tr("解锁 Pro", "Unlock Pro")).font(.title3.bold())
            HStack(spacing: 12) {
                planOption(annual: false, product: monthly)
                planOption(annual: true, product: yearly)
            }
            if loading {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(tr("正在读取 App Store 商品…", "Loading App Store products…")).font(.caption).foregroundStyle(.secondary) }
            } else if commerce.products.isEmpty {
                Label(tr("购买暂未开放或商品暂不可用，仍可继续免费使用。", "Purchases are not open or products are unavailable. You can keep using Free."), systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private func planOption(annual option: Bool, product: Product?) -> some View {
        let selected = annual == option
        return Button { annual = option } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(option ? tr("年付", "Yearly") : tr("月付", "Monthly")).font(.subheadline.bold())
                    Spacer(minLength: 4)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(selected ? MarketPalette.accent : .secondary)
                }
                Text(product?.displayPrice ?? tr("待开放", "Not available"))
                    .font(.title3.bold()).lineLimit(1).minimumScaleFactor(0.7)
                Text(product == nil ? tr("以 App Store 就绪为准", "When available in App Store") : (option ? tr("每年自动续订", "Auto-renews yearly") : tr("每月自动续订", "Auto-renews monthly")))
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                .background(selected ? MarketPalette.accent.opacity(0.08) : surface, in: RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(selected ? MarketPalette.accent : Color.secondary.opacity(0.18), lineWidth: selected ? 1.5 : 1))
        }.buttonStyle(.plain).foregroundStyle(.primary)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
    private var purchaseControls: some View {
        VStack(spacing: 16) {
            if store.isPro {
                Link(destination: URL(string: "https://apps.apple.com/account/subscriptions")!) {
                    primaryLabel(tr("管理我的订阅", "Manage subscription"))
                }
            } else {
                Button { if let product = selectedProduct { Task { await commerce.purchase(product) } } } label: {
                    primaryLabel(commerce.busy ? tr("正在处理…", "Processing…") : (purchaseReady ? tr("订阅 Pro · ", "Subscribe · ") + (selectedProduct?.displayPrice ?? "") + (annual ? tr(" / 年", " / year") : tr(" / 月", " / month")) : tr("购买暂不可用", "Purchases unavailable")))
                }.disabled(!purchaseReady || commerce.busy || loading).opacity(purchaseReady ? 1 : 0.5)
            }
            if !commerce.products.isEmpty {
                Text(tr("通过 App Store 自动续费，可随时在 Apple 订阅设置中取消。实际扣款价格以确认购买时显示为准。", "Auto-renews through the App Store. Cancel in Apple subscription settings. The price on the purchase confirmation applies."))
                    .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Button(tr("已购买？恢复购买", "Already subscribed? Restore purchases")) { Task { await commerce.restore() } }
                .font(.subheadline).disabled(commerce.busy)
            if let notice = commerce.notice {
                Text(notice).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).accessibilityAddTraits(.updatesFrequently)
            }
        }
    }
    private func primaryLabel(_ title: String) -> some View {
        Text(title).font(.headline).multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.vertical, 18)
            .foregroundStyle(colorScheme == .light ? .white : .black)
            .background(MarketPalette.accent, in: RoundedRectangle(cornerRadius: 18))
    }
    private var details: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(tr("相同刷新策略，无强制广告、无付费倒计时。", "Same refresh policy. No forced ads or paid countdown."), systemImage: "checkmark.shield")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup(tr("关于权益与更新", "About access and updates")) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(tr("Pro 到期后仍保留全部自选，前三个可用；灵动岛恢复单资产，中、大号小组件需 Pro。取消订阅不影响已验证的有效期。", "After Pro expires, your full watchlist is saved with the first three active. The Island returns to one asset; medium and large widgets need Pro. Cancellation preserves your verified paid term."))
                    Text(tr("后台推送和小组件刷新受 iOS 调度影响，不承诺逐秒送达。两版均可调整自选顺序、涨跌配色与外观。", "iOS controls background delivery and widget refreshes; second-by-second delivery is not guaranteed. Both plans support reordering, gain/loss colors and themes."))
                    Text(tr("本期不含价格提醒、持仓盈亏、跨设备同步和公开美股数据服务。个人 Alpaca IEX 测试资格与 Pro 分开。", "Price alerts, portfolio P&L, cross-device sync and public US stock data are not included. Personal Alpaca IEX testing is separate from Pro."))
                }.font(.caption).foregroundStyle(.secondary).padding(.top, 12)
            }.font(.subheadline)
            HStack(spacing: 20) {
                if let raw = commerce.profile?.privacyURL, let url = URL(string: raw) { Link(tr("隐私政策", "Privacy"), destination: url) }
                if let raw = commerce.profile?.termsURL, let url = URL(string: raw) { Link(tr("订阅条款", "Terms"), destination: url) }
            }.font(.caption)
        }
    }
}

struct Sparkline: Shape {
    let values: [Double]
    func path(in rect: CGRect) -> Path {
        guard values.count > 1, let low = values.min(), let high = values.max() else { return Path() }
        let span = max(high - low, 0.000001)
        return Path { path in
            for (index, value) in values.enumerated() {
                let point = CGPoint(x: CGFloat(index) / CGFloat(values.count - 1) * rect.width,
                                    y: rect.height - CGFloat((value - low) / span) * rect.height)
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
        }
    }
}
