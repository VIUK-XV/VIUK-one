/*
仕様:
- 役割: AI Studio を独立ワークスペースとして全画面表示し、他ワークスペースへの導線もまとめる。
- 主な型: `AIStudioWorkspaceView`.
- 編集ポイント: AIワークスペースのサイドバー、統合導線、全画面レイアウトを変えるときに触る。
- UI: プロフェッショナル macOS 向けにリファインされたビジュアル (ヘアライン・マテリアル・ホバー演出)。
  ロジック・バインディング・データモデルは一切変更していない。
*/

import SwiftUI

struct AIStudioWorkspaceView: View {
    #if os(iOS)
    @Environment(\.dismiss) private var dismiss
    #endif
    @State private var showAIStudioSettings = false
    @State private var showVoiceChat = false
    @State private var showAgentMode = false
    @StateObject private var aiCoach = AICoachService.shared

    var body: some View {
        Group {
            if showAgentMode {
                AgentBrowserView {
                    showAgentMode = false
                }
                .transition(.opacity)
            } else if aiCoach.executionConfig.reasoningMode == .persona {
                // ペルソナモード: 完全に分離した絆チャット UI に差し替え。
                // 既存 AI Studio のスレッド/コンポーザー/結果ペインは触らないので、
                // 他モードに戻った瞬間に状態がそのまま復元される。
                PersonaChatView()
                    .transition(.opacity)
            } else {
                RootLayoutView(
                    onOpenSettings: {
                        showAIStudioSettings = true
                    },
                    onClearConversation: {
                        AICoachService.shared.clearSavedChat()
                    }
                )
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: aiCoach.executionConfig.reasoningMode)
        .animation(.easeInOut(duration: 0.18), value: showAgentMode)
        .task {
            // AI Studio を開いた瞬間にローカルモデルの prewarm を走らせる。
            // 音声会話シートを開いた時点で既に温まっているようにするため。
            // 通常チャット側でも警告無く再利用される (singleton + bundled server セッション再利用)。
            LocalAssistantRuntimeBridge.shared.prewarmIfPossible()
            // ペルソナ設定を bridge の personaAddendum に同期しておく。
            PersonaSettings.shared.primeBridge()
        }
        .overlay(alignment: .bottomTrailing) {
            if !showAgentMode, aiCoach.executionConfig.reasoningMode != .persona {
                HStack(spacing: 12) {
                    VoiceChatFloatingButton {
                        showVoiceChat = true
                    }
                }
                // Dock や インスペクタパネルに隠れないよう十分な余白を確保。
                .padding(.trailing, 24)
                .padding(.bottom, 32)
                // RootLayoutView の compact/desktop 切り替えで再マウントされても
                // 最前面に来るよう zIndex を高めに固定。
                .zIndex(9_999)
                .allowsHitTesting(true)
            }
        }
        .sheet(isPresented: $showAIStudioSettings) {
            NavigationStack {
                AIStudioSettingsView()
            }
            .viukAdaptiveSheetSizing(minWidth: 820, minHeight: 660)
        }
        .sheet(isPresented: $showVoiceChat) {
            AIVoiceChatView()
                .viukAdaptiveSheetSizing(minWidth: 420, minHeight: 600)
        }
        #if os(iOS)
        .safeAreaInset(edge: .top, alignment: .leading) {
            AIStudioDismissBar {
                dismiss()
            }
        }
        #endif
        .workspaceSandboxPrompt(for: .aiStudio)
    }
}

#if os(iOS)
private struct AIStudioDismissBar: View {
    let onDismiss: () -> Void

