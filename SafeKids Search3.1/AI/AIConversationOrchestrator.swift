import Foundation

enum AIConversationIntent: Equatable {
    case noSearch
    case search
    case deepResearch
}

struct AIConversationIntentDecision: Equatable {
    let intent: AIConversationIntent
    let reasons: [String]
    let confidence: Double
}

enum AIConversationRoute: Equatable {
    case fastRemote
    case localGemma
    case remote
    case offlineFallback
}

struct AIConversationRouteDecision: Equatable {
    let route: AIConversationRoute
    let intentDecision: AIConversationIntentDecision
}

struct AIConversationRouteRequest {
    let prompt: String
    let attachedImageCount: Int
    let config: AIExecutionConfig
    let advancedSettings: GemmaAdvancedSettings
    let remoteAvailable: Bool
    let localGemmaAvailable: Bool
    let isDeepResearchRequested: Bool
    let currentThreadKind: AICoachService.ThreadKind
    let coachMode: AICoachService.CoachMode
}

struct AIConversationOrchestrator {
    func classifyIntent(
        prompt: String,
        config: AIExecutionConfig,
        advancedSettings: GemmaAdvancedSettings,
        isDeepResearchRequested: Bool
    ) -> AIConversationIntent {
        classifyIntentDecision(
            prompt: prompt,
            config: config,
            advancedSettings: advancedSettings,
            isDeepResearchRequested: isDeepResearchRequested
        ).intent
    }

    func classifyIntentDecision(
        prompt: String,
        config: AIExecutionConfig,
        advancedSettings: GemmaAdvancedSettings,
        isDeepResearchRequested: Bool
    ) -> AIConversationIntentDecision {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return AIConversationIntentDecision(intent: .noSearch, reasons: ["空の入力"], confidence: 1.0)
        }

        if isDeepResearchRequested {
            return AIConversationIntentDecision(
                intent: .deepResearch,
                reasons: ["Deep Research が明示されています"],
                confidence: 1.0
            )
        }

        if config.researchMode == .deep {
            return AIConversationIntentDecision(
                intent: .deepResearch,
                reasons: ["researchMode が deep です"],
                confidence: 0.98
            )
        }

        if looksLikeDeepResearchPrompt(trimmed) {
            return AIConversationIntentDecision(
                intent: .deepResearch,
                reasons: deepResearchReasons(for: trimmed),
                confidence: 0.94
            )
        }

        if isHighRiskPrompt(trimmed) {
            return AIConversationIntentDecision(
                intent: .search,
                reasons: ["医療・法律・金融など高リスク領域です"],
                confidence: 0.97
            )
        }

        guard config.allowWebSearch else {
            return AIConversationIntentDecision(
                intent: .noSearch,
                reasons: ["Web 検索が無効です"],
                confidence: 0.76
            )
        }

        let searchReasons = searchReasons(for: trimmed, advancedSettings: advancedSettings)
        if !searchReasons.isEmpty {
            return AIConversationIntentDecision(
                intent: .search,
                reasons: searchReasons,
                confidence: confidenceForSearchReasons(searchReasons)
            )
        }

