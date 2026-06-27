/*
仕様:
- 役割: AI Studio のリアルタイム音声会話パイプライン (STT → Gemma 4 ストリーミング → 句点単位 TTS) を提供する。
- 主な型: `AIVoiceChatService` (ObservableObject, MainActor)。
- 編集ポイント: STT (SFSpeechRecognizer)、Gemma 呼び出し、文単位の TTS キューイングを変えるときに触る。
- 設計メモ:
    * iOS sandbox の都合で llama-mtmd-cli をサブプロセス起動できないため、Gemma 4 のネイティブ音声入力は v1 では使わず、
      SFSpeechRecognizer をオンデバイス STT として利用する (ユーザー体感は同じ音声会話)。
    * LocalAssistantRuntimeBridge.generateReply の `onUpdate` 経由で `.visiblePreview` を受け取り、
      前回値との差分から新規に追加された句点 (。! ? . !? \n) ごとに 1 文を AVSpeechSynthesizer に流し込む。
    * 履歴・プロンプト・max_tokens は AIVoiceChatSettings.shared から取得し、レイテンシ最小化を最優先する。
*/

import Foundation
import AVFoundation
import Speech
import Combine

@MainActor
final class AIVoiceChatService: NSObject, ObservableObject {
    static let shared = AIVoiceChatService()

    enum Phase: Equatable {
        case idle
        case listening
        case thinking
        case speaking
        case error(String)
    }

    struct Turn: Identifiable, Equatable {
        let id = UUID()
        let user: String
        var assistant: String
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var liveTranscript: String = ""
    @Published private(set) var liveResponse: String = ""
    @Published private(set) var history: [Turn] = []
    @Published private(set) var isAuthorized: Bool = false

    private let settings = AIVoiceChatSettings.shared

    // Speech recognition
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    // TTS
    private let synthesizer = AVSpeechSynthesizer()
    private var ttsQueue: [String] = []
    private var isSpeaking: Bool = false

    // Streaming bookkeeping
    private var lastVisibleText: String = ""
    private var ttsBuffer: String = ""
    private var generationTask: Task<Void, Never>?

    /// 句点 (読点は含めない)。
    private static let sentenceTerminators: CharacterSet = CharacterSet(charactersIn: "。!?！?.\n")

    override init() {
        super.init()
        synthesizer.delegate = self
        rebuildRecognizer()
    }

    /// View 表示直後に呼ぶ。ユーザーが発話している間にモデルをメモリに乗せる。
    func prewarm() {
        LocalAssistantRuntimeBridge.shared.prewarmIfPossible()
    }

    /// 音声会話に最適化した advancedSettings。ツール/検索を完全に切り、内部システムプロンプトを最小化する。
    private var voiceOptimizedAdvancedSettings: GemmaAdvancedSettings {
        var s = GemmaAdvancedSettings.default
        s.allowToolUsage = false
        s.strictJSONToolCalls = false
        s.allowDirectAnswersWithoutTools = true
        s.requireSearchForFactualQueries = false
        s.requireExternalSourcesInDeepResearch = false
        s.maxToolRounds = 0
        s.maxSearchRounds = 0
        s.enabledTools = [:]
        s.useAutomaticTemperature = true
        return s
    }

    private func rebuildRecognizer() {
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: settings.localeIdentifier))
            ?? SFSpeechRecognizer(locale: Locale(identifier: "ja-JP"))
    }

    // MARK: - Permissions

    func requestAuthorization() async {
        let speechStatus: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
        var micGranted = false
#if os(iOS)
        micGranted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { granted in
                    cont.resume(returning: granted)
                }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    cont.resume(returning: granted)
                }
            }
        }
#elseif os(macOS)
        micGranted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                cont.resume(returning: granted)
            }
        }
