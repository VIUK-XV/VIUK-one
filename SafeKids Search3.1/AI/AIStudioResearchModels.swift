/*
仕様:
- 役割: AI Studio の調査結果ページと画面状態を表す表示モデルを定義する。
- 主な型: `AIStudioPresentationMode`, `AIResearchLoadingState`, `AIResultPage`.
- 編集ポイント: Deep Research UI の表示要素や状態遷移を増やすときに触る。
*/
import Foundation

enum AIStudioPresentationMode: String, Codable {
    case home
    case conversation
    case result
}

enum AIResearchLoadingState: String, Codable {
    case idle
    case searching
    case analyzing
    case waitingForSources
    case generating
    case completed

    var displayText: String {
        switch self {
        case .idle:
            return "待機中"
        case .searching:
            return "Web検索中…"
        case .analyzing:
            return "情報を整理中…"
        case .waitingForSources:
            return "追加確認待ち"
        case .generating:
            return "回答をまとめています…"
        case .completed:
            return "完了"
        }
    }
}

enum LocalRuntimeWarmState: String, Codable, Hashable {
    case coldStart
    case warming
    case warmReady
    case reusedWarmSession

    var displayText: String {
        switch self {
        case .coldStart:
            return "初回ロード中"
        case .warming:
            return "バックグラウンドで温め中"
        case .warmReady:
            return "温め済み"
        case .reusedWarmSession:
            return "温まったランタイムを再利用中"
        }
    }
}

enum LocalExecutionStage: String, Codable, Hashable {
    case preparing
    case routing
    case warmingRuntime
    case loadingModel
    case searchPlanning
    case searching
    case thinking
    case generating
    case streaming
    case completed
    case failed

    var displayText: String {
        switch self {
        case .preparing:
            return "準備中"
        case .routing:
            return "ルート選択中"
        case .warmingRuntime:
            return "ランタイム準備中"
        case .loadingModel:
            return "モデル読込中"
        case .searchPlanning:
            return "検索計画中"
        case .searching:
            return "検索中"
        case .thinking:
            return "推論方針を整理中"
        case .generating:
            return "推論を整理中"
        case .streaming:
            return "本文を書き出し中"
        case .completed:
            return "完了"
        case .failed:
            return "失敗"
        }
    }
}

struct LocalExecutionStatusUpdate: Codable, Hashable {
    let stage: LocalExecutionStage
    let title: String
    let detail: String
    let estimatedProgress: Int
    let runnerLabel: String?
    let warmState: LocalRuntimeWarmState?
    let elapsedSeconds: TimeInterval

    init(
        stage: LocalExecutionStage,
        title: String,
        detail: String,
        estimatedProgress: Int,
        runnerLabel: String? = nil,
        warmState: LocalRuntimeWarmState? = nil,
        elapsedSeconds: TimeInterval = 0
    ) {
        self.stage = stage
        self.title = title
        self.detail = detail
        self.estimatedProgress = min(max(estimatedProgress, 0), 100)
        self.runnerLabel = runnerLabel?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.warmState = warmState
        self.elapsedSeconds = max(0, elapsedSeconds)
    }

    var progressText: String {
        "\(estimatedProgress)%"
    }

    var elapsedText: String {
        if elapsedSeconds < 10 {
            return String(format: "%.1fs", elapsedSeconds)
        }
        return "\(Int(elapsedSeconds.rounded()))s"
    }
}

enum AIResultSourceStatus: String, Codable, Hashable {
    case insufficient
    case enriching
    case ready

    var title: String {
        switch self {
        case .insufficient:
            return "ソース不足"
        case .enriching:
            return "追加確認中"
        case .ready:
            return "確保済み"
        }
    }

    var detailPrefix: String {
        switch self {
        case .insufficient:
            return "外部ソースが不足しています。"
        case .enriching:
            return "外部ソースを追加確認しています。"
        case .ready:
            return "外部ソースを確保できています。"
        }
    }
}

enum AIResultSourceType: String, Codable, Hashable {
    case web
    case academic
    case conversation
    case memory
}

