import Foundation

struct AIResearchSourceSnapshot: Hashable, Codable {
    let status: AIResultSourceStatus
    let sourceCount: Int
    let requiredSourceCount: Int
    let distinctDomainCount: Int
    let requiredDistinctDomainCount: Int

    var isSatisfied: Bool {
        sourceCount >= requiredSourceCount &&
        distinctDomainCount >= requiredDistinctDomainCount
    }

    var detailText: String {
        if requiredDistinctDomainCount > 0 {
            return "\(status.detailPrefix) 現在は \(sourceCount) 件 / 必要 \(requiredSourceCount) 件、ユニークドメイン \(distinctDomainCount) 件 / 必要 \(requiredDistinctDomainCount) 件です。"
        }
        return "\(status.detailPrefix) 現在は \(sourceCount) 件 / 必要 \(requiredSourceCount) 件です。"
    }
}

struct AIResearchOrchestrator {
    func shouldRequireSources(config: AIExecutionConfig) -> Bool {
        config.researchMode == .deep && config.allowWebSearch
    }

    func queryIntent(
        for query: String?,
        searchPlan: AISearchPlan? = nil,
        config: AIExecutionConfig
    ) -> AISearchIntent {
        if let searchPlan {
            return searchPlan.intent
        }

        let trimmed = query?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard !trimmed.isEmpty else {
            return config.researchMode == .deep ? .standardResearch : .simpleFact
        }

        let timeSensitiveTerms = ["最新", "今日", "現在", "最近", "ニュース", "価格", "株価", "発売日", "latest", "today", "current", "recent"]
        if timeSensitiveTerms.contains(where: { trimmed.contains($0) }) {
            return .timelyUpdate
        }

        let complexTerms = ["比較", "違い", "メリット", "デメリット", "分析", "おすすめ", "歴史", "影響", "法律", "法的", "違法", "合法", "未成年", "compare", "difference", "analysis"]
        if complexTerms.contains(where: { trimmed.contains($0) }) {
            return .complexAnalysis
        }

        let factTerms = ["とは", "何", "誰", "どこ", "when", "what is", "definition", "意味", "概要"]
        if factTerms.contains(where: { trimmed.contains($0) }) {
            return .simpleFact
        }

        return config.researchMode == .deep ? .standardResearch : .simpleFact
    }

    func sourceRequirement(
        for config: AIExecutionConfig,
        query: String? = nil,
        searchPlan: AISearchPlan? = nil
    ) -> AIResearchRequirementProfile {
        guard config.allowWebSearch else {
            return AIResearchRequirementProfile(
                requiredSourceCount: 0,
                requiredDistinctDomainCount: 0,
                maxSearchRounds: 1,
                circuitBreakerSeconds: 0
            )
        }

        guard config.researchMode == .deep else {
            return AIResearchRequirementProfile(
                requiredSourceCount: 1,
                requiredDistinctDomainCount: 1,
                maxSearchRounds: 1,
                circuitBreakerSeconds: 0
            )
        }

        switch queryIntent(for: query, searchPlan: searchPlan, config: config) {
        case .simpleFact:
            return AIResearchRequirementProfile(
                requiredSourceCount: 12,
                requiredDistinctDomainCount: 5,
                maxSearchRounds: 12,
                circuitBreakerSeconds: 270
            )
        case .standardResearch:
            return AIResearchRequirementProfile(
                requiredSourceCount: 20,
                requiredDistinctDomainCount: 8,
                maxSearchRounds: 18,
                circuitBreakerSeconds: 360
            )
        case .complexAnalysis:
            return AIResearchRequirementProfile(
                requiredSourceCount: 30,
                requiredDistinctDomainCount: 12,
                maxSearchRounds: 24,
                circuitBreakerSeconds: 480
            )
        case .timelyUpdate:
            return AIResearchRequirementProfile(
                requiredSourceCount: 24,
                requiredDistinctDomainCount: 10,
                maxSearchRounds: 20,
                circuitBreakerSeconds: 400
            )
        }
    }

    func circuitBreakerSeconds(
        for config: AIExecutionConfig,
        query: String? = nil,
        searchPlan: AISearchPlan? = nil
    ) -> TimeInterval {
        sourceRequirement(for: config, query: query, searchPlan: searchPlan).circuitBreakerSeconds
    }

    func requiredSourceCount(
        for config: AIExecutionConfig,
        query: String? = nil,
        searchPlan: AISearchPlan? = nil
    ) -> Int {
        guard config.allowWebSearch else { return 0 }
        return sourceRequirement(for: config, query: query, searchPlan: searchPlan).requiredSourceCount
    }

