# Alpaca 免费 IEX：个人美股测试（0.7.3）

本版港股入口暂停。数字货币保持原有公共数据源；美股只对指定个人测试用户开放。

## 配置步骤

1. 在 Alpaca 切到 Paper Trading（模拟交易）环境，找到 API Keys，生成 Key ID 与 Secret Key。Secret 通常只显示一次，妥善保存。这里不用创建真实交易订单。
2. 安装本版 Xcode 工程运行 App。进入「设置 → 个人美股测试」，复制/分享完整的测试用户编号；也可在已有管理后台用户详情复制对应用户完整 ID。不要使用截断的 ID。
3. 在 Vercel → nosce-island → Environment Variables 添加以下三项，选择 Production：

| Key | Value |
|---|---|
| ALPACA_API_KEY_ID | Alpaca Paper 的 Key ID |
| ALPACA_API_SECRET_KEY | 与上面配对的 Secret Key |
| ALPACA_PERSONAL_USER_ID | 第 2 步复制的完整用户编号 |

密钥选择 Secret 类型。不需要填写 TWELVE_DATA_EXTERNAL_DISPLAY_LICENSED，也不要把 API 密钥放入 App、GitHub 或聊天。若之前配置了 Twelve Data，个人 Alpaca 配置完整时会优先选用 Alpaca，且不开放港股。

4. 保存后到 Deployments，对最新提交执行 Redeploy（Production）。之后在 App「自选」刷新市场列表，切换美股并添加品种。
5. 管理后台「服务」显示「Alpaca · IEX / 个人 IEX 测试」。这表示配置齐全，不代表已验证供应商密钥；实际能否获取行情以 App 返回为准。

## 范围与限制

- 仅指定用户可调用美股目录与快照；另一个匿名设备注册不能获得美股数据。重新创建用户/删除设备数据后需更新允许的用户编号。数据源密钥仅服务器持有。
- 目录来自 Alpaca 官方 active us_equity 列表，过滤 OTC 等非支持交易所；不编造股票或报价。资产目录有该股票不保证 IEX 最近有成交。
- 固定 feed=iex，最多每批 8 个自选，每 15 秒请求；服务器共享短缓存、并发请求合并、全局上游限额。免费版不是全市场 SIP，价格和成交稀疏程度可能与券商不同。
- 显示 Alpaca · IEX、上游真实成交时间。涨跌以 IEX 前一交易日日线收盘为参考，缺少可比数据时不展示涨跌。无报价时不以示例数据或 bid/ask 代替成交价；上游失败保留原价和原时间，显示过期状态。
- App 前台可获取报价并更新本地灵动岛。此个人测试路径未接后台 APNs 行情任务；切出 App 后不保证持续更新。股票主屏幕小组件读取 App 写入的缓存，iOS 决定刷新时机。
- 免费个人 API 权限不等于公开再分发授权；不将此测试路径用于正式对公众提供行情。公开上架前重新确认 Alpaca 的应用展示/分发授权。

## 验证状态

通过模拟供应商响应验证目录过滤、IEX 来源校验、价格时间、缓存、故障保留与跨设备访问限制。未使用真实 Alpaca 密钥验证；Linux 环境只检查 Swift 语法，需在 Xcode 编译及真机测试。

官方资料：
- https://docs.alpaca.markets/us/docs/about-market-data-api
- https://docs.alpaca.markets/us/docs/paper-trading
- https://docs.alpaca.markets/us/reference/stocksnapshots-1
- https://alpaca.markets/support/redistribute-alpaca-api
