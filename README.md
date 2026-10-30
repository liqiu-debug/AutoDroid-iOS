# AutoDroid iOS

**[AutoDroid](https://github.com/liqiu-debug/AutoDroid)** 自动化测试平台的 iOS 客户端（SwiftUI，iOS 17 及以上）。
登录平台后可在手机上执行用例 / 场景、查看报告、维护设备侧定时任务；脚本不在 App 进程里跑，
而是交给**同一台手机上**的 [AutoDroid-WDA](https://github.com/liqiu-debug/AutoDroid-WDA) 执行器
（WebDriverAgent fork，固定监听 `127.0.0.1:8100`）。

- 平台端：<https://github.com/liqiu-debug/AutoDroid>；接入协议见平台仓库
  [docs/APP_RUNNER_API.md](https://github.com/liqiu-debug/AutoDroid/blob/main/docs/APP_RUNNER_API.md)（第 8 节是 iOS 专属部分）。
- 同一产品的其它端：[AutoDroid-Android](https://github.com/liqiu-debug/AutoDroid-Android)、[AutoDroid-Desktop](https://github.com/liqiu-debug/AutoDroid-Desktop)。
- 首次启动的平台地址和账号为空，需要自行填写。应用只恢复用户此前保存的连接，不内置平台地址或账号。

## 它怎么工作

```text
AutoDroid App                           AutoDroid-WDA（同机 127.0.0.1:8100）            平台
─────────────                           ────────────────────────────────            ────
登录 POST /auth/token ──────────────────────────────────────────────────────────▶
注册 POST /device-runs/register {platform: ios, udid 或 IDFV} ─────────────────▶
点「运行」
GET /app-runs/{cases|scenarios}/{id}/script?platform=ios ─────────────────────▶
   ◀── bundle（manifest / runtime.js / main.js / adapter_js / case_files / assets）
POST /autodroid/run {bundle, run_id, server, token, notify, …} ──▶ 落盘 Documents/autodroid_runs/<run_id>/
                                                                   JavaScriptCore 执行 runtime.js + 适配层
                                                                   runtime.js POST /device-runs/report ───▶
                                                            ◀── 完成后激活 AutoDroid（completion_bundle_id）
每 3 秒 GET /autodroid/status、/autodroid/schedules 刷新状态；取回报告、发本地通知、切到报告页
上报失败的报告由 App 在回到前台后补传（按 run_id 去重）
```

几个约定：

- **每次运行都重新向平台取最新脚本**，禁用缓存并校验脚本包（`format_version == 1`、`manifest.platform == ios`、含 `adapter_js`）；预检不通过不会提交给执行器。
- App 标识与 USB UDID 不同。在 Web 设备中心「绑定有线／无线设备」可把 App 设备与同一台手机的 USB 设备合并显示，保留两条连接各自的状态；只有 App 接入时不开放 Web 截图、WDA 或其它物理设备控制。
- 成功与失败报告都会回传；WDA 没有网络权限弹窗时上报可能失败，App 回到前台后用自己的网络权限补传，平台按 `run_id` 去重。
- 执行结束由 WDA 把 AutoDroid 拉回前台（`notify_app` + `completion_bundle_id`），App 读取结果、切到报告页并发送**自己的**系统通知；首次运行申请通知权限，设置中可关闭。锁屏等原因无法回跳时，下次打开补发。没有 APNs 后台推送。

## 功能

| 入口 | 说明 |
|---|---|
| 用例 / 场景 | 平台文件夹层级筛选（保留空文件夹）、文件夹内搜索与分页；点击条目进入只读预览（步骤、iOS 定位、参数、超时、失败处理；场景展示子用例与别名，可继续进入子用例） |
| 运行 | 列表右侧运行按钮用设置里的默认飞书通知与执行环境；预览页底部可单独调整本次飞书通知 |
| 报告 | 平台记录搜索、状态筛选、分页、完整 HTML 详情；本机运行记录的日志、步骤与回传状态 |
| 定时 | 单次 / 每天 / 每周 / 分钟间隔；选择用例或场景、环境、飞书通知；编辑、启停、删除 |
| 设置 | 平台地址与账号、默认飞书通知、系统通知开关、本机自检、退出登录 |

## 设备在线状态

登录后在前台每 60 秒向平台发送心跳，执行器状态变化时提前更新；退出登录主动标记 App 离线。
设备中心分别显示 App 在线 / 心跳超时 / 已退出登录，以及执行器就绪 / 未就绪 / 执行中 / 未知。
超过 3 分钟未收到心跳即超时。iOS 后台挂起会停止心跳，**超时不表示 WDA 任务已停止**。

## 定时任务

支持单次、每天、每周和分钟间隔。定时器运行在 **WDA 进程内**（`POST /autodroid/schedules` 整体替换），
App 切到后台后也能触发。触发时由 WDA 用保存的 `fetch_url` + token 向平台取最新脚本，预检 / 网络失败不会执行缓存脚本；
执行器忙碌时顺延；登录过期会禁用定时任务；退出登录会先撤销 WDA 中的定时任务。

WDA 必须保持测试会话，手机应保持解锁并具备目标应用的正常操作条件。WDA 重启后打开 App 即可恢复定时任务
（App 会把本机保存的任务重新推给 WDA）；**历史错过的时间不补跑**。任务与下一次执行时间持久保存在 App 侧；
WDA 仅在内存中保存访问令牌。

## 代码地图

```text
AutoDroid-iOS/
├── Sources/Core/           # SwiftPM 库 AutoDroidCore（可在 macOS 上 swift test）
│   ├── Models.swift        #   平台 / 执行器数据模型、脚本包校验
│   ├── Clients.swift       #   PlatformClient（平台 REST）、ExecutorClient（127.0.0.1:8100）、HTTPClient、地址校验
│   └── ScriptPreview.swift #   用例 / 场景只读预览的构建
├── App/                    # SwiftUI 应用（依赖 Core）
│   ├── AutoDroidApp.swift  #   入口；前台每 3 秒 refresh()
│   ├── AppModel.swift      #   状态机：登录 / 运行 / 轮询 / 补传 / 定时同步 / 心跳
│   ├── Views.swift · FeatureViews.swift · ScriptPreviewView.swift
│   ├── Storage.swift       #   SessionVault（钥匙串）与 LocalStorage（Application Support/AutoDroid）
│   └── CompletionNotifications.swift  # 完成通知与按 run_id 去重
├── Tests/CoreTests/        # swift test（只覆盖 Core）
├── Resources/              # Info.plist、Assets.xcassets、selftest.json
├── Scripts/
│   ├── generate_project.py # 生成 AutoDroid.xcodeproj（新增 Swift 文件后必须重跑）
│   └── make_icon.swift     # 由 Android 图案生成 App 图标
├── Package.swift
└── VERIFICATION.md         # 历次验证记录
```

## 存储与安全

| 数据 | 位置 | 说明 |
|---|---|---|
| 平台会话 token | 钥匙串，service `com.liuzhenyu.autodroid.session` | `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`；启动时据此恢复登录 |
| 本机运行记录 `runs.json`、定时任务 `schedules.json` | `Application Support/AutoDroid/` | 原子写入，首次解锁前受文件保护 |
| 已发送通知、补传计数 | `UserDefaults` | 按 `run_id` 去重 |
| 执行器侧 | WDA 的 `Documents/autodroid_runs/<run_id>/` | 只保留最近 10 次；`autodroid_scheduler.json` 持久化调度 |

注意：

- `Info.plist` 设置了 `NSAllowsArbitraryLoads = true` 以允许 `http://` 平台地址（内网部署常见），此时凭证会明文经过该连接；对外访问请用 `https://`。
- App 与执行器之间走本机回环明文 HTTP；执行器本身没有鉴权，详见 AutoDroid-WDA 的说明。

## 构建、签名与验证

```sh
swift test                                   # Core 单元测试（macOS 上即可）
python3 Scripts/generate_project.py          # 新增 App 或 Core 的 Swift 文件后重新生成工程
xcodebuild -project AutoDroid.xcodeproj -scheme AutoDroid -configuration Debug \
  -destination 'generic/platform=iOS' -allowProvisioningUpdates build
swift Scripts/make_icon.swift Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png   # 重新生成图标
```

- Bundle ID `com.liuzhenyu.autodroid.ios`，自动签名（`CODE_SIGN_STYLE = Automatic`，团队 ID 在 `project.pbxproj`）；
  换团队或换 Bundle ID 直接改 `generate_project.py` 里的常量再重新生成工程。
- **改 Bundle ID 要同步改 WDA**：执行器只会把 `completion_bundle_id == com.liuzhenyu.autodroid.ios` 的 App 拉回前台（`ADTRunner.m`），否则完成回跳会静默失效。
- **描述文件有效期**：免费 Apple ID 签出的包 7 天到期，付费开发者账号 1 年。App 与 WDA 两个包都受此约束，到期后需重签重装；
  WDA 当前安装包的到期时间可用 `security cms -D -i <embedded.mobileprovision> | plutil -extract ExpirationDate raw -` 查看。
- 版本号在 `Resources/Info.plist`（`CFBundleShortVersionString` / `CFBundleVersion`）。
- 仓库目前**没有 CI**，`swift test` 与 `xcodebuild` 都需在本机执行。历次验证记录见 [VERIFICATION.md](VERIFICATION.md)。

## 配套 WDA 要求

本机 WDA 固定为 `127.0.0.1:8100`，必须是支持以下能力的 AutoDroid-WDA 构建：

| 端点 | 用途 |
|---|---|
| `GET /autodroid/status` | 运行状态、当前 `run_id`、`last_result` |
| `POST /autodroid/run` | 提交脚本包；载荷含 `bundle, run_id, platform, device_serial, server, token, notify, system_notify, notify_app, name, completion_bundle_id` |
| `GET /autodroid/logs` | 执行日志（App 每次取完整快照） |
| `POST /autodroid/stop` | 停止当前运行 |
| `POST /autodroid/report` | 按 `run_id` 取回落盘的报告（补传用） |
| `GET` / `POST /autodroid/schedules` | 读取 / 整体替换 WDA 内的定时任务 |
| `GET` / `POST /autodroid/notifications` | 执行器侧通知权限状态 / 申请 |

## 真机准备

1. 用 AutoDroid-WDA 仓库的 `autodroid/build_ipa.sh` 构建并安装 WDA，手机开启**开发者模式**并信任证书。
2. 在手机上**点 `WebDriverAgentRunner` 图标**启动 WDA（不需要连电脑），`curl http://<手机IP>:8100/status` 可验证。
3. 安装本 App，首次运行允许**本地网络**与**通知**权限。
4. 登录平台、点一个用例运行，或在设置里跑「本机自检」。

## 排障

| 现象 | 处理 |
|---|---|
| 运行按钮灰、提示「有尚未确认结束的运行」 | 执行器当前不可达；在手机上重新点 WDA 图标，App 下一次刷新（3 秒内）会自动把该运行标为「执行器已切换任务」并恢复按钮 |
| 「本机执行器未连接」 | WDA 没在跑或被系统回收；重新点图标。重启手机后若图标起不来，需连一次 Xcode 重新挂载开发者磁盘镜像 |
| 脚本校验失败 | 平台未开启 `ios_execution`、用例缺少 iOS 定位覆盖，或平台版本过旧没有 `adapter_js` |
| 执行完成但 App 没回到前台 / 没通知 | 锁屏时无法激活，打开 App 后补发；确认 Bundle ID 与 WDA 内硬编码一致；确认通知权限 |
| 报告「待上传」 | WDA 直接上报失败（常见于 WDA 无局域网权限），App 回前台后自动重试；执行器只保留最近 10 次运行文件，长期未上传可能丢失 |
| 定时没触发 | WDA 必须存活且手机解锁；App 退出登录或登录过期会撤销 / 禁用定时任务；错过的时间不补跑 |
