/*
仕様:
- 役割: AI Studio の Agent Mode 専用 WebView と視覚コンテキストを提供する。
- 主な型: `AgentBrowserView`, `AgentBrowserController`, `AgentVisualContext`,
  `InteractiveElement`, `WebViewSnapshotService`, `InteractiveElementExtractor`,
  `VisualAgentActionParser`。
- 方針: 初期実装では自由座標クリックを許可せず、DOM から抽出した interactiveElements の id だけを
  Gemma 4 に選ばせる。危険操作はユーザー確認を挟む。
*/

#if canImport(WebKit)
import SwiftUI
import WebKit
import Combine

#if canImport(AppKit)
import AppKit
private typealias AgentPlatformImage = NSImage
#elseif canImport(UIKit)
import UIKit
private typealias AgentPlatformImage = UIImage
#endif

// MARK: - Visual context models

struct AgentVisualContext {
    let screenshotImage: Data?
    let currentURL: URL?
    let title: String
    let visibleText: String
    let interactiveElements: [InteractiveElement]
    let viewportSize: CGSize
}

struct InteractiveElement: Identifiable, Codable, Hashable {
    enum ElementType: String, Codable {
        case link
        case button
        case input
        case select
        case textarea
    }

    var id: String
    var type: ElementType
    var text: String
    var ariaLabel: String
    var placeholder: String
    var href: String
    var bounds: CGRect
    var isVisible: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case text
        case ariaLabel
        case placeholder
        case href
        case bounds
        case isVisible
    }

    enum BoundsKeys: String, CodingKey {
        case x
        case y
        case width
        case height
    }

    init(
        id: String,
        type: ElementType,
        text: String,
        ariaLabel: String,
        placeholder: String,
        href: String,
        bounds: CGRect,
        isVisible: Bool
    ) {
        self.id = id
        self.type = type
        self.text = text
        self.ariaLabel = ariaLabel
        self.placeholder = placeholder
        self.href = href
        self.bounds = bounds
        self.isVisible = isVisible
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = try container.decode(ElementType.self, forKey: .type)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        ariaLabel = try container.decodeIfPresent(String.self, forKey: .ariaLabel) ?? ""
        placeholder = try container.decodeIfPresent(String.self, forKey: .placeholder) ?? ""
        href = try container.decodeIfPresent(String.self, forKey: .href) ?? ""
        isVisible = try container.decodeIfPresent(Bool.self, forKey: .isVisible) ?? false

        let boundsContainer = try container.nestedContainer(keyedBy: BoundsKeys.self, forKey: .bounds)
        let x = try boundsContainer.decodeIfPresent(CGFloat.self, forKey: .x) ?? 0
        let y = try boundsContainer.decodeIfPresent(CGFloat.self, forKey: .y) ?? 0
        let width = try boundsContainer.decodeIfPresent(CGFloat.self, forKey: .width) ?? 0
        let height = try boundsContainer.decodeIfPresent(CGFloat.self, forKey: .height) ?? 0
        bounds = CGRect(x: x, y: y, width: width, height: height)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(type, forKey: .type)
        try container.encode(text, forKey: .text)
        try container.encode(ariaLabel, forKey: .ariaLabel)
        try container.encode(placeholder, forKey: .placeholder)
        try container.encode(href, forKey: .href)
        try container.encode(isVisible, forKey: .isVisible)

        var boundsContainer = container.nestedContainer(keyedBy: BoundsKeys.self, forKey: .bounds)
        try boundsContainer.encode(bounds.origin.x, forKey: .x)
        try boundsContainer.encode(bounds.origin.y, forKey: .y)
        try boundsContainer.encode(bounds.size.width, forKey: .width)
        try boundsContainer.encode(bounds.size.height, forKey: .height)
    }

    var displayLabel: String {
        let candidates = [text, ariaLabel, placeholder, href]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return candidates.first(where: { !$0.isEmpty }) ?? id
    }
}

struct VisualAgentAction: Codable, Hashable {
    enum ActionType: String, Codable {
        case clickElement = "click_element"
        case none
    }

    let action: ActionType
    let target: String?
    let reason: String
}

struct PendingAgentConfirmation: Identifiable {
    let id = UUID()
    let action: VisualAgentAction
    let element: InteractiveElement
    let message: String
}

// MARK: - Snapshot

@MainActor
final class WebViewSnapshotService {
    func makeContext(for webView: WKWebView) async -> AgentVisualContext {
        async let screenshot = captureScreenshotData(webView)
        async let visibleText = extractVisibleText(webView)
        async let elements = InteractiveElementExtractor().extract(from: webView)
        let size = webView.bounds.size
        return AgentVisualContext(
            screenshotImage: await screenshot,
            currentURL: webView.url,
            title: webView.title ?? "",
            visibleText: await visibleText,
            interactiveElements: await elements,
            viewportSize: size
        )
    }

