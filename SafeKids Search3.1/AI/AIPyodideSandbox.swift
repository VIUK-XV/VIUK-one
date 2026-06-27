/*
仕様:
- 役割: 本物の Python (= Pyodide / WASM) を WKWebView 内で実行する。
  従来の `AIPythonSandbox` は Python サブセット → JavaScript への
  簡易 transpiler だった (for/if/print/数式のみ) 為、Gemma 4 が出す
  `import numpy` 等の通常コードがそのままでは動かなかった。
  本クラスは Pyodide を読み込み、`runPythonAsync` で実際の CPython を実行する。

- セキュリティ:
  - 実行環境は WebKit (WASM) サンドボックス。Python から host ファイルへ書き込めない。
  - `pyodide.http` の網外アクセスは CORS で制限される。子供向けアプリ用途では十分。
  - Python コード自身は WKWebView の Document サンドボックス内で完結。

- 主な API:
  - `prewarm()` — 起動時に Pyodide をプリロードしておく。最初の実行を 4-6 秒短縮。
  - `execute(code:) async -> AIPythonSandbox.ExecutionResult` —
    既存の `AIPythonSandbox.ExecutionResult` 型をそのまま返す。
    Pyodide が未準備の時は ready まで await し、本物の Python を走らせる。

- 編集ポイント:
  - 同梱パッケージ (numpy / pandas 等) を増やすときは Pyodide HTML の
    micropip.install を編集。
*/

import Foundation
import WebKit

@MainActor
final class AIPyodideSandbox: NSObject {
    static let shared = AIPyodideSandbox()

    private var webView: WKWebView?
    private(set) var isReady = false
    private(set) var initializationFailureReason: String?
    private var readyContinuations: [CheckedContinuation<Bool, Never>] = []
    private var didStartLoading = false
    /// 個別 execute の結果を JSON で書き戻すためのコールバック。
    private var pendingExecutions: [String: CheckedContinuation<AIPythonSandbox.ExecutionResult, Never>] = [:]

    private override init() {
        super.init()
    }

    /// 起動時 / chat 開始時に呼んで Pyodide WASM を先にロードしておく。
    /// 再呼び出しは安全 (内部で 1 回しか走らない)。
    func prewarm() {
#if os(iOS)
        return
#else
        setupIfNeeded()
#endif
    }

