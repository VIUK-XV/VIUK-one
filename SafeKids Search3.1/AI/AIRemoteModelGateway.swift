/*
仕様:
- 役割: 旧リモートAIモデル通信の互換窓口。AI Studio runtime では廃止済み。
- 主な型: `AIRemoteModelGateway`, `AIRemoteGatewayResponse`.
- 編集ポイント: リモートAPI通信、キー解決順、レスポンス共通処理を変えるときに触る。
*/
import Foundation

struct AIRemoteGatewayResponse {
    let data: Data
    let statusCode: Int
    let responseBody: String
}

final class AIRemoteModelGateway {
    static let shared = AIRemoteModelGateway()

    private init() {}

    func availableGeminiAPIKeys() -> [String] {
        []
    }

    func performJSONRequest<Request: Encodable>(
        url: URL,
        apiKey: String,
        body: Request
    ) async throws -> AIRemoteGatewayResponse {
        _ = (url, apiKey, body)
        throw URLError(.unsupportedURL)
    }

    func performStreamingJSONRequest<Request: Encodable>(
        url: URL,
        apiKey: String,
        body: Request,
        onEventData: @escaping @Sendable (Data) async -> Void
    ) async throws -> AIRemoteGatewayResponse {
        _ = (url, apiKey, body, onEventData)
        throw URLError(.unsupportedURL)
    }
}
