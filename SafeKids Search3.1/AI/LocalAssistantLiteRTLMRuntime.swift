/*
仕様:
- 役割: iOS 向け LiteRT-LM 推論経路の薄いアダプタ。
- 主な型: `LocalAssistantLiteRTLMRuntime`.
- 編集ポイント: Google AI Edge LiteRT-LM の iOS SDK / ネイティブバイナリを接続したら
  `isRuntimeLinked` と `generate(...)` の中身を差し替える。
*/
import Foundation
// LiteRT-LM integration enforcement (optional):
// Define -DUSE_LITERTLM in the iOS target's "Other Swift Flags" to require the SDK at build time.
// Define -DVIUK_ENABLE_LITERTLM_NATIVE only when the native Engine init path is stable on real iOS devices.
#if os(iOS) && !targetEnvironment(simulator)
#if USE_LITERTLM
#if !canImport(LiteRTLM)
#error("USE_LITERTLM is set but the LiteRTLM SDK is not linked. Add the LiteRT-LM package/xcframework to the iOS target.")
#endif
#endif
#if canImport(LiteRTLM)
import LiteRTLM
#endif
#endif

struct LocalAssistantLiteRTLMRequest {
    let prompt: String
    let systemPrompt: String?
    let modelPath: String
    let maxTokens: Int
    let temperature: Float
    let topP: Float
    let topK: Int
    let seed: UInt32
}

final class LocalAssistantLiteRTLMRuntime: @unchecked Sendable {
    static let shared = LocalAssistantLiteRTLMRuntime()

    private init() {}

    nonisolated var unavailableReason: String {
#if os(iOS) && !targetEnvironment(simulator)
#if VIUK_ENABLE_LITERTLM_NATIVE
#if canImport(LiteRTLM)
        return ""
#else
        return "LiteRT-LM SDK がこのビルドにリンクされていません。"
#endif
#else
        return "LiteRT-LM native runtime はこのiOSビルドでは停止中です。Engine初期化で実機クラッシュするため、安定確認できるまでローカル実行に入りません。"
#endif
#else
        return "LiteRT-LM runtime はこのビルドに含まれていません。"
#endif
    }

    nonisolated var isRuntimeLinked: Bool {
#if os(iOS) && !targetEnvironment(simulator) && VIUK_ENABLE_LITERTLM_NATIVE
#if canImport(LiteRTLM)
        return true
#else
        return false
#endif
#else
        return false
#endif
    }

    nonisolated func canRunModel(atPath modelPath: String) -> Bool {
#if os(iOS)
        guard isRuntimeLinked else { return false }
        return modelPath.lowercased().hasSuffix(".litertlm")
#else
        return false
#endif
    }

    nonisolated func performSelfCheck(modelPath: String) -> VIUKEmbeddedRuntimeResult {
        guard canRunModel(atPath: modelPath) else {
            return VIUKEmbeddedRuntimeResult(
                success: false,
                text: nil,
                errorMessage: unavailableReason
            )
        }

        return generate(
            LocalAssistantLiteRTLMRequest(
                prompt: "これは Gemma 4 E2B LiteRT-LM runtime check です。必ず `ok` とだけ短く返答してください。",
                systemPrompt: "あなたは VIUK AI tiny の LiteRT-LM runtime check です。出力は必ず `ok` のみです。",
                modelPath: modelPath,
                maxTokens: 16,
                temperature: 0,
                topP: 0.9,
                topK: 20,
                seed: 7
            )
        )
    }

