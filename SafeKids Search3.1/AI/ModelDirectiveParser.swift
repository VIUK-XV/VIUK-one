/*
仕様:
- 役割: モデル応答に含まれるJSONディレクティブを抽出して安全に解釈する。
- 主な型: `ModelDirectiveParser`, `StructuredModelDirective`.
- 編集ポイント: AIの出力形式、パース許容範囲、失敗時の扱いを調整するときに触る。
*/
import Foundation

final class ModelDirectiveResponseSchema: Encodable {
    let type: String
    let properties: [String: ModelDirectiveResponseSchema]?
    let required: [String]?
    let enumValues: [String]?
    let nullable: Bool?
    let items: ModelDirectiveResponseSchema?

    init(
        type: String,
        properties: [String: ModelDirectiveResponseSchema]? = nil,
        required: [String]? = nil,
        enumValues: [String]? = nil,
        nullable: Bool? = nil,
        items: ModelDirectiveResponseSchema? = nil
    ) {
        self.type = type
        self.properties = properties
        self.required = required
        self.enumValues = enumValues
        self.nullable = nullable
        self.items = items
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case properties
        case required
        case enumValues = "enum"
        case nullable
        case items
    }
}

enum StructuredDirectiveAction: String, Decodable, Equatable, CaseIterable {
    case conversationSearch = "conversation_search"
    case externalSearch = "external_search"
    case answer
    case clarify
    case refuse

    static let search: Self = .externalSearch

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        switch rawValue {
        case "search":
            self = .externalSearch
        case "conversation_search":
            self = .conversationSearch
        case "external_search":
            self = .externalSearch
        case "answer":
            self = .answer
        case "clarify":
            self = .clarify
        case "refuse":
            self = .refuse
        default:
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported action: \(rawValue)")
        }
    }
}

enum StructuredResponseActionKind: String, Decodable, Equatable, CaseIterable {
    case refine
    case conversationSearch = "conversation_search"
    case memory
}

struct StructuredToolCallName: RawRepresentable, Decodable, Equatable, Hashable {
    let rawValue: String

    init?(rawValue: String) {
        guard AIToolCatalog.containsTool(named: rawValue) else {
            return nil
        }
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let value = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported tool name: \(rawValue)")
        }
        self = value
    }

    static let conversationSearch = StructuredToolCallName(rawValue: "conversation_search")!
    static let externalSearch = StructuredToolCallName(rawValue: "external_search")!
    static let pythonExec = StructuredToolCallName(rawValue: "python_exec")!
    static let tableBuilder = StructuredToolCallName(rawValue: "table_builder")!
    static let currentTime = StructuredToolCallName(rawValue: "current_time")!
    static let calculator = StructuredToolCallName(rawValue: "calculator")!
}

struct StructuredToolCallArguments: Decodable, Equatable {
    let query: String?
    let queries: [String]?
    let code: String?
    let source: String?
    let expression: String?
    let limit: Int?
    let stopCondition: String?
}

struct StructuredToolCall: Decodable, Equatable {
    let name: StructuredToolCallName
    let arguments: StructuredToolCallArguments?
    let reason: String?
}

struct StructuredResponseAction: Decodable, Equatable {
    let title: String
    let prompt: String
    let kind: StructuredResponseActionKind
}

struct StructuredSettingsDirective: Decodable, Equatable {
    let instruction: String?
    let settingKey: String?
    let enabled: Bool?
    let level: String?
    let age: Int?
}

struct StructuredModelDirective: Decodable, Equatable {
    let version: String
    let requestId: String
    let action: StructuredDirectiveAction
    let message: String?
    let question: String?
    let query: String?
    let queries: [String]?
    let reason: String?
    let stopCondition: String?
    let toolCalls: [StructuredToolCall]?
    let responseActions: [StructuredResponseAction]?
    let memoryToStore: String?
    let settings: StructuredSettingsDirective?
    /// 表示用の思考プロセス。Thinking モードで model に明示的に出力させる。
    let thinking: String?

    private enum CodingKeys: String, CodingKey {
        case version
        case requestId
        case action
        case message
        case question
        case query
        case queries
        case reason
        case stopCondition
        case toolCalls
        case toolCallsSnake = "tool_calls"
        case responseActions
        case memoryToStore
        case settings
        case thinking
        case thinkingSnake = "thinking_summary"
    }

