/*
仕様:
- 役割: AIコーチ画面の表示と入力導線を担当するUIファイル。
- 主な型: `AICoachView` と関連する補助View群。
- 編集ポイント: チャット見た目、入力導線、クイックアクション、表示レイアウトを変えるときに触る。
*/
#if os(macOS)
import AppKit
typealias PlatformImage = NSImage
#elseif canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#endif
import PhotosUI
import SwiftUI

private func dismissAICoachKeyboard() {
    #if canImport(UIKit)
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    #endif
}

struct AICoachView: View {
    fileprivate struct ThoughtDisplayItem: Identifiable {
        let id: String
        let title: String
        let detail: String?
        let count: Int

        var previewText: String {
            if let detail, !detail.isEmpty {
                return "\(title)\n\(detail)"
            }
            return title
        }
    }

    fileprivate struct ThoughtDisplaySection: Identifiable {
        let id: String
        let title: String
        let symbolName: String
        let tint: Color
        let items: [ThoughtDisplayItem]
    }

    @StateObject private var aiCoach = AICoachService.shared
    @StateObject private var localModelManager = LocalAssistantModelManager.shared
    @StateObject private var localSupportModelManager = LocalSupportModelManager.shared
    @StateObject private var webSearchService = OllamaWebSearchService.shared
    @StateObject private var networkMonitor = NetworkStatusMonitor.shared
    @State private var userInput = ""
    @State private var memoryDraft = ""
    @State private var showMemoryEditor = false
    @State private var showMemoryManager = false
    @State private var showAnalysisDetails = false
    @State private var showThoughtDetailsInline = false
    @State private var selectedThoughtDetails: AICoachService.ResponseThoughtDetails?
    @State private var isViewingLiveThoughtDetails = false
    @State private var showRawThoughtSection = false
    @State private var showExecutionLogSection = false
    @State private var showThoughtFlowSection = false
    @State private var showDebugDetailsSheet = false
    @State private var selectedDebugDetails: AICoachService.ResponseDebugDetails?
    @State private var showSystemPromptSheet = false
    @State private var showLocalModelSheet = false
    @State private var showLocalModelAdvancedSettings = false
    @State private var showLocalSupportModelAdvancedSettings = false
    @State private var showWebSearchAdvancedSettings = false
    @State private var localModelURLDraft = LocalAssistantModelManager.shared.sourceURLString
    @State private var localModelTokenDraft = LocalAssistantModelManager.shared.accessToken
    @State private var localSupportModelURLDraft = LocalSupportModelManager.shared.sourceURLString
    @State private var localSupportModelTokenDraft = LocalSupportModelManager.shared.accessToken
    @State private var systemPromptDraft = ""
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var selectedImageData: [Data] = []
    @FocusState private var composerFocused: Bool
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let coachMode: AICoachService.CoachMode
    let onSearchRequest: ((String) -> Void)?
    var showsDismissButton: Bool = true
    var showsStudioThreadMenu: Bool = true
    var onOpenStudioSettings: (() -> Void)? = nil
    @Environment(\.presentationMode) private var presentationMode

    private var reasoningModeBinding: Binding<ReasoningMode> {
        Binding(
            get: { aiCoach.reasoningMode },
            set: { aiCoach.setReasoningMode($0) }
        )
    }

    private var researchModeBinding: Binding<ResearchMode> {
        Binding(
            get: { aiCoach.executionConfig.researchMode ?? .on },
            set: { aiCoach.setResearchMode($0) }
        )
    }

    private var fastSelectableResearchModes: [ResearchMode] {
        [.off, .on]
    }

    private var thinkingLevelBinding: Binding<ThinkingLevel> {
        Binding(
            get: { aiCoach.thinkingLevel },
            set: { aiCoach.setThinkingLevel($0) }
        )
    }

    private var thoughtTimelineVisibleBinding: Binding<Bool> {
        Binding(
            get: { aiCoach.showThoughtTimeline },
            set: { aiCoach.setThoughtTimelineVisible($0) }
        )
    }

    private var isGuardianMode: Bool {
        coachMode == .guardian
    }

    private var isStudioMode: Bool {
        coachMode == .studio
    }

    private var usesMinimalStudioChrome: Bool {
        isStudioMode && !aiCoach.messages.isEmpty
    }

    private var navigationTitleText: String {
        switch coachMode {
        case .studio:
            return "AI Studio"
        case .child:
            return "子ども用AI"
        case .guardian:
            return "保護者用AI"
        }
    }

    private var coachHeaderLabelText: String {
        switch coachMode {
        case .studio:
            return "統合 AI Studio"
        case .child:
            return "子ども用AIコーチ"
        case .guardian:
            return "保護者用AIアシスタント"
        }
    }

    private var coachHeaderIconName: String {
        switch coachMode {
        case .studio:
            return "sparkles.rectangle.stack.fill"
        case .child:
            return "figure.child"
        case .guardian:
            return "person.badge.key.fill"
        }
    }

    private var coachHeaderDescription: String {
        switch coachMode {
        case .studio:
            return "Web、Learning、Map、Love を横断しながら、その場で整理します。"
        case .child:
            return "質問、要約、検索を1つの流れで使えます。"
        case .guardian:
            return "設定の相談や変更を、この画面だけで進めます。"
        }
    }
    
    var body: some View {
        GeometryReader { proxy in
            let availableWidth = proxy.size.width

            VStack(spacing: 0) {
                coachControlPanel(availableWidth: availableWidth)
                    .padding(.horizontal)
                    .padding(.top, topContentPadding(for: availableWidth))

                if shouldShowStatusBar {
                    if isStudioMode {
                        studioInlineStatusBar
                            .padding(.horizontal, 12)
                            .padding(.top, 8)
                    } else {
                        coachStatusBar
                            .padding(.horizontal, 12)
                            .padding(.top, 8)
                    }
                }

                if shouldShowQuickActions {
                    quickActionStrip
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                }

                conversationPanel(availableWidth: availableWidth)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                bottomComposerArea(availableWidth: availableWidth)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(coachBackdrop.ignoresSafeArea())
        }
        .navigationTitle(navigationTitleText)
        .toolbar {
            if !isStudioMode {
                ToolbarItem(placement: .automatic) {
                    Button("会話を消す") {
                        aiCoach.clearSavedChat()
                    }
                    .disabled(aiCoach.messages.isEmpty || aiCoach.isLoading)
                }
            }
            if showsDismissButton && !isStudioMode {
                ToolbarItem(placement: .primaryAction) {
                    Button("閉じる") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
        .onAppear {
            if aiCoach.coachMode != coachMode {
                DispatchQueue.main.async {
                    aiCoach.setMode(coachMode)
                }
            }
            memoryDraft = aiCoach.memoryNote
            systemPromptDraft = aiCoach.customSystemPrompt
            showAnalysisDetails = isGuardianMode
            showThoughtDetailsInline = false
            showThoughtFlowSection = false
            showRawThoughtSection = false
            showExecutionLogSection = false
            localModelURLDraft = localModelManager.sourceURLString
            localModelTokenDraft = localModelManager.accessToken
        }
        .onChange(of: aiCoach.pendingSearchQuery) { _, query in
            guard coachMode != .studio, let query, let onSearchRequest else { return }
            onSearchRequest(query)
            aiCoach.pendingSearchQuery = nil
        }
        .sheet(isPresented: $showDebugDetailsSheet, onDismiss: {
            selectedDebugDetails = nil
        }) {
            debugDetailsSheet
                .viukAdaptiveSheetSizing(minWidth: 560, minHeight: 460)
        }
        .sheet(isPresented: $showMemoryManager) {
            memoryManagerSheet
                .viukAdaptiveSheetSizing(minWidth: 520, minHeight: 420)
        }
        .sheet(isPresented: $showSystemPromptSheet) {
            systemPromptSheet
                .viukAdaptiveSheetSizing(minWidth: 560, minHeight: 420)
        }
        .sheet(isPresented: $showLocalModelSheet) {
            localModelSheet
                .viukAdaptiveSheetSizing(minWidth: 560, minHeight: 460)
        }
    }

    private func bottomComposerArea(availableWidth: CGFloat) -> some View {
        VStack(spacing: 8) {
            if let transientStatusMessage = aiCoach.transientStatusMessage {
                transientStatusBanner(message: transientStatusMessage)
                    .padding(.horizontal, 12)
            }

            if showThoughtDetailsInline {
                thoughtDetailsInlinePanel
                    .padding(.horizontal, 12)
            }

            if isGuardianMode, aiCoach.pendingMemoryProposal != nil || aiCoach.pendingSettingsProposal != nil {
                approvalPanel
                    .padding(.horizontal, 12)
            }

            if !selectedImageData.isEmpty {
                composerAttachmentStrip
                    .padding(.horizontal, 12)
            }

            composerBar(availableWidth: availableWidth)
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .padding(.bottom, 12)
        }
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private var shouldShowStatusBar: Bool {
        if coachMode != .studio {
            return true
        }

        return false
    }

    private var shouldShowQuickActions: Bool {
        !isStudioMode && !aiCoach.quickActions.isEmpty && aiCoach.messages.isEmpty
    }

    private var isProcessing: Bool {
        aiCoach.isLoading || localModelManager.isDownloading
    }

    private var activeThoughtStepType: ThoughtStepType? {
        guard aiCoach.isLoading else { return nil }
        return aiCoach.thoughtTimeline.last?.type
    }

    private var activeThoughtStepColor: Color? {
        guard let type = activeThoughtStepType else { return nil }
        return color(for: type)
    }

    private var isSearchActive: Bool {
        activeThoughtStepType == .search
    }

    private var isSupportActive: Bool {
        activeThoughtStepType == .supportModel || (!aiCoach.supportModelCalls.isEmpty && aiCoach.isLoading)
    }

    private var isSynthesisActive: Bool {
        activeThoughtStepType == .synthesis || activeThoughtStepType == .finalization
    }

    private var coachStatusBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        AIProcessingPulseView(
                            tint: aiCoach.isLoading ? .orange : modeAccentColor,
                            systemName: aiCoach.isLoading ? "sparkles" : aiCoach.reasoningMode.iconName,
                            isActive: isProcessing
                        )
                        .frame(width: 18, height: 18)
                        Text(aiCoach.isLoading ? "応答を整理中" : "AI ステータス")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.primary)
                    }

                    Text(aiCoach.isLoading ? "必要な情報だけ見に行って、回答をまとめています。" : "今のモードと利用状況だけをここで確認できます。")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                Button("ローカルAI設定") {
                    localModelURLDraft = localModelManager.sourceURLString
                    localModelTokenDraft = localModelManager.accessToken
                    showLocalModelSheet = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 10)], spacing: 10) {
                statusChip(title: "推論", value: aiCoach.executionConfig.displayName, tint: modeAccentColor, isActive: isSynthesisActive)
                statusChip(title: "モデル", value: aiCoach.activeModelDisplayName, tint: .indigo, isActive: aiCoach.isLoading && !isSearchActive)
                statusChip(title: "検索", value: "\(aiCoach.searchCallCount)/\(aiCoach.executionConfig.maxSearchCalls)", tint: .teal, isActive: isSearchActive)
                statusChip(title: "ローカル", value: localModelStatusLabel, tint: .green, isActive: localModelManager.isDownloading)
                if aiCoach.executionConfig.allowSupportModels {
                    statusChip(title: "補助モデル", value: aiCoach.supportModelCalls.isEmpty ? "待機中" : "\(aiCoach.supportModelCalls.count)回", tint: .orange, isActive: isSupportActive)
                }
                statusChip(title: "Web Search", value: webSearchStatusLabel, tint: .cyan, isActive: isSearchActive && webSearchService.isEnabled)
            }

            // 仕様9.4: 流れる線アニメーションは使わない → dot indicator に置き換え
            if isProcessing {
                HStack(spacing: 6) {
                    let tint = activeThoughtStepColor ?? modeAccentColor
                    AIActivityDotsView(tint: tint, dotSize: 4)
                        .frame(width: 28, height: 8)
                    Text(aiCoach.thoughtTimeline.last?.title ?? "処理中…")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }

            if let quotaStatusMessage = aiCoach.quotaStatusMessage, !quotaStatusMessage.isEmpty {
                inlineNotice(text: quotaStatusMessage, tint: .orange)
            }

            if let lastErrorMessage = localModelManager.lastErrorMessage, !lastErrorMessage.isEmpty {
                inlineNotice(text: lastErrorMessage, tint: .red)
            }

            if let runtimeWarningMessage = localModelManager.runtimeWarningMessage,
               !runtimeWarningMessage.isEmpty,
               runtimeWarningMessage != localModelManager.lastErrorMessage {
                inlineNotice(text: runtimeWarningMessage, tint: .orange)
            }

            if localModelManager.isDownloading, let progress = localModelManager.progressValue {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                    Text("モデル受信中 \(Int(progress * 100))%")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .viukSurfaceCard(cornerRadius: 12, fill: Color.appElevatedBackground.opacity(0.94), border: Color.appBorder.opacity(0.12), shadowOpacity: 0.015, shadowRadius: 8, shadowY: 4)
    }

    private var studioInlineStatusBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let inlineNoticeMessage = studioInlineNoticeMessage {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: studioInlineNoticeIconName)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(studioInlineNoticeTint)
                    Text(inlineNoticeMessage)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
            }

            if localModelManager.isDownloading, let progress = localModelManager.progressValue {
                HStack(spacing: 10) {
                    compactStatusPill(
                        title: "ローカル",
                        value: "受信中 \(Int(progress * 100))%",
                        tint: .green,
                        isActive: true
                    )

                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.appElevatedBackground.opacity(0.72))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(studioInlineNoticeTint.opacity(0.12), lineWidth: 1)
        )
        .cornerRadius(12)
    }

    private var studioInlineNoticeMessage: String? {
        switch localModelManager.runtimeAvailability {
        case .recentFailure:
            return "この端末でのローカル会話確認に失敗したため、今回は代替応答で続けています。"
        case .savedOnly:
            return "モデルは保存済みですが、Gemma はまだこの端末で使えていません。"
        case .executable, .modelMissing:
            break
        }

        if let lastErrorMessage = localModelManager.lastErrorMessage, !lastErrorMessage.isEmpty {
            return "ローカルモデルの保存で問題が起きています。設定から確認してください。"
        }

        if let quotaStatusMessage = aiCoach.quotaStatusMessage, !quotaStatusMessage.isEmpty {
            if quotaStatusMessage.contains("高精度接続が未設定") {
                return "高精度応答はまだ使えないため、いまは端末側の応答で続けています。"
            }
            if quotaStatusMessage.contains("上限")
                || quotaStatusMessage.contains("利用枠")
                || quotaStatusMessage.contains("混雑") {
                return "高精度応答を使えないため、今回は代替応答で続けています。"
            }
            return quotaStatusMessage
        }

        return nil
    }

    private var studioInlineNoticeTint: Color {
        if localModelManager.runtimeAvailability == .recentFailure || localModelManager.runtimeAvailability == .savedOnly {
            return .orange
        }
        if localModelManager.lastErrorMessage?.isEmpty == false {
            return .red
        }
        if aiCoach.quotaStatusMessage?.isEmpty == false {
            return .orange
        }
        return .green
    }

    private var studioInlineNoticeIconName: String {
        if localModelManager.runtimeAvailability == .recentFailure || localModelManager.runtimeAvailability == .savedOnly {
            return "exclamationmark.circle.fill"
        }
        if localModelManager.lastErrorMessage?.isEmpty == false {
            return "exclamationmark.triangle.fill"
        }
        if aiCoach.quotaStatusMessage?.isEmpty == false {
            return "info.circle.fill"
        }
        return "checkmark.circle.fill"
    }

