# Velum 独立 AI 运行时管理方案

研究日期：2026-11-02。状态：架构研究，未安装运行时、未下载模型权重、未执行模型推理。本文替代旧文档中把“嵌入 App”误解成“embedding 检索”、并推荐 mlxcel 的部分。

## 1. 决策

采用用户提出的 LM Studio 类架构：

- App 是运行时、模型与服务的管理器，不把 Python/MLX 固定打进 App 包。
- 第一种引擎使用标准 Python `mlx-lm`；不 fork 它，也不把第三方 mlxcel 作为默认。
- 运行时是我们构建、锁依赖、签名、公证、发布的独立包；用户不需要安装 Homebrew、Python 或执行 pip。
- App 更新、引擎更新、模型更新是三条独立通道。
- App 内模型选择使用逻辑模型 ID；地址、端口、鉴权 token 都由服务管理器处理，不让用户填 URL。
- 未来可增加 mlx-vlm、llama.cpp 等引擎；“支持任意模型”应精确描述为“支持相应引擎已实现的架构和量化格式”，不能保证任意 checkpoint 都能运行。

## 2. LM Studio 真正值得借鉴的部分

[LM Studio 离线文档](https://lmstudio.ai/docs/app/offline)明确说明：runtime 是独立封装的引擎，允许不升级 App 而下载/切换引擎。

[CLI runtime 文档](https://lmstudio.ai/docs/cli/runtime/runtime)列出 `ls / get / select / remove / update`。应借鉴这个分层，而非照搬其内部实现。

[headless 文档](https://lmstudio.ai/docs/developer/core/headless)将 llmster/headless core 与桌面 UI 分离；daemon 与对外 HTTP server 也是不同生命周期。

[LM Studio MLX Engine 文章](https://lmstudio.ai/blog/mlx-engine-agentic-workloads)说明它的 mlx-engine 是其自己维护、基于 mlx-lm/mlx-vlm 的引擎。因此使用 upstream mlx-lm 不会自动获得 LM Studio 的 KV cache 管理、连续批处理等全部行为。

Velum 应借鉴：引擎独立更新、服务按需启动、模型按能力路由、UI 无需处理物理 endpoint。不是把 LM Studio 或其私有服务当依赖。

## 3. 指定 checkpoint 已核实

使用 `mlx-community/embeddinggemma-2-4bit`，不可换成旧 EmbeddingGemma、Gemma2 聊天模型或其他 checkpoint。

[固定版本模型卡](https://huggingface.co/mlx-community/embeddinggemma-2-4bit/blob/8ab839e127cb8cb305edd71fb7a02c82f2d49ab3/README.md)和[config](https://huggingface.co/mlx-community/embeddinggemma-2-4bit/blob/8ab839e127cb8cb305edd71fb7a02c82f2d49ab3/config.json)确认：

| 项目 | 已核实信息 |
|---|---|
| checkpoint revision | `8ab839e127cb8cb305edd71fb7a02c82f2d49ab3` |
| 架构 | `EmbeddingGemma2Model` / `embedding_gemma2` |
| 用途 | feature extraction / embeddings，不是对话生成 |
| 权重 | 模型卡称约 1.098 GB（十进制），不是峰值内存 |
| 输出 | 768 维、归一化；可选 128 / 256 / 512 / 768 维裁剪再归一化 |
| 量化 | affine 4bit、group_size 64；视觉/音频塔及部分投影保留 BF16 |
| 精度 | 非量化部分和激活必须保持 BF16，模型卡明确不应统一转 FP16 |
| 检索 query 前缀 | `task: search result | query: ` |
| 检索 document 前缀 | `title: none | text: ` |
| 许可 | 模型仓库声明 Apache-2.0，发布时仍需收录原始许可证/归属 |

**关键兼容性问题：标准 mlx-lm 不是这个模型的加载器。** 当前 mlx-lm 模型树未列出 `embedding_gemma2`；模型卡提供的是 `mlx_vlm.embedding_loader.load_embedding_model`，并指向 MLX-VLM 的固定提交：

`3d87e88402f307efbf68e568971aa887ee7d9ed0`

可追溯的[loader 源码](https://github.com/Blaizzy/mlx-vlm/blob/3d87e88402f307efbf68e568971aa887ee7d9ed0/mlx_vlm/embedding_loader.py)及[模型实现](https://github.com/Blaizzy/mlx-vlm/blob/3d87e88402f307efbf68e568971aa887ee7d9ed0/mlx_vlm/models/embedding_gemma2/embedding_gemma2.py)已下载检查。

因此建议第一个 MLX 运行时家族有两种独立依赖 profile：

1. `mlx-lm-text`：标准 mlx-lm，负责聊天、流式输出、兼容模型的工具调用。
2. `mlx-gemma2-embed`：标准 MLX + 模型卡指定的 mlx-vlm 提交，负责本 checkpoint。仍是我们封装的 Python 运行时，不用 native Swift 内嵌引擎，也不改用 mlxcel。

二者可共享 Python 构建配方，但不要强行共用同一可变 site-packages：依赖冲突时允许独立版本并存。

模型卡要求文本路径 `transformers>=5.18.0` 和 `mlx>=0.32.3`。其多模态路径更严格：需要提供 `EmbeddingGemma2Processor` 的兼容 Transformers 构建；模型卡称 stock PyPI 5.18.0 尚未提供该 processor。**第一阶段只承诺文本 embedding；图像/音频/视频在完成固定依赖和实际验证后再启用。**

模型卡也明确记录 4bit 误差和有限 smoke checks，它不等于已经通过我们的中文检索质量评测。

## 4. Python 和包版本选择

建议首版使用标准 GIL 的 CPython 3.12、arm64 原生构建，不选 free-threaded，也不依赖用户系统 Python。

[python-build-standalone](https://github.com/astral-sh/python-build-standalone)提供可重定位、自包含的 `install_only` 发行包，由 Astral 维护；适合作为我们打包的基础。

本次 GitHub release API 观测到可选构建：

- release：`20261026`
- `cpython-3.12.16+20261026-aarch64-apple-darwin-install_only.tar.gz`
- 归档大小约 25.17 MB（仅 Python 压缩包，不含引擎/权重）
- API 提供 SHA256：`fbf4afef53c2a6b72bb741bc06d5671a9dfaf87bd84e5aa73ac9b3d0d589f14e`

这只是已查到的候选发行物，尚未下载/验证兼容性；正式版在 CI 选定和验证具体 patch 后锁死。

截至本次研究：

- [mlx-lm PyPI](https://pypi.org/project/mlx-lm/) 版本 `0.32.2`，`Requires-Python >=3.11`；当前 main 的 pyproject 同样要求 >=3.11。不要只看 MLX 核心的 Python >=3.10 而误选 3.10。
- [mlx-lm main pyproject](https://github.com/ml-explore/mlx-lm/blob/main/pyproject.toml)与 PyPI wheel 依赖下限有区别，生产必须用具体发布版、完整传递依赖锁及 wheel hashes，不使用 `pip install -U` 或 main。
- MLX-VLM PyPI 当前是 `0.7.11`，但不能仅凭版本号推断它包含模型卡 branch 的实现；EmbeddingGemma2 profile 优先复现模型卡固定提交，再验证后续稳定版。

构建机离线装配全部 wheel、MLX Metal 资源和 adapter；签名后不可再 pip install 修改。每个运行时附 SBOM、锁文件、依赖版本、模型架构列表、许可证说明。Python 发行包的依赖许可证也需单独审计，不能认为所有内容都只有 Python/MLX 的许可证。

## 5. App / Runtime / Model 三层

```text
Velum App
  ├─ RuntimeCatalog / RuntimeInstaller / RuntimeManager
  ├─ ModelCatalog / ModelDownloader / ModelRegistry
  ├─ LocalAIProvider（逻辑 model ID → 推理服务）
  └─ Runtime Broker（启动、停止、health、版本验证与受控 IPC）
       ├─ Python MLX-LM runtime → chat / stream / tools（按模型能力）
       ├─ Python EmbeddingGemma2 profile → embeddings
       └─ 未来 llama.cpp / VLM / 音频引擎
```

推荐外部布局（示意，不声称 LM Studio 使用此目录结构）：

```text
Application Support/Velum/
  runtimes/<runtime-id>/<version>-arm64/
    Runtime.app/Contents/MacOS/python3
    Runtime.app/Contents/Resources/python/
    Runtime.app/Contents/Resources/adapter/
    manifest.json
    requirements.lock
    licenses/
  models/<model-key>/<revision>/
    config.json, tokenizer*, *.safetensors, model-manifest.json
  registry/{runtimes.json,models.json}
  staging/
  logs/
  caches/<runtime-version>/
```

这是数据/可执行包分离：运行时目录不可就地升级；模型升级也使用新 revision 目录。App 内只保存 runtime/model 的逻辑引用。

### 生命周期

`notInstalled → installing → installed → starting → ready → loadingModel → running → unloading → stopped`

异常分支：`incompatible / crashed / updatePending / rollback`。

- 选择本地模型时按需启动，等待真实 readiness，再发推理请求。
- UI 显示启动/加载进度、内存、正在执行的任务、错误日志、停止/卸载。
- 默认不开机自启动，不绑定公网，不添加 launchd 常驻；确需无 UI 后台服务时另加用户选项。
- 服务退出时终止并回收子进程；取消 generation 不能误停其他 runtime。
- 单 GPU 内存调度器负责 chat 与 embedding 的串行/并行策略；先采用一个重型生成模型驻留，embedding 按需加载，不默认同时占满统一内存。

### App 内无需 URL

用户只看见「本地 MLX」「模型」「下载」「启动/停止」「更新」。

现有供应商层应扩展为 `remote` 和 `managedLocal(runtimeID, modelRevision)` 两类，而不是为本地模型生成要求用户填写的假 API Key/URL。

`LocalAIProvider` 实现当前 `PiProvider` 流式接口；chat、tool calls、thinking、usage 映射成已有 PiStreamEvent；embedding 有独立服务接口，不伪装成聊天工具或对话模型。

内部传输优先用私有 stdin/stdout framing 或 Unix socket；若沿用 HTTP，就由 broker 分配 loopback 地址、临时端口、一次性 token，并处理端口占用/ready handshake。优先子进程绑定端口 0 后报告真实端口，避免“先找空闲端口再启动”的竞态。日志走 stderr，协议走 stdout。

Upstream [mlx-lm SERVER 文档](https://github.com/ml-explore/mlx-lm/blob/main/mlx_lm/SERVER.md)明确说其 server 只有基础安全检查，不推荐用于 production。所以可用原版 server 验证兼容性，但产品应有一层很薄的受控 adapter，调用 upstream API，而不是裸暴露 8080。**保留标准引擎 ≠ 完全不写服务适配层。**

## 6. 独立更新流程

三个版本：AppVersion、RuntimeVersion、ModelRevision。另设稳定 `RuntimeProtocolVersion`。

runtime manifest 至少包含：id、version、architecture、minOS、pythonVersion、engineVersion、adapterProtocol、capabilities、支持的 model_type、完整文件 hash、签名/发行元数据。

流程：

1. 下载签名 catalog 与 runtime archive 到 staging；验证发行签名、hash、架构、OS 和协议范围。
2. 安全解包：拒绝路径穿越和越界 symlink；校验 native libraries/Metal 资源。
3. 安装新版本目录，与旧版本并存；先运行不载模型的 import/health smoke test。
4. 等当前请求结束；新进程 warm-load 固定小型验收模型并验证输出。
5. 原子切换 active-version registry；后续请求使用新版，已有请求保持旧版本租约。
6. 失败恢复旧 registry 和旧进程；保留至少一个 previous 版本，确认成功后才清理。

模型也采用新 revision 下载、hash 校验、兼容检查、试载、原子激活。模型变化、维度、前缀/pooling 改变要使旧向量索引失效；索引保存完整 embedding identity（模型 revision、维度、前缀策略、adapter 版本）。

首版支持完整 runtime 包更新 + 单文件级模型缓存复用即可。真二进制差分不是 MLX 自带能力，先不承诺。

App 新版本只在管理协议、UI、系统权限变化时必要；支持新模型架构通常只需更新兼容协议下的 runtime，但不保证永远无需升级 App。

## 7. macOS 签名、公证、沙盒

本项目已确定直接分发，不做 App Store。独立下载执行引擎与 Mac App Store 的额外代码限制冲突，不再走 MAS 方案。

- Python、所有 .so/.dylib、启动器、Metal 依赖作为**独立签名、公证的 runtime 发布物**。不能直接把 upstream wheel 解压到用户目录后宣称可安全分发。
- hardened runtime 下 Python 加载 native wheels 涉及 library validation；优先将 native code 用同一 Team ID 签名，不默认加 disable-library-validation。Python/MLX 是否需要其他 entitlement 必须通过固定包测试，而不是照抄 Electron/JIT 权限。
- [Apple 公证工作流](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)要求网络安装器和下载 payload 分别处理公证。ZIP 本身不可 staple；可采用可 staple 的 Runtime.app/DMG/PKG 外壳，确保提取后仍能验证。hash 不等于来源签名，也不等于公证。
- **当前 App 是 sandboxed，这里有必须实测的约束**：外部 Python 的可执行访问、动态库加载、继承沙盒、Metal、模型目录和 Unix/loopback IPC 都不能只凭 Process.run 假设正常。
- 推荐新增用途受限的 runtime broker XPC，与 Linux helper 职责分开：只启动已签名 registry 内的 runtime、固定入口和受控参数；不得提供任意宿主 shell 执行。存储在 broker 可访问的受管理位置，通过受控接口写入/查询。公证和更新包验证也在相同受信边界内完成。
- 如果 sandbox + broker 原型验证失败，再明确选择直接分发的 non-sandbox App 架构；不在研究阶段悄悄取消沙盒。

Apple 来源：[App Sandbox](https://developer.apple.com/documentation/security/app-sandbox)、[distribution signing](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac)、[notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)、[library validation](https://developer.apple.com/documentation/BundleResources/Entitlements/com.apple.security.cs.disable-library-validation)。

## 8. 可执行验证里程碑

### P0：运行时可重定位 / 外部运行原型
- 选择 CPython 3.12 固定 patch + arm64 install_only；构建 mlx-lm 锁定环境。
- 移到包含空格路径的新目录，不依赖系统 Python/PATH；验证 mlx import、Metal、文本流式生成和取消。
- 检查沙盒 App → runtime broker → 外部 Runtime.app 启动与 IPC，不打扰用户前台。

### P1：指定 checkpoint 文本路径
- 固定上述模型 revision、MLX-VLM commit、兼容 Transformers 和 MLX。
- 检查所有向量 finite、768 维、接近单位范数；验证卡片 Mars/Venus 排序和中文检索样本。
- 如果给出 256 维选项，必须单独建索引；query/document 前缀固定在 adapter，不能依赖 Agent 记住。
- 不开启尚未验证的多模态 processor。

### P2：服务管理集成
- Runtime 管理页：安装/更新/版本/回滚/运行状态；供应商模型选择支持 managedLocal。
- 无 endpoint 输入；日志、错误、内存限制、卸载等可观察。
- 真实 PiProvider tool loop、聊天模板、reasoning 能力按模型验证；不把 system prompt 等价成 native reasoning 参数。

### P3：发行质量
- 模拟断网、hash 错误、损坏归档、恶意路径、端口占用、更新中 App 崩溃、旧版回滚。
- 另一台未装开发工具的 Apple Silicon Mac 上首次安装/离线重启/公证验证。
- 通过后再开发第二种 runtime，验证协议没有硬编码 mlx-lm/Python。

## 9. 本轮研究边界

已做：核对模型卡/config/实现提交、PyPI 元数据、Python 分发物元数据、LM Studio 官方 runtime/headless 分层；确定架构和验收方案。

未做：Python/runtime 包构建、1.098 GB 模型下载、真实 embedding/生成推理、沙盒 broker 原型、公证发布。不能把这些写成已完成或已兼容。

原始资料已保存在 `Runtime/research-runtime-manager/`，用于复核；main/release API 结果只是研究时点快照，实际发布必须重新锁定不可变版本。
