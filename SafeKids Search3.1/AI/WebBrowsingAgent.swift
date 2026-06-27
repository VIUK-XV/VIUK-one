/*
仕様:
- 役割: WKWebView を使った自律 Web スクレイピングエージェント。
        AI が外部サイトの全文テキストを取得するために使用する。
- 主な型: `WebBrowsingAgent`, `WebPageExtract`.
- 編集ポイント: JS 抽出ロジック、CAPTCHA 検出条件、ユーザーエージェントを変える際に触る。
*/
#if canImport(WebKit)
import Foundation
import WebKit
import Combine

// MARK: - Data

struct WebPageExtract: Sendable {
    let url: URL
    let title: String
    let text: String          // 抽出済みプレーンテキスト（最大 8000 文字）
    let domain: String
}

// MARK: - Agent

/// WKWebView を使った UI 可視型 Web ブラウジングエージェント。
/// @MainActor で所有し、SwiftUI の WebBrowsingPanelView から監視される。
@MainActor
final class WebBrowsingAgent: NSObject, ObservableObject {

    static let shared = WebBrowsingAgent()

    // MARK: Published（UI がバインドする）

    @Published private(set) var isActive = false
    @Published private(set) var currentURL: URL?
    @Published private(set) var pageTitle = ""
    @Published private(set) var loadProgress: Double = 0
    @Published private(set) var statusText = ""
    @Published private(set) var needsUserIntervention = false   // CAPTCHA 等
    @Published private(set) var completedCount = 0
    @Published private(set) var totalCount = 0

    // MARK: Internal

    /// 外部から WKWebView に直接アクセスできるよう公開（SwiftUI representable 用）
    let webView: WKWebView

    private var urlQueue: [URL] = []
    private var extractedResults: [WebPageExtract] = []
    private var onComplete: (([WebPageExtract]) -> Void)?
    private var progressObservation: NSKeyValueObservation?
    private var pageTitleObservation: NSKeyValueObservation?
    private var extractTask: Task<Void, Never>?

    // MARK: Init

    private override init() {
        let cfg = WKWebViewConfiguration()
        cfg.mediaTypesRequiringUserActionForPlayback = .all
        self.webView = WKWebView(frame: .zero, configuration: cfg)
        super.init()

        webView.navigationDelegate = self
        // Safari Mobile 風 UA でブロックされにくくする
        webView.customUserAgent =
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) " +
            "AppleWebKit/605.1.15 (KHTML, like Gecko) " +
            "Version/17.4 Mobile/15E148 Safari/604.1"
        // CAPTCHA 手動解除のため常にユーザー操作を有効化
        // isUserInteractionEnabled は iOS 専用のため条件コンパイル
#if canImport(UIKit)
        webView.isUserInteractionEnabled = true
#endif

