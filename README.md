# Project MCP

用 Python + FastMCP，让 ChatGPT 只读访问一个本地项目文件夹。通过 `PROJECT_ROOT` 选择目录，使用 STDIO 在本地运行，可通过 OpenAI Secure MCP Tunnel 连接 ChatGPT。

只提供三个工具：列目录、读文本、全文搜索。支持分页，无数据库、Embedding 或 Web UI。

## macOS 桌面启动器（测试版）

新增原生毛玻璃极简窗口：选择项目、查看状态、一键启动/停止；连接配置和诊断收进设置。应用内置 Python 和 Tunnel，使用方式及构建步骤见 [macOS 软件说明](docs/macos-app.md)。

首版目标为 Apple Silicon / macOS 15+。2026-10-30 已由当前源码重打本地测试包，并通过 Swift 31 项、Python 27 项测试；窗口关闭崩溃与 supervisor 停止死锁已修复。Apple 签名公证、公开分发的 runtime 来源复核和无 Python 新机器验收仍是正式发布前的门槛。现有 CLI 用法继续有效。

## 快速开始

需要 Python 3.10+。以下终端示例适用于 macOS / Linux 的 zsh 或 bash。

### 1. 安装和选择目标项目

```bash
git clone https://github.com/sc61561/Project-MCP.git
cd Project-MCP
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements.txt
cp .env.example .env
```

编辑 `.env`，把 `PROJECT_ROOT` 改为希望 ChatGPT 访问的文件夹绝对路径。例如：

```bash
PROJECT_ROOT="/absolute/path/to/my project"
```

加载配置：

```bash
set -a
source .env
set +a
```

`.env` 不会被程序自动读取。`PROJECT_ROOT` 是目标项目，不是 MCP 程序所在目录；切换项目后要重启进程。

仅本地 STDIO 客户端使用时，运行 `python server.py` 即可。启动后等待 MCP 请求是正常状态；ChatGPT 网页接入继续下一步。

### 2. 启动 Secure MCP Tunnel