    var body: some View {
        HStack {
            Button(action: onDismiss) {
                Label("戻る", systemImage: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay {
                        Capsule()
                            .stroke(AIStudioToken.hairlineStrong, lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("AI Studio を閉じる")

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 6)
        .background(.thinMaterial)
    }
}
#endif

private struct AgentModeFloatingButton: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: "cursorarrow.motionlines.click")
                    .font(.system(size: 17, weight: .bold))
                Text("Agent")
                    .font(.system(size: 13, weight: .bold))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule().stroke(Color.accentColor.opacity(0.28), lineWidth: 1)
            )
            .foregroundStyle(Color.accentColor)
            .shadow(color: .black.opacity(0.20), radius: 10, y: 3)
            .scaleEffect(isHovering ? 1.04 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Agent Mode を開く")
        .accessibilityLabel("Agent Mode")
    }
}

// MARK: - Voice Chat Floating Button

private struct VoiceChatFloatingButton: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 36))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Color.accentColor)
                .padding(14)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(
                    Circle().stroke(Color.accentColor.opacity(0.25), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.22), radius: 10, y: 3)
                .scaleEffect(isHovering ? 1.05 : 1.0)
                .animation(.easeInOut(duration: 0.15), value: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("音声会話を開く")
        .accessibilityLabel("音声会話")
    }
}

// MARK: - Design Tokens

private enum AIStudioToken {
    static let radiusS: CGFloat = 8
    static let radiusM: CGFloat = 10
    static let radiusL: CGFloat = 14
    static let radiusXL: CGFloat = 18

    static let hairline = Color.primary.opacity(0.08)
    static let hairlineStrong = Color.primary.opacity(0.14)
    static let softFill = Color.primary.opacity(0.035)
    static let softFillHover = Color.primary.opacity(0.07)
    static let softFillActive = Color.primary.opacity(0.10)
}

private struct AIStudioHairline: View {
    var body: some View {
        Rectangle()
            .fill(AIStudioToken.hairline)
            .frame(height: 1)
    }
}

// MARK: - Sidebar

private struct AIThreadSidebarView<Footer: View>: View {
    let threads: [AICoachService.ChatThreadSummary]
    let selectedThreadID: String
    @Binding var searchText: String
    let onCreateNew: () -> Void
    let onSelectThread: (String) -> Void
    @ViewBuilder let footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section header
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.tint)
                Text("チャット")
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)

                if threads.isEmpty == false {
                    Text("\(threads.count)")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(AIStudioToken.softFill, in: Capsule())
                }

                Spacer(minLength: 0)

                Button(action: onCreateNew) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(AIStudioIconButtonStyle())
                .help("新しいスレッドを作る")
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            AIThreadSearchField(text: $searchText)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)

            AIStudioHairline()

            AIThreadListView(
                threads: threads,
                selectedThreadID: selectedThreadID,
                onSelectThread: onSelectThread
            )

            AIStudioHairline()

            footer
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.appSecondaryBackground.opacity(0.22))
    }
}

private struct AIThreadSearchField: View {
    @Binding var text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isFocused ? Color.accentColor : .secondary)
            TextField("スレッドを探す", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .focused($isFocused)
            if text.isEmpty == false {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("クリア")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: AIStudioToken.radiusS, style: .continuous)
                .fill(AIStudioToken.softFill)
        }
        .overlay {
            RoundedRectangle(cornerRadius: AIStudioToken.radiusS, style: .continuous)
                .stroke(isFocused ? Color.accentColor.opacity(0.55) : AIStudioToken.hairline, lineWidth: 1)
        }
        .animation(.easeOut(duration: 0.14), value: isFocused)
        .animation(.easeOut(duration: 0.14), value: text.isEmpty)
    }
}

private struct AIThreadListView: View {
    let threads: [AICoachService.ChatThreadSummary]
    let selectedThreadID: String
    let onSelectThread: (String) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if threads.isEmpty {
                    emptyState
                } else {
                    ForEach(threads) { thread in
                        AIThreadRowView(
                            thread: thread,
                            isSelected: thread.id == selectedThreadID,
                            onSelect: {
                                onSelectThread(thread.id)
                            }
                        )
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text("まだスレッドがありません")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("右上の鉛筆アイコンから新しく開始できます")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.vertical, 40)
    }
}

private struct AIThreadRowView: View {
    let thread: AICoachService.ChatThreadSummary
    let isSelected: Bool
    let onSelect: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "bubble.left.fill" : "bubble.left")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.65))
                    .frame(width: 14)

                VStack(alignment: .leading, spacing: 2) {
                    Text(thread.title)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(thread.updatedAt, style: .relative)
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: AIStudioToken.radiusS, style: .continuous)
                    .fill(rowFill)
            }
            .overlay(alignment: .leading) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color.accentColor)
                        .frame(width: 2.5, height: 18)
                        .padding(.leading, -2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .animation(.easeOut(duration: 0.14), value: isSelected)
    }

    private var rowFill: Color {
        if isSelected {
            return Color.accentColor.opacity(0.11)
        }
        if isHovering {
            return AIStudioToken.softFillHover
        }
        return Color.clear
    }
}

