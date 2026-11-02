import Foundation

/// App-local embedding API: no endpoint/key fields and a fixed model revision.
@MainActor
final class LocalEmbeddingService {
    static let shared = LocalEmbeddingService()
    static let repo = "mlx-community/embeddinggemma-2-4bit"
    static let revision = "8ab839e127cb8cb305edd71fb7a02c82f2d49ab3"
    static var modelID: String { repo + "@" + revision }

    enum Purpose: String, Sendable { case query, document }

    func embed(_ texts: [String], purpose: Purpose, dimensions: Int = 768) async throws -> [[Double]] {
        guard !texts.isEmpty, texts.count <= 256, [128, 256, 512, 768].contains(dimensions) else {
            throw LocalRuntimeError.unavailable("向量输入数量或维度无效。")
        }
        let body = try JSONSerialization.data(withJSONObject: [
            "model": Self.modelID, "input": texts, "task": purpose.rawValue, "dimensions": dimensions
        ])
        let data = try await EnginePackageManager.shared.authorizedRequest(engineID: "mlx", path: "/v1/embeddings", method: "POST", body: body)
        struct Row: Decodable { let index: Int; let embedding: [Double] }
        struct Response: Decodable { let data: [Row] }
        let rows = try JSONDecoder().decode(Response.self, from: data).data.sorted { $0.index < $1.index }
        guard rows.count == texts.count, rows.enumerated().allSatisfy({ $0.offset == $0.element.index }),
              rows.allSatisfy({ $0.embedding.count == dimensions && $0.embedding.allSatisfy(\.isFinite) }) else {
            throw LocalRuntimeError.unavailable("模型返回了无效向量。")
        }
        return rows.map(\.embedding)
    }
}