    func requiredDistinctDomainCount(
        for config: AIExecutionConfig,
        query: String? = nil,
        searchPlan: AISearchPlan? = nil
    ) -> Int {
        let requiredCount = requiredSourceCount(for: config, query: query, searchPlan: searchPlan)
        guard requiredCount > 0 else { return 0 }
        return sourceRequirement(for: config, query: query, searchPlan: searchPlan).requiredDistinctDomainCount
    }

    func maxSearchRounds(
        for config: AIExecutionConfig,
        query: String? = nil,
        searchPlan: AISearchPlan? = nil
    ) -> Int {
        sourceRequirement(for: config, query: query, searchPlan: searchPlan).maxSearchRounds
    }

    func shouldAttemptContinuationAfterLength(
        finishReason: String?,
        config: AIExecutionConfig
    ) -> Bool {
        guard finishReason == "length" else { return false }
        return config.researchMode == .deep || config.reasoningMode != .fast
    }

    func distinctDomainCount(for sources: [AIResultSource]) -> Int {
        let normalized = filteredEligibleSources(sources).compactMap { source -> String? in
            let trimmedDomain = source.domain.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedDomain.isEmpty {
                return trimmedDomain.lowercased()
            }
            return URL(string: source.url)?.host?.lowercased()
        }
        return Set(normalized).count
    }

    func sourceSnapshot(
        for config: AIExecutionConfig,
        sources: [AIResultSource],
        isLoading: Bool = false,
        query: String? = nil,
        searchPlan: AISearchPlan? = nil
    ) -> AIResearchSourceSnapshot {
        let eligibleSources = filteredEligibleSources(sources)
        let requirement = sourceRequirement(for: config, query: query, searchPlan: searchPlan)
        let requiredCount = requirement.requiredSourceCount
        let requiredDomainCount = requirement.requiredDistinctDomainCount
        let sourceCount = eligibleSources.count
        let distinctDomainCount = distinctDomainCount(for: eligibleSources)
        let status = statusForReadiness(
            requiredCount: requiredCount,
            requiredDomainCount: requiredDomainCount,
            sourceCount: sourceCount,
            distinctDomainCount: distinctDomainCount,
            isLoading: isLoading
        )

        return AIResearchSourceSnapshot(
            status: status,
            sourceCount: sourceCount,
            requiredSourceCount: requiredCount,
            distinctDomainCount: distinctDomainCount,
            requiredDistinctDomainCount: requiredDomainCount
        )
    }

    func hasSatisfiedSourceRequirement(
        for config: AIExecutionConfig,
        sources: [AIResultSource],
        query: String? = nil,
        searchPlan: AISearchPlan? = nil
    ) -> Bool {
        sourceSnapshot(for: config, sources: sources, query: query, searchPlan: searchPlan).isSatisfied
    }

    func loadingState(
        for config: AIExecutionConfig,
        sources: [AIResultSource],
        isActivelyRunning: Bool = false,
        query: String? = nil,
        searchPlan: AISearchPlan? = nil
    ) -> AIResearchLoadingState {
        if shouldRequireSources(config: config),
           !sourceSnapshot(
                for: config,
                sources: sources,
                isLoading: isActivelyRunning,
                query: query,
                searchPlan: searchPlan
           ).isSatisfied {
            return isActivelyRunning ? .analyzing : .waitingForSources
        }
        return .completed
    }

    func sectionsWithSourceStatus(
        _ sections: [AIResultSection],
        config: AIExecutionConfig,
        sources: [AIResultSource],
        query: String? = nil,
        searchPlan: AISearchPlan? = nil
    ) -> [AIResultSection] {
        guard shouldRequireSources(config: config) else { return sections }
        let snapshot = sourceSnapshot(for: config, sources: sources, query: query, searchPlan: searchPlan)
        guard snapshot.status != .ready else { return sections }

        let note = AIResultSection(
            title: "ソース状況",
            bodyMarkdown: snapshot.detailText
        )
        return [note] + sections
    }

    func flowWithSourceStatus(
        _ flow: [AIResearchFlowStep],
        config: AIExecutionConfig,
        sources: [AIResultSource],
        query: String? = nil,
        searchPlan: AISearchPlan? = nil
    ) -> [AIResearchFlowStep] {
        guard shouldRequireSources(config: config) else { return flow }
        let snapshot = sourceSnapshot(for: config, sources: sources, query: query, searchPlan: searchPlan)
        guard snapshot.status != .ready else { return flow }

        let marker = snapshot.status.title
        guard flow.last?.label != marker else { return flow }

        let markerState: AIResearchLoadingState = snapshot.status == .enriching ? .analyzing : .waitingForSources

        return flow + [
            AIResearchFlowStep(
                state: markerState,
                label: marker,
                detail: snapshot.detailText
            )
        ]
    }

