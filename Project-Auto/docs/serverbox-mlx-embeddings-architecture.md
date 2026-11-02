# ServerBox 实现记录与旧 MLX 调研（后半部分已废弃）

> **2026-11-02 修订**：此前将“把 MLX LM 嵌入 App”误解成了“embedding 向量检索”，并给出了不符合需求的 mlxcel 推荐。该推荐已撤销，**第二部分仅保留为历史记录，不作为开发计划**。当前方案是独立可更新的 Python + 标准 mlx-lm 运行时，由 App 统一管理；指定 `mlx-community/embeddinggemma-2-4bit` 的加载兼容性另见 [独立 AI 运行时管理方案](local-ai-runtime-manager.md)。
>
> ServerBox 下述 11/11 仅为复刻校验逻辑的测试，不能等价为真实 SSH 连接、安全沙盒和远程执行已端到端验证。

状态：ServerBox 构建通过；实际远程连接需要另行验收。旧 MLX 推荐已废弃。
日期：2026-11-02

---

## 第一部分：ServerBox 远程主机管理 + Agent 附件授权 SSH（已实现）

### 1. 架构总览

```
┌─ ServerBox 窗口（主机配置）───────────────────────┐
│ ServerBoxStore (@MainActor, UserDefaults 持久化)     │
│  ├─ ServerHost: hostname/port/username               │
│  ├─ identityBookmark (security-scoped 私钥书签)       │
│  └─ trustedHostKeys[] (指纹确认后的 known_hosts 行)   │
│  方法: addHost / update / remove / chooseIdentity     │
│        hostKeyPreview / trustHostKey / testConnection │
└──────────────┬───────────────────────────────────────┘
               │ 用户显式「连接到此任务」
┌─ Agent 附件层 ─▼──────────────────────────────────┐
│ ServerBoxAttachment（每窗口实例，非全局）            │
│ AgentChatModel.attachedServerHostID (@Published)     │
│  ├─ attachServerHost() → 弹出 Picker                 │
│  └─ 仅当附件存在时注册 ServerBoxTool                  │
└──────────────┬───────────────────────────────────────┘
               │ AgentLoop 工具调用（经审批门）
┌─ SSH 执行层 ──▼───────────────────────────────────┐
│ SSHConnection.exec(host, command, timeout, onOutput) │
│  /usr/bin/ssh，key-only，BatchMode=yes               │
│  StrictHostKeyChecking=yes + 固定 known_hosts 文件   │
│  IdentityAgent=none, ForwardAgent=no                 │
│  流式输出 → ToolOutputRelay → Agent UI 实时显示       │
└──────────────────────────────────────────────────────┘
```

### 2. 安全边界（全部已实现并验证）