private struct AIStudioSidebarStatusView: View {
    let statusTitle: String
    let detail: String
    @State private var isPulsing = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.22))
                    .frame(width: 16, height: 16)
                    .scaleEffect(isPulsing ? 1.5 : 1.0)
                    .opacity(isPulsing ? 0 : 1)
                    .animation(.easeOut(duration: 1.6).repeatForever(autoreverses: false), value: isPulsing)
                Circle()
                    .fill(Color.green)
                    .frame(width: 7, height: 7)
                    .shadow(color: Color.green.opacity(0.5), radius: 2)
            }
            .frame(width: 16, height: 16)
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text("STATUS")
                    .font(.system(size: 9.5, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(.tertiary)
                Text(statusTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: AIStudioToken.radiusM, style: .continuous)
                .fill(AIStudioToken.softFill)
        }
        .overlay {
            RoundedRectangle(cornerRadius: AIStudioToken.radiusM, style: .continuous)
                .stroke(AIStudioToken.hairline, lineWidth: 1)
        }
        .onAppear {
            isPulsing = true
        }
    }
}

// MARK: - Settings

private struct AIStudioSettingsView: View {
    @StateObject private var aiCoach = AICoachService.shared
    @StateObject private var localModelManager = LocalAssistantModelManager.shared
    @StateObject private var localSupportModelManager = LocalSupportModelManager.shared
    @StateObject private var webSearchService = OllamaWebSearchService.shared
    @State private var showModelDetails = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header

                AIStudioSettingsCard(
                    icon: "slider.horizontal.3",
                    iconColor: .blue,
                    title: "会話",
                    subtitle: "普段の使い方に関わる設定だけを上にまとめます。"
                ) {
                    conversationSection
                }

                AIStudioSettingsCard(
                    icon: "eye.fill",
                    iconColor: .purple,
                    title: "表示",
                    subtitle: "会話中に見える補助情報だけを切り替えます。"
                ) {
                    displaySection
                }

                AIStudioSettingsCard(
                    icon: "cpu.fill",
                    iconColor: .indigo,
                    title: "ローカルモデル",
                    subtitle: "いまの状態と、次にやる操作だけを表示します。"
                ) {
                    localModelSection
                }

                AIStudioSettingsCard(
                    icon: "sparkle",
                    iconColor: .orange,
                    title: "Gemma 3 270M 補助モデル",
                    subtitle: "Deep Research の planner / auditor / architect 専用です。Gemma 4 とは別スロットで管理します。"
                ) {
                    localSupportModelSection
                }