    private var localModelSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("AIセットアップ")
                            .font(.system(size: 28, weight: .bold))
                        Text("\(LocalAssistantModelProfile.modelName) をアプリ内で保存・確認するための画面です。通常利用では外部APIキーの入力は想定していません。")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                            statusChip(title: "ローカルモデル", value: localModelStatusLabel, tint: .green)
                            statusChip(title: "ローカル補助", value: localSupportModelManager.statusTitle, tint: .mint)
                            statusChip(title: "Web Search", value: webSearchStatusLabel, tint: .cyan)
                            statusChip(title: "ローカル状態", value: localModelManager.runnerStatusLabel, tint: .indigo)
                            statusChip(title: "接続", value: networkMonitor.statusSummary, tint: .orange)
                        }
                    }

                    settingsCard(title: "ローカルモデル", subtitle: "今どうなっているかと、次にやる操作だけを表示します。") {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: localModelStatusIconName)
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundColor(localModelStatusIconColor)
                                    .frame(width: 28)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(localModelManager.statusTitle)
                                        .font(.system(size: 15, weight: .bold))
                                    Text(localModelManager.statusMessage)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }

                                Spacer(minLength: 0)
                            }

                            if let installedURL = localModelManager.installedModelURL {
                                infoLine(label: "保存済み", value: installedURL.lastPathComponent)
                                infoLine(label: "サイズ", value: ByteCountFormatter.string(fromByteCount: localModelManager.installedFileSize, countStyle: .file))
                            } else {
                                infoLine(label: "配布元", value: localModelManager.sourceDisplayLabel)
                                infoLine(label: "ホスト", value: localModelManager.sourceHostLabel)
                            }

                            if let legacyInstalledModelURL = localModelManager.legacyInstalledModelURL {
                                infoLine(label: "旧モデル", value: legacyInstalledModelURL.lastPathComponent)
                            }

                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 10) {
                                    Button(localModelPrimaryActionTitle) {
                                        persistLocalAIDrafts()
                                        performLocalModelPrimaryAction()
                                    }
                                    .buttonStyle(.borderedProminent)

                                    if localModelManager.canRestartDownloadFromScratch && !localModelManager.isDownloading {
                                        Button("最初からやり直す") {
                                            persistLocalAIDrafts()
                                            localModelManager.restartDownloadFromScratch()
                                        }
                                        .buttonStyle(.bordered)
                                    }

                                    Button("詳細設定") {
                                        showLocalModelAdvancedSettings.toggle()
                                    }
                                    .buttonStyle(.bordered)
                                }

                                HStack(spacing: 10) {
                                    Button("現在のモデルを削除") {
                                        localModelManager.removeInstalledModel()
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(localModelManager.installedModelURL == nil && !localModelManager.isDownloading)

                                    if localModelManager.hasLegacyInstalledModel {
                                        Button("旧モデルを削除") {
                                            localModelManager.removeLegacyInstalledModel()
                                        }
                                        .buttonStyle(.bordered)
                                    }
                                }
                            }

                            let tint: Color = localModelManager.isDownloadStateFailure ? .red : (localModelManager.isDownloadStateWarning ? .orange : .green)
                            inlineNotice(text: localModelManager.downloadStateSummary, tint: tint)

                            if localModelManager.hasLegacyInstalledModel {
                                inlineNotice(text: "旧 Gemma 3n モデルが残っています。旧モデルを削除しても、現在の Gemma 4 には影響しません。", tint: .blue)
                            }

                            if let runtimeWarningMessage = localModelManager.runtimeWarningMessage {
                                inlineNotice(text: runtimeWarningMessage, tint: .orange)
                            }

                            if let lastErrorMessage = localModelManager.supplementalLastErrorMessage, !lastErrorMessage.isEmpty {
                                inlineNotice(text: lastErrorMessage, tint: .red)
                            }

                            if localModelManager.isDownloading, let progress = localModelManager.progressValue {
                                VStack(alignment: .leading, spacing: 6) {
                                    ProgressView(value: progress)
                                        .progressViewStyle(.linear)
                                    Text("受信: \(ByteCountFormatter.string(fromByteCount: localModelManager.downloadedBytes, countStyle: .file)) / \(localModelManager.expectedBytes > 0 ? ByteCountFormatter.string(fromByteCount: localModelManager.expectedBytes, countStyle: .file) : "不明")")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(.secondary)
                                    if let progressDetails = [localModelManager.estimatedRemainingSummary, localModelManager.transferRateSummary]
                                        .compactMap({ $0 })
                                        .joined(separator: " ・ ")
                                        .nilIfEmpty {
                                        Text(progressDetails)
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundColor(.secondary.opacity(0.9))
                                    }
                                }
                            }
                        }
                    }

                    settingsCard(title: "Gemma 3 270M 補助モデル", subtitle: "Deep Research の planner / auditor / architect 専用です。Gemma 4 とは別スロットで管理します。") {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: localSupportModelStatusIconName)
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundColor(localSupportModelStatusIconColor)
                                    .frame(width: 28)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(localSupportModelManager.statusTitle)
                                        .font(.system(size: 15, weight: .bold))
                                    Text(localSupportModelManager.statusMessage)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }

                                Spacer(minLength: 0)
                            }

                            if let installedURL = localSupportModelManager.installedModelURL {
                                infoLine(label: "保存済み", value: installedURL.lastPathComponent)
                                infoLine(label: "サイズ", value: ByteCountFormatter.string(fromByteCount: localSupportModelManager.installedFileSize, countStyle: .file))
                            } else {
                                infoLine(label: "配布元", value: localSupportModelManager.sourceDisplayLabel)
                                infoLine(label: "ホスト", value: localSupportModelManager.sourceHostLabel)
                            }

                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 10) {
                                    Button(localSupportModelPrimaryActionTitle) {
                                        persistLocalSupportModelDrafts()
                                        performLocalSupportModelPrimaryAction()
                                    }
                                    .buttonStyle(.borderedProminent)

                                    Button("詳細設定") {
                                        showLocalSupportModelAdvancedSettings.toggle()
                                    }
                                    .buttonStyle(.bordered)
                                }

                                HStack(spacing: 10) {
                                    Button("現在の補助モデルを削除") {
                                        localSupportModelManager.removeInstalledModel()
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(localSupportModelManager.installedModelURL == nil && !localSupportModelManager.isDownloading)
                                }
                            }

                            let tint: Color = localSupportModelManager.runtimeAvailability == .recentFailure ? .orange : .green
                            inlineNotice(text: localSupportModelManager.downloadStateSummary, tint: tint)

                            if localSupportModelManager.installedModelURL == nil && !localSupportModelManager.isDownloading {
                                inlineNotice(text: "Deep Research 開始時にも自動導入を試みます。すぐ使いたい場合はここで先にダウンロードできます。", tint: .orange)
                            }

                            if localSupportModelManager.runtimeAvailability == .recentFailure {
                                inlineNotice(text: localSupportModelManager.runtimeStatusSummary, tint: .orange)
                            }

                            if let lastErrorMessage = localSupportModelManager.lastErrorMessage, !lastErrorMessage.isEmpty {
                                inlineNotice(text: lastErrorMessage, tint: .red)
                            }

                            if localSupportModelManager.isDownloading, let progress = localSupportModelManager.progressValue {
                                VStack(alignment: .leading, spacing: 6) {
                                    ProgressView(value: progress)
                                        .progressViewStyle(.linear)
                                    Text("受信: \(ByteCountFormatter.string(fromByteCount: localSupportModelManager.downloadedBytes, countStyle: .file)) / \(localSupportModelManager.expectedBytes > 0 ? ByteCountFormatter.string(fromByteCount: localSupportModelManager.expectedBytes, countStyle: .file) : "不明")")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(.secondary)
                                    if let progressDetails = [localSupportModelManager.estimatedRemainingSummary, localSupportModelManager.transferRateSummary]
                                        .compactMap({ $0 })
                                        .joined(separator: " ・ ")
                                        .nilIfEmpty {
                                        Text(progressDetails)
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundColor(.secondary.opacity(0.9))
                                    }
                                }
                            }
                        }
                    }

                    if showLocalSupportModelAdvancedSettings {
                        settingsCard(title: "Gemma 3 補助モデル詳細", subtitle: "Gemma 4 と完全に別設定です。Deep Research 補助モデルだけを上書きしたい時に使います。") {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("モデルURL")
                                    .font(.system(size: 13, weight: .semibold))
                                TextField("https://.../gemma-3-270m-it-UD-Q4_K_XL.gguf", text: $localSupportModelURLDraft)
                                    .textFieldStyle(.roundedBorder)

                                Text("Bearer トークン（必要な場合のみ）")
                                    .font(.system(size: 13, weight: .semibold))
                                SecureField("hf_xxx", text: $localSupportModelTokenDraft)
                                    .textFieldStyle(.roundedBorder)

                                HStack(spacing: 10) {
                                    Button("設定を反映") {
                                        persistLocalSupportModelDrafts()
                                    }
                                    .buttonStyle(.borderedProminent)

                                    Button("標準リンクに戻す") {
                                        localSupportModelManager.resetSourceURLToDefault()
                                        localSupportModelURLDraft = localSupportModelManager.sourceURLString
                                    }
                                    .buttonStyle(.bordered)

                                    Button("入力を戻す") {
                                        localSupportModelURLDraft = localSupportModelManager.sourceURLString
                                        localSupportModelTokenDraft = localSupportModelManager.accessToken
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                    }

                    settingsCard(title: "Web Search", subtitle: "検索の利用有無だけを切り替えます。接続キーは一般ユーザー入力を前提にしていません。") {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle(
                                "オンライン時だけ Web Search を使う",
                                isOn: Binding(
                                    get: { webSearchService.isEnabled },
                                    set: { webSearchService.updateEnabled($0) }
                                )
                            )

                            infoLine(label: "接続", value: networkMonitor.statusSummary)

                            Text(webSearchService.statusSummary)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            if let lastSearchSummary = webSearchService.lastSearchSummary, !lastSearchSummary.isEmpty {
                                inlineNotice(text: lastSearchSummary, tint: .cyan)
                            }
                            inlineNotice(text: "高精度検索の接続情報は提供側設定で管理します。通常利用ではキー入力は不要です。", tint: .blue)
                        }
                    }

                    if showLocalModelAdvancedSettings {
                        settingsCard(title: "ローカルモデル詳細", subtitle: "標準リンクは初期設定済みです。別ソースへ切り替えたいときだけ編集します。") {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("モデルURL")
                                    .font(.system(size: 13, weight: .semibold))
                                TextField("https://.../gemma-4-e4b-4bit...", text: $localModelURLDraft)
                                    .textFieldStyle(.roundedBorder)

                                Text("Bearer トークン（必要な場合のみ）")
                                    .font(.system(size: 13, weight: .semibold))
                                SecureField("hf_xxx", text: $localModelTokenDraft)
                                    .textFieldStyle(.roundedBorder)

                                HStack(spacing: 10) {
                                    Button("設定を反映") {
                                        persistLocalAIDrafts()
                                    }
                                    .buttonStyle(.borderedProminent)

                                    Button("標準リンクに戻す") {
                                        localModelManager.resetSourceURLToDefault()
                                        localModelURLDraft = localModelManager.sourceURLString
                                    }
                                    .buttonStyle(.bordered)

                                    Button("入力を戻す") {
                                        localModelURLDraft = localModelManager.sourceURLString
                                        localModelTokenDraft = localModelManager.accessToken
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                    }

                    settingsCard(title: "実行ブリッジ", subtitle: "ローカル推論がどこまで有効かを表示します。") {
                        Text(localModelManager.runtimeStatusSummary)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(24)
            }
            .background(Color.appCanvasBackground.ignoresSafeArea())
            .navigationTitle("AIセットアップ")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") {
                        showLocalModelSheet = false
                    }
                }
            }
        }
    }

    private var localModelStatusLabel: String {
        if localModelManager.isDownloading {
            return "受信中"
        }
        return localModelManager.statusTitle
    }

    private var webSearchStatusLabel: String {
        guard webSearchService.isEnabled else {
            return "オフ"
        }
        return NetworkStatusMonitor.shared.isOnline ? "オンライン" : "待機中"
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
        if localModelManager.isDownloading {
            return .orange
        }
        if localModelManager.canResumeDownload {
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

    private func persistLocalAIDrafts() {
        localModelManager.updateSourceURL(localModelURLDraft)
        localModelManager.updateAccessToken(localModelTokenDraft)
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

    private func persistLocalSupportModelDrafts() {
        localSupportModelManager.updateSourceURL(localSupportModelURLDraft)
        localSupportModelManager.updateAccessToken(localSupportModelTokenDraft)
    }

    private var localModelPrimaryActionTitle: String {
        if localModelManager.isDownloading {
            return "アプリ内ダウンロード停止"
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
        return "アプリ内ダウンロード開始"
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

    private func performLocalSupportModelPrimaryAction() {
        if localSupportModelManager.isDownloading {
            localSupportModelManager.cancelDownload()
        } else if localSupportModelManager.installedModelURL != nil {
            localSupportModelManager.recheckRuntimeAvailability()
        } else {
            localSupportModelManager.startDownload()
        }
    }

    private func statusChip(title: String, value: String, tint: Color, isActive: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                if isActive {
                    AIActivityDotsView(tint: tint, dotSize: 4)
                        .frame(width: 22, height: 8)
                }
            }
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(tint.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(tint.opacity(0.18), lineWidth: 1)
        )
        .cornerRadius(12)
        .overlay(alignment: .topTrailing) {
            if isActive {
                AIPulseBadge(tint: tint)
                    .padding(8)
            }
        }
        .shadow(color: isActive ? tint.opacity(0.12) : .clear, radius: 8, y: 3)
        .scaleEffect(isActive ? 1.01 : 1)
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: isActive)
    }

    private func compactStatusPill(title: String, value: String, tint: Color, isActive: Bool = false) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.secondary)

            Text(value)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.primary)

            if isActive {
                AIActivityDotsView(tint: tint, dotSize: 4)
                    .frame(width: 20, height: 8)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(tint.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(tint.opacity(0.16), lineWidth: 1)
        )
        .cornerRadius(10)
    }

    private func settingsCard<Content: View>(title: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 18, weight: .bold))
                Text(subtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            content()
        }
        .padding(18)
        .viukSurfaceCard(cornerRadius: 18, fill: Color.appElevatedBackground.opacity(0.95), border: Color.appBorder.opacity(0.14), shadowOpacity: 0.02, shadowRadius: 10, shadowY: 4)
    }

    private func inlineNotice(text: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundColor(tint)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(tint.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(tint.opacity(0.16), lineWidth: 1)
        )
        .cornerRadius(12)
    }

    private func infoLine(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.secondary)
                .frame(width: 76, alignment: .leading)
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var coachBackdrop: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.appCanvasBackground,
                    Color.appSecondaryBackground.opacity(0.94)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(modeAccentColor.opacity(0.05))
                .frame(width: 280, height: 280)
                .blur(radius: 26)
                .offset(x: -160, y: -180)
        }
    }

    private func conversationPanel(availableWidth: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: isStudioMode ? 18 : 22, style: .continuous)
                .fill(isStudioMode ? Color.appCardBackground.opacity(0.72) : Color.appCardBackground.opacity(0.985))

            RoundedRectangle(cornerRadius: isStudioMode ? 18 : 22, style: .continuous)
                .stroke(Color.appBorder.opacity(isStudioMode ? 0.10 : 0.22), lineWidth: 1)

            Group {
                if aiCoach.messages.isEmpty {
                    emptyState
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(isStudioMode ? 18 : 28)
                } else {
                    ScrollView {
                        ScrollViewReader { proxy in
                            VStack(spacing: isStudioMode ? 8 : 10) {
                                ForEach(Array(aiCoach.messages.enumerated()), id: \.element.id) { index, message in
                                    MessageBubble(
                                        message: message,
                                        showResponseActions: shouldShowResponseActions(for: index),
                                        showsThoughtDetailsButton: message.role == .assistant && hasModelGeneratedThoughts(message.thoughtDetails),
                                        showsDebugDetailsButton: message.role == .assistant && message.thoughtDetails?.debugDetails != nil,
                                        maxBubbleWidth: messageMaxBubbleWidth(for: availableWidth),
                                        showsAvatars: !isStudioMode,
                                        onRegenerate: {
                                            regenerateResponse(after: index)
                                        },
                                        onSelectResponseAction: { action in
                                            aiCoach.sendResponseAction(action)
                                        },
                                        onShowThoughtDetails: {
                                            openThoughtDetails(for: message.thoughtDetails)
                                        },
                                        onShowDebugDetails: {
                                            openDebugDetails(for: message.thoughtDetails?.debugDetails)
                                        }
                                    )
                                }

                                if aiCoach.isLoading, let liveResponsePreviewText {
                                    LiveAssistantPreviewBubble(
                                        text: liveResponsePreviewText,
                                        maxBubbleWidth: messageMaxBubbleWidth(for: availableWidth),
                                        showsAvatars: !isStudioMode
                                    )
                                }

                                if aiCoach.isLoading {
                                    AILiveReasoningRow(
                                        title: "応答を作成しています",
                                        subtitle: aiCoach.thoughtTimeline.last?.title ?? "必要な情報を整理しています",
                                        tint: activeThoughtStepColor ?? modeAccentColor,
                                        summaryItems: Array(displayedThoughtSummaryItems.prefix(isStudioMode ? 1 : 3)),
                                        rawThoughtItems: Array(rawThoughtItems.prefix(isStudioMode ? 1 : 2)),
                                        stageSections: isStudioMode ? [] : Array(thoughtStageSections.prefix(4)),
                                        liveThoughtText: aiCoach.liveThoughtPreview.nilIfEmpty
                                    )
                                }

                                Color.clear
                                    .frame(height: 1)
                                    .id("live-bottom")
                            }
                            .padding(.horizontal, isStudioMode ? 10 : 20)
                            .padding(.vertical, isStudioMode ? 10 : 18)
                            .animation(.spring(response: 0.36, dampingFraction: 0.82), value: aiCoach.messages.count)
                            .onChange(of: aiCoach.messages.count) { _, _ in
                                if let lastMessage = aiCoach.messages.last {
                                    withAnimation(.easeOut(duration: 0.2)) {
                                        proxy.scrollTo(lastMessage.id, anchor: .bottom)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(StudioConversationSurfaceModifier(isStudioMode: isStudioMode))
    }

    private func composerBar(availableWidth: CGFloat) -> some View {
        Group {
            if isCompactAICanvas(width: availableWidth) {
                VStack(spacing: 8) {
                    TextField(inputPlaceholder, text: $userInput, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...5)
                        .focused($composerFocused)
                        .submitLabel(.send)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(Color.appCardBackground.opacity(0.96))
                        .overlay(
                            RoundedRectangle(cornerRadius: 15)
                                .stroke(Color.appBorder.opacity(0.22), lineWidth: 1)
                        )
                        .cornerRadius(15)
                        .onSubmit {
                            sendMessage()
                        }
                        .dropDestination(for: URL.self) { droppedURLs, _ in
                            handleDroppedImageURLs(droppedURLs)
                        }

                    HStack(alignment: .center, spacing: 10) {
                        attachmentPickerButton
                        thoughtButton
                        Spacer(minLength: 0)
                        sendButton
                    }
                }
            } else {
                HStack(alignment: .bottom, spacing: 8) {
                    attachmentPickerButton
                    thoughtButton

                    TextField(inputPlaceholder, text: $userInput, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...4)
                        .focused($composerFocused)
                        .submitLabel(.send)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(Color.appCardBackground.opacity(0.96))
                        .overlay(
                            RoundedRectangle(cornerRadius: 15)
                                .stroke(Color.appBorder.opacity(0.22), lineWidth: 1)
                        )
                        .cornerRadius(15)
                        .onSubmit {
                            sendMessage()
                        }
                        .dropDestination(for: URL.self) { droppedURLs, _ in
                            handleDroppedImageURLs(droppedURLs)
                        }

                    sendButton
                }
            }
        }
        .padding(.horizontal, isStudioMode ? 4 : 8)
        .padding(.vertical, isStudioMode ? 4 : 8)
        .modifier(StudioComposerSurfaceModifier(isStudioMode: isStudioMode))
    }

    private var quickActionStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(aiCoach.quickActions) { action in
                    Button {
                        aiCoach.sendQuickAction(action)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: action.icon)
                                .font(.system(size: 12, weight: .bold))
                            Text(action.title)
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundColor(.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color.appCardBackground.opacity(0.96))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(Color.appBorder.opacity(0.35), lineWidth: 1)
                        )
                        .cornerRadius(14)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private var composerAttachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Array(selectedImageData.enumerated()), id: \.offset) { index, data in
                    ZStack(alignment: .topTrailing) {
                        platformRenderedImage(from: data)
                            .frame(width: 84, height: 84)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                        Button {
                            selectedImageData.remove(at: index)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.white)
                                .background(Circle().fill(Color.black.opacity(0.7)))
                        }
                        .buttonStyle(.plain)
                        .padding(4)
                    }
                }
            }
        }
    }

    private var liveResponsePreviewText: String? {
        aiCoach.liveResponsePreview.nilIfEmpty
    }

    private func coachControlPanel(availableWidth: CGFloat) -> some View {
        if coachMode == .studio {
            return AnyView(studioConversationHeader(availableWidth: availableWidth))
        }

        return AnyView(standardControlPanel)
    }

    private var currentStudioThreadSummary: AICoachService.ChatThreadSummary? {
        aiCoach.chatThreads.first(where: { $0.id == aiCoach.currentThreadID })
    }

    private var currentStudioThreadTitle: String {
        currentStudioThreadSummary?.title.nilIfEmpty ?? "新しいチャット"
    }

    private var currentStudioThreadSubtitle: String {
        if aiCoach.messages.isEmpty {
            return "ここから会話を始められます"
        }
        guard let updatedAt = currentStudioThreadSummary?.updatedAt else {
            return "会話に集中できる表示にしています"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return "更新 \(formatter.localizedString(for: updatedAt, relativeTo: Date()))"
    }

    private var canOpenStudioDetails: Bool {
        aiCoach.isLoading || latestAssistantThoughtDetails != nil
    }

    private func studioConversationHeader(availableWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if isCompactAICanvas(width: availableWidth) {
                VStack(alignment: .leading, spacing: 10) {
                    studioHeaderTitleBlock
                    HStack(spacing: 8) {
                        studioModeControl(availableWidth: availableWidth)
                        studioOptionsMenu
                        Spacer(minLength: 0)
                        studioDetailsButton
                        studioSettingsButton
                        if showsStudioThreadMenu {
                            threadMenu
                        }
                    }
                }
            } else {
                HStack(alignment: .center, spacing: 12) {
                    studioHeaderTitleBlock
                    Spacer(minLength: 16)
                    studioModeControl(availableWidth: availableWidth)
                    studioOptionsMenu
                    studioDetailsButton
                    studioSettingsButton
                    if showsStudioThreadMenu {
                        threadMenu
                    }
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, usesMinimalStudioChrome ? 4 : 6)
        .overlay(alignment: .bottom) {
            Divider()
                .opacity(0.45)
                .padding(.top, 4)
        }
    }

    private var studioHeaderTitleBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(currentStudioThreadTitle)
                .font(.system(size: usesMinimalStudioChrome ? 17 : 20, weight: .bold))
                .foregroundColor(.primary)
                .lineLimit(1)
            Text(currentStudioThreadSubtitle)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func studioModeControl(availableWidth: CGFloat) -> some View {
        if isCompactAICanvas(width: availableWidth) {
            studioModeMenu
        } else {
            studioModePicker
                .frame(width: min(320, max(240, availableWidth * 0.24)))
        }
    }

    private var studioOptionsMenu: some View {
        Menu {
            if aiCoach.reasoningMode == .fast {
                Picker("リサーチ", selection: researchModeBinding) {
                    ForEach(fastSelectableResearchModes) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
            } else {
                Text("検索は必要時に自動")
            }

            if aiCoach.reasoningMode == .thinking {
                Divider()
                Picker("Thinking 詳細度", selection: thinkingLevelBinding) {
                    ForEach(ThinkingLevel.allCases) { level in
                        Text(level.displayName).tag(level)
                    }
                }
            }
        } label: {
            Label("設定", systemImage: "slider.horizontal.3")
                .font(.system(size: 11, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.appSecondaryBackground.opacity(0.86))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.appBorder.opacity(0.18), lineWidth: 1)
        )
        .cornerRadius(10)
    }

    private var studioDetailsButton: some View {
        Button {
            openThoughtDetails(for: latestAssistantThoughtDetails, live: aiCoach.isLoading)
        } label: {
            Label("詳細", systemImage: "rectangle.righthand.inset.filled")
                .font(.system(size: 11, weight: .semibold))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.appSecondaryBackground.opacity(0.86))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.appBorder.opacity(0.18), lineWidth: 1)
        )
        .cornerRadius(10)
        .disabled(!canOpenStudioDetails)
        .opacity(canOpenStudioDetails ? 1 : 0.55)
    }

    private var studioSettingsButton: some View {
        Button {
            onOpenStudioSettings?()
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .background(Color.appSecondaryBackground.opacity(0.86))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.appBorder.opacity(0.18), lineWidth: 1)
        )
        .cornerRadius(10)
        .disabled(onOpenStudioSettings == nil)
        .opacity(onOpenStudioSettings == nil ? 0.55 : 1)
    }

    private func compactStudioControlPanel(availableWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if isCompactAICanvas(width: availableWidth) {
                VStack(alignment: .leading, spacing: 8) {
                    studioModePicker
                        .frame(maxWidth: .infinity)

                    HStack(spacing: 8) {
                        studioSecondaryPicker
                        Spacer(minLength: 0)
                    }

                    HStack(spacing: 8) {
                        studioThoughtToggleButton
                        studioThoughtDetailButton
                        Spacer(minLength: 0)
                    }
                }
            } else if availableWidth < 1080 {
                studioControlWrappedRows
            } else {
                studioControlInlineRow
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .background(Color.clear)
        .overlay(alignment: .bottom) {
            Divider()
                .opacity(0.55)
                .padding(.top, 6)
        }
    }

    private var minimalStudioControlPanel: some View {
        HStack(spacing: 8) {
            studioModeMenu

            if aiCoach.reasoningMode == .thinking {
                studioThinkingLevelMenu
            }

            if aiCoach.reasoningMode == .fast {
                studioResearchMenu
            }

            studioThoughtToggleButton

            if aiCoach.showThoughtTimeline || aiCoach.isLoading || hasVisibleThoughtDetails {
                studioThoughtDetailButton
            }

            Spacer(minLength: 0)

            if showsStudioThreadMenu {
                threadMenu
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) {
            Divider()
                .opacity(0.45)
                .padding(.top, 4)
        }
    }

    private var studioControlInlineRow: some View {
        HStack(alignment: .center, spacing: 10) {
            studioModePicker
            studioSecondaryPicker
            Spacer(minLength: 0)
            studioThoughtToggleButton
            studioThoughtDetailButton
            if showsStudioThreadMenu {
                threadMenu
            }
        }
    }

    private var studioControlWrappedRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                studioModePicker
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                studioSecondaryPicker
                Spacer(minLength: 0)
                studioThoughtToggleButton
                studioThoughtDetailButton
            }

            if showsStudioThreadMenu {
                HStack {
                    Spacer(minLength: 0)
                    threadMenu
                }
            }
        }
    }

    private var studioModePicker: some View {
        Picker("推論モード", selection: reasoningModeBinding) {
            ForEach(ReasoningMode.allCases) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 320)
    }

    private var studioModeMenu: some View {
        Menu {
            Picker("推論モード", selection: reasoningModeBinding) {
                ForEach(ReasoningMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
        } label: {
            Label(aiCoach.executionConfig.displayName, systemImage: aiCoach.reasoningMode.iconName)
                .font(.system(size: 11, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(modeAccentColor.opacity(0.10))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(modeAccentColor.opacity(0.16), lineWidth: 1)
        )
        .cornerRadius(10)
    }

    private var studioResearchMenu: some View {
        Menu {
            Picker("リサーチ", selection: researchModeBinding) {
                ForEach(fastSelectableResearchModes) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
        } label: {
            Label(aiCoach.executionConfig.researchMode?.displayName ?? ResearchMode.on.displayName, systemImage: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.appSecondaryBackground.opacity(0.86))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.appBorder.opacity(0.18), lineWidth: 1)
        )
        .cornerRadius(10)
    }

    private var studioThinkingLevelMenu: some View {
        Menu {
            Picker("Thinking 詳細度", selection: thinkingLevelBinding) {
                ForEach(ThinkingLevel.allCases) { level in
                    Text(level.displayName).tag(level)
                }
            }
        } label: {
            Label(aiCoach.thinkingLevel.displayName, systemImage: "dial.medium")
                .font(.system(size: 11, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.appSecondaryBackground.opacity(0.86))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.appBorder.opacity(0.18), lineWidth: 1)
        )
        .cornerRadius(10)
    }

    private var studioResearchPicker: some View {
        Picker("リサーチ", selection: researchModeBinding) {
            ForEach(fastSelectableResearchModes) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .frame(minWidth: 188, maxWidth: 260)
    }

    @ViewBuilder
    private var studioSecondaryPicker: some View {
        if aiCoach.reasoningMode == .fast {
            studioResearchPicker
        } else if aiCoach.reasoningMode == .thinking {
            HStack(spacing: 8) {
                Picker("Thinking 詳細度", selection: thinkingLevelBinding) {
                    ForEach(ThinkingLevel.allCases) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                .pickerStyle(.segmented)
                .frame(minWidth: 164, maxWidth: 196)
            }
        } else if aiCoach.reasoningMode == .deepThinking {
            EmptyView()
        }
    }

    @ViewBuilder
    private var studioThoughtToggleButton: some View {
        if supportsModelThoughtUI {
            Button {
                aiCoach.setThoughtTimelineVisible(!aiCoach.showThoughtTimeline)
            } label: {
                Label(
                    aiCoach.showThoughtTimeline ? "表示中" : "非表示",
                    systemImage: aiCoach.showThoughtTimeline ? "waveform.path.ecg" : "waveform.path"
                )
                .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.appSecondaryBackground.opacity(0.86))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.appBorder.opacity(0.18), lineWidth: 1)
            )
            .cornerRadius(10)
        }
    }

    @ViewBuilder
    private var studioThoughtDetailButton: some View {
        if supportsModelThoughtUI && aiCoach.isLoading && aiCoach.showThoughtTimeline {
            Button {
                openThoughtDetails(for: nil)
            } label: {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .frame(width: 32, height: 32)
            .background(Color.appSecondaryBackground.opacity(0.86))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.appBorder.opacity(0.18), lineWidth: 1)
            )
            .cornerRadius(10)
        }
    }

    private var standardControlPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Label(coachHeaderLabelText, systemImage: coachHeaderIconName)
                        .font(.system(size: 14, weight: .bold))
                    Text(coachHeaderDescription)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                }
                Spacer()
                HStack(spacing: 8) {
                    Button {
                        systemPromptDraft = aiCoach.customSystemPrompt
                        showSystemPromptSheet = true
                    } label: {
                        Label("指示", systemImage: "slider.horizontal.3")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    threadMenu
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("推論モード")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)
                Picker("推論モード", selection: reasoningModeBinding) {
                    ForEach(ReasoningMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("リサーチ")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)
                if aiCoach.reasoningMode == .fast {
                    Picker("リサーチ", selection: researchModeBinding) {
                        ForEach(fastSelectableResearchModes) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                } else {
                    Label("必要時に自動検索", systemImage: "magnifyingglass.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }

            if aiCoach.reasoningMode == .thinking {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Thinking 詳細度")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.secondary)
                    Picker("Thinking 詳細度", selection: thinkingLevelBinding) {
                        ForEach(ThinkingLevel.allCases) { level in
                            Text(level.displayName).tag(level)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }

            if supportsModelThoughtUI {
                Toggle("考え方を表示", isOn: thoughtTimelineVisibleBinding)
                    .font(.system(size: 12, weight: .medium))
            }

            if isGuardianMode {
                HStack(spacing: 8) {
                    Button(showMemoryEditor ? "メモを閉じる" : "メモ") {
                        showMemoryEditor.toggle()
                        memoryDraft = aiCoach.memoryNote
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if showMemoryEditor && isGuardianMode {
                VStack(alignment: .leading, spacing: 8) {
                    Text("保護者メモ")
                        .font(.system(size: 12, weight: .semibold))
                    TextEditor(text: $memoryDraft)
                        .frame(minHeight: 72, maxHeight: 110)
                        .padding(6)
                        .background(Color.appSoftFill)
                        .cornerRadius(10)

                    HStack {
                        Button("保存") {
                            aiCoach.updateMemoryNote(memoryDraft.trimmingCharacters(in: .whitespacesAndNewlines))
                        }
                        .buttonStyle(.borderedProminent)

                        Button("クリア") {
                            memoryDraft = ""
                            aiCoach.updateMemoryNote("")
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .viukSurfaceCard(
            cornerRadius: 14,
            fill: Color.appElevatedBackground.opacity(0.95),
            border: isGuardianMode ? Color.green.opacity(0.14) : (isStudioMode ? Color.indigo.opacity(0.14) : Color.blue.opacity(0.14)),
            shadowOpacity: 0.018,
            shadowRadius: 8,
            shadowY: 4
        )
    }

    private var approvalPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let memoryProposal = aiCoach.pendingMemoryProposal, !memoryProposal.isEmpty {
                proposalCard(
                    title: "メモリー保存の提案",
                    subtitle: "AIが会話の継続に必要だと判断しました。まだ保存されていません。",
                    detail: memoryProposal,
                    tint: .orange,
                    icon: "tray.and.arrow.down.fill",
                    approveTitle: "保存",
                    rejectTitle: "却下",
                    onApprove: { aiCoach.approvePendingMemoryProposal() },
                    onReject: { aiCoach.rejectPendingMemoryProposal() }
                )
            }

            if aiCoach.pendingSettingsProposal != nil {
                proposalCard(
                    title: "設定変更の提案",
                    subtitle: "AIが設定変更を提案しています。承認するまで反映されません。",
                    detail: aiCoach.pendingSettingsProposalSummary,
                    tint: .green,
                    icon: "checkmark.shield.fill",
                    approveTitle: "適用",
                    rejectTitle: "却下",
                    onApprove: { aiCoach.approvePendingSettingsProposal() },
                    onReject: { aiCoach.rejectPendingSettingsProposal() }
                )
            }
        }
    }

    private func proposalCard(
        title: String,
        subtitle: String,
        detail: String,
        tint: Color,
        icon: String,
        approveTitle: String,
        rejectTitle: String,
        onApprove: @escaping () -> Void,
        onReject: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(tint)
                Text(title)
                    .font(.system(size: 12, weight: .bold))
                Spacer()
                Text("承認待ち")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(tint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(tint.opacity(0.12))
                    .cornerRadius(999)
            }

            Text(subtitle)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(detail.isEmpty ? "内容がありません" : detail)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.appSecondaryBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(tint.opacity(0.12), lineWidth: 1)
                )
                .cornerRadius(10)

            HStack(spacing: 8) {
                Button(approveTitle, action: onApprove)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button(rejectTitle, action: onReject)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(tint.opacity(0.18), lineWidth: 1)
        )
        .cornerRadius(14)
    }

    private var threadMenu: some View {
        Menu {
            Button {
                aiCoach.createNewChatThread()
            } label: {
                Label("新しいチャット", systemImage: "plus.bubble")
            }

            Button {
                showMemoryManager = true
            } label: {
                Label("メモリー管理", systemImage: "tray.full")
            }

            if !aiCoach.chatThreads.isEmpty {
                Divider()
                ForEach(aiCoach.chatThreads) { thread in
                    Button {
                        aiCoach.switchToChatThread(thread.id)
                    } label: {
                        HStack {
                            Text(thread.title)
                            if thread.id == aiCoach.currentThreadID {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "bubble.left.and.bubble.right")
                Text(currentThreadTitle)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
            }
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.appSecondaryBackground.opacity(0.86))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.appBorder.opacity(0.18), lineWidth: 1)
            )
            .cornerRadius(10)
        }
    }

    private var contextDigestStrip: some View {
        HStack(spacing: 10) {
            digestPill(title: "検索", value: "\(aiCoach.contextDigest.searchCount)")
            digestPill(title: "閲覧", value: "\(aiCoach.contextDigest.browsingCount)")
            digestPill(title: "ブロック", value: "\(aiCoach.contextDigest.blockCount)")
            digestPill(title: "個人情報", value: "\(aiCoach.contextDigest.personalInfoCount)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func coachSummaryCard(snapshot: AICoachService.SafetySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("現在のページ診断", systemImage: "checkmark.shield")
                    .font(.system(size: 14, weight: .bold))
                Spacer()
                Text(snapshot.level)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(snapshot.level == "要注意" ? .red : (snapshot.level == "注意" ? .orange : .green))
            }

            Text(snapshot.summary)
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            if let firstAction = snapshot.recommendations.first {
                Text("まずは: \(firstAction)")
                    .font(.system(size: 12, weight: .semibold))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.08))
        .cornerRadius(14)
    }

    private var highlightsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("いま見ている要点", systemImage: "sparkles.rectangle.stack")
                .font(.system(size: 13, weight: .bold))

            ForEach(aiCoach.contextHighlights, id: \.self) { highlight in
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(Color.orange.opacity(0.8))
                        .frame(width: 6, height: 6)
                        .padding(.top, 5)
                    Text(highlight)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08))
        .cornerRadius(14)
    }

    private var latestAssistantThoughtDetails: AICoachService.ResponseThoughtDetails? {
        aiCoach.messages.reversed().first { $0.role == .assistant && $0.thoughtDetails != nil }?.thoughtDetails
    }

    private var liveThoughtDetails: AICoachService.ResponseThoughtDetails? {
        let supportModels = aiCoach.supportModelCalls.map(\.displayName)
        let hasContent =
            !aiCoach.thoughtSummaries.isEmpty ||
            !aiCoach.detailedThoughtSummaries.isEmpty ||
            !aiCoach.thoughtTimeline.isEmpty ||
            aiCoach.lastThinkingDuration != nil ||
            aiCoach.searchCallCount > 0 ||
            aiCoach.toolUsageCount > 0 ||
            !supportModels.isEmpty

        guard hasContent else { return nil }

        return AICoachService.ResponseThoughtDetails(
            executionDisplayName: aiCoach.executionConfig.displayName,
            activeModelDisplayName: aiCoach.activeModelDisplayName,
            usedRemoteThoughtSummaries: aiCoach.usedRemoteThoughtSummaries,
            responseDuration: nil,
            thoughtSummaries: aiCoach.thoughtSummaries,
            detailedThoughtSummaries: aiCoach.detailedThoughtSummaries,
            rawThoughtSummaries: aiCoach.rawThoughtSummaries,
            rawThoughtStream: aiCoach.rawThoughtSummaries.joined(separator: "\n\n"),
            displayThoughtSegments: aiCoach.detailedThoughtSummaries.isEmpty ? aiCoach.thoughtSummaries : aiCoach.detailedThoughtSummaries,
            thoughtTimeline: aiCoach.thoughtTimeline,
            thinkingDuration: aiCoach.lastThinkingDuration,
            searchCallCount: aiCoach.searchCallCount,
            toolUsageCount: aiCoach.toolUsageCount,
            supportModelDisplayNames: supportModels,
            toolActivity: liveToolActivityNotes(),
            searchActivity: liveSearchActivityNotes(),
            processingLogSummary: liveProcessingLogNotes(),
            createdAt: Date(),
            debugDetails: nil
        )
    }

    private func liveSearchActivityNotes() -> [String] {
        stableUniqueThoughtLines(
            aiCoach.thoughtTimeline
                .filter { $0.type == .search }
                .map(thoughtStepDisplayLine)
        )
    }

    private func liveToolActivityNotes() -> [String] {
        stableUniqueThoughtLines(
            aiCoach.thoughtTimeline
                .filter { $0.type == .tool || $0.type == .supportModel || $0.type == .imageAnalysis }
                .map(thoughtStepDisplayLine)
        )
    }

    private func liveProcessingLogNotes() -> [String] {
        stableUniqueThoughtLines(
            aiCoach.thoughtTimeline
                .filter { $0.type == .planning || $0.type == .synthesis || $0.type == .finalization }
                .map(thoughtStepDisplayLine)
        )
    }

    private func thoughtStepDisplayLine(_ step: ThoughtStep) -> String {
        let title = step.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = step.detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if title.isEmpty { return detail }
        if detail.isEmpty { return title }
        return "\(title): \(detail)"
    }

    private func stableUniqueThoughtLines(_ items: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for item in items {
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    private var displayedThoughtDetails: AICoachService.ResponseThoughtDetails? {
        if isViewingLiveThoughtDetails {
            if aiCoach.isLoading {
                return liveThoughtDetails ?? selectedThoughtDetails
            }
            return latestAssistantThoughtDetails ?? selectedThoughtDetails
        }
        if let selectedThoughtDetails {
            return selectedThoughtDetails
        }
        if aiCoach.isLoading {
            return liveThoughtDetails
        }
        return latestAssistantThoughtDetails ?? liveThoughtDetails
    }

    private func openThoughtDetails(for details: AICoachService.ResponseThoughtDetails?, live: Bool = false) {
        isViewingLiveThoughtDetails = live
        selectedThoughtDetails = live ? nil : details
        showThoughtFlowSection = false
        showRawThoughtSection = false
        showExecutionLogSection = false
        showThoughtDetailsInline = true
    }

    private func openDebugDetails(for details: AICoachService.ResponseDebugDetails?) {
        selectedDebugDetails = details
        showDebugDetailsSheet = true
    }

    private var thoughtDetailsInlinePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 仕様9.3: ヘッダーは「思考 + 経過時間 + 1行要約」
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("思考")
                            .font(.system(size: 18, weight: .bold))
                        if let durationText = thinkingDurationText {
                            Text(durationText)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.secondary)
                        }
                    }
                    if let summaryLine = thoughtOneSummaryLine {
                        Text(summaryLine)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    } else if aiCoach.isLoading {
                        Text("考えています…")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()

                Button {
                    showThoughtDetailsInline = false
                    showThoughtFlowSection = false
                    showRawThoughtSection = false
                    showExecutionLogSection = false
                    selectedThoughtDetails = nil
                    isViewingLiveThoughtDetails = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Color.appSecondaryBackground.opacity(0.9))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }

            ScrollView(showsIndicators: false) {
                thoughtDetailsContent
            }
            .frame(maxHeight: isStudioMode ? 280 : 340)
        }
        .padding(14)
        .background(Color.appElevatedBackground.opacity(0.98))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.appBorder.opacity(0.12), lineWidth: 1)
        )
        .cornerRadius(16)
        .shadow(color: Color.black.opacity(0.04), radius: 10, y: 4)
    }

    @ViewBuilder
    private var thoughtDetailsContent: some View {
        // ── 仕様9.1: 思考 = モデル reasoning + 検索で確かめたことの要約 ──
        let reasoningItems = thoughtPrimaryReasoningItems
        let searchNotes = displayedThoughtDetails?.searchActivity ?? []
        let hasThinkingContent = !reasoningItems.isEmpty || !searchNotes.isEmpty

        if hasThinkingContent {
            // 仕様9.3: 初期状態は折りたたみ、展開時は reasoning と検索要約のみ
            DisclosureGroup(isExpanded: $showRawThoughtSection) {
                VStack(alignment: .leading, spacing: 10) {
                    if !reasoningItems.isEmpty {
                        ForEach(Array(reasoningItems.enumerated()), id: \.offset) { _, item in
                            thoughtTextRow(item, tint: modeAccentColor, usesMonospace: false, subdued: false)
                        }
                    }
                    if !searchNotes.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("検索で確かめたこと")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.secondary)
                                .padding(.top, 4)
                            ForEach(Array(searchNotes.enumerated()), id: \.offset) { _, note in
                                thoughtTextRow(note, tint: .teal, usesMonospace: false, subdued: true)
                            }
                        }
                    }
                }
                .padding(.top, 8)
            } label: {
                Label("思考", systemImage: "brain.head.profile")
                    .font(.system(size: 13, weight: .bold))
            }
            .padding(14)
            .background(Color.appSoftFill)
            .cornerRadius(14)
        }

        // ── 仕様9.2: 実行ログ = toolActivity + processingLogSummary + 内部処理記録 ──
        // 仕様9.3: 実行ログは別欄で、思考より目立たせない
        let executionItems = thoughtExecutionLogItems
        let timelineSteps = displayedThoughtDetails?.thoughtTimeline ?? aiCoach.thoughtTimeline
        let hasLogContent = !executionItems.isEmpty || (!timelineSteps.isEmpty && aiCoach.showThoughtTimeline)

        if hasLogContent {
            DisclosureGroup(isExpanded: $showExecutionLogSection) {
                VStack(alignment: .leading, spacing: 8) {
                    if !executionItems.isEmpty {
                        ForEach(Array(executionItems.enumerated()), id: \.offset) { _, item in
                            Text(item)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.appSoftFill)
                                .cornerRadius(8)
                        }
                    }
                    if aiCoach.showThoughtTimeline && !timelineSteps.isEmpty {
                        ForEach(timelineSteps) { step in
                            thoughtTimelineRow(step)
                        }
                    }
                }
                .padding(.top, 8)
            } label: {
                Label("実行ログ", systemImage: "list.bullet.rectangle.portrait")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .padding(14)
            .background(Color.appSoftFill.opacity(0.5))
            .cornerRadius(14)
        }
    }

    private var thoughtCircuitFlowSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 10) {
                ForEach(Array(thoughtStageSections.enumerated()), id: \.element.id) { index, section in
                    thoughtCircuitRow(
                        number: index + 1,
                        section: section,
                        isActive: isThoughtSectionActive(section)
                    )
                }
            }
        }
        .padding(14)
        .background(Color.appSoftFill)
        .cornerRadius(14)
    }

    @ViewBuilder
    private var aiUsageCard: some View {
        if let details = displayedThoughtDetails?.debugDetails {
            let externalQueries = Array(NSOrderedSet(array: details.externalSearchQueries)) as? [String] ?? details.externalSearchQueries
            let conversationQueries = Array(NSOrderedSet(array: details.conversationSearchQueries)) as? [String] ?? details.conversationSearchQueries
            let latencyLines = responseLatencyLines(from: details)
            let supportLines = supportAgentLines(from: details)

            VStack(alignment: .leading, spacing: 12) {
                Label("AIの使用", systemImage: "sparkles.rectangle.stack")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.secondary)

                if !latencyLines.isEmpty {
                    aiUsageRow(
                        title: "待ち時間",
                        lines: latencyLines,
                        systemName: "stopwatch"
                    )
                }

                if !externalQueries.isEmpty {
                    aiUsageRow(
                        title: "外部検索",
                        lines: externalQueries,
                        systemName: "magnifyingglass"
                    )
                }

                if !conversationQueries.isEmpty {
                    aiUsageRow(
                        title: "会話検索",
                        lines: conversationQueries,
                        systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90"
                    )
                }

                if !supportLines.isEmpty {
                    aiUsageRow(
                        title: "補助エージェント",
                        lines: supportLines,
                        systemName: "sparkles"
                    )
                }

                if !details.toolSummaries.isEmpty {
                    aiUsageRow(
                        title: "ツール",
                        lines: details.toolSummaries,
                        systemName: "hammer"
                    )
                }
            }
            .padding(14)
            .background(Color.appSoftFill)
            .cornerRadius(14)
        }
    }

    private var debugDetailsSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("AIの使用")
                        .font(.system(size: 24, weight: .bold))

                    if let details = selectedDebugDetails {
                        debugSummaryCard(details)

                        let latencyLines = responseLatencyLines(from: details)
                        if !latencyLines.isEmpty {
                            debugSection("待ち時間", lines: latencyLines)
                        }

                        if !details.conversationSearchQueries.isEmpty {
                            debugSection("会話検索クエリ", lines: details.conversationSearchQueries)
                        }

                        if !details.searchQueries.isEmpty {
                            debugSection("検索クエリ", lines: details.searchQueries)
                        }

                        if !details.externalSearchQueries.isEmpty {
                            debugSection("外部検索クエリ", lines: details.externalSearchQueries)
                        }

                        if !details.toolSummaries.isEmpty {
                            debugSection("ツール", lines: details.toolSummaries)
                        }

                        if !details.toolDetails.isEmpty {
                            debugSection("ツール詳細", lines: details.toolDetails)
                        }

                        if !details.gemmaWebReaderSummaries.isEmpty {
                            debugSection("Gemma 4 26B Web読解", lines: details.gemmaWebReaderSummaries)
                        }

                        let supportLines = supportAgentLines(from: details)
                        if !supportLines.isEmpty {
                            debugSection("Gemma 3 270M 補助モデル", lines: supportLines)
                        }

                        if !details.retryEventNotes.isEmpty {
                            debugSection("再試行", lines: details.retryEventNotes)
                        }

                        if !details.supplementalNotes.isEmpty {
                            debugSection("補足ログ", lines: details.supplementalNotes)
                        }

                        if let rawJSONCandidate = details.rawJSONCandidate, !rawJSONCandidate.isEmpty {
                            debugMonospaceSection("JSON候補", text: rawJSONCandidate)
                        }

                        if let rawResponsePreview = details.rawResponsePreview, !rawResponsePreview.isEmpty {
                            debugMonospaceSection("生レスポンス抜粋", text: rawResponsePreview)
                        }
                    } else {
                        Text("この返答では、まだ表示できる AI の使用情報がありません。")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(20)
            }
            .navigationTitle("AIの使用")
        }
    }

    private func aiUsageRow(title: String, lines: [String], systemName: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemName)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.secondary)

            ForEach(Array(lines.prefix(4).enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.appElevatedBackground.opacity(0.8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.appBorder.opacity(0.10), lineWidth: 1)
                    )
                    .cornerRadius(10)
            }
        }
    }

    private func debugSummaryCard(_ details: AICoachService.ResponseDebugDetails) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            debugSummaryRow(title: "応答元", value: details.responseSource)
            if let responseStatusCode = details.responseStatusCode {
                debugSummaryRow(title: "HTTP", value: "\(responseStatusCode)")
            }
            if let latency = formattedLatencyValue(details.placeholderPreviewLatency) {
                debugSummaryRow(title: "Thinking表示", value: latency)
            }
            if let latency = formattedLatencyValue(details.firstThoughtLatency) {
                debugSummaryRow(title: "実Thinking", value: latency)
            }
            if let latency = formattedLatencyValue(details.firstVisibleLatency) {
                debugSummaryRow(title: "本文初表示", value: latency)
            }
            if let latency = formattedLatencyValue(details.visibleAfterThoughtLatency) {
                debugSummaryRow(title: "Thinking→本文", value: latency)
            }
            if let latency = formattedLatencyValue(details.responseDuration) {
                debugSummaryRow(title: "応答完了", value: latency)
            }
            if details.receivedThoughtChunks > 0 {
                debugSummaryRow(title: "考え方 chunk", value: "\(details.receivedThoughtChunks)")
            }
            if details.receivedVisibleChunks > 0 {
                debugSummaryRow(title: "回答 chunk", value: "\(details.receivedVisibleChunks)")
            }
            if let directiveParseStatus = details.directiveParseStatus {
                debugSummaryRow(title: "パース", value: directiveParseStatus)
            }
            if let searchRationale = details.searchRationale {
                debugSummaryRow(title: "検索理由", value: searchRationale)
            }
            if details.conversationSearchHitCount > 0 {
                debugSummaryRow(title: "会話検索ヒット", value: "\(details.conversationSearchHitCount)件")
            }
            if details.externalSearchRoundCount > 0 {
                debugSummaryRow(
                    title: "外部検索",
                    value: "\(details.externalSearchRoundCount)ラウンド / \(details.externalSearchQueries.count)クエリ"
                )
            }
            if !details.supportAgentExecutions.isEmpty {
                let succeeded = details.supportAgentExecutions.filter { !$0.degraded }.count
                let total = details.supportAgentExecutions.count
                let label = details.supportAgentsDegraded ? "\(succeeded)/\(total) 成功" : "\(total) 役"
                debugSummaryRow(title: "補助エージェント", value: label)
            }
            if let degradationReason = details.supportAgentsDegradationReason, !degradationReason.isEmpty {
                debugSummaryRow(title: "縮退理由", value: degradationReason)
            }
            if !details.externalSearchRoundReasons.isEmpty {
                debugSummaryRow(title: "外部検索の狙い", value: details.externalSearchRoundReasons.joined(separator: " / "))
            }
            if !details.gemmaWebReaderSummaries.isEmpty {
                debugSummaryRow(title: "Gemma 4 26B Web読解", value: "\(details.gemmaWebReaderSummaries.count)件")
            }
        }
        .padding(14)
        .background(Color.appSoftFill)
        .cornerRadius(14)
    }

    private func debugSummaryRow(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func responseLatencyLines(from details: AICoachService.ResponseDebugDetails) -> [String] {
        var lines: [String] = []

        if let latency = formattedLatencyValue(details.placeholderPreviewLatency) {
            lines.append("送信→Thinking表示: \(latency)")
        }
        if let latency = formattedLatencyValue(details.firstThoughtLatency) {
            lines.append("送信→実Thinking: \(latency)")
        }
        if let latency = formattedLatencyValue(details.firstVisibleLatency) {
            lines.append("送信→本文初表示: \(latency)")
        }
        if let latency = formattedLatencyValue(details.visibleAfterThoughtLatency) {
            lines.append("Thinking→本文初表示: \(latency)")
        }
        if let latency = formattedLatencyValue(details.responseDuration) {
            lines.append("送信→応答完了: \(latency)")
        }

        return lines
    }

    private func supportAgentLines(from details: AICoachService.ResponseDebugDetails) -> [String] {
        if !details.supportAgentExecutions.isEmpty {
            return details.supportAgentExecutions.map { item in
                let role = item.role ?? "support"
                let duration: String
                if let value = formattedLatencyValue(item.duration) {
                    duration = value
                } else {
                    duration = "-"
                }

                var base = "\(role) / \(item.modelDisplayName) / \(duration)"
                if item.degraded {
                    if let failureReason = item.failureReason, !failureReason.isEmpty {
                        base += "\n縮退: \(failureReason)"
                    } else {
                        base += "\n縮退"
                    }
                } else if let outputPreview = item.outputPreview, !outputPreview.isEmpty {
                    base += "\n\(outputPreview)"
                }
                return base
            }
        }

        return details.supportExecutions
    }

    private func formattedLatencyValue(_ duration: TimeInterval?) -> String? {
        guard let duration, duration.isFinite, duration >= 0 else { return nil }
        if duration < 1 {
            return String(format: "%.2f秒", duration)
        }
        if duration < 10 {
            return String(format: "%.1f秒", duration)
        }
        return "\(Int(duration.rounded()))秒"
    }

    private func debugSection(_ title: String, lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 14, weight: .bold))
            ForEach(lines, id: \.self) { line in
                Text(line)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.appSoftFill)
                    .cornerRadius(12)
            }
        }
    }

    private func debugMonospaceSection(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 14, weight: .bold))
            Text(text)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(12)
                .background(Color.appSoftFill)
                .cornerRadius(12)
        }
    }

    private var displayedThoughtSummaryItems: [String] {
        guard supportsModelThoughtUI else { return [] }
        if !rawThoughtItems.isEmpty {
            return rawThoughtItems
        }
        if let displayedThoughtDetails, !displayedThoughtDetails.detailedThoughtSummaries.isEmpty {
            return displayedThoughtDetails.detailedThoughtSummaries
        }
        if let displayedThoughtDetails, !displayedThoughtDetails.displayThoughtSegments.isEmpty {
            return displayedThoughtDetails.displayThoughtSegments
        }
        if let displayedThoughtDetails, !displayedThoughtDetails.thoughtSummaries.isEmpty {
            return displayedThoughtDetails.thoughtSummaries
        }
        return []
    }

    private var primaryThoughtItems: [String] {
        Array(displayedThoughtSummaryItems.prefix(1))
    }

    private var additionalThoughtItems: [String] {
        Array(displayedThoughtSummaryItems.dropFirst())
    }

    private var rawThoughtItems: [String] {
        guard supportsModelThoughtUI else { return [] }
        if let displayedThoughtDetails, !displayedThoughtDetails.rawThoughtStream.isEmpty {
            return Array(
                displayedThoughtDetails.rawThoughtStream
                    .components(separatedBy: "\n\n")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .prefix(6)
            )
        }
        if let displayedThoughtDetails, !displayedThoughtDetails.rawThoughtSummaries.isEmpty {
            return Array(displayedThoughtDetails.rawThoughtSummaries.prefix(6))
        }
        return Array(aiCoach.rawThoughtSummaries.prefix(6))
    }

    private var condensedThoughtItems: [String] {
        var items: [String] = []

        for section in thoughtStageSections {
            for item in section.items.prefix(1) {
                let text = item.detail?.isEmpty == false ? item.detail! : item.title
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty && !items.contains(trimmed) {
                    items.append(trimmed)
                }
            }
        }

        if items.isEmpty {
            items = additionalThoughtItems.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }

        return items
    }

    // 仕様9章: 思考 = モデル reasoning + 検索で確かめたことの要約
    private var thoughtPrimaryReasoningItems: [String] {
        guard supportsModelThoughtUI else { return [] }
        if let details = displayedThoughtDetails {
            if !details.displayThoughtSegments.isEmpty {
                return Array(details.displayThoughtSegments.prefix(4))
            }
            if !details.detailedThoughtSummaries.isEmpty {
                return Array(details.detailedThoughtSummaries.prefix(4))
            }
            if !details.thoughtSummaries.isEmpty {
                return Array(details.thoughtSummaries.prefix(4))
            }
        }
        if !aiCoach.detailedThoughtSummaries.isEmpty {
            return Array(aiCoach.detailedThoughtSummaries.prefix(4))
        }
        return Array(aiCoach.thoughtSummaries.prefix(4))
    }

    // 仕様9章: 実行ログ = toolActivity + processingLogSummary + 内部処理記録
    private var thoughtExecutionLogItems: [String] {
        guard supportsModelThoughtUI else { return [] }
        let tool = displayedThoughtDetails?.toolActivity ?? []
        let proc = displayedThoughtDetails?.processingLogSummary ?? []
        var merged: [String] = []
        var seen = Set<String>()
        for item in (tool + proc) {
            let t = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, seen.insert(t).inserted else { continue }
            merged.append(t)
        }
        return Array(merged.prefix(8))
    }

    // 完了後ヘッダー用の1行要約
    private var thoughtOneSummaryLine: String? {
        let reasoning = thoughtPrimaryReasoningItems
        if let first = reasoning.first?.trimmingCharacters(in: .whitespacesAndNewlines), !first.isEmpty {
            return first
        }
        let searchNotes = displayedThoughtDetails?.searchActivity ?? []
        if let note = searchNotes.first?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            return note
        }
        return nil
    }

    private var thoughtStageSections: [ThoughtDisplaySection] {
        guard supportsModelThoughtUI else { return [] }
        let steps = displayedThoughtDetails?.thoughtTimeline ?? aiCoach.thoughtTimeline
        let orderedStages: [(id: String, title: String, symbolName: String, tint: Color)] = [
            ("problem", "問題を整理", "brain.head.profile", .blue),
            ("search", "外部情報を確認", "magnifyingglass", .teal),
            ("tool", "補助で確かめる", "sparkles.rectangle.stack.fill", .orange),
            ("additional", "追加で考える", "plus.bubble.fill", .indigo),
            ("final", "答えをまとめる", "checkmark.circle.fill", .pink)
        ]

        return orderedStages.compactMap { stage in
            let stageSteps = steps.filter { thoughtStageIdentifier(for: $0) == stage.id }
            var items = compressedThoughtItems(from: stageSteps)

            if stage.id == "additional" {
                items.append(contentsOf: additionalThoughtItems.enumerated().map { index, item in
                    ThoughtDisplayItem(
                        id: "additional-summary-\(index)",
                        title: "追加メモ \(index + 1)",
                        detail: item,
                        count: 1
                    )
                })
            }

            guard !items.isEmpty else { return nil }
            return ThoughtDisplaySection(
                id: stage.id,
                title: stage.title,
                symbolName: stage.symbolName,
                tint: stage.tint,
                items: items
            )
        }
    }


    private func thoughtStageIdentifier(for step: ThoughtStep) -> String {
        switch step.type {
        case .planning, .imageAnalysis:
            return "problem"
        case .search:
            return "search"
        case .tool, .supportModel:
            return "tool"
        case .synthesis, .finalization:
            return "final"
        }
    }

    private func isThoughtSectionActive(_ section: ThoughtDisplaySection) -> Bool {
        guard aiCoach.isLoading, let activeType = activeThoughtStepType else { return false }
        return thoughtStageIdentifier(for: ThoughtStep(title: "", detail: nil, type: activeType)) == section.id
    }

    private func compressedThoughtItems(from steps: [ThoughtStep]) -> [ThoughtDisplayItem] {
        guard !steps.isEmpty else { return [] }

        var grouped: [(title: String, details: [String], count: Int)] = []
        for step in steps {
            let detail = step.detail?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let lastIndex = grouped.indices.last, grouped[lastIndex].title == step.title {
                grouped[lastIndex].count += 1
                if let detail, !detail.isEmpty, !grouped[lastIndex].details.contains(detail) {
                    grouped[lastIndex].details.append(detail)
                }
            } else {
                grouped.append((
                    title: step.title,
                    details: detail.map { [$0] } ?? [],
                    count: 1
                ))
            }
        }

        return grouped.enumerated().map { index, item in
            ThoughtDisplayItem(
                id: "thought-item-\(index)-\(item.title)",
                title: item.title,
                detail: compactThoughtDetail(title: item.title, details: item.details, count: item.count),
                count: item.count
            )
        }
    }

    private func compactThoughtDetail(title: String, details: [String], count: Int) -> String? {
        let nonEmptyDetails = details.filter { !$0.isEmpty }

        if title.contains("補助モデル") {
            let modelNames = Array(NSOrderedSet(array: nonEmptyDetails)) as? [String] ?? nonEmptyDetails
            if !modelNames.isEmpty {
                return "使った補助: " + modelNames.joined(separator: "、")
            }
        }

        if title.contains("応答モデルを選定") {
            if count > 1 {
                return "候補を比べながら \(count) 回見直しました。"
            }
            return nonEmptyDetails.first
        }

        if count > 1, let first = nonEmptyDetails.first {
            return "\(first)\nほか \(count - 1) 回の更新"
        }

        return nonEmptyDetails.first
    }

    private func thoughtCircuitRow(
        number: Int,
        section: ThoughtDisplaySection,
        isActive: Bool
    ) -> some View {
        let previews = Array(section.items.prefix(isActive ? 2 : 1))

        return HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill((isActive ? section.tint : Color.appSecondaryBackground).opacity(isActive ? 0.18 : 0.95))
                    .frame(width: 28, height: 28)
                if isActive {
                    AIPulseBadge(tint: section.tint)
                }
                Text("\(number)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(isActive ? section.tint : .secondary)
            }
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Image(systemName: section.symbolName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(section.tint)
                    Text(section.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                    if section.items.count > 1 {
                        Text("\(section.items.count)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.appSecondaryBackground.opacity(0.9))
                            .cornerRadius(999)
                    }
                    if isActive {
                        Text("LIVE")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(section.tint)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(section.tint.opacity(0.12))
                            .cornerRadius(999)
                    }
                }

                ForEach(previews) { item in
                    let previewText = item.previewText
                    if !previewText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(previewText)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .lineLimit(isActive ? nil : 3)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((isActive ? section.tint : Color.appElevatedBackground).opacity(isActive ? 0.10 : 0.72))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke((isActive ? section.tint : Color.appBorder).opacity(isActive ? 0.22 : 0.10), lineWidth: 1)
        )
        .cornerRadius(12)
    }

    private func thoughtTextRow(
        _ text: String,
        tint: Color,
        usesMonospace: Bool,
        subdued: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(tint.opacity(subdued ? 0.55 : 0.85))
                .frame(width: 6, height: 6)
                .padding(.top, 6)
            Text(text)
                .font(usesMonospace ? .system(.body, design: .monospaced) : .system(size: 13))
                .foregroundColor(subdued ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.appSoftFill)
        .cornerRadius(12)
    }

    private var thinkingDurationText: String? {
        if !supportsModelThoughtUI {
            return nil
        }
        guard let duration = displayedThoughtDetails?.thinkingDuration ?? aiCoach.lastThinkingDuration else { return nil }
        let rounded = Int(duration.rounded(.up))
        return "\(max(1, rounded))s"
    }

    private var supportsModelThoughtUI: Bool {
        aiCoach.reasoningMode != .fast
    }

    private var modeAccentColor: Color {
        switch aiCoach.reasoningMode {
        case .fast, .persona:
            return .blue
        case .thinking:
            return .orange
        case .deepThinking:
            return .pink
        }
    }

    private func timelineMetric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 16, weight: .bold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.appSecondaryBackground)
        .cornerRadius(10)
    }

    private func thoughtTimelineRow(_ step: ThoughtStep) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName(for: step.type))
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(color(for: step.type))
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(step.title)
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(step.timestamp.formatted(date: .omitted, time: .standard))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                }

                if let detail = step.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .background(Color.appSoftFill)
        .cornerRadius(12)
    }

    private func iconName(for type: ThoughtStepType) -> String {
        switch type {
        case .planning: return "list.bullet.rectangle.portrait"
        case .search: return "magnifyingglass"
        case .tool: return "wrench.and.screwdriver.fill"
        case .imageAnalysis: return "photo"
        case .supportModel: return "cpu"
        case .synthesis: return "square.stack.3d.up.fill"
        case .finalization: return "checkmark.circle.fill"
        }
    }

    private func color(for type: ThoughtStepType) -> Color {
        switch type {
        case .planning: return .blue
        case .search: return .teal
        case .tool: return .indigo
        case .imageAnalysis: return .purple
        case .supportModel: return .orange
        case .synthesis: return .pink
        case .finalization: return .green
        }
    }

    private var currentThreadTitle: String {
        aiCoach.chatThreads.first(where: { $0.id == aiCoach.currentThreadID })?.title ?? "チャット"
    }

    private var analysisPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            DisclosureGroup(isExpanded: $showAnalysisDetails) {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(aiCoach.visibleAnalysisNotes, id: \.self) { note in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "arrowtriangle.right.fill")
                                    .font(.system(size: 8))
                                    .foregroundColor(.purple)
                                    .padding(.top, 4)
                                Text(note)
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .frame(maxHeight: 120)
            } label: {
                HStack {
                    Label("AIの見方", systemImage: "brain")
                        .font(.system(size: 13, weight: .bold))
                    Spacer()
                    Text(showAnalysisDetails ? "閉じる" : "開く")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.purple)
                }
            }

            if !aiCoach.lastAppliedSettingChanges.isEmpty {
                Text("直近で変更した設定: " + aiCoach.lastAppliedSettingChanges.joined(separator: " / "))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.green)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.purple.opacity(0.08))
        .cornerRadius(14)
    }

    private var guardianReasoningPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("処理メモ", systemImage: "cpu")
                    .font(.system(size: 13, weight: .bold))
                Spacer()
                Text("詳細")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
            }

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(aiCoach.guardianReasoningTrace, id: \.self) { item in
                        HStack(alignment: .top, spacing: 8) {
                            Text(">")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundColor(.secondary)
                            Text(item)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .frame(maxHeight: 150)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.appSoftFill)
        .cornerRadius(14)
    }

    private var hasVisibleThoughtDetails: Bool {
        latestAssistantThoughtDetails != nil ||
        !aiCoach.thoughtSummaries.isEmpty ||
        !aiCoach.detailedThoughtSummaries.isEmpty ||
        !aiCoach.thoughtTimeline.isEmpty
    }

    private func hasModelGeneratedThoughts(_ details: AICoachService.ResponseThoughtDetails?) -> Bool {
        guard let details else { return false }
        return !details.displayThoughtSegments.isEmpty ||
            !details.rawThoughtStream.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !(details.detailedThoughtSummaries.isEmpty && details.thoughtSummaries.isEmpty)
    }

    private var shouldShowGuardianTrace: Bool {
        isGuardianMode && hasVisibleThoughtDetails && !aiCoach.guardianReasoningTrace.isEmpty
    }

    private func shouldShowResponseActions(for index: Int) -> Bool {
        guard index < aiCoach.messages.count else { return false }
        let message = aiCoach.messages[index]
        guard message.role == .assistant else { return false }
        if let actions = message.responseActions, !actions.isEmpty {
            return true
        }
        return index == aiCoach.messages.lastIndex(where: { $0.role == .assistant })
    }

    private func regenerateResponse(after index: Int) {
        guard index < aiCoach.messages.count else { return }
        let messages = Array(aiCoach.messages.prefix(index + 1))
        guard let latestUserMessage = messages.last(where: { $0.role == .user }) else { return }
        aiCoach.send(prompt: latestUserMessage.content)
    }

    private func digestPill(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 12, weight: .bold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.gray.opacity(0.08))
        .cornerRadius(12)
    }

    private var emptyState: some View {
        Group {
            if isStudioMode {
                VStack {
                    Spacer(minLength: 0)
                    VStack(spacing: 28) {
                        AIEmptyStateHeroView(
                            title: "何をお手伝いしましょう？",
                            subtitle: ""
                        )

                        AIStarterPromptGrid(
                            quickActions: Array(aiCoach.quickActions.prefix(4)),
                            onSelectQuickAction: { action in
                                aiCoach.sendQuickAction(action)
                            },
                            onSelectPrompt: { prompt in
                                userInput = prompt
                            }
                        )
                    }
                    .frame(maxWidth: 680)
                    .padding(.horizontal, 20)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: coachHeaderIconName)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundColor(modeAccentColor)
                        .frame(width: 52, height: 52)
                        .background(modeAccentColor.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                    VStack(spacing: 6) {
                        Text(coachHeaderLabelText)
                            .font(.system(size: 22, weight: .bold))

                        Text(
                            isGuardianMode
                                ? "相談、設定確認、履歴の読み解きをここから始められます。"
                                : "質問や要約、安全確認をここで進められます。"
                        )
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 440)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var inputPlaceholder: String {
        let base: String
        switch coachMode {
        case .guardian:
            base = "設定の相談や変更指示を入力"
        case .studio:
            base = "メッセージを入力"
        case .child:
            base = "質問や調べたいことを入力"
        }
        return isStudioMode ? base : "\(base) (\(aiCoach.executionConfig.displayName))"
    }

    private var systemPromptSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("AIへの追加指示")
                    .font(.system(size: 24, weight: .bold))
                Text("このモード専用の振る舞いを追加できます。元の Science Club と同じく、口調や役割の指定に使えます。")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)

                TextEditor(text: $systemPromptDraft)
                    .frame(minHeight: 220)
                    .padding(8)
                    .background(Color.appSecondaryBackground.opacity(0.9))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                Text("例: 中学生にもわかる言葉で、図や手順を重視して説明してください。")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)

                Spacer()
            }
            .padding(20)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") {
                        systemPromptDraft = aiCoach.customSystemPrompt
                        showSystemPromptSheet = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        aiCoach.updateCustomSystemPrompt(systemPromptDraft)
                        showSystemPromptSheet = false
                    }
                }
            }
        }
    }

    @MainActor
    private func loadSelectedImages(from items: [PhotosPickerItem]) async {
        selectedImageData.removeAll()

        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            if let normalized = normalizedJPEGData(from: data) {
                selectedImageData.append(normalized)
            }
        }
    }

    private func normalizedJPEGData(from data: Data) -> Data? {
        #if os(macOS)
        guard let image = NSImage(data: data) else { return nil }
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return data
        }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) ?? data
        #elseif canImport(UIKit)
        guard let image = UIImage(data: data) else { return nil }
        return image.jpegData(compressionQuality: 0.82) ?? data
        #else
        return data
        #endif
    }

    private func sendMessage() {
        let extracted = extractInlineImageAttachments(from: userInput)
        let attachments = selectedImageData + extracted.attachments
        let message = extracted.cleanedMessage.nilIfEmpty ?? (attachments.isEmpty ? "" : "この画像を見てください。")
        guard !message.isEmpty || !attachments.isEmpty else { return }

        composerFocused = false
        dismissAICoachKeyboard()
        userInput = ""
        selectedImageData.removeAll()
        selectedPhotos.removeAll()
        aiCoach.send(prompt: message, attachedImages: attachments)
    }

    @discardableResult
    private func handleDroppedImageURLs(_ urls: [URL]) -> Bool {
        var appended = false
        for url in urls {
            guard let data = localImageAttachmentData(from: url) else { continue }
            selectedImageData.append(data)
            appended = true
        }
        return appended
    }

    private func extractInlineImageAttachments(from rawInput: String) -> (cleanedMessage: String, attachments: [Data]) {
        var attachments: [Data] = []
        var keptLines: [String] = []

        for rawLine in rawInput.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if let data = localImageAttachmentData(from: trimmed) {
                attachments.append(data)
            } else {
                keptLines.append(rawLine)
            }
        }

        let cleanedMessage = keptLines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return (cleanedMessage, attachments)
    }

    private func localImageAttachmentData(from rawValue: String) -> Data? {
        let normalized = rawValue
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'<>"))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty else { return nil }

        let expandedPath = NSString(string: normalized).expandingTildeInPath
        let url = expandedPath.hasPrefix("/")
            ? URL(fileURLWithPath: expandedPath)
            : URL(string: normalized)?.isFileURL == true ? URL(string: normalized)! : nil

        guard let fileURL = url else { return nil }
        return localImageAttachmentData(from: fileURL)
    }

    private func localImageAttachmentData(from url: URL) -> Data? {
        guard url.isFileURL else { return nil }
        let supportedExtensions = Set(["jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "tif", "tiff", "bmp"])
        let ext = url.pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return normalizedJPEGData(from: data)
    }

    private var memoryManagerSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("メモリー管理")
                        .font(.system(size: 24, weight: .bold))
                    Spacer()
                    if !aiCoach.savedConversationMemories.isEmpty {
                        Button("すべて削除") {
                            aiCoach.clearConversationMemories()
                        }
                    }
                }

                if aiCoach.savedConversationMemories.isEmpty {
                    Text("保存されたメモリーはまだありません。")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                    Text("必要だと判断したときだけ、AIが会話内容をメモリーとして保管します。")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                } else {
                    List {
                        ForEach(Array(aiCoach.savedConversationMemories.enumerated()), id: \.offset) { index, memory in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(memory)
                                    .font(.system(size: 13))
                                Text("メモリー \(index + 1)")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                        .onDelete { offsets in
                            aiCoach.removeConversationMemory(at: offsets)
                        }
                    }
                }

                Text("検索・メモリー保管・設定変更は、必要に応じてAIが内部で実行します。")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .padding(20)
        }
    }

    private func transientStatusBanner(message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
            Text(message)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.primary)
            Spacer()
            Button {
                aiCoach.dismissTransientStatus()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                    .frame(width: 20, height: 20)
                    .background(Color.appSoftFill)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .viukSurfaceCard(cornerRadius: 14, fill: Color.appElevatedBackground.opacity(0.94), border: Color.green.opacity(0.12), shadowOpacity: 0.015, shadowRadius: 8, shadowY: 4)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var attachmentPickerButton: some View {
        PhotosPicker(
            selection: $selectedPhotos,
            maxSelectionCount: 5,
            matching: .images
        ) {
            Image(systemName: "photo.on.rectangle")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.blue)
                .frame(width: 42, height: 42)
                .background(Color.blue.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.blue.opacity(0.14), lineWidth: 1)
                )
                .cornerRadius(14)
        }
        .buttonStyle(.plain)
        .help("画像を添付します")
        .onChange(of: selectedPhotos) { _, newItems in
            Task {
                await loadSelectedImages(from: newItems)
            }
        }
    }

    private var thoughtButton: some View {
        Button {
            openThoughtDetails(for: latestAssistantThoughtDetails, live: aiCoach.isLoading)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: aiCoach.reasoningMode.iconName)
                    .font(.system(size: 12, weight: .semibold))
                if !isStudioMode {
                    Text("思考")
                        .font(.system(size: 12, weight: .bold))
                }
            }
            .foregroundColor(modeAccentColor)
            .padding(.horizontal, isStudioMode ? 0 : 12)
            .frame(width: isStudioMode ? 42 : nil, height: 42)
            .background(modeAccentColor.opacity(0.08))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(modeAccentColor.opacity(0.14), lineWidth: 1)
            )
            .cornerRadius(14)
        }
        .buttonStyle(.plain)
        .help("思考タイムラインを開きます")
    }

    private var sendButton: some View {
        Button {
            if aiCoach.isLoading {
                composerFocused = false
                dismissAICoachKeyboard()
                aiCoach.cancelCurrentGeneration()
            } else {
                sendMessage()
            }
        } label: {
            AISendButtonVisual(
                isEnabled: aiCoach.isLoading || !userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                isBusy: aiCoach.isLoading
            )
        }
        .buttonStyle(.plain)
        .disabled(!aiCoach.isLoading && userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .opacity(!aiCoach.isLoading && userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
    }

    private func topContentPadding(for availableWidth: CGFloat) -> CGFloat {
        if isStudioMode {
            if usesMinimalStudioChrome {
                #if os(macOS)
                return 10
                #else
                return 8
                #endif
            }
            #if os(macOS)
            return availableWidth < 720 ? 18 : 24
            #else
            return 12
            #endif
        }
        return 12
    }

    private func isCompactAICanvas(width: CGFloat) -> Bool {
        #if os(iOS)
        if horizontalSizeClass == .compact {
            return true
        }
        #endif
        return width < 760
    }

    private func messageMaxBubbleWidth(for availableWidth: CGFloat) -> CGFloat {
        let visualWidth = max(availableWidth - 72, 240)
        let ratio: CGFloat = isCompactAICanvas(width: availableWidth) ? 0.92 : (isStudioMode ? 0.54 : 0.72)
        return min(isStudioMode ? 680 : 620, visualWidth * ratio)
    }

    private func emptyStatePrompt(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.appSoftFill)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.appBorder.opacity(0.14), lineWidth: 1)
            )
            .cornerRadius(12)
    }

}