    nonisolated func generate(_ request: LocalAssistantLiteRTLMRequest) -> VIUKEmbeddedRuntimeResult {
        guard canRunModel(atPath: request.modelPath) else {
            return VIUKEmbeddedRuntimeResult(
                success: false,
                text: nil,
                errorMessage: unavailableReason
            )
        }

#if os(iOS) && !targetEnvironment(simulator) && VIUK_ENABLE_LITERTLM_NATIVE
#if canImport(LiteRTLM)
        return runLiteRTLM(request)
#else
        return VIUKEmbeddedRuntimeResult(
            success: false,
            text: nil,
            errorMessage: "LiteRT-LM runtime はこのビルドに含まれていません。"
        )
#endif
#else
        return VIUKEmbeddedRuntimeResult(
            success: false,
            text: nil,
            errorMessage: "LiteRT-LM runtime はこのビルドに含まれていません。"
        )
#endif
    }

#if os(iOS) && !targetEnvironment(simulator) && VIUK_ENABLE_LITERTLM_NATIVE
#if canImport(LiteRTLM)
	    nonisolated private func runLiteRTLM(_ request: LocalAssistantLiteRTLMRequest) -> VIUKEmbeddedRuntimeResult {
        let semaphore = DispatchSemaphore(value: 0)
        var completedResult = VIUKEmbeddedRuntimeResult(
            success: false,
            text: nil,
            errorMessage: "LiteRT-LM runtime が応答しませんでした。"
        )

        Task.detached(priority: .userInitiated) {
            do {
                let cacheURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("VIUKLiteRTLMCache", isDirectory: true)
                try? FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)

                let sizedRequest = self.runtimeSizedRequest(request)
                let maxNumTokens = max(768, min(sizedRequest.maxTokens + 768, 2048))
                let cpuThreadCount = min(max(ProcessInfo.processInfo.activeProcessorCount / 2, 2), 4)
                var lastError: Error?

                do {
                    let text = try await self.generateText(
                        sizedRequest,
                        backend: .gpu,
                        maxNumTokens: maxNumTokens,
                        cachePath: cacheURL.path
                    )
                    let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    completedResult = VIUKEmbeddedRuntimeResult(
                        success: !cleaned.isEmpty,
                        text: cleaned.isEmpty ? nil : cleaned,
                        errorMessage: cleaned.isEmpty ? "LiteRT-LM runtime の応答が空でした。" : nil
                    )
                    semaphore.signal()
                    return
                } catch {
                    lastError = error
                }

                do {
                    let text = try await self.generateText(
                        sizedRequest,
                        backend: .cpu(threadCount: cpuThreadCount),
                        maxNumTokens: maxNumTokens,
                        cachePath: cacheURL.path
                    )
                    let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    completedResult = VIUKEmbeddedRuntimeResult(
                        success: !cleaned.isEmpty,
                        text: cleaned.isEmpty ? nil : cleaned,
                        errorMessage: cleaned.isEmpty ? "LiteRT-LM runtime の応答が空でした。" : nil
                    )
                    semaphore.signal()
                    return
                } catch {
                    lastError = error
                }

                completedResult = VIUKEmbeddedRuntimeResult(
                    success: false,
                    text: nil,
                    errorMessage: "LiteRT-LM runtime error: \(lastError?.localizedDescription ?? "unknown error")"
                )
            }
            semaphore.signal()
        }

	        _ = semaphore.wait(timeout: .now() + 60)
	        return completedResult
    }

	    nonisolated private func generateText(
        _ request: LocalAssistantLiteRTLMRequest,
        backend: Backend,
        maxNumTokens: Int,
        cachePath: String
    ) async throws -> String {
                let engineConfig = try EngineConfig(
                    modelPath: request.modelPath,
            backend: backend,
            maxNumTokens: maxNumTokens,
            cacheDir: cachePath
                )
                let engine = Engine(engineConfig: engineConfig)
                try await engine.initialize()
                let sampler = try SamplerConfig(
                    topK: max(request.topK, 1),
                    topP: max(0, min(request.topP, 1)),
                    temperature: max(request.temperature, 0),
                    seed: Int(request.seed)
                )
                let conversation = try await engine.createConversation(
                    with: ConversationConfig(
                        systemMessage: request.systemPrompt.map { Message($0, role: .system) },
                        samplerConfig: sampler
                    )
                )
                let response = try await conversation.sendMessage(
                    Message(request.prompt)
                )
        return response.toString
    }

	    nonisolated private func runtimeSizedRequest(_ request: LocalAssistantLiteRTLMRequest) -> LocalAssistantLiteRTLMRequest {
	        LocalAssistantLiteRTLMRequest(
	            prompt: clipped(request.prompt, maxCharacters: 6_000),
	            systemPrompt: request.systemPrompt.map { clipped($0, maxCharacters: 2_000) },
	            modelPath: request.modelPath,
	            maxTokens: min(request.maxTokens, 512),
	            temperature: request.temperature,
            topP: request.topP,
            topK: request.topK,
            seed: request.seed
        )
    }

	    nonisolated private func clipped(_ value: String, maxCharacters: Int) -> String {
        guard value.count > maxCharacters else { return value }
        let suffix = value.suffix(maxCharacters)
        return """
        以下は長すぎる文脈の末尾です。直近のユーザー質問を優先して答えてください。

        \(suffix)
        """
    }
#endif
#endif

    private func combinedPrompt(for request: LocalAssistantLiteRTLMRequest) -> String {
        guard let systemPrompt = request.systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
              !systemPrompt.isEmpty else {
            return request.prompt
        }
        return """
        \(systemPrompt)

        ユーザー:
        \(request.prompt)
        """
    }
}