                AIStudioSettingsCard(
                    icon: "tray.full.fill",
                    iconColor: .teal,
                    title: "チャット",
                    subtitle: "スレッドを整理したい時だけ使います。"
                ) {
                    Button {
                        aiCoach.createNewChatThread()
                    } label: {
                        Label("新しいチャットを作る", systemImage: "plus.bubble")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }
            .padding(28)
            .frame(maxWidth: 880, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.appCanvasBackground.ignoresSafeArea())
        .navigationTitle("AI Studio 設定")
        .onAppear {
            webSearchService.refreshConfiguredSecrets()
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.accentColor.opacity(0.28), Color.accentColor.opacity(0.10)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 38, height: 38)
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.tint)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(AIStudioToken.hairline, lineWidth: 1)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("AI Studio 設定")
                        .font(.system(size: 22, weight: .bold))
                    Text("会話とローカルモデルの挙動をまとめて管理します。")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 2)

            Text("会話でよく触る設定だけをここにまとめています。ローカルモデルの細かい管理は、必要な時だけ下から開けます。")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Conversation Section

    @ViewBuilder
    private var conversationSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            AIStudioFormRow(label: "モード") {
                Picker("モード", selection: reasoningModeBinding) {
                    ForEach(ReasoningMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if aiCoach.executionConfig.reasoningMode == .fast {
                AIStudioFormRow(label: "リサーチ") {
                    Picker("リサーチ", selection: researchModeBinding) {
                        Text("OFF").tag(ResearchMode.off)
                        Text("ON").tag(ResearchMode.on)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            } else {
                AIStudioFormRow(label: "リサーチ") {
                    Label("必要時に自動検索", systemImage: "magnifyingglass.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }

            if aiCoach.executionConfig.reasoningMode == .thinking {
                AIStudioFormRow(label: "詳細度") {
                    Picker("Thinking 詳細度", selection: thinkingLevelBinding) {
                        Text("標準").tag(ThinkingLevel.standard)
                        Text("拡張").tag(ThinkingLevel.extended)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }

            AIStudioHairline()

            HStack(spacing: 10) {
                AIStudioStatusPill(
                    icon: "slider.horizontal.3",
                    title: "現在のモード",
                    value: aiCoach.executionConfig.displayName,
                    tint: .blue
                )
                AIStudioStatusPill(
                    icon: "globe",
                    title: "Web Search",
                    value: webSearchService.isEnabled ? "オン" : "オフ",
                    tint: .cyan
                )
            }

            AIStudioFormRow(label: "AIブラウジング") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(
                        "検索後に上位ページ本文まで読む",
                        isOn: webBrowsingEnabledBinding
                    )
                    .toggleStyle(.switch)
                    .tint(.accentColor)

                    Text(webSearchService.webBrowsingStatusSummary)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Toggle(
                        "Web本文を Gemma 4 で読む",
                        isOn: gemmaWebReaderEnabledBinding
                    )
                    .toggleStyle(.switch)
                    .tint(.accentColor)
                    .disabled(!webSearchService.webBrowsingEnabled)

                    Text(webSearchService.hasGemmaWebReaderAPIKey ? "Gemma 4 Web読解を使用" : "Gemma 4 Web読解は準備中です。")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(webSearchService.hasGemmaWebReaderAPIKey ? Color.secondary : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Display Section

    @ViewBuilder
    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(
                "考え方の流れを表示",
                isOn: Binding(
                    get: { aiCoach.showThoughtTimeline },
                    set: { aiCoach.setThoughtTimelineVisible($0) }
                )
            )
            .toggleStyle(.switch)
            .tint(.accentColor)

            DeveloperModeToggleRow()
        }
    }

    // MARK: Local Model Section

    @ViewBuilder
    private var localModelSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(localModelStatusIconColor.opacity(0.15))
                        .frame(width: 34, height: 34)
                    Image(systemName: localModelStatusIconName)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(localModelStatusIconColor)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(localModelManager.statusTitle)
                        .font(.system(size: 14.5, weight: .semibold))
                    Text(localModelManager.statusMessage)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                AIStudioStatusPill(
                    icon: "dot.radiowaves.up.forward",
                    title: "状態",
                    value: localModelManager.runnerStatusLabel,
                    tint: .indigo
                )
                if let installedURL = localModelManager.installedModelURL {
                    AIStudioStatusPill(
                        icon: "checkmark.seal.fill",
                        title: "保存済み",
                        value: installedURL.lastPathComponent,
                        tint: .green
                    )
                } else {
                    AIStudioStatusPill(
                        icon: "arrow.down.circle",
                        title: "配布元",
                        value: localModelManager.sourceDisplayLabel,
                        tint: .orange
                    )
                }
            }

            if let runtimeWarningMessage = localModelManager.runtimeWarningMessage {
                AIStudioInlineNote(text: runtimeWarningMessage, tint: .orange)
            } else {
                let tint: Color = localModelManager.isDownloadStateFailure
                    ? .red
                    : (localModelManager.isDownloadStateWarning ? .orange : .green)
                AIStudioInlineNote(text: localModelManager.downloadStateSummary, tint: tint)
            }

            if localModelManager.hasLegacyInstalledModel {
                AIStudioInlineNote(
                    text: "旧 Gemma 3n モデルが残っています。旧モデルを削除しても、現在の Gemma 4 には影響しません。",
                    tint: .blue
                )
            }

            if let lastErrorMessage = localModelManager.supplementalLastErrorMessage,
               lastErrorMessage.isEmpty == false {
                AIStudioInlineNote(text: lastErrorMessage, tint: .red)
            }

            HStack(spacing: 10) {
                Button {
                    performLocalModelPrimaryAction()
                } label: {
                    Label(localModelPrimaryActionTitle, systemImage: localModelPrimaryActionIconName)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)

                if localModelManager.canRestartDownloadFromScratch && localModelManager.isDownloading == false {
                    Button {
                        localModelManager.restartDownloadFromScratch()
                    } label: {
                        Label("最初からやり直す", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.bordered)
                }
            }

            HStack(spacing: 10) {
                Button(role: .destructive) {
                    localModelManager.removeInstalledModel()
                } label: {
                    Label("現在のモデルを削除", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .disabled(localModelManager.installedModelURL == nil && localModelManager.isDownloading == false)

                if localModelManager.hasLegacyInstalledModel {
                    Button(role: .destructive) {
                        localModelManager.removeLegacyInstalledModel()
                    } label: {
                        Label("旧モデルを削除", systemImage: "trash.slash")
                    }
                    .buttonStyle(.bordered)
                }
            }

            if localModelManager.isDownloading, let percent = localModelManager.progressValue {
                AIStudioDownloadProgressView(
                    progress: percent,
                    receivedBytes: localModelManager.downloadedBytes,
                    expectedBytes: localModelManager.expectedBytes,
                    remainingSummary: localModelManager.estimatedRemainingSummary,
                    transferRateSummary: localModelManager.transferRateSummary
                )
            }

            DisclosureGroup(isExpanded: $showModelDetails) {
                VStack(alignment: .leading, spacing: 8) {
                    AIStudioInfoRow(label: "ローカル状態", value: localModelManager.runnerStatusLabel)
                    AIStudioInfoRow(label: "Web Search", value: webSearchService.statusSummary)
                    AIStudioInfoRow(label: "接続", value: NetworkStatusMonitor.shared.statusSummary)
                    AIStudioInfoRow(label: "実行ブリッジ", value: localModelManager.runtimeStatusSummary)
                    if let legacyInstalledModelURL = localModelManager.legacyInstalledModelURL {
                        AIStudioInfoRow(label: "旧モデル", value: legacyInstalledModelURL.lastPathComponent)
                    }
                    if let runtimeDiagnosticMessage = localModelManager.runtimeDiagnosticMessage,
                       runtimeDiagnosticMessage.isEmpty == false {
                        AIStudioInlineNote(text: runtimeDiagnosticMessage, tint: .orange)
                    }
                }
                .padding(.top, 10)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11, weight: .semibold))
                    Text("モデルの詳細を表示")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.secondary)
            }
            .animation(.easeOut(duration: 0.18), value: showModelDetails)
        }
    }

    // MARK: Local Support Model Section

    @ViewBuilder
    private var localSupportModelSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(localSupportModelStatusIconColor.opacity(0.15))
                        .frame(width: 34, height: 34)
                    Image(systemName: localSupportModelStatusIconName)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(localSupportModelStatusIconColor)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(localSupportModelManager.statusTitle)
                        .font(.system(size: 14.5, weight: .semibold))
                    Text(localSupportModelManager.statusMessage)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                AIStudioStatusPill(
                    icon: "dot.radiowaves.up.forward",
                    title: "状態",
                    value: localSupportModelManager.runnerStatusLabel,
                    tint: .orange
                )
                if let installedURL = localSupportModelManager.installedModelURL {
                    AIStudioStatusPill(
                        icon: "checkmark.seal.fill",
                        title: "保存済み",
                        value: installedURL.lastPathComponent,
                        tint: .green
                    )
                } else {
                    AIStudioStatusPill(
                        icon: "arrow.down.circle",
                        title: "配布元",
                        value: localSupportModelManager.sourceDisplayLabel,
                        tint: .orange
                    )
                }
            }

            let supportTint: Color = localSupportModelManager.runtimeAvailability == .recentFailure ? .orange : .green
            AIStudioInlineNote(text: localSupportModelManager.downloadStateSummary, tint: supportTint)

            if localSupportModelManager.installedModelURL == nil && localSupportModelManager.isDownloading == false {
                AIStudioInlineNote(
                    text: "Deep Research 開始時に自動導入も試みますが、ここで先にダウンロードしておくと待ち時間を減らせます。",
                    tint: .blue
                )
            }

            if localSupportModelManager.runtimeAvailability == .recentFailure {
                AIStudioInlineNote(text: localSupportModelManager.runtimeStatusSummary, tint: .orange)
            }

            if let lastErrorMessage = localSupportModelManager.lastErrorMessage,
               lastErrorMessage.isEmpty == false {
                AIStudioInlineNote(text: lastErrorMessage, tint: .red)
            }

            HStack(spacing: 10) {
                Button {
                    performLocalSupportModelPrimaryAction()
                } label: {
                    Label(localSupportModelPrimaryActionTitle, systemImage: localSupportModelPrimaryActionIconName)
                }
                .buttonStyle(.borderedProminent)

                Button(role: .destructive) {
                    localSupportModelManager.removeInstalledModel()
                } label: {
                    Label("現在の補助モデルを削除", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .disabled(localSupportModelManager.installedModelURL == nil && localSupportModelManager.isDownloading == false)
            }

            if localSupportModelManager.isDownloading, let percent = localSupportModelManager.progressValue {
                AIStudioDownloadProgressView(
                    progress: percent,
                    receivedBytes: localSupportModelManager.downloadedBytes,
                    expectedBytes: localSupportModelManager.expectedBytes,
                    remainingSummary: localSupportModelManager.estimatedRemainingSummary,
                    transferRateSummary: localSupportModelManager.transferRateSummary
                )
            }
        }
    }

    // MARK: Action Titles / Icons

    private var localModelPrimaryActionTitle: String {
        if localModelManager.isDownloading {
            return "ダウンロード停止"
        }
        if localModelManager.canResumeDownload {
            return "続きから再開"
        }
        if localModelManager.installedModelURL != nil {
            switch localModelManager.runtimeAvailability {
            case .executable:
                return "状態を確認"
            case .savedOnly, .recentFailure:
                return "実行を確認"
            case .modelMissing:
                break
            }
        }
        return "ダウンロード開始"
    }

    private var localModelPrimaryActionIconName: String {
        if localModelManager.isDownloading {
            return "stop.circle"
        }
        if localModelManager.canResumeDownload {
            return "play.circle"
        }
        if localModelManager.installedModelURL != nil {
            switch localModelManager.runtimeAvailability {
            case .executable:
                return "checkmark.circle"
            case .savedOnly, .recentFailure:
                return "bolt.horizontal.circle"
            case .modelMissing:
                break
            }
        }
        return "arrow.down.circle"
    }

    private var localModelStatusIconName: String {
        if localModelManager.isDownloading {
            return "arrow.down.circle.fill"
        }
        if localModelManager.canResumeDownload {
            return "arrow.clockwise.circle.fill"
        }
        switch localModelManager.runtimeAvailability {
        case .executable:
            return "checkmark.circle.fill"
        case .recentFailure:
            return "exclamationmark.triangle.fill"
        case .savedOnly:
            return "externaldrive.fill.badge.person.crop"
        case .modelMissing:
            return localModelManager.lastErrorMessage == nil ? "square.and.arrow.down.fill" : "exclamationmark.triangle.fill"
        }
    }

    private var localModelStatusIconColor: Color {
        if localModelManager.isDownloading || localModelManager.canResumeDownload {
            return .orange
        }
        switch localModelManager.runtimeAvailability {
        case .executable:
            return .green
        case .recentFailure, .savedOnly:
            return .orange
        case .modelMissing:
            return localModelManager.lastErrorMessage == nil ? .blue : .red
        }
    }

    private var localSupportModelPrimaryActionTitle: String {
        if localSupportModelManager.isDownloading {
            return "ダウンロード停止"
        }
        if localSupportModelManager.installedModelURL != nil {
            switch localSupportModelManager.runtimeAvailability {
            case .executable:
                return "状態を確認"
            case .savedOnly, .recentFailure:
                return "実行を確認"
            case .modelMissing:
                break
            }
        }
        return "ダウンロード開始"
    }

    private var localSupportModelPrimaryActionIconName: String {
        if localSupportModelManager.isDownloading {
            return "stop.circle"
        }
        if localSupportModelManager.installedModelURL != nil {
            switch localSupportModelManager.runtimeAvailability {
            case .executable:
                return "checkmark.circle"
            case .savedOnly, .recentFailure:
                return "bolt.horizontal.circle"
            case .modelMissing:
                break
            }
        }
        return "arrow.down.circle"
    }

    private var localSupportModelStatusIconName: String {
        if localSupportModelManager.isDownloading {
            return "arrow.down.circle.fill"
        }
        switch localSupportModelManager.runtimeAvailability {
        case .executable:
            return "checkmark.circle.fill"
        case .recentFailure:
            return "exclamationmark.triangle.fill"
        case .savedOnly:
            return "externaldrive.fill.badge.person.crop"
        case .modelMissing:
            return localSupportModelManager.lastErrorMessage == nil ? "square.and.arrow.down.fill" : "exclamationmark.triangle.fill"
        }
    }

    private var localSupportModelStatusIconColor: Color {
        if localSupportModelManager.isDownloading {
            return .orange
        }
        switch localSupportModelManager.runtimeAvailability {
        case .executable:
            return .green
        case .recentFailure, .savedOnly:
            return .orange
        case .modelMissing:
            return localSupportModelManager.lastErrorMessage == nil ? .blue : .red
        }
    }

    private func performLocalModelPrimaryAction() {
        if localModelManager.isDownloading {
            localModelManager.cancelDownload()
        } else if localModelManager.canResumeDownload {
            localModelManager.resumeDownloadIfPossible()
        } else if localModelManager.installedModelURL != nil {
            localModelManager.recheckRuntimeAvailability()
        } else {
            localModelManager.startDownload()
        }
    }

    private func performLocalSupportModelPrimaryAction() {
        if localSupportModelManager.isDownloading {
            localSupportModelManager.cancelDownload()
        } else if localSupportModelManager.installedModelURL != nil {
            localSupportModelManager.recheckRuntimeAvailability()
        } else {
            localSupportModelManager.startDownload()
        }
    }

    private var reasoningModeBinding: Binding<ReasoningMode> {
        Binding(
            get: { aiCoach.executionConfig.reasoningMode },
            set: { aiCoach.setReasoningMode($0) }
        )
    }

    private var researchModeBinding: Binding<ResearchMode> {
        Binding(
            get: { aiCoach.executionConfig.researchMode ?? .on },
            set: { aiCoach.setResearchMode($0) }
        )
    }

    private var thinkingLevelBinding: Binding<ThinkingLevel> {
        Binding(
            get: { aiCoach.executionConfig.thinkingLevel ?? .standard },
            set: { aiCoach.setThinkingLevel($0) }
        )
    }

    private var webBrowsingEnabledBinding: Binding<Bool> {
        Binding(
            get: { webSearchService.webBrowsingEnabled },
            set: { webSearchService.updateWebBrowsingEnabled($0) }
        )
    }

    private var gemmaWebReaderEnabledBinding: Binding<Bool> {
        Binding(
            get: { webSearchService.gemmaWebReaderEnabled },
            set: { webSearchService.updateGemmaWebReaderEnabled($0) }
        )
    }
}

// MARK: - Form Row

private struct AIStudioFormRow<Control: View>: View {
    let label: String
    @ViewBuilder let control: Control

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label)
                .font(.system(size: 10.5, weight: .bold))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            control
        }
    }
}

// MARK: - Settings Card

private struct AIStudioSettingsCard<Content: View>: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    init(
        icon: String,
        iconColor: Color,
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) {
        self.icon = icon
        self.iconColor = iconColor
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(iconColor.opacity(0.14))
                        .frame(width: 32, height: 32)
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(iconColor)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            AIStudioHairline()

            content
        }
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: AIStudioToken.radiusXL, style: .continuous)
                .fill(Color.appElevatedBackground.opacity(0.95))
        }
        .overlay {
            RoundedRectangle(cornerRadius: AIStudioToken.radiusXL, style: .continuous)
                .stroke(AIStudioToken.hairline, lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.025), radius: 10, y: 4)
    }
}

