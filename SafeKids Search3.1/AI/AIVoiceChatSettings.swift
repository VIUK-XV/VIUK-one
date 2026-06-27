/*
仕様:
- 役割: リアルタイム音声会話 (AIVoiceChat) のパーソナライズ設定を UserDefaults に永続化する。
- 主な型: `AIVoiceChatSettings` (ObservableObject)。
- 編集ポイント: TTS 音声・速度・ペルソナ・履歴長・max_tokens 等のチューニング値を追加するときに触る。
*/

import Foundation
import AVFoundation
import Combine

@MainActor
final class AIVoiceChatSettings: ObservableObject {
    static let shared = AIVoiceChatSettings()

    private let defaults = UserDefaults.standard
    private enum Key {
        static let voiceID = "voicechat.voiceID"
        static let rate = "voicechat.rate"
        static let pitch = "voicechat.pitch"
        static let volume = "voicechat.volume"
        static let autoSpeak = "voicechat.autoSpeak"
        static let persona = "voicechat.persona"
        static let historyTurns = "voicechat.historyTurns"
        static let maxTokens = "voicechat.maxTokens"
        static let localeID = "voicechat.localeID"
    }

    @Published var voiceIdentifier: String {
        didSet { defaults.set(voiceIdentifier, forKey: Key.voiceID) }
    }
    /// 0.0 ... 1.0 (AVSpeechUtteranceDefaultSpeechRate ≒ 0.5)
    @Published var rate: Float {
        didSet { defaults.set(rate, forKey: Key.rate) }
    }
    /// 0.5 ... 2.0
    @Published var pitch: Float {
        didSet { defaults.set(pitch, forKey: Key.pitch) }
    }
    /// 0.0 ... 1.0
    @Published var volume: Float {
        didSet { defaults.set(volume, forKey: Key.volume) }
    }
    @Published var autoSpeak: Bool {
        didSet { defaults.set(autoSpeak, forKey: Key.autoSpeak) }
    }
    /// 固定の音声会話用システムプロンプトに 1 行追記される自由記述。
    @Published var personaAddendum: String {
        didSet { defaults.set(personaAddendum, forKey: Key.persona) }
    }
    /// 直近 N 往復のみコンテキストに含める (1...5)。
    @Published var historyTurns: Int {
        didSet { defaults.set(historyTurns, forKey: Key.historyTurns) }
    }
    /// 生成 max_tokens (40...160)。
    @Published var maxTokens: Int {
        didSet { defaults.set(maxTokens, forKey: Key.maxTokens) }
    }
    /// STT の優先言語 (SFSpeechRecognizer の locale)。
    @Published var localeIdentifier: String {
        didSet { defaults.set(localeIdentifier, forKey: Key.localeID) }
    }

    private init() {
        // 既存値が無ければ Premium > Enhanced > Default の順で最良の日本語ボイスを選ぶ。
        // 標準の Kyoko/Otoya (default 品質) は音質が古く、Premium が使えるならそちらが圧倒的に自然。
        let bestJapanese = AIVoiceChatSettings.bestVoice(forLanguagePrefix: "ja")
        let bestFallback = bestJapanese ?? AIVoiceChatSettings.bestVoice(forLanguagePrefix: "en")
        let defaultVoice = bestFallback?.identifier
            ?? AVSpeechSynthesisVoice(language: "ja-JP")?.identifier
            ?? AVSpeechSynthesisVoice.speechVoices().first?.identifier
            ?? ""
        self.voiceIdentifier = (defaults.string(forKey: Key.voiceID) ?? defaultVoice)
        self.rate = (defaults.object(forKey: Key.rate) as? Float) ?? AVSpeechUtteranceDefaultSpeechRate
        self.pitch = (defaults.object(forKey: Key.pitch) as? Float) ?? 1.0
        self.volume = (defaults.object(forKey: Key.volume) as? Float) ?? 1.0
        self.autoSpeak = (defaults.object(forKey: Key.autoSpeak) as? Bool) ?? true
        self.personaAddendum = defaults.string(forKey: Key.persona) ?? ""
        self.historyTurns = (defaults.object(forKey: Key.historyTurns) as? Int) ?? 3
        self.maxTokens = (defaults.object(forKey: Key.maxTokens) as? Int) ?? 80
        self.localeIdentifier = defaults.string(forKey: Key.localeID) ?? "ja-JP"
    }

    /// 音声会話用の固定システムプロンプト + ユーザー追記。
    /// レイテンシ削減のため意図的に短く保つ。
    var composedSystemPrompt: String {
        let base = "あなたは音声会話アシスタント。1〜2文で簡潔に返答。記号・箇条書き・コードブロック禁止。話し言葉で。"
        let trimmed = personaAddendum.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? base : base + " " + trimmed
    }

    var resolvedVoice: AVSpeechSynthesisVoice? {
        if !voiceIdentifier.isEmpty,
           let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
            return voice
        }
        return AIVoiceChatSettings.bestVoice(forLanguagePrefix: "ja")
            ?? AVSpeechSynthesisVoice(language: localeIdentifier)
            ?? AVSpeechSynthesisVoice(language: "ja-JP")
    }

    /// 指定言語プレフィックスから Premium > Enhanced > Default の順で最良ボイスを選ぶ。
    static func bestVoice(forLanguagePrefix prefix: String) -> AVSpeechSynthesisVoice? {
        let candidates = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.lowercased().hasPrefix(prefix.lowercased()) }
        if candidates.isEmpty { return nil }
        return candidates.max { lhs, rhs in
            qualityRank(lhs.quality) < qualityRank(rhs.quality)
        }
    }

    static func qualityRank(_ q: AVSpeechSynthesisVoiceQuality) -> Int {
        switch q {
        case .premium: return 3
        case .enhanced: return 2
        case .default: return 1
        @unknown default: return 0
        }
    }
}
