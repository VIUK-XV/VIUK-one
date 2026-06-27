/*
仕様:
- 役割: ユーザーがチャットへ添付したドキュメント (PDF / プレーンテキスト等) を、
        Web 検索結果と同じ「外部情報源」として扱うためのモデルと読み込みヘルパー。
- 設計方針:
    1. ファイル本文はディスクから読み込んだ直後に `PromptInjectionDefense.sanitize`
       を通し、制御トークン・「指示を無視」型の文言・ロールヘッダなどを無害化する。
       (ユーザー指示の悪意ある PDF / テキスト経由のプロンプトインジェクション対策)
    2. 上限文字数 (FileAttachmentLimits.maxCharacters) を超える本文は途中で切り捨てる。
       コンテキストウィンドウ爆発と "needle in haystack" 攻撃の両方を抑止する。
    3. このモデルは添付時点で本文をテキスト化して保持する。Gemma 4 26B Web 読解は、
        `OllamaWebSearchService.readSpecificURLExtractsForPrompt` に `WebPageExtract`
       として渡され、Web ページと同じパイプラインで圧縮される。
*/

import Foundation
#if canImport(PDFKit)
import PDFKit
#endif
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// チャットに添付された 1 ファイル分のスナップショット。
/// 本文 (`extractedText`) は読み込み時にサニタイズ済み・長さ制限済み。
struct ChatFileAttachment: Hashable, Codable, Sendable, Identifiable {
    let id: UUID
    let filename: String
    let mimeType: String
    let byteSize: Int
    /// 本文プレーンテキスト。`PromptInjectionDefense.sanitize` 済み・最大 16000 字。
    let extractedText: String
    /// 本文の元の長さ。`extractedText` が打ち切られた場合に元サイズを把握するため保持。
    let originalCharacterCount: Int
    /// 読み込み時に切り捨てが発生したか。
    let truncated: Bool

    init(
        id: UUID = UUID(),
        filename: String,
        mimeType: String,
        byteSize: Int,
        extractedText: String,
        originalCharacterCount: Int,
        truncated: Bool
    ) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.byteSize = byteSize
        self.extractedText = extractedText
        self.originalCharacterCount = originalCharacterCount
        self.truncated = truncated
    }
}

enum FileAttachmentLimits {
    /// 1 ファイルあたりに保持する本文の最大文字数。
    /// これ以上は 26B へ渡してもコンテキスト圧迫が大きく、圧縮効果も薄い。
    static let maxCharacters = 16_000
    /// 1 リクエストで添付できる最大ファイル数。
    static let maxFilesPerRequest = 5
}

enum ChatFileAttachmentLoader {

    enum LoadError: LocalizedError {
        case unreadable(URL)
        case unsupportedType(String)
        case empty(URL)

        var errorDescription: String? {
            switch self {
            case .unreadable(let url):
                return "ファイルを読み込めませんでした: \(url.lastPathComponent)"
            case .unsupportedType(let typeName):
                return "未対応のファイル形式です: \(typeName)"
            case .empty(let url):
                return "ファイル本文が空でした: \(url.lastPathComponent)"
            }
        }
    }

    /// ローカルファイル URL からテキストを抽出して `ChatFileAttachment` を作る。
    /// - PDF は PDFKit でテキスト化。
    /// - その他はまず UTF-8 / Shift-JIS 順に試して読む。
    /// - 抽出後に `PromptInjectionDefense.sanitize` を必ず通す。
    static func load(from url: URL) throws -> ChatFileAttachment {
        let didSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if didSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let byteSize = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        let filename = url.lastPathComponent
        let mimeType = inferMIMEType(for: url)

        let rawText: String
        if mimeType == "application/pdf" || url.pathExtension.lowercased() == "pdf" {
            rawText = try extractPDFText(at: url)
        } else {
            rawText = try extractPlainText(at: url)
        }

        let trimmedRaw = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRaw.isEmpty else {
            throw LoadError.empty(url)
        }

        // 1) 長さで切る (爆発防止)。
        let originalCount = trimmedRaw.count
        let truncated = originalCount > FileAttachmentLimits.maxCharacters
        let capped = truncated
            ? String(trimmedRaw.prefix(FileAttachmentLimits.maxCharacters))
            : trimmedRaw

        // 2) プロンプトインジェクション対策: 制御トークン・「指示を無視」「あなたは今〜」型・
        //    SYSTEM:/USER: ロールヘッダ・閉じタグ風インジェクションを無害化する。
        let sanitized = PromptInjectionDefense.sanitize(capped)

        return ChatFileAttachment(
            filename: filename,
            mimeType: mimeType,
            byteSize: byteSize,
            extractedText: sanitized,
            originalCharacterCount: originalCount,
            truncated: truncated
        )
    }

    private static func extractPlainText(at url: URL) throws -> String {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw LoadError.unreadable(url)
        }
        // UTF-8 → Shift-JIS → ISO-2022-JP の順で試す。
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        if let sjis = String(data: data, encoding: .shiftJIS) {
            return sjis
        }
        if let iso = String(data: data, encoding: .iso2022JP) {
            return iso
        }
        throw LoadError.unreadable(url)
    }

    private static func extractPDFText(at url: URL) throws -> String {
        #if canImport(PDFKit)
        guard let doc = PDFDocument(url: url) else {
            throw LoadError.unreadable(url)
        }
        var pieces: [String] = []
        for index in 0..<doc.pageCount {
            guard let page = doc.page(at: index) else { continue }
            if let s = page.string, !s.isEmpty {
                pieces.append(s)
            }
        }
        return pieces.joined(separator: "\n\n")
        #else
        throw LoadError.unsupportedType("application/pdf")
        #endif
    }

    private static func inferMIMEType(for url: URL) -> String {
        #if canImport(UniformTypeIdentifiers)
        if let type = UTType(filenameExtension: url.pathExtension),
           let mime = type.preferredMIMEType {
            return mime
        }
        #endif
        switch url.pathExtension.lowercased() {
        case "pdf": return "application/pdf"
        case "txt", "log": return "text/plain"
        case "md", "markdown": return "text/markdown"
        case "json": return "application/json"
        case "csv": return "text/csv"
        case "html", "htm": return "text/html"
        case "rtf": return "application/rtf"
        case "swift", "py", "js", "ts", "go", "rs", "java", "c", "cpp", "h":
            return "text/plain"
        default:
            return "application/octet-stream"
        }
    }
}
