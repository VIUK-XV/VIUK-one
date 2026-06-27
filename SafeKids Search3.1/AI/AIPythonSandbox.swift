/*
仕様:
- 役割: AI Studio から使う制限版 Python 実行系。app 内で完結し、ファイルI/O やネットワークを許可しない。
- 主な型: `AIPythonSandbox`, `ExecutionResult`.
- 編集ポイント: 許可構文や組み込み関数を増やすときに触る。
*/
import Foundation
import JavaScriptCore

final class AIPythonSandbox {
    static let shared = AIPythonSandbox()

    struct ValidationResult {
        let isValid: Bool
        let message: String?
    }

    struct ExecutionResult {
        let code: String
        let stdout: String
        let stderr: String
        let success: Bool
        let failureKind: FailureKind?
    }

    enum FailureKind: String {
        case unsupportedSyntax
        case blockedOperation
        case runtimeError
    }

    private enum SandboxError: LocalizedError {
        case emptyCode
        case blockedOperation(String)
        case unsupportedSyntax(String)
        case transpileFailure(String)

        var errorDescription: String? {
            switch self {
            case .emptyCode:
                return "実行コードが空です。"
            case .blockedOperation(let message),
                 .unsupportedSyntax(let message),
                 .transpileFailure(let message):
                return message
            }
        }
    }

    private let maxCodeLength = 12_000
    private let maxLineCount = 160
    private let maxRangeIterations = 512

    private init() {}

    func validate(code: String) -> ValidationResult {
        do {
            _ = try transpile(code)
            return ValidationResult(isValid: true, message: nil)
        } catch let error as SandboxError {
            return ValidationResult(isValid: false, message: error.errorDescription)
        } catch {
            return ValidationResult(isValid: false, message: error.localizedDescription)
        }
    }

