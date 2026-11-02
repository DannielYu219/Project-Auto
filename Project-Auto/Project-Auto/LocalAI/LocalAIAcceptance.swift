import Foundation

/// Isolated, explicit acceptance entry: does not open desktop applications or alter provider selection.
@MainActor
enum LocalAIAcceptance {
    static func runBlocking() {
        var done = false
        var result = 1
        Task { @MainActor in
            do { try await run(); result = 0 }
            catch { print("LOCAL AI FAIL: \(error)") }
            done = true
        }
        while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        exit(Int32(result))
    }

    private static func run() async throws {
        let manager = LocalRuntimeManager.shared
        let root = URL(fileURLWithPath: "/Users/Shared/Velum/ai")
        let archive = root.appendingPathComponent("incoming/velum-mlx-python-2026.11.02-dev.2-macos-arm64.tar.gz")
        try await manager.install(from: archive, allowDevelopmentAdHoc: true)
        guard !manager.installedRuntimes.isEmpty else { throw LocalRuntimeError.unavailable("install not recorded") }
        print("XPC INSTALL PASS \(manager.installedRuntimes.count) runtime(s)")
        try await manager.rollback()
        guard manager.installedRuntimes.first(where: \.isActive)?.version == "2026.11.02-dev" else {
            throw LocalRuntimeError.unavailable("rollback did not retain previous runtime")
        }
        try await manager.rollback()
        guard manager.installedRuntimes.first(where: \.isActive)?.version == "2026.11.02-dev.2" else {
            throw LocalRuntimeError.unavailable("rollback forward did not restore latest runtime")
        }
        print("XPC VERSION ROLLBACK PASS")
        try await manager.configureProxy("http://127.0.0.1:7890")
        try await manager.start()
        defer { Task { await manager.stop() } }
        let connection = try await manager.connection()
        let (data, response) = try await URLSession.shared.data(from: connection.baseURL.appendingPathComponent("health"))
        guard (response as? HTTPURLResponse)?.statusCode == 401 else { throw LocalRuntimeError.unavailable("unauthorized request unexpectedly accepted: \(data.count)") }
        print("LOOPBACK AUTH PASS")
        await LocalModelLibrary.shared.refresh()
        let models = LocalModelLibrary.shared.models
        guard let chat = models.first(where: { $0.capability == "chat" }),
              let embed = models.first(where: { $0.repo == "mlx-community/embeddinggemma-2-4bit" }) else {
            throw LocalRuntimeError.unavailable("required external model snapshots not registered")
        }
        let provider = ManagedLocalAIProvider(model: chat.selection, thinkingEnabled: false)
        let request = PiRequest(model: chat.id, messages: [.user("Reply with exactly the word Hello.")], maxTokens: 512)
        var text = ""
        for try await event in provider.stream(request) {
            if case .textDelta(let value) = event { text += value }
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalRuntimeError.unavailable("empty local PiProvider generation")
        }
        print("LOCAL PIPROVIDER PASS: \(text)")
        let toolSpec = PiToolSpec(name: "get_weather", description: "Get weather for a city", parameters: .object([
            "type": .string("object"), "properties": .object(["city": .object(["type": .string("string")])]),
            "required": .array([.string("city")])
        ]))
        let toolRequest = PiRequest(model: chat.id,
            messages: [.system("You must use the get_weather tool for any weather question."), .user("What is the weather in Paris? Call get_weather with city Paris.")],
            tools: [toolSpec], maxTokens: 256, temperature: 0)
        var foundTool = false
        for try await event in provider.stream(toolRequest) {
            if case .toolCallEnd(_, let call) = event, call.name == "get_weather", call.arguments["city"]?.stringValue == "Paris" {
                foundTool = true
            }
        }
        guard foundTool else { throw LocalRuntimeError.unavailable("local tool-call decoding failed") }
        print("LOCAL TOOL CALL PASS get_weather(city: Paris)")
        let body = try JSONSerialization.data(withJSONObject: [
            "model": embed.id,
            "input": ["task: search result | query: Which planet is known as the Red Planet?",
                      "title: none | text: Mars is known as the Red Planet.",
                      "title: none | text: Venus is often called Earth's twin."]
        ])
        let result = try await manager.authorizedRequest(path: "/v1/embeddings", method: "POST", body: body)
        let object = try JSONSerialization.jsonObject(with: result) as? [String: Any]
        guard let rows = object?["data"] as? [[String: Any]], rows.count == 3 else {
            throw LocalRuntimeError.unavailable("embedding response invalid")
        }
        let vectors = rows.compactMap { $0["embedding"] as? [Double] }
        guard vectors.count == 3, vectors.allSatisfy({ $0.count == 768 && $0.allSatisfy(\.isFinite) }) else {
            throw LocalRuntimeError.unavailable("embedding shape or finite check failed")
        }
        let mars = zip(vectors[0], vectors[1]).reduce(0.0) { $0 + $1.0 * $1.1 }
        let venus = zip(vectors[0], vectors[2]).reduce(0.0) { $0 + $1.0 * $1.1 }
        guard mars > venus else { throw LocalRuntimeError.unavailable("embedding retrieval ordering failed") }
        print("EMBEDDING PASS 768D Mars=\(mars) Venus=\(venus)")
        let appVectors = try await LocalEmbeddingService.shared.embed(["火星为什么叫红色星球？"], purpose: .query, dimensions: 256)
        guard appVectors.count == 1, appVectors[0].count == 256 else {
            throw LocalRuntimeError.unavailable("App embedding service failed")
        }
        print("APP EMBEDDING SERVICE PASS 256D")
        await manager.stop()
        guard !manager.status.isRunning else { throw LocalRuntimeError.unavailable("runtime did not stop") }
        print("XPC STOP PASS")
        print("LOCAL AI ACCEPTANCE PASS")
    }
}