struct AIResearchRequirementProfile: Codable, Hashable {
    let requiredSourceCount: Int
    let requiredDistinctDomainCount: Int
    let maxSearchRounds: Int
    let circuitBreakerSeconds: TimeInterval

    init(
        requiredSourceCount: Int,
        requiredDistinctDomainCount: Int,
        maxSearchRounds: Int,
        circuitBreakerSeconds: TimeInterval
    ) {
        self.requiredSourceCount = max(requiredSourceCount, 0)
        self.requiredDistinctDomainCount = max(requiredDistinctDomainCount, 0)
        self.maxSearchRounds = max(maxSearchRounds, 1)
        self.circuitBreakerSeconds = max(circuitBreakerSeconds, 0)
    }
}

struct AIResultSection: Identifiable, Codable, Hashable {
    let id: String
    let title: String
    let bodyMarkdown: String

    init(id: String = UUID().uuidString, title: String, bodyMarkdown: String) {
        self.id = id
        self.title = title
        self.bodyMarkdown = bodyMarkdown
    }
}

struct AIResultSource: Identifiable, Codable, Hashable {
    let id: String
    let title: String
    let domain: String
    let summary: String
    let url: String
    let sourceType: AIResultSourceType
    let qualityScore: Double?
    let freshnessScore: Double?
    let contentDensityScore: Double?
    let publishedAt: Date?
    let citationID: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case domain
        case summary
        case url
        case sourceType
        case qualityScore
        case freshnessScore
        case contentDensityScore
        case publishedAt
        case citationID
    }

    init(
        id: String = UUID().uuidString,
        title: String,
        domain: String,
        summary: String,
        url: String,
        sourceType: AIResultSourceType = .web,
        qualityScore: Double? = nil,
        freshnessScore: Double? = nil,
        contentDensityScore: Double? = nil,
        publishedAt: Date? = nil,
        citationID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.domain = domain
        self.summary = summary
        self.url = url
        self.sourceType = sourceType
        self.qualityScore = qualityScore
        self.freshnessScore = freshnessScore
        self.contentDensityScore = contentDensityScore
        self.publishedAt = publishedAt
        self.citationID = citationID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        title = try container.decode(String.self, forKey: .title)
        domain = try container.decodeIfPresent(String.self, forKey: .domain) ?? ""
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        url = try container.decode(String.self, forKey: .url)
        sourceType = try container.decodeIfPresent(AIResultSourceType.self, forKey: .sourceType) ?? .web
        qualityScore = try container.decodeIfPresent(Double.self, forKey: .qualityScore)
        freshnessScore = try container.decodeIfPresent(Double.self, forKey: .freshnessScore)
        contentDensityScore = try container.decodeIfPresent(Double.self, forKey: .contentDensityScore)
        publishedAt = try container.decodeIfPresent(Date.self, forKey: .publishedAt)
        citationID = try container.decodeIfPresent(String.self, forKey: .citationID)
    }
}

struct AIResearchFlowStep: Identifiable, Codable, Hashable {
    let id: String
    let state: AIResearchLoadingState
    let label: String
    let detail: String?
    let timestamp: Date

    init(
        id: String = UUID().uuidString,
        state: AIResearchLoadingState,
        label: String,
        detail: String? = nil,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.state = state
        self.label = label
        self.detail = detail
        self.timestamp = timestamp
    }
}

enum AIResultActionKind: String, Codable, Hashable {
    case standard
    case deepResearch
}

struct AIResultAction: Identifiable, Codable, Hashable {
    let id: String
    let title: String
    let prompt: String
    let kind: AIResultActionKind

    init(
        id: String = UUID().uuidString,
        title: String,
        prompt: String,
        kind: AIResultActionKind = .standard
    ) {
        self.id = id
        self.title = title
        self.prompt = prompt
        self.kind = kind
    }
}

struct AIResultPage: Codable, Hashable {
    let query: String
    let summary: String
    let sections: [AIResultSection]
    let sources: [AIResultSource]
    let sourceStatus: AIResultSourceStatus
    let requiredSourceCount: Int
    let distinctSourceDomainCount: Int
    let requiredDistinctDomainCount: Int
    let relatedQuestions: [String]
    let actions: [AIResultAction]
    let researchFlow: [AIResearchFlowStep]
    let thinkingDuration: TimeInterval?
    let searchPlan: AISearchPlan?

