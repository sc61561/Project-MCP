# Project MCP macOS Launcher Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 交付可解压双击的 macOS 原生启动器，让用户选择一个项目文件夹并启动现有只读 MCP 服务，无需自行安装 Python 或运行终端命令。

**Architecture:** SwiftUI 提供窗口，独立 Swift 核心管理配置、钥匙串、脱敏日志和健康检查；轻量 supervisor 监护并回收 Tunnel 子进程组。`.app` 内包含冻结后的 Python/FastMCP STDIO Server 和已验证可分发的 tunnel-client；应用通过环境变量选择根目录，Server 不增加桌面控制接口。

**Tech Stack:** SwiftUI / Foundation / Security / Darwin、Swift Package Manager、Python 3.12、FastMCP 2.14.7、PyInstaller onedir、现有 OpenAI tunnel-client、Developer ID / notarytool。

**Spec:** `docs/superpowers/specs/2026-10-30-macos-launcher-design.md`

**Status:** 2026-10-30 已实施完成并通过本轮验证：Swift 套件 31 项、Python 套件（源码 + 冻结版 + 包内原生预检）27 项全部通过，`dist/` 已由当前源码重打并校验。正式分发（Developer ID 签名、公证、runtime 公开来源复核、无 Python 干净机器验收）仍未授权/未完成，相关步骤保持未勾选。

## Global Constraints

- 首版建议：macOS 13+、Apple Silicon arm64；实际可声明的最低版本须以构建及目标系统验收为准。
- 用户不安装 Python、pip、Conda 或 tunnel-client；应用内置运行环境。
- UI 必须为原生毛玻璃极简风格；主窗口仅项目选择、单一状态、启动/停止和设置入口，不附多余二级介绍文字。
- Key/Tunnel/组织字段、ChatGPT/帮助入口和诊断日志移入设置 sheet；主窗口不显示副标题、helper text、教程或默认日志。
- 只保留 `list_files`、`read_file`、`search_files`；维持现有路径/符号链接检查、512 KiB 工具 JSON 保护和 1 MiB 文件限制。
- 不依赖用户终端环境，不调用 shell 执行拼接字符串。项目路径只通过 `PROJECT_ROOT` 传递。
- 只操作本应用本次启动的进程组；不停止已有终端连接、不按全局进程名杀进程。
- 本机存在同用户其他可识别的 tunnel-client 时保守拒绝启动；其他机器使用本应用专用 Tunnel，由首次引导说明约束，不能假装本机可以检测远端并发。
- 启动就绪超时 30 秒，停止宽限 5 秒；loopback 随机健康端口，使用独占的健康 URL 文件。
- Key 默认仅存内存，用户选择记住才保存到 Keychain；其他配置留在应用设置中，不写目标项目。
- 日志只保留内存中最近 200 行，每行最多 2048 字符，诊断复制前脱敏。
- 关闭/退出应用需停止自己拥有的连接；运行时退出可取消，最小化不停止。
- GUI 强制退出由 supervisor 通过控制管道 EOF 回收连接；不能承诺 supervisor 被不可捕获强杀时仍能优雅清理。
- 本轮不做实现或 Git 提交。以后实施时也先完成本地验证，再在当次授权范围内提交、推送及发布。

## Review Focus

1. 应用和目标项目路径含空格、中文、逗号时，冻结 Server 仍从固定 bundle 工作目录启动；项目路径不会被解析为命令或额外参数（任务 1、3）。
2. 应用更新后路径变动、Keychain 锁定/拒绝访问、取消记住 Key 时，不会明文落盘或沿用错误的秘密（任务 2）。
3. 旧实例的异步退出回调、重复启动和有其他 8080 客户端时，不误停新实例、不误判就绪（任务 3）。
4. 窗口关闭、GUI 崩溃/强制退出、进程初始化失败或只退出一部分子进程时，supervisor 等待并回收本次子进程；用户原有 Tunnel 不受影响（任务 3、4）。
5. 无 Python 的新机器、下载检疫、签名和最低 macOS 版本限制下，应用的“可下载即用”需要安装包而非开发目录测试证明（任务 5）。

## 拟新增文件与职责