    private func captureScreenshotData(_ webView: WKWebView) async -> Data? {
        await withCheckedContinuation { continuation in
            let config = WKSnapshotConfiguration()
            config.rect = webView.bounds
            webView.takeSnapshot(with: config) { image, _ in
                continuation.resume(returning: image?.agentPNGData())
            }
        }
    }

    private func extractVisibleText(_ webView: WKWebView) async -> String {
        let js = """
        (function() {
          try {
            const clone = document.body ? document.body.cloneNode(true) : null;
            if (!clone) return '';
            clone.querySelectorAll('script,style,noscript,iframe,svg').forEach(e => e.remove());
            return (clone.innerText || clone.textContent || '')
              .replace(/[ \\t]+/g, ' ')
              .replace(/\\n{3,}/g, '\\n\\n')
              .trim()
              .slice(0, 6000);
          } catch(e) { return ''; }
        })();
        """
        do {
            return (try await webView.evaluateJavaScript(js) as? String) ?? ""
        } catch {
            return ""
        }
    }
}

// MARK: - DOM extraction

@MainActor
final class InteractiveElementExtractor {
    func extract(from webView: WKWebView) async -> [InteractiveElement] {
        let js = """
        (function() {
          try {
            const nodes = Array.from(document.querySelectorAll('a,button,input,select,textarea'));
            const viewportW = window.innerWidth || document.documentElement.clientWidth || 0;
            const viewportH = window.innerHeight || document.documentElement.clientHeight || 0;
            const out = [];
            let index = 0;
            for (const el of nodes) {
              const tag = (el.tagName || '').toLowerCase();
              const rect = el.getBoundingClientRect();
              const style = window.getComputedStyle(el);
              const visible =
                rect.width > 3 && rect.height > 3 &&
                rect.bottom >= 0 && rect.right >= 0 &&
                rect.top <= viewportH && rect.left <= viewportW &&
                style.visibility !== 'hidden' &&
                style.display !== 'none' &&
                Number(style.opacity || '1') > 0.01;
              if (!visible) continue;
              let type = tag === 'a' ? 'link' : tag;
              if (tag === 'input') {
                const inputType = (el.getAttribute('type') || '').toLowerCase();
                if (['hidden','password','file'].includes(inputType)) continue;
              }
              index += 1;
              const id = `${type}_${index}`;
              el.setAttribute('data-viuk-agent-id', id);
              const text = (el.innerText || el.value || el.textContent || '').replace(/\\s+/g, ' ').trim().slice(0, 160);
              out.push({
                id,
                type,
                text,
                ariaLabel: (el.getAttribute('aria-label') || '').trim().slice(0, 160),
                placeholder: (el.getAttribute('placeholder') || '').trim().slice(0, 160),
                href: tag === 'a' ? (el.href || '') : '',
                bounds: { x: rect.left, y: rect.top, width: rect.width, height: rect.height },
                isVisible: true
              });
              if (out.length >= 80) break;
            }
            return JSON.stringify(out);
          } catch(e) { return '[]'; }
        })();
        """

        do {
            guard let raw = try await webView.evaluateJavaScript(js) as? String,
                  let data = raw.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([InteractiveElement].self, from: data)) ?? []
        } catch {
            return []
        }
    }
}

// MARK: - Action parser

struct VisualAgentActionParser {
    func parse(_ raw: String) -> VisualAgentAction? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let jsonText: String
        if let start = trimmed.firstIndex(of: "{"),
           let end = trimmed.lastIndex(of: "}"),
           start <= end {
            jsonText = String(trimmed[start...end])
        } else {
            jsonText = trimmed
        }

        guard let data = jsonText.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(VisualAgentAction.self, from: data)
    }
}

// MARK: - Controller

@MainActor
final class AgentBrowserController: NSObject, ObservableObject {
    enum Step: String {
        case idle = "待機中"
        case loading = "ページを開いています"
        case analyzing = "画面を解析中"
        case choosing = "ボタンを選択中"
        case opening = "リンクを開いています"
        case blocked = "安全確認が必要です"
        case done = "完了"
    }

    @Published var urlText = "https://www.google.com"
    @Published var objective = "この画面で次に押すべきリンクやボタンを選ぶ"
    @Published private(set) var step: Step = .idle
    @Published private(set) var visualContext: AgentVisualContext?
    @Published private(set) var selectedAction: VisualAgentAction?
    @Published private(set) var selectedElementID: String?
    @Published var pendingConfirmation: PendingAgentConfirmation?
    @Published var statusMessage = "Agent Mode は DOM の element_id だけを選んで操作します。"