private struct AIEmptyStateHeroView: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.blue, Color.purple.opacity(0.9)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Text(title)
                .font(.system(size: 30, weight: .bold))
                .multilineTextAlignment(.center)

            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
        .padding(.bottom, 8)
    }
}

private struct AIRecentThreadsCard: View {
    let threads: [AICoachService.ChatThreadSummary]
    let currentThreadID: String
    let onSelectThread: (String) -> Void
    let onCreateNew: () -> Void

    var body: some View {
        AIStudioHomeCard(title: "最近のスレッド", subtitle: "前の続きを開く") {
            VStack(alignment: .leading, spacing: 8) {
                if threads.isEmpty {
                    Text("まだ会話はありません。")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                } else {
                    ForEach(threads) { thread in
                        Button {
                            onSelectThread(thread.id)
                        } label: {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(thread.id == currentThreadID ? Color.blue : Color.appBorder.opacity(0.28))
                                    .frame(width: 8, height: 8)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(thread.title)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(.primary)
                                        .lineLimit(1)
                                    Text(thread.updatedAt, style: .relative)
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundColor(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 9)
                            .background(Color.appSoftFill)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(Color.appBorder.opacity(0.12), lineWidth: 1)
                            )
                            .cornerRadius(12)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Button("新しいチャットを作る", action: onCreateNew)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, 2)
            }
        }
    }
}

private struct AIStarterPromptGrid: View {
    let quickActions: [AICoachService.QuickAction]
    let onSelectQuickAction: (AICoachService.QuickAction) -> Void
    let onSelectPrompt: (String) -> Void