| 边界 | 机制 |
|---|---|
| 私钥访问 | 仅用户经 NSOpenPanel 选择（security-scoped bookmark），模型无法读取密钥内容 |
| 主机信任 | 首次连接前必须 `ssh-keyscan` → 展示指纹 → 用户显式确认；`trustHostKey` 重新计算指纹防 TOCTOU |
| 中间人检测 | 每次连接实时扫描当前主机公钥，与已信任指纹比对，不一致抛 `keyChanged` 拒绝连接 |
| 命令注入 | hostname/username 白名单校验（禁止空格、引号、`;`、`|`、`&`、`` ` ``、`$`、`<>`、`/\:`、换行）；命令经 ssh 参数数组传递，非 shell 拼接 |
| 端口范围 | 1–65535 |
| 无密码回退 | `BatchMode=yes`，密钥不可用直接失败，不提示密码 |
| 无转发 | `ForwardAgent=no`、`ClearAllForwardings=yes`、`ControlMaster=no` |
| 作用域最小化 | ServerBoxTool 绑定单一 hostID；每个 Agent 窗口独立的 ServerBoxAttachment；模型不能自选其他主机 |
| 超时与截断 | 连接 15s / 命令默认 60s（可 1–300s）；输出 20,000 字符截断 |
| 审批 | serverbox exec 走 `risk = .executesProcess`，默认需用户批准（可被全局 bypass 设置覆盖） |

**边界验证结果**（独立 swift 复刻校验逻辑，11/11 PASS）：
正常主机通过；分号/反引号/路径穿越/引号/换行/空格注入全部被拒；空主机名被拒；端口 0、65536 被拒；端口 65535 通过。

### 3. 关键文件

| 文件 | 职责 |
|---|---|
| `Project-Auto/ServerBox/ServerBoxStore.swift` | 主机档案 CRUD、指纹预览/信任、连接测试 |
| `Project-Auto/ServerBox/ServerBoxAttachmentPicker.swift` | 附件选择器（仅列出可连接主机） |
| `Project-Auto/ServerBox/ServerBoxAttachment.swift` | 每窗口授权作用域 |
| `Project-Auto/AgentCore/SSHConnection.swift` | SSH 执行、指纹扫描/比对、流式输出 |
| `Project-Auto/AgentCore/ServerBoxTools.swift` | Agent 工具（list 已移除，绑定单主机 exec） |
| `Project-Auto/Agent/AgentChatModel.swift` | 附件生命周期、工具注册、系统提示词约束 |
| `Project-Auto/Windows/VelumDesktopWindow.swift` | 工具栏入口、附件胶囊、Popover |

### 4. 用户流程

1. ServerBox 窗口：添加主机 → 填 hostname/port/username → 选择私钥 → 「获取指纹」→ 核对 → 信任 → 测试连接。
2. Agent 窗口：输入区 "+" → 「连接远程主机…」→ 选择主机（仅已配置完整的主机可选）→ 出现主机胶囊。
3. Agent 收到 `serverbox` 工具；每次 exec 经审批门；输出实时流式回显。

---

## 第二部分（已废弃，不实施）：旧的 embedding 服务调研

### 5. 结论：推荐方案

**方案 A（推荐）：mlxcel 作为独立嵌入服务**

- [mlxcel embeddings 文档](https://raw.githubusercontent.com/lablup/mlxcel/refs/heads/main/docs/embeddings.md) 提供 OpenAI 兼容的 `POST /v1/embeddings`，以及 `/v1/rerank` 重排端点。
- 与聊天模型同进程共存：`mlxcel-server -m <chat> --embedding-model <embedding>`；嵌入模型运行在专用 MLX 线程，不与聊天共享计算流。
- 支持的嵌入家族（key 摘录）：
  - BERT / XLM-RoBERTa（`all-MiniLM-L6-v2`、`multilingual-e5-*`、`bge-m3`）
  - ModernBERT（`nomic-ai/modernbert-embed-base`，8192 上下文，Matryoshka 截断到 256 维仍有效）
  - Qwen3-Embedding（last-token pooling，`mlx-community/Qwen3-Embedding-0.6B-4bit` 等）
  - EmbeddingGemma（Gemma3 双向 + 两层 Dense 投影）
  - LFM2.5-Embedding（350M，CLS pooling，512 上下文）
  - Nemotron-3-Embed、LLM2Vec、ColBERT 系（多向量 late-interaction）
- 离线验证工具 `mlxcel embed`：同一条加载/pooling/归一化路径，无监听端口，适合 CI 或本地验证。

**为什么不用 `mlx_lm` 本体内嵌嵌入**：上游 `mlx-lm` 主线以生成模型为主（`mlx_lm.server` 面向 chat completions），嵌入需要专门的 pooling/归一化/掩码处理；mlxcel 已把这部分完整实现并维护家族表，是 Mac 上 MLX 嵌入事实上的服务层。

### 6. 可更新性（热更新模型）的关键事实

- **模型可切换**：`--embedding-model` 支持路径或 repo-id，加载失败是启动错误；`-m` 加载嵌入 checkpoint 失败则路由返回 501。切换嵌入模型 = 重启服务或换端口，无需改业务代码——接口是 OpenAI 兼容的，客户端无感知。
- **维度可调**：请求字段 `dimensions` 支持截断（前 N 维 + 重新 L2 归一化），ModernBERT 等声明 Matryoshka 训练的模型降到 256 维仍保质量。注意：截断改变向量语义，**已建索引必须重建**。
- **checkpoint 检测自动路由**：`modules.json` 含 `.Pooling` 模块或 `model_type` 为 encoder 家族即按嵌入加载；不会误路由到生成器。升级模型只需换 checkpoint 目录。
- **已知数值特性**：bf16 checkpoint 下同一文本单独嵌入与批量嵌入余弦约 0.9999（批几何累积精度差），非 bug；YaRN/RoPE 实现变更会使旧索引向量失效（如 Nemotron-3 曾有此问题），**升级 mlxcel 版本后建议全量重建索引**。

### 7. Velum 集成架构（可执行）

```
┌─ Velum Agent (macOS) ────────────────────────────────┐
│ 1. 本地检索需求（工作区文件 /workspace 语义搜索）      │
│    新 AgentTool: EmbedTool                           │
│      action=search: POST http://127.0.0.1:8081/...   │
│ 2. launchd 管理 mlxcel-server（按需启动，空闲退出）    │
│    ~/Library/LaunchAgents/app.velum.embeddings.plist │
└──────────────────┬───────────────────────────────────┘
                   ▼
   mlxcel-server -m <embedding checkpoint> --port 8081
                   ▼
   向量库（SQLite + 向量扩展，或内存 HNSW）
