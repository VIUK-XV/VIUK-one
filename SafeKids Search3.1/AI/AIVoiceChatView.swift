/*
仕様:
- 役割: AI Studio から呼び出すリアルタイム音声会話画面。PTT (Push-to-Talk) のマイクボタンと
  パーソナライズ設定シートを提供する。
- 主な型: `AIVoiceChatView`, `AIVoiceChatSettingsSheet`.
- 編集ポイント: UI レイアウト・波形表現・設定項目 UI を変えるときに触る。データは `AIVoiceChatService.shared`
  と `AIVoiceChatSettings.shared` に閉じる。
*/

import SwiftUI
import AVFoundation

struct AIVoiceChatView: View {
    @StateObject private var service = AIVoiceChatService.shared
    @StateObject private var settings = AIVoiceChatSettings.shared
    @State private var showSettings = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcriptArea
            Divider()
            controls
        }
        .background(Color.appCanvasBackground.ignoresSafeArea())
        .task {
            // モデルロードはユーザーが発話している間に並走させたいので、画面表示と同時に開始する。
            service.prewarm()
            await service.requestAuthorization()
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                AIVoiceChatSettingsSheet()
            }
        }
    }

    private var header: some View {
        HStack {
            Button {
                service.interrupt()
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)

            Spacer()

            VStack(spacing: 2) {
                Text("音声会話")
                    .font(.system(size: 14, weight: .semibold))
                Text(phaseLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                showSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var phaseLabel: String {
        switch service.phase {
        case .idle: return "待機中"
        case .listening: return "聞いています…"
        case .thinking: return "考えています…"
        case .speaking: return "話しています"
        case .error(let msg): return msg
        }
    }

    private var transcriptArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(service.history) { turn in
                        turnBubble(user: turn.user, assistant: turn.assistant)
                    }
                    if !service.liveTranscript.isEmpty, service.phase == .listening {
                        bubble(role: "あなた", text: service.liveTranscript, accent: .blue, pending: true)
                            .id("live-user")
                    }
                    if !service.liveResponse.isEmpty,
                       (service.phase == .thinking || service.phase == .speaking) {
                        bubble(role: "アシスタント", text: service.liveResponse, accent: .purple, pending: true)
                            .id("live-assistant")
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .onChange(of: service.liveResponse) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .onChange(of: service.history.count) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    private func turnBubble(user: String, assistant: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            bubble(role: "あなた", text: user, accent: .blue, pending: false)
            bubble(role: "アシスタント", text: assistant, accent: .purple, pending: false)
        }
    }

    private func bubble(role: String, text: String, accent: Color, pending: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(accent).frame(width: 6, height: 6)
                Text(role)
                    .font(.system(size: 10, weight: .bold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                if pending {
                    ProgressView().controlSize(.mini)
                }
            }
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(accent.opacity(0.08))
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 16) {
                Button {
                    service.clearHistory()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .disabled(service.history.isEmpty)

                Spacer()

                micButton

                Spacer()

                Button {
                    service.interrupt()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .disabled(service.phase == .idle)
            }
            Text(micHelpText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var micHelpText: String {
        switch service.phase {
        case .listening: return "タップで送信"
        case .thinking, .speaking: return "■ で中断"
        default: return "マイクを押して話す"
        }
    }

    private var micButton: some View {
        Button {
            Task { await toggleMic() }
        } label: {
            ZStack {
                Circle()
                    .fill(micButtonColor)
                    .frame(width: 88, height: 88)
                    .shadow(color: micButtonColor.opacity(0.5), radius: service.phase == .listening ? 16 : 4)
                Image(systemName: micIcon)
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(service.phase == .listening ? 1.06 : 1.0)
        .animation(.easeInOut(duration: 0.2), value: service.phase)
    }

    private var micIcon: String {
        switch service.phase {
        case .listening: return "stop.fill"
        case .thinking, .speaking: return "waveform"
        default: return "mic.fill"
        }
    }

    private var micButtonColor: Color {
        switch service.phase {
        case .listening: return .red
        case .thinking: return .orange
        case .speaking: return .purple
        case .error: return .gray
        default: return .accentColor
        }
    }

    private func toggleMic() async {
        switch service.phase {
        case .idle, .error, .speaking:
            await service.startListening()
        case .listening:
            await service.stopListeningAndSend()
        case .thinking:
            break
        }
    }
}

// MARK: - Settings Sheet

struct AIVoiceChatSettingsSheet: View {
    @StateObject private var settings = AIVoiceChatSettings.shared
    @Environment(\.dismiss) private var dismiss
    @State private var previewSynth = AVSpeechSynthesizer()

    private func previewCurrentVoice() {
        let utterance = AVSpeechUtterance(string: "こんにちは。これはこの声のサンプル音声です。")
        utterance.voice = settings.resolvedVoice
        utterance.rate = settings.rate
        utterance.pitchMultiplier = settings.pitch
        utterance.volume = settings.volume
        if previewSynth.isSpeaking {
            previewSynth.stopSpeaking(at: .immediate)
        }
        previewSynth.speak(utterance)
    }

    private var availableVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("ja") || $0.language.hasPrefix("en") }
            .sorted { lhs, rhs in
                // 品質 (Premium > Enhanced > Default) を最優先、次に言語、最後に名前順。
                let lq = AIVoiceChatSettings.qualityRank(lhs.quality)
                let rq = AIVoiceChatSettings.qualityRank(rhs.quality)
                if lq != rq { return lq > rq }
                if lhs.language != rhs.language { return lhs.language < rhs.language }
                return lhs.name < rhs.name
            }
    }

    private var hasPremiumOrEnhancedJapanese: Bool {
        AVSpeechSynthesisVoice.speechVoices()
            .contains { $0.language.hasPrefix("ja") && ($0.quality == .premium || $0.quality == .enhanced) }
    }

    private func qualityLabel(_ q: AVSpeechSynthesisVoiceQuality) -> String {
        switch q {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        case .default: return "Default"
        @unknown default: return "?"
        }
    }

    var body: some View {
        Form {
            Section("音声") {
                Picker("読み上げ音声", selection: $settings.voiceIdentifier) {
                    ForEach(availableVoices, id: \.identifier) { voice in
                        Text("\(voice.name) — \(qualityLabel(voice.quality)) (\(voice.language))")
                            .tag(voice.identifier)
                    }
                }

                if !hasPremiumOrEnhancedJapanese {
                    Label {
                        Text("より自然な音声 (Premium / Enhanced) はシステム設定 → アクセシビリティ → 読み上げコンテンツ → 声 からダウンロードできます。")
                            .font(.caption)
                    } icon: {
                        Image(systemName: "sparkles")
                            .foregroundStyle(.tint)
                    }
                }

                Button {
                    previewCurrentVoice()
                } label: {
                    Label("この声で試聴", systemImage: "play.circle")
                }

                VStack(alignment: .leading) {
                    HStack {
                        Text("速度")
                        Spacer()
                        Text(String(format: "%.2f", settings.rate)).foregroundStyle(.secondary)
                    }
                    Slider(value: $settings.rate,
                           in: AVSpeechUtteranceMinimumSpeechRate...AVSpeechUtteranceMaximumSpeechRate)
                }

                VStack(alignment: .leading) {
                    HStack {
                        Text("ピッチ")
                        Spacer()
                        Text(String(format: "%.2f", settings.pitch)).foregroundStyle(.secondary)
                    }
                    Slider(value: $settings.pitch, in: 0.5...2.0)
                }

                VStack(alignment: .leading) {
                    HStack {
                        Text("音量")
                        Spacer()
                        Text(String(format: "%.2f", settings.volume)).foregroundStyle(.secondary)
                    }
                    Slider(value: $settings.volume, in: 0.0...1.0)
                }

                Toggle("応答を自動で読み上げる", isOn: $settings.autoSpeak)
            }

            Section("会話") {
                Stepper(value: $settings.historyTurns, in: 1...5) {
                    HStack {
                        Text("履歴ターン数")
                        Spacer()
                        Text("\(settings.historyTurns)").foregroundStyle(.secondary)
                    }
                }

                Picker("最大トークン", selection: $settings.maxTokens) {
                    Text("40").tag(40)
                    Text("80").tag(80)
                    Text("120").tag(120)
                    Text("160").tag(160)
                }

                Picker("認識言語", selection: $settings.localeIdentifier) {
                    Text("日本語").tag("ja-JP")
                    Text("English (US)").tag("en-US")
                }
            }

            Section("ペルソナ追記") {
                TextField("例: 子供向けに優しく", text: $settings.personaAddendum, axis: .vertical)
                    .lineLimit(2...4)
                Text("固定の音声プロンプトに 1 行追加されます。長く書くとレイテンシが増えます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("音声会話の設定")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完了") { dismiss() }
            }
        }
    }
}