    private let defaultPrompts: [(icon: String, title: String, subtitle: String)] = [
        ("lightbulb", "アイデアを出す", "ブレインストーミングを手伝って"),
        ("text.alignleft", "文章を整える", "メールや文書を読みやすく"),
        ("chevron.left.forwardslash.chevron.right", "コードを書く", "関数やスニペットを作る"),
        ("doc.text.magnifyingglass", "要点をまとめる", "長い情報を短く整理")
    ]

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            if quickActions.isEmpty {
                ForEach(defaultPrompts, id: \.title) { item in
                    starterButton(icon: item.icon, title: item.title, subtitle: item.subtitle) {
                        onSelectPrompt("\(item.title): \(item.subtitle)")
                    }
                }
            } else {
                ForEach(quickActions) { action in
                    starterButton(icon: action.icon, title: action.title, subtitle: nil) {
                        onSelectQuickAction(action)
                    }
                }
            }
        }
    }

    private func starterButton(icon: String, title: String, subtitle: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.blue)
                    .frame(width: 20, height: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                        .multilineTextAlignment(.leading)

                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.appSoftFill.opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.appBorder.opacity(0.18), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct AIModelStatusCard: View {
    let modeName: String
    let localStatus: String
    let webStatus: String

    var body: some View {
        AIStudioHomeCard(title: "現在の AI 状態", subtitle: "必要な時だけ詳細を開けます") {
            VStack(alignment: .leading, spacing: 10) {
                statusRow(title: "モード", value: modeName)
                statusRow(title: "ローカル", value: localStatus)
                statusRow(title: "Web Search", value: webStatus)
            }
        }
    }

    private func statusRow(title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.secondary)
            Spacer(minLength: 0)
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.primary)
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct AIStudioHomeCard<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .bold))
                Text(subtitle)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(.secondary)
            }

            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.appElevatedBackground.opacity(0.9))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.appBorder.opacity(0.12), lineWidth: 1)
        )
        .cornerRadius(18)
    }
}