    func execute(code: String) -> ExecutionResult {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let transpiled = try transpile(trimmed)
            var stdoutLines: [String] = []
            var runtimeError: String?

            guard let context = JSContext() else {
                return ExecutionResult(
                    code: trimmed,
                    stdout: "",
                    stderr: "制限版 Python の初期化に失敗しました。",
                    success: false,
                    failureKind: .runtimeError
                )
            }

            let printSink: @convention(block) (String) -> Void = { line in
                stdoutLines.append(line)
            }
            context.setObject(printSink, forKeyedSubscript: "__viukPrintSink" as NSString)
            context.exceptionHandler = { _, exception in
                runtimeError = exception?.toString() ?? "制限版 Python で実行時エラーが発生しました。"
            }

            _ = context.evaluateScript(javaScriptPrelude + "\n" + transpiled)
            if let runtimeError {
                return ExecutionResult(
                    code: trimmed,
                    stdout: stdoutLines.joined(separator: "\n"),
                    stderr: runtimeError,
                    success: false,
                    failureKind: .runtimeError
                )
            }

            return ExecutionResult(
                code: trimmed,
                stdout: stdoutLines.joined(separator: "\n"),
                stderr: "",
                success: true,
                failureKind: nil
            )
        } catch let error as SandboxError {
            let failureKind: FailureKind = switch error {
            case .blockedOperation:
                .blockedOperation
            case .unsupportedSyntax, .transpileFailure, .emptyCode:
                .unsupportedSyntax
            }
            return ExecutionResult(
                code: trimmed,
                stdout: "",
                stderr: error.errorDescription ?? "制限版 Python の実行に失敗しました。",
                success: false,
                failureKind: failureKind
            )
        } catch {
            return ExecutionResult(
                code: trimmed,
                stdout: "",
                stderr: error.localizedDescription,
                success: false,
                failureKind: .runtimeError
            )
        }
    }

    private func transpile(_ code: String) throws -> String {
        let normalized = code
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\t", with: "    ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty else {
            throw SandboxError.emptyCode
        }
        guard normalized.count <= maxCodeLength else {
            throw SandboxError.unsupportedSyntax("コードが長すぎるため、制限版 Python では実行できません。")
        }

        let lines = normalized.components(separatedBy: .newlines)
        guard lines.count <= maxLineCount else {
            throw SandboxError.unsupportedSyntax("行数が多すぎるため、制限版 Python では実行できません。")
        }

        try validateBlockedPatterns(in: normalized)

        var jsLines = ["(() => {"]
        var declaredVariables = Set<String>()
        var openBlocks: [(indent: Int, kind: String)] = []

        for rawLine in lines {
            let line = rawLine.replacingOccurrences(of: "\u{00A0}", with: " ")
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            let indentWidth = line.prefix { $0 == " " }.count
            guard indentWidth % 4 == 0 else {
                throw SandboxError.unsupportedSyntax("インデントは半角スペース4つ単位で書いてください。")
            }
            let indentLevel = indentWidth / 4

            if trimmed.hasPrefix("elif ") || trimmed == "else:" {
                while openBlocks.count > indentLevel + 1 {
                    jsLines.append(String(repeating: "    ", count: openBlocks.count - 1) + "}")
                    openBlocks.removeLast()
                }
                guard openBlocks.count == indentLevel + 1, openBlocks.last?.kind == "if" else {
                    throw SandboxError.unsupportedSyntax("elif / else の位置が不正です。")
                }

                if trimmed == "else:" {
                    jsLines.append(String(repeating: "    ", count: indentLevel) + "} else {")
                } else {
                    let condition = String(trimmed.dropFirst(5).dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                    jsLines.append(String(repeating: "    ", count: indentLevel) + "} else if (\(try translateExpression(condition))) {")
                }
                continue
            }

            while openBlocks.count > indentLevel {
                jsLines.append(String(repeating: "    ", count: openBlocks.count - 1) + "}")
                openBlocks.removeLast()
            }

            if let match = firstMatch(pattern: #"^for\s+([A-Za-z_][A-Za-z0-9_]*)\s+in\s+range\((.*)\):$"#, in: trimmed),
               match.count == 2 {
                let variableName = match[0]
                let rangeArgs = try splitTopLevel(match[1], separator: ",")
                    .map { try translateExpression($0) }
                    .joined(separator: ", ")
                jsLines.append(String(repeating: "    ", count: indentLevel) + "for (const \(variableName) of __viukRange(\(rangeArgs))) {")
                openBlocks.append((indentLevel, "for"))
                continue
            }

            if trimmed.hasPrefix("if "), trimmed.hasSuffix(":") {
                let condition = String(trimmed.dropFirst(3).dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                jsLines.append(String(repeating: "    ", count: indentLevel) + "if (\(try translateExpression(condition))) {")
                openBlocks.append((indentLevel, "if"))
                continue
            }

            if trimmed.hasPrefix("print("), trimmed.hasSuffix(")") {
                let inner = String(trimmed.dropFirst("print(".count).dropLast())
                let arguments = try splitTopLevel(inner, separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .map { try translateExpression($0) }
                    .joined(separator: ", ")
                jsLines.append(String(repeating: "    ", count: indentLevel) + "__viukPrint([\((arguments))]);")
                continue
            }

            if let assignment = firstMatch(pattern: #"^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+)$"#, in: trimmed),
               assignment.count == 2,
               !trimmed.contains("=="),
               !trimmed.contains("!="),
               !trimmed.contains(">="),
               !trimmed.contains("<=") {
                let variableName = assignment[0]
                let translatedExpression = try translateExpression(assignment[1])
                let declaration = declaredVariables.insert(variableName).inserted ? "let " : ""
                jsLines.append(String(repeating: "    ", count: indentLevel) + "\(declaration)\(variableName) = \(translatedExpression);")
                continue
            }

            if trimmed.hasPrefix("def ") || trimmed.hasPrefix("class ") || trimmed.hasPrefix("while ") {
                throw SandboxError.unsupportedSyntax("def / class / while は v1 の制限版 Python ではまだ使えません。")
            }

            jsLines.append(String(repeating: "    ", count: indentLevel) + "\(try translateExpression(trimmed));")
        }

        while !openBlocks.isEmpty {
            jsLines.append(String(repeating: "    ", count: openBlocks.count - 1) + "}")
            openBlocks.removeLast()
        }
        jsLines.append("})();")
        return jsLines.joined(separator: "\n")
    }

    private func validateBlockedPatterns(in code: String) throws {
        let blockedPatterns = [
            ("import ", "import は制限版 Python では使えません。"),
            ("open(", "ファイルI/O は制限版 Python では使えません。"),
            ("exec(", "exec は制限版 Python では使えません。"),
            ("eval(", "eval は制限版 Python では使えません。"),
            ("input(", "input は制限版 Python では使えません。"),
            ("__", "特殊属性アクセスは制限版 Python では使えません。"),
            ("subprocess", "サブプロセス起動は制限版 Python では使えません。"),
            ("socket", "ネットワーク機能は制限版 Python では使えません。"),
            ("requests", "ネットワーク機能は制限版 Python では使えません。"),
            ("urllib", "ネットワーク機能は制限版 Python では使えません。"),
            ("pathlib", "ファイルシステム操作は制限版 Python では使えません。"),
            ("os.", "OS 操作は制限版 Python では使えません。"),
            ("sys.", "システム操作は制限版 Python では使えません。")
        ]

        let normalized = code.lowercased()
        for (pattern, message) in blockedPatterns where normalized.contains(pattern) {
            throw SandboxError.blockedOperation(message)
        }
    }

    private func translateExpression(_ expression: String) throws -> String {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SandboxError.transpileFailure("式が空です。")
        }

        var translated = replaceOutsideStrings(
            in: trimmed,
            replacements: [
                (" and ", " && "),
                (" or ", " || "),
                ("True", "true"),
                ("False", "false"),
                ("None", "null"),
                ("math.pi", "Math.PI"),
                ("math.e", "Math.E"),
                ("math.sqrt", "Math.sqrt"),
                ("math.floor", "Math.floor"),
                ("math.ceil", "Math.ceil"),
                ("math.sin", "Math.sin"),
                ("math.cos", "Math.cos"),
                ("math.tan", "Math.tan"),
                ("math.log", "Math.log"),
                ("statistics.mean", "__viukStatistics.mean"),
                ("statistics.median", "__viukStatistics.median"),
                ("range(", "__viukRange("),
                ("len(", "__viukLen("),
                ("sum(", "__viukSum("),
                ("min(", "__viukMin("),
                ("max(", "__viukMax("),
                ("sorted(", "__viukSorted("),
                ("round(", "__viukRound("),
                ("str(", "__viukStr("),
                ("int(", "__viukInt("),
                ("float(", "__viukFloat(")
            ]
        )

        translated = replaceNotKeyword(in: translated)
        return translated
    }

    private func replaceOutsideStrings(in text: String, replacements: [(String, String)]) -> String {
        var result = ""
        var index = text.startIndex
        var activeQuote: Character?
        var escaping = false

        while index < text.endIndex {
            let character = text[index]
            if escaping {
                result.append(character)
                escaping = false
                index = text.index(after: index)
                continue
            }

            if character == "\\" {
                result.append(character)
                escaping = true
                index = text.index(after: index)
                continue
            }

            if let currentQuote = activeQuote {
                result.append(character)
                if character == currentQuote {
                    activeQuote = nil
                }
                index = text.index(after: index)
                continue
            }

            if character == "\"" || character == "'" {
                activeQuote = character
                result.append(character)
                index = text.index(after: index)
                continue
            }

            if let replacement = replacements.first(where: { text[index...].hasPrefix($0.0) }) {
                result.append(replacement.1)
                index = text.index(index, offsetBy: replacement.0.count)
            } else {
                result.append(character)
                index = text.index(after: index)
            }
        }

        return result
    }

    private func replaceNotKeyword(in text: String) -> String {
        var result = ""
        let scalars = Array(text.unicodeScalars)
        var index = 0

        while index < scalars.count {
            if index + 2 < scalars.count,
               String(String.UnicodeScalarView(scalars[index...(index + 2)])) == "not" {
                let previousIsBoundary = index == 0 || CharacterSet.alphanumerics.inverted.contains(scalars[index - 1])
                let nextIndex = index + 3
                let nextIsBoundary = nextIndex >= scalars.count || CharacterSet.alphanumerics.inverted.contains(scalars[nextIndex])
                if previousIsBoundary && nextIsBoundary {
                    result.append("!")
                    index += 3
                    continue
                }
            }
            result.append(Character(scalars[index]))
            index += 1
        }

        return result
    }

    private func splitTopLevel(_ text: String, separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        var activeQuote: Character?
        var escaping = false

        for character in text {
            if escaping {
                current.append(character)
                escaping = false
                continue
            }

            if character == "\\" {
                current.append(character)
                escaping = true
                continue
            }

            if let quote = activeQuote {
                current.append(character)
                if character == quote {
                    activeQuote = nil
                }
                continue
            }

            if character == "\"" || character == "'" {
                activeQuote = character
                current.append(character)
                continue
            }

            if character == "[" || character == "(" || character == "{" {
                depth += 1
                current.append(character)
                continue
            }

            if character == "]" || character == ")" || character == "}" {
                depth = max(0, depth - 1)
                current.append(character)
                continue
            }

            if character == separator, depth == 0 {
                parts.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
                continue
            }

            current.append(character)
        }

        let final = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !final.isEmpty {
            parts.append(final)
        }
        return parts
    }

    private func firstMatch(pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges >= 2 else {
            return nil
        }
        return (1..<match.numberOfRanges).compactMap { index in
            guard let range = Range(match.range(at: index), in: text) else { return nil }
            return String(text[range])
        }
    }

    private var javaScriptPrelude: String {
        """
        const __VIUK_MAX_RANGE__ = \(maxRangeIterations);
        function __viukStringify(value) {
          if (value === null || value === undefined) return "None";
          if (typeof value === "boolean") return value ? "True" : "False";
          if (Array.isArray(value)) return "[" + value.map(__viukStringify).join(", ") + "]";
          if (typeof value === "object") return JSON.stringify(value);
          return String(value);
        }
        function __viukPrint(values) {
          __viukPrintSink(values.map(__viukStringify).join(" "));
        }
        function __viukRange(a, b, c) {
          let start = 0;
          let end = 0;
          let step = 1;
          if (b === undefined) {
            end = Number(a);
          } else if (c === undefined) {
            start = Number(a);
            end = Number(b);
          } else {
            start = Number(a);
            end = Number(b);
            step = Number(c);
          }
          if (!Number.isFinite(start) || !Number.isFinite(end) || !Number.isFinite(step) || step === 0) {
            throw new Error("range の引数が不正です。");
          }
          const values = [];
          if (step > 0) {
            for (let i = start; i < end; i += step) {
              values.push(i);
              if (values.length > __VIUK_MAX_RANGE__) throw new Error("range が大きすぎます。");
            }
          } else {
            for (let i = start; i > end; i += step) {
              values.push(i);
              if (values.length > __VIUK_MAX_RANGE__) throw new Error("range が大きすぎます。");
            }
          }
          return values;
        }
        function __viukLen(value) {
          if (typeof value === "string" || Array.isArray(value)) return value.length;
          if (value && typeof value === "object") return Object.keys(value).length;
          throw new Error("len() は文字列、配列、辞書にだけ使えます。");
        }
        function __viukSum(values) {
          if (!Array.isArray(values)) throw new Error("sum() は配列にだけ使えます。");
          return values.reduce((acc, value) => acc + Number(value), 0);
        }
        function __viukMin(values) {
          if (Array.isArray(values)) return values.reduce((acc, value) => acc < value ? acc : value);
          return Math.min.apply(null, arguments);
        }
        function __viukMax(values) {
          if (Array.isArray(values)) return values.reduce((acc, value) => acc > value ? acc : value);
          return Math.max.apply(null, arguments);
        }
        function __viukSorted(values) {
          if (!Array.isArray(values)) throw new Error("sorted() は配列にだけ使えます。");
          return [...values].sort((a, b) => {
            if (typeof a === "number" && typeof b === "number") return a - b;
            return String(a).localeCompare(String(b), "ja");
          });
        }
        function __viukRound(value, digits) {
          if (digits === undefined) return Math.round(Number(value));
          const factor = Math.pow(10, Number(digits));
          return Math.round(Number(value) * factor) / factor;
        }
        function __viukStr(value) { return __viukStringify(value); }
        function __viukInt(value) { return parseInt(value, 10); }
        function __viukFloat(value) { return parseFloat(value); }
        const __viukStatistics = {
          mean(values) {
            if (!Array.isArray(values) || values.length === 0) throw new Error("statistics.mean() は空でない配列にだけ使えます。");
            return __viukSum(values) / values.length;
          },
          median(values) {
            if (!Array.isArray(values) || values.length === 0) throw new Error("statistics.median() は空でない配列にだけ使えます。");
            const sorted = __viukSorted(values).map(Number);
            const mid = Math.floor(sorted.length / 2);
            return sorted.length % 2 === 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid];
          }
        };
        """
    }
}
