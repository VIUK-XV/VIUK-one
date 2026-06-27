/*
仕様:
- 役割: AI Studio と Science Club が共通で使う軽量 SML 分析レイヤー。
- 主な型: `AISMLAnalysisEngine`, `AISMLAnalysisContext`, `AISMLAnalysisResult`.
- 編集ポイント: フォールバック時の質問分類、危険度判定、簡易回答の文面を変えるときに触る。
*/
import Foundation

enum AISMLAssistantIntent: String {
    case greeting
    case appOverview
    case workspaceRouting
    case settingsHelp
    case safetyReview
    case pageContext
    case scienceQuestion
    case clarify
    case generalAssistance
}

enum AISMLRiskLevel: String {
    case safe = "safe"
    case caution = "caution"
    case high = "high"
}

enum AISMLResponseStyle: String {
    case concise
    case structured
    case safetyFirst
    case scienceCoach
}

struct AISMLAnalysisContext {
    enum Domain {
        case aiStudio
        case scienceClub
    }

    let domain: Domain
    let coachMode: AICoachService.CoachMode
    let childAge: Int
    let pageInfo: AICoachService.PageInfo?
    let safetySnapshot: AICoachService.SafetySnapshot?
    let fallbackDescription: String?
}

struct AISMLAnalysisResult {
    let intent: AISMLAssistantIntent
    let riskLevel: AISMLRiskLevel
    let detectedSignals: [String]
    let recommendedTone: String
    let responseStyle: AISMLResponseStyle
    let summary: String
    let suggestedAnswer: String
    let shouldEscalateSafety: Bool
}

final class AISMLAnalysisEngine {
    static let shared = AISMLAnalysisEngine()

    private let sml = UltraLightSafetySML.shared

    private init() {}

    func analyzeForAssistant(
        question: String,
        images: [Data] = [],
        context: AISMLAnalysisContext
    ) -> AISMLAnalysisResult {
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedQuestion = trimmedQuestion.lowercased()

        let evaluationText = [
            trimmedQuestion,
            context.pageInfo?.title ?? "",
            context.pageInfo?.content.map { String($0.prefix(320)) } ?? ""
        ]
        .joined(separator: "\n")

        let evaluation = sml.evaluate(
            text: evaluationText,
            url: context.pageInfo?.url ?? ""
        )

        let intent = classifyIntent(
            question: trimmedQuestion,
            normalizedQuestion: normalizedQuestion,
            domain: context.domain
        )

        let riskLevel = deriveRiskLevel(
            evaluation: evaluation,
            snapshot: context.safetySnapshot
        )

        let shouldEscalateSafety = riskLevel != .safe
        let responseStyle: AISMLResponseStyle
        if shouldEscalateSafety {
            responseStyle = .safetyFirst
        } else if context.domain == .scienceClub {
            responseStyle = .scienceCoach
        } else if intent == .clarify || intent == .greeting {
            responseStyle = .concise
        } else {
            responseStyle = .structured
        }

        let detectedSignals = buildDetectedSignals(
            evaluation: evaluation,
            snapshot: context.safetySnapshot
        )

        let suggestedAnswer: String
        switch context.domain {
        case .aiStudio:
            suggestedAnswer = makeStudioAnswer(
                question: trimmedQuestion,
                normalizedQuestion: normalizedQuestion,
                images: images,
                context: context,
                intent: intent,
                shouldEscalateSafety: shouldEscalateSafety
            )
        case .scienceClub:
            suggestedAnswer = makeScienceAnswer(
                question: trimmedQuestion,
                normalizedQuestion: normalizedQuestion,
                images: images,
                context: context,
                intent: intent,
                shouldEscalateSafety: shouldEscalateSafety
            )
        }

        let summary = makeSummary(
            intent: intent,
            riskLevel: riskLevel,
            detectedSignals: detectedSignals
        )

        return AISMLAnalysisResult(
            intent: intent,
            riskLevel: riskLevel,
            detectedSignals: detectedSignals,
            recommendedTone: recommendedTone(for: context, responseStyle: responseStyle),
            responseStyle: responseStyle,
            summary: summary,
            suggestedAnswer: suggestedAnswer,
            shouldEscalateSafety: shouldEscalateSafety
        )
    }