#endif
        self.isAuthorized = (speechStatus == .authorized) && micGranted
        if !self.isAuthorized {
            self.phase = .error("マイクまたは音声認識の権限が許可されていません。")
        }
    }

    // MARK: - Listening (PTT)

    func startListening() async {
        if !isAuthorized {
            await requestAuthorization()
            guard isAuthorized else { return }
        }
        cancelAllSpeech()
        generationTask?.cancel()
        liveTranscript = ""
        liveResponse = ""
        lastVisibleText = ""
        ttsBuffer = ""
        rebuildRecognizer()

        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            phase = .error("音声認識が利用できません。")
            return
        }

        do {
#if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.duckOthers, .defaultToSpeaker, .allowBluetooth])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
#endif

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            if #available(iOS 13.0, macOS 10.15, *) {
                request.requiresOnDeviceRecognition = true
            }
            recognitionRequest = request

            let inputNode = audioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                self?.recognitionRequest?.append(buffer)
            }

            audioEngine.prepare()
            try audioEngine.start()

            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                guard let self else { return }
                Task { @MainActor in
                    if let result {
                        self.liveTranscript = result.bestTranscription.formattedString
                    }
                    if error != nil || (result?.isFinal ?? false) {
                        // Final または error — finishListening 側で扱う
                    }
                }
            }

            phase = .listening
        } catch {
            phase = .error("録音開始に失敗しました: \(error.localizedDescription)")
            teardownAudio()
        }
    }

    /// 録音を止めて、現時点の transcript を確定し、Gemma に投げる。
    func stopListeningAndSend() async {
        guard phase == .listening else { return }
        let finalText = liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        teardownAudio()
        if finalText.isEmpty {
            phase = .idle
            return
        }
        await runGeneration(forUserText: finalText)
    }

    func cancelListening() {
        teardownAudio()
        phase = .idle
        liveTranscript = ""
    }

    private func teardownAudio() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
