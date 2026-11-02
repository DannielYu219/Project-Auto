import Foundation

/// Narrow XPC bridge to the external-runtime lifecycle service. No shell or arbitrary executable API.
nonisolated final class LocalAIConnectionBridge: @unchecked Sendable {
    static let shared = LocalAIConnectionBridge()
    private let lock = NSLock()
    private var connection: NSXPCConnection?

    @MainActor
    static func install() {
        LocalRuntimeManager.shared.requestBroker = { json in
            try await shared.request(json)
        }
    }

    private func currentConnection() -> NSXPCConnection {
        lock.lock()
        defer { lock.unlock() }
        if let connection { return connection }
        let created = NSXPCConnection(serviceName: LinuxHelperClient.serviceName)
        created.remoteObjectInterface = NSXPCInterface(with: LinuxHelperProtocol.self)
        created.invalidationHandler = { [weak self] in
            self?.lock.lock()
            self?.connection = nil
            self?.lock.unlock()
        }
        created.resume()
        connection = created
        return created
    }

    func requestStopOnTermination() {
        let connection = currentConnection()
        let proxy = connection.remoteObjectProxy as? LinuxHelperProtocol
        proxy?.splitEngineRequest(requestJSON: "{\"op\":\"stop\"}", reply: { _, _ in })
        proxy?.localRuntimeRequest(requestJSON: "{\"op\":\"stop\"}", reply: { _, _ in })
    }

    func splitRequest(_ json: String) async throws -> String {
        let connection = currentConnection()
        return try await withCheckedThrowingContinuation { continuation in
            let reply = RuntimeReplyOnce(continuation)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ reply.fail($0) }) as? LinuxHelperProtocol else {
                reply.fail(PiProviderError.transport("独立引擎服务不可用")); return
            }
            proxy.splitEngineRequest(requestJSON: json) { response, error in
                if let error { reply.fail(PiProviderError.transport(error)) }
                else if let response { reply.succeed(response) }
                else { reply.fail(PiProviderError.invalidResponse("引擎没有返回结果")) }
            }
        }
    }

    func request(_ json: String) async throws -> String {
        let connection = currentConnection()
        return try await withCheckedThrowingContinuation { continuation in
            let reply = RuntimeReplyOnce(continuation)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ reply.fail($0) }) as? LinuxHelperProtocol else {
                reply.fail(PiProviderError.transport("本地运行时服务不可用")); return
            }
            proxy.localRuntimeRequest(requestJSON: json) { response, error in
                if let error { reply.fail(PiProviderError.transport(error)) }
                else if let response { reply.succeed(response) }
                else { reply.fail(PiProviderError.invalidResponse("运行时没有返回结果")) }
            }
        }
    }
}

private nonisolated final class RuntimeReplyOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?
    init(_ continuation: CheckedContinuation<String, Error>) { self.continuation = continuation }
    func succeed(_ value: String) { finish(.success(value)) }
    func fail(_ error: Error) { finish(.failure(error)) }
    private func finish(_ result: Result<String, Error>) {
        lock.lock()
        let next = continuation
        continuation = nil
        lock.unlock()
        next?.resume(with: result)
    }
}