private struct StudioConversationSurfaceModifier: ViewModifier {
    let isStudioMode: Bool

    func body(content: Content) -> some View {
        if isStudioMode {
            content
        } else {
            content.viukSurfaceCard(
                cornerRadius: 22,
                fill: Color.appElevatedBackground.opacity(0.94),
                border: Color.appBorder.opacity(0.10),
                shadowOpacity: 0.01,
                shadowRadius: 6,
                shadowY: 2
            )
        }
    }
}

private struct StudioComposerSurfaceModifier: ViewModifier {
    let isStudioMode: Bool

    func body(content: Content) -> some View {
        if isStudioMode {
            content
                .background(Color.clear)
        } else {
            content.viukSurfaceCard(
                cornerRadius: 18,
                fill: Color.appElevatedBackground.opacity(0.97),
                border: Color.appBorder.opacity(0.10),
                shadowOpacity: 0.01,
                shadowRadius: 6,
                shadowY: 2
            )
        }
    }
}

// ✅ MessageBubble を AICoachView.swift 内に定義
struct MessageBubble: View {
    let message: AICoachService.ChatMessage
    let showResponseActions: Bool
    let showsThoughtDetailsButton: Bool
    let showsDebugDetailsButton: Bool
    let maxBubbleWidth: CGFloat
    let showsAvatars: Bool
    let onRegenerate: (() -> Void)?
    let onSelectResponseAction: ((AICoachService.ResponseAction) -> Void)?
    let onShowThoughtDetails: (() -> Void)?
    let onShowDebugDetails: (() -> Void)?
    @State private var feedbackSelection: FeedbackSelection?
    @State private var copyFeedback: Bool = false
    @State private var isInlineThinkingExpanded: Bool = false
    private let directiveParser = ModelDirectiveParser()