// MARK: - Status Pill

private struct AIStudioStatusPill: View {
    let icon: String?
    let title: String
    let value: String
    let tint: Color

    init(icon: String? = nil, title: String, value: String, tint: Color) {
        self.icon = icon
        self.title = title
        self.value = value
        self.tint = tint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(tint)
                }
                Text(title)
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.4)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: AIStudioToken.radiusM, style: .continuous)
                .fill(tint.opacity(0.08))
        }
        .overlay {
            RoundedRectangle(cornerRadius: AIStudioToken.radiusM, style: .continuous)
                .stroke(tint.opacity(0.22), lineWidth: 1)
        }
    }
}

// MARK: - Inline Note

private struct AIStudioInlineNote: View {
    let text: String
    let tint: Color

    private var iconName: String {
        switch tint {
        case .red:
            return "exclamationmark.octagon.fill"
        case .orange:
            return "exclamationmark.triangle.fill"
        case .green:
            return "checkmark.seal.fill"
        case .blue:
            return "info.circle.fill"
        default:
            return "info.circle.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: AIStudioToken.radiusM, style: .continuous)
                .fill(tint.opacity(0.075))
        }
        .overlay {
            RoundedRectangle(cornerRadius: AIStudioToken.radiusM, style: .continuous)
                .stroke(tint.opacity(0.22), lineWidth: 1)
        }
    }
}

