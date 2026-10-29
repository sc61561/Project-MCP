# DeepSeek 接手任务：完成 Project MCP macOS 软件

更新时间：2026-10-30。本文件是当前交接的权威入口；其他断点记录和旧测试日志用于追溯，不能覆盖这里的未完成状态。

## 最终目标：不得改变

完成一个 **Apple Silicon / macOS 15+ 可解压双击的原生 `.app` 测试包**：用户不安装 Python、pip、Conda 或 Tunnel 程序，在窗口中选择一个本地项目，配置一次连接信息，点击启动后可由 ChatGPT 的既有 MCP 连接读取该项目。

UI 已由用户明确指定：**毛玻璃、极简、只保留核心内容，不能加多余的二级文字介绍**。

- 主窗口：`Project MCP` 小标题、设置图标、项目选择行、一个状态标识、一个启动/停止按钮。
- 连接字段、密钥记忆开关、ChatGPT/官方入口、帮助和折叠日志都在设置 sheet 内。
- 不加副标题、功能介绍、helper text、统计卡片、侧边栏、欢迎页、装饰渐变或炫光动画。
- 浅色/深色、减少透明度模式均可读；窗口退出处理不能依赖视觉材质。

**在当前代码上续做，不重写，不换 Electron/Tauri/网页管理后台，不退回只提供脚本或教程。** 保留现有 SwiftUI + Swift supervisor + 冻结 Python/FastMCP 的方案。不要因文档标题仍写“规划”就等待重批：用户已明确说“开始实现”，现在指定由 DeepSeek 完成。

## 必须保留的边界

- MCP 仍且仅有 `list_files`、`read_file`、`search_files` 三个只读工具；不增加写入、删除、移动、Shell 或桌面控制 MCP 工具。
- 维持 `PROJECT_ROOT`、根目录边界、符号链接拒绝、分页、512 KiB 工具 JSON 保护、1 MiB 文本文件上限。
- GUI 可以保存自己的设置和管理自己拥有的进程，但不能读用户真实 Key、旧进程环境或 Shell 历史来自动填配置。
- Key 默认会话内存，用户明确勾选才进 Keychain；不写明文 `.env`，不进入配置 Codable/argv/控制 JSON/日志。
- 不停止现有终端 Tunnel，不删除旧目录；禁止全局 `pkill python/tunnel-client` 等操作。
- 本轮没有远端推送、公证、GitHub Release 发布授权。允许本地继续开发、构建、测试；正式发布需另行完成条件和授权。

## 必须在同一个本地工作目录接手

仓库：`/Users/chen/Documents/ChatGPT/MCP server`。
当前分支：`feat/macos-launcher`；基线：`ea30549`。用户要求将当前进度保存为本地 WIP 断点提交，具体提交号以 `git log -1` 为准；这不是测试全部通过的发布提交。

**新实现仅在本地功能分支保存，尚未推送；GitHub 的 main 只有之前的 CLI Server。不要只 clone 远端后误以为没有实现；必须先打开这个本地目录。不要 reset/clean/覆盖当前工作树。**

先读：

1. `AGENTS.md`。
2. `docs/superpowers/specs/2026-10-30-macos-launcher-design.md`。
3. `docs/superpowers/plans/2026-10-30-macos-launcher.md`。
4. 本文“当前阻塞”和 `work/macos-launcher-progress.md`。

## 已有实现，不要重复搭建

