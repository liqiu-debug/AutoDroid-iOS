# iOS 0.2.1 验证记录

验证日期：2026-10-20。客户端构建号 3，已安装到已连接的 iPhone；配套 WDA 已重新构建并安装。

## 后续增量：设备在线状态

0.2.2 (4) 已构建并安装；Swift 20 项通过。新增独立 App 心跳、执行器状态和退出登录下线接口；退出前等待正在进行的刷新完成，避免迟到心跳覆盖下线。前台 60 秒心跳，平台 3 分钟超时；后台挂起不代表任务结束。Web 与 Android 的对应实现、隔离 UI 检查和验证范围见相邻 `AutoDroid/docs/app-device-presence.md`。本轮没有退出用户真实登录会话。

## 后续增量：用例与场景预览

发布准备：0.2.3 (6) 已移除内置平台地址和预填账号，以及 LocalDefaults 资源加载/打包逻辑。首次安装为空，保留用户自己保存的连接；Swift 23 项和全新目录的真机构建通过。

0.2.3 (5)：点击列表条目进入只读预览，独立运行按钮直接取最新脚本执行，预览底部也可执行。场景展示有序子用例及别名，并可打开子用例步骤。列表运行采用设置中的默认飞书选项，预览支持调整本次选项。两个按钮显式采用独立点击样式，避免 SwiftUI List 行内按钮自动行为造成误执行。

Swift 23 项通过。新增测试验证 GET 预览不请求执行脚本、iOS 定位覆盖、步骤顺序、场景重复引用及别名、缺失用例和过期登录。测试发现 HTTPClient 丢失非 401 错误状态码，已修复，保证 404 缺失用例与认证/网络错误分开处理。模拟器与真机构建通过；本轮未通过 UI 自动化验证点击流程（电脑控制工具无法访问 Simulator），也未执行真实业务用例。

## 本次修复

- 图像：修复 NCC/SSIM 积分图平方和取错字段；细化多个粗匹配候选；释放每次匹配及步骤产生的原生图像；修复内嵌模板父目录创建。
- 通知：新客户端始终关闭 WDA 自身通知。完成后 WDA 激活 AutoDroid，App 刷新结果并发送自己的本地通知、切到报告页，按 run_id 持久去重。锁屏无法激活时下次打开补发，不提供未配置的 APNs 后台推送。
- 文件夹：用例、场景、定时目标选择接入对应平台目录树，保留嵌套和空目录；列表请求携带 folder_id，搜索和分页保留筛选。
- 图标：复用 Android 前景图案，修复绘图上下文导致输出全黑的问题，输出不透明 1024×1024 图标。
- 步骤：输入定位元素时清除旧值；启动验证实际前台 App；停止验证实际运行状态；图像点击、滑动、返回、回桌面检查原生返回值，失败不再报 PASS。自检不再在 iOS 设置根页面执行没有目的地的返回动作。

## 回归结果与范围

| 验证 | 结果 | 范围 |
| --- | --- | --- |
| Python 导出/运行时/回传 | 57 项通过 | 真实平台生成器、运行时及 iOS 适配层；设备原语使用测试替身 |
| Swift 客户端 | 19 项通过 | URL、登录、脚本校验、文件夹层级/筛选/分页、报告、定时、旧数据迁移 |
| Objective-C 原生 | 6 项通过 | 小图/手机分辨率精确定位、不匹配拒绝、SSIM、超大模板、模板缓存读写 |
| 模拟器原生图像 | 通过 | 实际截图裁切模板 → assert_image → click_image → assert_text 确认进入设置页；无图像/点击替身 |
| 模拟器原生输入 | 通过 | 同一输入框连续输入两次，确认第二次替换旧内容；无输入替身 |
| 模拟器自检 | 通过 | 启动设置、等待、截图 OCR、滑动、回桌面；5 步均 PASS |
| 模拟器通知与目录 UI | 通过 | 使用本地测试平台；通知授权归属 AutoDroid，实际执行后返回报告页；系统记录本 App 提交通知无错误，持续刷新没有重复提交；目录显示嵌套与空目录 |

13 种平台步骤均覆盖脚本执行链：click、input、wait_until_exists、assert_text、assert_image、click_image、extract_by_ocr、sleep、swipe、back、home、start_app、stop_app。除 sleep 外，全部增加原语失败/无结果分支验证，并确认失败报告仍上传。sleep 的等待参数由测试替身记录。另验证错误前台应用不能算启动成功。

上述覆盖不等于每个业务用例在真机通过。iOS 的 back 通过边缘右滑/常见返回按钮实现，并检查页面变化；没有上级页面时应失败。定位仍以平台预检支持的类型为准，不能把 Android 控件标识直接当作 iOS 标识。

## 真机剩余验证

设备安装列表已确认 `com.liuzhenyu.autodroid.ios` 为 0.2.1 (3)，WDA 也已安装。Xcode 启动提示 `Unlock 华为14 Pro to Continue`，设备状态 `passcodeRequired: true`。需要解锁后才能完成本轮海尔商城真机点击、系统通知和桌面图标显示验证。未向真实飞书机器人发送测试消息。

## 重跑

```sh
# AutoDroid 目录
.venv/bin/python -m pytest backend/tests/test_ios_runtime_harness.py backend/tests/test_autojs_export.py -q
.venv/bin/python -m backend.autojs_export.selftest --url http://设备地址:8100

# AutoDroid-iOS 目录
swift test

# AutoDroid-WDA 目录（替换模拟器标识）
xcodebuild -project WebDriverAgent.xcodeproj -scheme WebDriverAgentLib \
  -destination 'platform=iOS Simulator,id=模拟器标识' \
  -only-testing:UnitTests/ADTImageToolsTests test
```
