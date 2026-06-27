/*
仕様:
- 役割: 旧 Gemini 補助応答リクエストの互換窓口。runtime 呼び出しは廃止済み。
- 主な型: `GeminiSupportService`.
- 編集ポイント: 廃止済み remote 呼び出しを再有効化しないこと。
*/
import Foundation

private struct GeminiSupportRequestBody: Encodable {
    let systemInstruction: GeminiSupportSystemInstruction?
    let contents: [GeminiSupportRequestContent]
    let generationConfig: GeminiSupportGenerationConfig
}

private struct GeminiSupportSystemInstruction: Encodable {
    let parts: [GeminiSupportRequestPart]
}

private struct GeminiSupportRequestContent: Encodable {
    let role: String
    let parts: [GeminiSupportRequestPart]
}

private struct GeminiSupportRequestPart: Encodable {
    struct InlineData: Encodable {
        let mimeType: String
        let data: String
    }

    let text: String?
    let inlineData: InlineData?

    init(text: String) {
        self.text = text
        self.inlineData = nil
    }

    init(jpegData: Data) {
        self.text = nil
        self.inlineData = InlineData(
            mimeType: "image/jpeg",
            data: jpegData.base64EncodedString()
        )
    }
}

private struct GeminiSupportGenerationConfig: Encodable {
    let temperature: Double
    let maxOutputTokens: Int
}

private struct GeminiSupportResponseBody: Decodable {
    let candidates: [GeminiSupportCandidate]?
}

private struct GeminiSupportCandidate: Decodable {
    let content: GeminiSupportResponseContent?
}

private struct GeminiSupportResponseContent: Decodable {
    let parts: [GeminiSupportResponsePart]?
}

private struct GeminiSupportResponsePart: Decodable {
    let text: String?
}

private struct GeminiSupportAPIErrorEnvelope: Decodable {
    let error: GeminiSupportAPIErrorBody?
}

private struct GeminiSupportAPIErrorBody: Decodable {
    let code: Int?
    let message: String?
    let status: String?
}

enum GeminiSupportServiceError: LocalizedError {
    case disabled
    case missingAPIKey
    case invalidEndpoint
    case apiError(String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .disabled:
            return "Gemini remote は廃止済みです。"
        case .missingAPIKey:
            return "Remote API キーが見つかりません。"
        case .invalidEndpoint:
            return "Remote API の接続先を解決できません。"
        case .apiError(let message):
            return message
        case .emptyResponse:
            return "Remote API から有効な応答が返りませんでした。"
        }
    }
}

final class GeminiSupportService {
    static let shared = GeminiSupportService()

    private init() {}

    func generateSupportResponse(
        prompt: String,
        systemInstruction: String,
        images: [Data],
        modelName: String = ""
    ) async throws -> String {
        _ = (prompt, systemInstruction, images, modelName)
        throw GeminiSupportServiceError.disabled
    }

    private func extractAPIErrorMessage(from data: Data) -> String? {
        guard let envelope = try? JSONDecoder().decode(GeminiSupportAPIErrorEnvelope.self, from: data) else {
            return nil
        }
        return envelope.error?.message ?? envelope.error?.status
    }
}
