# Project MCP for macOS

## 测试包

本版为 Apple Silicon（M 系列）Mac 的本地测试包，系统要求 macOS 15.0 或更高；已在 macOS 15.7.7（回退界面）与 macOS 27.2（原生 Liquid Glass）实机验证。本版加入 macOS 26 原生 Liquid Glass 条件化支持，并继续提供 macOS 15 的毛玻璃界面。已修复窗口关闭时的 AppKit 释放回归，以及 supervisor 继承阻塞信号导致的停止死锁；一体式窗口拖动已在 macOS 27.2 由用户验证。未完成 Apple Developer ID 公证，也未做无 Python 新机器的独立验收，不等同于正式公开发行版。

解压 `Project-MCP-macOS-arm64-v版本号.zip`，把 `Project MCP.app` 放入应用程序目录后打开。应用内置 Python、FastMCP 和 Tunnel，无需自行安装运行环境。测试包为本地 ad-hoc 签名、未公证，首次打开若出现系统拦截，请用右键“打开”，不要全局关闭 Gatekeeper；下载校验值见同目录 `.sha256` 文件。

## 外观与系统版本

- macOS 26 及以上：项目选择、启动/停止和设置入口使用系统原生 Liquid Glass 材质与按钮样式；窗口内容区不叠加额外玻璃层，状态文字保持清晰。系统开启“减少透明度”时自动回到可读的不透明背景，不启用玻璃控件。
- macOS 15：保持原有的 `NSVisualEffectView` 毛玻璃背景和自定义按钮样式，布局、文案、快捷键和无障碍标签不变。
- 两种系统都使用一体式窗口、原生窗口按钮与关闭确认，不改变进程回收逻辑。

2026-10-31 已在 macOS 27.2 实机验收：项目选择、启动/停止与设置入口均显示系统原生玻璃材质，设置 sheet 为玻璃材质；深色和浅色模式下文字对比度正常。一体式窗口拖动经用户实际操作验证；系统“减少透明度”仍需人工复核。macOS 15 回退界面已在本机构建并截图核对。

## 使用

本分支的新版本在设置中默认展开“快速开始”，提供三步指引、相关入口和循环播放的 API Key、插件操作视频。API Key 视频已截去生成后的密钥画面；有效期和权限请按需设置。GitHub 上已发布的 0.2.1 尚不包含此指引，且设置中必须填写组织 ID；以下说明针对本分支的新版本。

主界面的 GitHub 图标可打开项目仓库；齿轮图标打开设置。

1. **获取连接信息：**在 [OpenAI API Keys](https://platform.openai.com/api-keys) 获取 API Key，在 [Tunnel 设置](https://platform.openai.com/settings/organization/tunnels)创建 Tunnel，并关联要使用的 ChatGPT 工作区；复制 Tunnel ID。
2. **配置并启动：**在 App 设置中填写 API Key 和 Tunnel ID，选择目标项目文件夹，点击“启动”，等待“本地就绪”。组织 ID 可在高级设置中选填；已有保存值会继续使用。“记住密钥”使用系统钥匙串；不选时仅用于当前会话。
3. **添加 ChatGPT 插件：**打开 [ChatGPT 插件](https://chatgpt.com/plugins)，选择“＋”→“添加自定义 MCP 服务器”，在连接方式中选择 Tunnel、选择相同隧道，身份验证选择“无身份验证”，确认风险提示后创建并安装。在对话中输入 `@` 选择插件，请它列出项目目录，验证端到端连接。

应用设置中提供官方入口；隧道客户端自身仍使用 API Key 认证。操作流程以 [OpenAI 官方指南](https://developers.openai.com/api/docs/guides/secure-mcp-tunnels#connect-from-chatgpt)为准。

同一隧道不要同时用于多个客户端/项目。检测到本机已有其他同用户 Tunnel 客户端时，应用会拒绝启动，保留现有连接；请自行在原终端停止旧客户端。应用不会读取旧客户端环境变量或自动结束它。

切换项目先停止连接。默认关闭窗口会最小化，连接继续运行；可在设置中关闭该选项，恢复关闭窗口时的连接确认。退出应用会提示并停止本应用的连接。GUI 被强制退出时，监护进程会回收它创建的 Tunnel/Server；监护进程本身被不可捕获强杀不在优雅退出保证范围内。

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

构建产物位于 `dist/Project MCP.app` 和 `dist/Project-MCP-macOS-arm64-v版本号.zip`；生成的运行环境、缓存和二进制不提交 Git。重复构建仅替换本脚本生成且 Bundle ID 匹配的 App，将上一份保留在此次构建的 stage 目录。

## 正式分发前仍需完成

- 对 runtime 来源和第三方许可证完成公开分发核验。
- 配置本机 Developer ID，按嵌套顺序签名，完成 notarytool 公证、stapling 与 Gatekeeper 验证。
- 在没有 Python/Conda 的新机器从实际下载渠道验收，包括系统检疫、配置、启动、读取和退出回收。
- 如需支持低于 macOS 15 的版本或 Intel，分别构建和验收后再声明支持。

当前构建脚本只提供测试包模式，正式发布模式会明确失败，不会静默交付未公证包。现有终端运行方式继续受支持，不因 GUI 开发停止旧进程。