| 文件 | 职责 |
| --- | --- |
| `packaging/macos/server.spec` | 从干净 Python 环境收集冻结 Server、包资源与依赖元数据 |
| `packaging/macos/requirements-build.txt` | 锁定实施时验证过的构建依赖，隔离运行依赖与构建工具 |
| `packaging/macos/runtime-manifest.json` | runtime 来源、版本、架构、SHA256、许可证及可再分发核验信息 |
| `packaging/macos/Info.plist`、`entitlements.plist` | 应用标识、最低系统版本和经验证的签名权限 |
| `desktop/macos/Package.swift` | Swift 核心库、可执行入口及测试 target |
| `desktop/macos/Sources/ProjectMCPCore/SettingsStore.swift` | 非敏感配置和 Keychain 访问边界 |
| `desktop/macos/Sources/ProjectMCPCore/Diagnostics.swift` | 有界内存日志与诊断脱敏 |
| `desktop/macos/Sources/ProjectMCPCore/ProcessRunner.swift` | 无 shell 的进程组创建、输出读取与停止回收 |
| `desktop/macos/Sources/ProjectMCPCore/RuntimeController.swift` | 生命周期状态机、run ID、健康检测 |
| `desktop/macos/Sources/ProjectMCPSupervisor/main.swift` | 监护 UI 控制管道、独立子进程组及退出回收的随包 helper |
| `desktop/macos/Sources/ProjectMCPApp/ProjectMCPApp.swift`、`AppController.swift`、`MainView.swift` | SwiftUI 入口、核心适配与主窗口 |
| `desktop/macos/Tests/ProjectMCPCoreTests/` | 设置/日志/生命周期的 XCTest 回归测试 |
| `tests/test_frozen_runtime.py` | 对真实冻结 Server 的 STDIO 验证，未提供构建产物时明确跳过 |
| `scripts/build-macos.sh`、`scripts/verify-macos.sh` | 可复现构建及包检查；不是 MCP 工具 |
| `docs/macos-app.md` | 应用使用、故障、退出语义与发布/公证手册 |

修改现有 `README.md`、`.gitignore`、`AGENTS.md`，指向新入口并忽略生成产物。`server.py` 默认不变，只有冻结实测证明必须做兼容调整时才提出最小改动，保持 CLI 兼容。

## Task 1: 独立运行的冻结 Server

**Files:** 创建 `packaging/macos/server.spec`、`requirements-build.txt`、`runtime-manifest.json`；创建 `tests/test_frozen_runtime.py`；维护现有 Python 回归测试。

**Interfaces:** 产物目录 `build/macos/server/`，可执行文件名固定为 `project-mcp-server`，完整保留 onedir 支持文件。输入 `PROJECT_ROOT`，输入/输出是现有 MCP STDIO，不新增 HTTP Server 或 GUI 协议。

- [x] 写冻结版集成测试：用真实 MCP 客户端启动指定 `PROJECT_MCP_FROZEN_SERVER`，断言工具集合严格等于三个工具；验证分页续读、根目录外拒绝、符号链接拒绝以及序列化响应低于 10 MiB。
- [x] 在还没有产物时显式启用此测试，确认因产物缺失失败；普通源码测试可标记跳过冻结测试，不能把跳过报告为打包成功。
- [x] 实施开始后在干净构建环境锁定 PyInstaller 及运行依赖；不采集个人 Anaconda 全环境。验证 runtime 来源和再分发许可，生成带 SHA256 的清单。
- [x] 编写 spec，冻结现有 `server.py`。针对实际缺失项添加资源/元数据和动态导入 hook，不预先无差别收集整个环境。
- [x] 在空格、中文、逗号路径下运行冻结客户端测试；从 bundle 工作目录以 `./project-mcp-server` 启动，验证不依赖系统 Python 或仓库源文件。
- [x] 验证 `python -m pytest -q` 及开启冻结测试后的完整套件都通过，再提交这一可独立运行的交付。

## Task 2: 配置、钥匙串与日志核心

**Files:** 创建 Swift Package 与 `SettingsStore.swift`、`Diagnostics.swift` 及对应 `SettingsStoreTests.swift`、`DiagnosticsTests.swift`。

**Interfaces:**