    func filteredEligibleSources(_ sources: [AIResultSource]) -> [AIResultSource] {
        var seen = Set<String>()
        var filtered: [AIResultSource] = []

        for source in sources {
            let normalizedURL = normalizedSourceKey(for: source)
            guard !normalizedURL.isEmpty else { continue }
            guard seen.insert(normalizedURL).inserted else { continue }

            let hasTitle = !source.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasSummary = !source.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasDomain = !normalizedDomain(for: source).isEmpty
            guard hasDomain || hasTitle || hasSummary else { continue }

            filtered.append(source)
        }

        return filtered
    }

    /// 重複排除済みソースを「ドメイン権威性 + スニペット充実度」でスコアリングして並べ替える。
    /// 同点時は元の挿入順を保つ（安定ソート）。
    /// 用途: 合成ステップへ渡す上位 N 件選定や、UI 表示の上位優先化。
    func rankedEligibleSources(_ sources: [AIResultSource]) -> [AIResultSource] {
        let eligible = filteredEligibleSources(sources)
        let scored = eligible.enumerated().map { (index, source) -> (Int, Double, AIResultSource) in
            (index, sourceQualityScore(for: source), source)
        }
        return scored
            .sorted { left, right in
                if left.1 != right.1 { return left.1 > right.1 }
                return left.0 < right.0
            }
            .map { $0.2 }
    }

    /// 1 ソースの相対品質スコア。0 を中立、+/- で品質を表現する。
    /// 範囲: 概ね -0.5 〜 +5.0。
    private func sourceQualityScore(for source: AIResultSource) -> Double {
        let domain = normalizedDomain(for: source)
        let urlLower = source.url.lowercased()
        let title = source.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = source.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        var score: Double = 0

        // 1) ドメイン権威性
        if Self.highAuthorityHints.contains(where: { domain.contains($0) }) {
            score += 3.0
        } else if Self.mediumAuthorityHints.contains(where: { domain.contains($0) }) {
            score += 1.0
        }

        // 2) HTTPS は微小加点
        if urlLower.hasPrefix("https://") {
            score += 0.1
        }

        // 3) スニペット充実度
        let summaryLength = summary.count
        if summaryLength >= 120 && summaryLength <= 600 {
            score += 1.5
        } else if summaryLength > 600 {
            score += 1.0
        } else if summaryLength >= 40 {
            score += 0.4
        } else {
            score -= 0.3 // 極端に短い要約はノイズの可能性
        }

        // 4) タイトル長（極端に短い/長いタイトルは品質劣化のサイン）
        let titleLength = title.count
        if titleLength >= 8 && titleLength <= 80 {
            score += 0.3
        } else if titleLength > 0 {
            score += 0.1
        } else {
            score -= 0.2
        }

        // 5) 既知のスパム/低品質指標（粗いヒューリスティック）
        let lowQualityHints = ["pinterest.", "amazon.co.jp/s?", "yahoo.co.jp/search", "google.com/search"]
        if lowQualityHints.contains(where: { urlLower.contains($0) }) {
            score -= 0.5
        }

        return score
    }

    /// 高権威ドメイン（部分一致）。教育系 / 公的機関 / 大手百科事典 / 公式ドキュメント。
    private static let highAuthorityHints: [String] = [
        ".gov", ".go.jp", ".ac.jp", ".edu",
        "wikipedia.org", "wikimedia.org",
        "mext.go.jp", "kantei.go.jp", "soumu.go.jp", "courts.go.jp",
        "nhk.or.jp", "asahi.com", "yomiuri.co.jp", "nikkei.com", "mainichi.jp",
        "developer.mozilla.org", "developer.apple.com",
        "stats.gov.jp", "stat.go.jp", "e-stat.go.jp"
    ]

    /// 中信頼性ドメイン（部分一致）。
    private static let mediumAuthorityHints: [String] = [
        ".org", ".or.jp", ".ne.jp",
        "github.com", "stackoverflow.com",
        "qiita.com", "zenn.dev"
    ]

    private func statusForReadiness(
        requiredCount: Int,
        requiredDomainCount: Int,
        sourceCount: Int,
        distinctDomainCount: Int,
        isLoading: Bool
    ) -> AIResultSourceStatus {
        if requiredCount == 0 || (sourceCount >= requiredCount && distinctDomainCount >= requiredDomainCount) {
            return .ready
        }
        return isLoading ? .enriching : .insufficient
    }

    private func normalizedSourceKey(for source: AIResultSource) -> String {
        let trimmedURL = source.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { return "" }
        if let normalized = URL(string: trimmedURL)?.absoluteString.lowercased(), !normalized.isEmpty {
            return normalized
        }
        return trimmedURL.lowercased()
    }

    private func normalizedDomain(for source: AIResultSource) -> String {
        let trimmedDomain = source.domain.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedDomain.isEmpty {
            return trimmedDomain.lowercased()
        }
        return URL(string: source.url)?.host?.lowercased() ?? ""
    }
}