        // estimatedProgress を KVO で監視
        progressObservation = webView.observe(\.estimatedProgress, options: [.new]) {
            [weak self] _, change in
            guard let self, let v = change.newValue else { return }
            Task { @MainActor in self.loadProgress = v }
        }
        pageTitleObservation = webView.observe(\.title, options: [.new]) {
            [weak self] _, change in
            guard let self, let t = change.newValue as? String else { return }
            Task { @MainActor in self.pageTitle = t }
        }
    }

    // MARK: - Public API

    /// URL リストを順番にブラウズし、全ページのテキストを抽出して completion を呼ぶ。
    func browse(urls: [URL], completion: @escaping ([WebPageExtract]) -> Void) {
        let safeURLs = urls.filter { WebSearchSecurityPolicy.isAllowedForNetworkFetch($0) }
        guard !safeURLs.isEmpty else { completion([]); return }
        // 前のセッションが進行中なら completion を空結果で完了させてからリセット。
        // これを怠ると withCheckedContinuation が永遠に resume されずタスクリークする。
        cancel()
        urlQueue = safeURLs
        extractedResults = []
        onComplete = completion
        totalCount = safeURLs.count
        completedCount = 0
        isActive = true
        loadNext()
    }

    /// 進行中のブラウジングを中断する。保留中の completion は空結果で即時完了させる。
    func cancel() {
        extractTask?.cancel()
        extractTask = nil
        webView.stopLoading()
        urlQueue = []
        isActive = false
        needsUserIntervention = false
        statusText = ""
        currentURL = nil
        loadProgress = 0
        // 保留中の completion があれば空結果で完了し、タスクリークを防ぐ
        if let pending = onComplete {
            onComplete = nil
            pending([])
        }
    }

    // MARK: - Internal flow

    private func loadNext() {
        guard !urlQueue.isEmpty else { finish(); return }
        let url = urlQueue.removeFirst()
        guard WebSearchSecurityPolicy.isAllowedForNetworkFetch(url) else {
            completedCount += 1
            statusText = "安全でないURLをスキップしました"
            loadNext()
            return
        }
        currentURL = url
        pageTitle = ""
        needsUserIntervention = false
        statusText = "読み込み中…"
        loadProgress = 0
        webView.load(URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 20
        ))
    }

    private func finish() {
        isActive = false
        statusText = "完了"
        currentURL = nil
        loadProgress = 0
        let results = extractedResults
        onComplete?(results)
        onComplete = nil
    }

    /// ページ読み込み完了後に呼ばれる。CAPTCHA 判定 → テキスト抽出 → 次 URL。
    private func handlePageLoaded() {
        extractTask?.cancel()
        extractTask = Task {
            // JS が走りきるまで待機。1.5s → 0.8s に短縮（レスポンス速度改善）
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }

            // CAPTCHA / ブロッカー検出
            if await detectBlocker() {
                needsUserIntervention = true
                statusText = "⚠️ CAPTCHA を検出 — 手動で解除してください"
                // 最大 40 秒ユーザー解除を待つ（2 秒ポーリング）
                for _ in 0..<20 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    guard !Task.isCancelled else { return }
                    if !needsUserIntervention { break }   // 解除フラグを外から落とせる
                    let stillBlocked = await detectBlocker()
                    if !stillBlocked {
                        needsUserIntervention = false
                        break
                    }
                }
                if needsUserIntervention {
                    // CAPTCHA タイムアウト時も「DOM が露出している部分テキスト」だけは救出する。
                    // タイトル・先頭数百字でも synthesis 側に渡せばゼロより遥かに価値がある。
                    let (partialTitle, partialText) = await extractPageContent()
                    if let url = currentURL,
                       !partialText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let domain = url.host ?? url.absoluteString
                        extractedResults.append(
                            WebPageExtract(url: url, title: partialTitle, text: partialText, domain: domain)
                        )
                        statusText = "CAPTCHA 越しに部分テキストを取得しました"
                    } else {
                        statusText = "CAPTCHA タイムアウト — スキップします"
                    }
                    needsUserIntervention = false
                    completedCount += 1
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    loadNext(); return
                }
            }

            // テキスト抽出
            statusText = "テキストを抽出中…"
            var (title, text) = await extractPageContent()

            // フォールバック 1: メイン抽出が空 / 極端に短いとき、innerText 全文を取り直す。
            // JS フィルタが厳しすぎてコンテンツを切り捨てるサイトを救済する。
            if text.trimmingCharacters(in: .whitespacesAndNewlines).count < 100 {
                let (fallbackTitle, fallbackText) = await extractPlainBodyText()
                if fallbackText.count > text.count {
                    if title.isEmpty { title = fallbackTitle }
                    text = fallbackText
                }
            }

            if let url = currentURL {
                let domain = url.host ?? url.absoluteString
                extractedResults.append(
                    WebPageExtract(url: url, title: title, text: text, domain: domain)
                )
            }
            completedCount += 1
            statusText = "抽出完了 (\(completedCount)/\(totalCount))"
            try? await Task.sleep(nanoseconds: 300_000_000)
            loadNext()
        }
    }

    /// メイン抽出が失敗 / 極端に短いときの救済用。
    /// メインコンテンツセレクタを使わず、document.body 全体の innerText を取り、
    /// 簡易ノイズ除去だけ行う。CAPTCHA 越しの部分テキスト取得にも使う。
    private func extractPlainBodyText() async -> (title: String, text: String) {
        let js = """
        (function() {
          try {
            var title = document.title || '';
            var body = document.body;
            if (!body) return JSON.stringify({ title: title, text: '' });
            var clone = body.cloneNode(true);
            var garbage = clone.querySelectorAll('script,style,noscript,iframe');
            garbage.forEach(function(e){ e.remove(); });
            var text = (clone.innerText || clone.textContent || '')
              .replace(/[ \\t]+/g, ' ')
              .replace(/\\n{3,}/g, '\\n\\n')
              .trim()
              .substring(0, 8000);
            return JSON.stringify({ title: title, text: text });
          } catch(e) { return JSON.stringify({ title: '', text: '' }); }
        })();
        """
        do {
            let result = try await webView.evaluateJavaScript(js)
            if let jsonStr = result as? String,
               let data = jsonStr.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                return (title: obj["title"] ?? "", text: obj["text"] ?? "")
            }
        } catch {}
        return ("", "")
    }

    // MARK: - JavaScript helpers

    private func detectBlocker() async -> Bool {
        let js = """
        (function() {
          try {
            var checks = [
              !!document.querySelector('.g-recaptcha'),
              !!document.querySelector('#cf-challenge-form'),
              !!document.querySelector('[id*="captcha"]'),
              !!document.querySelector('[class*="captcha"]'),
              document.title.toLowerCase().includes('just a moment'),
              document.title.toLowerCase().includes('attention required'),
              (document.body && document.body.innerText.toLowerCase().includes('verify you are human')),
              (document.body && document.body.innerText.toLowerCase().includes('please complete the security check')),
            ];
            return checks.some(Boolean);
          } catch(e) { return false; }
        })();
        """
        do {
            let result = try await webView.evaluateJavaScript(js)
            return (result as? Bool) ?? false
        } catch { return false }
    }

    private func extractPageContent() async -> (title: String, text: String) {
        let js = """
        (function() {
          try {
            var title = document.title || '';
            // メインコンテンツ要素を優先
            var selectors = ['main','article','[role="main"]','.content','#content',
                             '.post-content','.entry-content','.article-body'];
            var root = null;
            for (var s of selectors) {
              root = document.querySelector(s);
              if (root) break;
            }
            root = root || document.body;
            var clone = root.cloneNode(true);
            // 不要要素を除去
            var garbage = clone.querySelectorAll(
              'script,style,nav,header,footer,aside,iframe,noscript,' +
              '.ad,.ads,[class*="banner"],[class*="cookie"],[class*="popup"],' +
              '[aria-hidden="true"],[role="complementary"]'
            );
            garbage.forEach(function(e){ e.remove(); });
            var text = (clone.innerText || clone.textContent || '')
              .replace(/[ \\t]+/g, ' ')
              .replace(/\\n{3,}/g, '\\n\\n')
              .trim()
              .substring(0, 8000);
            return JSON.stringify({ title: title, text: text });
          } catch(e) { return JSON.stringify({ title: '', text: '' }); }
        })();
        """
        do {
            let result = try await webView.evaluateJavaScript(js)
            if let jsonStr = result as? String,
               let data = jsonStr.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                return (title: obj["title"] ?? "", text: obj["text"] ?? "")
            }
        } catch {}
        return ("", "")
    }
}

// MARK: - WKNavigationDelegate

extension WebBrowsingAgent: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        statusText = "読み込み完了"
        handlePageLoaded()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let nsErr = error as NSError
        guard nsErr.code != NSURLErrorCancelled else { return }
        statusText = "読み込みエラー"
        completedCount += 1
        Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            loadNext()
        }
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        self.webView(webView, didFail: navigation, withError: error)
    }

    // 外部アプリへのリダイレクトをブロック（App Store 等）
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if !WebSearchSecurityPolicy.isAllowedForNetworkFetch(navigationAction.request.url) {
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }
}

#endif  // canImport(WebKit)
