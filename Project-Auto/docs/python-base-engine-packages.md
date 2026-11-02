# Python 基座与外置引擎包（schema 2）实施记录

日期：2026-11-02。状态：实际签名沙盒 App → XPC helper → App 内干净 CPython → 外部 MLX / 自定义包 / Splash 验收通过。所有引擎包目前是显式授权的开发签名包，未宣称公证发行。

## 结构

- App 仅新增内嵌 `Resources/python-base/`：CPython3.12.16、标准库、原生扩展和许可证，无第三方 site-packages、MLX、pip、ensurepip。约56MiB（压缩归档20.6MB）。其他已有 VM/Needle 功能资源不在本次 Python 引擎拆分范围。
- 外部 `engines/packages/<id>/<version>-arm64/`：引擎 adapter + site-packages/native payload，禁止夹带 CPython/libpython。只有固定入口由 broker 启动。
- 模型单独存储于 `/Users/Shared/Velum/ai/engines/Models`，不进入 App 或引擎包。
- 每个引擎拥有独立 active/previous 版本，完整 hash、symlink/native signatures 验证，安全解包，更新前停止。生产包可通过应用内信任锚 Ed25519 验证 `runtime.sig`；未配置发行密钥时不冒充可信发行包。
- 自定义包使用同一 schema2，可导入，仍须用户明确允许开发/自定义代码；不是从任意 requirements 在本机执行 pip。
- 默认一个引擎和一个加载模型，避免多个重型后端争抢 GPU 内存；切换引擎先停止原引擎。
- URL/端口/token 为私有实现，用户只选引擎和模型。已有 PiProvider/embedding 路由均已切换新服务；旧schema1包保留作历史数据，不再作为默认UI启动路径。

## 真实包

| 包 | 压缩字节 | SHA256 |
|---|---:|---|
| Python base3.12.16-split.1 |20627203|3cdacb2a8cca1f85e069bff3f357d8dbba62c0856a74823d12aa7d92b01df8a8|
| MLX2026.11.02-split.1 |181642210|f7d0be6491b6ad88e48f1bac5656afe554bfc274b065bc6d7259f9a56a273672|
| custom-echo 示例 |4046|3bf07fca3017823d16bb889e5ee05598105d7208eacbec071d870df6a1d61a1d|
| Splash1.5.0-velum.1 |54302400|9f56f796506306a5166cb82f2f033857c4a8738164e0dc476481bda67b7d9e4d|

基座954 regular files、11个签名Mach-O；MLX包10537 regular files；Splash5457 regular files、57个签名Mach-O。App总大小本机约251MiB，无MLX包和模型权重。

## Splash

固定官方1.5.0 commit `cabbad2732b027540f5a141511544e0bb62224b7`。

Splash不是MLX pip模块。它是官方 C++/Metal native engine + Python前端；独立包使用我们自己的CPython3.12执行adapter和官方前端，再启动同包native payload。没有把上游发行包自带的Python3.13带入我们的包。

- 系统：M3及更新Apple Silicon，macOS26.4+，有实际native device-check。
- 对App提供统一的velum.local-ai.v1 readiness/token/API；这是我们的adapter协议，不声称上游原生支持这个协议。
- 真实支持chat/SSE/tool/reasoning API；本适配层目前首个固定验证catalog为Ternary-Bonsai2 PQ2_0，配套固定DFlash2 draft。不是所有HF模型随意可跑。
- **不提供embeddings**，EmbeddingGemma2仍由独立MLX包运行。
- `control/download`明确选择模型/预算后才下载，load/chat不隐式下载。约11.055GB target+draft已下载到独立缓存并校验；不会塞进54MB引擎包。
- Bonsai实测reasoning可分low/medium/xhigh，High/Max按上游alias落到最高；Off使用reasoning_effort none。
- 首次实测native加载约56.4秒（冷编译），warm约9秒；仅为本机测试值，不作为其他设备承诺。
- 控制退出取消完整wrapper/upstream/native进程组；磁盘KV缓存默认禁用避免隐式32GiB空间占用。

## 验证

App显式 `--split-ai-selftest --splash-check`（无桌面窗口、无截屏抢占前台）输出：

```
SPLIT APP MLX CHAT PASS Hello! How can I assist you today?
SPLIT APP EMBEDDING PASS 256D
SPLIT APP CUSTOM ENGINE AUTH/START PASS
SPLIT APP SPLASH HEALTH PASS ...device supported...
SPLIT APP SPLASH INFERENCE PASS SPLASH_OK
SPLIT APP ACCEPTANCE PASS
```

此前standalone package/Swift tests覆盖真实MLX text/SSE、float/base64向量、内存单模型切换、完整hash+native signatures、归档恶意路径/硬链接/设备节点、签名/manifest篡改、版本回滚、parent-death清理；Splash原生真实非流式/SSE推理和所有子进程退出。App seal `codesign --verify --deep --strict`通过。

## 使用

1. Dock「本地 AI」已采用引擎包UI：选择mlx/splash/custom-echo，启动/停止、更新/回滚。
2. 点击「刷新所选引擎模型」查看已有模型；聊天模型「用于Agent」。本地模型选择持久化时记录engineID，App自动路由。
3. 模型下载有EmbeddingGemma2与Splash Bonsai预设，向量用途不允许发给Splash。
4. 更新用新的完整引擎包导入，App内Python无需重复打包；可扩展在线catalog但目前没有线上发行服务器。

## 后续发行工作

- 配置可信发行密钥及DeveloperID签名/公证，CI复核整个App基座资源seal和native库加载。
- 实际线上catalog和下载源尚未部署；当前按用户要求的“直接导入构建包”完整可用。
- Splash只测试固定catalog文本路径；更多家族、视觉输入、native structured-output等需逐项验收后开放。
- 暂不删除旧schema1运行时/旧模型目录以避免误删用户数据；新UI使用新引擎目录。

源码：App `LocalAI/EnginePackageManager.swift`、`SplitEngine*.swift`、`ManagedLocalAIProvider.swift`；打包/原始证据在 `Runtime/split-ai/` 和 `Runtime/splash-engine/`。本说明替代上一版把Python也放在外部引擎包中的默认结构。
