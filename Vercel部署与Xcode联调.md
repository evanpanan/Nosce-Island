# Nosce Island 0.6.0 · Vercel 后台 / Xcode App 联调

这次交付是源码，未替你部署、创建商户商品或设置公开默认密码。原生 App 免登录，管理后台需要管理员账号密码。支付只使用苹果内购。

## 先测试正式后台登录

1. 解压源码。将包含 `app.py`、`vercel.json`、`requirements.txt`、`Server` 的文件夹提交到自己的 GitHub 仓库。Vercel 不会把仓库中的源码 ZIP 自动解压成项目；需要提交解压后的文件。
2. 在 Vercel Import Project。Root Directory 选 `app.py` 所在文件夹（本包为 NosceIsland），让平台识别 FastAPI。不要选 App、Server/nosce 或旧静态预览目录。部署使用 Python 3.12。
3. 在 Vercel Storage/Marketplace 连接 PostgreSQL（例如 Neon），将连接变量提供为 `DATABASE_URL`，保留服务商提供的 TLS 参数。这是后台持久数据库，和行情 API 申请无关。
4. 在项目 Environment Variables 设置下表，选择你要测试的环境。Production 和 Preview 应分别关联测试/正式数据库；至少要在当前部署环境中设置变量。

| 变量 | 设置方式 |
| --- | --- |
| DATABASE_URL | 连接的 PostgreSQL 完整连接串，通常由集成注入 |
| TOKEN_ENCRYPTION_KEY | 在自己的 Mac 运行下方命令生成，保存好，后续不要随意更换 |
| ADMIN_USERNAME | 你希望使用的管理员账号，如 owner |
| ADMIN_PASSWORD | 自己设置，至少 14 个字符；没有默认密码 |
| ADMIN_TOTP_SECRET | 可留空，留空只要求账号密码；填写后额外要求验证器动态码 |
| COMMERCE_SALES_ENABLED | 先保持 false，不售卖尚未完成的权益 |

在 Mac 终端生成加密密钥：

```bash
python3 -c 'import secrets; print(secrets.token_hex(32))'
```

把结果填入 Vercel 私密环境变量，不放进 App、GitHub 或聊天。不要照抄 `Vercel.env.example` 的占位值。高级配置 `ADMIN_PASSWORD_HASH` 若存在，会优先于 ADMIN_PASSWORD；测试初期只设置 ADMIN_PASSWORD 即可。

5. Deploy / Redeploy。打开 `https://你的项目.vercel.app/admin`，使用刚才设置的账号密码登录。未设置必须变量时会显示配置提示，不能用 admin/admin 等默认口令进入。
6. 手机打开同一个 HTTPS 地址。支持密码自动填充、显示密码、可选动态码、登录反馈；小屏记录用卡片显示。会话最长 8 小时。退出或更新密码后会话失效。

仅部署这个默认配置，就可以测试登录、用户、订单和订阅管理接口；没配置 Apple/后台任务时相应数据为空或状态未就绪，这不是演示数据。

## Xcode 测试原生 App

在源码根目录的 Mac 终端执行：

```bash
python3 Tools/configure-api.py https://你的稳定项目域名.vercel.app
```

脚本只接受 HTTPS 根地址，不接受 `/admin` 等路径。它会修改 `Config/Service.xcconfig`，不写任何管理员密码或 Apple 私钥。也可以手动修改该文件的 NOSCE_API_BASE_URL，保留 xcconfig 中 `https:/$()/` 的写法。

打开 `NosceIsland.xcodeproj`，选 NosceIsland Scheme 及模拟器/手机，运行后版本应为 **0.6.0 (11)**。App 内公开行情仍直连 Binance/Hyperliquid，不因后台账户配置而停用。管理员不用在 App 登录。

App 会自动注册匿名安装身份，后台“用户”可看到对应 UUID。已有付费用户的恢复购买在暂停新售卖时也保持可用。当前没有预置价格或定义具体高级权益，所以售卖默认关闭。

### Vercel Deployment Protection

