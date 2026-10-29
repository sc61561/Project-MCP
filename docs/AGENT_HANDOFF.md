# Project MCP macOS — Agent 交接断点

> 已由 [DEEPSEEK_HANDOFF.md](DEEPSEEK_HANDOFF.md) 接替为现役交接入口。以下内容是较早开发快照，测试状态可能过期；继续工作以 DeepSeek 文档中的当前阻塞、目标和验收标准为准。

更新时间：2026-10-30。当前是开发中间态，不是最终验收或正式发布凭证。

## 用户目标与授权

- 将现有只读 MCP 封装为 Apple Silicon macOS 软件，双击打开、选择目录、一键启动。
- UI 必须原生毛玻璃、极简，无多余二级介绍；主界面只有标题/设置、项目选择、状态、启动/停止；配置与诊断进设置 sheet。
- 用户已说“开始实现”，允许本地开发、构建和测试；本轮未要求远端推送、GitHub Release 或 Apple 公证。
- 用户要求额度不足时留下本断点。维护本文件不代表用户要求停止开发。
- 不能停止现有终端 Tunnel、读取真实 Key、删除旧运行目录。测试只使用虚构凭据和自己拥有的进程。

## 工作位置与文档

- 仓库：`/Users/chen/Documents/ChatGPT/MCP server`。
- 分支：`feat/macos-launcher`，基线：`ea30549`（此前已推 main 的只读 Server）。用户随后要求保存本地 WIP 断点；当前以 `git log -1` 和 DEEPSEEK_HANDOFF.md 为准，未推远端。
- 设计：`docs/superpowers/specs/2026-10-30-macos-launcher-design.md`。
- 计划：`docs/superpowers/plans/2026-10-30-macos-launcher.md`。
- 执行记录：`work/macos-launcher-progress.md`。
- 使用与构建说明：`docs/macos-app.md`；协作边界：`AGENTS.md`。
- 设计/计划开头的“仅规划”是历史状态，用户后续已明确批准实施；交付前应同步文档状态。

## 已完成的代码和验证

1. 干净构建虚拟环境：`work/build-env`，Python 3.12.2；FastMCP 2.14.7、PyInstaller 6.22.3。依赖锁：`packaging/macos/requirements-lock.txt`。
2. 原 Python Server 源码未因桌面封装而增加工具或进程执行能力。`packaging/macos/server.spec` 输出 `build/macos/server/`，约 60 MiB。
3. 冻结曾实际失败：缺 docket Lua 数据、动态导入 burner_redis；已通过 spec 的 data/hook 收集修复。原 25 项 + 冻结协议测试共 26 项通过，证据 `work/python-tests.log`。
4. 新增包内原生 supervisor 对实际冻结 Server 的 initialize/ping/tools-list 预检测试；结合冻结客户端测试两项通过，证据 `work/app-protocol-tests.log`。不需要真实 Key 或外网。
5. 原生窗口、设置页、目录选择器已编译并实际打开检查；取消目录选择保持原状态。正常视图无副标题或额外说明文字。截图由 CUA 返回，无独立截图文件。
6. 本地测试 App 与约 40 MiB ZIP 已生成，并通过 ad-hoc codesign/bundle 结构检查：`dist/Project MCP.app`、`dist/Project-MCP-macOS-arm64-test.zip`、对应 `.sha256`。
7. 现有 ZIP 是较早构建，之后源码还有修复；最终交付前必须重新构建、重新验证，不能因为文件已存在就宣称最终通过。

## 当前最关键的未闭合项

### Swift 全套健康/状态测试仍有失败，正在修复

- `work/swift-tests.log` 最近一次完整运行：21 tests、5 failures，均为 RuntimeController 就绪/重试超时；其他配置、脱敏、supervisor 子进程组/EOF 清理测试通过。
- Core 实现者正在定位修复；不要增加超时预算或把失败删除。当前文件有并行更新，接手先看最新源码、报告和时间戳，再判断是否仍失败。
- 核心相关文件：`desktop/macos/Sources/ProjectMCPCore/{HealthEndpoint,RuntimeController,ProcessRunner,LaunchConfiguration}.swift` 和 `desktop/macos/Sources/ProjectMCPSupervisor/main.swift`。
- 夹具：`desktop/macos/Tests/ProjectMCPCoreTests/Fixtures/fixture.c`，会启动真实本地 HTTP 健康服务和独立子进程；不是简单 mock。
- 已向实现者提示检查 URLSession 健康请求的准确错误/URL 比较、ATS 或本地网络处理，但这些只是定位线索，不是确认结论。

