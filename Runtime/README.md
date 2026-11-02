# Linux 运行时（smolvm）

Velum 的 Linux 工作环境用 **smolvm** 运行：OCI 原生、无守护进程、<200ms 启动，
macOS/Linux/Windows 同一套 CLI，支持持久机器、目录挂载、端口、checkpoint/branch。

不迁移旧 iSH 数据，全部从零构建。

## 当前架构（已接入 App）

```
Project-Auto.app
├── Contents/Resources/velum-pack              45 MB   # 自包含 VM stub
├── Contents/Resources/velum-pack.smolmachine  99 MB   # Debian 13 rootfs + 工具
└── Contents/XPCServices/VelumLinuxHelper.xpc          # 非沙盒 helper
        └── 拉起 velum-pack，执行 exec
Project-Auto（App 沙盒）
        └── NSXPCConnection → LinuxHelperClient → BashTool
```

- **App 保持沙盒**；XPC helper 不沙盒，带 `com.apple.security.hypervisor`，负责启动 VM。
- **pack 随 App 分发**，总包约 150 MB；用户无需安装 smolvm。
- Agent 的 `bash` 工具经 helper 在 Debian 13 中执行，`/workspace` 双向挂载。
- 文件页真实读取 Linux `/workspace` 以及用户明确授权的 `/mnt/mac/<grant-id>` 挂载目录；挂载支持只读/读写，授权目录不能由模型自行扩大。
- Agent 可使用 `linux_mount` 请求用户选择 Mac 目录，使用 `browser_state` 获取内置 WKWebView 页面/截图，使用 `browser_action` 直接执行严格 JSON 浏览器动作；`browser_command` 是可选的 Needle3 英文翻译路径，低置信度不执行。
- 默认每次写文件/执行命令/控制界面都会在对话里弹出审批卡（允许 / 拒绝 / 本次会话总是允许）；只读工具直接放行。开发验收可用 `--allow-shell` 自动放行。

## 工作区路径

App 容器里的路径 helper 读不到（smolvm virtiofs 会挂载失败），所以工作区放在：

```
/Users/Shared/Velum/workspace
```

App 通过 `com.apple.security.temporary-exception.files.absolute-path.read-write`
访问该目录（当前写死为 `/Users/Shared/Velum/`）。

> 分发前要把 temporary exception 换成 **App Group**（app 与 helper 共用 group 容器），
> 或者由 helper 自己持有工作区并通过受控通道同步。App Group 需要包含该 capability
> 的 provisioning profile；当前开发 profile 不含，所以先用 temporary exception。

## 发行版与 apt

- 基础镜像：**`debian:stable-slim`**（Debian 13 trixie），arm64。
- apt 不走代理：init 先切清华 HTTP 源装 `ca-certificates`，再切到
  `https://mirrors.aliyun.com/debian`，之后直接走阿里云。
- 不用 Alpine（musl/apk 生态），也不把 DietPi 当底座。

## 重新打 pack

```sh
cd Runtime
smolvm machine create --name velum-dev --smolfile velum.Smolfile
smolvm machine start --name velum-dev --proxy http://<宿主IP>:7890  # 仅镜像拉取
smolvm pack create --from-vm velum-dev -o pack/velum-pack
cp pack/velum-pack pack/velum-pack.smolmachine ../Project-Auto/Project-Auto/Resources/
```

工具集变化后重新 pack；App 构建会把 Resources 里的文件自动拷进 bundle。

## 验收

```sh
Project-Auto.app/Contents/MacOS/Project-Auto --sandbox-selftest \
  --test-provider anthropicMessages \
  --test-base-url http://127.0.0.1:3000 \
  --test-model claude-haiku-5-5 \
  --test-api-key ...
```

已验证（helper + 沙盒 App + 嵌入 pack）：

- `runtime=LinuxHelperClient`，直连 exec 返回 Debian 13 / aarch64；
- Agent 调用 `bash` → 写 `/workspace/sandbox-ok.txt` → 宿主
  `/Users/Shared/Velum/workspace` 能看到文件；
- `codesign --verify --deep --strict` 通过，App 约 150 MB。

## 开发机 CLI（可选）

```sh
./install-smolvm.sh ~/Downloads/smolvm-1.32.4-darwin-arm64.tar
cd Runtime && smolvm machine create --name velum-dev --smolfile velum.Smolfile
smolvm machine start --name velum-dev --proxy http://<宿主IP>:7890
```

pack 的 guest 磁盘是稀疏的（20G 表观、实际 MB 级）；不要用 CLI 创建的 20G/10G 机器分发
（实测会真占约 30GB）。

## 环境验收（显式入口，普通启动不会自动打开应用）

```sh
Project-Auto.app/Contents/MacOS/Project-Auto --environment-selftest
# 追加真实云端 Agent 截图/点击/输入闭环，使用已配置的 Provider：
VELUM_ENV_TEST_AGENT=1 Project-Auto.app/Contents/MacOS/Project-Auto --environment-selftest
```

测试实际启动 WebKit 和 Needle，检查点击、输入、滚动、PNG 截图、helper 书签解析、只读挂载拒写、读写挂载回写、真实文件列表/目录导航/文本预览。Needle 推理关闭遥测；包内约增加 35 MiB，默认工具路径为 Agent 直接 JSON 控制。网页事件当前为合成 DOM 事件，跨域 iframe、依赖 trusted user activation 的控件和下载不支持，错误会明确返回。

## 安全基线

- guest 内是 root（便于 init/apt）；Agent 的写/执行都经过审批。
- helper 当前不沙盒；正式分发建议用 App Group + 签名/公证，并收紧 network allowlist。
- 不要挂载整个 `$HOME`；每个 Space 只挂自己的工作区。