- `desktop/macos/Package.swift`：Swift 核心、UI、supervisor 和测试 target。
- `Sources/ProjectMCPCore/`：设置、Keychain、脱敏日志、启动配置、进程管理、健康检查、生命周期状态机及新增 `LauncherLock.swift`。
- `Sources/ProjectMCPSupervisor/main.swift`：无 shell 的子进程组启动；控制管道 EOF / 终止信号触发回收；仅操作本组。上述 Sources/ 路径均相对于 `desktop/macos/`。
- `Sources/ProjectMCPApp/`：毛玻璃主窗口、设置 sheet、AppController、正常退出确认；已经实际打开检查。
- `packaging/macos/server.spec`：已实际生成约 60 MiB 的冻结 Server，修复了 docket Lua 和 burner_redis 动态导入。
- `packaging/macos/requirements-lock.txt`：干净构建环境的依赖锁；Python 3.12.2、FastMCP 2.14.7、PyInstaller 6.22.3。
- `scripts/build-macos.sh`、`verify-macos.sh`、`package-licenses.py`：打包、本地 ad-hoc 签名、架构/资源/私钥检查和许可收集。
- `docs/macos-app.md`：软件使用与构建说明；README 与 AGENTS 已加桌面入口。
- `pytest.ini` 限定项目测试目录，避免收集忽略目录 work/ 内第三方测试。

## 已有验证与现有安装包的真实含义

- 原有 Python 25 项 + 真实冻结 Server MCP 协议测试：26 项通过，`work/python-tests.log`。
- 包内冻结 Server + 实际 Swift supervisor 的无凭据预检：2 项通过，`work/app-protocol-tests.log`。
- 实际 UI 验证：设置 sheet、极简主界面、系统目录选择器及取消操作可用；没有填真实凭据或启动真实连接。
- 已有 `dist/Project MCP.app` 和约 40 MiB `dist/Project-MCP-macOS-arm64-test.zip`，以及 `.sha256`，曾通过 ad-hoc 签名与包结构检查。
- **这些产物早于最后几次源码修复，不能作为当前最终版本交付，必须重打。**
- 最新源码 release 编译成功的记录：`/tmp/project-mcp-swift-release-final.log`。这不代表测试套件通过。

## 当前阻塞：先解决它们，再交付

### 1. 最新完整 Swift 套件在原生窗口回归测试处 SIGSEGV

最新日志：`/tmp/project-mcp-swift-final-tests.log`。明确结果是 `Exited with unexpected signal code 11`，进入 `AppControllerTests.testWindowCloseDelegateInstallsWithoutGlassBackground` 时中断。

此前五项 UI 控制器测试（含草稿保存失败）在该次运行中已通过；但进程崩溃，后续核心测试未完成，**不能写成“全部通过”**。先定位测试里的 NSWindow 创建/关闭/ARC 生命周期和真实关闭委托行为；例如检查 `isReleasedWhenClosed` 与测试持有方式，但这只是排查线索，不是已确认根因。不能仅删除该测试来通过门禁。

### 2. 审查提出三项 Important，均有代码改动，但还没有统一的最终 GREEN

1. **跨进程互斥**：原先只有进程列表快照，两个 App 可同时启动同一 Tunnel。现在有 `LauncherLock.swift`（每用户稳定 lock inode，flock、O_NOFOLLOW/O_CLOEXEC、权限/owner 检查），RuntimeController 已接入 acquire/release。`LauncherLockTests.swift` 和 competing-controller 测试已添加；须重新验证锁竞争、失败/正常 stop 释放和进程退出释放，不能 unlink 仍作为共享锁的 inode。
2. **设置草稿事务**：原先 settings sheet 直绑已提交状态，项目选择可偷偷持久化未成功的记住密钥偏好。现在设置页有独立 draft/draftKey，`saveSettings(candidate:key:)` 在凭据操作成功后更新已提交状态；项目选择仅更新项目。新增测试在最近完整运行中通过，仍需整体回归。
3. **减少透明度下关闭确认**：原先委托仅由玻璃背景安装。现已拆出与材质无关的 `WindowBehaviorView`；新增测试就是当前 SIGSEGV 的位置，需确认测试本身与产品行为都正确。

### 3. 先前的健康超时不能直接当作仍然存在，也不能当作已彻底解决

`work/swift-tests.log` 是较早一轮，21 tests / 5 failures，RuntimeController ready 超时；另有较后 focused core 17 项通过的 `/tmp/project-mcp-core-green.log`，以及更后完整运行曾显示 readiness/stop/retry 用例通过。