    private func classifyIntent(
        question: String,
        normalizedQuestion: String,
        domain: AISMLAnalysisContext.Domain
    ) -> AISMLAssistantIntent {
        if question.isEmpty {
            return .clarify
        }

        let greetingTerms = ["こんにちは", "こんばんは", "おはよう", "やあ", "hello", "hi", "おーい", "おい"]
        if question.count <= 10 && greetingTerms.contains(where: { normalizedQuestion.contains($0) }) {
            return .greeting
        }

        if normalizedQuestion.contains("このアプリ") || normalizedQuestion.contains("何のアプリ") || normalizedQuestion.contains("なにができる") {
            return .appOverview
        }

        if normalizedQuestion.contains("どこ") || normalizedQuestion.contains("進めば") || normalizedQuestion.contains("使えば") {
            return .workspaceRouting
        }

        if normalizedQuestion.contains("設定") {
            return .settingsHelp
        }

        let safetyTerms = ["安全", "危険", "大丈夫", "ブロック", "不適切", "見ていい", "見ても", "リスク", "危ない"]
        if safetyTerms.contains(where: { normalizedQuestion.contains($0) }) {
            return .safetyReview
        }

        let pageTerms = ["このページ", "今見て", "いま見て", "この記事", "このサイト", "この画面", "url", "リンク", "ページ", "web", "ウェブ"]
        if pageTerms.contains(where: { normalizedQuestion.contains($0) }) {
            return .pageContext
        }

        let scienceTerms = ["実験", "観察", "自由研究", "scratch", "科学", "工作", "考察", "なぜ", "レポート", "まとめ"]
        if domain == .scienceClub || scienceTerms.contains(where: { normalizedQuestion.contains($0) }) {
            return .scienceQuestion
        }

        if fallbackDefinitionTopic(from: question) != nil {
            return .generalAssistance
        }

        if question.count <= 12 {
            return .clarify
        }

        return .generalAssistance
    }

    private func deriveRiskLevel(
        evaluation: UltraLightSMLEvaluation,
        snapshot: AICoachService.SafetySnapshot?
    ) -> AISMLRiskLevel {
        if snapshot?.level == "要注意" {
            return .high
        }

        if let topSignal = evaluation.topSignal, topSignal.probability >= 0.82, !topSignal.isLikelyFalsePositive {
            return .high
        }

        if let snapshot, snapshot.level == "注意" || snapshot.level == "要確認" {
            return .caution
        }

        if let topSignal = evaluation.topSignal, topSignal.probability >= 0.62, !topSignal.isLikelyFalsePositive {
            return .caution
        }

        return .safe
    }

    private func buildDetectedSignals(
        evaluation: UltraLightSMLEvaluation,
        snapshot: AICoachService.SafetySnapshot?
    ) -> [String] {
        var signals: [String] = []

        if let topSignal = evaluation.topSignal {
            signals.append(topSignal.category)
            signals.append(contentsOf: topSignal.matchedKeywords.prefix(4))
        }

        if let snapshot {
            signals.append(snapshot.level)
        }

        var seen = Set<String>()
        return signals.filter { signal in
            let normalized = signal.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { return false }
            return seen.insert(normalized).inserted
        }
    }

    private func makeSummary(
        intent: AISMLAssistantIntent,
        riskLevel: AISMLRiskLevel,
        detectedSignals: [String]
    ) -> String {
        let signalSuffix = detectedSignals.prefix(3).joined(separator: ", ")
        if signalSuffix.isEmpty {
            return "\(intent.rawValue) / \(riskLevel.rawValue)"
        }
        return "\(intent.rawValue) / \(riskLevel.rawValue) / \(signalSuffix)"
    }

