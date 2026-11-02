# Project-Auto / Velum

Velum 是一个面向 macOS 的本地 AI 工作台：原生 SwiftUI 桌面、内置 VM 与浏览器、Agent 工具调用、审批、ServerBox SSH，以及可独立安装的本地推理引擎。

这不是一个“演示界面”。仓库里的代码会启动真实 VM、执行真实 SSH、连接真实模型服务；没有假数据路径。

## 当前能力

- **Velum 桌面**：空桌面启动，Dock、窗口、文件/组件/浏览器/供应商/ServerBox/本地 AI 等应用。
- **Agent**：流式回复、工具调用、审批门、会话历史、附件、模型/推理强度选择。
- **本地 AI**：App 只内嵌干净的 CPython 3.12 基座。MLX、Splash 和自定义引擎都是外部包，单独安装、升级、回滚。
- **MLX 引擎**：聊天、EmbeddingGemma 2 向量、模型下载、本地模型文件夹导入。
- **Splash 引擎**：官方 C++/Metal 原生引擎；支持导入一组本地模型文件（DFlash2、GGUF 本体、多分片 GGUF、可选 mmproj），不提供 embeddings。
- **Provider**：多供应商、协议选择、自动拉取模型目录；模型默认全部不勾选，需手动勾选或全选/取消全选。
- **ServerBox**：SSH 密钥或密码登录；密码只存 Keychain，通过 askpass 读取；强制主机公钥确认；连接测试有超时和取消。
- **VM / 浏览器**：smolvm Debian 环境、`/workspace` 双向挂载、内置 WKWebView 浏览器及受控页面操作。

## 仓库结构

```
Project-Auto/                   Xcode 工程与 Swift 源码
  Project-Auto.xcodeproj
  Project-Auto/                  App、AgentCore、ServerBox、LocalAI、DesignSystem…
  VelumLinuxHelper/              非沙盒 XPC helper
  docs/                          架构与实施记录
Runtime/                         VM、Python 基座、引擎打包/验收脚本
  split-ai/                     Python-only 基座与 MLX 外置引擎构建脚本
  splash-engine/                Splash 外置引擎 adapter、打包与验收脚本
  README.md                     smolvm Linux 运行环境说明
```

## 未提交的大文件

为了避免把模型权重和 100MB+ 二进制塞进 Git，以下本地构建资产不在此仓库：

- `Project-Auto/Project-Auto/Resources/velum-pack.smolmachine` 和 `velum-pack/`
- `Project-Auto/Project-Auto/Resources/python-base/`
- `Runtime/split-ai/python-base/`、`Runtime/split-ai/engines/`
- `Runtime/splash-engine/Models/`、Splash/MLX 引擎压缩包
- 任何 Hugging Face 缓存或模型权重

构建前需在开发机准备这些资源。Python 基座可由 `Runtime/split-ai/build_split.py` 生成；引擎包由 `Runtime/splash-engine/build_package.py` 重新封包。具体路径和校验值见 `Runtime/split-ai/README.md`、`Runtime/splash-engine/README.md`、`Project-Auto/docs/python-base-engine-packages.md`。

## 构建

要求：macOS 26.4+、Xcode 27.1+、Apple Silicon。Splash 要求 M3 及更新芯片、macOS 26.4+。

```sh
open Project-Auto/Project-Auto.xcodeproj
# 选择 Project-Auto scheme，Debug/Release 构建
```

或命令行：

```sh
xcodebuild -project Project-Auto/Project-Auto.xcodeproj \
  -scheme Project-Auto -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/projectauto-build build
```

App 是沙盒应用；`VelumLinuxHelper` 是非沙盒 XPC helper。当前是开发签名构建，未做 Developer ID 公证。

## 本地模型导入

### MLX

在「本地 AI」中选择 MLX，停止引擎后点击「导入 MLX 模型文件夹…」。文件夹需包含 `config.json` 和至少一个 `.safetensors`。导入会复制到独立模型目录并写入 `models.json`，随后启动引擎并刷新模型列表。

### Splash

选择 Splash，点击「导入 Splash 模型组…」，分别指定：

1. **DFlash2**：完整的 draft 目录（`config.json` + safetensors），或其中单个 `config.json`/`.safetensors`；
2. **模型本体**：一个或多个 GGUF；split 分片请一次全选，官方安装器会发现同目录所有分片；
3. **mmproj**：可选 GGUF 视觉投影；纯文本模型可留空。

文件会复制到 `Models/splash-local/<id>/`，由 Splash 引擎的 `/control/import` 调用官方 `prepare_local_model` 在离线隔离子进程中准备；不会执行模型仓库代码，也不会自动下载。

## 安全边界

- API Key 与 SSH 密码保存在 Keychain；密码不写入主机配置、SSH 命令行或日志。
- SSH 强制 `StrictHostKeyChecking`，首次连接必须核对并信任完整主机公钥；地址/端口变化会清除旧信任。
- 本地引擎导入只接受受管模型目录内的文件；拒绝 `..`、符号链接逃逸和特殊文件。
- 引擎包安装验证文件哈希、符号链接、Mach-O 签名，并只启动固定入口。
- 当前生产包信任锚尚未配置，引擎包仅支持显式开发签名导入。

## 许可证

见根目录 [LICENSE](LICENSE)。第三方组件和引擎许可证随各自包分发。