    init(
        version: String,
        requestId: String,
        action: StructuredDirectiveAction,
        message: String? = nil,
        question: String? = nil,
        query: String? = nil,
        queries: [String]? = nil,
        reason: String? = nil,
        stopCondition: String? = nil,
        toolCalls: [StructuredToolCall]? = nil,
        responseActions: [StructuredResponseAction]? = nil,
        memoryToStore: String? = nil,
        settings: StructuredSettingsDirective? = nil,
        thinking: String? = nil
    ) {
        self.version = version
        self.requestId = requestId
        self.action = action
        self.message = message
        self.question = question
        self.query = query
        self.queries = queries
        self.reason = reason
        self.stopCondition = stopCondition
        self.toolCalls = toolCalls
        self.responseActions = responseActions
        self.memoryToStore = memoryToStore
        self.settings = settings
        self.thinking = thinking
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(String.self, forKey: .version)
        requestId = try container.decode(String.self, forKey: .requestId)
        action = try container.decode(StructuredDirectiveAction.self, forKey: .action)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        question = try container.decodeIfPresent(String.self, forKey: .question)
        query = try container.decodeIfPresent(String.self, forKey: .query)
        queries = try container.decodeIfPresent([String].self, forKey: .queries)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        stopCondition = try container.decodeIfPresent(String.self, forKey: .stopCondition)
        toolCalls = try container.decodeIfPresent([StructuredToolCall].self, forKey: .toolCallsSnake)
            ?? container.decodeIfPresent([StructuredToolCall].self, forKey: .toolCalls)
        responseActions = try container.decodeIfPresent([StructuredResponseAction].self, forKey: .responseActions)
        memoryToStore = try container.decodeIfPresent(String.self, forKey: .memoryToStore)
        settings = try container.decodeIfPresent(StructuredSettingsDirective.self, forKey: .settings)
        thinking = try container.decodeIfPresent(String.self, forKey: .thinking)
            ?? container.decodeIfPresent(String.self, forKey: .thinkingSnake)
    }
}

struct ModelDirectiveParser {
    enum ParseOutcome: Equatable {
        case decoded(StructuredModelDirective)
        case jsonLikeButInvalid
        case notJSONLike
    }

    func parse(_ text: String) -> ParseOutcome {
        let sanitized = sanitizeModelOutput(text)
        guard !sanitized.isEmpty else {
            return .notJSONLike
        }

        guard let candidate = extractStructuredJSONCandidate(fromSanitized: sanitized) else {
            return looksJSONLike(sanitized) ? .jsonLikeButInvalid : .notJSONLike
        }

        guard let data = candidate.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(StructuredModelDirective.self, from: data),
              validate(decoded) else {
            return .jsonLikeButInvalid
        }

        return .decoded(decoded)
    }

    func extractStructuredJSONCandidate(from text: String) -> String? {
        let sanitized = sanitizeModelOutput(text)
        return extractStructuredJSONCandidate(fromSanitized: sanitized)
    }

    func bestEffortVisibleMessage(from text: String) -> String? {
        let sanitized = sanitizeModelOutput(text)
        guard !sanitized.isEmpty else { return nil }

        if let candidate = extractStructuredJSONCandidate(fromSanitized: sanitized) {
            if let message = extractLooseStringValue(for: "message", from: candidate) {
                return message
            }
            if let question = extractLooseStringValue(for: "question", from: candidate) {
                return question
            }
        }

        let stripped = stripJSONCodeFenceIfNeeded(from: sanitized)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !looksJSONLike(stripped), !stripped.isEmpty {
            return stripped
        }

        return nil
    }