    private func recommendedTone(
        for context: AISMLAnalysisContext,
        responseStyle: AISMLResponseStyle
    ) -> String {
        switch responseStyle {
        case .safetyFirst:
            return "安全優先で短く具体的"
        case .scienceCoach:
            return "やさしい科学コーチ"
        case .concise:
            return context.coachMode == .guardian ? "実務的で簡潔" : "自然で短く"
        case .structured:
            return "結論先行で整理して説明"
        }
    }

    private func makeStudioAnswer(
        question: String,
        normalizedQuestion: String,
        images: [Data],
        context: AISMLAnalysisContext,
        intent: AISMLAssistantIntent,
        shouldEscalateSafety: Bool
    ) -> String {
        if shouldEscalateSafety, let snapshot = context.safetySnapshot {
            var lines = [
                "安全面では \(snapshot.level) です。",
                snapshot.summary
            ]
            if let first = snapshot.recommendations.first {
                lines.append("まずは \(first) を優先してください。")
            }
            return lines.joined(separator: "\n")
        }

        switch intent {
        case .greeting:
            return "こんにちは。調べたいこと、整理したいこと、見ているページの確認などを手伝えます。"
        case .appOverview:
            return "\(AppBrand.displayName) は、VIUK の各アプリへ入るためのハブです。Safe Browse、Learning、AI Studio、Map、Love などをここから開けます。"
        case .workspaceRouting:
            return "目的ごとに分けるなら、調べものは Safe Browse、整理や要約は AI Studio、教材は Learning、移動は Map、関係の相談は Love が向いています。"
        case .settingsHelp:
            return "設定したい対象を言ってください。AI Studio、Safe Browse、Science Club など、アプリごとに独立して案内します。"
        case .safetyReview:
            if let snapshot = context.safetySnapshot {
                return "いま見えている範囲では安全評価は \(snapshot.level) です。必要なら理由や次の対応も整理します。"
            }
            return "安全性が気になるなら、ページ名、URL、どこが不安かを一緒に見ると整理しやすいです。"
        case .pageContext:
            if let pageInfo = context.pageInfo {
                let pageLabel = pageInfo.title.isEmpty ? pageInfo.url : pageInfo.title
                return "今見ているのは「\(pageLabel)」です。必要なら内容の要点、気になる点、安全性を順に整理します。"
            }
            return "見ているページが分かると整理しやすいです。ページ名やURLを教えてください。"
        case .clarify:
            if question.isEmpty {
                return "質問や調べたいことを送ってください。要約、比較、使い分けの整理、ページの安全確認を手伝えます。"
            }
            if let answer = fallbackDefinitionAnswer(for: question) {
                return answer
            }
            if shouldExplainOperationalState(for: normalizedQuestion), let fallbackDescription = context.fallbackDescription {
                return "現在は \(fallbackDescription) で案内しています。確認したい状態を1つ書いてください。"
            }
            return "もう少し具体的に書いてください。たとえば「何を比較したいか」「どのページのことか」「どこが分からないか」があると整理しやすいです。"
        case .generalAssistance, .scienceQuestion:
            if let answer = fallbackDefinitionAnswer(for: question) {
                return answer
            }
            var lines = ["質問の意図を整理しながら答えます。必要なら、調べたい対象、比較したい候補、今見ているページのどこを知りたいかを少し足してください。"]
            if !images.isEmpty {
                lines.append("画像が \(images.count) 枚あるので、気になる部分を一言添えると整理しやすくなります。")
            }
            if shouldExplainOperationalState(for: normalizedQuestion), let fallbackDescription = context.fallbackDescription {
                lines.append("いまは \(fallbackDescription) で続行しています。")
            }
            return lines.joined(separator: "\n")
        }
    }

    private func fallbackDefinitionTopic(from question: String) -> String? {
        let trimmed = question
            .replacingOccurrences(of: "？", with: "?")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let markers = ["とは", "って何", "ってなに", "とは何", "とはなに"]
        for marker in markers {
            guard let range = trimmed.range(of: marker, options: .caseInsensitive) else { continue }
            let topic = String(trimmed[..<range.lowerBound])
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            if topic.count >= 2 {
                return topic
            }
        }

        return nil
    }

