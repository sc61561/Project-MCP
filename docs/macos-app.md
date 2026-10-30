# Project MCP for macOS

## 测试包

本版为 Apple Silicon（M 系列）Mac 的本地测试包，系统要求 macOS 15.0 或更高；已验证的构建机器是 macOS 15.7.7。当前包由 2026-10-30 的源码重新打包：Swift 31 项、Python 27 项测试通过；已修复窗口关闭时的 AppKit 释放回归，以及 supervisor 继承阻塞信号导致的停止死锁。未完成 Apple Developer ID 公证，也未做无 Python 新机器的独立验收，不等同于正式公开发行版。

解压 `Project-MCP-macOS-arm64-test.zip`，把 `Project MCP.app` 放入应用程序目录后打开。应用内置 Python、FastMCP 和 Tunnel，无需自行安装运行环境。测试包为本地 ad-hoc 签名、未公证，首次打开若出现系统拦截，请用右键“打开”，不要全局关闭 Gatekeeper；下载校验值见同目录 `.sha256` 文件。

## 使用

1. 在设置中填写 API Key、Tunnel ID 和组织 ID。可选择“记住密钥”，凭据保存在系统钥匙串；不选时仅用于当前会话。
2. 点击项目行，选择目标文件夹。
3. 点击“启动”，等待“本地就绪”。
4. 在 ChatGPT 启用 Project MCP，读取项目 README 验证端到端连接。

首次接入仍需在 OpenAI 创建本应用专用的 Tunnel，并在 ChatGPT 添加自定义 MCP，选择对应 Tunnel 和“无身份验证”。应用设置中提供官方入口；隧道客户端自身仍使用 API Key 认证。

同一隧道不要同时用于多个客户端/项目。检测到本机已有其他同用户 Tunnel 客户端时，应用会拒绝启动，保留现有连接；请自行在原终端停止旧客户端。应用不会读取旧客户端环境变量或自动结束它。

切换项目先停止连接。最小化不影响连接，关闭窗口或退出应用会提示并停止本应用的连接。GUI 被强制退出时，监护进程会回收它创建的 Tunnel/Server；监护进程本身被不可捕获强杀不在优雅退出保证范围内。

“本地就绪”表示本地预检和健康检测通过，不保证 ChatGPT 已完成工作区授权。电脑仍需联网且保持唤醒。

## 配置和诊断

主界面保持原生毛玻璃极简布局。配置、按需帮助和脱敏诊断均在设置内，默认不展示日志。

配置保存在应用 UserDefaults，API Key 不进入配置文件。选中记住密钥时使用 Keychain service `com.sc61561.project-mcp`；若钥匙串拒绝访问，应用会报告失败，不降级为明文存储。诊断日志仅保留内存中最新 200 行，每行最多 2048 字符。

不访问项目目录之外的文件，不增加写入、删除或 Shell MCP 工具。应用自身的设置保存、进程管理与三个只读文件工具分开。文件工具合同、分页规则和 1 MiB 文件限制见根目录 README。

## 从源码构建

需要 Xcode/Command Line Tools、arm64 Python 3.12 和网络依赖下载。使用专用虚拟环境：

```bash
python3.12 -m venv work/build-env
work/build-env/bin/python -m pip install -r packaging/macos/requirements-lock.txt
```

将匹配 `packaging/macos/runtime-manifest.json` 校验值的 runtime 放在根目录 `tunnel-client`，或导出 `TUNNEL_CLIENT_PATH`。第三方许可证随包附带；本地原始 runtime 与下载版本的哈希一致，但公开再分发的来源核验尚未作为发布 gate 完成。

```bash
bash scripts/build-macos.sh --test-package
PROJECT_MCP_FROZEN_SERVER="dist/Project MCP.app/Contents/Resources/server/project-mcp-server" \
  work/build-env/bin/python -m pytest -q
swift test --package-path desktop/macos
bash scripts/verify-macos.sh "dist/Project MCP.app"
```

构建产物位于 `dist/Project MCP.app` 和 `dist/Project-MCP-macOS-arm64-test.zip`；生成的运行环境、缓存和二进制不提交 Git。重复构建仅替换本脚本生成且 Bundle ID 匹配的 App，将上一份保留在此次构建的 stage 目录。

## 正式分发前仍需完成

- 对 runtime 来源和第三方许可证完成公开分发核验。
- 配置本机 Developer ID，按嵌套顺序签名，完成 notarytool 公证、stapling 与 Gatekeeper 验证。
- 在没有 Python/Conda 的新机器从实际下载渠道验收，包括系统检疫、配置、启动、读取和退出回收。
- 如需支持低于 macOS 15 的版本或 Intel，分别构建和验收后再声明支持。

当前构建脚本只提供测试包模式，正式发布模式会明确失败，不会静默交付未公证包。现有终端运行方式继续受支持，不因 GUI 开发停止旧进程。
