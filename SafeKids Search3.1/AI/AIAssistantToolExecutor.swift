import Foundation
import CryptoKit

struct AIAssistantToolExecution {
    let toolName: String
    let contextText: String
    let visibleSummary: String
    let prefersDirectReply: Bool
}

final class AIAssistantToolExecutor {
    static let shared = AIAssistantToolExecutor()

    private init() {}

    func executeDeclaredToolCall(_ toolCall: StructuredToolCall) async -> AIAssistantToolExecution? {
        switch toolCall.name.rawValue {
        case StructuredToolCallName.conversationSearch.rawValue:
            return nil
        case StructuredToolCallName.externalSearch.rawValue:
            let queries: [String]
            if let q = toolCall.arguments?.queries, !q.isEmpty {
                queries = q
            } else if let q = toolCall.arguments?.query, !q.isEmpty {
                queries = [q]
            } else if let src = toolCall.arguments?.source, !src.isEmpty {
                queries = [src]
            } else {
                return nil
            }
            guard OllamaWebSearchService.shared.canPerformSearch else { return nil }
            var sections: [String] = []
            var totalResults = 0
            for query in queries.prefix(4) {
                let safeQuery = WebSearchSecurityPolicy.normalizedQuery(from: query)
                guard !safeQuery.isEmpty else { continue }
                guard let ctx = await OllamaWebSearchService.shared.performSearch(
                    query: safeQuery,
                    maxResults: 4
                ) else { continue }
                sections.append(ctx.promptSection)
                totalResults += ctx.resultCount
            }
            guard !sections.isEmpty else { return nil }
            let label = queries.prefix(2).joined(separator: " / ")
            return AIAssistantToolExecution(
                toolName: "external_search",
                contextText: sections.joined(separator: "\n\n"),
                visibleSummary: "外部検索「\(String(label.prefix(40)))」: \(totalResults)件",
                prefersDirectReply: false
            )
        case StructuredToolCallName.pythonExec.rawValue:
            guard let source = normalizedPythonSource(from: toolCall.arguments) else { return nil }
            return await runPython(source: source)
        case StructuredToolCallName.tableBuilder.rawValue:
            guard let source = normalizedTableSource(from: toolCall.arguments),
                  let execution = tableExecution(fromSource: source) else {
                return nil
            }
            return execution
        case StructuredToolCallName.currentTime.rawValue:
            return makeCurrentTimeExecution()
        case StructuredToolCallName.calculator.rawValue:
            guard let expression = normalizedCalculatorExpression(from: toolCall.arguments),
                  !expression.isEmpty else {
                return nil
            }
            return calculationExecution(forExpression: expression)
        default:
            return nil
        }
    }