如果 App 请求得到 Vercel 登录页/401，而浏览器可以打开，检查该部署的 Deployment Protection。App 使用的是自己的安装凭证，不是 Vercel 账号；应使用可以公开访问业务 API 的稳定域名。不要把 Vercel 绕过令牌写进 iOS App。业务管理数据仍由我们自己的管理员登录保护。

## 持续行情和灵动岛后台推送

Vercel 普通 Functions 不启动永久行情循环。我们将它分为短请求 API 和独立 market worker，共用 PostgreSQL：

- API：账号、会话、订单、会员、活动登记、缓存读取。
- worker：持续连接数据源、记录原始报价时间、APNs 推送、续费补偿对账。
- readiness 同时检查行情目录、APNs 配置与 worker 心跳。只配一个空服务器不会再被报告为可持续后台推送。

仓库提供 `vercel.with-worker.json` 和 `Server/Dockerfile.worker`。若你的 Vercel 项目已可用 Daemons，将它复制为 vercel.json 后部署，配置中只有一个市场任务实例，并设健康检查。按 Vercel 当前文档，Daemons 为 beta，支持生产部署，Preview 不运行 Daemon；是否可用以你的账号控制台为准。没有此能力时，可将同一 worker Dockerfile 放在支持持续进程的容器平台，API 和 worker 使用相同数据库与加密密钥。worker 还需 WORKER_DATABASE_URL（或 DATABASE_URL_UNPOOLED / POSTGRES_URL_NON_POOLING），指向同一数据库的直连地址，不能使用事务连接池地址；它用于跨进程主任务锁，避免部署切换期间重复推送。

注意：仅把账号后台部署到 Vercel，不能代替 worker、APNs 和 Apple Developer 配置。没有 worker 时，App 可创建本机活动，离开前台后会标明暂停；不会伪装持续行情。后台更新频率受 iOS 送达预算影响，不保证逐笔/逐秒。

## Apple 开发者账号就绪后

在服务器环境变量配置：

- APNS_TEAM_ID、APNS_KEY_ID、APNS_PRIVATE_KEY、APPLE_BUNDLE_ID、APNS_ENVIRONMENT。
- APP_STORE_ISSUER_ID、APP_STORE_KEY_ID、APP_STORE_PRIVATE_KEY、APP_STORE_ROOT_CERTIFICATES_BASE64、APP_STORE_ENVIRONMENT。
- APP_STORE_PRODUCT_IDS、PUBLIC_PRIVACY_URL、PUBLIC_TERMS_URL；Production 还要 APP_STORE_APP_ID。

PRIVATE_KEY 支持多行 PEM 或字面量 \n，私钥仅进服务器变量。Root Certificates 是 Apple DER 根证书的 Base64，多份用逗号分开。原有 *_KEY_FILE 和证书路径配置仍适用于容器，不要求把文件打进 Vercel 函数。

App Store Connect 配置自动续期订阅、期限与价格，关闭未实现的 Family Sharing。Notifications V2 地址为 `https://你的API域名/v1/app-store/notifications`。先使用 Sandbox 和测试数据库，Xcode Debug 对应 APNs development，发布包对应 production，两个环境不要混用。

当前高级权益/价格仍待确定和实现，请不要仅凭 Pro 标签就开启收费。真实 Apple 验签、支付、恢复、续费、退款和推送必须联调后再开启 COMMERCE_SALES_ENABLED。用户购买无需 Nosce 账号，不跳支付宝/微信/USDT。

## 验证边界

已执行本地自动化测试，并使用 PGlite 的 PostgreSQL 引擎与 PostgreSQL 协议验证建表、持久会话、跨实例读取、购买/恢复归属和退款逻辑。它不是 Vercel/Neon 云端验收；仓库另有 PostgreSQL 16 CI 任务，尚未在 GitHub 运行。

本环境没有 Xcode，没有替你部署 Vercel，也没有 Apple 收款或 APNs 凭据。不能据此声称已完成真机或真实付款验收。

官方参考：
- https://vercel.com/docs/frameworks/backend/fastapi
- https://vercel.com/docs/postgres
- https://vercel.com/docs/daemons
- https://vercel.com/docs/functions/limitations