#if os(iOS)
        // 録音を止めても直後に TTS で再生するので、セッションは active のまま、
        // カテゴリを playback 用に切り替える。setActive(false) は cancelListening 等の終了時のみ行う。
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true, options: [])
#endif
    }

    /// 完全終了 (画面を閉じた等) の時にだけ呼ぶ。
    private func deactivateAudioSession() {
#if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
#endif
    }

    // MARK: - Generation

    private func runGeneration(forUserText userText: String) async {
        phase = .thinking
        liveResponse = ""
        ttsBuffer = ""
        lastVisibleText = ""

        let composedPrompt = buildPrompt(userText: userText)
        let advanced = voiceOptimizedAdvancedSettings
        let voiceSystemPrompt = settings.composedSystemPrompt

        generationTask = Task { [weak self] in
            guard let self else { return }
            let bridge = LocalAssistantRuntimeBridge.shared
            let reply = await bridge.generateReply(
                prompt: composedPrompt,
                contextPrompt: nil,
                coachMode: .studio,
                reasoningMode: .fast,
                researchMode: .off,
                childAge: 12,
                pageInfo: nil,
                safetySnapshot: nil,
                advancedSettings: advanced,
                overrideSystemPrompt: voiceSystemPrompt,
                onUpdate: { @MainActor [weak self] update in
                    self?.handleStreamUpdate(update)
                }
            )
            await MainActor.run {
                self.finalizeGeneration(reply: reply, userText: userText)
            }
        }
    }

    private func handleStreamUpdate(_ update: LocalAssistantStructuredTurnUpdate) {
        guard case let .visiblePreview(text) = update else { return }
        let stripped = sanitize(text)
        guard stripped.count > lastVisibleText.count else {
            // 既存より短い (リセット等) は無視
            lastVisibleText = stripped
            liveResponse = stripped
            return
        }
        let startIdx = stripped.index(stripped.startIndex, offsetBy: lastVisibleText.count)
        let delta = String(stripped[startIdx...])
        lastVisibleText = stripped
        liveResponse = stripped
        ttsBuffer += delta
        flushCompleteSentences()
    }

    private func flushCompleteSentences() {
        guard settings.autoSpeak else { return }
        while let idx = ttsBuffer.unicodeScalars.firstIndex(where: { Self.sentenceTerminators.contains($0) }) {
            let endIdx = ttsBuffer.unicodeScalars.index(after: idx)
            let sentenceScalars = ttsBuffer.unicodeScalars[ttsBuffer.unicodeScalars.startIndex..<endIdx]
            let sentence = String(String.UnicodeScalarView(sentenceScalars))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let remainderScalars = ttsBuffer.unicodeScalars[endIdx..<ttsBuffer.unicodeScalars.endIndex]
            ttsBuffer = String(String.UnicodeScalarView(remainderScalars))
            if !sentence.isEmpty {
                enqueueSpeak(sentence)
            }
        }
    }

    private func finalizeGeneration(reply: String?, userText: String) {
        let finalText = (reply?.isEmpty == false ? reply! : liveResponse)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitized = sanitize(finalText)
        liveResponse = sanitized

        // 残り (句点で締めなかった末尾) を流し込む
        let leftover = ttsBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        ttsBuffer = ""
        if !leftover.isEmpty, settings.autoSpeak {
            enqueueSpeak(leftover)
        }

        history.append(Turn(user: userText, assistant: sanitized))
        trimHistory()

        if isSpeaking || !ttsQueue.isEmpty {
            phase = .speaking
        } else {
            phase = .idle
        }
    }

    // MARK: - Prompt assembly

    private func buildPrompt(userText: String) -> String {
        // System プロンプト側 (overrideSystemPrompt) に音声会話の指示を寄せているので、
        // ここでは履歴とユーザー発話だけを最短で渡す。
        var lines: [String] = []
        let recent = history.suffix(settings.historyTurns)
        for turn in recent {
            lines.append("ユーザー: " + turn.user)
            lines.append("アシスタント: " + turn.assistant)
        }
        lines.append("ユーザー: " + userText)
        return lines.joined(separator: "\n")
    }

    private func trimHistory() {
        let maxKeep = max(settings.historyTurns, 1)
        if history.count > maxKeep {
            history.removeFirst(history.count - maxKeep)
        }
    }

    /// 記号や箇条書きが混ざった場合に TTS が読みづらくなるので、最低限の整形を行う。
    private func sanitize(_ text: String) -> String {
        var out = text
        // markdown emphasis 等を最低限剥がす
        for token in ["**", "__", "`", "*", "_"] {
            out = out.replacingOccurrences(of: token, with: "")
        }
        return out
    }

    // MARK: - TTS

    private func enqueueSpeak(_ text: String) {
        ttsQueue.append(text)
        speakNextIfNeeded()
    }

    private func speakNextIfNeeded() {
        guard !isSpeaking else { return }
        guard !ttsQueue.isEmpty else { return }
        let next = ttsQueue.removeFirst()
        let utterance = AVSpeechUtterance(string: next)
        utterance.voice = settings.resolvedVoice
        utterance.rate = settings.rate
        utterance.pitchMultiplier = settings.pitch
        utterance.volume = settings.volume
        isSpeaking = true
        if phase != .listening {
            phase = .speaking
        }
        synthesizer.speak(utterance)
    }

    func cancelAllSpeech() {
        ttsQueue.removeAll()
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        isSpeaking = false
    }

    func interrupt() {
        cancelAllSpeech()
        generationTask?.cancel()
        LocalAssistantRuntimeBridge.shared.cancelActiveGeneration()
        phase = .idle
    }

    func clearHistory() {
        history.removeAll()
        liveResponse = ""
        liveTranscript = ""
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension AIVoiceChatService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            self.speakNextIfNeeded()
            if !self.isSpeaking, self.ttsQueue.isEmpty, self.phase == .speaking {
                self.phase = .idle
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            if self.ttsQueue.isEmpty, self.phase == .speaking {
                self.phase = .idle
            }
        }
    }
}