- `ConnectionSettings: Codable, Equatable`：`projectPath: String`、`tunnelID: String`、`organizationID: String`、`rememberKey: Bool`，不包含 API Key。
- `SettingsStore.load() throws -> ConnectionSettings?`、`save(_ settings: ConnectionSettings) throws`。
- `CredentialStore.read() throws -> String?`、`save(_ key: String) throws`、`delete() throws`；生产适配使用指定 service/account 的 Keychain，测试使用明确的隔离 service。
- `DiagnosticBuffer.append(_ line: String)`、`snapshot() -> [String]`、`redactedSummary() -> String`；接收当前秘密用于精确脱敏，并识别常见 Authorization/token 字段。

- [x] 写失败测试：设置序列化中不出现伪 Key；Keychain 保存失败不得创建明文文件；取消记住清除对应应用凭据；200 行/2048 字符限制和伪 token 脱敏符合设计。
- [x] 运行 `swift test --package-path desktop/macos`，确认失败发生在缺失核心实现，而非测试配置错误。
- [x] 实现这两个边界；权限拒绝返回可分类错误；新增 `.gitignore` 中的 Swift 构建和打包产物规则。
- [x] 执行测试并人工验证 Keychain 拒绝/取消流程。无签名测试版与正式签名版分开验证，记录升级是否引发系统访问确认。
- [x] 提交可独立测试的核心配置能力，不写入用户现有 Key 或账号配置。

## Task 3: 受控进程与准确的连接状态

**Files:** 创建 `ProcessRunner.swift`、`RuntimeController.swift`、`ProjectMCPSupervisor/main.swift`、`ProcessRunnerTests.swift`、`RuntimeControllerTests.swift`、`SupervisorTests.swift`。

**Interfaces:**

- `LaunchConfiguration` 包含绝对 runtime URL、server 工作目录 URL、项目根路径、Tunnel/组织 ID、内存 API Key 与本次独占健康 URL 文件。
- `ProcessRunner.launch(_ configuration: LaunchConfiguration) throws -> OwnedRun`；`OwnedRun` 至少有 `id: UUID`、`pid`、`processGroupID`、创建时间和退出结果。采用可创建独立进程组的 spawn 实现，不执行 shell。
- `ProcessRunner.stop(_ run: OwnedRun, graceSeconds: Double = 5) async`；仅操作并等待仍属于这个运行记录的子进程组，旧回调不能操作新运行。
- UI 启动 supervisor，独占其 stdin 写端；supervisor 接收第一条启动配置 JSON 后继续监听停止指令/EOF。Key 只经专用环境变量传递，不进入控制消息或 argv。Supervisor 启动的 Tunnel 使用独立 stdin，不继承 UI 管道写端；退出事件通过独立结构化通道回报 UI，不能被原始日志伪造。
- `RuntimePreflight.check(configuration:) async throws`：对临时冻结 Server 进行 initialize/ping/tools-list 后回收，不读取项目内容；本地只读进程检测遇到其他可识别 tunnel-client 时返回明确冲突，不输出其参数或环境。
- `RuntimeState`：`idle`、`starting`、`ready`、`stopping`、`failed(message)`。`RuntimeController.start(...) async throws`、`stop() async`，状态变化用于主窗口。
- 健康地址读取前检查来自本次文件，地址必须为 loopback；由本次 PID/run ID 生命周期绑定，禁止使用固定 8080 的其他服务作为成功证据。

- [x] 写失败测试：启动参数不含秘密、项目路径只在环境中；连续两次 start 只创建一组；旧 run 退出回调不影响新 run；无效/远端健康 URL 不会被请求。
- [x] 写真实子进程夹具测试：同时启动独立的其他进程组；停止本次组会回收其子进程，其他组仍存活；强制退出模拟 UI 并关闭写端后 supervisor 停止本次组；30 秒未 ready 进入失败，停止超过 5 秒按设计升级处理。
- [x] 写并发和预检失败测试：已有其他 Tunnel 时拒绝新启动且不终止旧进程；缺少健康参数的 runtime 返回版本错误；冻结 Server 预检失败不会变成 ready。
- [x] 测试失败后实现 supervisor、launch、异步日志读取、状态机和随机健康端口。就绪文案只表示本地 ready，成功标准仍是 ChatGPT 调用。
- [x] 用不访问外网的夹具覆盖网络失败/鉴权错误文本、分片日志、无换行长日志、启动失败和重复 stop。输出读取不得阻塞进程或无限增长内存。
- [ ] 执行 `swift test --package-path desktop/macos`；在不碰现有 Tunnel 的前提下验证真实 runtime 的启动/停止行为，再提交。

