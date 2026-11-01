# Nosce Island

A lightweight iPhone market companion with a Dynamic Island interface and a mobile web preview.

轻量行情 App，采用深色与薄荷绿波形标志，行情来源为 Hyperliquid。

## Downloads / 文件下载

| File | Contents |
| --- | --- |
| [NosceIsland-iOS-Alpha-0.2.zip](NosceIsland-iOS-Alpha-0.2.zip) | 原生 iOS 工程、ActivityKit 扩展、图标、接口模型与测试资料；不是已签名 IPA |
| [nosce-island-preview.html](nosce-island-preview.html) | 手机交互预览源码，单文件 HTML，无构建依赖 |
| [Nosce-Island-source.zip](Nosce-Island-source.zip) | 整理好的完整源码目录：`ios/`、`preview/`、安装说明及 `.gitignore` |

## Mobile preview / 手机交互预览

[Open the hosted interactive preview / 打开手机预览](https://nosce-island-mobile.brawnypixie21.chatgpt.site/)

The hosted preview may require sign-in with the owner's ChatGPT account. You can switch screens, manage two watchlist assets, expand the simulated island, change appearance/language, and enable Hyperliquid live data.

网页中的灵动岛是模拟展示，不能控制 iPhone 系统灵动岛。示例模式中的价格与图表不代表当前市场。

To run the web preview locally, extract `Nosce-Island-source.zip` and run:

```bash
python3 -m http.server 8080 --directory preview
```

Open `http://localhost:8080` on the computer. A phone on the same network can use a reachable address of that computer.

## Native iOS alpha / 原生测试

1. Download and extract `NosceIsland-iOS-Alpha-0.2.zip`.
2. Open `NosceIsland.xcodeproj` in an Xcode version supporting your iPhone's iOS version.
3. Choose the `NosceIsland` scheme.
4. Set the same signing team for both the App and Live Activity extension, then connect your iPhone and run.
5. Read the included `README-先读我.md` for full installation and testing instructions.

The package contains source code, not an App Store release or signed installation package. It has not yet been compiled in Xcode or verified on an iPhone. Swift syntax, project/resource structure, and live Hyperliquid REST/WebSocket message shapes have been checked.

## Market data / 行情说明

- Hyperliquid public API and WebSocket `activeAssetCtx`.
- Perpetual mark price (`markPx`), with 24h change calculated against `prevDayPx`.
- Native app discovers markets using `perpDexs` and each market's `meta`; the preview refreshes native and `xyz` markets.
- Full market-prefixed IDs remain distinct across markets.
- Equity-linked contracts are not official stock exchange quotes. Hong Kong coverage depends on actual listings; US/HK symbols are not silently mapped.
- Displayed times indicate local receipt, not exchange trade timestamps.

## Current limitations / 当前边界

本地 iOS 版进入后台后停止行情连接，并标记过期数据。持续后台灵动岛行情还需要服务器和 Apple ActivityKit/APNs 推送配置，本版尚未包含。

No trading, account system, payments, ads, portfolio or price-alert backend is implemented. The web prototype does not imply native feature parity.

## Official references

- https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/info-endpoint/perpetuals
- https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/websocket/subscriptions
- https://developer.apple.com/documentation/ActivityKit