    func executeLocalToolCall(_ toolCall: LocalAssistantToolCall) async -> AIAssistantToolExecution? {
        switch toolCall.name.rawValue {
        case LocalAssistantToolName.conversationSearch.rawValue:
            return nil
        case LocalAssistantToolName.externalSearch.rawValue:
            let queries: [String]
            if let q = toolCall.arguments?.queries, !q.isEmpty {
                queries = q
            } else if let q = toolCall.arguments?.query, !q.isEmpty {
                queries = [q]
            } else if let src = toolCall.arguments?.source, !src.isEmpty {
                queries = [src]
            } else {
                return nil
            }
            guard OllamaWebSearchService.shared.canPerformSearch else { return nil }
            var sections: [String] = []
            var totalResults = 0
            for query in queries.prefix(4) {
                let safeQuery = WebSearchSecurityPolicy.normalizedQuery(from: query)
                guard !safeQuery.isEmpty else { continue }
                guard let ctx = await OllamaWebSearchService.shared.performSearch(
                    query: safeQuery,
                    maxResults: 4
                ) else { continue }
                sections.append(ctx.promptSection)
                totalResults += ctx.resultCount
            }
            guard !sections.isEmpty else { return nil }
            let label = queries.prefix(2).joined(separator: " / ")
            return AIAssistantToolExecution(
                toolName: "external_search",
                contextText: sections.joined(separator: "\n\n"),
                visibleSummary: "外部検索「\(String(label.prefix(40)))」: \(totalResults)件",
                prefersDirectReply: false
            )
        case LocalAssistantToolName.pythonExec.rawValue:
            guard let source = normalizedPythonSource(
                query: toolCall.arguments?.query,
                code: toolCall.arguments?.code,
                source: toolCall.arguments?.source
            ) else { return nil }
            return await runPython(source: source)
        case LocalAssistantToolName.tableBuilder.rawValue:
            guard let source = normalizedTableSource(
                query: toolCall.arguments?.query,
                code: toolCall.arguments?.code,
                source: toolCall.arguments?.source
            ),
            let execution = tableExecution(fromSource: source) else {
                return nil
            }
            return execution
        case LocalAssistantToolName.currentTime.rawValue:
            return makeCurrentTimeExecution()
        case LocalAssistantToolName.calculator.rawValue:
            guard let expression = normalizedCalculatorExpression(
                query: toolCall.arguments?.query,
                expression: toolCall.arguments?.expression,
                source: toolCall.arguments?.source
            ),
            !expression.isEmpty else {
                return nil
            }
            return calculationExecution(forExpression: expression)
        default:
            return nil
        }
    }

    func executeRelevantTools(for prompt: String) async -> [AIAssistantToolExecution] {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var outputs: [AIAssistantToolExecution] = []

        if shouldUseTimeTool(for: trimmed) {
            outputs.append(makeCurrentTimeExecution())
        }

        if let calculation = calculateIfNeeded(for: trimmed) {
            outputs.append(calculation)
        }

        outputs.append(contentsOf: uuidExecutions(for: trimmed))

        if let base64Execution = base64Execution(for: trimmed) {
            outputs.append(base64Execution)
        }

        if let urlExecution = urlCodingExecution(for: trimmed) {
            outputs.append(urlExecution)
        }

        if let tableExecution = tableExecution(for: trimmed) {
            outputs.append(tableExecution)
        }

        if let jsonExecution = jsonExecution(for: trimmed) {
            outputs.append(jsonExecution)
        }

        if let textStatsExecution = textStatsExecution(for: trimmed) {
            outputs.append(textStatsExecution)
        }

        outputs.append(contentsOf: hashExecutions(for: trimmed))

        if let pythonSource = extractPythonSource(from: trimmed) {
            outputs.append(await runPython(source: pythonSource))
        }

        return outputs
    }

    private func normalizedPythonSource(from arguments: StructuredToolCallArguments?) -> String? {
        normalizedPythonSource(query: arguments?.query, code: arguments?.code, source: arguments?.source)
    }