// MARK: - Info Row

private struct AIStudioInfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.system(size: 10.5, weight: .bold))
                .tracking(0.4)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            Text(value)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Download Progress

private struct AIStudioDownloadProgressView: View {
    let progress: Double
    let receivedBytes: Int64
    let expectedBytes: Int64
    let remainingSummary: String?
    let transferRateSummary: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("ダウンロード中")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.4)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 12, weight: .bold).monospacedDigit())
                    .foregroundStyle(.tint)
            }

            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(.accentColor)

            Text("受信: \(ByteCountFormatter.string(fromByteCount: receivedBytes, countStyle: .file)) / \(expectedBytes > 0 ? ByteCountFormatter.string(fromByteCount: expectedBytes, countStyle: .file) : "不明")")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)

            let progressDetails = [remainingSummary, transferRateSummary]
                .compactMap { $0 }
                .joined(separator: " ・ ")
            if progressDetails.isEmpty == false {
                Text(progressDetails)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary.opacity(0.9))
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: AIStudioToken.radiusM, style: .continuous)
                .fill(AIStudioToken.softFill)
        }
        .overlay {
            RoundedRectangle(cornerRadius: AIStudioToken.radiusM, style: .continuous)
                .stroke(AIStudioToken.hairline, lineWidth: 1)
        }
    }
}