### GUI/打包已知修复

- `AppController` 的 actor 默认参数改为可选 nil，在 MainActor 内初始化；RuntimeController.start 是 async 非 throwing，UI 不使用无效 try/catch。
- UI 保存曾允许缺组织 ID 还保存 Key；新增回归测试实际 RED 后已修正为完整配置先验证，再保存凭据。测试在 `desktop/macos/Tests/ProjectMCPAppTests/AppControllerTests.swift`；需确认最新完整运行全部 GREEN。
- 窗口新增透明 titlebar；尚需用最终构建复核。
- 包检查不能禁止所有 `.pem`，certifi/cacert.pem 是必需公共 CA；已改为禁止 `.env`、`.key` 和 PEM 私钥内容，`bash scripts/verify-macos.sh` 已通过。
- `pytest.ini` 限定 `testpaths=tests`，否则 pytest 会收集 `work/uv-cache` 内第三方测试；这不排除任何项目测试。

## 并行 Agent（仅当前会话内有意义）

- Hooke：`01a188e0-9e50-7062-93b0-41abdceccc75`，拥有 Swift Package/core/supervisor/CoreTests；要求不提交、不推送、不动 GUI/脚本/Python，修复当前健康测试后汇报。主 Agent 写 GUI 和 AppTests。
- Chandrasekhar：`01a188ec-a618-74f0-babf-9df19c9c10fb`，只读整体验证/审查；已告知健康失败正在修复，要求报告其他具体问题。未返回最终结论前不能宣称审查通过。
- 若这些 Agent 在新会话不可访问，以工作树、日志和测试为准，不依赖其 ID 才能恢复。

## 建议续做顺序与命令

1. `git status --short --branch`，读最新核心状态/审查结果，避免覆盖并行改动。
2. 修复并验证 Swift 套件（本机 Xcode 可能需要 sandbox escalation 才能访问缓存/测试进程）：

```bash
swift test --package-path desktop/macos \
  --scratch-path work/swift-release --cache-path work/swift-cache
```

3. 汇总并修复整体验证的 Critical/Important；每个实际缺陷先加 RED 测试再修复；不把正式公证缺失误认为测试版必须阻塞的代码 bug。
4. 重新生成最终测试包：

```bash
bash scripts/build-macos.sh --test-package
```

脚本构建 Swift release、冻结 Server、复制 runtime/许可、组装图标并本地签名。已有同 Bundle ID 的旧生成 App 会移动到本次 stage 保留，不删除用户文件。正式模式明确拒绝，未实现公证发布。

5. 针对包内产物跑完整 Python 测试：

```bash
PROJECT_MCP_APP_BUNDLE='dist/Project MCP.app' \
PROJECT_MCP_FROZEN_SERVER='dist/Project MCP.app/Contents/Resources/server/project-mcp-server' \
  work/build-env/bin/python -m pytest -q
bash scripts/verify-macos.sh 'dist/Project MCP.app'
```

6. 再检查实际窗口、设置、关闭语义；不要填真实 Key 或停止原终端。CUA 的 `getApp` 可能把已退出的软件再次打开；关闭后可用只读进程检查辨别实际结果。App 可能仍在显示空的首次设置窗口。
7. 同步 README/设计/计划的实际状态、更新本断点和执行记录；只提交源码/文档/测试。未获本轮远端发布授权，不推共享分支、不创建 Release。
8. 最终回复给出本地测试 ZIP 和 App 绝对路径、真实测试结果和未完成项，不称“正式发布完成”。

## 正式发布的明确边界

- 测试 bundle 要求 macOS 15+ / arm64；只在 15.7.7 上验证，不承诺旧系统/Intel。
- 未发现可用 Developer ID 签名身份，无公证凭证；不请求聊天中发送私钥，也不全局关闭 Gatekeeper。
- Runtime 当前本地二进制与原下载 v0.0.14 SHA256 一致，记录在 manifest；上游 LICENSE/NOTICE/依赖报告已附带，但公开再分发来源审查仍 pending，`public_distribution_approved=false`。
- 未做无 Python 的独立新机器下载/检疫验收；当前包只是测试版。
- API Key、真实 Tunnel/组织 ID 不在代码、文档和安装包内。不要为联调去读终端环境或旧 shell 历史。
