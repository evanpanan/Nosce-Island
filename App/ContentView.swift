import SwiftUI
import StoreKit

struct ContentView: View {
    @EnvironmentObject var store: MarketStore
    @EnvironmentObject var commerce: CommerceStore
    @State private var tab = 0
    @State private var search = ""
    @State private var market = "All"
    
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
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.7.1").font(.caption2.monospaced()).foregroundStyle(.secondary)
                }.foregroundStyle(MarketPalette.accent)
                VStack(alignment: .leading, spacing: 8) {
                    Text(tr("行情，抬眼即见。", "Markets. At a glance.")).font(.largeTitle.bold())
                    Text(tr("无强制广告 · 无付费倒计时", "No forced ads. No paid countdown."))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                VStack(spacing: 20) {
                    HStack {
                        Text(tr("灵动岛预览", "ISLAND PREVIEW")).font(.caption.bold()).foregroundStyle(.secondary)
                        Spacer()
                        Text(tr("真实行情", "MARKET DATA"))
                            .font(.caption2.bold()).foregroundStyle(MarketPalette.accent)
                    }
                    VStack(spacing:3) {
                        ForEach(store.visibleInstruments) { item in
                            HStack(spacing:8) {
                                Image("WaveMark").resizable().scaledToFit().frame(width:16,height:16)
                                Text(item.symbol).font(.caption.bold())
                                Spacer(minLength:4)
                                Text(store.quotes[item.id]?.formattedPrice ?? "—")
                                    .foregroundStyle(store.color(store.quotes[item.id]?.change))
                                    .font(.caption.monospacedDigit().bold()).lineLimit(1).minimumScaleFactor(0.6)
                            }
                        }
                    }.padding(.horizontal,20).padding(.vertical,10)
                        .background(.black,in:RoundedRectangle(cornerRadius:24)).padding(.horizontal,20)
                    HStack {
                        Image(systemName: "hand.draw").foregroundStyle(.secondary)
                        Text(tr("最多 8 个资产，逐个轮播；长按查看当前行情。", "Up to 8 assets, rotating one at a time; hold to expand."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(20).background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 26))
                HStack {
                    Text(tr("正在关注", "Your watch")).font(.title3.bold())
                    Spacer()
                    Button { tab = 1 } label: { Image(systemName: "plus.circle").font(.title3) }
                        .accessibilityLabel(tr("添加资产", "Add instrument"))
                }
                Text(store.connection).font(.caption).foregroundStyle(.secondary)
                ForEach(store.chosen) { item in quoteCard(item) }
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
                }.buttonStyle(.borderedProminent).tint(store.activityRunning ? .gray : MarketPalette.accent).foregroundStyle(.black)
                    .disabled(store.activityStarting)
                Text(store.lastActivityResult).font(.caption).foregroundStyle(.secondary)
                if store.activityRunning {
                    Text(tr("请返回桌面或切换到其他 App 查看；系统决定实时活动的显示位置。", "Return to Home or another app to check; iOS controls presentation."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(tr("实时活动受 iOS 管理，单次最长 8 小时；本版不人为缩短。", "iOS manages Live Activities, with an 8-hour maximum per session. No shorter app-imposed timer."))
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(20)
        }.background(Color(red: 0.035, green: 0.045, blue: 0.055)).toolbar(.hidden, for: .navigationBar)
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
        }.padding(18).background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 20))
    }
    private var instruments: some View {
        List {
            Section {
                Picker(tr("市场", "Market"), selection: $market) {
                    Text(tr("全部", "All")).tag("All")
                    Text(tr("加密", "Crypto")).tag("Crypto")
                    Text(tr("合约", "Perps")).tag("Contracts")
                    Text(tr("美股", "US")).tag("US")
                }.pickerStyle(.segmented)
            }
            Section {
                Text(tr("直接搜索并添加想看的资产。名称下方标明报价类型与来源。", "Search and add an asset. The quote type and source appear below its name."))
                    .font(.caption).foregroundStyle(.secondary)
                if store.catalogLoading { ProgressView(tr("正在加载市场…", "Loading markets…")) }
                if let notice = store.catalogNotice { Text(notice).font(.caption).foregroundStyle(.orange) }
                if ["US", "HK"].contains(market), !store.catalog.contains(where: { $0.market == market }) {
                    Text(tr("该市场的股票数据尚未开放；合约报价不作为股票报价展示。", "Stock data for this market is not available yet. Contract prices are not exchange stock quotes."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button(tr("刷新市场列表", "Reload markets")) { store.reloadCatalog() }.disabled(store.catalogLoading)
            }
            Section(tr("已选择 · 点按移除", "Selected · tap to remove")) {
                ForEach(store.chosen) { item in
                    Button { store.toggle(item) } label: {
                        HStack { Text(item.id); Spacer(); Image(systemName: "minus.circle") }
                    }
                }
            }
            Section(tr("最多关注 8 个资产 · 灵动岛逐个轮播", "Follow up to 8 · island rotates one at a time")) {
                ForEach(store.catalog.filter {
                    (market == "All" || $0.market == market) &&
                    (search.isEmpty || ($0.id + " " + $0.name).localizedCaseInsensitiveContains(search))
                }) { item in
                    Button { store.toggle(item) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(item.symbol).font(.headline).foregroundStyle(.primary)
                                Text(item.name + " · " + item.typeLabel + (item.exchange.isEmpty ? "" : " · " + item.exchange))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: store.selected.contains(item.id) ? "checkmark.circle.fill" : "plus.circle")
                        }.padding(.vertical, 6)
                    }.accessibilityLabel(item.symbol + (store.selected.contains(item.id) ? tr(" 已选择", " selected") : tr(" 添加", " add")))
                }
            }
        }.navigationTitle(tr("自选行情", "Watchlist"))
            .searchable(text: $search, prompt: tr("搜索代码或英文名称", "Symbol or name"))
    }
    private var settings: some View {
        Form {
            membershipSection
            Section(tr("显示", "Display")) {
                Toggle(tr("红涨绿跌", "Red for gains"), isOn: $store.redUp)
                    .onChange(of: store.redUp) { value in
                        UserDefaults.standard.set(value, forKey: "redUp")
                        Task { await store.updateActivity() }
                    }
                LabeledContent(tr("语言", "Language"), value: tr("跟随系统", "System"))
                LabeledContent(tr("币种", "Currency"), value: tr("按品种 USD / HKD / USDT", "Native USD / HKD / USDT"))
            }
            Section(tr("主屏幕小组件", "Home Screen widgets")) {
                Label(tr("小号 · 单个自选", "Small · one instrument"), systemImage: "square")
                Label(tr("中号 · 最多三个自选", "Medium · up to three instruments"), systemImage: "rectangle")
                Label(tr("大号 · 最多八个自选", "Large · up to eight instruments"), systemImage: "rectangle.portrait")
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
                Text("Nosce Island · " + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.7.0")).font(.subheadline.bold())
                Text(tr("合约：币安 / Hyperliquid 标记价，无同口径参考价时不显示涨跌幅。独立股票：按标注的数据源展示；Alpaca IEX 涨跌以 IEX 前一交易日日线收盘价为参考。币安和股票保留上游报价时间；Hyperliquid 显示服务器接收时间。", "Perpetuals: Binance / Hyperliquid mark prices; change is unavailable without a matching reference. Stocks use the labelled source; Alpaca IEX changes use the previous IEX daily close. Binance and stocks preserve upstream timestamps; Hyperliquid uses server receipt time."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.navigationTitle(tr("设置", "Settings"))

    }
    private func subscriptionPeriod(_ product: Product) -> String {
        guard let period=product.subscription?.subscriptionPeriod else { return "" }
        let unit: String
        switch period.unit {
        case .day:unit=tr("天","day(s)")
        case .week:unit=tr("周","week(s)")
        case .month:unit=tr("个月","month(s)")
        case .year:unit=tr("年","year(s)")
        @unknown default:return ""
        }
        return " / \(period.value) \(unit)"
    }
    private var membershipSection: some View {
        Section(tr("会员", "Membership")) {
            LabeledContent(tr("当前版本", "Current plan"), value: commerce.profile?.pro == true ? "Pro" : tr("免费版", "Free"))
            Text(tr("免注册 · 免登录 · 无广告", "No registration · No app sign-in · No ads"))
                .font(.caption).foregroundStyle(.secondary)
            if let expiry = commerce.profile?.expiresAt, commerce.profile?.pro == true {
                LabeledContent(tr("会员到期", "Expires"), value: Date(timeIntervalSince1970:expiry).formatted(date:.abbreviated,time:.omitted))
            }
            ForEach(commerce.products,id:\.id) { product in
                Button { Task { await commerce.purchase(product) } } label: {
                    VStack(alignment:.leading,spacing:4) {
                        Text(product.displayName + " · " + product.displayPrice + subscriptionPeriod(product))
                        Text(product.description).font(.caption).foregroundStyle(.secondary)
                    }
                }.disabled(commerce.busy)
            }
            if !commerce.products.isEmpty {
                Text(tr("通过 App Store 购买。订阅将自动续费，可在苹果设置中管理或取消。", "Billed by the App Store. Subscriptions renew automatically; manage or cancel them in Apple Settings."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if commerce.products.isEmpty {
                Text(tr("基础功能免费，高级功能即将推出。", "Basic features are free. More features are coming."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button(tr("恢复购买", "Restore purchases")) { Task { await commerce.restore() } }.disabled(commerce.busy)
            if commerce.profile?.pro == true {
                Link(tr("管理订阅", "Manage subscription"), destination:URL(string:"https://apps.apple.com/account/subscriptions")!)
            }
            if let raw = commerce.profile?.privacyURL, let url = URL(string:raw) { Link(tr("隐私政策", "Privacy policy"),destination:url) }
            if let raw = commerce.profile?.termsURL, let url = URL(string:raw) { Link(tr("订阅条款", "Subscription terms"),destination:url) }
            if let notice = commerce.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
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