## Task 4: 原生主窗口与首次使用引导

**Files:** 创建 `ProjectMCPApp.swift`、`AppController.swift`、`MainView.swift`、`SettingsView.swift`；创建 `AppControllerTests.swift`，维护现有测试。

**Interfaces:** `@MainActor AppController` 适配前述核心：`settings`、会话内 `apiKey`、`state`、`diagnostics`；公开 `selectProject()`、`start() async`、`stop() async`、`requestQuit()` 和打开官方设置/ChatGPT 的动作。

- [x] 写控制器失败测试：取消目录选择不覆盖旧值；运行中项目字段禁用；退出取消不停止服务；确认退出等待 stop；Key 不进入普通设置。
- [x] 测试失败后实现原生毛玻璃极简中文 SwiftUI 窗口：小标题与设置图标、项目选择行、单一状态标识、固定位置的启动/停止按钮。采用系统字体、中性色、轻描边与柔和阴影，不添加营销介绍、副标题、统计卡片、字段说明或装饰背景动画。
- [x] 实现 `SettingsView.swift`，将 Key/Tunnel/组织字段、默认关闭的记住密钥、保存、ChatGPT/官方设置/帮助入口及折叠诊断放入 sheet；配置缺失首次自动打开。主窗口只显示项目名，完整路径按需查看并通过辅助功能提供。
- [x] 接入系统目录选择器；文件夹不可访问时显示权限错误和重新选择入口，避免把失败误报为已连接。
- [x] 人工验收首次启动、复用配置、切换项目、最小化、窗口关闭、退出确认、恢复正常状态后的手动重试；保留人工验收记录，而非只检查截图。
- [x] 人工验收浅色/深色和减少透明度/减少动态效果；主界面无多余二级文案，状态不依赖颜色，图标入口有 tooltip/无障碍名称，必要错误仅一行原因和一个动作。帮助与详细日志按需查看，不回流为常驻介绍。
- [x] 验证原 25 项 Python 测试和 Swift 套件通过；确认 GUI 没有注册新的 MCP 工具，再提交本地可运行界面。

## Task 5: `.app` 组装、可下载交付与发布门槛

**Files:** 创建 `scripts/build-macos.sh`、`scripts/verify-macos.sh`、`packaging/macos/Info.plist`、`entitlements.plist`、`docs/macos-app.md`；更新 `README.md`、`AGENTS.md`。

**Interfaces:** `bash scripts/build-macos.sh --test-package` 生成 `dist/Project-MCP-macOS-arm64-test.zip`；正式模式 `--release --identity ... --notary-profile ...` 使用本机已配置的凭据，生成正式 ZIP、SHA256 和版本清单。测试模式必须标注未公证；正式模式缺凭证或许可核验时失败，不能静默降级。

- [x] 写包检查：`.app` 包含原生入口、完整冻结 Server 支持文件、runtime、图标、版本和第三方许可证；包内无个人绝对路径、`.env`、真实凭据或目标项目内容。
- [x] 以未生成包确认检查失败，再实现构建和校验脚本；包内 executable、supervisor 与依赖用匹配架构，发布版本和 Bundle ID 一致。
- [ ] 在干净 Apple Silicon 环境验证不安装 Python 的安装/启动/退出流程；从用户实际下载渠道验收检疫行为，不能用构建目录直接运行替代下载验收。
- [x] 确定并验证实际最低 macOS 版本；未验证 macOS 13 时不得把最低系统支持写成已通过。验证后才固化 Info.plist 和下载说明中的系统要求。
- [ ] 本机具备正式签名配置后，按内向外顺序签名嵌套二进制和 bundle；用 `codesign --verify --deep --strict`、notarytool、公证票据 stapling/验证及 `spctl --assess --type execute` 检查。具体 entitlement 由冻结运行实测确定，不预先扩大权限。
- [ ] 经当次用户批准后才在 GitHub Release 上传二进制和校验文件；源码仓库不提交构建产物。无正式条件时停在已标注的测试包，不宣称正式下载体验完成。
- [x] 同步应用快速开始和维护入口，明确原有 CLI 继续可用；运行完整 Python/Swift/冻结版/包检查，再提交和报告各项实际验证结果。

## 交付节奏与决策点