// MARK: - Icon Button Style

private struct AIStudioIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        IconButtonContainer(configuration: configuration)
    }

    private struct IconButtonContainer: View {
        let configuration: ButtonStyleConfiguration
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(iconColor)
                .background {
                    RoundedRectangle(cornerRadius: AIStudioToken.radiusS, style: .continuous)
                        .fill(backgroundFill)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: AIStudioToken.radiusS, style: .continuous)
                        .stroke(AIStudioToken.hairline, lineWidth: 1)
                }
                .onHover { hovering in
                    isHovering = hovering
                }
                .animation(.easeOut(duration: 0.12), value: isHovering)
                .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
        }

        private var iconColor: Color {
            if configuration.isPressed {
                return Color.accentColor
            }
            return isHovering ? .primary : .secondary
        }

        private var backgroundFill: Color {
            if configuration.isPressed {
                return Color.accentColor.opacity(0.14)
            }
            if isHovering {
                return AIStudioToken.softFillHover
            }
            return AIStudioToken.softFill
        }
    }
}

/// 設定の「表示」セクションに置く開発者モードトグル。
/// 右パネルの内部実装名・directiveParseStatus・補助モデル I/O などを
/// 開発者モード時のみ表示する。デフォルト OFF。
private struct DeveloperModeToggleRow: View {
    @AppStorage("studio.developerMode.enabled") private var isEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("開発者モード (詳細ログを表示)", isOn: $isEnabled)
                .toggleStyle(.switch)
                .tint(.accentColor)
            Text("右パネルに internal モデル名・実行ステータス・補助モデル I/O などの技術情報を出します。")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
