import Foundation

final class AILocalModelGateway {
    static let shared = AILocalModelGateway()

    private init() {}

    func generateReply(
        prompt: String,
        contextPrompt: String?,
        coachMode: AICoachService.CoachMode,
        reasoningMode: ReasoningMode,
        childAge: Int,
        pageInfo: AICoachService.PageInfo?,
        safetySnapshot: AICoachService.SafetySnapshot?
    ) async -> String? {
        await LocalAssistantRuntimeBridge.shared.generateReply(
            prompt: prompt,
            contextPrompt: contextPrompt,
            coachMode: coachMode,
            reasoningMode: reasoningMode,
            childAge: childAge,
            pageInfo: pageInfo,
            safetySnapshot: safetySnapshot
        )
    }
}
