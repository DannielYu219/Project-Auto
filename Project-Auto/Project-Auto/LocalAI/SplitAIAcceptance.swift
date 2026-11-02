import Foundation

@MainActor
enum SplitAIAcceptance {
    static func runBlocking() {
        var done = false
        var code: Int32 = 1
        Task {
            do { try await run(); code = 0 }
            catch { print("SPLIT APP FAIL \(error)") }
            done = true
        }
        while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        exit(code)
    }

    private static func run() async throws {
        let manager = EnginePackageManager.shared
        let incoming = URL(fileURLWithPath: "/Users/Shared/Velum/ai/engines/incoming")
        guard let base = manager.pythonBaseURL,
              !FileManager.default.fileExists(atPath: base.appendingPathComponent("python/lib/python3.12/site-packages/mlx").path) else {
            throw SplitEngineError.invalid("App base contains an engine")
        }
        try await manager.install(from: incoming.appendingPathComponent("velum-engine-mlx-2026.11.02-split.1-macos-arm64.tar.gz"), allowDevelopment: true)
        try await manager.start(engineID: "mlx")
        manager.selectedEngineID = "mlx"
        await LocalModelLibrary.shared.refresh()
        guard let chat = LocalModelLibrary.shared.models.first(where: { $0.capability == "chat" && ($0.engineID ?? "mlx") == "mlx" }) else {
            throw SplitEngineError.unavailable("No external MLX chat model")
        }
        let provider = ManagedLocalAIProvider(model: chat.selection, thinkingEnabled: false)
        var text = ""
        for try await event in provider.stream(PiRequest(model: chat.id, messages: [.user("Reply exactly Hello.")], maxTokens: 64, temperature: 0)) {
            if case .textDelta(let next) = event { text += next }
        }
        guard !text.isEmpty else { throw SplitEngineError.unavailable("empty split chat") }
        print("SPLIT APP MLX CHAT PASS \(text)")
        let vectors = try await LocalEmbeddingService.shared.embed(["火星为什么叫红色星球？"], purpose: .query, dimensions: 256)
        guard vectors.count == 1, vectors[0].count == 256 else { throw SplitEngineError.invalid("embedding dimensions") }
        print("SPLIT APP EMBEDDING PASS 256D")
        await manager.stop()
        try await manager.install(from: incoming.appendingPathComponent("velum-engine-custom-echo-2026.11.02-split.1-macos-arm64.tar.gz"), allowDevelopment: true)
        try await manager.start(engineID: "custom-echo")
        let info = try await manager.connection(engineID: "custom-echo")
        let (_, response) = try await URLSession.shared.data(from: info.baseURL.appendingPathComponent("health"))
        guard (response as? HTTPURLResponse)?.statusCode == 401 else { throw SplitEngineError.invalid("auth") }
        print("SPLIT APP CUSTOM ENGINE AUTH/START PASS")
        await manager.stop()
        if ProcessInfo.processInfo.arguments.contains("--splash-check") {
            try await manager.install(from: incoming.appendingPathComponent("velum-engine-splash-1.5.0-velum.2.tar.gz"), allowDevelopment: true)
            manager.downloadProxy = "http://127.0.0.1:7890"
            try await manager.start(engineID: "splash")
            manager.selectedEngineID = "splash"
            let data = try await manager.authorizedRequest(engineID: "splash", path: "/health")
            print("SPLIT APP SPLASH HEALTH PASS \(String(decoding: data, as: UTF8.self))")
            let downloadBody = try JSONSerialization.data(withJSONObject: [
                "repo": "prism-ml/Ternary-Bonsai-2-27B-gguf",
                "revision": "94dd51cdbbec5309ed8b76a12f3268bc4fdceb93", "capability": "chat"
            ])
            let jobData = try await manager.authorizedRequest(engineID: "splash", path: "/control/download", method: "POST", body: downloadBody)
            guard let job = try JSONSerialization.jsonObject(with: jobData) as? [String: Any], let id = job["job_id"] as? String else {
                throw SplitEngineError.invalid("Splash preparation job invalid")
            }
            let deadline = Date().addingTimeInterval(300)
            while true {
                let statusData = try await manager.authorizedRequest(engineID: "splash", path: "/control/jobs/\(id)")
                let value = try JSONSerialization.jsonObject(with: statusData) as? [String: Any] ?? [:]
                if value["status"] as? String == "completed" { break }
                if value["status"] as? String == "failed" { throw SplitEngineError.unavailable(String(describing: value)) }
                guard Date() < deadline else { throw SplitEngineError.unavailable("Splash preparation timeout") }
                try await Task.sleep(for: .seconds(1))
            }
            await LocalModelLibrary.shared.refresh()
            guard let splashModel = LocalModelLibrary.shared.models.first(where: { $0.engineID == "splash" }) else {
                throw SplitEngineError.unavailable("No Splash model registered")
            }
            let splash = ManagedLocalAIProvider(model: splashModel.selection, thinkingEnabled: false)
            var output = ""
            for try await event in splash.stream(PiRequest(model: splashModel.id, messages: [.user("Reply with exactly SPLASH_OK, no other text.")], maxTokens: 64, temperature: 0)) {
                if case .textDelta(let next) = event { output += next }
            }
            guard output.contains("SPLASH_OK") else { throw SplitEngineError.unavailable("Splash inference failed: \(output)") }
            print("SPLIT APP SPLASH INFERENCE PASS \(output)")
            await manager.stop()
        }
        manager.selectedEngineID = "mlx"
        print("SPLIT APP ACCEPTANCE PASS")
    }
}