    func makeResponseSchema() -> ModelDirectiveResponseSchema {
        ModelDirectiveResponseSchema(
            type: "object",
            properties: [
                "version": ModelDirectiveResponseSchema(type: "string", nullable: false),
                "requestId": ModelDirectiveResponseSchema(type: "string", nullable: false),
                "action": ModelDirectiveResponseSchema(
                    type: "string",
                    enumValues: StructuredDirectiveAction.allCases.map(\.rawValue),
                    nullable: false
                ),
                "message": ModelDirectiveResponseSchema(type: "string", nullable: true),
                "thinking": ModelDirectiveResponseSchema(type: "string", nullable: true),
                "question": ModelDirectiveResponseSchema(type: "string", nullable: true),
                "query": ModelDirectiveResponseSchema(type: "string", nullable: true),
                "queries": ModelDirectiveResponseSchema(
                    type: "array",
                    nullable: true,
                    items: ModelDirectiveResponseSchema(type: "string")
                ),
                "reason": ModelDirectiveResponseSchema(type: "string", nullable: true),
                "stopCondition": ModelDirectiveResponseSchema(type: "string", nullable: true),
                "tool_calls": ModelDirectiveResponseSchema(
                    type: "array",
                    nullable: true,
                    items: ModelDirectiveResponseSchema(
                        type: "object",
                        properties: [
                            "name": ModelDirectiveResponseSchema(
                                type: "string",
                                enumValues: AIToolCatalog.toolNames,
                                nullable: false
                            ),
                            "reason": ModelDirectiveResponseSchema(type: "string", nullable: true),
                            "arguments": ModelDirectiveResponseSchema(
                                type: "object",
                                properties: AIToolCatalog.toolCallArgumentSchemaProperties(),
                                nullable: true
                            )
                        ],
                        required: ["name"],
                        nullable: false
                    )
                ),
                "responseActions": ModelDirectiveResponseSchema(
                    type: "array",
                    nullable: true,
                    items: ModelDirectiveResponseSchema(
                        type: "object",
                        properties: [
                            "title": ModelDirectiveResponseSchema(type: "string", nullable: false),
                            "prompt": ModelDirectiveResponseSchema(type: "string", nullable: false),
                            "kind": ModelDirectiveResponseSchema(
                                type: "string",
                                enumValues: StructuredResponseActionKind.allCases.map(\.rawValue),
                                nullable: false
                            )
                        ],
                        required: ["title", "prompt", "kind"],
                        nullable: false
                    )
                ),
                "memoryToStore": ModelDirectiveResponseSchema(type: "string", nullable: true),
                "settings": ModelDirectiveResponseSchema(
                    type: "object",
                    properties: [
                        "instruction": ModelDirectiveResponseSchema(type: "string", nullable: true),
                        "settingKey": ModelDirectiveResponseSchema(
                            type: "string",
                            enumValues: [
                                "auto_protection",
                                "personal_info_protection",
                                "whitelist_only",
                                "ai_coach",
                                "safe_browsing",
                                "ai_detection",
                                "realtime_detection",
                                "strict_mode",
                                "child_age",
                                "filter_level"
                            ],
                            nullable: true
                        ),
                        "enabled": ModelDirectiveResponseSchema(type: "boolean", nullable: true),
                        "level": ModelDirectiveResponseSchema(
                            type: "string",
                            enumValues: ["やさしめ", "中程度", "厳しめ"],
                            nullable: true
                        ),
                        "age": ModelDirectiveResponseSchema(type: "integer", nullable: true)
                    ],
                    nullable: true
                )
            ],
            required: ["version", "requestId", "action"],
            nullable: false
        )
    }

    private func extractStructuredJSONCandidate(fromSanitized sanitized: String) -> String? {
        let unfenced = stripJSONCodeFenceIfNeeded(from: sanitized)
        guard let firstBrace = unfenced.firstIndex(of: "{"),
              let lastBrace = unfenced.lastIndex(of: "}"),
              firstBrace <= lastBrace else {
            return nil
        }

        let candidate = String(unfenced[firstBrace...lastBrace])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return candidate.isEmpty ? nil : candidate
    }

    private func validate(_ directive: StructuredModelDirective) -> Bool {
        guard hasRenderableText(directive.version),
              hasRenderableText(directive.requestId) else {
            return false
        }

        if let toolCalls = directive.toolCalls, !toolCalls.isEmpty {
            return true
        }

        switch directive.action {
        case .conversationSearch, .externalSearch:
            return hasRenderableText(directive.query) || !(directive.queries?.isEmpty ?? true)
        case .clarify:
            return hasRenderableText(directive.question) || hasRenderableText(directive.message)
        case .answer, .refuse:
            return hasRenderableText(directive.message)
        }
    }

    private func hasRenderableText(_ text: String?) -> Bool {
        guard let text else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sanitizeModelOutput(_ text: String) -> String {
        let invisibleScalars = CharacterSet(charactersIn: "\u{FEFF}\u{200B}\u{200C}\u{200D}\u{2060}")
        let filteredScalars = text.unicodeScalars.filter { !invisibleScalars.contains($0) }
        return String(String.UnicodeScalarView(filteredScalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func stripJSONCodeFenceIfNeeded(from text: String) -> String {
        guard text.hasPrefix("```") else { return text }
        var lines = text.components(separatedBy: .newlines)
        guard !lines.isEmpty else { return text }

        if lines.first?.hasPrefix("```") == true {
            lines.removeFirst()
        }
        if lines.last?.hasPrefix("```") == true {
            lines.removeLast()
        }

        return lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func looksJSONLike(_ text: String) -> Bool {
        text.contains("{")
            || text.contains("}")
            || text.localizedCaseInsensitiveContains("\"action\"")
            || text.localizedCaseInsensitiveContains("```json")
    }

    private func extractLooseStringValue(for key: String, from candidate: String) -> String? {
        let pattern = "\"\(NSRegularExpression.escapedPattern(for: key))\"\\s*:\\s*\"((?:\\\\.|[^\"])*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }

        let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
        guard let match = regex.firstMatch(in: candidate, options: [], range: range),
              match.numberOfRanges >= 2,
              let valueRange = Range(match.range(at: 1), in: candidate) else {
            return nil
        }

        let rawValue = String(candidate[valueRange])
        let unescaped = rawValue
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return unescaped.isEmpty ? nil : unescaped
    }
}