    let webView: WKWebView

    private let snapshotService = WebViewSnapshotService()
    private let parser = VisualAgentActionParser()

    override init() {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        self.webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.customUserAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    }

    func loadURLFromInput() {
        guard let url = normalizedURL(from: urlText) else {
            statusMessage = "URL が正しくありません。"
            return
        }
        guard AgentURLSafety.isAllowed(url) else {
            statusMessage = "このURLはAgent Modeでは開けません: \(url.absoluteString)"
            step = .blocked
            return
        }
        step = .loading
        statusMessage = "ページを開いています。"
        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20))
    }

    func analyzeAndChoose() {
        Task {
            step = .analyzing
            statusMessage = "画面を解析中"
            let context = await snapshotService.makeContext(for: webView)
            visualContext = context

            guard !context.interactiveElements.isEmpty else {
                statusMessage = "押せる候補が見つかりません。"
                step = .done
                return
            }

            step = .choosing
            statusMessage = "Gemma 4 E4B が候補IDを選んでいます。"
            let prompt = agentPrompt(for: context)
            let systemPrompt = """
            You are VIUK Agent Mode. Choose the next safe UI action from the provided DOM interactiveElements only.
            Return only one JSON object. Never include markdown.
            Schema: {"action":"click_element","target":"element_id","reason":"short Japanese reason"}
            You must not output click_coordinates.
            Do not choose actions that log in, purchase, post, submit forms, pay, upload files, or enter personal information unless the user explicitly asks and the app can confirm with the user.
            If no safe action exists, return {"action":"none","target":null,"reason":"安全に自動実行できる候補がありません"}.
            """
            let raw = await LocalAssistantRuntimeBridge.shared.generateReply(
                prompt: prompt,
                contextPrompt: nil,
                coachMode: .studio,
                reasoningMode: .thinking,
                researchMode: .off,
                childAge: 13,
                pageInfo: nil,
                safetySnapshot: nil,
                overrideSystemPrompt: systemPrompt
            )
            guard let action = raw.flatMap({ parser.parse($0) }) else {
                selectedAction = nil
                selectedElementID = nil
                statusMessage = "Gemma の action JSON を解釈できませんでした。"
                step = .done
                return
            }
            selectedAction = action
            selectedElementID = action.target
            statusMessage = action.reason
            if action.action == .clickElement, let target = action.target {
                prepareOrExecuteClick(targetID: target, action: action)
            } else {
                step = .done
            }
        }
    }

    func confirmPendingAction() {
        guard let pending = pendingConfirmation else { return }
        pendingConfirmation = nil
        Task {
            await executeClick(element: pending.element)
        }
    }

    func cancelPendingAction() {
        pendingConfirmation = nil
        step = .blocked
        statusMessage = "危険操作の可能性があるため実行しませんでした。"
    }

    private func prepareOrExecuteClick(targetID: String, action: VisualAgentAction) {
        guard let context = visualContext,
              let element = context.interactiveElements.first(where: { $0.id == targetID && $0.isVisible }) else {
            step = .blocked
            statusMessage = "指定された element_id が現在の画面に存在しません: \(targetID)"
            return
        }
        guard AgentURLSafety.isAllowed(context.currentURL) else {
            step = .blocked
            statusMessage = "現在のURLはAgent Modeで操作できません。"
            return
        }
        if !element.href.isEmpty, let hrefURL = URL(string: element.href), !AgentURLSafety.isAllowed(hrefURL) {
            step = .blocked
            statusMessage = "遷移先URLがブロック対象です: \(element.href)"
            return
        }
        if let warning = AgentActionSafety.confirmationReason(for: element) {
            step = .blocked
            pendingConfirmation = PendingAgentConfirmation(action: action, element: element, message: warning)
            statusMessage = warning
            return
        }
        Task {
            await executeClick(element: element)
        }
    }

    private func executeClick(element: InteractiveElement) async {
        step = .opening
        statusMessage = element.type == .link ? "リンクを開いています" : "ボタンを押しています"
        let js = """
        (function() {
          const id = \(Self.jsString(element.id));
          const el = document.querySelector('[data-viuk-agent-id="' + CSS.escape(id) + '"]');
          if (!el) return JSON.stringify({ ok: false, message: 'element not found' });
          el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
          const tag = (el.tagName || '').toLowerCase();
          if (['input','select','textarea'].includes(tag)) {
            el.focus();
            return JSON.stringify({ ok: true, message: 'focused' });
          }
          el.click();
          return JSON.stringify({ ok: true, message: 'clicked' });
        })();
        """
        do {
            _ = try await webView.evaluateJavaScript(js)
            try? await Task.sleep(nanoseconds: 650_000_000)
            visualContext = await snapshotService.makeContext(for: webView)
            step = .done
            statusMessage = "実行しました。"
        } catch {
            step = .blocked
            statusMessage = "クリック実行に失敗しました: \(error.localizedDescription)"
        }
    }

    private func agentPrompt(for context: AgentVisualContext) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let elementJSON: String
        if let data = try? encoder.encode(context.interactiveElements),
           let json = String(data: data, encoding: .utf8) {
            elementJSON = json
        } else {
            elementJSON = "[]"
        }
        return """
        ユーザー目的:
        \(objective)

        現在URL:
        \(context.currentURL?.absoluteString ?? "")

        ページタイトル:
        \(context.title)

        ビューポート:
        \(Int(context.viewportSize.width)) x \(Int(context.viewportSize.height))

        画面内テキスト:
        \(context.visibleText)

        interactiveElements:
        \(elementJSON)

        指示:
        - target は必ず interactiveElements の id から選ぶ。
        - click_coordinates は絶対に出さない。
        - ログイン、購入、投稿、送信、決済、個人情報入力、ファイルアップロードにつながる操作は選ばない。
        - 返答は JSON オブジェクト1個だけ。
        """
    }

    private func normalizedURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.scheme != nil {
            return url
        }
        return URL(string: "https://" + trimmed)
    }

    private static func jsString(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let encoded = String(data: data, encoding: .utf8) else { return "''" }
        return encoded
    }
}

