import Combine
import Foundation

/// Local model identity is not a remote API endpoint. Embedding models cannot become chat providers.
nonisolated struct ManagedLocalModel: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let repo: String
    let revision: String
    let capability: String
    var engineID: String? = nil
}

@MainActor
final class LocalModelSelection: ObservableObject {
    static let shared = LocalModelSelection()
    @Published private(set) var selected: ManagedLocalModel?
    private let key = "velum.localAI.chatSelection.v1"

    private init() {
        if let data = UserDefaults.standard.data(forKey: key) {
            selected = try? JSONDecoder().decode(ManagedLocalModel.self, from: data)
        }
    }

    func select(_ model: ManagedLocalModel) {
        guard model.capability == "chat" else { return }
        selected = model
        UserDefaults.standard.set(try? JSONEncoder().encode(model), forKey: key)
    }

    func useRemoteProvider() {
        selected = nil
        UserDefaults.standard.removeObject(forKey: key)
    }
}

/// Lazy preparation permits stopping/restarting runtimes without saving a loopback URL in provider settings.
nonisolated final class ManagedLocalAIProvider: PiProvider, @unchecked Sendable {
    let providerName = "本地 MLX"
    private let model: ManagedLocalModel
    private let thinkingEnabled: Bool
    private let reasoningEffort: String?
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var client: OpenAIChatCompletionsClient?

    init(model: ManagedLocalModel, thinkingEnabled: Bool = true, reasoningEffort: String? = nil) {
        self.model = model
        self.thinkingEnabled = thinkingEnabled
        self.reasoningEffort = reasoningEffort
    }

    func stream(_ request: PiRequest) -> AsyncThrowingStream<PiStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let work = Task {
                do {
                    let manager = await EnginePackageManager.shared
                    let engineID = model.engineID ?? "mlx"
                    _ = try await manager.connection(engineID: engineID)
                    let body = try JSONSerialization.data(withJSONObject: ["model": model.id, "capability": "chat"])
                    _ = try await manager.authorizedRequest(engineID: engineID, path: "/control/load", method: "POST", body: body)
                    let connection = try await manager.connection(engineID: engineID)
                    let configuration = URLSessionConfiguration.ephemeral
                    configuration.connectionProxyDictionary = [:]
                    configuration.httpCookieStorage = nil
                    configuration.timeoutIntervalForRequest = 300
                    let session = URLSession(configuration: configuration, delegate: LocalRuntimeHTTPPolicy.shared, delegateQueue: nil)
                    let provider = OpenAIChatCompletionsClient(
                        baseURL: connection.baseURL.appendingPathComponent("v1"), apiKey: connection.token,
                        session: session,
                        localThinkingEnabled: engineID == "mlx" ? thinkingEnabled : nil,
                        localReasoningEffort: engineID == "splash" ? (thinkingEnabled ? reasoningEffort : "none") : nil)
                    setClient(provider)
                    var localRequest = request
                    localRequest.model = model.id
                    for try await event in provider.stream(localRequest) {
                        try Task.checkCancellation()
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            setTask(work)
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    func cancel() {
        lock.lock()
        let task = task
        let client = client
        lock.unlock()
        task?.cancel()
        client?.cancel()
    }

    private func setTask(_ task: Task<Void, Never>) {
        lock.lock(); self.task = task; lock.unlock()
    }
    private func setClient(_ client: OpenAIChatCompletionsClient) {
        lock.lock(); self.client = client; lock.unlock()
    }
}
