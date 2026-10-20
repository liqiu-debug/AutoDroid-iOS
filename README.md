# AutoDroid iOS

SwiftUI 客户端，iOS 17 及以上。底部入口：用例、场景、报告、定时、设置。

首次启动的平台地址和账号为空，需要自行填写。应用只恢复用户此前保存的连接，不内置平台地址或账号，也不打包本地默认配置。

## 设备在线状态

登录后在前台每 60 秒向平台发送心跳，执行器状态变化时提前更新；退出登录主动标记 App 离线。设备中心分别显示 App 在线、心跳超时或已退出登录，以及执行器就绪、未就绪、执行中或未知。超过 3 分钟未收到心跳即超时。iOS 后台挂起会停止心跳，超时不表示 WDA 任务已停止。

App 标识与 USB UDID 不同。在 Web 设备中心点击“绑定有线／无线设备”可手动选择同一台手机，绑定后合并卡片、保留两条连接的独立状态；“管理同机绑定”可解除。只有 App 接入时不开放 Web 截图、WDA 或其他物理设备控制。

## 执行与报告

- 登录成功后才显示导航、用例和执行入口；启动时会验证钥匙串中的会话。
- 点击用例或场景条目进入只读预览：用例按顺序展示步骤、iOS 定位、参数、超时和失败处理；场景按编排顺序展示子用例与别名，可继续进入子用例预览。空内容、加载失败和已删除用例分别提示。
- 列表右侧运行按钮直接运行，采用设置中的默认飞书通知与执行环境；预览页底部也可直接运行，并可单独调整本次飞书通知。预览不会生成或执行脚本，运行时仍重新获取最新脚本。
- 点击运行时请求平台 `app-runs/{cases|scenarios}/{id}/script?platform=ios`，禁用缓存并校验脚本，再提交给本机 WDA。没有手动下载、已下载或旧脚本执行入口。
- 飞书开关传入运行配置并保留在报告中；使用平台已有机器人配置。失败报告与成功报告都自动回传，App 恢复前台后补传未成功上传的记录，平台按 run_id 去重。
- 报告支持平台记录搜索、状态筛选、分页和完整 HTML 详情，以及本机日志、步骤与回传状态。
- 用例、场景及定时目标选择支持平台文件夹层级筛选，保留空文件夹，并支持文件夹内搜索和分页。
- 执行结束由 WDA 返回 AutoDroid，AutoDroid 读取完成结果、切换报告页并发送自己的系统通知；首次运行申请 AutoDroid 通知权限，设置中可关闭。按 run_id 去重。锁屏等原因无法返回 App 时，下次打开后补发；没有配置 APNs 后台推送。

## 定时任务

支持单次、每天、每周和分钟间隔，可选择用例/场景、环境、飞书通知，支持编辑、启停和删除。

定时器运行在 WDA 中，App 切到后台后也可触发。触发时获取平台最新脚本，预检/网络失败不会执行缓存脚本。执行器忙碌时顺延；过期登录禁用定时任务。退出登录会先撤销 WDA 中的定时任务。

WDA 必须保持测试会话，手机应保持解锁并具备目标应用的正常操作条件。WDA 重启后打开 App 恢复定时任务；历史错过的时间不补跑。任务与下一次执行时间持久保存，WDA 仅在内存中保存访问令牌。

## 开发与验证

```sh
swift test
python3 Scripts/generate_project.py
xcodebuild -project AutoDroid.xcodeproj -scheme AutoDroid -configuration Debug -destination 'generic/platform=iOS' -allowProvisioningUpdates build
```

新增 App 或 Core Swift 文件后运行项目生成器。图标直接复用相邻 AutoJs6 项目的 Android 图案：

```sh
swift Scripts/make_icon.swift Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png
```

本机 WDA 固定为 `127.0.0.1:8100`，需安装支持 `/autodroid/run`、`/autodroid/schedules` 以及 `notify_app`/`completion_bundle_id` 完成回跳参数的 AutoDroid-WDA 构建。AutoDroid 的通知和局域网权限需在手机上允许。