```

**落地步骤**：

1. `brew install` 或 pip 安装 mlxcel；预下载 checkpoint（推荐起点：
   - 轻量多语：`intfloat/multilingual-e5-small`（mean pooling，512 上限，注意 `query: `/`passage: ` 前缀由调用方拼）
   - 质量优先：`mlx-community/Qwen3-Embedding-0.6B-4bit`（8192 上下文）
   - Matryoshka：`nomic-ai/modernbert-embed-base`（`search_query: `/`search_document: ` 前缀）
2. launchd plist：`ProgramArguments` 带上述 `-m`；`KeepAlive=false` + socket 激活或 Velum 启动时拉起。
3. Velum 内 `EmbedTool`（`risk: .network`）参数：`query`、`top_k`；索引构建在沙盒内对 `/workspace` 增量扫描，写入本地向量库。
4. 前缀规则进系统提示词：e5 系必须 `query: `/`passage: `；nomic 必须 `search_query: `/`search_document: `；漏前缀不报错但检索质量显著下降（上游文档明确）。
5. 模型升级流程：下载新 checkpoint → `mlxcel embed` 离线跑冒烟集（固定 10 对 query/doc，比较相似度矩阵）→ 通过后切换 plist 中的路径 → **全量重建索引**。

### 8. 风险与备注

- SigLIP 文本塔**不适合**文本-文本检索（对比训练目标是图文，无关节文本对相似度地板高，上游实测无关对余弦均值 0.653）——不要选。
- LLM2Vec PEFT 适配器目录不可直接加载，需先合并导出完整 checkpoint。
- 生成式 reranker（Qwen3-Reranker）只能经 `--reranker-model` 挂载，`-m` 不识别。
- 嵌入与聊天同进程时共享 `--embedding-queue-depth`（默认 8，满则 503）与 120s 请求超时；Agent 工具超时应设 ≥ 该值。

## 参考资料

- [mlxcel Embeddings and reranking APIs and CLI（官方文档）](https://raw.githubusercontent.com/lablup/mlxcel/refs/heads/main/docs/embeddings.md)
- [mlx-vlm（PyPI，相关 MLX 多模态服务）](https://pypi.org/project/mlx-vlm/0.7.2/)
- [ADR-0065: mlx_lm.server 作为按需 launchd 服务的先例](https://raw.githubusercontent.com/shimo4228/contemplative-agent/34208725235bf937177692fdb81244616ed9218d/docs/adr/0065-mlx-ondemand-launchd-and-telemetry-model-contract.md)