extension AgentBrowserController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        urlText = webView.url?.absoluteString ?? urlText
        Task {
            visualContext = await snapshotService.makeContext(for: webView)
            if step == .loading {
                step = .done
                statusMessage = "ページを開きました。解析できます。"
            }
        }
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if AgentURLSafety.isAllowed(navigationAction.request.url) {
            decisionHandler(.allow)
        } else {
            step = .blocked
            statusMessage = "Agent Modeで禁止されたURLです。"
            decisionHandler(.cancel)
        }
    }
}

// MARK: - Safety

enum AgentURLSafety {
    static func isAllowed(_ url: URL?) -> Bool {
        guard let url else { return true }
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            return false
        }
        guard let host = url.host?.lowercased(), !host.isEmpty else { return false }
        if host == "localhost" || host.hasSuffix(".localhost") { return false }
        if host == "0.0.0.0" || host == "::1" { return false }
        if host.hasPrefix("fc") || host.hasPrefix("fd") || host.hasPrefix("fe80") { return false }
        if isPrivateIPv4(host) { return false }
        return true
    }

    private static func isPrivateIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        if parts[0] == 10 { return true }
        if parts[0] == 127 { return true }
        if parts[0] == 169 && parts[1] == 254 { return true }
        if parts[0] == 172 && (16...31).contains(parts[1]) { return true }
        if parts[0] == 192 && parts[1] == 168 { return true }
        return false
    }
}

enum AgentActionSafety {
    static func confirmationReason(for element: InteractiveElement) -> String? {
        switch element.type {
        case .input, .select, .textarea:
            return "フォーム操作はユーザー確認が必要です。"
        case .link, .button:
            break
        }
        let haystack = [
            element.text,
            element.ariaLabel,
            element.placeholder,
            element.href
        ]
        .joined(separator: " ")
        .lowercased()

        let riskyWords = [
            "login", "sign in", "signin", "log in", "register", "signup", "sign up",
            "buy", "purchase", "checkout", "cart", "order", "pay", "payment",
            "submit", "send", "post", "tweet", "upload", "delete", "remove",
            "ログイン", "登録", "購入", "決済", "支払", "注文", "送信", "投稿", "アップロード", "削除", "申し込"
        ]
        if riskyWords.contains(where: { haystack.contains($0) }) {
            return "ログイン・購入・投稿・送信などに繋がる可能性があるため確認が必要です。"
        }
        return nil
    }
}

// MARK: - UI