    private func fallbackDefinitionAnswer(for question: String) -> String? {
        guard let topic = fallbackDefinitionTopic(from: question) else { return nil }
        let normalizedTopic = topic.lowercased()

        if normalizedTopic.contains("gemma") {
            return "\(topic) は、このアプリで会話や調査回答を作るために使っているローカルAIモデルです。質問文を理解し、必要ならWeb検索やツール実行の結果も使って、自然文の回答にまとめる役割を持ちます。\n\nいま Gemma 本体が使えない場合でも、最低限のフォールバックで説明を返します。"
        }

        return "\(topic) についての定義を聞いています。短く言うと、「\(topic) が何で、何に使われ、ほかと何が違うのか」を整理すると分かりやすいです。\n\nいまは軽量フォールバックで返しているため、詳しい説明が必要なら「\(topic) の特徴」「使い方」「メリット・デメリット」のように続けて聞いてください。"
    }

    private func makeScienceAnswer(
        question: String,
        normalizedQuestion: String,
        images: [Data],
        context: AISMLAnalysisContext,
        intent: AISMLAssistantIntent,
        shouldEscalateSafety: Bool
    ) -> String {
        if shouldEscalateSafety, let snapshot = context.safetySnapshot {
            var lines = [
                "結論: まず安全確認を優先してください。",
                "どう見るか: \(snapshot.summary)"
            ]
            if let first = snapshot.recommendations.first {
                lines.append("次にやること: \(first)")
            }
            return lines.joined(separator: "\n")
        }

        switch intent {
        case .greeting:
            return "こんにちは。観察、実験、自由研究、Scratch の整理を手伝えます。"
        case .clarify:
            return "もう少し具体的に書いてください。たとえば「何を観察したいか」「何を比べたいか」「どこまで分かっているか」があると科学の流れで整理しやすいです。"
        default:
            var lines: [String] = []

            if normalizedQuestion.contains("レポート") || normalizedQuestion.contains("まとめ") || normalizedQuestion.contains("考察") {
                lines.append("結論: 目的、結果、そこから分かることの順に書くと、考察がまとまりやすいです。")
            } else if normalizedQuestion.contains("なぜ") {
                lines.append("結論: まず原因の候補を2〜3個に分けると整理しやすいです。")
            } else {
                lines.append("結論: \(question.isEmpty ? "科学の質問" : question) は、目的・条件・観察ポイントに分けると整理しやすいです。")
            }

            if !images.isEmpty {
                lines.append("どう見るか: 画像は \(images.count) 枚あります。色、形、変化、数字など見えている特徴を文章でも足すと、分析が安定します。")
            } else {
                lines.append("どう見るか: 何を変えるか、何を比べるか、何を観察するかの3つに分けて考えてください。")
            }

            if normalizedQuestion.contains("実験") || normalizedQuestion.contains("自由研究") {
                lines.append("次にやること: 目的、予想、使うもの、手順、観察記録の順でメモすると進めやすいです。")
            } else if normalizedQuestion.contains("scratch") {
                lines.append("次にやること: まず作りたい動きを1つに絞って、必要なブロックを順に並べてください。")
            } else {
                lines.append("次にやること: いちばん知りたい点を1つに絞って送ると、次の説明を具体化できます。")
            }

            if let fallbackDescription = context.fallbackDescription,
               shouldExplainOperationalState(for: normalizedQuestion) {
                lines.append("補足: いまは \(fallbackDescription) で続けています。")
            }

            return lines.joined(separator: "\n")
        }
    }

    private func shouldExplainOperationalState(for normalizedQuestion: String) -> Bool {
        let operationalTerms = [
            "gemini", "api", "キー", "key", "モデル", "ローカルai", "ローカル ai",
            "ランタイム", "runtime", "ダウンロード", "保存", "実行", "起動",
            "動か", "使え", "使える", "接続", "エラー", "設定", "未設定", "状態"
        ]
        return operationalTerms.contains(where: { normalizedQuestion.localizedCaseInsensitiveContains($0) })
    }
}
