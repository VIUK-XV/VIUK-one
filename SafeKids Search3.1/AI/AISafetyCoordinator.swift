/*
仕様:
- 役割: SML、外部分類、プロンプト安全方針を束ねる安全判定の集約入口。
- 主な型: `AISafetyCoordinator`.
- 編集ポイント: 最終判定閾値、補助分類器の扱い、システム向け安全ガイダンスを変えるときに触る。
*/
import Foundation

final class AISafetyCoordinator {
    static let shared = AISafetyCoordinator()

    private let sml = UltraLightSafetySML.shared
    private let secretStore = AISecretStore.shared

    private init() {}

    func buildPageSnapshot(from pageInfo: AICoachService.PageInfo?) -> AICoachService.SafetySnapshot? {
        guard let pageInfo else { return nil }

        let evaluation = sml.evaluate(
            text: [pageInfo.title, pageInfo.content ?? ""].joined(separator: " "),
            url: pageInfo.url
        )

        guard let topSignal = evaluation.topSignal else {
            return nil
        }

        let matched = topSignal.matchedKeywords.prefix(4).joined(separator: ", ")
        let detectedKeywords = matched.isEmpty ? "なし" : matched

        if topSignal.isLikelyFalsePositive {
            let level = topSignal.probability < 0.74 ? "安全寄り" : "注意"
            let dampening = topSignal.dampeningKeywords.prefix(3).joined(separator: ", ")
            let contextSuffix = dampening.isEmpty
                ? "解説や相談の文脈も含まれていそうです。"
                : "ただし \(dampening) のような解説寄りの文脈も強く、誤認識の可能性があります。"
            return AICoachService.SafetySnapshot(
                level: level,
                summary: "\(LocalAssistantModelProfile.modelName) 向けSMLは \(topSignal.category) 関連語を検知しました。検知語: \(detectedKeywords)。\(contextSuffix)",
                recommendations: defaultRecommendations(for: topSignal.category)
            )
        }

        if topSignal.probability >= 0.82 {
            return AICoachService.SafetySnapshot(
                level: "要注意",
                summary: "\(LocalAssistantModelProfile.modelName) 向けSMLが \(topSignal.category) の可能性を高めに検知しました。検知語: \(detectedKeywords)",
                recommendations: focusedRecommendations(for: topSignal.category)
            )
        }

        if topSignal.probability >= 0.62 {
            return AICoachService.SafetySnapshot(
                level: "注意",
                summary: "\(LocalAssistantModelProfile.modelName) 向けSMLが \(topSignal.category) の可能性を中程度に検知しました。検知語: \(detectedKeywords)",
                recommendations: defaultRecommendations(for: topSignal.category)
            )
        }

        return nil
    }

    func requestSupplementalClassificationIfNeeded(
        for pageInfo: AICoachService.PageInfo?,
        currentSnapshot: AICoachService.SafetySnapshot?,
        completion: @escaping (AICoachService.SafetySnapshot?) -> Void
    ) {
        guard let pageInfo,
              let textRazorAPIKey = secretStore.configuredTextRazorAPIKey(),
              !textRazorAPIKey.isEmpty,
              let content = pageInfo.content,
              content.count >= 180 else {
            return
        }

        TextRazorClassifier(apiKey: textRazorAPIKey).classifyPageContent(text: content) { result in
            guard case .success(let classification) = result else { return }
            let assessment = classification.dangerAssessment()
            guard assessment.isDangerous else { return }

            let snapshot = self.mergeSupplementalAssessment(
                categories: assessment.detectedCategories,
                currentSnapshot: currentSnapshot
            )
            completion(snapshot)
        }
    }

    func safetyInstructionLines(
        coachMode: AICoachService.CoachMode,
        childAge: Int,
        filterLevel: String,
        snapshot: AICoachService.SafetySnapshot?
    ) -> [String] {
        var lines: [String] = [
            "安全制御は SafetyCoordinator の判定を前提に従ってください。",
            "危険行為、違法行為、詐欺、性的搾取、自傷他害の具体的な実行手順は出さないでください。",
            "安全上グレーな内容では、まず危険性を短く説明し、代替案や安全な行動へ誘導してください。"
        ]

        if coachMode == .child {
            lines.append("\(childAge)歳向けに、刺激の強い表現や露骨な表現は避けてください。")
        } else if coachMode == .guardian {
            lines.append("保護者向けでは、遮断ではなく理由と実務的な対処を優先して説明してください。")
        }

        lines.append("現在のフィルターレベルは \(filterLevel) です。")

        if let snapshot {
            lines.append("現在のページ安全状態: \(snapshot.level) / \(snapshot.summary)")
        }

        return lines
    }

    private func mergeSupplementalAssessment(
        categories: [String],
        currentSnapshot: AICoachService.SafetySnapshot?
    ) -> AICoachService.SafetySnapshot {
        if let currentSnapshot, currentSnapshot.level == "要注意" {
            return currentSnapshot
        }

        let categorySummary = categories.prefix(3).joined(separator: ", ")
        return AICoachService.SafetySnapshot(
            level: "要確認",
            summary: "外部分類でも注意カテゴリを検出しました: \(categorySummary)",
            recommendations: [
                "ページの目的と送信先を確認する",
                "入力や登録を急がない",
                "必要なら保護者または管理者へ共有する"
            ]
        )
    }

    private func focusedRecommendations(for category: String) -> [String] {
        switch category {
        case "個人情報詐欺":
            return [
                "ログインや入力の前にURLを見直す",
                "知らないページへカード番号やパスワードを入れない",
                "公式サイトか保護者に確認する"
            ]
        case "成人向けコンテンツ", "出会い系":
            return [
                "このページを続ける前に保護者へ確認する",
                "個人情報や写真を送らない",
                "不安なら前のページに戻る"
            ]
        case "勧誘、カジノ、金融等", "薬物":
            return [
                "申し込みや購入に進まない",
                "広告や誘導ボタンを押さない",
                "不安なら前のページに戻る"
            ]
        default:
            return defaultRecommendations(for: category)
        }
    }

    private func defaultRecommendations(for category: String) -> [String] {
        switch category {
        case "個人情報詐欺", "成人向けコンテンツ", "出会い系", "勧誘、カジノ、金融等", "薬物":
            return focusedRecommendations(for: category)
        default:
            return [
            "ページの目的を見出しとURLで確認する",
            "不安なら前のページに戻る",
            "必要なら保護者へ共有する"
            ]
        }
    }
}