struct AgentBrowserView: View {
    @StateObject private var controller = AgentBrowserController()
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                toolbar
                AgentWebViewRepresentable(webView: controller.webView)
                    .overlay(alignment: .topLeading) {
                        if let element = highlightedElement {
                            AgentElementHighlight(element: element)
                        }
                    }
            }
            Divider()
            inspector
                .frame(width: 340)
        }
        .background(Color.appCanvasBackground.ignoresSafeArea())
        .alert(item: $controller.pendingConfirmation) { pending in
            Alert(
                title: Text("確認が必要です"),
                message: Text("\(pending.message)\n\n\(pending.element.displayLabel)"),
                primaryButton: .default(Text("実行する")) {
                    controller.confirmPendingAction()
                },
                secondaryButton: .cancel(Text("キャンセル")) {
                    controller.cancelPendingAction()
                }
            )
        }
    }

    private var highlightedElement: InteractiveElement? {
        guard let id = controller.selectedElementID else { return nil }
        return controller.visualContext?.interactiveElements.first { $0.id == id }
    }

    private var toolbar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Button(action: onClose) {
                    Label("AI Studio", systemImage: "chevron.left")
                }
                .buttonStyle(.bordered)

                TextField("URL", text: $controller.urlText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { controller.loadURLFromInput() }

                Button("開く") {
                    controller.loadURLFromInput()
                }
                .buttonStyle(.borderedProminent)
            }
            HStack(spacing: 10) {
                TextField("Agentの目的", text: $controller.objective)
                    .textFieldStyle(.roundedBorder)
                Button {
                    controller.analyzeAndChoose()
                } label: {
                    Label("解析して選択", systemImage: "sparkle.magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(.thinMaterial)
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label("Agent Mode", systemImage: "cursorarrow.motionlines.click")
                    .font(.system(size: 18, weight: .bold))

                stepCard
                screenshotCard
                selectedCard
                elementsCard
            }
            .padding(16)
        }
        .background(Color.appSecondaryBackground.opacity(0.26))
    }

    private var stepCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(controller.step.rawValue)
                .font(.system(size: 14, weight: .bold))
            Text(controller.statusMessage)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                AgentStepPill(title: "画面を解析中", isActive: controller.step == .analyzing)
                AgentStepPill(title: "ボタンを選択中", isActive: controller.step == .choosing)
                AgentStepPill(title: "リンクを開いています", isActive: controller.step == .opening)
            }
        }
        .agentCard()
    }

    @ViewBuilder
    private var screenshotCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("スクリーンショット")
                .font(.system(size: 13, weight: .bold))
            if let data = controller.visualContext?.screenshotImage,
               let image = AgentPlatformImage(data: data) {
                agentImage(image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 190)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                    }
            } else {
                Text("ページを開くとここに表示します。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .agentCard()
    }

    private var selectedCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Gemma 4 E4B の選択")
                .font(.system(size: 13, weight: .bold))
            if let action = controller.selectedAction {
                Text(action.target ?? action.action.rawValue)
                    .font(.system(size: 13, weight: .semibold))
                Text(action.reason)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("まだ選択されていません。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .agentCard()
    }

    private var elementsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("操作候補")
                    .font(.system(size: 13, weight: .bold))
                Spacer()
                Text("\(controller.visualContext?.interactiveElements.count ?? 0)")
                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ForEach(controller.visualContext?.interactiveElements.prefix(18) ?? []) { element in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(element.id)
                            .font(.system(size: 11, weight: .bold).monospaced())
                        Text(element.type.rawValue)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    Text(element.displayLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(element.id == controller.selectedElementID ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.035))
                )
            }
        }
        .agentCard()
    }

    @ViewBuilder
    private func agentImage(_ image: AgentPlatformImage) -> Image {
#if canImport(AppKit)
        Image(nsImage: image)
#else
        Image(uiImage: image)
#endif
    }
}

private struct AgentStepPill: View {
    let title: String
    let isActive: Bool

    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Capsule().fill(isActive ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05)))
            .foregroundStyle(isActive ? Color.accentColor : .secondary)
    }
}

private struct AgentElementHighlight: View {
    let element: InteractiveElement

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(Color.accentColor, lineWidth: 3)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
            )
            .frame(width: max(element.bounds.width, 16), height: max(element.bounds.height, 16))
            .offset(x: element.bounds.minX, y: element.bounds.minY)
            .allowsHitTesting(false)
    }
}

private struct AgentWebViewRepresentable: View {
    let webView: WKWebView

    var body: some View {
        AgentPlatformWebViewRepresentable(webView: webView)
    }
}

#if os(macOS)
private struct AgentPlatformWebViewRepresentable: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#else
private struct AgentPlatformWebViewRepresentable: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#endif

private extension View {
    func agentCard() -> some View {
        self
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.appSecondaryBackground.opacity(0.72))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
    }
}

private extension AgentPlatformImage {
    func agentPNGData() -> Data? {
#if canImport(AppKit)
        guard let tiff = tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
#else
        return pngData()
#endif
    }
}

#endif
