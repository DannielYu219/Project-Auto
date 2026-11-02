import Combine
import Foundation

nonisolated struct RuntimeModelRecord: Codable, Identifiable, Sendable {
    let id: String
    let repo: String?
    let revision: String?
    let capability: String?
    var engineID: String? = nil
    var key: String { (engineID ?? "mlx") + ":" + id }
    var selection: ManagedLocalModel {
        ManagedLocalModel(id: id, repo: repo ?? id, revision: revision ?? "", capability: capability ?? "chat", engineID: engineID ?? "mlx")
    }
}

@MainActor
final class LocalModelLibrary: ObservableObject {
    static let shared = LocalModelLibrary()
    @Published private(set) var models: [RuntimeModelRecord] = []
    @Published private(set) var message = ""
    @Published private(set) var downloading = false
    private let cacheKey = "velum.localAI.models.v1"

    private init() {
        if let data = UserDefaults.standard.data(forKey: cacheKey),
           let values = try? JSONDecoder().decode([RuntimeModelRecord].self, from: data) {
            models = values
        }
    }

    func refresh() async {
        let engineID = EnginePackageManager.shared.selectedEngineID
        do {
            let data = try await EnginePackageManager.shared.authorizedRequest(engineID: engineID, path: "/v1/models")
            let decoder = JSONDecoder()
            struct Response: Decodable { let data: [RuntimeModelRecord] }
            let installed = try decoder.decode(Response.self, from: data).data.map { value in
                var model = value
                model.engineID = engineID
                return model
            }
            models.removeAll { ($0.engineID ?? "mlx") == engineID }
            models += installed
            if let cached = try? JSONEncoder().encode(models) { UserDefaults.standard.set(cached, forKey: cacheKey) }
            message = "已安装 \(models.count) 个模型"
        } catch { message = error.localizedDescription }
    }

    func download(repo: String, revision: String, capability: String) async {
        guard !downloading else { return }
        downloading = true
        defer { downloading = false }
        do {
            let manager = EnginePackageManager.shared
            let engineID = manager.selectedEngineID
            _ = try await manager.connection(engineID: engineID)
            let body = try JSONSerialization.data(withJSONObject: ["repo": repo, "revision": revision, "capability": capability])
            let data = try await manager.authorizedRequest(engineID: engineID, path: "/control/download", method: "POST", body: body)
            guard let job = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let jobID = job["job_id"] as? String else { throw LocalRuntimeError.unavailable("下载任务响应无效") }
            while true {
                try Task.checkCancellation()
                let state = try await manager.authorizedRequest(engineID: engineID, path: "/control/jobs/\(jobID)")
                guard let value = try JSONSerialization.jsonObject(with: state) as? [String: Any] else {
                    throw LocalRuntimeError.unavailable("下载状态无效")
                }
                let status = value["status"] as? String ?? "unknown"
                let bytes = value["downloaded_bytes"] as? Int64 ?? 0
                message = "\(repo) · \(status) · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
                if status == "completed" { break }
                if status == "failed" || status == "cancelled" {
                    throw LocalRuntimeError.unavailable(value["error"] as? String ?? "模型下载未完成")
                }
                try await Task.sleep(for: .seconds(1))
            }
            await refresh()
        } catch { message = error.localizedDescription }
    }

    func load(_ model: RuntimeModelRecord) async {
        do {
            let manager = EnginePackageManager.shared
            let engineID = model.engineID ?? "mlx"
            let body = try JSONSerialization.data(withJSONObject: ["model": model.id, "capability": model.capability ?? "chat"])
            _ = try await manager.authorizedRequest(engineID: engineID, path: "/control/load", method: "POST", body: body)
            manager.selectedEngineID = engineID
            if model.capability != "embeddings" { LocalModelSelection.shared.select(model.selection) }
            message = "已加载 \(model.repo ?? model.id)"
        } catch { message = error.localizedDescription }
    }
}
