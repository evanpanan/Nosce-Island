> 0.7.1（build 14）统一价格涨跌颜色，详见 [更新记录](更新记录-0.7.1.md)。主屏幕小组件与 App Groups 配置继续参考下方说明。

> 0.7.0 新增小、中、大主屏幕行情组件，保留灵动岛。构建前请看 [主屏幕小组件说明](主屏幕小组件-0.7.0.md)，确认 App 与 Widget 扩展的 App Groups 签名配置。后台继续使用 0.6.8。

# Nosce Island 0.6.0

本版同步提供原生 iOS 工程与可部署到 Vercel 的真实管理后台。请先阅读 **Vercel部署与Xcode联调.md**。

- 后台：管理员账号密码，动态码可选；手机密码自动填充、显示/隐藏密码、登录反馈和记录卡片。无默认密码，不使用离线预览冒充管理后台。
- 数据：Vercel 使用 PostgreSQL 持久化会话、用户、订单、会员与活动；本地 SQLite 仍用于旧单进程部署和测试。Vercel 明确拒绝本地临时数据库。
- 运行：短请求 API 与持续 market worker 分开，跨进程共享目录/报价/订阅；后台任务心跳参与 readiness。
- 支付：仅苹果内购；服务端验签和归属验证、恢复购买、续费/退款处理。App 保持免登录；售卖开关默认关闭，未设置正式商品与价格。
- App：保留最多 8 个关注资产、每组 2 个，公开真实行情直接连接；恢复前台会同步会员状态，购买失败明确反馈，显示订阅期限与自动续费说明。

部署文件在源码根目录：app.py、vercel.json、pyproject.toml、requirements.txt、Vercel.env.example。Xcode 打开 NosceIsland.xcodeproj。额外的 Admin-Preview.html 仅供静态查看布局，不是正式后台登录入口。

没有执行 Vercel 云端部署、Xcode 编译、真机 APNs 或真实 StoreKit 付款；对应操作需你的账号与环境。GitHub 仓库没有自动同步本源码包。