    private enum CodingKeys: String, CodingKey {
        case query
        case summary
        case sections
        case sources
        case sourceStatus
        case requiredSourceCount
        case distinctSourceDomainCount
        case requiredDistinctDomainCount
        case relatedQuestions
        case actions
        case researchFlow
        case thinkingDuration
        case searchPlan
    }

    init(
        query: String,
        summary: String,
        sections: [AIResultSection],
        sources: [AIResultSource],
        sourceStatus: AIResultSourceStatus,
        requiredSourceCount: Int,
        distinctSourceDomainCount: Int,
        requiredDistinctDomainCount: Int,
        relatedQuestions: [String],
        actions: [AIResultAction],
        researchFlow: [AIResearchFlowStep],
        thinkingDuration: TimeInterval?,
        searchPlan: AISearchPlan? = nil
    ) {
        self.query = query
        self.summary = summary
        self.sections = sections
        self.sources = sources
        self.sourceStatus = sourceStatus
        self.requiredSourceCount = requiredSourceCount
        self.distinctSourceDomainCount = distinctSourceDomainCount
        self.requiredDistinctDomainCount = requiredDistinctDomainCount
        self.relatedQuestions = relatedQuestions
        self.actions = actions
        self.researchFlow = researchFlow
        self.thinkingDuration = thinkingDuration
        self.searchPlan = searchPlan
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        query = try container.decode(String.self, forKey: .query)
        summary = try container.decode(String.self, forKey: .summary)
        sections = try container.decode([AIResultSection].self, forKey: .sections)
        sources = try container.decodeIfPresent([AIResultSource].self, forKey: .sources) ?? []
        sourceStatus = try container.decodeIfPresent(AIResultSourceStatus.self, forKey: .sourceStatus)
            ?? (sources.isEmpty ? .insufficient : .ready)
        requiredSourceCount = try container.decodeIfPresent(Int.self, forKey: .requiredSourceCount)
            ?? max(sources.isEmpty ? 1 : sources.count, 1)
        distinctSourceDomainCount = try container.decodeIfPresent(Int.self, forKey: .distinctSourceDomainCount)
            ?? Set(
                sources.compactMap { source in
                    let trimmedDomain = source.domain.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmedDomain.isEmpty {
                        return trimmedDomain.lowercased()
                    }
                    return URL(string: source.url)?.host?.lowercased()
                }
            ).count
        requiredDistinctDomainCount = try container.decodeIfPresent(Int.self, forKey: .requiredDistinctDomainCount)
            ?? (requiredSourceCount > 1 ? min(requiredSourceCount, 2) : min(requiredSourceCount, 1))
        relatedQuestions = try container.decodeIfPresent([String].self, forKey: .relatedQuestions) ?? []
        actions = try container.decodeIfPresent([AIResultAction].self, forKey: .actions) ?? []
        researchFlow = try container.decodeIfPresent([AIResearchFlowStep].self, forKey: .researchFlow) ?? []
        thinkingDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .thinkingDuration)
        searchPlan = try container.decodeIfPresent(AISearchPlan.self, forKey: .searchPlan)
    }
}

struct AIStudioRootViewModel {
    var searchQuery: String = ""
    var isSidebarOpen: Bool = true
    var isDeepResearchRequested: Bool = false
    var isWebEnabled: Bool = true
    var presentationMode: AIStudioPresentationMode = .home
    var selectedThreadID: String = ""
    var showCompactSidebar: Bool = false
    var showCompactInspector: Bool = false

    mutating func syncPresentationMode(
        messagesAreEmpty: Bool,
        activeResultPage: AIResultPage?,
        currentThreadKind: AICoachService.ThreadKind
    ) {
        if currentThreadKind == .research, activeResultPage != nil {
            presentationMode = .result
        } else if messagesAreEmpty {
            presentationMode = .home
        } else {
            presentationMode = .conversation
        }
    }
}