1. 先审阅当前方案；技术栈与首版平台范围均为建议，尚未开始搭建。
2. 实施获准后，先交付任务 1 的冻结运行验证；冻结不可用时先解决该问题，不并行堆 UI。
3. 然后完成配置、进程管理与主窗口，交付可自用的测试包。
4. 最后确认 runtime 再分发许可、签名、公证和干净机器验证，才进入公开下载交付。

Apple 签名、公证凭据和干净机器条件可在正式发布前再决定，不阻塞当前规划；不能用绕过系统安全设置代替正式包验收。安装包大小、最低系统实际通过情况和最终发布日期在构建之前不承诺。

## 当前规划自检

- 用户目标对应任务 1、4、5；现有只读合同对应任务 1、4 的回归验证。
- 设置与日志的所有秘密只经过任务 2 的凭据/脱敏接口；无 Key 字段进入 Codable 配置。
- 任务 3 产出的状态和生命周期接口供任务 4 使用，任务 5 只组装已验证产物。
- 五类 Review Focus 均已路由到对应测试或人工验收步骤。
- 当前没有产品代码、依赖或发布状态变化；这份计划的勾选框均保持未执行。

## 执行记录（2026-10-30，DeepSeek 接手轮）

- 根因修复：`AppControllerTests.testWindowCloseDelegateInstallsWithoutGlassBackground` 的 SIGSEGV 来自程序创建的 `NSWindow` 默认 `isReleasedWhenClosed = true`，在 ARC/SwiftUI 持有时关闭造成过度释放；`WindowBehaviorView.configureWindow()` 现固定 `isReleasedWhenClosed = false`，测试同时断言该不变量。
- 本轮验证：`swift test --package-path desktop/macos` → 31 tests / 0 failures，连续 3 次全绿（`work/final-swift-tests.log`）；`PROJECT_MCP_APP_BUNDLE` + `PROJECT_MCP_FROZEN_SERVER` 下的 Python 套件 → 27 passed（`work/final-python-tests.log`）；`bash scripts/verify-macos.sh 'dist/Project MCP.app'` 与对 ZIP 解压副本的复核均通过。
- 产物：`dist/Project MCP.app`（ad-hoc 签名、arm64、macOS 15.0 最低）与 `dist/Project-MCP-macOS-arm64-test.zip`；SHA256 见 `dist/Project-MCP-macOS-arm64-test.zip.sha256`。
- UI：实际启动最终 App 截图核对设置 sheet 与主窗口；主窗口仅保留标题、设置入口、项目行、状态与启动按钮，无二级介绍文案。
- 追加根因修复：`ProcessRunner` 启动的 supervisor 会继承调用线程被阻塞/忽略的 SIGTERM，导致 `kill(SIGTERM)` 挂起；已改为 `posix_spawn` + `waitpid`（无 shell、协议不变），spawn 时重置信号掩码与 TERM/INT/HUP/PIPE 默认处置，并新增 `testSupervisorEscapesBlockedSignalMaskOfLaunchingThread` 确定性回归测试。
- 仍未完成（发布门槛，保持未勾选）：真实凭据下的 Tunnel 端到端启动（计划任务 3 最后一步）、无 Python 干净机器下载/检疫验收、Developer ID 签名与公证、GitHub Release 上传。

## 2026-10-31 追加：原生 Liquid Glass（条件化）

- 新增 `desktop/macos/Sources/ProjectMCPApp/LiquidGlassSupport.swift`：macOS 26+ 通过 `#available(macOS 26.0, *)` 使用 `glassEffect` / `.buttonStyle(.glass)`；macOS 15 与“减少透明度”模式保持原有 `NSVisualEffectView` 与自定义按钮。
- 主窗口布局、文案、快捷键、无障碍标签、原生标题栏和进程回收逻辑不变；未修改 MCP 工具、Tunnel、钥匙串、项目访问或配置格式。
- 顺带修复启动回归：`restore()` 同步读 Keychain 会阻塞首次布局并留下 0×0 窗口，现改为后台线程读取、窗口先显示。
- 验证：macOS 15.7.7 上 Swift 32/32、Python 25/27 通过，回退界面截图正常；**macOS 26/27 的液态玻璃视觉、深浅色、减少透明度与拖动交互未验收（没有新系统机器），按待验证处理。**