旧日志、并行构建和源文件修复的时间不同，唯一正确做法是：修完窗口测试后，以当前源码重新完整跑一遍。不要从旧失败归因 ATS 后盲目关闭全局网络安全；也不要提高 30 秒超时掩盖问题。之前 SIGPIPE 和失败清理/并发 stop 也有新增回归用例，必须保留。

## 续做命令

先检查分支和未提交文件：

```bash
cd "/Users/chen/Documents/ChatGPT/MCP server"
git status --short --branch
```

调试并跑当前完整 Swift 套件：

```bash
swift test --package-path desktop/macos \
  --scratch-path work/swift-release --cache-path work/swift-cache
```

本机 sandbox 可能阻挡 Xcode 缓存、进程枚举或本地网络测试；需要时正常申请工具权限，不弱化测试。还有 `/tmp/project-mcp-swift-build` 这一套旧构建缓存和日志，不要将两套日志混为同一结果。

Swift 全部通过后重新打包并验证当前包：

```bash
bash scripts/build-macos.sh --test-package
PROJECT_MCP_APP_BUNDLE='dist/Project MCP.app' \
PROJECT_MCP_FROZEN_SERVER='dist/Project MCP.app/Contents/Resources/server/project-mcp-server' \
  work/build-env/bin/python -m pytest -q
bash scripts/verify-macos.sh 'dist/Project MCP.app'
```

完整 Python 测试预计为原 25 项 + 两项包验证；以实际输出为准。未设这两个环境变量时两项是 skip，不能称包验证通过。

## 接手时的进程与文件注意事项

- 本轮参与的实现/审查 Agent 均已停止；不应再有 Agent 继续改代码。
- 交接检查时旧终端 Tunnel PID 为 93217，必须保留，PID 可能变化，应以实际来源辨别，不能依据此旧 PID 直接执行任何信号操作。
- 自建测试 App 可能仍开着首次配置窗口；尚未配置密钥。测试进程 12018 已核对为本任务 XCTest 后发送 SIGTERM，避免遗留构建锁；接手重新检查实际状态，不按旧 PID 误杀。
- 未删临时库、旧安装包 stage 或旧源码；保留用于复核。
- 发布时不要提交 `work/`、`build/`、`dist/`、虚拟环境或二进制。本文含本机路径和临时 PID，适合本地交接，不应未经整理直接公开上传。

## 完成标准：全部满足才说测试版完成

- 当前源码的 Python、冻结协议、Swift 完整套件均有本轮成功输出；无未解释的失败、signal 11 或被掩盖 skip。
- 多开互斥、设置草稿、减少透明度下窗口关闭、退出取消/确认、GUI 进程退出后的 supervisor 回收均已验证，原终端连接不受影响。
- 最新源码重打 ZIP，与 App 对应；签名/包结构/arm64 检查通过，并给出 SHA256。
- 实际打开最终 App 检查极简 UI，错误仅保留必要一句和动作；不因为“帮助完整”把说明搬回主界面。
- 正常用户只需打开 App、填自己的连接信息、选目录、启动；端到端真实 ChatGPT 测试需用户自行输入 Key 和完成首次授权，不能从旧环境偷取凭据。
- 更新 README、软件说明、计划勾选状态和执行记录，清楚区分“已实现”“已测试”“待正式分发”。

## 正式发行尚未授权或验证

无 Developer ID / Apple 公证凭证，未完成无 Python 新机器下载/检疫验收；runtime 的原下载一致性已验证，但独立公开来源复核仍 pending，manifest 中 `public_distribution_approved=false` 必须保留到真实审核完成。

可以交付明确标注未公证的本地测试包；不能声称所有 Mac 默认安全设置下无提示即用。不要请求聊天中发送私钥、不要全局关闭 Gatekeeper，也不要未经用户指令推送共享分支或创建 GitHub Release。
