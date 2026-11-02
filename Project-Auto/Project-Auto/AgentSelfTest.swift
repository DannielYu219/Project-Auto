//
//  AgentSelfTest.swift
//  Project-Auto
//
//  本地验收入口：
//  - `--agent-selftest`：Provider + AgentLoop + 只读工具，不打开窗口
//  - `--sandbox-selftest`：启动 smolvm Linux 沙盒，让 Agent 用 bash 工具做事
//
//  配置通过环境变量传入：
//  VELUM_TEST_PROVIDER / VELUM_TEST_BASE_URL / VELUM_TEST_MODEL / VELUM_TEST_API_KEY
//  VELUM_PACK_PATH / VELUM_WORKSPACE（可选）
//

import Foundation

enum AgentSelfTest {
    static func runBlocking() {
        var finished = false
        Task { @MainActor in
            await run()
            finished = true
        }
        while !finished {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    static func runSandboxBlocking() {
        var finished = false
        Task { @MainActor in
            await runSandbox()
            finished = true
        }
        while !finished {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    @MainActor
    static func runSandbox() async {
        guard let runtime = LinuxRuntimeFactory.make() else {
            print("SANDBOX SELFTEST FAILED: 找不到 velum-pack")
            return
        }
        print("runtime=\(type(of: runtime))")
        

        do {
            let started = Date()
            let direct = try await runtime.execStreaming("echo tick1; sleep 2; echo tick2; sleep 2; echo tick3", timeout: 30) { text, isError in
                print(String(format: "[stream %.2fs] %@", Date().timeIntervalSince(started), text.trimmingCharacters(in: .newlines)))
            }
            print("--- direct exec ---")
            print(direct.stdout)
            if !direct.stderr.isEmpty { print("stderr:", direct.stderr) }
            print("exit=\(direct.exitCode)")
        } catch {
            print("SANDBOX SELFTEST FAILED: \(error.localizedDescription)")
            return
        }

        let config = AgentConfig.shared
        let kind = config.effectiveProviderKind
        let endpoint = config.effectiveEndpoint
        let key = config.effectiveAPIKey
        let model = config.effectiveModel
        guard let provider = PiProviderFactory.make(kind: kind, endpoint: endpoint, apiKey: key) else {
            print("SANDBOX SELFTEST: provider 未配置，跳过 Agent 部分")
            runtime.stop()
            return
        }
        print("provider=\(kind.rawValue) model=\(model)")

        let tools: [any AgentTool] = [BashTool(runtime: runtime, onOutput: { text, isError in
            print("[agent-\(isError ? "err" : "out")] \(text.trimmingCharacters(in: .newlines))")
        })]
        let loop = AgentLoop(provider: provider,
                             tools: tools,
                             gate: AutoApprovalGate(),
                             configuration: .init(model: model,
                                                  systemPrompt: "You are a test agent in a Debian 13 Linux sandbox. The workspace is /workspace. Use the bash tool for commands. Be terse.",
                                                  maxTurns: 6,
                                                  maxTokens: 1024,
                                                  toolTimeout: 60,
                                                  temperature: nil,
                                                  cacheKey: "sandbox-selftest",
                                                  cacheRetention: .short))
        let prompt = """
        请用 bash 工具完成三件事：
        1) 运行 uname -a 和 cat /etc/os-release | head -2；
        2) 在 /workspace 写 sandbox-ok.txt，内容包含当前时间；
        3) 运行 ls -la /workspace。
        最后用一句中文总结。
        """
        var finalText = ""
        do {
            for try await event in loop.run(prompt: prompt) {
                switch event {
                case .textDelta(let delta):
                    finalText += delta
                case .toolCall(let call):
                    print("toolCall: \(call.name) \(PiJSON.encodeString(call.arguments))")
                case .toolResult(let result):
                    print("toolResult: error=\(result.isError) \(result.content.prefix(400))")
                case .usage(let usage):
                    print(String(format: "usage input=%d output=%d cacheRead=%d cacheWrite=%d",
                                 usage.input, usage.output, usage.cacheRead, usage.cacheWrite))
                case .failed(let message):
                    print("agent error: \(message)")
                default:
                    break
                }
            }
        } catch {
            print("agent failed: \(error.localizedDescription)")
        }
        print("--- final text ---")
        print(finalText)

        let sandboxFile = runtime.workspaceURL.appendingPathComponent("sandbox-ok.txt")
        if let content = try? String(contentsOf: sandboxFile, encoding: .utf8) {
            print("host sees /workspace/sandbox-ok.txt: \(content.trimmingCharacters(in: .whitespacesAndNewlines))")
        } else {
            print("host does not see sandbox-ok.txt")
        }
        runtime.stop()
    }

    @MainActor
    static func run() async {
        let config = AgentConfig.shared
        let kind = config.effectiveProviderKind
        let endpoint = config.effectiveEndpoint
        let key = config.effectiveAPIKey
        let model = config.effectiveModel
        print("provider=\(kind.rawValue) endpoint=\(endpoint) model=\(model)")

        guard let provider = PiProviderFactory.make(kind: kind, endpoint: endpoint, apiKey: key) else {
            print("SELFTEST FAILED: provider 配置不完整")
            return
        }

        let tools: [any AgentTool] = ProcessInfo.processInfo.environment["VELUM_TEST_NO_TOOLS"] == "1"
            ? []
            : [ListDirectoryTool(sandbox: .default), ReadFileTool(sandbox: .default)]
        let loop = AgentLoop(provider: provider,
                             tools: tools,
                             gate: RiskPolicyGate(broker: nil),
                             configuration: .init(model: model,
                                                  systemPrompt: "You are a terse test assistant. Reply briefly.",
                                                  maxTurns: 4,
                                                  maxTokens: 256,
                                                  toolTimeout: 30,
                                                  temperature: nil,
                                                  cacheKey: "selftest-session-1",
                                                  cacheRetention: .short))

        // 长前缀（>1024 tokens）才能触发 Anthropic/OpenAI 的最小可缓存长度。
        // 每次运行用唯一前缀，避免命中网关上一轮遗留的缓存，才能看出「第一次写、第二次读」。
        let probe = UUID().uuidString
        let longPrefix = String(repeating: "Cache probe \(probe). Prefix stability is the only thing that matters. ", count: 140)
        let prompt = ProcessInfo.processInfo.environment["VELUM_TEST_PROMPT"]
            ?? (longPrefix + "\n\nReply with exactly: hello")

        // 两次完全相同的请求：第二次应命中第一次写入的前缀缓存。
        for turn in 1...2 {
            print("--- turn \(turn) ---")
            var text = ""
            var usage: PiUsage?
            var failed: String?
            do {
                for try await event in loop.run(prompt: prompt) {
                    switch event {
                    case .textDelta(let delta): text += delta
                    case .usage(let value): usage = value
                    case .toolCall(let call):
                        print("toolCall: \(call.name) args=\(PiJSON.encodeString(call.arguments))")
                    case .toolResult(let result):
                        print("toolResult: \(result.toolName) error=\(result.isError) content=\(result.content.prefix(200))")
                    case .failed(let message): failed = message
                    default: break
                    }
                }
            } catch {
                failed = error.localizedDescription
            }
            print("text: \(text)")
            if let usage {
                print(String(format: "usage input=%d output=%d cacheRead=%d cacheWrite=%d hit=%.1f%%",
                             usage.input, usage.output, usage.cacheRead, usage.cacheWrite, usage.cacheHitRate * 100))
            }
            if let failed { print("error: \(failed)") }
        }
    }
}