        return AIConversationIntentDecision(
            intent: .noSearch,
            reasons: ["雑談・相談・一般説明寄りの質問です"],
            confidence: 0.68
        )
    }

    func route(for request: AIConversationRouteRequest) -> AIConversationRoute {
        routeDecision(for: request).route
    }

    func routeDecision(for request: AIConversationRouteRequest) -> AIConversationRouteDecision {
        let intentDecision = classifyIntentDecision(
            prompt: request.prompt,
            config: request.config,
            advancedSettings: request.advancedSettings,
            isDeepResearchRequested: request.isDeepResearchRequested
        )
        let intent = intentDecision.intent

        let route: AIConversationRoute
        if shouldUseFastRemoteConversationPath(request, intent: intent) {
            route = .fastRemote
        } else if shouldPreferLocalGemma(request) {
            route = .localGemma
        } else if request.remoteAvailable {
            route = .remote
        } else {
            route = .offlineFallback
        }

        return AIConversationRouteDecision(route: route, intentDecision: intentDecision)
    }

    func shouldPrioritizeSearch(
        prompt: String,
        config: AIExecutionConfig,
        advancedSettings: GemmaAdvancedSettings,
        canSearch: Bool,
        isDeepResearchRequested: Bool
    ) -> Bool {
        guard config.allowWebSearch, canSearch else { return false }
        let intent = classifyIntentDecision(
            prompt: prompt,
            config: config,
            advancedSettings: advancedSettings,
            isDeepResearchRequested: isDeepResearchRequested
        ).intent
        return intent == .search || intent == .deepResearch
    }

    private func shouldPreferLocalGemma(_ request: AIConversationRouteRequest) -> Bool {
        request.coachMode == .studio && request.localGemmaAvailable
    }

    private func shouldUseFastRemoteConversationPath(
        _ request: AIConversationRouteRequest,
        intent: AIConversationIntent
    ) -> Bool {
        guard request.remoteAvailable else { return false }
        guard !shouldPreferLocalGemma(request) else { return false }
        guard intent == .noSearch else { return false }
        guard request.config.reasoningMode == .fast else { return false }
        guard request.currentThreadKind != .research else { return false }
        guard request.attachedImageCount == 0 else { return false }

        let trimmed = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 240 else { return false }

        return !isSearchHeavyPrompt(trimmed)
    }

    private func isSearchHeavyPrompt(_ prompt: String) -> Bool {
        let normalized = prompt.lowercased()
        let heavyTerms = [
            "調べて", "検索", "web", "ウェブ", "最新", "比較", "おすすめ", "価格", "仕様",
            "api", "release", "benchmark", "python", "コード", "関数", "ツール",
            "画像", "添付", "前に話した", "以前", "会話", "製品", "サービス", "モデル"
        ]
        return heavyTerms.contains { normalized.localizedCaseInsensitiveContains($0) } || isFactualOrSpecQuery(prompt)
    }

    private func deepResearchReasons(for prompt: String) -> [String] {
        let normalized = prompt.lowercased()
        var reasons: [String] = []
        let mappings: [(String, String)] = [
            ("deep research", "Deep Research の明示要求があります"),
            ("深く調べて", "深く調べる依頼です"),
            ("深掘り", "深掘り要求です"),
            ("網羅的", "網羅的な整理が必要です"),
            ("レポート", "レポート形式の依頼です"),
            ("比較表", "比較表の作成依頼です"),
            ("複数ソース", "複数ソースの確認を求めています"),
            ("根拠付き", "根拠付きの回答を求めています"),
            ("体系的", "体系的な整理を求めています"),
            ("詳しく調査", "詳しい調査依頼です")
        ]
        for (needle, reason) in mappings where normalized.localizedCaseInsensitiveContains(needle) {
            reasons.append(reason)
        }
        return Array(reasons.prefix(4))
    }

    private func searchReasons(for prompt: String, advancedSettings: GemmaAdvancedSettings) -> [String] {
        var reasons: [String] = []

        if hasExplicitSearchRequest(prompt) {
            reasons.append("検索や公式確認の明示要求があります")
        }
        if containsTimeSensitiveLanguage(prompt) {
            reasons.append("最新性や現在性が必要です")
        }
        if advancedSettings.requireSearchForFactualQueries && isFactualOrSpecQuery(prompt) {
            reasons.append("仕様・定義・比較など事実確認寄りです")
        }
        if advancedSettings.requireSearchForFactualQueries && isShortNamedEntityQuery(prompt) {
            reasons.append("短い固有名詞クエリで外部確認が向いています")
        }

        return reasons
    }

    private func confidenceForSearchReasons(_ reasons: [String]) -> Double {
        switch reasons.count {
        case 4...:
            return 0.96
        case 3:
            return 0.91
        case 2:
            return 0.86
        case 1:
            return 0.78
        default:
            return 0.5
        }
    }

    private func looksLikeDeepResearchPrompt(_ prompt: String) -> Bool {
        let normalized = prompt.lowercased()
        let deepResearchTerms = [
            "deep research", "深く調べて", "深掘り", "網羅的", "レポート",
            "比較表", "複数ソース", "根拠付き", "体系的", "詳しく調査"
        ]
        return deepResearchTerms.contains { normalized.localizedCaseInsensitiveContains($0) }
    }

    private func isHighRiskPrompt(_ prompt: String) -> Bool {
        let normalized = prompt.lowercased()
        let highRiskTerms = [
            "医療", "病気", "薬", "副作用", "診断", "法律", "法務", "契約", "違法",
            "金融", "投資", "税金", "税制", "申請", "制度", "確定申告", "保険", "年金"
        ]
        return highRiskTerms.contains { normalized.localizedCaseInsensitiveContains($0) }
    }

    private func hasExplicitSearchRequest(_ prompt: String) -> Bool {
        let normalized = prompt.lowercased()
        let explicitTerms = [
            "調べて", "調査して", "検索して", "検索かけて", "検索掛けて", "検索をかけて",
            "検索", "ググって", "web", "ウェブ", "オンライン", "公式", "ソース"
        ]
        return explicitTerms.contains { normalized.localizedCaseInsensitiveContains($0) }
    }

    private func containsTimeSensitiveLanguage(_ prompt: String) -> Bool {
        let normalized = prompt.lowercased()
        let liveTerms = [
            "最新", "現在", "今日", "きょう", "今年", "ニュース", "最近",
            "直近", "アップデート", "更新", "本日"
        ]
        return liveTerms.contains { normalized.localizedCaseInsensitiveContains($0) }
    }

    private func isShortNamedEntityQuery(_ prompt: String) -> Bool {
        let normalized = prompt
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let tokenCount = normalized.split(whereSeparator: \.isWhitespace).count
        guard normalized.count <= 64, tokenCount <= 6 else { return false }

        let entityHints = [
            "gemma", "gemini", "gpt", "claude", "openai", "google", "deepmind",
            "iphone", "mac", "switchbot", "echo", "react", "python", "xcode", "api",
            "円相場", "株価", "ceo", "営業時間", "運行", "天気", "m4", "m3", "m2"
        ]
        if entityHints.contains(where: { normalized.contains($0) }) {
            return true
        }

        return normalized.range(of: #"[a-z]+\s*\d|[a-z]+\d|\d+[a-z]+"#, options: .regularExpression) != nil
    }

    private func isFactualOrSpecQuery(_ prompt: String) -> Bool {
        let normalized = prompt.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }

        let factualTerms = [
            "とは", "って何", "とは何", "何ですか", "なに", "概要", "意味", "どんな",
            "仕様", "比較", "違い", "最新", "価格", "値段", "製品", "サービス", "公式",
            "モデル", "機能", "性能", "benchmark", "release", "api", "spec", "version",
            "model", "gemma", "gpt", "claude", "openai", "google", "deepmind",
            "ceo", "株価", "為替", "天気", "営業時間", "運行", "バージョン"
        ]
        if factualTerms.contains(where: { normalized.contains($0) }) {
            return true
        }

        let searchNouns = [
            "仕様", "比較", "違い", "最新", "価格", "値段", "製品", "サービス", "公式",
            "モデル", "機能", "性能", "benchmark", "release", "api", "spec", "version",
            "model", "gemma", "gpt", "claude", "openai", "google", "deepmind",
            "ceo", "株価", "為替", "天気", "営業時間", "運行", "バージョン"
        ]
        if (normalized.hasSuffix("?") || normalized.hasSuffix("？")) &&
            searchNouns.contains(where: { normalized.contains($0) }) {
            return true
        }

        let containsVersionLikeToken = normalized.range(of: #"[a-z]+\s*\d|[a-z]+\d|\d+[a-z]+"#, options: .regularExpression) != nil
        return containsVersionLikeToken && normalized.count <= 64
    }
}