    private enum FeedbackSelection {
        case up
        case down
    }

    private var compactStudioStyle: Bool {
        !showsAvatars
    }
    
    var body: some View {
        HStack(alignment: .bottom, spacing: showsAvatars ? 10 : 0) {
            if message.role == .assistant, showsAvatars {
                bubbleAvatar(systemName: "sparkles", tint: .blue)
            } else if showsAvatars {
                Spacer(minLength: 28)
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: compactStudioStyle ? 3 : 4) {
                if message.role == .assistant, let thinkingText = inlineThinkingText {
                    inlineThinkingBlock(thinkingText)
                }

                VStack(alignment: message.role == .user ? .trailing : .leading, spacing: compactStudioStyle ? 4 : 6) {
                    messageText
                        .padding(.horizontal, message.role == .user ? 14 : (compactStudioStyle ? 0 : 14))
                        .padding(.vertical, message.role == .user ? 10 : (compactStudioStyle ? 2 : 11))
                        .background(bubbleBackground)
                        .foregroundColor(.primary)
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(message.role == .assistant && !compactStudioStyle ? Color.appBorder.opacity(0.18) : Color.clear, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        // 右クリック (macOS) / 長押し (iOS) でコピー。assistant メッセージは
                        // 全件で使えるようバブル自体に付け、最後の応答以外でもコピー可能にする。
                        .contextMenu {
                            if !copyableContent.isEmpty {
                                Button {
                                    copyAssistantContent()
                                } label: {
                                    Label("回答をコピー", systemImage: "doc.on.doc")
                                }
                            }
                        }

                    if let attachedImagesData = message.attachedImagesData, !attachedImagesData.isEmpty {
                        attachedImageStrip(attachedImagesData)
                    }
                }

                Text(timeString(from: message.timestamp))
                    .font(.system(size: compactStudioStyle ? 9 : 10, weight: .medium))
                    .foregroundColor(.secondary)

                if message.role == .assistant, shouldShowAssistantMetaRow {
                    assistantMetaRow
                }

                if showResponseActions && message.role == .assistant {
                    responseActionRow
                }
            }
            .frame(maxWidth: maxBubbleWidth, alignment: message.role == .user ? .trailing : .leading)

            if message.role == .user, showsAvatars {
                bubbleAvatar(systemName: "person.fill", tint: .indigo)
            } else if showsAvatars {
                Spacer()
            }
        }
        .id(message.id)
    }
    
    private func timeString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }


