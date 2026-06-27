/*
仕様:
- 役割: 検索の要否判定と、無駄の少ない検索クエリ計画を作る。
- 主な型: `AISearchPlanner`, `AISearchPlan`.
- 編集ポイント: 検索発火条件、クエリ展開数、比較/最新情報の判定を変えるときに触る。
*/
import Foundation

enum AISearchIntent: String, Codable, Hashable {
    case simpleFact
    case standardResearch
    case complexAnalysis
    case timelyUpdate
}

struct AISearchSubQuery: Identifiable, Codable, Hashable {
    let id: String
    let query: String
    let priority: Float
    let rationale: String?

    init(
        id: String = UUID().uuidString,
        query: String,
        priority: Float,
        rationale: String? = nil
    ) {
        self.id = id
        self.query = query
        self.priority = min(max(priority, 0), 1)
        self.rationale = rationale?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

struct AISearchPlan: Codable, Hashable {
    let shouldSearch: Bool
    let queries: [String]
    let rationale: String
    let subQueries: [AISearchSubQuery]
    let estimatedRounds: Int
    let intent: AISearchIntent
    let shouldUseParallelToolCalls: Bool
}

final class AISearchPlanner {
    static let shared = AISearchPlanner()

    private init() {}

    private enum SearchReasonKind {
        case liveInfo
        case comparison
        case numericOrSpec
        case explicitResearch
        case factCheck
        case legal
    }

    func makePlan(
        for prompt: String,
        pageInfo: AICoachService.PageInfo?,
        config: AIExecutionConfig,
        canSearch: Bool
    ) -> AISearchPlan {
        let trimmed = prompt
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard config.allowWebSearch, canSearch else {
            return AISearchPlan(
                shouldSearch: false,
                queries: [],
                rationale: "検索は無効です。",
                subQueries: [],
                estimatedRounds: 0,
                intent: .simpleFact,
                shouldUseParallelToolCalls: false
            )
        }

        guard trimmed.count >= 8 else {
            return AISearchPlan(
                shouldSearch: false,
                queries: [],
                rationale: "短い質問なので検索しません。",
                subQueries: [],
                estimatedRounds: 0,
                intent: .simpleFact,
                shouldUseParallelToolCalls: false
            )
        }

        if isPageBoundTask(trimmed, pageInfo: pageInfo) {
            return AISearchPlan(
                shouldSearch: false,
                queries: [],
                rationale: "現在のページ文脈だけで足りるため検索しません。",
                subQueries: [],
                estimatedRounds: 0,
                intent: .simpleFact,
                shouldUseParallelToolCalls: false
            )
        }

        guard let reason = searchReason(for: trimmed) else {
            return AISearchPlan(
                shouldSearch: false,
                queries: [],
                rationale: "最新性や外部確認の必要が薄いため検索しません。",
                subQueries: [],
                estimatedRounds: 0,
                intent: .simpleFact,
                shouldUseParallelToolCalls: false
            )
        }

        let baseQuery = normalizedQuerySeed(from: trimmed)
        guard !baseQuery.isEmpty else {
            return AISearchPlan(
                shouldSearch: false,
                queries: [],
                rationale: "検索語を安定して組み立てられませんでした。",
                subQueries: [],
                estimatedRounds: 0,
                intent: .simpleFact,
                shouldUseParallelToolCalls: false
            )
        }

        let queries = buildQueries(baseQuery: baseQuery, prompt: trimmed, reason: reason.kind, config: config)
        let intent = searchIntent(for: reason.kind, prompt: trimmed)
        let subQueries = buildSubQueries(
            queries: queries,
            intent: intent,
            reasonMessage: reason.message
        )
        return AISearchPlan(
            shouldSearch: !queries.isEmpty,
            queries: queries,
            rationale: reason.message,
            subQueries: subQueries,
            estimatedRounds: estimatedRounds(for: intent),
            intent: intent,
            shouldUseParallelToolCalls: subQueries.count > 1
        )
    }

    private func isPageBoundTask(_ prompt: String, pageInfo: AICoachService.PageInfo?) -> Bool {
        let pageTerms = ["このページ", "この記事", "このサイト", "今見ている", "いま見ている", "このURL", "この画面", "上の内容", "この文章"]
        if pageTerms.contains(where: { prompt.localizedCaseInsensitiveContains($0) }) {
            return true
        }

        let localOnlyVerbs = ["要約", "まとめ", "翻訳", "言い換え", "添削", "説明して", "整理して"]
        if pageInfo != nil && localOnlyVerbs.contains(where: { prompt.localizedCaseInsensitiveContains($0) }) {
            return true
        }

        return false
    }

    private func searchReason(for prompt: String) -> (kind: SearchReasonKind, message: String)? {
        let liveInfoTerms = ["最新", "最近", "今日", "きょう", "現在", "今", "ニュース", "動向", "アップデート", "更新"]
        if liveInfoTerms.contains(where: { prompt.localizedCaseInsensitiveContains($0) }) {
            return (.liveInfo, "最新性が必要です。")
        }

        let comparisonTerms = ["比較", "おすすめ", "どれ", "選び方", "vs", "違い"]
        if comparisonTerms.contains(where: { prompt.localizedCaseInsensitiveContains($0) }) {
            return (.comparison, "比較や推薦には外部確認が有効です。")
        }

        let specTerms = ["価格", "値段", "相場", "株価", "仕様", "型番", "スペック", "発売日", "バージョン"]
        if specTerms.contains(where: { prompt.localizedCaseInsensitiveContains($0) }) {
            return (.numericOrSpec, "数値や仕様の確認が必要です。")
        }

        let legalTerms = ["法律", "法律上", "法的", "違法", "合法", "条例", "規制", "権利", "著作権", "未成年"]
        if legalTerms.contains(where: { prompt.localizedCaseInsensitiveContains($0) }) {
            return (.legal, "法律上の観点は外部確認が必要です。")
        }

        let explicitSearchTerms = ["調べて", "検索して", "ウェブ", "web", "online", "オンライン", "公式"]
        if explicitSearchTerms.contains(where: { prompt.localizedCaseInsensitiveContains($0) }) {
            return (.explicitResearch, "ユーザーが外部調査を求めています。")
        }

        if prompt.contains("?") || prompt.contains("？") {
            let interrogatives = ["いつ", "どこ", "誰", "何", "なに", "どれ", "いくら"]
            if interrogatives.contains(where: { prompt.localizedCaseInsensitiveContains($0) }) {
                return (.factCheck, "事実確認が必要そうです。")
            }
        }

        return nil
    }

    private func searchIntent(for reason: SearchReasonKind, prompt: String) -> AISearchIntent {
        switch reason {
        case .liveInfo:
            return .timelyUpdate
        case .comparison:
            return .complexAnalysis
        case .numericOrSpec:
            return .standardResearch
        case .explicitResearch:
            return prompt.count >= 32 ? .complexAnalysis : .standardResearch
        case .factCheck:
            return .simpleFact
        case .legal:
            return .complexAnalysis
        }
    }

    private func estimatedRounds(for intent: AISearchIntent) -> Int {
        switch intent {
        case .simpleFact:
            return 1
        case .standardResearch:
            return 2
        case .complexAnalysis:
            return 3
        case .timelyUpdate:
            return 2
        }
    }

    private func buildSubQueries(
        queries: [String],
        intent: AISearchIntent,
        reasonMessage: String
    ) -> [AISearchSubQuery] {
        let priorities: [Float]
        switch intent {
        case .simpleFact:
            priorities = [1.0, 0.82, 0.7, 0.58]
        case .standardResearch:
            priorities = [1.0, 0.88, 0.76, 0.64]
        case .complexAnalysis:
            priorities = [1.0, 0.92, 0.84, 0.76, 0.68, 0.60, 0.52]
        case .timelyUpdate:
            priorities = [1.0, 0.9, 0.8, 0.7]
        }

        return queries.enumerated().map { index, query in
            AISearchSubQuery(
                query: query,
                priority: priorities[min(index, priorities.count - 1)],
                rationale: index == 0 ? reasonMessage : nil
            )
        }
    }

    private func normalizedQuerySeed(from prompt: String) -> String {
        if let semanticSeed = semanticQuerySeed(from: prompt) {
            return semanticSeed
        }

        var query = prompt
        let fillers = [
            "教えてください", "教えて", "知りたい", "について", "を調べて", "を検索して",
            "調べて", "検索して", "検索", "ですか", "ますか", "って何", "とは", "ください", "お願いします",
            "レポートにまとめて", "レポートにして", "要点をまとめて", "簡単にまとめて",
            "まとめて", "詳しく教えて", "詳しく", "説明して", "整理して"
        ]
        for filler in fillers {
            query = query.replacingOccurrences(of: filler, with: "", options: .caseInsensitive)
        }

        query = query
            .replacingOccurrences(of: "？", with: " ")
            .replacingOccurrences(of: "?", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let compact = compactQueryText(query)
        return compact.isEmpty ? compactQueryText(prompt) : compact
    }

    private func buildQueries(
        baseQuery: String,
        prompt: String,
        reason: SearchReasonKind,
        config: AIExecutionConfig
    ) -> [String] {
        var queries: [String] = [baseQuery]

        if reason == .liveInfo {
            queries.append(baseQuery + " 最新")
        }

        if reason == .comparison {
            queries.append(baseQuery + " 比較")
            if config.reasoningMode == .deepThinking || config.thinkingLevel == .extended {
                queries.append(baseQuery + " 公式")
            }
            if shouldAddOpinionQueries(for: prompt) && (config.reasoningMode == .deepThinking || config.thinkingLevel == .extended) {
                queries.append(baseQuery + " 評判")
                queries.append(baseQuery + " 問題点")
            }
        } else if reason == .legal {
            queries.append(baseQuery + " 法律")
            queries.append(baseQuery + " 公式")
        } else if reason == .numericOrSpec || containsSpecLanguage(prompt) {
            queries.append(baseQuery + " 公式")
        }

        // ステップ 1: 字句正規化（連続空白を単一スペース化、両端トリム）。
        var normalized: [String] = []
        for query in queries {
            let cleaned = query
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                normalized.append(cleaned)
            }
        }

        // ステップ 2: トークン集合のオーバーラップでセマンティック重複を除去。
        // Jaccard 類似度 >= 0.75 を「実質同一クエリ」とみなして後続を捨てる。
        // 例: 「再生可能エネルギー 比較」と「再生可能エネルギー vs 比較」は重複扱い。
        var unique: [String] = []
        var tokenSets: [Set<String>] = []
        for query in normalized {
            let tokens = tokenSet(of: query)
            // 既存と Jaccard >= 0.75 で類似のものがあればスキップ
            let isNearDuplicate = tokenSets.contains { existing in
                jaccardSimilarity(existing, tokens) >= 0.75
            }
            if isNearDuplicate { continue }
            unique.append(query)
            tokenSets.append(tokens)
        }

        return Array(unique.prefix(min(config.maxSearchCalls, 3)))
    }

    /// クエリをトークン集合に分解する（小文字化 + 1 文字以下のトークンを除外）。
    /// 日本語の場合は空白区切り済み（compactQueryText 後）を前提とする。
    private func tokenSet(of query: String) -> Set<String> {
        let parts = query
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { $0.count >= 2 }
        return Set(parts)
    }

    /// 2 つのトークン集合の Jaccard 類似度（|A∩B| / |A∪B|）。
    /// 両方空の場合は 0 を返す（dedup の判定では「同一」とせず別物として扱う）。
    private func jaccardSimilarity(_ left: Set<String>, _ right: Set<String>) -> Double {
        let intersection = left.intersection(right).count
        let union = left.union(right).count
        guard union > 0 else { return 0 }
        return Double(intersection) / Double(union)
    }

    private func semanticQuerySeed(from prompt: String) -> String? {
        let normalized = prompt
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        let separators = CharacterSet(charactersIn: "。！？!?、，,；;\n\r")
        var candidates: [String] = []
        for clause in normalized.components(separatedBy: separators) {
            let trimmed = clause.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let topic = topicBefore(marker: "について", in: trimmed) {
                candidates.append(topic)
            }
            if let topic = topicBefore(marker: "とは", in: trimmed) {
                candidates.append(topic)
            }
            if let topic = topicBefore(marker: "を知", in: trimmed) {
                candidates.append(topic)
            }
            if !looksLikeMetaClause(trimmed) {
                candidates.append(trimmed)
            }
        }

        guard let topic = candidates
            .map(compactQueryText(_:))
            .filter({ !$0.isEmpty })
            .sorted(by: { $0.count < $1.count })
            .first else {
            return nil
        }

        var parts = topic.split(whereSeparator: \.isWhitespace).map(String.init)
        if normalized.localizedCaseInsensitiveContains("法律") ||
            normalized.localizedCaseInsensitiveContains("法的") ||
            normalized.localizedCaseInsensitiveContains("違法") ||
            normalized.localizedCaseInsensitiveContains("合法") {
            parts.append("法律")
        }
        if normalized.localizedCaseInsensitiveContains("中学生") ||
            normalized.localizedCaseInsensitiveContains("未成年") {
            parts.append("未成年")
        }
        return compactQueryText(parts.joined(separator: " "))
    }

    private func topicBefore(marker: String, in text: String) -> String? {
        guard let range = text.range(of: marker, options: .caseInsensitive) else { return nil }
        let compact = compactQueryText(String(text[..<range.lowerBound]))
        return compact.isEmpty ? nil : compact
    }

    private func looksLikeMetaClause(_ clause: String) -> Bool {
        let normalized = clause.lowercased()
        if normalized.localizedCaseInsensitiveContains("私は中学生") ||
            normalized.localizedCaseInsensitiveContains("中学生です") ||
            normalized.localizedCaseInsensitiveContains("高校生です") ||
            normalized.localizedCaseInsensitiveContains("小学生です") {
            return true
        }
        let requestTerms = ["知りたい", "知りたく", "教えて", "調べて", "検索して", "まとめて", "説明して", "観点も含めて", "含めて"]
        let stripped = requestTerms.reduce(normalized) { partial, term in
            partial.replacingOccurrences(of: term, with: "")
        }
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func compactQueryText(_ text: String) -> String {
        var query = text
        let removable = [
            "私は", "自分は", "僕は", "中学生です", "高校生です", "小学生です",
            "教えてください", "教えて", "知りたい", "知りたく", "について", "を調べて", "を検索して",
            "調べて", "検索して", "検索", "ですか", "ますか", "って何", "とは", "ください", "お願いします",
            "まとめて", "詳しく", "説明して", "整理して", "観点も含めて", "含めて"
        ]
        for phrase in removable {
            query = query.replacingOccurrences(of: phrase, with: " ", options: .caseInsensitive)
        }
        query = query
            .replacingOccurrences(of: "[「」『』“”\"'`]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "[。！？!?、，,；;：:（）()\\[\\]{}]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return query.count > 80 ? String(query.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines) : query
    }

    private func containsSpecLanguage(_ prompt: String) -> Bool {
        let specTerms = ["仕様", "型番", "スペック", "価格", "値段", "相場", "株価", "発売日", "バージョン"]
        return specTerms.contains(where: { prompt.localizedCaseInsensitiveContains($0) })
    }

    private func shouldAddOpinionQueries(for prompt: String) -> Bool {
        let factHeavyTerms = [
            "情勢", "ニュース", "外交", "政治", "選挙", "戦争", "紛争", "事件", "事故",
            "災害", "地震", "台風", "景気", "経済", "株価", "相場", "為替", "統計", "歴史"
        ]
        return !factHeavyTerms.contains(where: { prompt.localizedCaseInsensitiveContains($0) })
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
