# Nosce Island 0.8.0（build 21）

本工程包含 iOS App、灵动岛与锁屏实时活动、主屏幕小组件，以及部署在 Vercel 的公开官网、管理后台和 API。

## 先看这里

- 当前权益与购买准备：[Free / Pro 说明](Free与Pro-0.8.0.md)。Free：3 个自选、单资产盯盘、小号组件。Pro：8 个自选、最多 8 个逐个轮播、小中大组件。
- 官网为域名首页 `/`；管理后台为 `/admin`。官网使用公开加密行情做交互演示，下载地址可在管理后台「服务」中配置。
- USD 参考价格为月付 $4.99、年付 $39.99。实际地区售价必须在 App Store Connect 配置，App 展示苹果返回的价格。商品、校验、协议和沙盒测试未准备好时，不开放购买。
- 到期保留原自选，启用免费额度；退款与恢复购买以服务端验证的 Apple 记录为准。不会通过后台手工伪造会员。
- 两版行情刷新策略相同。App 前台直连公开行情；离开前台后，灵动岛持续更新需要 APNs 和持续行情任务；小组件刷新由 iOS 调度。
- 美股 Alpaca IEX 仅限指定用户个人测试；公开美股服务不属于 Pro 权益。港股与 Android 暂未开放。

## Xcode

打开 `NosceIsland.xcodeproj`。检查 App 和 Widget Extension 使用同一个已注册 App Group，填写正确的 Apple Team 与 Bundle ID。配置位置见 `Config/` 和 [小组件说明](主屏幕小组件-0.7.0.md)。

构建版本为 0.8.0 / 21。签名安装、APNs 真机送达和真实 Apple 沙盒购买仍需开发者账号；GitHub 检查只执行未签名模拟器构建与自动化测试。

## 部署

源码根目录包含 `app.py`、`vercel.json`、`pyproject.toml`、`requirements.txt` 和环境变量示例。Vercel 使用 PostgreSQL 持久化用户、订单、订阅和运营者配置，不能使用临时 SQLite 代替。详见 [部署与联调](Vercel部署与Xcode联调.md)。

代码已同步到 `evanpanan/Nosce-Island`，推送触发 Vercel 自动部署。管理员账号、数据库和加密主密钥属于部署配置；第三方服务、订阅商品和下载链接可在后台配置。

下载包内 `Preview/NosceIsland-Admin-Preview.html` 是新版离线界面预览，使用空的模拟记录，不连接服务器，不保存配置或执行购买。

其他按版本命名的说明保留为历史记录；发生冲突时以本文件和 `Free与Pro-0.8.0.md` 为准。