    // @ViewBuilder 内に let を入れるとコンパイラが混乱するケースを避けるため
    // 前処理は processedDisplayContent に切り出す
    @ViewBuilder
    private var messageText: some View {
        let fontSize: CGFloat = compactStudioStyle ? 15 : 14
        let lineSpacing: CGFloat = compactStudioStyle ? 3 : 2
        if message.role == .assistant,
           let attributed = assistantAttributedMessageText(fontSize: fontSize) {
            Text(attributed)
                .lineSpacing(lineSpacing)
                .textSelection(.enabled)
        } else {
            Text(message.role == .assistant ? processedDisplayContent : displayContent)
                .font(.system(size: fontSize, weight: .regular))
                .lineSpacing(lineSpacing)
                .textSelection(.enabled)
        }
    }

    private func assistantAttributedMessageText(fontSize: CGFloat) -> AttributedString? {
        guard var attributed = try? AttributedString(
            markdown: processedDisplayContent,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) else {
            return nil
        }

        // AttributedString に Font を明示的に設定し、markdown パースで乗る presentation intent が
        // Text の .font() を上書きするケースを防ぐ。ストリーミング側と完全に同一の font にする。
        attributed.font = .system(size: fontSize, weight: .regular)
        return attributed
    }

    private var processedDisplayContent: String {
        preprocessMarkdownForDisplay(displayContent)
    }

    /// Swift の AttributedString は markdown リスト記号 (* -) を未対応。
    /// 表示前に • に変換し、見出し・インライン装飾（**bold** など）は保持する。
    private func preprocessMarkdownForDisplay(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var result: [String] = []
        var orderedCounters: [Int: Int] = [:]  // indent depth → current counter

        for line in lines {
            // leading whitespace を保持
            var idx = line.startIndex
            while idx < line.endIndex, line[idx] == " " || line[idx] == "\t" {
                idx = line.index(after: idx)
            }
            let indent = String(line[..<idx])
            let rest   = String(line[idx...])
            let depth  = indent.count

            // 見出し: # ## ### → ** で囲んでインライン太字として扱う
            if rest.hasPrefix("### ") {
                result.append(indent + "**" + rest.dropFirst(4) + "**")
                continue
            }
            if rest.hasPrefix("## ") {
                result.append(indent + "**" + rest.dropFirst(3) + "**")
                continue
            }
            if rest.hasPrefix("# ") {
                result.append(indent + "**" + rest.dropFirst(2) + "**")
                continue
            }

            // 番号付きリスト: "1. " "2. " など
            var numberEnd = rest.startIndex
            while numberEnd < rest.endIndex, rest[numberEnd].isNumber {
                numberEnd = rest.index(after: numberEnd)
            }
            if numberEnd > rest.startIndex,
               rest[numberEnd...].hasPrefix(". ") {
                let counter = (orderedCounters[depth] ?? 0) + 1
                orderedCounters[depth] = counter
                let startOfContent = rest.index(numberEnd, offsetBy: 2)
                let content = String(rest[startOfContent...])
                result.append("\(indent)\(counter). \(content)")
                continue
            }
            orderedCounters.removeValue(forKey: depth)

            // 箇条書き: "* " "- " "+ " (スペース数は問わない)
            // モデル出力が "*   text" (複数スペース) のケースにも対応
            let bulletMarkers: [Character] = ["*", "-", "+"]
            var didMatchBullet = false
            if let firstChar = rest.first, bulletMarkers.contains(firstChar) {
                let afterMarker = rest.dropFirst()
                if let secondChar = afterMarker.first, secondChar == " " || secondChar == "\t" {
                    let content = afterMarker.trimmingCharacters(in: .init(charactersIn: " \t"))
                    result.append("\(indent)• \(content)")
                    didMatchBullet = true
                }
            }
            if !didMatchBullet {
                result.append(line)
            }
        }
        // AttributedString(markdown:) は単独 \n をソフト改行(スペース)として解釈する。
        // \n\n にすることで paragraph break として正しく改行を表示する。
        var joined = result.joined(separator: "\n\n")
        // 既存の連続改行(\n\n\n以上)を \n\n に正規化して過剰な空白行を防ぐ
        joined = joined.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        // モデルが「**見出し**: 本文 **次の見出し**: 本文…」のように1段落に詰めて出力する場合、
        // 太字見出し(+コロン) の前に paragraph break を挿入して視覚的に分節する。
        // 既に直前が改行なら何もしない（[^\n] で直前が改行以外の場合のみ一致）。
        joined = joined.replacingOccurrences(
            of: "([^\\n])\\s*(\\*\\*[^*\\n]{1,40}\\*\\*[：:])",
            with: "$1\n\n$2",
            options: .regularExpression
        )
        return joined
    }

    private var displayContent: String {
        guard message.role == .assistant else { return message.content }

        switch directiveParser.parse(message.content) {
        case .decoded(let directive):
            return directive.message?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? directive.question?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? message.content
        case .jsonLikeButInvalid, .notJSONLike:
            return message.content
        }
    }

    private var bubbleBackground: some ShapeStyle {
        if message.role == .user {
            // ChatGPT ライクな落ち着いたユーザー吹き出し (薄いグレー角丸)
            return AnyShapeStyle(Color.appSoftFill.opacity(0.85))
        }

        // AI 側は Studio の compact 表示では背景なし (ChatGPT 風)
        if compactStudioStyle {
            return AnyShapeStyle(Color.clear)
        }

        return AnyShapeStyle(Color.appSecondaryBackground.opacity(0.6))
    }

    // 仕様9.3: 完了後ヘッダーは「思考 + 経過時間 + 1行要約」
    private var assistantMetaRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            if hasPrimaryDetailAction {
                Button(action: openPrimaryDetail) {
                    HStack(spacing: 6) {
                        Image(systemName: "brain.head.profile")
                            .font(.system(size: 10, weight: .semibold))

                        // 「思考」+ 経過時間
                        HStack(spacing: 4) {
                            Text("思考")
                                .font(.system(size: compactStudioStyle ? 10 : 10.5, weight: .semibold))
                            if let badge = thoughtBadgeText {
                                Text(badge)
                                    .font(.system(size: compactStudioStyle ? 9.5 : 10, weight: .medium))
                                    .foregroundColor(.secondary)
                            }
                        }

                        // 1行要約
                        if let preview = thoughtPreviewText {
                            Text("・")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(.secondary.opacity(0.5))
                            Text(preview)
                                .font(.system(size: compactStudioStyle ? 9.5 : 10, weight: .medium))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 0)
                    }
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.appSoftFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.appBorder.opacity(0.14), lineWidth: 1)
                    )
                    .cornerRadius(10)
                }
                .buttonStyle(.plain)
            } else if let processingLogText {
                Text(processingLogText)
                    .font(.system(size: compactStudioStyle ? 9.5 : 10, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var shouldShowAssistantMetaRow: Bool {
        hasPrimaryDetailAction || processingLogText != nil
    }

    private var hasPrimaryDetailAction: Bool {
        (showsThoughtDetailsButton && onShowThoughtDetails != nil) || (showsDebugDetailsButton && onShowDebugDetails != nil)
    }

    private func openPrimaryDetail() {
        if showsThoughtDetailsButton {
            onShowThoughtDetails?()
        } else {
            onShowDebugDetails?()
        }
    }

    private var thoughtBadgeText: String? {
        guard let thoughtDetails = message.thoughtDetails else { return nil }
        if let duration = thoughtDetails.thinkingDuration {
            let rounded = Int(duration.rounded(.up))
            return "\(max(1, rounded))s"
        }
        return thoughtDetails.executionDisplayName
    }

    private var thoughtPreviewText: String? {
        guard let thoughtDetails = message.thoughtDetails else { return nil }

        let summaryCandidates = thoughtDetails.displayThoughtSegments + thoughtDetails.detailedThoughtSummaries + thoughtDetails.thoughtSummaries
        if let firstSummary = summaryCandidates.first?.trimmingCharacters(in: .whitespacesAndNewlines),
           !firstSummary.isEmpty {
            return firstSummary
        }

        return nil
    }

    private var detailSummaryText: String? {
        var parts: [String] = []

        if let thoughtBadgeText {
            parts.append(thoughtBadgeText)
        }

        if let debugDetails = message.thoughtDetails?.debugDetails {
            if debugDetails.externalSearchRoundCount > 0 {
                parts.append("外部検索 \(debugDetails.externalSearchRoundCount)回")
            }
            if debugDetails.conversationSearchHitCount > 0 {
                parts.append("会話検索 \(debugDetails.conversationSearchHitCount)件")
            }
            if !debugDetails.toolSummaries.isEmpty {
                parts.append("ツール \(debugDetails.toolSummaries.count)回")
            }
            if !debugDetails.supportAgentExecutions.isEmpty {
                parts.append("補助エージェント \(debugDetails.supportAgentExecutions.count)役")
            } else if !debugDetails.supportExecutions.isEmpty {
                parts.append("補助モデル \(debugDetails.supportExecutions.count)回")
            }
        }

        if parts.isEmpty, let usagePreviewText {
            parts.append(usagePreviewText)
        }

        if parts.isEmpty, let processingLogText {
            parts.append(processingLogText)
        }

        return parts.isEmpty ? nil : parts.joined(separator: " ・ ")
    }

    private var usagePreviewText: String? {
        guard let debugDetails = message.thoughtDetails?.debugDetails else { return nil }

        let externalQueries = Array(NSOrderedSet(array: debugDetails.externalSearchQueries)) as? [String] ?? debugDetails.externalSearchQueries
        if let firstExternalQuery = externalQueries.first {
            let suffix = externalQueries.count > 1 ? " ほか\(externalQueries.count - 1)件" : ""
            return "検索: \(firstExternalQuery)\(suffix)"
        }

        let conversationQueries = Array(NSOrderedSet(array: debugDetails.conversationSearchQueries)) as? [String] ?? debugDetails.conversationSearchQueries
        if let firstConversationQuery = conversationQueries.first {
            let suffix = conversationQueries.count > 1 ? " ほか\(conversationQueries.count - 1)件" : ""
            return "会話検索: \(firstConversationQuery)\(suffix)"
        }

        if let firstSupportExecution = supportAgentLines(from: debugDetails).first {
            return "補助: \(firstSupportExecution)"
        }

        if let firstTool = debugDetails.toolSummaries.first {
            return "ツール: \(firstTool)"
        }

        return nil
    }

    private func supportAgentLines(from details: AICoachService.ResponseDebugDetails) -> [String] {
        if !details.supportAgentExecutions.isEmpty {
            return details.supportAgentExecutions.map { item in
                let role = item.role ?? "support"
                let duration: String
                if let value = formattedLatencyValue(item.duration) {
                    duration = value
                } else {
                    duration = "-"
                }

                var base = "\(role) / \(item.modelDisplayName) / \(duration)"
                if item.degraded {
                    if let failureReason = item.failureReason, !failureReason.isEmpty {
                        base += "\n縮退: \(failureReason)"
                    } else {
                        base += "\n縮退"
                    }
                } else if let outputPreview = item.outputPreview, !outputPreview.isEmpty {
                    base += "\n\(outputPreview)"
                }
                return base
            }
        }

        return details.supportExecutions
    }

    private func formattedLatencyValue(_ duration: TimeInterval?) -> String? {
        guard let duration, duration.isFinite, duration >= 0 else { return nil }
        if duration < 1 {
            return String(format: "%.2f秒", duration)
        }
        if duration < 10 {
            return String(format: "%.1f秒", duration)
        }
        return "\(Int(duration.rounded()))秒"
    }

    private var processingLogText: String? {
        let summary = message.thoughtDetails?.toolActivity.isEmpty == false
            ? message.thoughtDetails?.toolActivity
            : message.thoughtDetails?.processingLogSummary
        guard let summary, !summary.isEmpty else { return nil }
        return Array(summary.prefix(2)).joined(separator: " · ")
    }

    private func bubbleAvatar(systemName: String, tint: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 12, weight: .bold))
            .foregroundColor(tint)
            .frame(width: 28, height: 28)
            .background(tint.opacity(0.12))
            .clipShape(Circle())
    }

    private func attachedImageStrip(_ images: [Data]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(images.enumerated()), id: \.offset) { _, data in
                    platformRenderedImage(from: data)
                        .frame(width: 120, height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
        .frame(maxWidth: 320, alignment: .leading)
    }

    private var responseActionRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let actions = message.responseActions, !actions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(actions) { action in
                            Button {
                                onSelectResponseAction?(action)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: action.kind.iconName)
                                        .font(.system(size: 10, weight: .semibold))
                                    Text(action.title)
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(Color.appSoftFill)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(Color.appBorder.opacity(0.14), lineWidth: 1)
                                )
                                .cornerRadius(10)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            HStack(spacing: 10) {
                if let onRegenerate {
                    actionPillButton(systemImage: "arrow.clockwise", title: "もう一度生成") {
                        onRegenerate()
                    }
                }

                actionPillButton(
                    systemImage: copyFeedback ? "checkmark" : "doc.on.doc",
                    title: copyFeedback ? "コピーしました" : "コピー",
                    isDisabled: copyableContent.isEmpty
                ) {
                    copyAssistantContent()
                }

                Button {
                    feedbackSelection = .up
                } label: {
                    Image(systemName: feedbackSelection == .up ? "hand.thumbsup.fill" : "hand.thumbsup")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)

                Button {
                    feedbackSelection = .down
                } label: {
                    Image(systemName: feedbackSelection == .down ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)

                if let usageLabel = tokenUsageLabel {
                    Text(usageLabel)
                        .font(.system(size: compactStudioStyle ? 9.5 : 10, weight: .medium))
                        .foregroundColor(.secondary.opacity(0.85))
                }
            }
        }
        .font(.system(size: compactStudioStyle ? 9.5 : 10, weight: .semibold))
        .foregroundColor(.secondary)
    }

    /// macOS の `.buttonStyle(.plain)` + `Label` だとアイコン／テキストの片方が
    /// 消えるケースがあるため、明示的な HStack で組み立てたピル型ボタン。
    @ViewBuilder
    private func actionPillButton(
        systemImage: String,
        title: String,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundColor(isDisabled ? .secondary.opacity(0.4) : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.appSoftFill.opacity(0.7))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.appBorder.opacity(0.18), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }

    /// 完了済み assistant メッセージの inline `<Thinking>` ブロックに使う本文。
    /// 生成中は `AIThinkingRow` 側がライブ表示を担当するので、ここでは確定値のみ扱う。
    private var inlineThinkingText: String? {
        guard let details = message.thoughtDetails else { return nil }
        let raw = details.rawThoughtStream.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty { return raw }
        let segments = details.displayThoughtSegments
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !segments.isEmpty { return segments.joined(separator: "\n\n") }
        let detailed = details.detailedThoughtSummaries
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !detailed.isEmpty { return detailed.joined(separator: "\n\n") }
        return nil
    }

    @ViewBuilder
    private func inlineThinkingBlock(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isInlineThinkingExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isInlineThinkingExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                    Text("<Thinking>")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(.secondary)
                    if let badge = thoughtBadgeText {
                        Text(badge)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary.opacity(0.85))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)

            if isInlineThinkingExpanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            copyThinkingContent(text)
                        } label: {
                            Label(copyFeedback ? "コピーしました" : "Thinkingをコピー", systemImage: copyFeedback ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 11.5, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)

                        Text(text)
                            .font(.system(size: 12.5, weight: .regular))
                            .foregroundColor(.secondary)
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }
                .frame(maxHeight: 220)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
    }

    private var copyableContent: String {
        // 貼り付け先 (メモ/エディタ/メール) で再利用しやすいよう、`•` 置換前の
        // 「素の markdown」を採用する。assistant メッセージは directive を剥がした
        // displayContent、user メッセージは message.content 原文を返す。
        let candidate = displayContent
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        // 念のためのフォールバック (directive 化された場合等)
        return message.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func copyThinkingContent(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
#if os(macOS)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(trimmed, forType: .string)
#else
        UIPasteboard.general.string = trimmed
#endif
        copyFeedback = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copyFeedback = false
        }
    }

    private func copyAssistantContent() {
        let text = copyableContent
        guard !text.isEmpty else { return }
#if os(macOS)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
#else
        UIPasteboard.general.string = text
#endif
        copyFeedback = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copyFeedback = false
        }
    }

    private var tokenUsageLabel: String? {
        // ResponseDebugDetails.promptTokens / completionTokens がある時だけ
        // "prompt 123 / out 456 tok" を末尾に出す。検索専用のトークンしか無いケースは
        // 値が小さすぎて意味が無いので両方とも非 nil の時のみ表示する。
        guard let details = message.thoughtDetails?.debugDetails else { return nil }
        switch (details.promptTokens, details.completionTokens) {
        case let (pt?, ct?):
            return "in \(pt) / out \(ct) tok"
        case let (pt?, nil):
            return "in \(pt) tok"
        case let (nil, ct?):
            return "out \(ct) tok"
        default:
            return nil
        }
    }
}