    /// 本物の Python を走らせる。Pyodide が初期化中なら ready まで待つ。
    /// 初期化に失敗した場合は `success: false, failureKind: .runtimeError` を返す。
    func execute(code: String) async -> AIPythonSandbox.ExecutionResult {
#if os(iOS)
        return AIPythonSandbox.ExecutionResult(
            code: code,
            stdout: "",
            stderr: "iPhone版ではPython/WASMツールを無効化しています。Gemma4本体で回答を継続します。",
            success: false,
            failureKind: .runtimeError
        )
#else
        setupIfNeeded()

        // ready まで待つ。WKWebView 内の JS が messageHandler に "ready" を送ってきたら解放。
        let ready = await waitUntilReady()
        guard ready, let webView else {
            return AIPythonSandbox.ExecutionResult(
                code: code,
                stdout: "",
                stderr: initializationFailureReason ?? "Pyodide の初期化に失敗しました。",
                success: false,
                failureKind: .runtimeError
            )
        }

        // 各 execute を識別するための ID。複数同時 execute にも対応。
        let token = UUID().uuidString
        // JS テンプレートリテラル用に最低限のエスケープ。
        let escaped = code
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")
        let script = """
        (async () => {
          const out = await __viukRunPython(`\(escaped)`);
          window.webkit.messageHandlers.viukpy.postMessage({
            type: "result",
            token: "\(token)",
            payload: out
          });
        })();
        """

        return await withCheckedContinuation { (continuation: CheckedContinuation<AIPythonSandbox.ExecutionResult, Never>) in
            pendingExecutions[token] = continuation
            webView.evaluateJavaScript(script) { [weak self] _, error in
                // evaluateJavaScript 自体の失敗は postMessage が来ないので、ここで早期 resume する。
                guard let error else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let cont = self.pendingExecutions.removeValue(forKey: token) {
                        cont.resume(returning: AIPythonSandbox.ExecutionResult(
                            code: code,
                            stdout: "",
                            stderr: "Pyodide 呼び出し失敗: \(error.localizedDescription)",
                            success: false,
                            failureKind: .runtimeError
                        ))
                    }
                }
            }
        }
#endif
    }

    // MARK: - Setup

    private func setupIfNeeded() {
        guard !didStartLoading else { return }
        didStartLoading = true

        let config = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        ucc.add(self, name: "viukpy")
        config.userContentController = ucc
        // ネット越しに pyodide.js / pyodide.asm.wasm を取りに行くので JS / WebKit の標準設定で OK。
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isHidden = true
#if canImport(UIKit)
        webView.isOpaque = false
        webView.backgroundColor = .clear
#endif
        self.webView = webView

        // 「baseURL を https 系にしておかないと <script src> の cross-origin が止まる」ので
        // jsdelivr ベースに揃える。
        let html = pyodideBootstrapHTML()
        webView.loadHTMLString(html, baseURL: URL(string: "https://cdn.jsdelivr.net/"))
    }

    private func waitUntilReady() async -> Bool {
        if isReady { return true }
        if initializationFailureReason != nil { return false }
        return await withCheckedContinuation { continuation in
            readyContinuations.append(continuation)
        }
    }

    /// Pyodide をロードするブートストラップ HTML。
    /// - stdout / stderr を独自バッファに溜め、execute ごとにリセットして取り出す。
    /// - 例外発生時は traceback を文字列化して返す。
    private func pyodideBootstrapHTML() -> String {
        """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8" /></head><body>
        <script src="https://cdn.jsdelivr.net/pyodide/v0.27.5/full/pyodide.js"></script>
        <script>
        (async function() {
          let pyo = null;
          let stdoutBuf = [];
          let stderrBuf = [];

          try {
            pyo = await loadPyodide({
              indexURL: "https://cdn.jsdelivr.net/pyodide/v0.27.5/full/",
              stdout: (line) => { stdoutBuf.push(line); },
              stderr: (line) => { stderrBuf.push(line); }
            });
            window.webkit.messageHandlers.viukpy.postMessage({ type: "ready" });
          } catch (e) {
            window.webkit.messageHandlers.viukpy.postMessage({
              type: "init_failed",
              reason: String(e && e.stack ? e.stack : e)
            });
            return;
          }

          window.__viukRunPython = async function(code) {
            stdoutBuf = [];
            stderrBuf = [];
            try {
              const result = await pyo.runPythonAsync(code);
              let resultStr = "";
              if (result !== undefined && result !== null) {
                try { resultStr = result.toString(); } catch { resultStr = ""; }
              }
              return JSON.stringify({
                success: true,
                stdout: stdoutBuf.join("\\n"),
                stderr: stderrBuf.join("\\n"),
                result: resultStr
              });
            } catch (err) {
              // PythonError は traceback プロパティを持つ。
              const trace = (err && err.message) ? err.message : String(err);
              return JSON.stringify({
                success: false,
                stdout: stdoutBuf.join("\\n"),
                stderr: stderrBuf.join("\\n"),
                traceback: trace
              });
            }
          };
        })();
        </script>
        </body></html>
        """
    }
}

// MARK: - WKScriptMessageHandler

extension AIPyodideSandbox: WKScriptMessageHandler {
    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }

        switch type {
        case "ready":
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isReady = true
                let conts = self.readyContinuations
                self.readyContinuations.removeAll()
                conts.forEach { $0.resume(returning: true) }
            }
        case "init_failed":
            let reason = (body["reason"] as? String) ?? "Pyodide の初期化に失敗しました。"
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.initializationFailureReason = reason
                let conts = self.readyContinuations
                self.readyContinuations.removeAll()
                conts.forEach { $0.resume(returning: false) }
            }
        case "result":
            guard let token = body["token"] as? String,
                  let payload = body["payload"] as? String else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let continuation = self.pendingExecutions.removeValue(forKey: token) else { return }
                continuation.resume(returning: Self.parseExecutionResult(payload: payload))
            }
        default:
            break
        }
    }

    private static func parseExecutionResult(payload: String) -> AIPythonSandbox.ExecutionResult {
        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return AIPythonSandbox.ExecutionResult(
                code: "",
                stdout: "",
                stderr: "Pyodide 結果のパースに失敗しました。",
                success: false,
                failureKind: .runtimeError
            )
        }
        let success = obj["success"] as? Bool ?? false
        let stdout = (obj["stdout"] as? String) ?? ""
        let stderr = (obj["stderr"] as? String) ?? ""
        let resultStr = (obj["result"] as? String) ?? ""
        let traceback = (obj["traceback"] as? String) ?? ""

        // stdout に「式の評価結果」を追記して、`expr` 単独行の戻り値もユーザーに見えるようにする。
        var combinedStdout = stdout
        if success, !resultStr.isEmpty, resultStr != "None" {
            combinedStdout = combinedStdout.isEmpty ? resultStr : combinedStdout + "\n" + resultStr
        }

        let combinedStderr: String
        if success {
            combinedStderr = stderr
        } else {
            combinedStderr = stderr.isEmpty ? traceback : stderr + "\n" + traceback
        }

        return AIPythonSandbox.ExecutionResult(
            code: "",
            stdout: combinedStdout,
            stderr: combinedStderr,
            success: success,
            failureKind: success ? nil : .runtimeError
        )
    }
}
