import SwiftUI
import StoreKit
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject var store: MarketStore
    @EnvironmentObject var commerce: CommerceStore
    @State private var tab = 0
    @AppStorage("appearanceV1") private var appearance = "dark"
    @State private var search = ""
    @State private var market = "All"
    @State private var draggedAsset: String?
    @State private var dropTarget: String?
    @State private var activityActionPending = false
    @State private var endingWatch = false
    @State private var confirmDeletion = false
    @State private var deleting = false
    @State private var detailInstrument: Instrument?

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
        .sheet(isPresented: $store.showPro) { ProMembershipView() }
        .sheet(item: $detailInstrument) { item in
            NavigationStack {
                instrumentDetails(item)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button(tr("完成", "Done")) { detailInstrument = nil } } }
            }
        }
        .tint(MarketPalette.accent)
        .task { store.startRefreshing(); await commerce.start() }
        .alert(tr("提示", "Notice"), isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) {
            Button(tr("好", "OK")) { store.message = nil }
        } message: { Text(store.message ?? "") }
        .confirmationDialog(tr("删除设备服务数据？", "Delete device service data?"), isPresented: $confirmDeletion, titleVisibility: .visible) {
            Button(tr("删除", "Delete"), role: .destructive) {
                deleting = true
                Task { defer { deleting = false }; await store.deleteServiceData() }
            }
            Button(tr("取消", "Cancel"), role: .cancel) { }
        } message: {
            Text(tr("将结束盯盘并删除此设备的服务端记录，自选列表保留。此操作不会取消 Apple 订阅。", "This ends watching and deletes this device's server records. Your watchlist stays saved. Apple subscriptions are not cancelled."))
        }
    }
    private var dashboard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(tr("我的自选", "Watchlist")).font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Text(store.isPro ? tr("按序轮播", "In order") : tr("显示首位", "First asset"))
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.horizontal, 4)
                ForEach(store.chosen) { item in draggableQuoteCard(item) }
            }.padding(.horizontal, 20).padding(.vertical, 12)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(tr("盯盘", "Watch"))
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 16) {
                    NavigationLink { marketDetails } label: { Image(systemName: "info.circle") }
                        .accessibilityLabel(tr("行情与更新说明", "Market and update information"))
                    Button { tab = 1 } label: { Image(systemName: "plus") }
                        .accessibilityLabel(tr("管理自选", "Manage watchlist"))
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { watchControls }
    }
    private var watchControls: some View {
        VStack(spacing: 10) {
            if store.activityRunning {
                Text(tr("灵动岛已开启", "Island is active"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button {
                guard !activityActionPending else { return }
                endingWatch = store.activityRunning
                activityActionPending = true
                Task {
                    defer { activityActionPending = false }
                    if store.activityRunning { await store.endActivity() } else { await store.startActivity() }
                }
            } label: {
                HStack(spacing: 8) {
                    if store.activityStarting || activityActionPending { ProgressView().tint(store.activityRunning ? Color.primary : (colorScheme == .light ? .white : .black)) }
                    else { Image(systemName: store.activityRunning ? "stop.circle" : "waveform.path") }
                    Text(activityActionPending ? (endingWatch ? tr("正在结束…", "Stopping…") : tr("正在开启…", "Starting…")) : (store.activityRunning ? tr("结束盯盘", "Stop watching") : tr("显示到灵动岛", "Show on Dynamic Island")))
                }.font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(store.activityRunning ? Color(uiColor: .tertiarySystemFill) : MarketPalette.accent)
            .foregroundStyle(store.activityRunning ? Color.primary : (colorScheme == .light ? .white : .black))
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .disabled(store.activityStarting || activityActionPending)
        }.padding(.horizontal, 20).padding(.vertical, 12).frame(maxWidth: .infinity).background(.regularMaterial)
    }
    private func draggableQuoteCard(_ item: Instrument) -> some View {
        quoteCard(item)
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(dropTarget == item.id ? MarketPalette.accent : .clear, lineWidth: 2))
            .onDrag { draggedAsset = item.id; return NSItemProvider(object: item.id as NSString) }
            .onDrop(of: [UTType.text], isTargeted: Binding(get: { dropTarget == item.id }, set: { dropTarget = $0 ? item.id : nil })) { providers in
                guard let source = draggedAsset, let provider = providers.first,
                      provider.canLoadObject(ofClass: NSString.self) else { return false }
                provider.loadObject(ofClass: NSString.self) { value, _ in
                    guard let payload = value as? String, payload == source else { return }
                    Task { @MainActor in store.moveSelected(source, before: item.id) }
                }
                draggedAsset = nil; dropTarget = nil
                return true
            }
            .contentShape(RoundedRectangle(cornerRadius: 24))
            .onTapGesture { detailInstrument = item }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(tr("查看资产详情", "View instrument details"))
            .accessibilityAction { detailInstrument = item }
            .accessibilityAction(named: Text(tr("向上移动", "Move up"))) { moveAsset(item.id, by: -1) }
            .accessibilityAction(named: Text(tr("向下移动", "Move down"))) { moveAsset(item.id, by: 1) }
    }
    private func quoteIdentity(_ item: Instrument) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(item.symbol).font(.title3.weight(.semibold))
            Text([item.typeLabel, item.exchange].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
    }
    private func quotePrice(_ item: Instrument) -> some View {
        let quote = store.quotes[item.id]
        return VStack(alignment: .trailing, spacing: 5) {
            Text(quote?.formattedPrice ?? "—").font(.title2.monospacedDigit().weight(.semibold))
                .lineLimit(1).minimumScaleFactor(0.7)
            if let quote, quote.change != nil {
                Text(quote.formattedChange + " · " + (quote.basis == "last" ? tr("日涨跌", "DAY") : "24h"))
                    .font(.caption.monospacedDigit())
            }
        }.foregroundStyle(store.color(quote?.change))
    }
    private func quoteCard(_ item: Instrument) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) { quoteIdentity(item); quotePrice(item) }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) { quoteIdentity(item); Spacer(minLength: 8); quotePrice(item) }
                    VStack(alignment: .leading, spacing: 12) { quoteIdentity(item); quotePrice(item) }
                }
            }
            if !store.isPro, store.activeSelected.first == item.id {
                Label(tr("灵动岛", "Dynamic Island"), systemImage: "waveform.path").font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let points = store.history[item.id], points.count > 1 {
                VStack(alignment: .trailing, spacing: 4) {
                    Sparkline(values: points).stroke(store.quotes[item.id]?.change == nil ? MarketPalette.accent : store.color(store.quotes[item.id]?.change), style: StrokeStyle(lineWidth: 2, lineCap: .round)).frame(height: 48)
                        .accessibilityLabel(tr("本次浏览期间采集的价格走势", "Price samples from this app visit"))
                    Text(tr("本次浏览", "This visit")).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            if let error = store.errors[item.id] {
                Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
            }
            if let quote = store.quotes[item.id] { quoteMetadata(quote) }
            else if store.loading { ProgressView().controlSize(.small) }
            else { Text(tr("等待报价", "Awaiting quote")).font(.caption).foregroundStyle(.secondary) }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
    }
    private func quoteMetadata(_ quote: IslandQuote) -> some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle().fill(quote.isStale(at: context.date) ? .orange : MarketPalette.accent).frame(width: 5, height: 5)
                    Text(quote.source).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(quote.updatedAt.formatted(date: Calendar.current.isDate(quote.updatedAt, inSameDayAs: context.date) ? .omitted : .abbreviated, time: .standard)).monospacedDigit()
                }.font(.caption2).foregroundStyle(.secondary)
                let notes = quoteNotes(quote, at: context.date)
                if !notes.isEmpty { Text(notes).font(.caption2).foregroundStyle(quote.isStale(at: context.date) ? Color.orange : Color.secondary) }
            }
        }
    }
    private func quoteNotes(_ quote: IslandQuote, at date: Date) -> String {
        var notes: [String] = []
        if quote.marketState == "closed" { notes.append(tr("休市", "Market closed")) }
        if quote.delaySeconds > 0 { notes.append(tr("延迟 ", "Delayed ") + "\(quote.delaySeconds)s") }
        if quote.isStale(at: date) { notes.append(tr("报价待刷新", "Quote outdated")) }
        return notes.joined(separator: " · ")
    }
    private var instruments: some View {
        List {
            marketPickerSection
            catalogStatusSection
            selectedAssetsSection
            availableAssetsSection
        }
        .navigationTitle(tr("自选", "Watchlist"))
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: tr("搜索代码或名称", "Symbol or name"))
        .scrollDismissesKeyboard(.interactively)
        .refreshable { await store.refreshCatalog() }
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
    private var stockMarketIsEmpty: Bool { market == "US" && store.stockNotice == nil && !store.catalog.contains { $0.market == market } }
    @ViewBuilder private var catalogStatusSection: some View {
        if store.catalogNotice != nil || (market == "US" && store.stockNotice != nil) || stockMarketIsEmpty {
            Section {
                if let notice = store.catalogNotice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                if market == "US", store.stockNotice != nil {
                    Text(tr("美股个人测试暂不可用", "Personal US testing unavailable")).font(.subheadline).foregroundStyle(.secondary)
                    NavigationLink(tr("查看测试设置", "View test settings")) { personalTesting }
                }
                if stockMarketIsEmpty { Text(tr("美股暂不可用", "US stocks unavailable")).foregroundStyle(.secondary) }
                if !store.catalogLoading { Button(tr("重新加载", "Reload")) { store.reloadCatalog() } }
            }
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
                        if !store.activeSelected.contains(item.id) { Text(tr("已保留 · Pro 启用", "Saved · needs Pro")).font(.caption2).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 4)
                    Button { store.toggle(item) } label: { Image(systemName: "minus.circle").frame(minWidth: 44, minHeight: 44) }
                        .buttonStyle(.borderless).disabled(store.activityRunning || store.activityStarting || store.selected.count == 1)
                        .accessibilityLabel(item.symbol + tr("，移除", ", remove"))
                }.padding(.vertical, 2)
            }.onMove { store.moveSelected(from: $0, to: $1) }.moveDisabled(store.activityStarting)
        } header: { Text(tr("我的自选", "My watchlist") + " · \(store.activeSelected.count)/\(store.watchlistLimit)") }
          footer: { Text(store.isPro ? tr("灵动岛与小组件按此顺序显示。", "The Island and widgets follow this order.") : tr("第一位显示在灵动岛和小号小组件。", "The first asset appears in the Island and small widget.")) }
    }
    private var matchingAssets: [Instrument] {
        store.catalog.filter { item in
            guard market == "All" || item.market == market else { return false }
            return search.isEmpty || [item.id, item.symbol, item.name].joined(separator: " ").localizedCaseInsensitiveContains(search)
        }
    }
    private var availableAssetsSection: some View {
        let matches = matchingAssets
        return Section(tr("市场", "Markets")) {
            if matches.isEmpty {
                if store.catalogLoading { ProgressView(tr("更新列表…", "Updating markets…")) }
                else { emptySearchHint }
            } else { ForEach(matches) { item in assetSelectionButton(item) } }
        }
    }
    private var emptySearchHint: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("没有匹配结果", "No matches")).foregroundStyle(.secondary)
            if market != "US" { Button(tr("查看美股", "Browse US stocks")) { market = "US"; search = "" } }
            Button(tr("清除筛选", "Clear filters")) { market = "All"; search = "" }
        }.font(.subheadline)
    }
    private func assetDescription(_ item: Instrument) -> String {
        [item.name == item.symbol ? "" : item.name, item.typeLabel, item.exchange].filter { !$0.isEmpty }.joined(separator: " · ")
    }
    private func assetSelectionButton(_ item: Instrument) -> some View {
        let selected = store.selected.contains(item.id)
        return Button { store.toggle(item) } label: {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.symbol).font(.headline).foregroundStyle(.primary)
                    Text(assetDescription(item)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 8)
                Image(systemName: selected ? "checkmark.circle.fill" : "plus.circle").frame(minWidth: 32, minHeight: 44)
            }.padding(.vertical, 2)
        }.accessibilityLabel(Text(item.symbol + (selected ? tr("，已选择", ", selected") : tr("，添加", ", add"))))
    }
    private func instrumentDetails(_ item: Instrument) -> some View {
        Form {
            Section {
                LabeledContent(tr("名称", "Name"), value: item.name)
                LabeledContent(tr("类型", "Type"), value: item.typeLabel)
                if !item.exchange.isEmpty { LabeledContent(tr("交易所", "Exchange"), value: item.exchange) }
                LabeledContent(tr("计价币种", "Price currency"), value: item.currency)
                if !item.settlementCurrency.isEmpty { LabeledContent(tr("结算币种", "Settlement currency"), value: item.settlementCurrency) }
            }
            if let quote = store.quotes[item.id] {
                Section(tr("报价", "Quote")) {
                    LabeledContent(tr("价格", "Price"), value: quote.formattedPrice)
                    LabeledContent(tr("来源", "Source"), value: quote.source)
                    LabeledContent(tr("状态", "Status"), value: quote.statusLabel)
                    LabeledContent(tr("报价时间", "Quote time"), value: quote.updatedAt.formatted(date: .abbreviated, time: .standard))
                    if !quoteNotes(quote, at: Date()).isEmpty { Text(quoteNotes(quote, at: Date())).font(.footnote).foregroundStyle(.secondary) }
                }
            }
            Section {
                Button { moveAsset(item.id, by: -1) } label: { Label(tr("上移", "Move up"), systemImage: "arrow.up") }
                    .disabled(store.activeSelected.first == item.id)
                Button { moveAsset(item.id, by: 1) } label: { Label(tr("下移", "Move down"), systemImage: "arrow.down") }
                    .disabled(store.activeSelected.last == item.id)
            }
        }.navigationTitle(item.symbol).navigationBarTitleDisplayMode(.inline)
    }
    private var settings: some View {
        Form {
            membershipSection
            Section(tr("外观", "Appearance")) {
                Picker(tr("主题", "Theme"), selection: $appearance) {
                    Text(tr("跟随系统", "System")).tag("system")
                    Text(tr("深色", "Dark")).tag("dark")
                    Text(tr("浅色", "Light")).tag("light")
                }
                Toggle(tr("红涨绿跌", "Red for gains"), isOn: $store.redUp).onChange(of: store.redUp) { value in
                    UserDefaults.standard.set(value, forKey: "redUp")
                    Task { await store.updateActivity() }
                }
            }
            Section {
                NavigationLink { widgetHelp } label: { Label(tr("桌面小组件", "Home Screen widgets"), systemImage: "square.grid.2x2") }
                NavigationLink { marketDetails } label: { Label(tr("行情与更新", "Market & updates"), systemImage: "waveform.path") }
                NavigationLink { personalTesting } label: { Label(tr("美股个人测试", "Personal US testing"), systemImage: "person.crop.circle") }
                NavigationLink { about } label: { Label(tr("关于", "About"), systemImage: "info.circle") }
            }
        }.navigationTitle(tr("设置", "Settings"))
    }
    private var membershipSection: some View {
        Section {
            Button { store.showPro = true } label: {
                HStack(spacing: 14) {
                    Image(systemName: "sparkles").font(.title3).foregroundStyle(MarketPalette.accent)
                        .frame(width: 44, height: 44).background(MarketPalette.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(store.isPro ? "Nosce Island Pro" : tr("免费版", "Free")).font(.headline).foregroundStyle(.primary)
                        Text(store.isPro ? tr("8 个自选 · 全尺寸小组件", "8 assets · all widget sizes") : tr("3 个自选 · 查看 Pro 权益", "3 assets · explore Pro")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }.padding(.vertical, 6).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
    }
    private var widgetHelp: some View {
        Form {
            Section {
                Label(tr("小号 · 1 个资产", "Small · 1 asset"), systemImage: "square")
                Label(tr("Pro 中号 · 最多 3 个", "Pro medium · up to 3"), systemImage: "rectangle")
                Label(tr("Pro 大号 · 最多 8 个", "Pro large · up to 8"), systemImage: "rectangle.portrait")
            }
            Section(tr("添加到桌面", "Add to Home Screen")) {
                Text(tr("长按主屏幕，添加 Nosce Island 小组件，再选择尺寸。", "Touch and hold the Home Screen, add a Nosce Island widget, then choose a size."))
                Text(tr("内容跟随自选顺序。刷新由 iOS 调度，不保证逐秒更新。", "Widgets follow your watchlist order. iOS schedules refreshes; updates are not guaranteed every second.")).foregroundStyle(.secondary)
            }
            Section(tr("更新状态", "Update status")) { Text(store.widgetStockStatus).font(.footnote).foregroundStyle(.secondary) }
        }.navigationTitle(tr("桌面小组件", "Widgets")).navigationBarTitleDisplayMode(.inline)
    }
    private var marketDetails: some View {
        Form {
            Section(tr("连接", "Connection")) {
                LabeledContent(tr("App 行情", "App feed")) { Text(store.connection).multilineTextAlignment(.trailing) }
                LabeledContent(tr("灵动岛", "Dynamic Island"), value: store.activityRunning ? tr("已开启", "Active") : tr("未开启", "Inactive"))
                if store.activityRunning { Text(store.lastActivityResult).font(.footnote).foregroundStyle(.secondary) }
            }
            Section(tr("行情来源", "Quote sources")) {
                Text(tr("加密合约：Binance / Hyperliquid 标记价。美股：Alpaca IEX 仅供指定用户个人测试。", "Perpetuals use Binance / Hyperliquid mark prices. Alpaca IEX US stocks are restricted to personal testing."))
                Text(tr("IEX 为单一交易所报价，涨跌以前一交易日 IEX 收盘价为基准，可能与全市场价格不同。", "IEX is a single-exchange feed. Changes use the previous IEX daily close and can differ from consolidated quotes.")).foregroundStyle(.secondary)
                Text(tr("卡片保留报价来源、时间、休市及延迟状态。图表仅记录本次浏览期间的采样。", "Cards show source, quote time, closed-market and delay status. Charts contain samples from the current app visit.")).foregroundStyle(.secondary)
                Text(tr("轻点行情卡片，可查看资产名称、交易所及计价、结算币种。", "Tap a quote card for its name, exchange, price and settlement currencies.")).font(.footnote).foregroundStyle(.secondary)
            }
            Section(tr("后台更新", "Background updates")) {
                Text(tr("离开 App 后，灵动岛持续更新需要服务器推送；未启用时返回 App 更新。小组件由 iOS 调度刷新。", "After leaving the app, continuous Island updates need server push. Without it, open the app for updates. iOS schedules widget refreshes."))
                Text(tr("实时活动由 iOS 管理，单次最长 8 小时。", "iOS manages Live Activities, with a maximum of 8 hours per activity.")).font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle(tr("行情与更新", "Market & updates")).navigationBarTitleDisplayMode(.inline)
    }
    private var personalTesting: some View {
        Form {
            Section {
                Text(tr("Alpaca IEX 仅供指定用户个人测试，不属于 Pro 权益。", "Alpaca IEX access is limited to personal testing and is separate from Pro.")).font(.subheadline).foregroundStyle(.secondary)
            }
            Section {
                if let user = commerce.profile?.userId {
                    Text(user).font(.footnote.monospaced()).textSelection(.enabled)
                    ShareLink(item: user) { Label(tr("分享编号", "Share ID"), systemImage: "square.and.arrow.up") }
                } else { Button(tr("获取编号", "Load ID")) { Task { await commerce.refresh() } } }
            } header: { Text(tr("测试用户编号", "Test user ID")) }
              footer: { Text(tr("在管理后台选择此编号并保存，即可启用个人测试。", "Select this ID in admin services to enable personal testing.")) }
            if let notice = store.stockNotice { Section { Text(notice).font(.footnote).foregroundStyle(.secondary) } }
        }.navigationTitle(tr("美股个人测试", "Personal US testing")).navigationBarTitleDisplayMode(.inline)
    }
    private var about: some View {
        Form {
            Section {
                LabeledContent("Nosce Island", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                LabeledContent(tr("构建", "Build"), value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—")
            }
            Section {
                if let raw = commerce.profile?.privacyURL, let url = URL(string: raw) { Link(tr("隐私政策", "Privacy policy"), destination: url) }
                if let raw = commerce.profile?.termsURL, let url = URL(string: raw) { Link(tr("使用条款", "Terms"), destination: url) }
            }
            Section {
                Button(tr("删除设备服务数据", "Delete device service data"), role: .destructive) { confirmDeletion = true }.disabled(deleting)
            } header: { EmptyView() }
              footer: { Text(tr("自选列表保留。删除设备服务数据不会取消 Apple 订阅。", "Your watchlist is retained. Deleting device data does not cancel Apple subscriptions.")) }
        }.navigationTitle(tr("关于", "About")).navigationBarTitleDisplayMode(.inline)
    }
}

struct ProMembershipView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
        .task { await refreshPlans() }
    }
    private func refreshPlans() async {
        loading = true
        await commerce.refresh()
        if yearly == nil, monthly != nil { annual = false }
        else if monthly == nil, yearly != nil { annual = true }
        loading = false
    }
    private var introduction: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "sparkles").font(.largeTitle).foregroundStyle(MarketPalette.accent).accessibilityHidden(true)
            Text("Nosce Island Pro").font(.largeTitle.bold())
            Text(tr("更多自选，全尺寸小组件。", "More assets. Every widget size."))
                .font(.subheadline).foregroundStyle(.secondary)
            if store.isPro, let expiry = store.proExpiresAt {
                Label(tr("有效至 ", "Active through ") + expiry.formatted(date: .abbreviated, time: .omitted), systemImage: "checkmark.seal")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var comparison: some View {
        VStack(spacing: 0) {
            HStack {
                Text(tr("权益对比", "Compare plans")).font(.subheadline.bold())
                Spacer()
                if !dynamicTypeSize.isAccessibilitySize {
                    Text(tr("免费", "Free")).font(.caption).frame(width: 58)
                    Text("Pro").font(.caption.bold()).foregroundStyle(MarketPalette.accent).frame(width: 72)
                }
            }.padding(.bottom, 18)
            benefitRow(tr("自选资产", "Watchlist"), free: tr("3 个", "3"), pro: tr("8 个", "8"))
            Divider().padding(.vertical, 14)
            benefitRow(tr("灵动岛 / 锁屏", "Island / Lock Screen"), free: tr("单资产", "Single"), pro: tr("最多 8 个轮播", "Rotate 8"))
            Divider().padding(.vertical, 14)
            benefitRow(tr("桌面小组件", "Widgets"), free: tr("小号", "Small"), pro: tr("小 · 中 · 大", "S · M · L"))
        }.padding(20).background(surface, in: RoundedRectangle(cornerRadius: 24))
    }
    private func benefitRow(_ title: String, free: String, pro: String) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    Text(title).font(.headline)
                    Text(tr("免费版：", "Free: ") + free).foregroundStyle(.secondary)
                    Text("Pro: " + pro).foregroundStyle(MarketPalette.accent)
                }.frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .center, spacing: 6) {
                    Text(title).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                    Text(free).font(.caption).foregroundStyle(.secondary).frame(width: 58)
                    Text(pro).font(.caption.bold()).foregroundStyle(MarketPalette.accent).multilineTextAlignment(.center).frame(width: 72)
                }
            }
        }.fixedSize(horizontal: false, vertical: true)
    }
    private var subscriptionOptions: some View {
        VStack(alignment: .leading, spacing: 14) {
            if loading {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(tr("载入订阅…", "Loading subscriptions…")).font(.subheadline).foregroundStyle(.secondary) }
            } else if commerce.products.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Label(tr("订阅暂未开放", "Subscriptions unavailable"), systemImage: "info.circle").font(.subheadline)
                    Text(tr("可继续使用免费版。", "You can keep using Free.")).font(.caption).foregroundStyle(.secondary)
                    Button(tr("重新检查", "Check again")) { Task { await refreshPlans() } }.font(.subheadline).disabled(commerce.busy)
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(surface, in: RoundedRectangle(cornerRadius: 20))
            } else {
                Text(tr("订阅方案", "Subscription plans")).font(.headline)
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 12) { planOption(annual: false, product: monthly); planOption(annual: true, product: yearly) }
                } else {
                    HStack(alignment: .top, spacing: 12) { planOption(annual: false, product: monthly); planOption(annual: true, product: yearly) }
                }
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
                Text(product == nil ? tr("暂不可用", "Currently unavailable") : (option ? tr("每年自动续订", "Auto-renews yearly") : tr("每月自动续订", "Auto-renews monthly")))
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                .background(selected ? MarketPalette.accent.opacity(0.08) : surface, in: RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(selected ? MarketPalette.accent : Color.secondary.opacity(0.18), lineWidth: selected ? 1.5 : 1))
        }.buttonStyle(.plain).foregroundStyle(.primary)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .disabled(product == nil || commerce.busy || loading).opacity(product == nil ? 0.55 : 1)
    }
    private var purchaseControls: some View {
        VStack(spacing: 16) {
            if store.isPro {
                Link(destination: URL(string: "https://apps.apple.com/account/subscriptions")!) {
                    primaryLabel(tr("管理我的订阅", "Manage subscription"))
                }
            } else if !commerce.products.isEmpty {
                Button { if let product = selectedProduct { Task { await commerce.purchase(product) } } } label: {
                    primaryLabel(commerce.busy ? tr("正在处理…", "Processing…") : (purchaseReady ? tr("订阅 Pro · ", "Subscribe · ") + (selectedProduct?.displayPrice ?? "") + (annual ? tr(" / 年", " / year") : tr(" / 月", " / month")) : tr("购买暂不可用", "Purchases unavailable")))
                }.disabled(!purchaseReady || commerce.busy || loading).opacity(purchaseReady ? 1 : 0.5)
            }
            if !commerce.products.isEmpty {
                Text(tr("App Store 自动续订，可随时取消。实际价格以购买确认页为准。", "Auto-renews through the App Store. Cancel anytime. The purchase confirmation price applies."))
                    .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Button(tr("恢复购买", "Restore purchases")) { Task { await commerce.restore() } }
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
            Label(tr("两版采用相同的行情刷新策略。", "Both plans share the same refresh policy."), systemImage: "checkmark.shield")
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