    private func normalizedPythonSource(query: String?, code: String?, source: String?) -> String? {
        let candidates = [code, source, query]
        for candidate in candidates {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    private func normalizedTableSource(from arguments: StructuredToolCallArguments?) -> String? {
        normalizedTableSource(query: arguments?.query, code: arguments?.code, source: arguments?.source)
    }

    private func normalizedTableSource(query: String?, code: String?, source: String?) -> String? {
        let candidates = [source, query, code]
        for candidate in candidates {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    private func normalizedCalculatorExpression(from arguments: StructuredToolCallArguments?) -> String? {
        normalizedCalculatorExpression(query: arguments?.query, expression: arguments?.expression, source: arguments?.source)
    }

    private func normalizedCalculatorExpression(query: String?, expression: String?, source: String?) -> String? {
        let candidates = [expression, query, source]
        for candidate in candidates {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty {
                return normalizeMathWords(in: trimmed)
            }
        }
        return nil
    }

    private func shouldUseTimeTool(for prompt: String) -> Bool {
        let normalized = prompt.lowercased()
        let phrases = [
            "今何時", "いま何時", "現在時刻", "今の時間", "いまの時間",
            "今日何日", "今日の日付", "今の日付", "現在の日付",
            "what time", "current time", "date today", "today's date", "datetime"
        ]
        return phrases.contains(where: { normalized.localizedCaseInsensitiveContains($0) })
    }

    private func makeCurrentTimeExecution() -> AIAssistantToolExecution {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current
        formatter.dateFormat = "yyyy年M月d日(E) HH:mm:ss zzz"
        let text = formatter.string(from: Date())
        return AIAssistantToolExecution(
            toolName: "time",
            contextText: "現在の日時: \(text)",
            visibleSummary: "現在の日時は \(text) です。",
            prefersDirectReply: true
        )
    }

    private func calculateIfNeeded(for prompt: String) -> AIAssistantToolExecution? {
        let normalized = prompt.lowercased()
        let triggerPhrases = ["計算して", "計算", "calc:", "calculate:", "計算式:"]
        let explicitTrigger = triggerPhrases.contains(where: { normalized.contains($0) })
        let directMathQuestion = looksLikeDirectMathQuestion(prompt)
        guard explicitTrigger || directMathQuestion else { return nil }

        let expression = extractCalculationExpression(from: prompt)
        guard !expression.isEmpty else { return nil }

        return calculationExecution(forExpression: expression)
    }

    private func calculationExecution(forExpression expression: String) -> AIAssistantToolExecution {
        guard let result = evaluateMathExpression(expression) else {
            return AIAssistantToolExecution(
                toolName: "calculator",
                contextText: "計算失敗: 式を解釈できませんでした。入力: \(expression)",
                visibleSummary: "計算式を解釈できませんでした。括弧や演算子の並びを確認してください。",
                prefersDirectReply: true
            )
        }

        return AIAssistantToolExecution(
            toolName: "calculator",
            contextText: "計算式: \(expression)\n計算結果: \(result)",
            visibleSummary: "\(expression) = \(result)",
            prefersDirectReply: true
        )
    }

    private func uuidExecutions(for prompt: String) -> [AIAssistantToolExecution] {
        let normalized = prompt.lowercased()
        let needsUUID = normalized.contains("uuid") || normalized.contains("guid")
        guard needsUUID else { return [] }

        let count = min(max(extractRequestedCount(from: prompt) ?? 1, 1), 10)
        let uuids = (0..<count).map { _ in UUID().uuidString }
        return [
            AIAssistantToolExecution(
                toolName: "uuid",
                contextText: "UUID 生成結果:\n" + uuids.joined(separator: "\n"),
                visibleSummary: uuids.joined(separator: "\n"),
                prefersDirectReply: true
            )
        ]
    }

    private func base64Execution(for prompt: String) -> AIAssistantToolExecution? {
        let normalized = prompt.lowercased()

        if normalized.contains("base64") && (normalized.contains("decode") || normalized.contains("デコード")) {
            guard let source = extractColonPayload(from: prompt) ?? extractQuotedPayload(from: prompt) else { return nil }
            guard let data = Data(base64Encoded: source),
                  let decoded = String(data: data, encoding: .utf8) else {
                return AIAssistantToolExecution(
                    toolName: "base64-decode",
                    contextText: "Base64 デコード失敗: 入力が不正です。",
                    visibleSummary: "Base64 デコードに失敗しました。文字列を確認してください。",
                    prefersDirectReply: true
                )
            }
            return AIAssistantToolExecution(
                toolName: "base64-decode",
                contextText: "Base64 デコード結果:\n\(decoded)",
                visibleSummary: decoded,
                prefersDirectReply: true
            )
        }

        if normalized.contains("base64") && (normalized.contains("encode") || normalized.contains("エンコード")) {
            guard let source = extractColonPayload(from: prompt) ?? extractQuotedPayload(from: prompt) else { return nil }
            let encoded = Data(source.utf8).base64EncodedString()
            return AIAssistantToolExecution(
                toolName: "base64-encode",
                contextText: "Base64 エンコード結果:\n\(encoded)",
                visibleSummary: encoded,
                prefersDirectReply: true
            )
        }

        return nil
    }

    private func urlCodingExecution(for prompt: String) -> AIAssistantToolExecution? {
        let normalized = prompt.lowercased()

        if normalized.contains("url") && (normalized.contains("decode") || normalized.contains("デコード")) {
            guard let source = extractColonPayload(from: prompt) ?? extractQuotedPayload(from: prompt) else { return nil }
            let decoded = source.removingPercentEncoding ?? source
            return AIAssistantToolExecution(
                toolName: "url-decode",
                contextText: "URL デコード結果:\n\(decoded)",
                visibleSummary: decoded,
                prefersDirectReply: true
            )
        }

        if normalized.contains("url") && (normalized.contains("encode") || normalized.contains("エンコード")) {
            guard let source = extractColonPayload(from: prompt) ?? extractQuotedPayload(from: prompt) else { return nil }
            let encoded = source.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? source
            return AIAssistantToolExecution(
                toolName: "url-encode",
                contextText: "URL エンコード結果:\n\(encoded)",
                visibleSummary: encoded,
                prefersDirectReply: true
            )
        }

        return nil
    }

    private func jsonExecution(for prompt: String) -> AIAssistantToolExecution? {
        let normalized = prompt.lowercased()
        let payload = firstMatch(pattern: #"```json\s*([\s\S]*?)```"#, in: prompt) ?? extractColonPayload(from: prompt)
        guard let source = payload?.trimmingCharacters(in: .whitespacesAndNewlines), !source.isEmpty else { return nil }

        if normalized.contains("json") && (normalized.contains("整形") || normalized.contains("pretty") || normalized.contains("format")) {
            return formatJSON(source, pretty: true)
        }

        if normalized.contains("json") && (normalized.contains("圧縮") || normalized.contains("minify")) {
            return formatJSON(source, pretty: false)
        }

        return nil
    }

    private func textStatsExecution(for prompt: String) -> AIAssistantToolExecution? {
        let normalized = prompt.lowercased()
        let trigger = normalized.contains("文字数") || normalized.contains("単語数") || normalized.contains("text stats") || normalized.contains("テキスト統計")
        guard trigger else { return nil }
        guard let source = extractColonPayload(from: prompt) ?? extractQuotedPayload(from: prompt) else { return nil }

        let characters = source.count
        let lines = source.components(separatedBy: .newlines).count
        let words = source.split { $0.isWhitespace || $0.isNewline }.count
        let summary = "文字数: \(characters)\n単語数: \(words)\n行数: \(lines)"
        return AIAssistantToolExecution(
            toolName: "text-stats",
            contextText: "テキスト統計:\n\(summary)",
            visibleSummary: summary,
            prefersDirectReply: true
        )
    }

    private func hashExecutions(for prompt: String) -> [AIAssistantToolExecution] {
        let normalized = prompt.lowercased()
        guard normalized.contains("sha256") || normalized.contains("md5") || normalized.contains("hash") || normalized.contains("ハッシュ") else {
            return []
        }
        guard let source = extractColonPayload(from: prompt) ?? extractQuotedPayload(from: prompt) else { return [] }

        var executions: [AIAssistantToolExecution] = []
        let data = Data(source.utf8)

        if normalized.contains("sha256") || normalized.contains("hash") || normalized.contains("ハッシュ") {
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            executions.append(
                AIAssistantToolExecution(
                    toolName: "sha256",
                    contextText: "SHA-256:\n\(digest)",
                    visibleSummary: digest,
                    prefersDirectReply: true
                )
            )
        }

        if normalized.contains("md5") {
            let digest = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
            executions.append(
                AIAssistantToolExecution(
                    toolName: "md5",
                    contextText: "MD5:\n\(digest)",
                    visibleSummary: digest,
                    prefersDirectReply: true
                )
            )
        }

        return executions
    }

    private func tableExecution(for prompt: String) -> AIAssistantToolExecution? {
        guard shouldUseTableTool(for: prompt),
              let payload = extractTabularPayload(from: prompt),
              let execution = tableExecution(fromSource: payload) else {
            return nil
        }
        return execution
    }

    private func tableExecution(fromSource payload: String) -> AIAssistantToolExecution? {
        guard let markdownTable = buildMarkdownTable(from: payload) else {
            return nil
        }

        return AIAssistantToolExecution(
            toolName: "table_builder",
            contextText: """
            表の下書き候補:
            \(markdownTable)

            この下書きをそのまま貼り付けず、ユーザーの依頼に合わせて列名や並びを整え、必要なら日本語の見出しや短い補足を付けて返してください。
            表が求められている場合は、message の中で Markdown の表として返してください。
            """,
            visibleSummary: "表生成 1回",
            prefersDirectReply: false
        )
    }

    private func shouldUseTableTool(for prompt: String) -> Bool {
        let normalized = prompt.lowercased()
        let phrases = [
            "表にして", "表でまとめて", "表形式", "テーブルにして", "テーブルで", "markdown表",
            "一覧表", "比較表", "表を作って", "table", "markdown table"
        ]
        return phrases.contains(where: { normalized.localizedCaseInsensitiveContains($0) })
    }

    private func extractTabularPayload(from prompt: String) -> String? {
        let patterns = [
            #"```json\s*([\s\S]*?)```"#,
            #"```csv\s*([\s\S]*?)```"#,
            #"```tsv\s*([\s\S]*?)```"#
        ]

        for pattern in patterns {
            if let match = firstMatch(pattern: pattern, in: prompt)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !match.isEmpty {
                return match
            }
        }

        if let payload = extractColonPayload(from: prompt) {
            return payload
        }

        if let quoted = extractQuotedPayload(from: prompt) {
            return quoted
        }

        return nil
    }

    private func buildMarkdownTable(from source: String) -> String? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let jsonTable = markdownTableFromJSON(trimmed) {
            return jsonTable
        }

        if let keyValueTable = markdownTableFromKeyValueLines(trimmed) {
            return keyValueTable
        }

        if let delimitedTable = markdownTableFromDelimitedText(trimmed) {
            return delimitedTable
        }

        if let bulletTable = markdownTableFromBulletList(trimmed) {
            return bulletTable
        }

        return nil
    }

    private func markdownTableFromJSON(_ source: String) -> String? {
        guard let data = source.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }

        if let dictionary = object as? [String: Any] {
            let rows = dictionary.map { [escapeMarkdownCell($0.key), escapeMarkdownCell(stringifyJSONValue($0.value))] }
            return markdownTable(headers: ["項目", "内容"], rows: rows)
        }

        if let array = object as? [[String: Any]], !array.isEmpty {
            var headers: [String] = []
            for item in array {
                for key in item.keys where !headers.contains(key) {
                    headers.append(key)
                }
            }
            let rows = array.map { item in
                headers.map { header in
                    escapeMarkdownCell(stringifyJSONValue(item[header] as Any))
                }
            }
            return markdownTable(headers: headers.map(escapeMarkdownCell), rows: rows)
        }

        if let array = object as? [Any], !array.isEmpty {
            let rows = array.map { [escapeMarkdownCell(stringifyJSONValue($0))] }
            return markdownTable(headers: ["項目"], rows: rows)
        }

        return nil
    }

    private func markdownTableFromKeyValueLines(_ source: String) -> String? {
        let lines = source
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let rows: [[String]] = lines.compactMap { line in
            if let range = line.range(of: "：") ?? line.range(of: ":") {
                let key = String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let value = String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty, !value.isEmpty else { return nil }
                return [escapeMarkdownCell(key), escapeMarkdownCell(value)]
            }
            return nil
        }

        guard rows.count >= 2 else { return nil }
        return markdownTable(headers: ["項目", "内容"], rows: rows)
    }

    private func markdownTableFromDelimitedText(_ source: String) -> String? {
        let lines = source
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard lines.count >= 2 else { return nil }

        let delimiter: Character
        if lines.allSatisfy({ $0.contains("\t") }) {
            delimiter = "\t"
        } else if lines.allSatisfy({ $0.contains(",") }) {
            delimiter = ","
        } else {
            return nil
        }

        let rows = lines.map { line in
            line.split(separator: delimiter, omittingEmptySubsequences: false)
                .map { escapeMarkdownCell(String($0).trimmingCharacters(in: .whitespacesAndNewlines)) }
        }

        guard let header = rows.first, header.count >= 2 else { return nil }
        let body = rows.dropFirst().filter { !$0.isEmpty }
        guard !body.isEmpty else { return nil }

        return markdownTable(headers: header, rows: Array(body))
    }

    private func markdownTableFromBulletList(_ source: String) -> String? {
        let rows = source
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .compactMap { line -> [String]? in
                let markers = ["- ", "* ", "・", "• "]
                guard let marker = markers.first(where: { line.hasPrefix($0) }) else { return nil }
                let value = String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : [escapeMarkdownCell(value)]
            }

        guard rows.count >= 2 else { return nil }
        return markdownTable(headers: ["項目"], rows: rows)
    }

    private func markdownTable(headers: [String], rows: [[String]]) -> String {
        let headerLine = "| " + headers.joined(separator: " | ") + " |"
        let separatorLine = "| " + Array(repeating: "---", count: headers.count).joined(separator: " | ") + " |"
        let bodyLines = rows.map { row in
            let paddedRow: [String]
            if row.count < headers.count {
                paddedRow = row + Array(repeating: "", count: headers.count - row.count)
            } else {
                paddedRow = Array(row.prefix(headers.count))
            }
            return "| " + paddedRow.joined(separator: " | ") + " |"
        }

        return ([headerLine, separatorLine] + bodyLines).joined(separator: "\n")
    }

    private func stringifyJSONValue(_ value: Any) -> String {
        if value is NSNull {
            return "-"
        }
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        if let array = value as? [Any] {
            return array.map { stringifyJSONValue($0) }.joined(separator: ", ")
        }
        if let dictionary = value as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return String(describing: value)
    }

    private func escapeMarkdownCell(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\n", with: "<br>")
            .replacingOccurrences(of: "|", with: "\\|")
    }

    private func extractPythonSource(from prompt: String) -> String? {
        if let fenced = firstMatch(pattern: #"```python\s*([\s\S]*?)```"#, in: prompt) {
            let cleaned = fenced.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? nil : cleaned
        }

        if containsPythonExecutionIntent(prompt),
           let fenced = firstMatch(pattern: #"```(?:py|python)?\s*([\s\S]*?)```"#, in: prompt) {
            let cleaned = fenced.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? nil : cleaned
        }

        for prefix in ["python:", "Python:", "PYTHON:", "py:", "Py:", "PY:"] {
            if let range = prompt.range(of: prefix) {
                let code = String(prompt[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                return code.isEmpty ? nil : code
            }
        }

        if containsPythonExecutionIntent(prompt) {
            if let payload = extractColonPayload(from: prompt), looksLikePythonSource(payload) {
                return payload
            }

            if let quoted = extractQuotedPayload(from: prompt), looksLikePythonSource(quoted) {
                return quoted
            }

            if let expressionSource = pythonExpressionSourceIfNeeded(from: prompt) {
                return expressionSource
            }
        }

        return nil
    }

    private func containsPythonExecutionIntent(_ prompt: String) -> Bool {
        let normalized = prompt.lowercased()
        let triggers = [
            "python", "pythonで", "python を使って", "pyで", "py:",
            "実行", "走らせ", "動かして", "試して", "検証", "コードを実行"
        ]
        return triggers.contains(where: { normalized.localizedCaseInsensitiveContains($0) })
    }

    private func looksLikePythonSource(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let strongMarkers = [
            "print(", "for ", "while ", "def ", "class ", "import ",
            "from ", "return ", "if ", "elif ", "else:", "with ",
            "range(", "len(", "json.", "pandas", "numpy"
        ]
        if strongMarkers.contains(where: { trimmed.localizedCaseInsensitiveContains($0) }) {
            return true
        }

        if trimmed.contains("\n"), trimmed.contains("=") {
            return true
        }

        return false
    }

    private func pythonExpressionSourceIfNeeded(from prompt: String) -> String? {
        guard prompt.localizedCaseInsensitiveContains("python") else { return nil }

        let expression = extractCalculationExpression(from: prompt)
        guard !expression.isEmpty, evaluateMathExpression(expression) != nil else {
            return nil
        }

        return "print(\(expression))"
    }

    private func extractCalculationExpression(from prompt: String) -> String {
        let normalizedPrompt = normalizeMathWords(in: prompt)
        if let payload = extractColonPayload(from: prompt) {
            return normalizeMathWords(in: payload)
        }

        let operators = CharacterSet(charactersIn: "0123456789+-*/().,% ")
        let filtered = normalizedPrompt.unicodeScalars.filter { operators.contains($0) }
        return String(String.UnicodeScalarView(filtered)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func looksLikeDirectMathQuestion(_ prompt: String) -> Bool {
        let normalized = normalizeMathWords(in: prompt)
            .replacingOccurrences(of: "？", with: "")
            .replacingOccurrences(of: "?", with: "")
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "は", with: "")
            .replacingOccurrences(of: "って", with: "")
            .replacingOccurrences(of: "ですか", with: "")
            .replacingOccurrences(of: "なんですか", with: "")
            .replacingOccurrences(of: "答え", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard normalized.range(of: #"[+\-*/%]"#, options: .regularExpression) != nil else {
            return false
        }

        let allowed = CharacterSet(charactersIn: "0123456789+-*/().,% ")
        return normalized.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private func normalizeMathWords(in text: String) -> String {
        text
            .replacingOccurrences(of: "タス", with: "+")
            .replacingOccurrences(of: "たす", with: "+")
            .replacingOccurrences(of: "足す", with: "+")
            .replacingOccurrences(of: "プラス", with: "+")
            .replacingOccurrences(of: "ヒク", with: "-")
            .replacingOccurrences(of: "ひく", with: "-")
            .replacingOccurrences(of: "引く", with: "-")
            .replacingOccurrences(of: "マイナス", with: "-")
            .replacingOccurrences(of: "カケル", with: "*")
            .replacingOccurrences(of: "かける", with: "*")
            .replacingOccurrences(of: "掛ける", with: "*")
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "ワル", with: "/")
            .replacingOccurrences(of: "わる", with: "/")
            .replacingOccurrences(of: "割る", with: "/")
            .replacingOccurrences(of: "÷", with: "/")
    }

    private func evaluateMathExpression(_ expression: String) -> String? {
        let cleaned = expression
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "％", with: "%")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        if cleaned.contains("%") {
            let normalized = cleaned.replacingOccurrences(of: "%", with: "*0.01")
            return evaluateMathExpression(normalized)
        }

        let allowed = CharacterSet(charactersIn: "0123456789+-*/(). ")
        guard cleaned.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }

        let expression = NSExpression(format: cleaned)
        guard let value = expression.expressionValue(with: nil, context: nil) as? NSNumber else { return nil }

        let number = value.doubleValue
        if number.rounded() == number {
            return String(Int(number))
        }
        return String(number)
    }

    private func formatJSON(_ source: String, pretty: Bool) -> AIAssistantToolExecution {
        guard let data = source.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let formattedData = try? JSONSerialization.data(withJSONObject: object, options: pretty ? [.prettyPrinted, .sortedKeys] : []),
              let formatted = String(data: formattedData, encoding: .utf8) else {
            return AIAssistantToolExecution(
                toolName: pretty ? "json-pretty" : "json-minify",
                contextText: "JSON 変換失敗: 入力が不正です。",
                visibleSummary: "JSON の形式が正しくないため変換できませんでした。",
                prefersDirectReply: true
            )
        }

        return AIAssistantToolExecution(
            toolName: pretty ? "json-pretty" : "json-minify",
            contextText: "JSON 変換結果:\n\(formatted)",
            visibleSummary: formatted,
            prefersDirectReply: true
        )
    }

    private func extractColonPayload(from prompt: String) -> String? {
        guard let range = prompt.range(of: ":") else { return nil }
        let payload = String(prompt[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return payload.isEmpty ? nil : payload
    }

    private func extractQuotedPayload(from prompt: String) -> String? {
        firstMatch(pattern: #""([^"]+)""#, in: prompt)
            ?? firstMatch(pattern: #"「([^」]+)」"#, in: prompt)
    }

    private func extractRequestedCount(from prompt: String) -> Int? {
        guard let match = firstMatch(pattern: #"([0-9]+)\s*個"#, in: prompt) ?? firstMatch(pattern: #"([0-9]+)"#, in: prompt) else {
            return nil
        }
        return Int(match)
    }

    private func runPython(source: String) async -> AIAssistantToolExecution {
        // 本物の Python (Pyodide) を優先実行。Pyodide の初期化に失敗 (オフライン等) した場合は
        // 既存の JS-based 制限版サブセットへフォールバック。
        let pyodideResult = await AIPyodideSandbox.shared.execute(code: source)
        if pyodideResult.success {
            return formatPythonResult(source: source, result: pyodideResult, runtimeLabel: "Pyodide")
        }
        // Pyodide が「初期化失敗」のときだけ JS フォールバックを試す。
        // Python の実行時エラー (ZeroDivisionError 等) はそのまま Pyodide の出力を返す方が正確。
        let stderr = pyodideResult.stderr
        let looksLikeInitFailure = stderr.contains("Pyodide の初期化に失敗")
            || stderr.contains("Pyodide 呼び出し失敗")
            || stderr.contains("Pyodide 結果のパースに失敗")
        if looksLikeInitFailure {
            let fallback = AIPythonSandbox.shared.execute(code: source)
            return formatPythonResult(source: source, result: fallback, runtimeLabel: "制限版 (Pyodide 未初期化)")
        }
        return formatPythonResult(source: source, result: pyodideResult, runtimeLabel: "Pyodide")
    }

    private func formatPythonResult(
        source: String,
        result: AIPythonSandbox.ExecutionResult,
        runtimeLabel: String
    ) -> AIAssistantToolExecution {
        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)

        if result.success {
            let visible = stdout.isEmpty ? "(出力なし)" : stdout
            return AIAssistantToolExecution(
                toolName: "python_exec",
                contextText: """
                Python 実行 (\(runtimeLabel)):
                ```python
                \(source)
                ```

                結果:
                \(visible)
                """,
                visibleSummary: stdout.isEmpty
                    ? "Python (\(runtimeLabel)) 出力なし"
                    : "Python (\(runtimeLabel)) 実行成功",
                prefersDirectReply: false
            )
        }

        let failureText = stderr.isEmpty ? "Python を実行できませんでした。" : stderr
        return AIAssistantToolExecution(
            toolName: "python_exec",
            contextText: """
            Python 実行 (\(runtimeLabel)):
            ```python
            \(source)
            ```

            実行失敗:
            \(failureText)
            """,
            visibleSummary: "Python (\(runtimeLabel)) 失敗",
            prefersDirectReply: false
        )
    }

    private func firstMatch(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges >= 2,
              let capturedRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[capturedRange])
    }
}