private struct LiveAssistantPreviewBubble: View {
    let text: String
    let maxBubbleWidth: CGFloat
    let showsAvatars: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: showsAvatars ? 10 : 0) {
            if showsAvatars {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.blue)
                    .frame(width: 28, height: 28)
                    .background(Color.blue.opacity(0.12))
                    .clipShape(Circle())
            }

            VStack(alignment: .leading, spacing: 4) {
                AILiveStreamingText(
                    text: text,
                    font: .system(size: showsAvatars ? 14 : 15, weight: .regular),
                    foregroundColor: .primary,
                    lineSpacing: showsAvatars ? 2 : 3
                )
                    .padding(.horizontal, showsAvatars ? 14 : 0)
                    .padding(.vertical, showsAvatars ? 11 : 2)
                    .background(showsAvatars ? Color.appSecondaryBackground.opacity(0.6) : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(showsAvatars ? Color.appBorder.opacity(0.18) : Color.clear, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                // 仕様9.4: 固定フレームのdotのみ。流れる線アニメーションは使わない。
                HStack(spacing: 6) {
                    AIPulseBadge(tint: .blue)
                    AILiveStatusText(
                        baseText: "考えています",
                        tint: .secondary,
                        font: .system(size: showsAvatars ? 10 : 9, weight: .medium)
                    )
                    Spacer(minLength: 0)
                    AIActivityDotsView(tint: .blue, dotSize: 4)
                        .frame(width: 24, height: 8)
                }
            }
            .frame(maxWidth: maxBubbleWidth, alignment: .leading)

            Spacer(minLength: 0)
        }
    }
}

@ViewBuilder
private func platformRenderedImage(from data: Data) -> some View {
    #if os(macOS)
    if let image = NSImage(data: data) {
        Image(nsImage: image)
            .resizable()
            .scaledToFill()
    }
    #elseif canImport(UIKit)
    if let image = UIImage(data: data) {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
    }
    #endif
}

private struct AIActivityDotsView: View {
    let tint: Color
    let dotSize: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.06)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: dotSize) {
                ForEach(0..<3, id: \.self) { index in
                    let phase = max(0, sin((time * 4.2) - Double(index) * 0.65))
                    Circle()
                        .fill(tint.opacity(0.35 + phase * 0.65))
                        .frame(width: dotSize, height: dotSize)
                        .scaleEffect(0.78 + phase * 0.48)
                }
            }
        }
    }
}

private struct AILiveStatusText: View {
    let baseText: String
    let tint: Color
    let font: Font

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.2)) { context in
            let tick = Int(context.date.timeIntervalSinceReferenceDate * 5)
            let dots = String(repeating: ".", count: (tick % 3) + 1)

            Text(baseText + dots)
                .font(font)
                .foregroundColor(tint)
        }
    }
}

struct AILiveStreamingText: View {
    let text: String
    let font: Font
    let foregroundColor: Color
    let lineSpacing: CGFloat

    @State private var renderedCharacterCount: Int = 0

    private func attributed(from display: String) -> AttributedString? {
        guard var attr = try? AttributedString(
            markdown: display,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else { return nil }
        attr.font = font
        return attr
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.18)) { context in
            let showCursor = Int(context.date.timeIntervalSinceReferenceDate * 5).isMultiple(of: 2)
            let cursor = showCursor ? " ▍" : ""
            let display = Self.preprocessStreamingMarkdown(renderedText) + cursor

            Group {
                if let attr = attributed(from: display) {
                    Text(attr)
                } else {
                    Text(display).font(font)
                }
            }
            .lineSpacing(lineSpacing)
            .foregroundColor(foregroundColor)
            .textSelection(.enabled)
        }
        .task {
            renderedCharacterCount = min(renderedCharacterCount, text.count)
        }
        .task(id: text) {
            await animateTowardLatestText()
        }
    }

    private var renderedText: String {
        String(text.prefix(renderedCharacterCount))
    }

    @MainActor
    private func synchronizeRenderedCountIfNeeded() {
        let currentRenderedText = renderedText
        guard text.hasPrefix(currentRenderedText) else {
            renderedCharacterCount = 0
            return
        }
        if renderedCharacterCount > text.count {
            renderedCharacterCount = text.count
        }
    }

    private func animateTowardLatestText() async {
        // `synchronizeRenderedCountIfNeeded` は `@MainActor` だが同期関数。
        // 呼び出し側もメインアクター上で実行されるためそのまま呼ぶ (await を外す)。
        await MainActor.run { synchronizeRenderedCountIfNeeded() }

        while true {
            let remaining = await MainActor.run { text.count - renderedCharacterCount }
            guard remaining > 0 else { break }

            // 生成が UI より大幅に先行している場合は即座に追いつく（タイピング演出より応答性優先）。
            if remaining > 200 {
                await MainActor.run {
                    renderedCharacterCount = text.count
                }
                continue
            }

            let step: Int
            let delayNanoseconds: UInt64
            switch remaining {
            case 1...12:
                step = 2
                delayNanoseconds = 14_000_000
            case 13...48:
                step = 4
                delayNanoseconds = 8_000_000
            case 49...120:
                step = 10
                delayNanoseconds = 5_000_000
            default:
                step = min(max(16, remaining / 8), 40)
                delayNanoseconds = 3_000_000
            }

            await MainActor.run {
                renderedCharacterCount = min(renderedCharacterCount + step, text.count)
            }

            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
    }

    /// ストリーミング中の Text でも markdown を解釈できるよう、
    /// 見出し/箇条書きを inline markdown に寄せ、paragraph break を `\n\n` に揃える。
    static func preprocessStreamingMarkdown(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var out: [String] = []
        for line in lines {
            var idx = line.startIndex
            while idx < line.endIndex, line[idx] == " " || line[idx] == "\t" {
                idx = line.index(after: idx)
            }
            let indent = String(line[..<idx])
            let rest = String(line[idx...])
            if rest.allSatisfy({ $0 == "#" }), (1...3).contains(rest.count) {
                continue
            }
            if rest == "**" || rest == "***" || rest == "---" {
                continue
            }
            if rest.hasPrefix("### ") {
                out.append(indent + "**" + rest.dropFirst(4) + "**"); continue
            }
            if rest.hasPrefix("## ") {
                out.append(indent + "**" + rest.dropFirst(3) + "**"); continue
            }
            if rest.hasPrefix("# ") {
                out.append(indent + "**" + rest.dropFirst(2) + "**"); continue
            }
            let bulletMarkers: [Character] = ["*", "-", "+"]
            if let firstChar = rest.first, bulletMarkers.contains(firstChar) {
                let afterMarker = rest.dropFirst()
                if let second = afterMarker.first, second == " " || second == "\t" {
                    let content = afterMarker.trimmingCharacters(in: .init(charactersIn: " \t"))
                    out.append("\(indent)• \(content)"); continue
                }
            }
            out.append(line)
        }
        var joined = out.joined(separator: "\n\n")
        joined = joined.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        joined = joined.replacingOccurrences(
            of: "([^\\n])\\s*(\\*\\*[^*\\n]{1,40}\\*\\*[：:])",
            with: "$1\n\n$2",
            options: .regularExpression
        )
        return joined
    }
}

private struct AIPulseBadge: View {
    let tint: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.06)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let pulseValue = (sin(time * 3.6) + 1) / 2
            let pulse = CGFloat(pulseValue)

            ZStack {
                Circle()
                    .stroke(tint.opacity(0.18 + pulseValue * 0.22), lineWidth: 1)
                    .frame(width: 12 + pulse * 5, height: 12 + pulse * 5)
                Circle()
                    .fill(tint)
                    .frame(width: 7, height: 7)
            }
        }
    }
}

private struct AIProcessingPulseView: View {
    let tint: Color
    let systemName: String
    let isActive: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.06)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let pulseValue = isActive ? (sin(time * 3.1) + 1) / 2 : 0
            let pulse = CGFloat(pulseValue)

            ZStack {
                Circle()
                    .fill(tint.opacity(isActive ? 0.12 + pulseValue * 0.08 : 0.10))
                    .frame(width: 18, height: 18)

                Circle()
                    .stroke(tint.opacity(isActive ? 0.18 + pulseValue * 0.24 : 0.14), lineWidth: 1)
                    .frame(width: 18 + pulse * 6, height: 18 + pulse * 6)

                Image(systemName: systemName)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(tint)
                    .scaleEffect(isActive ? 0.95 + pulse * 0.08 : 1)
            }
        }
    }
}

// 仕様9.3: 返答中は薄い live preview のみ表示。レイアウトを揺らすアニメーションは使わない。
private struct AILiveReasoningRow: View {
    let title: String
    let subtitle: String
    let tint: Color
    let summaryItems: [String]      // 後方互換のため残す（使用しない）
    let rawThoughtItems: [String]   // 後方互換のため残す（使用しない）
    let stageSections: [AICoachView.ThoughtDisplaySection] // 後方互換のため残す（使用しない）
    let liveThoughtText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // ヘッダー行（固定高さ・レイアウト揺れなし）
            HStack(spacing: 10) {
                AIProcessingPulseView(tint: tint, systemName: "sparkles", isActive: true)
                    .frame(width: 22, height: 22)

                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Spacer()

                // 仕様9.4: 固定フレームの dot indicator のみ（流れる線アニメーションは使わない）
                AIActivityDotsView(tint: tint, dotSize: 5)
                    .frame(width: 30, height: 10)
            }

            // 仕様9.3: 返答中は薄い live preview のみ（1行・低opacity）
            if let liveThoughtText, !liveThoughtText.isEmpty {
                AILiveStreamingText(
                    text: liveThoughtText,
                    font: .system(size: 11, weight: .medium),
                    foregroundColor: .secondary,
                    lineSpacing: 1.5
                )
                .lineLimit(2)
                .opacity(0.72)
                .padding(.horizontal, 4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.appSoftFill.opacity(0.9))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(tint.opacity(0.10), lineWidth: 1)
        )
        .cornerRadius(14)
    }
}

private struct AISendButtonVisual: View {
    let isEnabled: Bool
    let isBusy: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.06)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let pulseValue = isEnabled && !isBusy ? (sin(time * 2.6) + 1) / 2 : 0
            let pulse = CGFloat(pulseValue)

            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.blue, Color.cyan],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 42, height: 42)

                if isEnabled && !isBusy {
                    Circle()
                        .stroke(Color.cyan.opacity(0.12 + pulseValue * 0.2), lineWidth: 1)
                        .frame(width: 42 + pulse * 8, height: 42 + pulse * 8)
                }

                if isBusy {
                    AIActivityDotsView(tint: .white, dotSize: 4)
                        .frame(width: 22, height: 10)
                } else {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                        .offset(x: isEnabled ? pulse * 1.4 : 0, y: isEnabled ? -pulse * 0.8 : 0)
                }
            }
        }
        .frame(width: 42, height: 42)
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension View {
    @ViewBuilder
    func viukAdaptiveSheetSizing(minWidth: CGFloat, minHeight: CGFloat) -> some View {
        #if os(macOS)
        self.frame(minWidth: minWidth, minHeight: minHeight)
        #else
        self.presentationDetents([.large])
            .presentationDragIndicator(.visible)
        #endif
    }
}