struct ResultPageViewModel {
    private(set) var page: AIResultPage?
    private(set) var followUpMessages: [AICoachService.ChatMessage] = []
    private(set) var queryFallback: String = "Deep Research"

    mutating func update(
        page: AIResultPage?,
        followUpMessages: [AICoachService.ChatMessage],
        queryFallback: String
    ) {
        self.page = page
        self.followUpMessages = followUpMessages
        self.queryFallback = queryFallback
    }
}

struct ThinkingPanelViewModel {
    var isExpanded: Bool = false
    var isExecutionLogExpanded: Bool = false
    var isSearchTraceExpanded: Bool = true
    private(set) var summaryText: String?
    private(set) var visibleThoughts: [String] = []
    private(set) var visibleSearchNotes: [String] = []
    private(set) var executionLogItems: [String] = []
    private(set) var activeStep: AIResearchFlowStep?
    private(set) var flow: [AIResearchFlowStep] = []
    private(set) var isLoading: Bool = false
    private(set) var liveThoughtPreview: String?
    private(set) var liveExecutionStatus: LocalExecutionStatusUpdate?
    private(set) var thinkingDuration: TimeInterval?
    private(set) var formattedDuration: String?

    mutating func update(
        thoughtDetails: AICoachService.ResponseThoughtDetails?,
        flow: [AIResearchFlowStep],
        liveThoughtPreview: String?,
        liveExecutionStatus: LocalExecutionStatusUpdate?,
        isLoading: Bool
    ) {
        let candidates = thoughtDetails?.displayThoughtSegments.isEmpty == false
            ? (thoughtDetails?.displayThoughtSegments ?? [])
            : (thoughtDetails?.thoughtSummaries ?? [])
        let searchNotes = thoughtDetails?.searchActivity ?? []
        let executionLog = stableDeduplicatedItems((thoughtDetails?.toolActivity ?? []) + (thoughtDetails?.processingLogSummary ?? []))

        self.visibleThoughts = candidates
        self.visibleSearchNotes = searchNotes
        self.executionLogItems = executionLog
        self.activeStep = flow.last
        self.flow = flow
        self.isLoading = isLoading
        self.liveThoughtPreview = liveThoughtPreview?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.liveExecutionStatus = liveExecutionStatus
        self.thinkingDuration = thoughtDetails?.thinkingDuration
        self.formattedDuration = formatThinkingDuration(thoughtDetails?.thinkingDuration)
        self.summaryText = makeSummaryText()
    }

    private func makeSummaryText() -> String? {
        if let liveExecutionStatus, shouldPreferExecutionStatusSummary(liveExecutionStatus) {
            return liveExecutionStatus.detail.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? liveExecutionStatus.title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        if let liveThoughtPreview, !liveThoughtPreview.isEmpty {
            return liveThoughtPreview
        }
        if let liveExecutionStatus {
            return liveExecutionStatus.detail
        }
        if let firstThought = visibleThoughts.first, !firstThought.isEmpty {
            return firstThought
        }
        return nil
    }

    private func shouldPreferExecutionStatusSummary(_ status: LocalExecutionStatusUpdate) -> Bool {
        if status.runnerLabel?.localizedCaseInsensitiveContains("VIUK Search Engine") == true {
            return true
        }
        switch status.stage {
        case .searchPlanning, .searching, .routing, .warmingRuntime, .loadingModel, .generating, .streaming:
            return true
        case .preparing, .thinking, .completed, .failed:
            return false
        }
    }

    private func stableDeduplicatedItems(_ items: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for item in items {
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if seen.insert(trimmed).inserted {
                result.append(trimmed)
            }
        }

        return result
    }

    private func formatThinkingDuration(_ interval: TimeInterval?) -> String? {
        guard let interval else { return nil }
        if interval < 1 {
            return "0.0s"
        }
        if interval < 10 {
            return String(format: "%.1fs", interval)
        }
        if interval < 60 {
            return "\(Int(interval.rounded()))s"
        }
        let minutes = Int(interval / 60)
        let seconds = Int(interval.truncatingRemainder(dividingBy: 60))
        return "\(minutes)m \(seconds)s"
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