1. 在 [OpenAI Tunnel 设置](https://platform.openai.com/settings/organization/tunnels)创建隧道，并关联需要使用的 ChatGPT 工作区。
2. 将 Tunnel ID 和所属组织 ID 填入 `.env`，重新加载配置。
3. 按[官方指南](https://developers.openai.com/api/docs/guides/secure-mcp-tunnels)下载适合系统的 `tunnel-client`，把可执行文件放在本仓库根目录。macOS / Linux 可执行 `chmod +x ./tunnel-client`。

在已经激活虚拟环境、加载 `.env` 的终端输入 API Key。下面命令从终端隐藏读取，不会把真实 Key 写入命令历史：

```bash
export CONTROL_PLANE_API_KEY="$(python -c 'import getpass; print(getpass.getpass("OpenAI API Key: "))')"
```

输入完成后，再执行启动命令：

```bash
./tunnel-client run \
  --control-plane.api-key env:CONTROL_PLANE_API_KEY \
  --control-plane.tunnel-id "$CONTROL_PLANE_TUNNEL_ID" \
  --control-plane.organization-id "$CONTROL_PLANE_ORGANIZATION_ID" \
  --mcp.command "command=python server.py,channel=main"
```

必须在仓库根目录运行，并保持虚拟环境激活，让子进程使用正确的 Python。此命令适用于本项目验证过的 runtime 客户端；其他版本请先看 `./tunnel-client run --help`。不要假设所有版本都有 `init` 或 `doctor` 子命令。

Tunnel 会自动启动 FastMCP，无需再单独运行一次 `python server.py`。保持终端进程运行、电脑联网且唤醒。看到启动横幅只能证明本地进程启动，最终应以 ChatGPT 成功读文件为准。

### 3. 在 ChatGPT 中使用

已有 Project MCP 插件时直接启用，无需重新安装。首次添加时：

1. 在 ChatGPT 的插件入口添加自定义 MCP Server，连接方式选 **Tunnel**。
2. 选择隧道或填写 Tunnel ID。这个 Server 未实现 OAuth，应用身份验证选 **无身份验证**；隧道控制平面仍使用 API Key 认证。
3. 阅读风险提示后确认创建，检查工具只有 `list_files`、`read_file`、`search_files`。

测试提示词：

> 使用 Project MCP，先列出项目根目录，再读取 README 并介绍项目结构；遇到下一页时按返回游标继续。

如果隧道不可见，检查 ChatGPT 工作区关联、Tunnel 的 Read + Use 权限，以及当前账号的开发者模式权限。步骤以 [OpenAI 官方连接指南](https://developers.openai.com/api/docs/guides/secure-mcp-tunnels#connect-from-chatgpt)为准。

## 工具与分页

所有 `path` 都相对于 `PROJECT_ROOT`，例如 `src/main.ts`。成功返回数据对象，预期的路径、权限、编码和参数错误返回 `{"error": "清晰说明"}`。工具 schema 参数类型错误由 FastMCP 返回 MCP 验证错误。

| 工具 | 参数 | 行为 |
| --- | --- | --- |
| `list_files` | `path=""`, `recursive=false`, `limit=200`, `cursor=null` | 每页默认 200 条、最多 500 条；返回文件名、相对路径、类型、大小、UTC 修改时间 |
| `read_file` | `path`, `start_line=1`, `max_lines=200`, `start_column=0` | 每页默认 200 行、最多 1000 行，并限制为 32768 个 Unicode 字符 |
| `search_files` | `query`, `limit=200`, `cursor=null` | 大小写不敏感的字面关键词搜索；每页最多 200 个匹配及前后各一行片段 |

目录和搜索结果包含 `truncated`、`next_cursor`。有下一页时保持原路径、递归选项或关键词，把返回的 `next_cursor` 作为下一次的 `cursor`：

```json
{"path": "", "recursive": true, "limit": 200, "cursor": "200"}
```

文件读取被截断时，把 `next_line`、`next_column` 同时传回 `start_line`、`start_column`。行号从 1 开始，列号是从 0 开始的 Unicode 字符偏移；超长单行也能分段续读。

```json
{"path": "src/main.ts", "start_line": 201, "start_column": 0, "max_lines": 200}
```

游标和行号不代表文件快照，项目在翻页过程中变化时应重新开始。搜索每页会重新扫描至指定偏移，适合交互式阅读，不适合高吞吐索引。

## 大小与搜索范围

- 单次工具结果的保守 JSON 序列化上限为 **512 KiB**，目录/搜索会提前分页，并有最终响应保护。这个值不是完整网络包大小，为 FastMCP 文本/结构化结果和隧道封装留有余量。
- Secure MCP Tunnel 的默认单次序列化请求/响应上限为 **10 MiB**，包括协议封装。分页用于满足这一限制，无法通过本地配置提高服务端额度。[官方额度](https://developers.openai.com/api/docs/guides/secure-mcp-tunnels#limits)
- 文本文件大小默认最多 **1 MiB**。`MAX_READ_BYTES` 可调低，配置更大值仍按 1 MiB 处理；大文件读取返回错误。
- 搜索跳过超过该文件上限、无效 UTF-8、不可读的文件，`skipped_files` 表示本次扫描已跳过的数量。搜索结果不覆盖这些文件。
- 搜索片段通常最多 200 字符，长关键词会保留完整匹配和附近文本；`line_truncated`、`context_truncated` 表示片段裁剪。完整内容可再按行读取。
- 递归列目录与搜索跳过 `.git`、`node_modules`、`build`、`dist`、`.next`、`.venv`、`venv`、`__pycache__`、`coverage`、`out`。非递归列表仍可看到这些目录名。
- 读取和搜索支持 UTF-8 的 md、txt、json、yaml/yml、py、js/jsx、ts/tsx、dart、toml、HTML/CSS 等文本格式，完整扩展名白名单见 `server.py`。

## 日常操作与排查

- **停止**：终端按 `Ctrl+C`。
- **切换项目**：修改 `.env` 的 `PROJECT_ROOT`，停止进程、重新加载配置并启动。
- **更新源码**：`git pull` 后重启 Tunnel；如果 ChatGPT 仍显示旧参数，刷新工具列表或重新连接插件。
- **Key 未设置或为空**：先加载 `.env`，再单独执行隐藏读取 Key 的命令，输入完成后才启动。
- **413 / request_body_too_large**：确认运行的是本仓库的新版本，使用分页参数，不要一次返回完整目录或大段内联内容。
- **AuthlibDeprecationWarning**：当前 FastMCP 2.x 依赖可能显示此警告，它本身不表示启动失败；本项目暂不升级 FastMCP 主版本。

默认客户端启用本地健康接口时，可在另一个终端检查：

```bash
curl --max-time 5 http://127.0.0.1:8080/healthz
curl --max-time 5 http://127.0.0.1:8080/readyz
```

通常分别返回 `live` / `ready`。接口不可达表示该地址当前没有可访问的健康服务，不单独证明远端连接状况。最终检查仍是在 ChatGPT 调用一个小的文件工具。

## 只读与安全边界

工具只读取目录元数据和允许的文本文件，不提供写入、删除、移动、复制或 Shell 执行能力。路径解析会检查根目录包含关系，并拒绝绝对路径、NUL 和符号链接；解析到根目录之外的 `../` 会被拒绝。

这是一份应用层路径保护，不是操作系统沙箱；适用于自己控制的项目目录，不应让不可信进程在读取期间并发替换目录或符号链接。

只读不等于无数据披露：工具返回的内容会交给调用方处理。`.env`、私钥等不在文本扩展名白名单内，但 JSON/YAML 或源码仍可能包含凭据。请只选择适合向 ChatGPT 提供的项目，不要把整个用户主目录作为根目录。

## 开发与仓库约定

```bash
python -m pytest -q
python -m py_compile server.py
```

测试使用真实临时文件，覆盖分页不遗漏、长行续读、响应转义膨胀、搜索上下文、忽略目录、文件大小、根目录边界和符号链接。

本仓库根目录的 `server.py` 是维护入口，`tests/` 保存回归测试，`AGENTS.md` 记录协作约定。`requirements.txt` 保持 FastMCP 2.x，不自动跨主版本升级。

下载的 `tunnel-client` / `cloudflared`、本地 `.env`、缓存、日志和原始图稿不入库。仓库可保留小尺寸 `project_mcp_icon_256.png` 作为插件图标。
