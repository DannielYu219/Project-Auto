# 独立本地 AI 运行时：实施记录

日期：2026-11-02。状态：本机开发版本已完成，真实沙盒 App → XPC → 外部 Python → MLX 推理通过。**不是 Developer ID 公证发行版**。

## 已实现

- 运行时独立于 App：`/Users/Shared/Velum/ai/runtimes/velum-mlx-python/<version>-arm64/`。
- 版本化安装、完整 SHA256 校验、受控 symlink、安全归档解包、所有 Mach-O 签名校验、active/previous registry、回滚。
- 默认拒绝非受信生产发行包（发布签名 metadata 还未配置）；安装本机 adhoc 包必须显式选择开发模式。
- App 保持沙盒，经现有内嵌 XPC helper 的用途受限 API 启动固定 Python/adapter 入口。helper 验证调用 App 的签名标识及 Team ID。
- 本地服务仅 loopback，端口由系统分配，64 位十六进制 token 私有传递。UI 不填写或展示 endpoint/API Key；HTTP 禁止重定向。
- 独立「本地 AI」App 页面：运行时安装/更新、启动/停止、回滚、已安装模型、下载指定模型/版本、加载及释放内存。
- 供应商模型选择面板同时提供本地聊天模型；切换远程供应商会关闭本地选择，本地不冒充远程 API 配置。
- `ManagedLocalAIProvider` 将 OpenAI SSE 转为已有 PiStreamEvent，支持实际 text/thinking/tool calls。Off 映射本地 `enable_thinking=false`；其余等级不伪造模型原生多档预算。
- `LocalEmbeddingService` 为 App 提供固定 checkpoint 的向量服务，无需 endpoint；task 前缀由服务按模型配置处理。
- 模型存放于独立 `Models/`，已安装固定 revision 的 Qwen3-0.6B-4bit 与用户指定 EmbeddingGemma2。
- runtime 默认无代理依赖。本机下载可在 UI 选择 `127.0.0.1:7890`；修改代理/安装更新需先停止，避免中断现有任务或 active registry 与进程版本不一致。
- Python 启动父进程死亡时自动退出；应用结束有显式 stop；请求断开能取消 generation。

## 包版本

- CPython 3.12.16（standalone，可重定位）
- 标准 `mlx-lm==0.32.2`
- MLX / MLX Metal 0.32.3，Transformers 5.18.0
- MLX-VLM 固定 commit `3d87e88402f307efbf68e568971aa887ee7d9ed0`
- 系统：arm64，macOS 26+
- runtime：`2026.11.02-dev.2`
- 归档：`Runtime/local-ai/velum-mlx-python-2026.11.02-dev.2-macos-arm64.tar.gz`
- 压缩体积：262,113,196 bytes；SHA256 `4316e78a757b83b023975404dd86aeb869a44208fbf2253485090d0b73f70f9d`
- manifest SHA256 `f23aa4bf25ed071ecca7f51239d7a4d49f2f4ca26ef0fdc434f4a3d54c4ead61`
- regular files 20,306，内部 symlinks 10，签名并验证 Mach-O 284。
- pip、ensurepip、编译/打包工具不随运行时交付。版本与 wheel hashes 在包内锁文件。

## 实际验收

在签名、沙盒 App 的显式 `--local-ai-selftest` 入口中执行，不会打开 Agent/浏览器窗口或修改当前模型选择：

1. 从外部归档安装 `dev.2`，记录两个版本；XPC 真实回滚旧版，再回滚到新版。
2. XPC 启动 Python，未经 token 的 `/health` 返回 401。
3. `ManagedLocalAIProvider` 对 Qwen3 发送真实流式生成，得到 `Hello!`。
4. 模型输出 `get_weather(city: Paris)`，PiProvider 成功解码 tool call；工具不在 Python 侧执行。
5. EmbeddingGemma2 输出 3×768 finite vectors，Mars 相似度 0.87782596 > Venus 0.70131542。
6. App LocalEmbeddingService 的 query task + 256 维路径验收。
7. 停止后 endpoint/token 清理，状态 stopped。

Python 原始证据：`Runtime/local-ai/evidence/integration.json`、`relocation.json`、`package.json`、`parent-monitor.json`、`proxy-policy.json`。

Swift standalone tests 另验证：恶意 tar 路径/硬链接/设备文件、越界 symlink、未登记文件、hash 篡改、修改 native code 后重算 manifest 仍被签名校验拒绝、显式开发许可、不可变重装、失败就绪回滚、运行中拒绝安装/代理变更且旧服务正常。

## 用户使用

1. 打开 Dock「本地 AI」，可查看已安装的 `2026.11.02-dev.2`。
2. 点击启动并刷新，已预下载的聊天/向量模型来自独立 Models 目录。
3. 点击聊天模型「用于 Agent」，或从 Agent 的模型面板选择本地模型。
4. 输入任务即可按需启动和加载本地服务，不需要 URL 或 API Key。
5. 向量模型仅提供 embeddings，不会出现在聊天模型列表。
6. 后续更新先停止，再导入新的独立运行时包；运行时和 App 不绑定。

## 尚未声称完成

- 无在线发行 catalog/CDN，也没有配置正式发行签名 metadata，因此当前是完整开发包的导入式安装更新，不是已上线一键在线更新。
- 没有 Developer ID 公证；未做另一台干净 Mac 安装验收。
- 只有一个实际 MLX runtime backend，协议已分层，不代表 llama.cpp 等其他 backend 已实现。
- 不保证任意架构/量化 checkpoint；只保证经具体模型验证的路径。
- 未实现 VLM/音频/视频输入、embedding RAG 索引、logprobs/严格 structured output/tool_choice 强制约束。
- Qwen3 0.6B 是接口验收模型，不代表通用 Agent 性能或复杂任务可靠性。

发行阶段需要签名的 catalog/manifest、公证 runtime、稳定下载源、更新回滚实机验收，再开放默认生产安装。
