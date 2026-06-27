/*
仕様:
- 役割: AI Studio を「会話入口 + Deep Research 起動」型の3カラムUIで表示する。
- 主な型: `RootLayoutView`, `SearchHeaderView`, `ResultPageView`.
- 編集ポイント: AI Studio のホーム、結果ページ、右カラムの表示構造を変えるときに触る。
*/
#if os(macOS)
import AppKit
private typealias StudioPlatformImage = NSImage
#elseif canImport(UIKit)
import UIKit
private typealias StudioPlatformImage = UIImage
#endif
import Foundation
import Combine
import PhotosUI
import SwiftUI

/// `Link(destination:)` に渡す前に URL のスキームを http/https に限定する。
/// モデル出力や検索結果に `javascript:` / `data:` / `file:` 等が混入してもクリック開封されないようにする。
private func safeWebURL(_ raw: String) -> URL? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmed),
          let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https" else {
        return nil
    }
    return url
}

private func dismissAIStudioKeyboard() {
    #if canImport(UIKit)
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    #endif
}

/// Markdown ソースに `[label](javascript:...)` 等の危険スキームが入っていたら、
/// `[label]` だけのプレーンテキストに置換する。
/// View 階層に `OpenURLAction` の scheme allowlist も別途仕込んでいるが、
/// AttributedString レンダリングよりも前にソース文字列を毒抜きしておくことで、
/// 万一の経路 (sheet・popover 等で env が伝搬しないケース) でもクリック誘導を遮断する。
private func sanitizeMarkdownLinkSchemes(_ markdown: String) -> String {
    let pattern = #"\[([^\]]*)\]\(\s*([^)\s]+)\s*\)"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
        return markdown
    }
    let ns = markdown as NSString
    let matches = regex.matches(in: markdown, range: NSRange(location: 0, length: ns.length))
    guard !matches.isEmpty else { return markdown }
    var result = markdown
    // 後ろから置換しないと range がずれるので逆順
    for match in matches.reversed() {
        guard match.numberOfRanges >= 3 else { continue }
        let labelRange = match.range(at: 1)
        let urlRange = match.range(at: 2)
        guard labelRange.location != NSNotFound, urlRange.location != NSNotFound else { continue }
        let label = ns.substring(with: labelRange)
        let urlString = ns.substring(with: urlRange)
        let safe = safeWebURL(urlString) != nil
        if !safe {
            let fullRange = match.range
            let asNS = result as NSString
            let replacement = "[\(label)]"
            result = asNS.replacingCharacters(in: fullRange, with: replacement)
        }
    }
    return result
}

// ── AI Studio Redesign — warm dark palette ──────────────────────────────
// oklch → sRGB approximate conversions (warm-toned dark, hue ≈ 30°)
private let studioCanvasColor   = Color(red: 0.16, green: 0.14, blue: 0.13)  // --bg-0
private let studioBg1           = Color(red: 0.19, green: 0.17, blue: 0.15)  // --bg-1 canvas
private let studioBg2           = Color(red: 0.21, green: 0.185, blue: 0.17) // --bg-2 sidebar/rail
private let studioBg3           = Color(red: 0.245, green: 0.215, blue: 0.20)// --bg-3 cards
private let studioBg4           = Color(red: 0.29,  green: 0.255, blue: 0.24)// --bg-4 hover
private let studioPanelColor    = studioBg2.opacity(0.9)
private let studioLineColor     = Color.white.opacity(0.08)
private let studioLineStrong    = Color.white.opacity(0.15)
private let studioMutedText     = Color.white.opacity(0.62)
// Purple accent  oklch(0.66 0.18 295)
private let studioAccent        = Color(red: 0.42, green: 0.28, blue: 0.88)
private let studioAccentHi      = Color(red: 0.53, green: 0.38, blue: 0.93)
private let studioAccentLo      = Color(red: 0.30, green: 0.18, blue: 0.80)
private let studioAccentSoft    = Color(red: 0.42, green: 0.28, blue: 0.88).opacity(0.16)
// Warm amber     oklch(0.78 0.12 55)
private let studioWarm          = Color(red: 0.93, green: 0.73, blue: 0.44)
private let studioWarmSoft      = Color(red: 0.93, green: 0.73, blue: 0.44).opacity(0.14)
// Text
private let studioText1         = Color(red: 0.97, green: 0.94, blue: 0.90)  // near-white warm
private let studioText3         = Color(red: 0.62, green: 0.58, blue: 0.54)  // tertiary/meta

struct RootLayoutView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @StateObject private var aiCoach = AICoachService.shared
    @StateObject private var localModelManager = LocalAssistantModelManager.shared
    @StateObject private var localSupportModelManager = LocalSupportModelManager.shared
    @StateObject private var webBrowsingAgent = WebBrowsingAgent.shared
    @StateObject private var webSearchService = OllamaWebSearchService.shared
    @State private var rootViewModel = AIStudioRootViewModel()
    @State private var resultPageViewModel = ResultPageViewModel()
    @State private var thinkingPanelViewModel = ThinkingPanelViewModel()
    @State private var threadSearchText = ""
    @State private var selectedMessageID: UUID?
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var selectedImageData: [Data] = []
    /// 添付ドキュメント (PDF / テキスト等)。Gemma 4 26B Web 読解パイプラインで Web ソースと同じように扱う。
    @State private var selectedFileAttachments: [ChatFileAttachment] = []
    @State private var fileImporterIsPresented: Bool = false
    @State private var fileImportErrorMessage: String?
    @State private var showComposerAdvancedSettings = false
    @State private var draftGemmaAdvancedSettings = AICoachService.shared.gemmaAdvancedSettings

    let onOpenSettings: () -> Void
    let onClearConversation: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let compact = shouldUseCompactLayout(width: proxy.size.width)

            layoutView(compact: compact)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(studioCanvasColor.ignoresSafeArea())
                // モデル出力や検索結果由来の markdown リンクが javascript: / data: / file: を
                // 含む場合に開かれないよう、http/https のみ許可する。
                .environment(\.openURL, OpenURLAction { url in
                    let scheme = url.scheme?.lowercased() ?? ""
                    return (scheme == "http" || scheme == "https") ? .systemAction : .discarded
                })
                .onAppear {
                    if aiCoach.coachMode != .studio {
                        DispatchQueue.main.async {
                            aiCoach.setMode(.studio)
                        }
                    }
                    rootViewModel.isWebEnabled = aiCoach.executionConfig.reasoningMode == .fast
                        ? aiCoach.executionConfig.allowWebSearch
                        : true
                    draftGemmaAdvancedSettings = aiCoach.gemmaAdvancedSettings
                    syncPresentationMode()
                }
                .onChange(of: aiCoach.messages.count) { _, _ in
                    syncPresentationMode()
                }
                .onChange(of: aiCoach.activeResultPage) { _, _ in
                    syncPresentationMode()
                }
                .onChange(of: aiCoach.currentThreadID) { _, _ in
                    selectedMessageID = nil
                    thinkingPanelViewModel.isExpanded = false
                    syncPresentationMode()
                }
                .onChange(of: selectedPhotos) { _, items in
                    Task { await loadSelectedImages(from: items) }
                }
                .onChange(of: aiCoach.gemmaAdvancedSettings) { _, nextValue in
                    guard draftGemmaAdvancedSettings != nextValue else { return }
                    draftGemmaAdvancedSettings = nextValue
                }
                .onChange(of: draftGemmaAdvancedSettings) { _, nextValue in
                    guard aiCoach.gemmaAdvancedSettings != nextValue else { return }
                    DispatchQueue.main.async {
                        aiCoach.updateGemmaAdvancedSettings { settings in
                            settings = nextValue
                        }
                    }
                }
                .task(id: derivedViewModelSyncKey) {
                    await MainActor.run {
                        syncDerivedViewModels()
                    }
                }
                .sheet(isPresented: $rootViewModel.showCompactSidebar) {
                    NavigationStack {
                        SidebarView(
                            threads: filteredThreads,
                            selectedThreadID: aiCoach.currentThreadID,
                            searchText: $threadSearchText,
                            isCompact: true,
                            onCreateNew: {
                                rootViewModel.isDeepResearchRequested = false
                                aiCoach.createNewChatThread()
                            },
                            onSelectThread: { threadID in
                                rootViewModel.isDeepResearchRequested = false
                                aiCoach.switchToChatThread(threadID)
                                rootViewModel.showCompactSidebar = false
                            }
                        )
                    }
                    .viukAdaptiveSheetSizing(minWidth: 340, minHeight: 520)
                }
                .sheet(isPresented: $rootViewModel.showCompactInspector) {
                    NavigationStack {
                        rightPanel
                            .padding(16)
                            .navigationTitle("詳細")
                    }
                    .viukAdaptiveSheetSizing(minWidth: 360, minHeight: 520)
                }
        }
    }

    private func layoutView(compact: Bool) -> some View {
        Group {
            if compact {
                compactLayout
            } else {
                desktopLayout
            }
        }
    }

    private var desktopLayout: some View {
        HStack(spacing: 0) {
            if rootViewModel.isSidebarOpen {
                SidebarView(
                    threads: filteredThreads,
                    selectedThreadID: aiCoach.currentThreadID,
                    searchText: $threadSearchText,
                    isCompact: false,
                    onCreateNew: {
                        rootViewModel.isDeepResearchRequested = false
                        aiCoach.createNewChatThread()
                    },
                    onSelectThread: { threadID in
                        rootViewModel.isDeepResearchRequested = false
                        aiCoach.switchToChatThread(threadID)
                    }
                )
                .frame(width: 260)
                Divider()
            } else {
                collapsedSidebarRail
                Divider()
            }

            centerColumn(
                onOpenSidebar: { rootViewModel.isSidebarOpen.toggle() },
                onOpenInspector: nil
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            rightPanel
                .frame(width: 300)
                .background(studioPanelColor)
        }
    }

    private var compactLayout: some View {
        centerColumn(
            onOpenSidebar: { rootViewModel.showCompactSidebar = true },
            onOpenInspector: { rootViewModel.showCompactInspector = true }
        )
    }

    private func centerColumn(
        onOpenSidebar: @escaping () -> Void,
        onOpenInspector: (() -> Void)?
    ) -> some View {
        VStack(spacing: 0) {
            StudioTopBarView(
                currentThread: aiCoach.currentThreadSummary,
                presentationMode: rootViewModel.presentationMode,
                modelChipTitle: localModelManager.runtimeAvailability == .executable
                    ? "gemma · direct"
                    : "fallback",
                isModelReady: localModelManager.runtimeAvailability == .executable,
                onToggleSidebar: onOpenSidebar,
                onOpenInspector: onOpenInspector,
                onOpenSettings: onOpenSettings,
                onCreateNewChat: {
                    rootViewModel.isDeepResearchRequested = false
                    aiCoach.createNewChatThread()
                },
                onClearConversation: onClearConversation
            )

            Group {
                switch rootViewModel.presentationMode {
                case .home:
                    HomePromptView(
                        query: $rootViewModel.searchQuery,
                        onSelectExample: { rootViewModel.searchQuery = $0 },
                        onSubmit: submitCurrentQuery,
                        recentThreads: Array(aiCoach.chatThreads.prefix(5)),
                        modelStatus: localModelManager.statusTitle
                    )
                case .conversation:
                    ConversationPageView(
                        messages: aiCoach.messages,
                        isLoading: aiCoach.isLoading,
                        liveThoughtPreview: normalizedThoughtPreview(aiCoach.liveThoughtPreview),
                        liveRawThoughtStream: aiCoach.liveRawThoughtStream,
                        liveExecutionStatus: aiCoach.liveExecutionStatus,
                        liveResponsePreview: aiCoach.liveResponsePreview,
                        onTapDetails: { message in
                            selectedMessageID = message.id
                        },
                        onTapResponseAction: { action in
                            aiCoach.sendResponseAction(action)
                        },
                        onRegenerate: { message in
                            guard let index = aiCoach.messages.firstIndex(where: { $0.id == message.id }) else { return }
                            let prior = Array(aiCoach.messages.prefix(index))
                            guard let lastUser = prior.last(where: { $0.role == .user }) else { return }
                            aiCoach.send(prompt: lastUser.content)
                        }
                    )
                case .result:
                    ResultPageView(
                        viewModel: resultPageViewModel,
                        thinkingViewModel: $thinkingPanelViewModel,
                        isLoading: aiCoach.isLoading,
                        loadingState: aiCoach.loadingState,
                        liveExecutionStatus: aiCoach.liveExecutionStatus,
                        liveThoughtPreview: normalizedThoughtPreview(aiCoach.liveThoughtPreview),
                        onAction: handleResultAction,
                        onRelatedQuestionTap: { rootViewModel.searchQuery = $0 }
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 12)

            VStack(spacing: 10) {
                StatusIndicatorView(
                    loadingState: aiCoach.loadingState,
                    isVisible: aiCoach.isLoading || rootViewModel.presentationMode == .result,
                    currentStep: aiCoach.currentResearchFlow.last,
                    executionStatus: aiCoach.liveExecutionStatus,
                    liveThoughtPreview: normalizedThoughtPreview(aiCoach.liveThoughtPreview)
                )

                if !selectedImageData.isEmpty {
                    attachmentStrip
                }

                SearchHeaderView(
                    searchQuery: $rootViewModel.searchQuery,
                    isWebEnabled: $rootViewModel.isWebEnabled,
                    isDeepResearchRequested: $rootViewModel.isDeepResearchRequested,
                    selectedReasoningMode: aiCoach.executionConfig.reasoningMode,
                    selectedThinkingLevel: aiCoach.executionConfig.thinkingLevel ?? aiCoach.thinkingLevel,
                    advancedSettings: gemmaAdvancedSettingsBinding,
                    showAdvancedSettings: $showComposerAdvancedSettings,
                    selectedPhotos: $selectedPhotos,
                    attachedImageCount: selectedImageData.count,
                    selectedFileAttachments: $selectedFileAttachments,
                    isLoading: aiCoach.isLoading,
                    runtimeStatusSummary: localModelManager.runtimeStatusSummary,
                    supportRuntimeStatusSummary: localSupportModelManager.runtimeStatusSummary,
                    onSelectReasoningMode: { mode in
                        aiCoach.setReasoningMode(mode)
                        if mode != .fast {
                            rootViewModel.isWebEnabled = true
                        }
                    },
                    onSelectThinkingLevel: { aiCoach.setThinkingLevel($0) },
                    onSubmit: submitCurrentQuery,
                    onCancel: { aiCoach.cancelCurrentGeneration() }
                )
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 18)
        }
        .frame(maxWidth: 900)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var rightPanel: some View {
        VStack(spacing: 0) {
            if webBrowsingAgent.isActive {
                WebBrowsingPanelView(agent: webBrowsingAgent)
                    .padding(10)
                Divider()
                    .opacity(0.15)
            }
            if shouldShowGemmaWebReaderLivePanel {
                // Gemma 4 26B Web 読解は実行中だけ表示する。完了後の出典は回答本文側へ残す。
                GemmaWebReaderPanelView()
                    .padding(.horizontal, 10)
                    .padding(.top, webBrowsingAgent.isActive ? 0 : 10)
                    .padding(.bottom, 10)
                Divider()
                    .opacity(0.15)
            }
            // ── 通常の右パネル ─────────────────────────────────────────
            AIStudioSidePanelView(
                presentationMode: rootViewModel.presentationMode,
                currentThread: aiCoach.currentThreadSummary,
                selectedMessage: selectedInspectorMessage,
                resultViewModel: resultPageViewModel,
                thinkingViewModel: $thinkingPanelViewModel,
                isLoading: aiCoach.isLoading,
                liveExecutionStatus: aiCoach.liveExecutionStatus,
                liveThoughtPreview: normalizedThoughtPreview(aiCoach.liveThoughtPreview),
                quickActions: aiCoach.quickActions,
                onTapRelatedQuestion: { rootViewModel.searchQuery = $0 },
                onTapSuggestedPrompt: { rootViewModel.searchQuery = $0 }
            )
        }
    }

    private var shouldShowGemmaWebReaderLivePanel: Bool {
        guard aiCoach.isLoading else { return false }
        return webSearchService.liveGemmaReadingPages.contains { $0.status == .reading }
            || webSearchService.liveGemmaReadingPages.isEmpty == false
    }

    private var filteredThreads: [AICoachService.ChatThreadSummary] {
        let query = threadSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return aiCoach.chatThreads }
        return aiCoach.chatThreads.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    private var gemmaAdvancedSettingsBinding: Binding<GemmaAdvancedSettings> {
        Binding(
            get: { draftGemmaAdvancedSettings },
            set: { next in
                draftGemmaAdvancedSettings = next
            }
        )
    }

    private var currentQueryTitle: String {
        aiCoach.activeResultPage?.query ?? aiCoach.messages.reversed().first(where: { $0.role == .user })?.content ?? "Deep Research"
    }

    private var selectedInspectorMessage: AICoachService.ChatMessage? {
        aiCoach.messages.first(where: { $0.id == selectedMessageID })
            ?? aiCoach.messages.reversed().first(where: { $0.role == .assistant })
    }

    private var researchFollowUpMessages: [AICoachService.ChatMessage] {
        guard aiCoach.currentThreadKind == .research,
              let anchorIndex = aiCoach.messages.firstIndex(where: { $0.role == .assistant && $0.resultPage != nil }) else {
            return []
        }
        let nextIndex = aiCoach.messages.index(after: anchorIndex)
        guard aiCoach.messages.indices.contains(nextIndex) else { return [] }
        return Array(aiCoach.messages.suffix(from: nextIndex))
    }

    private var collapsedSidebarRail: some View {
        VStack(spacing: 14) {
            // サイドバー展開
            Button {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.78)) {
                    rootViewModel.isSidebarOpen = true
                }
            } label: {
                Image(systemName: "sidebar.leading")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary.opacity(0.75))
                    .frame(width: 36, height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white.opacity(0.05))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(studioLineColor, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .help("サイドバーを開く")
            .accessibilityLabel("サイドバーを開く")

            // 新規チャット
            Button {
                rootViewModel.isDeepResearchRequested = false
                aiCoach.createNewChatThread()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .background(
                        LinearGradient(
                            colors: [
                                Color(red: 0.28, green: 0.55, blue: 1.0),
                                Color(red: 0.55, green: 0.30, blue: 1.0)
                            ],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(color: Color.purple.opacity(0.35), radius: 6, y: 2)
            }
            .buttonStyle(.plain)
            .help("新しいチャットを開始")
            .accessibilityLabel("新しいチャットを開始")

            Spacer()
        }
        .padding(.top, 16)
        .frame(width: 60)
        .background(studioPanelColor)
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Array(selectedImageData.enumerated()), id: \.offset) { index, data in
                    ZStack(alignment: .topTrailing) {
                        researchImage(from: data)
                            .frame(width: 72, height: 72)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
                            )
                            .shadow(color: .black.opacity(0.3), radius: 5, y: 2)

                        Button {
                            let targetIndex: Int = index
                            _ = withAnimation(.spring(response: 0.28, dampingFraction: 0.7)) {
                                selectedImageData.remove(at: targetIndex)
                            }
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(Color.black.opacity(0.75))
                                    .frame(width: 20, height: 20)
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(.white)
                            }
                            .overlay(
                                Circle().stroke(Color.white.opacity(0.3), lineWidth: 0.5)
                            )
                        }
                        .buttonStyle(.plain)
                        .padding(5)
                    }
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 4)
        }
    }

    private func syncPresentationMode() {
        rootViewModel.syncPresentationMode(
            messagesAreEmpty: aiCoach.messages.isEmpty,
            activeResultPage: aiCoach.activeResultPage,
            currentThreadKind: aiCoach.currentThreadKind
        )
        rootViewModel.selectedThreadID = aiCoach.currentThreadID
    }

    private var derivedViewModelSyncKey: String {
        // liveThoughtPreview / liveRawThoughtStream はストリーミング中に毎トークン更新される。
        // ここに含めると .task(id:) が毎トークン cancel → restart を繰り返して UI がカクつく。
        // それらは syncDerivedViewModels() 内で直接 aiCoach から読むのでキーには不要。
        [
            aiCoach.activeResultPage?.query ?? "",
            "\(aiCoach.messages.count)",
            "\(aiCoach.currentResearchFlow.count)",
            aiCoach.loadingState.rawValue,
            aiCoach.liveExecutionStatus?.stage.rawValue ?? "",
            aiCoach.liveExecutionStatus?.detail ?? "",
            "\(aiCoach.liveExecutionStatus?.estimatedProgress ?? -1)",
            selectedMessageID?.uuidString ?? "none",
            aiCoach.isLoading ? "loading" : "idle"
        ].joined(separator: "|")
    }

    private func syncDerivedViewModels() {
        resultPageViewModel.update(
            page: aiCoach.activeResultPage,
            followUpMessages: researchFollowUpMessages,
            queryFallback: currentQueryTitle
        )
        thinkingPanelViewModel.update(
            thoughtDetails: selectedInspectorMessage?.thoughtDetails,
            flow: aiCoach.activeResultPage?.researchFlow ?? aiCoach.currentResearchFlow,
            liveThoughtPreview: normalizedThoughtPreview(aiCoach.liveThoughtPreview),
            liveExecutionStatus: aiCoach.liveExecutionStatus,
            isLoading: aiCoach.isLoading
        )
    }

    private func shouldUseCompactLayout(width: CGFloat) -> Bool {
        #if os(iOS)
        if horizontalSizeClass == .compact {
            return true
        }
        #endif
        return width < 1180
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
        guard let image = NSImage(data: data),
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return data
        }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.84]) ?? data
        #elseif canImport(UIKit)
        guard let image = UIImage(data: data) else { return nil }
        return image.jpegData(compressionQuality: 0.84) ?? data
        #else
        return data
        #endif
    }

    private func submitCurrentQuery() {
        let trimmed = rootViewModel.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !selectedImageData.isEmpty || !selectedFileAttachments.isEmpty else { return }
        dismissAIStudioKeyboard()

        let attachments = selectedImageData
        let files = selectedFileAttachments
        let deepResearch = rootViewModel.isDeepResearchRequested

        if deepResearch {
            aiCoach.createNewResearchThread(initialTitle: trimmed.isEmpty ? "Deep Research" : trimmed)
            selectedMessageID = nil
        } else if aiCoach.executionConfig.reasoningMode == .fast {
            aiCoach.setResearchMode(rootViewModel.isWebEnabled ? .on : .off)
        }

        rootViewModel.presentationMode = deepResearch || aiCoach.currentThreadKind == .research ? .result : .conversation
        let defaultPrompt: String
        if !trimmed.isEmpty {
            defaultPrompt = trimmed
        } else if !attachments.isEmpty {
            defaultPrompt = "この画像を見てください。"
        } else {
            // ファイルのみ添付されたケース。
            defaultPrompt = "添付ファイルの内容を読んで要約してください。"
        }
        aiCoach.send(
            prompt: defaultPrompt,
            attachedImages: attachments,
            attachedFiles: files,
            isDeepResearchRequested: deepResearch
        )
        rootViewModel.searchQuery = ""
        rootViewModel.isDeepResearchRequested = false
        selectedPhotos.removeAll()
        selectedImageData.removeAll()
        selectedFileAttachments.removeAll()
    }

    private func handleResultAction(_ action: AIResultAction) {
        rootViewModel.searchQuery = action.prompt
        if action.kind == .deepResearch {
            rootViewModel.isDeepResearchRequested = true
            submitCurrentQuery()
        } else {
            aiCoach.send(prompt: action.prompt)
            rootViewModel.presentationMode = aiCoach.currentThreadKind == .research ? .result : .conversation
        }
    }

    private func normalizedThoughtPreview(_ preview: String) -> String? {
        // Fast モードでは Thinking プレビューを表示しない。
        guard aiCoach.executionConfig.reasoningMode != .fast else { return nil }
        let trimmed = preview.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    @ViewBuilder
    private func researchImage(from data: Data) -> some View {
        #if os(macOS)
        if let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.appCardBackground)
        }
        #elseif canImport(UIKit)
        if let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.appCardBackground)
        }
        #else
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.appCardBackground)
        #endif
    }
}

// MARK: - Sidebar time grouping
private enum SidebarTimeGroup: String, CaseIterable {
    case today = "今日"
    case yesterday = "昨日"
    case thisWeek = "先週"
    case older = "以前"
}

private func sidebarTimeGroup(for date: Date) -> SidebarTimeGroup {
    let cal = Calendar.current
    if cal.isDateInToday(date) { return .today }
    if cal.isDateInYesterday(date) { return .yesterday }
    if let weekAgo = cal.date(byAdding: .day, value: -7, to: Date()), date >= weekAgo { return .thisWeek }
    return .older
}

struct SidebarView: View {
    let threads: [AICoachService.ChatThreadSummary]
    let selectedThreadID: String
    @Binding var searchText: String
    let isCompact: Bool
    let onCreateNew: () -> Void
    let onSelectThread: (String) -> Void

    // Grouped threads ordered: today → yesterday → thisWeek → older
    private var groupedThreads: [(SidebarTimeGroup, [AICoachService.ChatThreadSummary])] {
        var buckets: [SidebarTimeGroup: [AICoachService.ChatThreadSummary]] = [:]
        for t in threads {
            let g = sidebarTimeGroup(for: t.updatedAt)
            buckets[g, default: []].append(t)
        }
        return SidebarTimeGroup.allCases.compactMap { g in
            guard let items = buckets[g], !items.isEmpty else { return nil }
            return (g, items)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Brand mark + new-chat button ─────────────────────────────
            HStack(spacing: 10) {
                // Gradient brand square
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [studioAccentHi, studioAccentLo],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 26, height: 26)
                    Image(systemName: "sparkle")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                }

                Text("AI Studio")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(studioText1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            // ── "新しいチャット" gradient button ────────────────────────
            Button(action: onCreateNew) {
                HStack(spacing: 7) {
                    Image(systemName: "plus")
                        .font(.system(size: 11.5, weight: .bold))
                    Text("新しいチャット")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(
                    LinearGradient(
                        colors: [studioAccentHi, studioAccent],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: studioAccent.opacity(0.35), radius: 8, y: 2)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            // ── Search bar with ⌘K hint ──────────────────────────────────
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(studioText3)
                TextField("履歴を探す", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(studioText1)
                Spacer(minLength: 0)
                Text("⌘K")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(studioText3)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2.5)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(studioLineColor, lineWidth: 1)
                    )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(Color.white.opacity(0.04))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(studioLineColor, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            // ── Time-grouped thread list ─────────────────────────────────
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                    if threads.isEmpty {
                        Text("会話履歴はまだありません")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(studioText3)
                            .padding(.horizontal, 16)
                            .padding(.top, 20)
                    } else {
                        ForEach(groupedThreads, id: \.0) { group, items in
                            // Group label
                            Text(group.rawValue)
                                .font(.system(size: 10.5, weight: .bold))
                                .foregroundColor(studioText3)
                                .tracking(0.6)
                                .padding(.horizontal, 16)
                                .padding(.top, 14)
                                .padding(.bottom, 4)

                            ForEach(items) { thread in
                                SidebarThreadRowView(
                                    thread: thread,
                                    isSelected: thread.id == selectedThreadID,
                                    onTap: { onSelectThread(thread.id) }
                                )
                                .padding(.horizontal, 8)
                            }
                        }
                    }
                }
                .padding(.bottom, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // ── User footer ──────────────────────────────────────────────
            Divider()
                .overlay(studioLineColor)
                .padding(.horizontal, 0)

            HStack(spacing: 10) {
                // Avatar circle
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [studioAccentHi.opacity(0.7), studioWarm.opacity(0.5)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 28, height: 28)
                    Image(systemName: "person.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.9))
                }

                Text("あなた")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(studioText1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(studioBg2)
    }
}

struct SidebarThreadRowView: View {
    let thread: AICoachService.ChatThreadSummary
    let isSelected: Bool
    let onTap: () -> Void
    @State private var isHovering = false
    @State private var showRenameSheet = false
    @State private var showDeleteConfirm = false
    @State private var renameDraft = ""

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 9) {
                // Dot indicator — warm amber on hover, accent purple on active, dim otherwise
                Circle()
                    .fill(
                        isSelected
                            ? studioAccent
                            : (isHovering ? studioWarm : Color.white.opacity(0.2))
                    )
                    .frame(width: 5, height: 5)
                    .animation(.easeInOut(duration: 0.15), value: isSelected)
                    .animation(.easeInOut(duration: 0.15), value: isHovering)

                VStack(alignment: .leading, spacing: 2) {
                    Text(thread.title)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                        .foregroundColor(isSelected ? studioText1 : studioText1.opacity(0.82))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    // タイムスタンプは常時表示 (タッチ環境やキーボード操作で
                    // ホバー前提だと永久に見えなくなる問題を回避)。
                    Text(relativeDateText(for: thread.updatedAt))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(studioText3)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.easeInOut(duration: 0.15), value: isHovering)
                .animation(.easeInOut(duration: 0.2), value: isSelected)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                Group {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(
                                LinearGradient(
                                    stops: [
                                        .init(color: studioAccent.opacity(0.18), location: 0),
                                        .init(color: studioAccent.opacity(0.08), location: 1)
                                    ],
                                    startPoint: .top, endPoint: .bottom
                                )
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .strokeBorder(studioAccent.opacity(0.22), lineWidth: 1)
                            )
                    } else if isHovering {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(studioBg4)
                    }
                }
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovering)
        .animation(.easeInOut(duration: 0.2), value: isSelected)
        .help(tooltipText)
        .contextMenu {
            Button {
                renameDraft = thread.title
                showRenameSheet = true
            } label: {
                Label("名前を変更", systemImage: "pencil")
            }
            Button {
                AICoachService.shared.duplicateChatThread(thread.id)
            } label: {
                Label("複製", systemImage: "doc.on.doc")
            }
            Divider()
            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Label("削除", systemImage: "trash")
            }
        }
        .confirmationDialog(
            "「\(thread.title)」を削除しますか？",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("削除", role: .destructive) {
                AICoachService.shared.deleteChatThread(thread.id)
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("このスレッドのメッセージがすべて消えます。元に戻せません。")
        }
        .sheet(isPresented: $showRenameSheet) {
            ThreadRenameSheet(
                originalTitle: thread.title,
                draftTitle: $renameDraft,
                onConfirm: {
                    AICoachService.shared.renameChatThread(thread.id, to: renameDraft)
                    showRenameSheet = false
                },
                onCancel: {
                    showRenameSheet = false
                }
            )
        }
    }

    private var tooltipText: String {
        let kindText = thread.kind == .research ? "Deep Research スレッド" : "通常会話スレッド"
        let relative = relativeDateText(for: thread.updatedAt)
        let absolute = absoluteDateText(for: thread.updatedAt)
        return "\(kindText)\n\n\(thread.title)\n\n最終更新: \(relative)（\(absolute)）"
    }

    private func relativeDateText(for date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func absoluteDateText(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.locale = Locale(identifier: "ja_JP")
        return formatter.string(from: date)
    }
}

/// スレッド名変更用のシンプルなシート。
private struct ThreadRenameSheet: View {
    let originalTitle: String
    @Binding var draftTitle: String
    let onConfirm: () -> Void
    let onCancel: () -> Void
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("スレッド名を変更")
                .font(.system(size: 16, weight: .semibold))
            Text("変更前: \(originalTitle)")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(.secondary)
            TextField("新しい名前", text: $draftTitle)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit(onConfirm)
            HStack {
                Spacer()
                Button("キャンセル", role: .cancel, action: onCancel)
                    .keyboardShortcut(.escape, modifiers: [])
                Button("変更", action: onConfirm)
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 360)
        .onAppear { fieldFocused = true }
    }
}

struct StudioTopBarView: View {
    let currentThread: AICoachService.ChatThreadSummary?
    let presentationMode: AIStudioPresentationMode
    let modelChipTitle: String
    let isModelReady: Bool
    let onToggleSidebar: () -> Void
    let onOpenInspector: (() -> Void)?
    let onOpenSettings: () -> Void
    let onCreateNewChat: () -> Void
    let onClearConversation: () -> Void

    private var title: String {
        switch presentationMode {
        case .home:
            return "AI Studio"
        case .conversation:
            return currentThread?.title ?? "会話"
        case .result:
            return currentThread?.title ?? "Deep Research"
        }
    }

    private var subtitle: String {
        switch presentationMode {
        case .home:
            return "必要なときだけ深く調べられます"
        case .conversation:
            return "通常会話"
        case .result:
            return "Deep Research"
        }
    }

    private var topBarGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.28, green: 0.55, blue: 1.0),
                Color(red: 0.55, green: 0.30, blue: 1.0)
            ],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    private var modeIcon: String {
        switch presentationMode {
        case .home: return "sparkles"
        case .conversation: return "bubble.left.and.bubble.right.fill"
        case .result: return "doc.text.magnifyingglass"
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            Button(action: onToggleSidebar) {
                Image(systemName: "sidebar.leading")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary.opacity(0.75))
                    .frame(width: 34, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white.opacity(0.05))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(studioLineColor, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .help("サイドバーを開閉")
            .accessibilityLabel("サイドバーを開閉")

            // モードアイコンバッジ
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.blue.opacity(0.22), Color.purple.opacity(0.14)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 30, height: 30)
                Image(systemName: modeIcon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(topBarGradient)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(studioMutedText)
                    .tracking(0.3)
            }

            Spacer(minLength: 0)

            // Model chip — green dot + name pill
            HStack(spacing: 5) {
                Circle()
                    .fill(isModelReady ? Color(red: 0.20, green: 0.82, blue: 0.35) : Color.orange)
                    .frame(width: 6, height: 6)
                Text(modelChipTitle)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundColor(studioText3)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(studioBg3)
            .overlay(
                Capsule(style: .continuous)
                    .stroke(studioLineColor, lineWidth: 1)
            )
            .clipShape(Capsule(style: .continuous))

            QueryOptionsMenu(
                onCreateNewChat: onCreateNewChat,
                onOpenSettings: onOpenSettings,
                onOpenInspector: onOpenInspector,
                onClearConversation: onClearConversation
            )
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background(
            VStack(spacing: 0) {
                Spacer()
                studioLineColor.frame(height: 1)
            }
        )
    }
}

struct SearchHeaderView: View {
    @StateObject private var localSupportModelManager = LocalSupportModelManager.shared
    @StateObject private var webSearch = OllamaWebSearchService.shared
    @Binding var searchQuery: String
    @Binding var isWebEnabled: Bool
    @Binding var isDeepResearchRequested: Bool
    let selectedReasoningMode: ReasoningMode
    let selectedThinkingLevel: ThinkingLevel
    @Binding var advancedSettings: GemmaAdvancedSettings
    @Binding var showAdvancedSettings: Bool
    @Binding var selectedPhotos: [PhotosPickerItem]
    let attachedImageCount: Int
    /// 添付ドキュメント (PDF / テキスト等)。SearchHeaderView は表示・削除のみ行う。
    @Binding var selectedFileAttachments: [ChatFileAttachment]
    let isLoading: Bool
    let runtimeStatusSummary: String
    let supportRuntimeStatusSummary: String
    let onSelectReasoningMode: (ReasoningMode) -> Void
    let onSelectThinkingLevel: (ThinkingLevel) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void
    @State private var showGenerationTuning = false
    @State private var showSafetyThresholdDetails = false
    @State private var showToolCatalog = false
    @State private var documentImporterPresented: Bool = false
    @State private var documentImportError: String?
    @FocusState private var searchFieldFocused: Bool

    /// `.fileImporter` の結果を受けて、各 URL からテキストを抽出した `ChatFileAttachment` を `selectedFileAttachments` に積む。
    /// プロンプトインジェクション対策のサニタイズは `ChatFileAttachmentLoader.load` 内で行われる。
    private func handleDocumentImport(result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            documentImportError = "ファイルを選択できませんでした: \(error.localizedDescription)"
        case .success(let urls):
            var newAttachments: [ChatFileAttachment] = []
            var errors: [String] = []
            for url in urls {
                // 1 リクエストの上限を超える分はスキップ。
                let alreadyAttached = selectedFileAttachments.count + newAttachments.count
                if alreadyAttached >= FileAttachmentLimits.maxFilesPerRequest {
                    errors.append("一度に添付できるのは \(FileAttachmentLimits.maxFilesPerRequest) 件までです: \(url.lastPathComponent) はスキップしました。")
                    continue
                }
                do {
                    let attachment = try ChatFileAttachmentLoader.load(from: url)
                    newAttachments.append(attachment)
                } catch {
                    errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            if !newAttachments.isEmpty {
                selectedFileAttachments.append(contentsOf: newAttachments)
            }
            if !errors.isEmpty {
                documentImportError = errors.joined(separator: "\n")
            }
        }
    }

    // MARK: - 共有グラデーション
    private var composerAccentGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.28, green: 0.55, blue: 1.0),
                Color(red: 0.55, green: 0.30, blue: 1.0)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: "sparkle.magnifyingglass")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(composerAccentGradient)
                    TextField("何を知りたいですか？", text: $searchQuery, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 17, weight: .medium))
                        .lineLimit(1...6)
                        .focused($searchFieldFocused)
                        .submitLabel(.send)
                        .onSubmit {
                            dismissKeyboardAndSubmit()
                        }
                        // Enter のみ → 送信 / Shift+Enter → 改行
                        // axis: .vertical の TextField は Return キーで改行する挙動だが、
                        // macOS チャット UI 慣行に合わせて Enter で送信に倒す。
                        .onKeyPress(keys: [.return]) { press in
                            if press.modifiers.contains(.shift) {
                                // Shift+Enter は SwiftUI の標準改行に任せる
                                return .ignored
                            }
                            dismissKeyboardAndSubmit()
                            return .handled
                        }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 15)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(searchQuery.isEmpty ? 0.10 : 0.22),
                                    Color.white.opacity(0.06)
                                ],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )

                Button(action: isLoading ? onCancel : dismissKeyboardAndSubmit) {
                    ZStack {
                        // 外側ソフトグロー
                        Circle()
                            .fill(composerAccentGradient)
                            .frame(width: 44, height: 44)
                            .blur(radius: isLoading ? 10 : 6)
                            .opacity(isLoading ? 0.55 : 0.35)

                        // メインボタン
                        Image(systemName: isLoading ? "stop.fill" : "arrow.up")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 40, height: 40)
                            .background(composerAccentGradient)
                            .clipShape(Circle())
                            .overlay(
                                Circle()
                                    .stroke(Color.white.opacity(0.2), lineWidth: 0.6)
                            )
                    }
                }
                .buttonStyle(.plain)
                .disabled(!isLoading && searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachedImageCount == 0)
                .help(isLoading ? "出力を停止" : "送信（Enter）。Shift+Enter で改行。")
                .accessibilityLabel(isLoading ? "出力を停止" : "送信")
            }

            HStack(spacing: 10) {
                if selectedReasoningMode == .fast && !isDeepResearchRequested {
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.72)) {
                            isWebEnabled.toggle()
                        }
                    } label: {
                        HStack(spacing: 8) {
                            ZStack {
                                Capsule()
                                    .fill(Color.white.opacity(0.14))
                                    .frame(width: 30, height: 18)
                                Capsule()
                                    .fill(composerAccentGradient)
                                    .frame(width: 30, height: 18)
                                    .opacity(isWebEnabled ? 1 : 0)
                            }
                            .overlay(alignment: isWebEnabled ? .trailing : .leading) {
                                Circle()
                                    .fill(.white)
                                    .frame(width: 13, height: 13)
                                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                                    .padding(2.5)
                            }
                            Text("Webを使う")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(isWebEnabled ? .primary : studioMutedText)
                        }
                    }
                    .buttonStyle(.plain)
                    .help(isWebEnabled
                          ? "Fast の Web検索オン: Ollama Web Search で最新情報を補完します。"
                          : "Fast の Web検索オフ: Gemma 4 の内部知識のみで回答します。")
                }

                // 思考モード + Deep Research を 1 つに統合した Menu。
                // 旧 UI では「Deep Research トグル」「モード Menu」「Thinking 詳細度トグル」が
                // 横並びだったが、混乱しやすかったので 1 つのドロップダウンにまとめた。
                Menu {
                    Section("思考モード") {
                        ForEach(ReasoningMode.allCases) { mode in
                            Button {
                                if isDeepResearchRequested {
                                    isDeepResearchRequested = false
                                }
                                onSelectReasoningMode(mode)
                            } label: {
                                let isActive = !isDeepResearchRequested && selectedReasoningMode == mode
                                Label {
                                    HStack {
                                        Text(mode.displayName)
                                        if isActive {
                                            Spacer()
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                } icon: {
                                    Image(systemName: mode.iconName)
                                }
                            }
                        }
                    }
                    if selectedReasoningMode == .thinking && !isDeepResearchRequested {
                        Section("Thinking 詳細度") {
                            ForEach(ThinkingLevel.allCases) { level in
                                Button {
                                    onSelectThinkingLevel(level)
                                } label: {
                                    let isActive = selectedThinkingLevel == level
                                    Label {
                                        HStack {
                                            Text(level.displayName)
                                            if isActive {
                                                Spacer()
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    } icon: {
                                        Image(systemName: level == .extended ? "wand.and.stars" : "sparkles")
                                    }
                                }
                            }
                        }
                    }
                    Section("徹底調査") {
                        Button {
                            isDeepResearchRequested.toggle()
                        } label: {
                            Label {
                                HStack {
                                    Text("Deep Research")
                                    if isDeepResearchRequested {
                                        Spacer()
                                        Image(systemName: "checkmark")
                                    }
                                }
                            } icon: {
                                Image(systemName: "sparkles.rectangle.stack.fill")
                            }
                        }
                    }
                } label: {
                    let modeLabel: String = isDeepResearchRequested
                        ? "Deep Research"
                        : (selectedReasoningMode == .thinking
                            ? "\(selectedReasoningMode.displayName) ・ \(selectedThinkingLevel.displayName)"
                            : selectedReasoningMode.displayName)
                    let modeIcon: String = isDeepResearchRequested
                        ? "sparkles.rectangle.stack.fill"
                        : selectedReasoningMode.iconName
                    // `.menuStyle(.borderlessButton)` がデフォルトで chevron を付与するため、
                    // 重複を避けて Label のみを並べる。
                    Label(modeLabel, systemImage: modeIcon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(isDeepResearchRequested ? .white : .primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background {
                            if isDeepResearchRequested {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(composerAccentGradient)
                            } else {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.white.opacity(0.05))
                            }
                        }
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(
                                    isDeepResearchRequested ? Color.white.opacity(0.22) : studioLineColor,
                                    lineWidth: 1
                                )
                        )
                        .shadow(
                            color: isDeepResearchRequested ? Color.purple.opacity(0.35) : .clear,
                            radius: 8, x: 0, y: 2
                        )
                }
                .menuStyle(.borderlessButton)
                .animation(.easeInOut(duration: 0.2), value: isDeepResearchRequested)
                .help("思考モードと Deep Research を 1 か所で切替できます。Deep Research は複数回の検索・サブエージェントで徹底調査します。")
                .accessibilityLabel("思考モードを選択")

                // 画像とドキュメントの両方を選べる Menu。
                // - 画像: Gemma 4 マルチモーダル直接入力。
                // - ドキュメント: Gemma 4 26B Web 読解で要約してから evidence として注入。
                //   いずれも内容は PromptInjectionDefense でサニタイズ済み。
                let totalAttached = attachedImageCount + selectedFileAttachments.count
                Menu {
                    Section("添付の種類") {
                        // 画像
                        PhotosPicker(selection: $selectedPhotos, matching: .images) {
                            Label("画像を追加 (Gemma 4 が直接読む)", systemImage: "photo.on.rectangle")
                        }
                        // ドキュメント
                        Button {
                            documentImporterPresented = true
                        } label: {
                            Label("ドキュメントを追加 (Gemma 4 26B が要約)", systemImage: "doc.text")
                        }
                    }
                    if !selectedFileAttachments.isEmpty {
                        Section("添付中のドキュメント") {
                            ForEach(selectedFileAttachments) { file in
                                Button {
                                    selectedFileAttachments.removeAll(where: { $0.id == file.id })
                                } label: {
                                    Label("削除: \(file.filename)", systemImage: "minus.circle")
                                }
                            }
                        }
                    }
                } label: {
                    Label(totalAttached > 0 ? "ファイル \(totalAttached)" : "ファイルを追加", systemImage: "paperclip")
                        .font(.system(size: 13, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(studioLineColor, lineWidth: 1)
                )
                .cornerRadius(12)
                .help(totalAttached > 0
                      ? "添付 \(totalAttached) 件 (画像 \(attachedImageCount) / ドキュメント \(selectedFileAttachments.count))。ドキュメントは Gemma 4 26B が要約してから本体に渡されます。"
                      : "画像 / PDF / テキストを添付できます。ドキュメントは Web 検索結果と同じパイプライン (Gemma 4 26B) で読解されます。")
                .fileImporter(
                    isPresented: $documentImporterPresented,
                    allowedContentTypes: [
                        .pdf, .plainText, .text, .rtf,
                        .commaSeparatedText, .json, .html, .sourceCode, .data
                    ],
                    allowsMultipleSelection: true
                ) { result in
                    handleDocumentImport(result: result)
                }
                .alert(
                    "ファイル読み込みエラー",
                    isPresented: Binding(
                        get: { documentImportError != nil },
                        set: { newValue in if !newValue { documentImportError = nil } }
                    ),
                    presenting: documentImportError
                ) { _ in
                    Button("OK") { documentImportError = nil }
                } message: { message in
                    Text(message)
                }

                // Gemma 詳細設定はギアアイコンのみ。ホバーで内容を説明。
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showAdvancedSettings.toggle()
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(showAdvancedSettings ? .white : .primary.opacity(0.85))
                        .frame(width: 34, height: 34)
                        .background {
                            if showAdvancedSettings {
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .fill(composerAccentGradient)
                            } else {
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .fill(Color.white.opacity(0.05))
                            }
                        }
                        .overlay(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .stroke(
                                    showAdvancedSettings
                                        ? Color.white.opacity(0.22)
                                        : studioLineColor,
                                    lineWidth: 1
                                )
                        )
                        .shadow(
                            color: showAdvancedSettings
                                ? Color.purple.opacity(0.30) : .clear,
                            radius: 6, x: 0, y: 2
                        )
                }
                .buttonStyle(.plain)
                .help(showAdvancedSettings
                      ? "Gemma 詳細設定を閉じる"
                      : "Gemma 詳細設定 (安全フィルタ・ツール・温度など)。通常は変更不要です。")
                .accessibilityLabel(showAdvancedSettings ? "Gemma 詳細設定を閉じる" : "Gemma 詳細設定")

                Spacer(minLength: 0)
            }

            if !isDeepResearchRequested {
                HStack(spacing: 8) {
                    Image(systemName: selectedReasoningMode.iconName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(studioMutedText)
                    Text(selectedReasoningMode.recommendedUseText
                         + (selectedReasoningMode == .thinking
                            ? (selectedThinkingLevel == .extended ? " ・ 拡張: 補助モデル併用" : " ・ 標準")
                            : ""))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(studioMutedText)
                    Spacer(minLength: 0)
                }
            }

            if isDeepResearchRequested {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(studioMutedText)
                    Text("Deep Research では速度指定より検索・根拠集め・レポート統合を優先します。")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(studioMutedText)
                    Spacer(minLength: 0)
                }
            }

            if showAdvancedSettings {
                advancedSettingsPanel
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 6)
        .onAppear {
            webSearch.refreshConfiguredSecrets()
        }
    }

    private func dismissKeyboardAndSubmit() {
        searchFieldFocused = false
        dismissAIStudioKeyboard()
        onSubmit()
    }

    private var advancedSettingsPanel: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Gemma 4 の詳細")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.primary)
                        Text("通常は Auto のままで使い、必要な時だけ Gemma 4 の組み込み安全カテゴリとツールを細かく調整します。")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundColor(studioMutedText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Text(runtimeStatusSummary)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(studioMutedText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.04))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(studioLineColor, lineWidth: 1)
                        )
                        .cornerRadius(10)
                }

                HStack(spacing: 8) {
                    settingsSummaryPill(title: "安全", value: advancedSettings.safetyProfile.displayName)
                    settingsSummaryPill(title: "温度", value: advancedSettings.temperatureSummary)
                    settingsSummaryPill(
                        title: "ツール",
                        value: advancedSettings.allowToolUsage ? "\(enabledToolCount)/\(AIToolCatalog.toolNames.count)" : "オフ"
                    )
                    settingsSummaryPill(title: "補助", value: supportModelStatusTitle)
                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Gemma 3 270M 補助モデル")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(studioMutedText)

                    Text("Deep Research の planner / auditor / architect 専用です。Gemma 4 とは別スロットで管理します。")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(studioMutedText)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(supportRuntimeStatusSummary)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(.primary.opacity(0.92))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.035))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(studioLineColor, lineWidth: 1)
                        )
                        .cornerRadius(12)

                    HStack(spacing: 10) {
                        Button(localSupportModelPrimaryActionTitle) {
                            performLocalSupportModelPrimaryAction()
                        }
                        .buttonStyle(.borderedProminent)

                        Button("削除") {
                            localSupportModelManager.removeInstalledModel()
                        }
                        .buttonStyle(.bordered)
                        .disabled(localSupportModelManager.installedModelURL == nil && !localSupportModelManager.isDownloading)
                    }

                    if localSupportModelManager.isDownloading, let progress = localSupportModelManager.progressValue {
                        VStack(alignment: .leading, spacing: 6) {
                            ProgressView(value: progress)
                                .progressViewStyle(.linear)
                            Text("受信: \(ByteCountFormatter.string(fromByteCount: localSupportModelManager.downloadedBytes, countStyle: .file)) / \(localSupportModelManager.expectedBytes > 0 ? ByteCountFormatter.string(fromByteCount: localSupportModelManager.expectedBytes, countStyle: .file) : "不明")")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(studioMutedText)
                            let progressDetails = [localSupportModelManager.estimatedRemainingSummary, localSupportModelManager.transferRateSummary]
                                .compactMap { $0 }
                                .joined(separator: " ・ ")
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            if !progressDetails.isEmpty {
                                Text(progressDetails)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(studioMutedText)
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("AI ブラウジング")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(studioMutedText)

                    Toggle("検索後に上位ページ本文まで読む", isOn: webBrowsingEnabledBinding)
                        .font(.system(size: 12, weight: .medium))

                    Text(webSearch.webBrowsingStatusSummary)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(studioMutedText)
                        .fixedSize(horizontal: false, vertical: true)

                    Toggle("Web本文を Gemma 4 で読む", isOn: gemmaWebReaderEnabledBinding)
                        .font(.system(size: 12, weight: .medium))
                        .disabled(!webSearch.webBrowsingEnabled)

                    Text(webSearch.hasGemmaWebReaderAPIKey ? "Gemma 4 Web読解を使用" : "Gemma 4 Web読解は準備中です。")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(webSearch.hasGemmaWebReaderAPIKey ? studioMutedText : .orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Gemma 4 の組み込み安全設定")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(studioMutedText)

                    Picker("安全プリセット", selection: safetyProfileBinding) {
                        ForEach(GemmaSafetyProfile.allCases) { profile in
                            Text(profile.displayName).tag(profile)
                        }
                    }
                    .pickerStyle(.menu)

                    Text(advancedSettings.safetyProfile.detailText)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(studioMutedText)
                        .fixedSize(horizontal: false, vertical: true)

                    DisclosureGroup(isExpanded: $showSafetyThresholdDetails) {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                            ForEach(GemmaSafetyCategory.allCases) { category in
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(category.displayName)
                                            .font(.system(size: 11.5, weight: .semibold))
                                            .foregroundColor(.primary)
                                        Spacer(minLength: 0)
                                        Picker(category.displayName, selection: safetyThresholdBinding(for: category)) {
                                            ForEach(GemmaSafetyThreshold.allCases) { threshold in
                                                Text(threshold.displayName).tag(threshold)
                                            }
                                        }
                                        .labelsHidden()
                                        .pickerStyle(.menu)
                                    }

                                    Text(category.detailText)
                                        .font(.system(size: 10.5, weight: .medium))
                                        .foregroundColor(studioMutedText)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(10)
                                .background(Color.white.opacity(0.035))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(studioLineColor, lineWidth: 1)
                                )
                                .cornerRadius(12)
                            }
                        }
                        .padding(.top, 8)
                    } label: {
                        HStack {
                            Text("カテゴリ別のしきい値")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundColor(.primary)
                            Spacer(minLength: 0)
                            Text(showSafetyThresholdDetails ? "閉じる" : "開く")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(studioMutedText)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("検索と回答")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(studioMutedText)

                    Toggle("事実確認系は検索を優先する", isOn: requireSearchBinding)
                    Toggle("Deep Research では外部ソースを必須にする", isOn: requireExternalSourcesBinding)
                    Toggle("ツールなしでも直接回答を許可する", isOn: allowDirectAnswersBinding)
                    Toggle("tool call は JSON のみを優先する", isOn: strictJSONBinding)
                }
                .font(.system(size: 12, weight: .medium))

                DisclosureGroup(isExpanded: $showGenerationTuning) {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("温度を自動で決める", isOn: automaticTemperatureBinding)
                            .font(.system(size: 12, weight: .medium))

                        if !advancedSettings.useAutomaticTemperature {
                            HStack {
                                Text("手動温度")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(studioMutedText)
                                Spacer(minLength: 0)
                                Text(String(format: "%.2f", advancedSettings.clampedTemperature))
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundColor(.primary)
                            }
                            Slider(value: temperatureBinding, in: 0 ... 1.2, step: 0.05)
                                .tint(.blue)
                        }

                        Text("通常は Auto のままで十分です。高速は低め、Thinking は標準、高精度は少し高めに自動調整します。")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundColor(studioMutedText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 8)
                } label: {
                    HStack {
                        Text("高度な生成設定")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(studioMutedText)
                        Spacer(minLength: 0)
                        Text("温度 \(advancedSettings.temperatureSummary)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(studioMutedText)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("推論加速 (投機デコード)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(studioMutedText)
                        Spacer(minLength: 0)
                        Text(advancedSettings.speculativeDecodingMode.displayName)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(studioMutedText)
                    }

                    Picker("投機デコード方式", selection: speculativeDecodingModeBinding) {
                        ForEach(availableSpeculativeDecodingModes, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()

                    Text(advancedSettings.speculativeDecodingMode.detailText)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(studioMutedText)
                        .fixedSize(horizontal: false, vertical: true)

                    if showsSpeculativeDecodingFallbackHint {
                        Text("バンドルされた llama-server がこのモードに対応していない場合は、自動的に n-gram 推測または OFF にフォールバックします。")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.orange.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12)
                .background(Color.white.opacity(0.035))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(studioLineColor, lineWidth: 1)
                )
                .cornerRadius(12)

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("ツール")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(studioMutedText)
                        Spacer(minLength: 0)
                        Toggle("使用する", isOn: allowToolUsageBinding)
                            .toggleStyle(.switch)
                            .font(.system(size: 12, weight: .semibold))
                    }

                    HStack(spacing: 12) {
                        Stepper(value: maxToolRoundsBinding, in: 1 ... 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("最大ツール往復")
                                    .font(.system(size: 11.5, weight: .semibold))
                                Text("\(advancedSettings.clampedMaxToolRounds) 回")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(studioMutedText)
                            }
                        }

                        Stepper(value: maxSearchRoundsBinding, in: 1 ... 16) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("最大検索ラウンド")
                                    .font(.system(size: 11.5, weight: .semibold))
                                Text("\(advancedSettings.clampedMaxSearchRounds) 回")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(studioMutedText)
                            }
                        }
                    }

                    if advancedSettings.allowToolUsage {
                        DisclosureGroup(isExpanded: $showToolCatalog) {
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                                ForEach(AIToolCatalog.toolNames, id: \.self) { toolName in
                                    VStack(alignment: .leading, spacing: 6) {
                                        Toggle(AIToolCatalog.displayName(forToolNamed: toolName), isOn: toolEnabledBinding(toolName))
                                            .font(.system(size: 11.5, weight: .semibold))
                                        Text(AIToolCatalog.summary(forToolNamed: toolName))
                                            .font(.system(size: 10.5, weight: .medium))
                                            .foregroundColor(studioMutedText)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .padding(10)
                                    .background(Color.white.opacity(0.035))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .stroke(studioLineColor, lineWidth: 1)
                                    )
                                    .cornerRadius(12)
                                }
                            }
                            .padding(.top, 8)
                        } label: {
                            HStack {
                                Text("ツール詳細")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundColor(.primary)
                                Spacer(minLength: 0)
                                Text(showToolCatalog ? "閉じる" : "開く")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(studioMutedText)
                            }
                        }
                    } else {
                        Text("ツールを止めると、Gemma は会話だけで返します。検索や Python、会話検索は呼ばれません。")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundColor(studioMutedText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(14)
            .padding(.trailing, 4)
        }
        .frame(minHeight: 220, maxHeight: 420)
        .background(Color.white.opacity(0.045))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(studioLineColor, lineWidth: 1)
        )
        .cornerRadius(16)
    }

    private var supportModelStatusTitle: String {
        if supportRuntimeStatusSummary.localizedCaseInsensitiveContains("使えます") {
            return "利用可"
        }
        if supportRuntimeStatusSummary.localizedCaseInsensitiveContains("未導入") {
            return "未導入"
        }
        if supportRuntimeStatusSummary.localizedCaseInsensitiveContains("失敗") {
            return "要確認"
        }
        return "準備中"
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

    private var safetyProfileBinding: Binding<GemmaSafetyProfile> {
        Binding(
            get: { advancedSettings.safetyProfile },
            set: { newValue in
                advancedSettings.safetyProfile = newValue
                if newValue != .custom {
                    advancedSettings.safetyThresholds = GemmaAdvancedSettings.presetThresholds(for: newValue)
                }
            }
        )
    }

    private var automaticTemperatureBinding: Binding<Bool> {
        Binding(
            get: { advancedSettings.useAutomaticTemperature },
            set: { newValue in
                advancedSettings.useAutomaticTemperature = newValue
            }
        )
    }

    private var temperatureBinding: Binding<Double> {
        Binding(
            get: { advancedSettings.clampedTemperature },
            set: { newValue in
                advancedSettings.temperature = newValue
            }
        )
    }

    private var allowToolUsageBinding: Binding<Bool> {
        Binding(
            get: { advancedSettings.allowToolUsage },
            set: { newValue in
                advancedSettings.allowToolUsage = newValue
            }
        )
    }

    private var strictJSONBinding: Binding<Bool> {
        Binding(
            get: { advancedSettings.strictJSONToolCalls },
            set: { newValue in
                advancedSettings.strictJSONToolCalls = newValue
            }
        )
    }

    private var allowDirectAnswersBinding: Binding<Bool> {
        Binding(
            get: { advancedSettings.allowDirectAnswersWithoutTools },
            set: { newValue in
                advancedSettings.allowDirectAnswersWithoutTools = newValue
            }
        )
    }

    private var requireSearchBinding: Binding<Bool> {
        Binding(
            get: { advancedSettings.requireSearchForFactualQueries },
            set: { newValue in
                advancedSettings.requireSearchForFactualQueries = newValue
            }
        )
    }

    private var requireExternalSourcesBinding: Binding<Bool> {
        Binding(
            get: { advancedSettings.requireExternalSourcesInDeepResearch },
            set: { newValue in
                advancedSettings.requireExternalSourcesInDeepResearch = newValue
            }
        )
    }

    private var webBrowsingEnabledBinding: Binding<Bool> {
        Binding(
            get: { webSearch.webBrowsingEnabled },
            set: { newValue in
                webSearch.updateWebBrowsingEnabled(newValue)
            }
        )
    }

    private var gemmaWebReaderEnabledBinding: Binding<Bool> {
        Binding(
            get: { webSearch.gemmaWebReaderEnabled },
            set: { newValue in
                webSearch.updateGemmaWebReaderEnabled(newValue)
            }
        )
    }

    private var maxToolRoundsBinding: Binding<Int> {
        Binding(
            get: { advancedSettings.clampedMaxToolRounds },
            set: { newValue in
                advancedSettings.maxToolRounds = newValue
            }
        )
    }

    private var maxSearchRoundsBinding: Binding<Int> {
        Binding(
            get: { advancedSettings.clampedMaxSearchRounds },
            set: { newValue in
                advancedSettings.maxSearchRounds = newValue
            }
        )
    }

    private var speculativeDecodingModeBinding: Binding<SpeculativeDecodingMode> {
        Binding(
            get: { advancedSettings.speculativeDecodingMode },
            set: { newValue in
                advancedSettings.speculativeDecodingMode = newValue
            }
        )
    }

    /// バンドル llama-server が実際にサポートする投機デコードモードのみを Picker に並べる。
    /// 結果は capability キャッシュ済みで安価。`auto` と `off` は常に表示される。
    private var availableSpeculativeDecodingModes: [SpeculativeDecodingMode] {
        LocalAssistantRuntimeBridge.shared.availableSpeculativeDecodingModes()
    }

    /// 現在の選択がバンドル llama-server で利用不可能な場合にフォールバック説明を出す。
    private var showsSpeculativeDecodingFallbackHint: Bool {
        let current = advancedSettings.speculativeDecodingMode
        guard current != .off, current != .auto else { return false }
        let available = availableSpeculativeDecodingModes
        return available.contains(current) == false
    }

    private func toolEnabledBinding(_ toolName: String) -> Binding<Bool> {
        Binding(
            get: { advancedSettings.enabledTools[toolName] ?? true },
            set: { newValue in
                var updated = advancedSettings.enabledTools
                updated[toolName] = newValue
                advancedSettings.enabledTools = updated
            }
        )
    }

    private func safetyThresholdBinding(for category: GemmaSafetyCategory) -> Binding<GemmaSafetyThreshold> {
        Binding(
            get: { advancedSettings.safetyThreshold(for: category) },
            set: { newValue in
                var updated = advancedSettings.safetyThresholds
                updated[category.rawValue] = newValue
                advancedSettings.safetyThresholds = updated
                if advancedSettings.safetyProfile != .custom {
                    advancedSettings.safetyProfile = .custom
                }
            }
        )
    }

    private var enabledToolCount: Int {
        AIToolCatalog.toolNames.filter { advancedSettings.isToolEnabled($0) }.count
    }

    private func settingsSummaryPill(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(studioMutedText)
            Text(value)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.04))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(studioLineColor, lineWidth: 1)
        )
        .cornerRadius(10)
    }
}

struct QueryOptionsMenu: View {
    let onCreateNewChat: () -> Void
    let onOpenSettings: () -> Void
    let onOpenInspector: (() -> Void)?
    let onClearConversation: () -> Void
    @State private var showClearConfirmation = false

    var body: some View {
        Menu {
            Button("新しいチャット", action: onCreateNewChat)
            Button("会話を消す", role: .destructive) {
                showClearConfirmation = true
            }
            Button("設定", action: onOpenSettings)
            if let onOpenInspector {
                Button("補助パネル", action: onOpenInspector)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 32, height: 32)
        }
        .menuStyle(.borderlessButton)
        .help("メニュー")
        .accessibilityLabel("会話メニュー")
        .confirmationDialog(
            "この会話を削除しますか？",
            isPresented: $showClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("会話を削除", role: .destructive, action: onClearConversation)
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("このスレッドのメッセージがすべて消えます。元に戻せません。")
        }
    }
}

// (`ThinkingLevelToggle` は入力欄統合 Menu に吸収済み。
//  バインディングと表示は SearchHeaderView 側の Menu で行う。)

struct HomePromptView: View {
    @Binding var query: String
    let onSelectExample: (String) -> Void
    let onSubmit: () -> Void
    let recentThreads: [AICoachService.ChatThreadSummary]
    let modelStatus: String

    @ObservedObject private var localModelManager = LocalAssistantModelManager.shared

    private let categories: [(String, String, Color, [String])] = [
        // 調べる — accent purple
        ("調べる", "sparkle.magnifyingglass", Color(red: 0.53, green: 0.38, blue: 0.93),
         ["Gemma 4 とは？", "量子コンピュータの仕組み"]),
        // 要約する — warm amber
        ("要約する", "text.alignleft", Color(red: 0.93, green: 0.73, blue: 0.44),
         ["この話題を3行で要約", "要点だけ教えて"]),
        // 比較する — neutral slate
        ("比較する", "square.split.2x1.fill", Color(red: 0.62, green: 0.70, blue: 0.82),
         ["M3 と M4 を比較", "SwiftUI と UIKit の違い"]),
        // 学習する — ok green
        ("学習する", "graduationcap.fill", Color(red: 0.28, green: 0.82, blue: 0.60),
         ["中学生向けに説明", "テスト用にまとめる"])
    ]

    @State private var orbBreathe: CGFloat = 1.0
    @State private var ring1Scale: CGFloat = 1.0
    @State private var ring1Opacity: Double = 0.55
    @State private var ring2Scale: CGFloat = 1.0
    @State private var ring2Opacity: Double = 0.55

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                Spacer(minLength: 40)

                VStack(spacing: 20) {
                    // ── Animated orb ──────────────────────────────────────
                    ZStack {
                        // Ring 1 — slow pulse
                        Circle()
                            .stroke(studioAccent.opacity(ring1Opacity), lineWidth: 1)
                            .frame(width: 96, height: 96)
                            .scaleEffect(ring1Scale)
                            .blur(radius: 0.5)

                        // Ring 2 — offset delay pulse
                        Circle()
                            .stroke(studioAccentHi.opacity(ring2Opacity), lineWidth: 1)
                            .frame(width: 96, height: 96)
                            .scaleEffect(ring2Scale)
                            .blur(radius: 0.5)

                        // Outer glow
                        Circle()
                            .fill(
                                RadialGradient(
                                    colors: [studioAccent.opacity(0.32), Color.clear],
                                    center: .center,
                                    startRadius: 0,
                                    endRadius: 72
                                )
                            )
                            .frame(width: 144, height: 144)
                            .blur(radius: 12)
                            .scaleEffect(orbBreathe)

                        // Main orb — warm gradient
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        studioAccent.opacity(0.28),
                                        studioWarm.opacity(0.12)
                                    ],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 96, height: 96)
                            .overlay(
                                Circle()
                                    .stroke(
                                        LinearGradient(
                                            colors: [
                                                Color.white.opacity(0.28),
                                                studioAccent.opacity(0.18)
                                            ],
                                            startPoint: .topLeading, endPoint: .bottomTrailing
                                        ),
                                        lineWidth: 1
                                    )
                            )
                            .scaleEffect(orbBreathe)

                        // Sparkle icon
                        Image(systemName: "sparkles")
                            .font(.system(size: 34, weight: .light))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [studioAccentHi, studioWarm],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }
                    .onAppear {
                        // Orb breathe — 6s loop
                        withAnimation(.easeInOut(duration: 3.0).repeatForever(autoreverses: true)) {
                            orbBreathe = 1.06
                        }
                        // Ring 1 — 4s loop
                        withAnimation(.easeOut(duration: 2.0).repeatForever(autoreverses: false)) {
                            ring1Scale = 1.35
                            ring1Opacity = 0.0
                        }
                        // Ring 2 — 4s loop, 2s offset
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            withAnimation(.easeOut(duration: 2.0).repeatForever(autoreverses: false)) {
                                ring2Scale = 1.35
                                ring2Opacity = 0.0
                            }
                        }
                    }

                    VStack(spacing: 6) {
                        Text("何を\u{200B}お手伝い\u{200B}しましょうか？")
                            .font(.system(size: 28, weight: .bold))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [studioText1, studioWarm.opacity(0.85)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                )
                            )
                        Text("ローカル Gemma で安全に・素早く考えます")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundColor(studioText3)
                    }
                }

                if let progress = localModelManager.modelLoadProgress {
                    ModelLoadProgressBanner(progress: progress)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                    ForEach(categories, id: \.0) { category in
                        PromptCategoryCard(
                            title: category.0,
                            icon: category.1,
                            accentColor: category.2,
                            examples: category.3,
                            onSelect: onSelectExample
                        )
                    }
                }

                Spacer(minLength: 20)
            }
            .frame(maxWidth: 680)
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity)
            .animation(.easeInOut(duration: 0.2), value: localModelManager.modelLoadProgress)
        }
    }
}

struct ModelLoadProgressBanner: View {
    let progress: LocalAssistantLoadProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: progress.isDone ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(progress.isDone ? .green : .blue)
                Text(progress.isDone ? "準備完了" : "\(LocalAssistantModelProfile.modelName) を読み込み中")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(Int((progress.fraction * 100).rounded()))%")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundColor(.secondary)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.15))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Color.blue, Color.purple],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(6, geo.size.width * CGFloat(progress.fraction)))
                        .animation(.easeOut(duration: 0.25), value: progress.fraction)
                }
            }
            .frame(height: 6)

            Text(progress.message)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.appSecondaryBackground.opacity(0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        )
    }
}

private struct SuggestButton: View {
    let example: String
    let accentColor: Color
    let onSelect: (String) -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: { onSelect(example) }) {
            HStack(spacing: 6) {
                Text(example)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(isHovering ? studioText1 : studioText1.opacity(0.80))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(accentColor.opacity(isHovering ? 0.9 : 0.55))
                    .offset(x: isHovering ? 1.5 : 0, y: isHovering ? -1.5 : 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovering ? studioBg4 : Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isHovering ? accentColor.opacity(0.25) : studioLineColor, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovering)
    }
}

struct PromptCategoryCard: View {
    let title: String
    let icon: String
    let accentColor: Color
    let examples: [String]
    let onSelect: (String) -> Void
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Card header
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(accentColor.opacity(0.18))
                        .frame(width: 26, height: 26)
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(accentColor)
                }
                Text(title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(studioText1)
            }

            // Suggest buttons
            VStack(alignment: .leading, spacing: 5) {
                ForEach(examples, id: \.self) { example in
                    SuggestButton(example: example, accentColor: accentColor, onSelect: onSelect)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            studioBg3.opacity(isHovering ? 1.0 : 0.85),
                            studioBg2.opacity(isHovering ? 1.0 : 0.85)
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    isHovering
                        ? accentColor.opacity(0.30)
                        : studioLineColor,
                    lineWidth: 1
                )
        )
        .shadow(
            color: isHovering ? accentColor.opacity(0.18) : .clear,
            radius: 14, x: 0, y: 4
        )
        .scaleEffect(isHovering ? 1.015 : 1.0)
        .onHover { isHovering = $0 }
        .animation(.spring(response: 0.35, dampingFraction: 0.72), value: isHovering)
    }
}

private struct ResearchRecentThreadsCard: View {
    let threads: [AICoachService.ChatThreadSummary]
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("最近のスレッド")
                .font(.system(size: 14, weight: .bold))
            if threads.isEmpty {
                Text("まだ会話がありません。")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(studioMutedText)
            } else {
                ForEach(threads) { thread in
                    Button(action: { onSelect(thread.title) }) {
                        Text(thread.title)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(studioLineColor, lineWidth: 1)
        )
        .cornerRadius(18)
    }
}

private struct ResearchModelStatusCard: View {
    let status: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("現在の AI 状態")
                .font(.system(size: 14, weight: .bold))
            Text(status)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundColor(studioMutedText)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(studioLineColor, lineWidth: 1)
        )
        .cornerRadius(18)
    }
}

struct ConversationPageView: View {
    let messages: [AICoachService.ChatMessage]
    let isLoading: Bool
    let liveThoughtPreview: String?
    let liveRawThoughtStream: String
    let liveExecutionStatus: LocalExecutionStatusUpdate?
    let liveResponsePreview: String
    let onTapDetails: (AICoachService.ChatMessage) -> Void
    let onTapResponseAction: (AICoachService.ResponseAction) -> Void
    var onRegenerate: ((AICoachService.ChatMessage) -> Void)? = nil

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    ForEach(messages) { message in
                        AIMessageRowView(
                            message: message,
                            onTapDetails: { onTapDetails(message) },
                            onTapResponseAction: onTapResponseAction,
                            onRegenerate: onRegenerate.map { handler in
                                { handler(message) }
                            }
                        )
                    }

                    // isLoading = true になった瞬間から常に表示
                    if isLoading {
                        AIThinkingRow(
                            executionStatus: liveExecutionStatus,
                            thoughtPreview: liveThoughtPreview,
                            rawThoughtStream: liveRawThoughtStream,
                            responsePreview: trimmedLiveResponsePreview
                        )
                        .id("live-preview")
                    }
                }
                .padding(.horizontal, 2)
                .padding(.bottom, 60)
            }
            .onChange(of: messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("live-preview", anchor: .bottom)
                }
            }
            .onChange(of: liveResponsePreview) { _, _ in
                proxy.scrollTo("live-preview", anchor: .bottom)
            }
            .onChange(of: isLoading) { _, newValue in
                if newValue {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("live-preview", anchor: .bottom)
                    }
                }
            }
        }
    }

    private var trimmedLiveResponsePreview: String {
        liveResponsePreview.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// ローディング中に常に表示される AI 応答プレースホルダー行。
/// 送信直後からドットが動き、思考テキストはリアルタイムで展開表示される。
private struct AIThinkingRow: View {
    let executionStatus: LocalExecutionStatusUpdate?
    let thoughtPreview: String?
    let rawThoughtStream: String
    let responsePreview: String

    /// 持続表示と同じ PerplexityFlowListView を live でも使うため、
    /// thoughtTimeline (@Published) を直接観察する。
    @ObservedObject private var aiCoach = AICoachService.shared

    @State private var isThinkingExpanded = true
    @State private var isSearchTraceExpanded = true
    @State private var rememberedThinkingText = ""
    @State private var didUserToggleThinking = false

    /// Gemma 4 ツリー (#4) では search 中も thinking 中も「これまでの履歴」を全部見せる方が分かりやすいので、
    /// thinking テキストの有無だけで判定する。 (以前は `isSearchEngineStage` を見て検索中は thinking 非表示にしていたが、
    /// 「Gemma 4 の中に VIUK Search Engine と Gemma 4 Thinking が両方並ぶ」という流れには合わなかったため除去)
    private var hasThinking: Bool {
        return !thinkingDisplayText.isEmpty
    }
    private var hasSearchTrace: Bool { !searchTraceItems.isEmpty }
    /// 親 "Gemma 4" カードを出す条件: 実行中の status があれば、少なくとも 1 つは子ステップが存在するはず。
    private var hasGemma4Flow: Bool {
        executionStatus != nil || hasThinking || hasSearchTrace
    }
    private var isStreaming: Bool { !responsePreview.isEmpty }
    private var isActivelyThinking: Bool {
        guard !isSearchEngineStage, !currentThinkingText.isEmpty else { return false }
        guard let stage = executionStatus?.stage else { return false }
        return stage == .preparing || stage == .searchPlanning || stage == .thinking
    }
    private var isSearchEngineStage: Bool {
        if executionStatus?.stage == .searching {
            return true
        }
        let runner = executionStatus?.runnerLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return runner.localizedCaseInsensitiveContains("VIUK Search Engine")
    }
    private var thinkingDisplayText: String {
        let live = currentThinkingText
        if !live.isEmpty { return live }
        return rememberedThinkingText
    }
    private var currentThinkingText: String {
        // 検索中も thinking テキストが既に入っていれば隠さない (Gemma 4 ツリー表示で同時に並べるため)
        let raw = rawThoughtStream.trimmingCharacters(in: .whitespacesAndNewlines)
        if let displayable = displayableGemma4ThinkingText(raw) {
            return displayable
        }
        // rawThoughtStream はサービス層の displayableGemma4ThinkingPreview を通過済みだが、
        // ビュー側の二重フィルタ (looksLikeGenericThinkingPreamble 等) で消える場合がある。
        // サービス層で検証済みの thoughtPreview にフォールバックする。
        if let preview = thoughtPreview?.trimmingCharacters(in: .whitespacesAndNewlines),
           !preview.isEmpty {
            if let displayable = displayableGemma4ThinkingText(preview) {
                return displayable
            }
            if !rememberedThinkingText.isEmpty { return rememberedThinkingText }
        }
        if !raw.isEmpty, !rememberedThinkingText.isEmpty { return rememberedThinkingText }
        return ""
    }
    private var searchTraceItems: [String] {
        guard isSearchEngineStage else { return [] }
        let detail = executionStatus?.detail.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = executionStatus?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var items: [String] = []
        if !detail.isEmpty {
            let detailLines = detail
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if detailLines.contains(where: { $0.contains(":") || $0.contains("：") }) {
                items.append(contentsOf: detailLines)
            } else {
                let queries = detail
                    .components(separatedBy: "/")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                if queries.count > 1 {
                    items.append(contentsOf: queries.enumerated().map { index, query in
                        "検索語 \(index + 1): \(query)"
                    })
                } else {
                    items.append("検索語: \(detail)")
                }
            }
        } else if !title.isEmpty {
            items.append("目的: \(title)")
        }
        // 「実行: VIUK Search Engine」「経過: 13s」は親カード側で既に出ているため、
        // 内部のステップとしては検索語 / 目的だけを並べ、重複表記を消す。
        return stableUniqueItems(items)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 持続表示と同じ PerplexityFlowListView を live でも使う。
            // 「Gemma 4」ヘッダ・縦線などの専用ラッパーは廃止し、
            // 検索 / Thinking / tool call が同じフラットなステップ列に並ぶようにした。
            if !aiCoach.thoughtTimeline.isEmpty {
                PerplexityFlowListView(
                    timeline: aiCoach.thoughtTimeline,
                    searchQueries: [], // queries は各 search step の detail から自動パースされる
                    sources: aiCoach.latestResultSources, // ライブ中も集まったソースを表示
                    thinkingText: thinkingDisplayText.isEmpty ? nil : thinkingDisplayText,
                    autoExpandLatest: true  // 新しいステップが来るたび自動展開 → streaming 中の thinking 段組みが常に見える
                )
            }

            // ── ストリーミングレスポンス (回答本文。フローの「外」= 結果そのもの) ──────────
            if isStreaming {
                StreamingTextWithCursor(text: responsePreview)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.top, 4)
        .onAppear {
            // 初期表示時に rawThoughtStream に既に値があれば保持する。
            // executionStatus 由来のプレースホルダ文言は保持しない（非 thinking モデルで残留する原因）。
            rememberedThinkingText = ""
            rememberThinkingTextIfNeeded(rawThoughtStream)
            isThinkingExpanded = hasThinking
        }
        .onChange(of: rawThoughtStream) { _, newValue in
            // ネイティブ thinking モデル（Gemma 4 等）の rawThoughtStream のみを記憶対象とする。
            // これにより、planning ステータスがついても残留せず、
            // ストリーミング開始時に rawThoughtStream が一時的に空になっても直前値を保持できる。
            rememberThinkingTextIfNeeded(newValue)
        }
        .onChange(of: thoughtPreview) { _, newValue in
            rememberThinkingTextIfNeeded(newValue ?? "")
        }
        .onChange(of: executionStatus?.stage) { _, newStage in
            // 新しいリクエスト開始（.preparing）時は前メッセージの thinking 痕跡を完全にクリア。
            // SwiftUI が同一 .id("live-preview") のため View を再利用するケースに備えた保険。
            if newStage == .preparing {
                rememberedThinkingText = ""
                didUserToggleThinking = false
                isThinkingExpanded = false
                isSearchTraceExpanded = true
            } else if newStage == .searching {
                isSearchTraceExpanded = true
            }
        }
        .onChange(of: hasThinking) { _, newVal in
            guard newVal, !didUserToggleThinking else { return }
            withAnimation(.easeInOut(duration: 0.18)) {
                isThinkingExpanded = true
            }
        }
    }

    /// 親「Gemma 4」カード。中に VIUK Search Engine + Thinking が縦に並ぶ。
    /// - ヘッダはステージ名 + 1 秒ごとに更新される経過時間
    /// - 子はそれぞれ既存の DisclosureGroup スタイルを継承
    @ViewBuilder
    private var gemma4FlowContainer: some View {
        VStack(alignment: .leading, spacing: 10) {
            gemma4FlowHeader

            // 子ステップ: 左側に縦線を引いて「Gemma 4 の中の流れ」感を出す。
            HStack(alignment: .top, spacing: 10) {
                Rectangle()
                    .fill(Color.blue.opacity(0.25))
                    .frame(width: 2)
                    .padding(.leading, 6)

                VStack(alignment: .leading, spacing: 10) {
                    if hasSearchTrace {
                        SearchTraceDisclosureCard(
                            title: "VIUK Search Engine",
                            items: searchTraceItems,
                            isActive: true,
                            isExpanded: $isSearchTraceExpanded
                        )
                    }
                    if hasThinking {
                        gemma4ThinkingChild
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.blue.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.blue.opacity(0.18), lineWidth: 1)
        )
    }

    /// 「Gemma 4 ● <ステージ名> ・ 12.3s」のような実行中ヘッダ。経過時間はライブ更新。
    @ViewBuilder
    private var gemma4FlowHeader: some View {
        HStack(spacing: 8) {
            StudioLoadingPulseDot(
                color: executionStatus?.stage.tintColor ?? .blue,
                isAnimating: executionStatus?.stage.isAnimated ?? false,
                baseSize: 10,
                pulseSize: 16
            )
            Text("Gemma 4")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.primary)
            if let stageLabel = currentStageLabel {
                Text("·")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(studioMutedText)
                Text(stageLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(executionStatus?.stage.tintColor ?? .blue)
            }
            Spacer(minLength: 0)
            // ライブ経過時間。AICoachService の liveExecutionStartedAt と TimelineView でティック。
            Gemma4FlowElapsedText()
        }
    }

    private var currentStageLabel: String? {
        guard let stage = executionStatus?.stage else { return nil }
        switch stage {
        case .preparing: return "準備中"
        case .routing: return "ルーティング"
        case .warmingRuntime: return "ランタイム準備"
        case .searchPlanning: return "検索計画"
        case .searching: return "検索中"
        case .loadingModel: return "モデル準備"
        case .thinking: return "思考中"
        case .generating, .streaming: return "回答中"
        case .completed: return "完了"
        case .failed: return "失敗"
        }
    }

    /// 「<Gemma 4 Thinking>」のサブカード。Gemma 4 ツリーの子として描画される。
    @ViewBuilder
    private var gemma4ThinkingChild: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    didUserToggleThinking = true
                    isThinkingExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isThinkingExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundColor(.purple)
                    Text("Gemma 4 の思考")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(.secondary)
                    if isActivelyThinking {
                        StudioThinkingDots(color: .secondary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)

            if isThinkingExpanded {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(thinkingDisplayText + (isActivelyThinking ? "▍" : ""))
                            .font(.system(size: 13.5, weight: .regular))
                            .foregroundColor(.secondary)
                            .lineSpacing(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .id("thought-end")
                    }
                    .frame(maxHeight: 160)
                    .onChange(of: thinkingDisplayText) { _, _ in
                        proxy.scrollTo("thought-end", anchor: .bottom)
                    }
                }
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

    private func rememberThinkingTextIfNeeded(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let displayable = displayableGemma4ThinkingText(trimmed) else { return }
        rememberedThinkingText = displayable
    }

    private func displayableGemma4ThinkingText(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !looksLikeStatusOnlyThinkingText(trimmed) else { return nil }
        let stripped = stripGenericThinkingPreambleLines(from: trimmed)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty else { return nil }
        guard !looksLikeStatusOnlyThinkingText(stripped) else { return nil }
        guard !looksLikeGenericThinkingPreamble(stripped) else { return nil }
        return stripped
    }

    private func looksLikeStatusOnlyThinkingText(_ text: String) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "…", with: "...")
            .lowercased()
        let statusOnly = [
            "回答前に状況を整理しています...",
            "回答前に状況を整理しています",
            "gemma 4 が回答前に論点を整理しています",
            "gemma 4 の reasoning を始める準備をしています",
            "gemma 4 が回答の構成を整理しています",
            "収集済み情報をレポートとして統合しています",
            "質問の意図、前提、答える順番を整理しています",
            "回答の構成と本文の流れを整理しています",
            "思考中",
            "推論中",
            "推論方針を整理中",
            "推論を整理中",
            "回答材料を整理中"
        ]
        return statusOnly.contains { normalized == $0 || normalized.hasPrefix($0 + "\n") }
    }

    private func stableUniqueItems(_ items: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for item in items {
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    private func looksLikeGenericThinkingPreamble(_ text: String) -> Bool {
        // Gemma 4 ネイティブ thinking では "analyze the user" / "desired response" 等の
        // フレーズが思考本文中にも自然に現れる。contains で全文検索すると本物の thinking まで
        // 握りつぶしてしまうため、短いプリアンブル 1〜2 行だけのテキストに限定する。
        let normalized = normalizedThinkingPreambleText(text)
        // 200 文字を超える思考テキストはプリアンブルではなく本物の思考。
        guard normalized.count < 200 else { return false }
        let prefixMarkers = [
            "to construct the desired response",
            "to construct the detailed answer",
            "construct the desired response",
            "construct the detailed answer",
            "thinking process to construct",
            "here is a thinking process",
            "here's a thinking process"
        ]
        if prefixMarkers.contains(where: { normalized.hasPrefix($0) }) {
            return true
        }
        return normalized.hasPrefix("analyze") || normalized.hasPrefix("1. analyze") || normalized.hasPrefix("1 analyze")
    }

    private func normalizedThinkingPreambleText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"[\*_`]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^[\s>\-•]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^\d+[\.)]\s*"#, with: "", options: .regularExpression)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func stripGenericThinkingPreambleLines(from text: String) -> String {
        var lines = text.components(separatedBy: .newlines)
        while let first = lines.first {
            let normalized = normalizedThinkingPreambleText(first)
            let isGeneric = normalized.isEmpty ||
                normalized.hasPrefix("to construct the desired response") ||
                normalized.hasPrefix("to construct the detailed answer") ||
                normalized.hasPrefix("here is a thinking process") ||
                normalized.hasPrefix("here's a thinking process") ||
                normalized.hasPrefix("thinking process to construct") ||
                normalized.hasPrefix("analyze") ||
                normalized.hasPrefix("analyze the user") ||
                normalized.hasPrefix("analyze the request") ||
                normalized.hasPrefix("analyze the question") ||
                normalized.hasPrefix("topic:") ||
                normalized.hasPrefix("\" (what is") ||
                normalized.hasPrefix("(what is") ||
                normalized.hasPrefix("format requirement") ||
                normalized.hasPrefix("structure requirement") ||
                normalized.hasPrefix("tool requirement") ||
                normalized.hasPrefix("determine the strategy") ||
                normalized.hasPrefix("formulate search") ||
                normalized.hasPrefix("the core subject") ||
                normalized.hasPrefix("i need ") ||
                normalized.hasPrefix("i must ") ||
                normalized.hasPrefix("given the ")
            guard isGeneric else { break }
            lines.removeFirst()
        }
        return lines.joined(separator: "\n")
    }
}

/// 「Gemma 4」ヘッダ用のライブ更新テキスト。AICoachService の `liveExecutionStartedAt` を読み、
/// TimelineView で 1 秒ごとに「経過 N.Ns / Ns」を再計算する。
/// Perplexity 風のフラットな step リスト。
/// - 1 行 = 1 ステップ。動詞 + 「中」「完了」の present-progressive 表現。
/// - 各行は chevron でその場展開できる。
/// - 検索ステップ ( type == .search ) はクエリ ・ ソースを含む。
/// - 他のステップ ( planning / supportModel / synthesis 等) は detail のみを展開時に表示。
private struct PerplexityFlowListView: View {
    let timeline: [ThoughtStep]
    /// 該当する検索ステップに紐づけるためのクエリ群。MVP では「最後の search-type ステップ」に全部寄せる。
    let searchQueries: [String]
    let sources: [AIResultSource]
    /// Gemma 4 の native thinking 全文 (rawThoughtStream)。timeline 末尾の synthesis ステップを
    /// 開くと、推論過程がそのまま読めるようにする (o3 の "Reasoned for Xs" を開いた状態に相当)。
    let thinkingText: String?
    /// 「N ステップ完了」のヘッダを表示するかどうか。
    var showsHeader: Bool = true
    /// Live 中: 最新ステップを自動展開し、streaming 中の thinking 段組みをそのまま見せる。
    /// 持続表示 (完了後) では false にしてユーザーが任意で開けるように。
    var autoExpandLatest: Bool = false
    @State private var expandedStepIDs: Set<UUID> = []
    @State private var isWholeListCollapsed: Bool = false
    @State private var lastAutoExpandedStepID: UUID?

    /// 毎回必ず出る定型 planning ステップ。ユーザーに見せても情報量がないため非表示にする。
    private static let boilerplateTitles: Set<String> = [
        "質問を分解中",
        "質問を振り分け",
        "Gemma 4 で応答を開始",
        "Gemma 4 で調査を開始",
        "Gemmaで要点整理",
        "Gemma 3 サブエージェントを起動",
        "Gemma 3 補助をスキップ",
        "Gemma 3 planner を起動",
        "Gemma 3 planner を実行中",
        "Gemma 3 planner を使えずスキップ",
        "Gemma 3 planner を反映",
    ]

    /// MVP のステップ→クエリ/ソース紐付け: timeline 内で最初に出現する .search ステップに集約。
    private var lastSearchStepID: UUID? {
        timeline.last(where: { $0.type == .search })?.id
    }

    /// 推論本文を貼り付ける先: 最後の synthesis (or finalization) ステップ。
    /// もし無ければ thinking 専用の合成ステップを足したいが、ここでは nil として落とす (=最後の任意ステップに表示)。
    private var thinkingHostStepID: UUID? {
        if let last = visibleSteps.last(where: { $0.type == .synthesis || $0.type == .finalization }) {
            return last.id
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsHeader {
                headerRow
                    .padding(.bottom, 6)
            }
            if !isWholeListCollapsed {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(visibleSteps.enumerated()), id: \.element.id) { index, step in
                        flowRow(
                            for: step,
                            isActive: autoExpandLatest && index == visibleSteps.count - 1,
                            showsConnector: index < visibleSteps.count - 1
                        )
                    }
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(studioLineColor, lineWidth: 1)
        )
        .onChange(of: latestTimelineStepID) { _, newID in
            guard autoExpandLatest, let id = newID, id != lastAutoExpandedStepID else { return }
            _ = expandedStepIDs.insert(id)
            lastAutoExpandedStepID = id
        }
        .onAppear {
            if autoExpandLatest, let id = latestTimelineStepID {
                _ = expandedStepIDs.insert(id)
                lastAutoExpandedStepID = id
            }
        }
    }

    /// 表示するステップ群 (定型 planning ステップを除外)。
    private var visibleSteps: [ThoughtStep] {
        timeline.filter { step in
            guard !Self.boilerplateTitles.contains(step.title) else { return false }
            guard !step.title.hasPrefix("ページ読解 ") else { return false }
            return true
        }
    }

    private var latestTimelineStepID: UUID? {
        visibleSteps.last?.id
    }

    private var headerRow: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                isWholeListCollapsed.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Text("\(visibleSteps.count) ステップ完了")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(studioMutedText)
                Image(systemName: isWholeListCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(studioMutedText)
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func flowRow(for step: ThoughtStep, isActive: Bool = false, showsConnector: Bool = false) -> some View {
        let isExpanded = expandedStepIDs.contains(step.id)
        let icon = iconName(for: step.type)
        let hasExpandableContent = stepHasExpandableContent(step)

        HStack(alignment: .top, spacing: 10) {
            // ── 左カラム: タイムラインのドット + 縦の連結線 ─────────────
            VStack(spacing: 0) {
                ZStack {
                    // アクティブ時のパルスハロー
                    if isActive {
                        Circle()
                            .fill(Color.accentColor.opacity(0.25))
                            .frame(width: 18, height: 18)
                            .blur(radius: 3)
                    }
                    Circle()
                        .stroke(isActive ? Color.accentColor : Color.white.opacity(0.25), lineWidth: isActive ? 2 : 1)
                        .frame(width: 10, height: 10)
                    Circle()
                        .fill(isActive ? Color.accentColor : Color.white.opacity(0.35))
                        .frame(width: 5, height: 5)
                    if isActive {
                        TimelineView(.periodic(from: .now, by: 0.1)) { context in
                            let progress = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                            Circle()
                                .stroke(Color.accentColor.opacity(0.5 * (1 - progress)), lineWidth: 1.5)
                                .frame(width: 10 + CGFloat(progress) * 16, height: 10 + CGFloat(progress) * 16)
                        }
                    }
                }
                .frame(width: 18, height: 18)
                .padding(.top, 8)

                if showsConnector {
                    Rectangle()
                        .fill(Color.white.opacity(0.12))
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 18)

            // ── 右カラム: 既存のヘッダ + 展開コンテンツ ───────────────
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    guard hasExpandableContent else { return }
                    withAnimation(.easeInOut(duration: 0.15)) {
                        if isExpanded {
                            _ = expandedStepIDs.remove(step.id)
                        } else {
                            _ = expandedStepIDs.insert(step.id)
                        }
                    }
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: icon)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundColor(isActive ? Color.accentColor : studioMutedText)
                            .frame(width: 16, alignment: .center)
                        Text(displayTitle(for: step))
                            .font(.system(size: 13, weight: isActive ? .semibold : .medium))
                            .foregroundColor(isActive ? .primary : .primary.opacity(0.85))
                            .lineLimit(1)
                        if isActive {
                            Text("進行中")
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundColor(Color.accentColor)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Capsule(style: .continuous).fill(Color.accentColor.opacity(0.14)))
                        }
                        Spacer(minLength: 0)
                        if hasExpandableContent {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(studioMutedText.opacity(0.7))
                        }
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .disabled(!hasExpandableContent)
                .background(
                    isActive
                        ? RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.accentColor.opacity(0.06))
                            .padding(.horizontal, -6)
                        : nil
                )

                if isExpanded {
                    expandedContent(for: step)
                        .padding(.leading, 25)
                        .padding(.bottom, 6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func displayTitle(for step: ThoughtStep) -> String {
        if step.type == .search, step.title.hasPrefix("外部検索") {
            return "外部検索"
        }
        if step.title == "Gemma 4 26B でページ読解" {
            return "上位ソースを読解"
        }
        return step.title
    }

    /// 検索系ステップで「+さらに N 件」を押したら全件展開する。
    @State private var expandedFullQuerySteps: Set<UUID> = []
    @State private var expandedFullSourceSteps: Set<UUID> = []
    /// Gemma 4 推論を「先頭ハイライト 3 段」だけ見せている状態を抜けて全段表示する。
    /// 一度展開した後も、再度「畳む」ボタンで戻せる。
    @State private var expandedFullThinking: Bool = false

    @ViewBuilder
    private func expandedContent(for step: ThoughtStep) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // 検索ステップは detail を「クエリ列」としてパースしてクリック可能な行に。
            // それ以外のステップは detail をプレーンテキストで描画 (Gemma 3 270M planner の説明等)。
            if step.type == .search {
                searchStepBody(for: step)
            } else if let detail = step.detail?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(studioMutedText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // 推論過程の表示。最後の synthesis / finalization ステップを開くと
            // Gemma 4 の reasoning_content 全文がそのまま読める (o3 の "Reasoned for X" を開いた状態に相当)。
            // 「Thinking は常時表示してね」というユーザー要望に従い、英語 preamble フィルタを外し、
            // 非空ならそのまま見せる。完了後 (persisted) は別経路でクリーン版を出す。
            if step.id == thinkingHostStepID,
               let thinking = thinkingText?.trimmingCharacters(in: .whitespacesAndNewlines),
               !thinking.isEmpty {
                if step.type != .synthesis && step.type != .finalization {
                    Divider().opacity(0.12).padding(.vertical, 2)
                }
                thinkingTextBlock(thinking)
            }
        }
    }

    /// 「Gemma 4 の推論」を **段落ごとの bullet リスト** として表示する。
    /// 背景: OpenAI o1 / o3 は raw chain-of-thought を出さず、`reasoning.summary` で
    /// segmented なサマリだけ提示する方針 (理由: 認知負荷・安全性・競合 distillation 防止)。
    /// 業界スタンダードに寄せて、ここでは raw thinking を「段落単位の bullet」へ
    /// 分割表示することで、長大な文塊を読まされる感じを軽減する。
    @ViewBuilder
    private func thinkingTextBlock(_ text: String) -> some View {
        let segments = thinkingSegments(from: text)
        let isFull = expandedFullThinking
        // o3 / GPT-5.5 Thinking と同様、デフォルトは「先頭 2-3 段だけ」のハイライトのみ。
        // ユーザーが「+ さらに表示」を押したら全段、それも「△ 畳む」で戻せる。
        let visibleLimit = 3
        let visible = isFull ? segments : Array(segments.prefix(visibleLimit))
        let overflow = segments.count - visible.count

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundColor(studioMutedText)
                    .frame(width: 12)
                Text("Gemma 4 の思考ステップ")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(studioMutedText)
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(visible.enumerated()), id: \.offset) { _, segment in
                    HStack(alignment: .top, spacing: 8) {
                        Text("•")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(studioMutedText)
                            .frame(width: 8, alignment: .leading)
                        Text(segment)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundColor(.primary.opacity(0.85))
                            .lineSpacing(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
                if !isFull, overflow > 0 {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            expandedFullThinking = true
                        }
                    } label: {
                        Text("+ さらに \(overflow) 段の思考を表示")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundColor(.blue.opacity(0.85))
                            .padding(.leading, 16)
                    }
                    .buttonStyle(.plain)
                } else if isFull, segments.count > visibleLimit {
                    // 一度開いたら畳めるようにする。閉じた後に再度開くのも可能。
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            expandedFullThinking = false
                        }
                    } label: {
                        Text("△ 思考を畳む")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundColor(studioMutedText)
                            .padding(.leading, 16)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(studioLineColor, lineWidth: 1)
            )
        }
    }

    /// 推論本文を「段落 / 思考のまとまり」に分割する。
    /// - 二重改行 (\n\n) を基本セパレータ
    /// - 1 セグメントが 500 字超なら 1 文単位でさらに細かく分割 (長大段落の救済)
    /// - 空白・短すぎ (8 字未満) のセグメントは除外
    private func thinkingSegments(from raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let coarse = trimmed.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var result: [String] = []
        for chunk in coarse {
            if chunk.count > 500 {
                // 長い 1 段落は 「。」「. 」「!」「?」 で文単位に細分化する。
                let sentenceSplit = chunk
                    .replacingOccurrences(of: "。", with: "。|")
                    .replacingOccurrences(of: "！", with: "！|")
                    .replacingOccurrences(of: "？", with: "？|")
                    .split(separator: "|")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                // 文単位は短すぎるので 2 文ずつまとめる
                var buffer = ""
                for sentence in sentenceSplit {
                    if buffer.isEmpty {
                        buffer = sentence
                    } else if buffer.count + sentence.count < 280 {
                        buffer += sentence
                    } else {
                        result.append(buffer)
                        buffer = sentence
                    }
                }
                if !buffer.isEmpty { result.append(buffer) }
            } else {
                // ストリーミング中は短い断片 ("1." 等) でも消さずに表示する。
                result.append(chunk)
            }
        }
        return result
    }

    @ViewBuilder
    private func searchStepBody(for step: ThoughtStep) -> some View {
        // step.detail から実際のクエリ群を取り出す ("q1 / q2 / q3" 形式)。
        // 「最後の search ステップ」なら、全体の searchQueries / sources も合わせて表示する。
        let detailQueries: [String] = {
            guard let detail = step.detail?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !detail.isEmpty else { return [] }
            let separators: [Character] = ["·", "/", "、", ","]
            return detail.split(whereSeparator: { separators.contains($0) })
                .map { raw in
                    raw.trimmingCharacters(in: .whitespacesAndNewlines)
                        .replacingOccurrences(of: #"^round\s+\d+/\d+:\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
                }
                .filter { !$0.isEmpty }
        }()
        let allQueries = step.id == lastSearchStepID && !searchQueries.isEmpty
            ? searchQueries
            : detailQueries
        let allSources = step.id == lastSearchStepID ? sources : []
        let showAllQueries = expandedFullQuerySteps.contains(step.id)
        let showAllSources = expandedFullSourceSteps.contains(step.id)
        let queryDisplayLimit = 6
        let sourceDisplayLimit = 5
        let visibleQueries = showAllQueries ? allQueries : Array(allQueries.prefix(queryDisplayLimit))
        let visibleSources = showAllSources ? allSources : Array(allSources.prefix(sourceDisplayLimit))

        VStack(alignment: .leading, spacing: 5) {
            // クエリ行 (引用符付き)。
            ForEach(Array(visibleQueries.enumerated()), id: \.offset) { _, query in
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundColor(studioMutedText)
                        .frame(width: 12)
                    Text("\u{0022}\(query)\u{0022}")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(.primary.opacity(0.82))
                        .lineLimit(1)
                }
            }
            if !showAllQueries, allQueries.count > queryDisplayLimit {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        _ = expandedFullQuerySteps.insert(step.id)
                    }
                } label: {
                    Text("+ さらに \(allQueries.count - queryDisplayLimit) 件のクエリ")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(.blue.opacity(0.85))
                        .padding(.leading, 18)
                }
                .buttonStyle(.plain)
            }

            // クエリ群の下に「取得した出典」リスト。各行はクリックで開ける Link。
            if !visibleSources.isEmpty {
                Divider().opacity(0.12).padding(.vertical, 2)
                ForEach(visibleSources) { source in
                    sourceLinkRow(source: source)
                }
                if !showAllSources, allSources.count > sourceDisplayLimit {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            _ = expandedFullSourceSteps.insert(step.id)
                        }
                    } label: {
                        Text("+ さらに \(allSources.count - sourceDisplayLimit) 件のサイト")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundColor(.blue.opacity(0.85))
                            .padding(.leading, 18)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// 1 出典 = クリックでブラウザに開ける Link 行。タイトル + 小さなドメイン。
    @ViewBuilder
    private func sourceLinkRow(source: AIResultSource) -> some View {
        let target = safeWebURL(source.url)
        let titleText = source.title.isEmpty ? source.domain : source.title
        let row = HStack(spacing: 6) {
            Image(systemName: "globe")
                .font(.system(size: 10, weight: .regular))
                .foregroundColor(studioMutedText)
                .frame(width: 12)
            Text(titleText)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary.opacity(0.82))
                .lineLimit(1)
            Text(source.domain)
                .font(.system(size: 11, weight: .regular))
                .foregroundColor(studioMutedText)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        if let target {
            Link(destination: target) {
                row.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            row
        }
    }

    private func stepHasExpandableContent(_ step: ThoughtStep) -> Bool {
        let detail = step.detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !detail.isEmpty { return true }
        if step.id == lastSearchStepID, !searchQueries.isEmpty || !sources.isEmpty {
            return true
        }
        // 推論本文を持つ host ステップは「展開できる」扱い (o3 風)。
        if step.id == thinkingHostStepID,
           let thinking = thinkingText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !thinking.isEmpty {
            return true
        }
        return false
    }

    /// Gemma 4 の native thinking 冒頭に出る英語 preamble だけしか無い断片を判定。
    /// "1. **Analyze the" / "Thinking Process:" 等は UI に出すと不自然なので非表示にする。
    private func isBrokenEnglishPreambleFragment(_ text: String) -> Bool {
        let normalized = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"[\*_`#]+"#, with: "", options: .regularExpression)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count < 220 else { return false }
        let markers = [
            "1. analyze",
            "analyze the",
            "thinking process",
            "construct the desired response",
            "construct the detailed answer",
            "desired answer",
            "desired response",
            "here is a thinking process",
            "here's a thinking process"
        ]
        return markers.contains { normalized.hasPrefix($0) || normalized.contains($0) }
    }

    /// Perplexity 風: 全部アウトライン (.fill なし) + 同じ細さ。
    /// 「ぼってり」したカラフルバッジではなく、線画 1 種類で統一する。
    private func iconName(for type: ThoughtStepType) -> String {
        switch type {
        case .planning: return "lightbulb"
        case .search: return "globe"
        case .tool: return "wrench.adjustable"
        case .imageAnalysis: return "photo"
        case .supportModel: return "sparkles"
        case .synthesis, .finalization: return "text.bubble"
        }
    }

}


private struct Gemma4FlowElapsedText: View {
    @ObservedObject private var aiCoach = AICoachService.shared

    var body: some View {
        if let startedAt = aiCoach.liveExecutionStartedAt {
            TimelineView(.periodic(from: Date(), by: 1.0)) { context in
                Text(formatElapsed(now: context.date, startedAt: startedAt))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(studioMutedText)
            }
        } else if let snapshot = aiCoach.liveExecutionStatus?.elapsedText {
            Text(snapshot)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(studioMutedText)
        }
    }

    private func formatElapsed(now: Date, startedAt: Date) -> String {
        let elapsed = max(0, now.timeIntervalSince(startedAt))
        if elapsed < 10 {
            return String(format: "%.1fs", elapsed)
        }
        return "\(Int(elapsed.rounded()))s"
    }
}

private struct SearchTraceDisclosureCard: View {
    let title: String
    let items: [String]
    var isActive: Bool = false
    @Binding var isExpanded: Bool

    private var steps: [SearchTraceStep] {
        items.enumerated().map { index, item in
            SearchTraceStep(index: index, rawText: item)
        }
    }

    /// ChatGPT / Perplexity 風のコンパクト表示。
    /// - 縦線・大きなドット・「検索語 1, 検索語 2, ...」の繰り返しを廃止。
    /// - 検索クエリは「検索」1 行にチップ (pill) で並べる。
    /// - 各ステップは「アイコン + ラベル + 本文/チップ」の横並び 1 段。
    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(steps) { step in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: step.icon)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(step.tint)
                            .frame(width: 14, alignment: .center)
                        Text(step.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.primary.opacity(0.78))
                            .frame(width: 56, alignment: .leading)
                        if let chips = step.chips, !chips.isEmpty {
                            queryChipRow(chips)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text(step.body)
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundColor(studioMutedText)
                                .lineSpacing(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "globe")
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                if isActive {
                    StudioThinkingDots(color: studioMutedText)
                }
                Spacer(minLength: 0)
                // 件数表示: ステップ数 (旧実装は items.count をそのまま出していて、検索クエリ 5 件分が
                // 別行に膨らんでいた時の "28" のような不正確な数字が出ていた)。
                if steps.count > 1 {
                    Text("\(steps.count)")
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .foregroundColor(studioMutedText)
                }
            }
            .foregroundColor(studioMutedText)
        }
        .disclosureGroupStyle(.automatic)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.blue.opacity(0.055))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.blue.opacity(0.16), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// 検索クエリを全件チップで表示する。Deep Research の調査語を省略しない。
    @ViewBuilder
    private func queryChipRow(_ chips: [String]) -> some View {
        FlowLayout(chips, spacing: 6) { chip in
            Text(chip)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(.blue.opacity(0.95))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.blue.opacity(0.11))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.blue.opacity(0.22), lineWidth: 1)
                )
                .lineLimit(1)
        }
    }

    private struct SearchTraceStep: Identifiable {
        let id: Int
        let title: String
        let body: String
        /// 検索クエリ等を「pill 行」で表示する場合に使う。nil の場合は body をプレーンテキストで描画する。
        let chips: [String]?
        let icon: String
        let tint: Color

        init(index: Int, rawText: String) {
            id = index
            let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = trimmed.split(separator: ":", maxSplits: 1).map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let key = parts.first ?? ""
            let value = parts.count > 1 ? parts[1] : trimmed
            let lowerKey = key.lowercased()
            if key == "検索" || key.hasPrefix("検索語") {
                title = "検索"
                body = value
                // 「q1 · q2 · q3」or 「q1, q2, q3」or 「q1 / q2 / q3」を pill 列に分解。
                // live trace は " / " 区切り、persisted trace は " · " 区切り。
                let separators: [Character] = ["·", ",", "、", "/"]
                let split = value.split(whereSeparator: { separators.contains($0) })
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                chips = split.count >= 1 ? split : nil
                icon = "magnifyingglass"
                tint = .blue
            } else if key.hasPrefix("サイト") {
                title = "サイト"
                body = value
                chips = nil
                icon = "safari"
                tint = .cyan
            } else if key == "目的" || lowerKey.contains("rationale") {
                title = "目的"
                body = value
                chips = nil
                icon = "scope"
                tint = .orange
            } else if key == "経過" {
                title = "経過"
                body = value
                chips = nil
                icon = "timer"
                tint = .secondary
            } else {
                title = "確認"
                body = trimmed
                chips = nil
                icon = "checkmark.seal"
                tint = .secondary
            }
        }
    }
}

/// ストリーミング中のテキスト＋点滅カーソル。
private struct StreamingTextWithCursor: View {
    let text: String
    @State private var cursorVisible = true
    private let timer = Timer.publish(every: 0.52, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            MarkdownRenderView(text: normalizedStreamingMarkdown(text))
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(cursorVisible ? "▍" : " ")
                .font(.system(size: 16, weight: .regular))
                .foregroundColor(.blue)
        }
            .textSelection(.enabled)
            .onReceive(timer) { _ in
                cursorVisible.toggle()
            }
    }

    private func normalizedStreamingMarkdown(_ raw: String) -> String {
        var normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized = Self.dropTrailingPartialMarkdownLine(normalized)
        let boldCount = normalized.components(separatedBy: "**").count - 1
        if boldCount % 2 != 0 {
            normalized += "**"
        }
        return normalized
    }

    private static func dropTrailingPartialMarkdownLine(_ text: String) -> String {
        var lines = text.components(separatedBy: .newlines)
        guard let last = lines.last else { return text }
        let trimmed = last.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.allSatisfy({ $0 == "#" }), (1...3).contains(trimmed.count) {
            lines.removeLast()
            return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if trimmed == "**" || trimmed == "***" || trimmed == "---" {
            lines.removeLast()
            return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }
}

struct AIMessageRowView: View {
    let message: AICoachService.ChatMessage
    let onTapDetails: () -> Void
    let onTapResponseAction: (AICoachService.ResponseAction) -> Void
    var onRegenerate: (() -> Void)? = nil
    @ObservedObject private var aiCoach = AICoachService.shared
    @State private var copyFeedback: Bool = false
    @State private var isThinkingDisclosureExpanded: Bool = true
    @State private var isSearchTraceDisclosureExpanded: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if message.role == .user {
                HStack {
                    Spacer(minLength: 72)
                    Text(message.content)
                        .font(.system(size: 16, weight: .regular))
                        .foregroundColor(.primary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color.appSoftFill.opacity(0.9))
                        )
                        .frame(maxWidth: 560, alignment: .trailing)
                        .textSelection(.enabled)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    contentCard
                        .contextMenu {
                            if !copyableAssistantContent.isEmpty {
                                Button {
                                    copyAssistantContent()
                                } label: {
                                    Label("回答をコピー", systemImage: "doc.on.doc")
                                }
                            }
                            if onRegenerate != nil {
                                Button {
                                    onRegenerate?()
                                } label: {
                                    Label("もう一度生成", systemImage: "arrow.clockwise")
                                }
                            }
                    }
                    inlineSourceCard
                    persistedThinkingCard
                    persistedSearchTraceCard
                    AIMessageMetaBar(message: message, onTapDetails: onTapDetails)
                    assistantActionRow
                }
            }

            if message.role == .assistant {
                if let actions = message.responseActions, !actions.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(actions) { action in
                                Button(action.title) {
                                    onTapResponseAction(action)
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 13, weight: .semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(Color.white.opacity(0.05))
                                .overlay(
                                    Capsule(style: .continuous)
                                        .stroke(studioLineColor, lineWidth: 1)
                                )
                                .clipShape(Capsule(style: .continuous))
                            }
                        }
                    }
                }
            }
        }
    }

    /// 完了済み assistant メッセージのコピー対象。
    private var copyableAssistantContent: String {
        repairedAssistantDisplayContent(message.content)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func copyAssistantContent() {
        let text = copyableAssistantContent
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
        guard let debug = message.thoughtDetails?.debugDetails else { return nil }
        switch (debug.promptTokens, debug.completionTokens) {
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

    @ViewBuilder
    private var assistantActionRow: some View {
        HStack(spacing: 8) {
            studioActionPill(
                systemImage: copyFeedback ? "checkmark" : "doc.on.doc",
                title: copyFeedback ? "コピーしました" : "コピー",
                isDisabled: copyableAssistantContent.isEmpty
            ) {
                copyAssistantContent()
            }

            if let onRegenerate {
                studioActionPill(
                    systemImage: "arrow.clockwise",
                    title: "もう一度生成"
                ) {
                    onRegenerate()
                }
            }

            if let usageLabel = tokenUsageLabel {
                Text(usageLabel)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(studioMutedText)
            }

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func studioActionPill(
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
            .foregroundColor(isDisabled ? studioMutedText.opacity(0.4) : studioMutedText)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(studioLineColor, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }

    private var contentCard: some View {
        MarkdownRenderView(text: repairedAssistantDisplayContent(message.content))
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    @ViewBuilder
    private var inlineSourceCard: some View {
        if let page = message.resultPage, !page.sources.isEmpty {
            ResultSourcesInlineView(
                sources: page.sources,
                sourceStatus: page.sourceStatus,
                requiredSourceCount: page.requiredSourceCount,
                distinctSourceDomainCount: page.distinctSourceDomainCount,
                requiredDistinctDomainCount: page.requiredDistinctDomainCount
            )
            .padding(.top, 6)
        }
    }

    @ViewBuilder
    private var persistedThinkingCard: some View {
        if let thoughtDetails = message.thoughtDetails {
            let items = persistedThinkingItems(from: thoughtDetails)
            if shouldShowPersistedThinkingCard(details: thoughtDetails, items: items) {
                DisclosureGroup(isExpanded: $isThinkingDisclosureExpanded) {
                    VStack(alignment: .leading, spacing: 6) {
                        Button {
                            copyThinkingItems(items)
                        } label: {
                            Label(copyFeedback ? "コピーしました" : "Thinkingをコピー", systemImage: copyFeedback ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 11.5, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(studioMutedText)
                        .padding(.bottom, 2)

                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            Text(item)
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundColor(studioMutedText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "brain.head.profile")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Gemma 4 の思考")
                            .font(.system(size: 12.5, weight: .semibold))
                        if let durationText = formatThinkingDuration(thoughtDetails.thinkingDuration) {
                            Text(durationText)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundColor(studioMutedText)
                        }
                    }
                    .foregroundColor(studioMutedText)
                }
                .disclosureGroupStyle(.automatic)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.secondary.opacity(0.055))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contextMenu {
                    Button {
                        copyThinkingItems(items)
                    } label: {
                        Label("Thinkingをコピー", systemImage: "doc.on.doc")
                    }
                }
            }
        }
    }

    private func shouldShowPersistedThinkingCard(
        details: AICoachService.ResponseThoughtDetails,
        items: [String]
    ) -> Bool {
        guard !items.isEmpty else { return false }
        let executionName = details.executionDisplayName.lowercased()
        if executionName.contains("deep research") {
            return true
        }
        // 現在の選択モードではなく、このメッセージを生成した時の表示名で判定する。
        if executionName == "fast" || executionName == "fast + search" || executionName.contains("高速") {
            return false
        }
        return true
    }

    private func copyThinkingItems(_ items: [String]) {
        let text = items
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        guard !text.isEmpty else { return }
#if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
#else
        UIPasteboard.general.string = text
#endif
        copyFeedback = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copyFeedback = false
        }
    }

    private func persistedSearchTraceItems(from details: AICoachService.ResponseThoughtDetails) -> [String] {
        // 各カテゴリを 1 行だけにまとめる (ChatGPT / Perplexity 風)。
        // 旧実装は「検索語 1, 検索語 2, ..., 検索語 5」と 5 行に膨張させていたため、
        // ここで「検索: q1 · q2 · q3 · +N」の 1 行に圧縮し、UI 側でチップ化して描画する。
        var items: [String] = []
        if let rationale = details.debugDetails?.searchRationale?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rationale.isEmpty {
            items.append("目的: \(rationale)")
        }
        let queries = stableUniqueItems(
            (details.debugDetails?.searchQueries ?? []) +
            (details.debugDetails?.externalSearchQueries ?? [])
        )
        if !queries.isEmpty {
            // 検索クエリは 1 行にまとめる (UI 側で「・」分割してチップに展開する)
            items.append("検索: " + queries.joined(separator: " · "))
        }
        // 「確認したこと」系は重複排除し、最大 2 件まで。
        // 旧実装は同一文言が 2 回・3 回と並ぶケースがあった。
        let dedupedActivity = stableUniqueItems(details.searchActivity)
        items.append(contentsOf: dedupedActivity.prefix(2))
        return stableUniqueItems(items)
    }

    private func persistedThinkingItems(from details: AICoachService.ResponseThoughtDetails) -> [String] {
        // 取得元を順番に試す: rawStream > rawThoughtSummaries > displayThoughtSegments > detailedThoughtSummaries > thoughtSummaries。
        // どれか一つでも非空ならそれを採用 (rawStream は完全な思考全文なので最優先)。
        let stream = details.rawThoughtStream.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates: [String] = []
        if !stream.isEmpty {
            candidates = [stream]
        } else if !details.rawThoughtSummaries.isEmpty {
            candidates = details.rawThoughtSummaries
        } else if !details.displayThoughtSegments.isEmpty {
            candidates = details.displayThoughtSegments
        } else if !details.detailedThoughtSummaries.isEmpty {
            candidates = details.detailedThoughtSummaries
        } else if !details.thoughtSummaries.isEmpty {
            candidates = details.thoughtSummaries
        }
        guard !candidates.isEmpty else { return [] }
        var seen = Set<String>()
        var result: [String] = []
        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let displayText = cleanedPersistedGemma4ThinkingText(trimmed) else { continue }
            guard seen.insert(displayText).inserted else { continue }
            result.append(displayText)
        }
        return result
    }

    private func cleanedPersistedGemma4ThinkingText(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.lowercased()
        // 補助モデル (Gemma 3 270M planner 等) 由来の "思考" は別系統なので除外。
        // ここは substring 一致でよい (補助モデルが本文中で名前を出すケースは無い)。
        let blockedMarkers = [
            "gemma 3 planner",
            "270m",
            "補助モデル",
            "によるクエリ分解",
            "source backfill"
        ]
        if blockedMarkers.contains(where: { normalized.contains($0.lowercased()) }) {
            return nil
        }
        // UI スピナー文言の「丸ごとそのままが思考に流れ込んだ」ケースだけを除外する。
        // 旧実装は preamble フラグメント (analyze the user / construct the desired response 等) を
        // substring で弾いていたため、Gemma 4 の正規の思考冒頭が完了時に消える原因になっていた。
        // 完全一致 (前後空白許容) のみで判定する。
        let exactPlaceholders: Set<String> = [
            "回答前に状況を整理しています。",
            "回答前に状況を整理しています...",
            "回答前に論点を整理しています。",
            "検索前に調査観点を整理しています。",
            "検索結果を確認し、根拠として使える情報を選別しています。",
            "収集済み情報をレポートとして統合しています。",
            "gemma 4 の reasoning を始める準備をしています。",
            "本文を生成中",
            "回答を生成中",
            "思考中",
            "考えています",
            "考えています…",
            "考えています...",
            "gemma 4 thinking を受信中です。"
        ]
        guard !exactPlaceholders.contains(normalized) else { return nil }

        let stripped = stripPersistedThinkingPreambleLines(from: trimmed)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty else { return nil }
        guard !exactPlaceholders.contains(stripped.lowercased()) else { return nil }
        guard !looksLikeBrokenGenericThinkingFragment(stripped) else { return nil }
        return stripped
    }

    private func stripPersistedThinkingPreambleLines(from text: String) -> String {
        var lines = text.components(separatedBy: .newlines)
        while let first = lines.first {
            let normalized = normalizedThinkingPreambleText(first)
            let isGeneric = normalized.isEmpty ||
                normalized.hasPrefix("to construct the desired response") ||
                normalized.hasPrefix("to construct the detailed answer") ||
                normalized.hasPrefix("here is a thinking process") ||
                normalized.hasPrefix("here's a thinking process") ||
                normalized.hasPrefix("thinking process to construct") ||
                normalized.hasPrefix("analyze") ||
                normalized.hasPrefix("analyze the user") ||
                normalized.hasPrefix("analyze the request") ||
                normalized.hasPrefix("analyze the question") ||
                normalized.hasPrefix("topic:") ||
                normalized.hasPrefix("\" (what is") ||
                normalized.hasPrefix("(what is") ||
                normalized.hasPrefix("format requirement") ||
                normalized.hasPrefix("structure requirement") ||
                normalized.hasPrefix("tool requirement") ||
                normalized.hasPrefix("determine the strategy") ||
                normalized.hasPrefix("formulate search") ||
                normalized.hasPrefix("the core subject") ||
                normalized.hasPrefix("i need ") ||
                normalized.hasPrefix("i must ") ||
                normalized.hasPrefix("given the ")
            guard isGeneric else { break }
            lines.removeFirst()
        }
        return lines.joined(separator: "\n")
    }

    private func normalizedThinkingPreambleText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"[\*_`]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^[\s>\-•]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^\d+[\.)]\s*"#, with: "", options: .regularExpression)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func looksLikeBrokenGenericThinkingFragment(_ text: String) -> Bool {
        let normalized = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"[\*_`]+"#, with: "", options: .regularExpression)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count < 220 else { return false }
        let markers = [
            "1. analyze",
            "analyze the",
            "construct the desired response",
            "construct the detailed answer",
            "desired answer",
            "desired response"
        ]
        return markers.contains { normalized.hasPrefix($0) || normalized.contains($0) }
    }

    @ViewBuilder
    private var persistedSearchTraceCard: some View {
        if let thoughtDetails = message.thoughtDetails,
           !thoughtDetails.thoughtTimeline.isEmpty {
            // Perplexity 風: 各 ThoughtStep を 1 行のフラットステップとして並べる。
            // 検索ステップにだけ実クエリと出典ソースをひもづけて、その場で展開できるようにする。
            // 推論過程 (Gemma 4 native thinking) は最後の synthesis ステップに同梱して、
            // o3 の "Reasoned for Xs" を開いたときの体験に近づける。
            let queries = stableUniqueItems(
                (thoughtDetails.debugDetails?.searchQueries ?? []) +
                (thoughtDetails.debugDetails?.externalSearchQueries ?? [])
            )
            let sources = message.resultPage?.sources ?? []
            // 推論本文の取得元 (優先度順): rawThoughtStream → rawThoughtSummaries(joined) → detailedThoughtSummaries。
            let thinkingText: String? = {
                let candidates = [
                    thoughtDetails.rawThoughtStream,
                    thoughtDetails.rawThoughtSummaries.joined(separator: "\n\n"),
                    thoughtDetails.detailedThoughtSummaries.joined(separator: "\n\n")
                ]
                for candidate in candidates {
                    if let cleaned = cleanedPersistedGemma4ThinkingText(candidate) {
                        return cleaned
                    }
                }
                return nil
            }()
            PerplexityFlowListView(
                timeline: thoughtDetails.thoughtTimeline,
                searchQueries: queries,
                sources: sources,
                thinkingText: thinkingText
            )
        } else if let thoughtDetails = message.thoughtDetails {
            // タイムラインが空ならフォールバックで従来のリスト風カードを使う (旧データ互換)。
            let items = persistedSearchTraceItems(from: thoughtDetails)
            if !items.isEmpty {
                SearchTraceDisclosureCard(
                    title: "VIUK Search Engine",
                    items: items,
                    isExpanded: $isSearchTraceDisclosureExpanded
                )
            }
        }
    }

    private func stableUniqueItems(_ items: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for item in items {
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    private func repairedAssistantDisplayContent(_ text: String) -> String {
        let trimmed = normalizedAssistantDisplayText(text).trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.lowercased()
        let looksBroken =
            trimmed.isEmpty ||
            trimmed == "<|" ||
            trimmed == "|>" ||
            normalized.hasPrefix("<|assistant") ||
            normalized.hasPrefix("<|user") ||
            normalized.hasPrefix("<|system") ||
            trimmed.contains("<start_of_turn>") ||
            trimmed.contains("<end_of_turn>")

        if looksBroken {
            return "Gemma 4 の応答が壊れています。Gemma設定の「実行を確認」を押すか、もう一度送信してください。"
        }

        return displayFormattedAssistantContent(trimmed)
    }

    private func normalizedAssistantDisplayText(_ text: String) -> String {
        let invisibleScalarValues: Set<UInt32> = [
            0x200B, 0x200C, 0x200D, 0x200E, 0x200F,
            0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
            0x2060, 0x2066, 0x2067, 0x2068, 0x2069,
            0xFEFF
        ]

        let filtered = text.unicodeScalars.filter { scalar in
            if invisibleScalarValues.contains(scalar.value) {
                return false
            }
            if CharacterSet.illegalCharacters.contains(scalar) {
                return false
            }
            if CharacterSet.controlCharacters.contains(scalar),
               !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                return false
            }
            return true
        }

        var normalized = String(String.UnicodeScalarView(filtered))
            .replacingOccurrences(
                of: #"\u{001B}\[[0-9;?]*[ -/]*[@-~]"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?<![0-9A-Za-z])\[[0-9;]{1,12}[A-Za-z](?![0-9A-Za-z])"#,
                with: "",
                options: .regularExpression
            )

        let boldCount = normalized.components(separatedBy: "**").count - 1
        if boldCount % 2 != 0 {
            normalized += "**"
        }

        return normalized
    }

    @ViewBuilder
    private func assistantParagraphText(_ text: String) -> some View {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let mdOptions = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if looksLikeMarkdownFormattedAssistantContent(trimmed),
           let attributed = try? AttributedString(markdown: sanitizeMarkdownLinkSchemes(trimmed), options: mdOptions) {
            Text(attributed)
                .font(.system(size: 16, weight: .regular))
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(trimmed)
                .font(.system(size: 16, weight: .regular))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func looksLikeMarkdownFormattedAssistantContent(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // \n\n だけでは markdown とみなさない（通常の段落区切りを markdown レンダラーに渡すと
        // 段落間が広がりすぎるため）。明確な markdown 記法がある場合のみ true。
        return trimmed.contains("**") ||
            trimmed.contains("# ") ||
            trimmed.contains("### ") ||
            trimmed.contains("\n- ") ||
            trimmed.contains("\n1.") ||
            trimmed.contains("| ")
    }

    private func displayFormattedAssistantContent(_ text: String) -> String {
        // モデル出力はすでに適切に整形されている。
        // 人工的な段落分割は行わず、\r\n の正規化と前後トリムだけ行う。
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return highlightSourceCitations(in: normalized)
    }

    /// 本文中の `[S1]` / `[S1, S2]` / `[S1-S3]` 等の引用マークを markdown 太字 `**[S1]**`
    /// に変換して視認性を上げる。MarkdownRenderView が太字を強調表示するので
    /// ユーザーが「どこが引用か」を即座に把握できるようにする。
    private func highlightSourceCitations(in text: String) -> String {
        // パターン: 角括弧の中に S<数字> をカンマ/中黒/ハイフン/スペースで複数並べたもの。
        // 既に太字 (** で囲まれている) 場合は二重 ** を作らないため negative lookbehind で守る。
        let pattern = #"(?<!\*)\[\s*(S\d+(?:\s*[-,、・]\s*S\d+)*)\s*\](?!\*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let replaced = regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: "**[$1]**"
        )
        return replaced
    }

    private func structuredAssistantSections(from text: String) -> [StructuredAssistantSection]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let headingPattern = #"(?m)^(?:###\s+|[*]{2})([^*\n#]+?)(?:[*]{2})?\s*$"#
        guard let regex = try? NSRegularExpression(pattern: headingPattern) else {
            return nil
        }

        let nsRange = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        let matches = regex.matches(in: trimmed, range: nsRange)
        guard !matches.isEmpty else { return nil }

        var sections: [StructuredAssistantSection] = []
        for (index, match) in matches.enumerated() {
            guard let titleRange = Range(match.range(at: 1), in: trimmed) else { continue }
            let title = String(trimmed[titleRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }

            let bodyStart = Range(match.range, in: trimmed)?.upperBound ?? trimmed.endIndex
            let bodyEnd: String.Index = {
                if index + 1 < matches.count,
                   let nextRange = Range(matches[index + 1].range, in: trimmed) {
                    return nextRange.lowerBound
                }
                return trimmed.endIndex
            }()

            let body = String(trimmed[bodyStart..<bodyEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
            let paragraphs = body
                .components(separatedBy: "\n\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            sections.append(
                StructuredAssistantSection(
                    title: title,
                    paragraphs: paragraphs.isEmpty ? [body].filter { !$0.isEmpty } : paragraphs
                )
            )
        }

        return sections.isEmpty ? nil : sections
    }
}

private struct StructuredAssistantSection {
    let title: String
    let paragraphs: [String]
}

// MARK: - MarkdownRenderView
/// ChatGPT / Claude 風の Markdown ブロックレンダラー。
/// 見出し・リスト・コードブロック・段落を個別スタイルで描画する。
private struct MarkdownRenderView: View {
    let text: String

    // インライン記法（**太字** 等）を保持しつつ \n を改行として扱うオプション
    private static let inlineOpts = AttributedString.MarkdownParsingOptions(
        interpretedSyntax: .inlineOnlyPreservingWhitespace
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(parseBlocks(text).enumerated()), id: \.offset) { i, block in
                blockView(block, isFirst: i == 0)
            }
        }
        .foregroundColor(.primary)
    }

    // MARK: Block rendering

    @ViewBuilder
    private func blockView(_ block: Block, isFirst: Bool) -> some View {
        switch block {
        case .heading(let level, let raw):
            inlineText(raw)
                .font(headingFont(for: level))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, isFirst ? 0 : (level == 1 ? 14 : 10))
                .padding(.bottom, 3)

        case .paragraph(let raw):
            inlineText(raw)
                .font(.system(size: 16.5, weight: .regular))
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, isFirst ? 0 : 8)

        case .listItem(let raw):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
                    .frame(width: 12, alignment: .center)
                inlineText(raw)
                    .font(.system(size: 16.5, weight: .regular))
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, isFirst ? 0 : 3)

        case .numberedItem(let num, let raw):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(num).")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
                    .frame(minWidth: 22, alignment: .trailing)
                inlineText(raw)
                    .font(.system(size: 16.5, weight: .regular))
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, isFirst ? 0 : 3)

        case .codeBlock(let code):
            Text(code)
                .font(.system(size: 14, design: .monospaced))
                .foregroundColor(.primary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.top, isFirst ? 0 : 8)

        case .divider:
            Divider()
                .opacity(0.25)
                .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func inlineText(_ raw: String) -> some View {
        if let attr = try? AttributedString(markdown: sanitizeMarkdownLinkSchemes(raw), options: Self.inlineOpts) {
            Text(attr)
        } else {
            Text(raw)
        }
    }

    private func headingFont(for level: Int) -> Font {
        switch level {
        case 1:  return .system(size: 22, weight: .bold)
        case 2:  return .system(size: 19, weight: .bold)
        case 3:  return .system(size: 17, weight: .semibold)
        default: return .system(size: 16, weight: .semibold)
        }
    }

    // MARK: Parser

    private enum Block {
        case heading(level: Int, raw: String)
        case paragraph(raw: String)
        case listItem(raw: String)
        case numberedItem(num: Int, raw: String)
        case codeBlock(code: String)
        case divider
    }

    private func parseBlocks(_ source: String) -> [Block] {
        var result: [Block] = []
        var paraLines: [String] = []
        var codeLines: [String] = []
        var inCode = false

        func flushPara() {
            let joined = paraLines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { result.append(.paragraph(raw: joined)) }
            paraLines = []
        }

        for line in source.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)

            // コードフェンス
            if t.hasPrefix("```") {
                if inCode {
                    let code = codeLines.joined(separator: "\n")
                    if !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        result.append(.codeBlock(code: code))
                    }
                    codeLines = []; inCode = false
                } else {
                    flushPara(); inCode = true
                }
                continue
            }
            if inCode { codeLines.append(line); continue }

            // 見出し（長い順に評価）
            if t.hasPrefix("#### ") {
                flushPara(); result.append(.heading(level: 4, raw: String(t.dropFirst(5))))
            } else if t.hasPrefix("### ") {
                flushPara(); result.append(.heading(level: 3, raw: String(t.dropFirst(4))))
            } else if t.hasPrefix("## ") {
                flushPara(); result.append(.heading(level: 2, raw: String(t.dropFirst(3))))
            } else if t.hasPrefix("# ") {
                flushPara(); result.append(.heading(level: 1, raw: String(t.dropFirst(2))))
            }
            // 区切り線
            else if t == "---" || t == "***" || t == "___" {
                flushPara(); result.append(.divider)
            }
            // 箇条書き
            else if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("+ ") {
                flushPara(); result.append(.listItem(raw: String(t.dropFirst(2))))
            }
            // 番号付きリスト（"1. " 形式）
            else if let dotRange = t.range(of: ". "),
                    let num = Int(t[t.startIndex..<dotRange.lowerBound]),
                    num > 0 {
                flushPara()
                result.append(.numberedItem(num: num, raw: String(t[dotRange.upperBound...])))
            }
            // 空行 → 段落区切り
            else if t.isEmpty {
                flushPara()
            }
            // 通常テキスト
            else {
                paraLines.append(line)
            }
        }

        flushPara()
        if inCode && !codeLines.isEmpty {
            result.append(.codeBlock(code: codeLines.joined(separator: "\n")))
        }
        return result
    }
}

private func formattedResponseDurationText(_ duration: TimeInterval?) -> String? {
    guard let duration, duration.isFinite, duration > 0 else { return nil }
    if duration < 10 {
        return String(format: "応答 %.1f秒", duration)
    }
    return "応答 \(Int(duration.rounded()))秒"
}

struct AIMessageMetaBar: View {
    let message: AICoachService.ChatMessage
    let onTapDetails: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let summary = metaSummaryText {
                Text(summary)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(studioMutedText)
                    .lineLimit(1)
            }

            if let durationText = formattedResponseDurationText(message.thoughtDetails?.responseDuration) {
                Text(durationText)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(studioMutedText)
            }

            if message.thoughtDetails != nil || message.resultPage != nil {
                Button("右側で見る", action: onTapDetails)
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(studioMutedText)
            }
        }
    }

    /// メタバーの 1 行サマリ。「回答前に状況を整理しています...」のような
    /// UI スピナー文言がスナップショットに紛れ込んでいた場合は除外する。
    private var metaSummaryText: String? {
        guard let details = message.thoughtDetails else { return nil }
        let placeholderMarkers: Set<String> = [
            "回答前に状況を整理しています。",
            "回答前に状況を整理しています...",
            "回答前に論点を整理しています。",
            "検索前に調査観点を整理しています。",
            "検索結果を確認し、根拠として使える情報を選別しています。",
            "収集済み情報をレポートとして統合しています。",
            "本文を生成中",
            "回答を生成中",
            "考えています",
            "考えています…",
            "考えています...",
            "gemma 4 thinking を受信中です。",
            "gemma 4 の reasoning を始める準備をしています。"
        ]
        let candidates = details.displayThoughtSegments
            + details.thoughtSummaries
            + details.searchActivity
            + details.processingLogSummary
        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if placeholderMarkers.contains(trimmed.lowercased()) { continue }
            return trimmed
        }
        return nil
    }
}

struct ResultPageView: View {
    let viewModel: ResultPageViewModel
    @Binding var thinkingViewModel: ThinkingPanelViewModel
    let isLoading: Bool
    let loadingState: AIResearchLoadingState
    let liveExecutionStatus: LocalExecutionStatusUpdate?
    let liveThoughtPreview: String?
    let onAction: (AIResultAction) -> Void
    let onRelatedQuestionTap: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let page = viewModel.page {
                    ResultReasoningView(
                        viewModel: $thinkingViewModel,
                        loadingState: loadingState,
                        isLoading: isLoading,
                        liveThoughtPreview: liveThoughtPreview
                    )
                    ResultContentView(sections: page.sections, sources: page.sources)
                    ResearchFollowUpSectionView(messages: viewModel.followUpMessages)
                    ActionBarView(actions: page.actions, onTap: onAction)

                    if !page.relatedQuestions.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("関連する質問")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(studioMutedText)
                                .tracking(0.4)
                            FlowLayout(page.relatedQuestions, spacing: 8) { item in
                                Button {
                                    onRelatedQuestionTap(item)
                                } label: {
                                    HStack(spacing: 4) {
                                        Text(item)
                                            .font(.system(size: 12.5, weight: .medium))
                                            .foregroundColor(.primary)
                                        Image(systemName: "arrow.up.right")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundColor(studioMutedText)
                                    }
                                    .padding(.horizontal, 11)
                                    .padding(.vertical, 7)
                                    .background(Color.white.opacity(0.05))
                                    .overlay(
                                        Capsule(style: .continuous)
                                            .stroke(studioLineColor, lineWidth: 1)
                                    )
                                    .clipShape(Capsule(style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                } else if isLoading {
                    if let liveExecutionStatus {
                        ExecutionStatusCard(
                            status: liveExecutionStatus,
                            thoughtPreview: liveThoughtPreview,
                            compact: false
                        )
                    } else if let liveThoughtPreview, !liveThoughtPreview.isEmpty {
                        ThoughtPreviewCard(
                            preview: liveThoughtPreview,
                            loadingState: loadingState,
                            compact: false
                        )
                    }
                }
            }
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ResearchFollowUpSectionView: View {
    let messages: [AICoachService.ChatMessage]

    var body: some View {
        if !messages.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                Text("フォローアップ")
                    .font(.system(size: 15, weight: .bold))

                ForEach(messages) { message in
                    AIMessageRowView(
                        message: message,
                        onTapDetails: {},
                        onTapResponseAction: { _ in }
                    )
                }
            }
        }
    }
}

struct ResultContentView: View {
    let sections: [AIResultSection]
    let sources: [AIResultSource]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                VStack(alignment: .leading, spacing: 8) {
                    if !section.title.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(section.title)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.primary)
                            Spacer(minLength: 0)
                            let referencedSources = referencedSources(for: section)
                            if !referencedSources.isEmpty {
                                CompactCitationStripView(sources: referencedSources)
                            }
                        }
                    }

                    let displayMarkdown = readableCitationMarkdown(section.bodyMarkdown, sources: sources)
                    if let attributed = try? AttributedString(markdown: sanitizeMarkdownLinkSchemes(displayMarkdown)) {
                        Text(attributed)
                            .font(.system(size: 15.5, weight: .regular))
                            .lineSpacing(6)
                            .foregroundColor(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    } else {
                        Text(displayMarkdown)
                            .font(.system(size: 15.5, weight: .regular))
                            .lineSpacing(6)
                            .foregroundColor(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
                .padding(.vertical, index == 0 ? 0 : 14)

                if index < sections.count - 1 {
                    Rectangle()
                        .fill(studioLineColor)
                        .frame(height: 1)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.028))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(studioLineColor, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func referencedSources(for section: AIResultSection) -> [AIResultSource] {
        let body = section.bodyMarkdown
        guard !body.isEmpty else { return [] }
        return sources.filter { source in
            guard let citationID = source.citationID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !citationID.isEmpty else {
                return false
            }
            return body.contains("[\(citationID)]") || body.contains(citationID)
        }
        .prefix(4)
        .map { $0 }
    }
}

private func displayCitationLabel(_ citationID: String?) -> String {
    let trimmed = citationID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !trimmed.isEmpty else { return "出典" }
    if trimmed.uppercased().hasPrefix("S") {
        let number = trimmed.dropFirst()
        if number.allSatisfy(\.isNumber), !number.isEmpty {
            return "出典\(number)"
        }
    }
    return trimmed
}

private func readableCitationMarkdown(_ markdown: String, sources: [AIResultSource]) -> String {
    var output = markdown
    for source in sources {
        guard let citationID = source.citationID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !citationID.isEmpty else {
            continue
        }
        let label = displayCitationLabel(citationID)
        let replacement = citationMarkdownReplacement(label: label, url: source.url)
        let bracketedReplacement = "［\(replacement)］"
        output = output.replacingOccurrences(of: "[\(citationID)]", with: bracketedReplacement)
        output = output.replacingOccurrences(of: "[\(label)]", with: bracketedReplacement)
        output = output.replacingOccurrences(
            of: #"(?<![A-Za-z0-9])\#(citationID)(?![A-Za-z0-9])"#,
            with: label,
            options: .regularExpression
        )
    }
    output = output.replacingOccurrences(
        of: #"\[([^\]\[]*出典\d[^\]\[]*)\]"#,
        with: "［$1］",
        options: .regularExpression
    )
    return output
}

private func citationMarkdownReplacement(label: String, url: String) -> String {
    let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedURL.isEmpty else { return label }
    let escapedURL = trimmedURL
        .replacingOccurrences(of: ">", with: "%3E")
        .replacingOccurrences(of: "\n", with: "")
    return "[\(label)](<\(escapedURL)>)"
}

private struct CompactCitationStripView: View {
    let sources: [AIResultSource]

    var body: some View {
        HStack(spacing: 5) {
            Text("出典")
                .font(.system(size: 10.5, weight: .bold))
                .foregroundColor(studioMutedText)
            ForEach(sources.prefix(4)) { source in
                if let destination = safeWebURL(source.url) {
                    Link(destination: destination) {
                        citationChip(source)
                    }
                    .buttonStyle(.plain)
                } else {
                    citationChip(source)
                }
            }
        }
    }

    private func citationChip(_ source: AIResultSource) -> some View {
        Text(displayCitationLabel(source.citationID))
            .font(.system(size: 10.5, weight: .bold))
            .foregroundColor(.blue)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .help("\(displayCitationLabel(source.citationID)): \(source.domain) / \(source.title)")
        .background(Color.blue.opacity(0.07))
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.blue.opacity(0.18), lineWidth: 1)
        )
        .clipShape(Capsule(style: .continuous))
    }
}

struct ResultReasoningView: View {
    @Binding var viewModel: ThinkingPanelViewModel
    let loadingState: AIResearchLoadingState
    let isLoading: Bool
    let liveThoughtPreview: String?

    private var effectiveLiveThoughtPreview: String? {
        let direct = liveThoughtPreview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !direct.isEmpty { return direct }
        let model = viewModel.liveThoughtPreview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return model.isEmpty ? nil : model
    }

    var body: some View {
        if !viewModel.visibleThoughts.isEmpty || !viewModel.visibleSearchNotes.isEmpty || !viewModel.executionLogItems.isEmpty || viewModel.summaryText != nil || (isLoading && effectiveLiveThoughtPreview != nil) {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewModel.isExpanded.toggle()
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Text("思考")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.primary)

                            if let formattedDuration = viewModel.formattedDuration {
                                Text(formattedDuration)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(studioMutedText)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.white.opacity(0.04))
                                    .clipShape(Capsule(style: .continuous))
                            }

                            Spacer(minLength: 0)

                            Image(systemName: viewModel.isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(studioMutedText)
                        }

                        if let summaryText = viewModel.summaryText {
                            Text(summaryText)
                                .font(.system(size: 13.5, weight: .medium))
                                .foregroundColor(studioMutedText)
                                .lineLimit(viewModel.isExpanded ? nil : 2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(14)
                    .background(Color.white.opacity(0.03))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(studioLineColor, lineWidth: 1)
                    )
                    .cornerRadius(16)
                }
                .buttonStyle(.plain)

                if viewModel.isExpanded {
                    VStack(alignment: .leading, spacing: 12) {
                        if isLoading, let liveThoughtPreview = effectiveLiveThoughtPreview {
                            ThoughtPreviewCard(
                                preview: liveThoughtPreview,
                                loadingState: loadingState,
                                compact: false
                            )
                        }

                        if !viewModel.visibleThoughts.isEmpty {
                            ReasoningListSection(
                                title: "考えていたこと",
                                items: viewModel.visibleThoughts,
                                compact: false
                            )
                        }

                        if !viewModel.visibleSearchNotes.isEmpty {
                            SearchTraceDisclosureCard(
                                title: "VIUK Search Engine",
                                items: viewModel.visibleSearchNotes,
                                isExpanded: $viewModel.isSearchTraceExpanded
                            )
                        }

                        ExecutionLogSection(
                            title: "実行ログ",
                            items: viewModel.executionLogItems,
                            compact: false,
                            isExpanded: $viewModel.isExecutionLogExpanded
                        )
                    }
                    .padding(.top, 2)
                }
            }
            .onChange(of: effectiveLiveThoughtPreview) { _, newPreview in
                if isLoading, newPreview != nil, !viewModel.isExpanded {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewModel.isExpanded = true
                    }
                }
            }
            .onAppear {
                if isLoading, effectiveLiveThoughtPreview != nil {
                    viewModel.isExpanded = true
                }
            }
        }
    }
}

struct ResultSourcesInlineView: View {
    let sources: [AIResultSource]
    let sourceStatus: AIResultSourceStatus
    let requiredSourceCount: Int
    let distinctSourceDomainCount: Int
    let requiredDistinctDomainCount: Int

    var body: some View {
        if !sources.isEmpty || sourceStatus != .ready {
            VStack(alignment: .leading, spacing: 12) {
                Text("参照ソース")
                    .font(.system(size: 15, weight: .bold))

                ResultSourceStatusView(
                    status: sourceStatus,
                    sourceCount: sources.count,
                    requiredSourceCount: requiredSourceCount,
                    distinctSourceDomainCount: distinctSourceDomainCount,
                    requiredDistinctDomainCount: requiredDistinctDomainCount
                )

                if sources.isEmpty {
                    Text("まだ参照ソースを集めています。")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundColor(studioMutedText)
                } else {
                    ForEach(sources) { source in
                        if let destination = safeWebURL(source.url) {
                            Link(destination: destination) {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        citationBadge(source)
                                        Text(source.title)
                                            .font(.system(size: 14.5, weight: .semibold))
                                            .foregroundColor(.primary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    Text(source.domain)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(studioMutedText)
                                    if !source.summary.isEmpty {
                                        Text(source.summary)
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundColor(studioMutedText)
                                            .lineLimit(2)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func citationBadge(_ source: AIResultSource) -> some View {
            Text(displayCitationLabel(source.citationID))
            .font(.system(size: 11.5, weight: .bold))
            .foregroundColor(.blue)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.blue.opacity(0.10))
            .clipShape(Capsule(style: .continuous))
    }
}

struct ActionBarView: View {
    let actions: [AIResultAction]
    let onTap: (AIResultAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("次にできること")
                .font(.system(size: 14, weight: .bold))
            FlowLayout(actions, spacing: 10) { action in
                Button(action.title) { onTap(action) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.05))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(studioLineColor, lineWidth: 1)
                    )
                    .clipShape(Capsule(style: .continuous))
            }
        }
    }
}

struct AIStudioSidePanelView: View {
    let presentationMode: AIStudioPresentationMode
    let currentThread: AICoachService.ChatThreadSummary?
    let selectedMessage: AICoachService.ChatMessage?
    let resultViewModel: ResultPageViewModel
    @Binding var thinkingViewModel: ThinkingPanelViewModel
    let isLoading: Bool
    let liveExecutionStatus: LocalExecutionStatusUpdate?
    let liveThoughtPreview: String?
    let quickActions: [AICoachService.QuickAction]
    let onTapRelatedQuestion: (String) -> Void
    let onTapSuggestedPrompt: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("詳細")
                    .font(.system(size: 15, weight: .bold))

                switch presentationMode {
                case .result:
                    CurrentThreadPanelView(thread: currentThread)
                    ResultReasoningPanelView(
                        viewModel: $thinkingViewModel,
                        liveExecutionStatus: liveExecutionStatus,
                        liveThoughtPreview: liveThoughtPreview
                    )
                    SourcePanelView(
                        sources: resultViewModel.page?.sources ?? [],
                        sourceStatus: resultViewModel.page?.sourceStatus,
                        requiredSourceCount: resultViewModel.page?.requiredSourceCount ?? 0,
                        distinctSourceDomainCount: resultViewModel.page?.distinctSourceDomainCount ?? 0,
                        requiredDistinctDomainCount: resultViewModel.page?.requiredDistinctDomainCount ?? 0
                    )
                    RelatedQuestionsView(
                        questions: resultViewModel.page?.relatedQuestions ?? [],
                        onTap: onTapRelatedQuestion
                    )
                    ResearchFlowPanelView(flow: thinkingViewModel.flow, isLoading: isLoading)
                case .home, .conversation:
                    ConversationAssistPanelView(
                        message: selectedMessage,
                        isLoading: isLoading,
                        liveExecutionStatus: liveExecutionStatus,
                        liveThoughtPreview: liveThoughtPreview,
                        quickActions: quickActions,
                        onTapSuggestedPrompt: onTapSuggestedPrompt
                    )
                }
            }
            .padding(18)
        }
    }
}

private struct ResultReasoningPanelView: View {
    @Binding var viewModel: ThinkingPanelViewModel
    let liveExecutionStatus: LocalExecutionStatusUpdate?
    let liveThoughtPreview: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    viewModel.isExpanded.toggle()
                }
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        // アイコンアクセント
                        ZStack {
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [Color.blue.opacity(0.22), Color.purple.opacity(0.12)],
                                        startPoint: .topLeading, endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 22, height: 22)
                            Image(systemName: "brain")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(
                                    LinearGradient(
                                        colors: [Color(red: 0.4, green: 0.6, blue: 1.0),
                                                 Color(red: 0.6, green: 0.4, blue: 1.0)],
                                        startPoint: .topLeading, endPoint: .bottomTrailing
                                    )
                                )
                        }
                        Text("思考")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.primary)

                        if let formattedDuration = viewModel.formattedDuration {
                            Text(formattedDuration)
                                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                                .foregroundColor(studioMutedText)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color.white.opacity(0.06))
                                .clipShape(Capsule(style: .continuous))
                        }

                        Spacer(minLength: 0)

                        Image(systemName: viewModel.isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundColor(studioMutedText)
                    }

                    if let summaryText = viewModel.summaryText {
                        Text(summaryText)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundColor(studioMutedText)
                            .lineLimit(viewModel.isExpanded ? nil : 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if viewModel.visibleThoughts.isEmpty && viewModel.visibleSearchNotes.isEmpty && viewModel.executionLogItems.isEmpty && liveExecutionStatus == nil {
                        Text("まだ推論過程はありません。")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundColor(studioMutedText)
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.035))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color.blue.opacity(0.18),
                                    Color.white.opacity(0.06)
                                ],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
            }
                    .buttonStyle(.plain)

            if viewModel.isExpanded {
                if viewModel.visibleThoughts.isEmpty && viewModel.visibleSearchNotes.isEmpty && viewModel.executionLogItems.isEmpty && !(viewModel.isLoading && (viewModel.liveThoughtPreview != nil || liveExecutionStatus != nil)) {
                Text("まだ推論過程はありません。")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(studioMutedText)
                } else {
                if viewModel.isLoading,
                       let liveExecutionStatus {
                        ExecutionStatusCard(
                            status: liveExecutionStatus,
                            thoughtPreview: liveThoughtPreview ?? viewModel.liveThoughtPreview,
                            compact: true
                        )
                    } else if viewModel.isLoading,
                              let liveThoughtPreview = viewModel.liveThoughtPreview,
                              !liveThoughtPreview.isEmpty {
                        ThoughtPreviewCard(
                            preview: liveThoughtPreview,
                            loadingState: viewModel.activeStep?.state ?? .analyzing,
                            compact: true
                        )
                    }

                    if !viewModel.visibleThoughts.isEmpty {
                        ReasoningListSection(
                            title: "考えていたこと",
                            items: viewModel.visibleThoughts,
                            compact: true
                        )
                    }

                    if !viewModel.visibleSearchNotes.isEmpty {
                        SearchTraceDisclosureCard(
                            title: "VIUK Search Engine",
                            items: viewModel.visibleSearchNotes,
                            isExpanded: $viewModel.isSearchTraceExpanded
                        )
                    }

                    ExecutionLogSection(
                        title: "実行ログ",
                        items: viewModel.executionLogItems,
                        compact: true,
                        isExpanded: $viewModel.isExecutionLogExpanded
                    )
                }
            }
        }
    }
}

private struct ThoughtPreviewCard: View {
    let preview: String
    let loadingState: AIResearchLoadingState
    let compact: Bool

    var body: some View {
        HStack(alignment: .top, spacing: compact ? 8 : 10) {
            StudioLoadingPulseDot(
                color: loadingState.tintColor,
                isAnimating: true,
                baseSize: compact ? 12 : 14,
                pulseSize: compact ? 20 : 24
            )
            VStack(alignment: .leading, spacing: compact ? 4 : 6) {
                Text("考え中")
                    .font(.system(size: compact ? 11 : 11.5, weight: .semibold))
                    .foregroundColor(studioMutedText)
                Text(preview)
                    .font(.system(size: compact ? 11.5 : 12.5, weight: .medium))
                    .foregroundColor(.primary.opacity(0.88))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(compact ? 3 : 4)
                    .textSelection(.enabled)
            }
        }
        .padding(compact ? 10 : 12)
        .background(Color.white.opacity(0.03))
        .overlay(
            RoundedRectangle(cornerRadius: compact ? 12 : 14, style: .continuous)
                .stroke(studioLineColor, lineWidth: 1)
        )
        .cornerRadius(compact ? 12 : 14)
    }
}

private struct ExecutionStatusCard: View {
    let status: LocalExecutionStatusUpdate
    let thoughtPreview: String?
    let compact: Bool

    /// 進行中の実行開始時刻を観察する。AICoachService 側で発行され、停止時に nil になる。
    /// この StateObject 経由で `liveExecutionStartedAt` が変化したら自動再描画され、
    /// 加えて TimelineView の 1秒 tick で「経過 N秒」が毎秒更新される。
    @ObservedObject private var aiCoach = AICoachService.shared

    /// startedAt から計算した「いま現在」の経過秒。TimelineView 内で呼ぶ。
    /// service が startedAt を保持していなければ status のスナップショット値で代用する。
    private func liveElapsedText(now: Date) -> String {
        guard let startedAt = aiCoach.liveExecutionStartedAt else {
            return status.elapsedText
        }
        let elapsed = max(0, now.timeIntervalSince(startedAt))
        if elapsed < 10 {
            return String(format: "%.1fs", elapsed)
        }
        return "\(Int(elapsed.rounded()))s"
    }

    private func metadataText(elapsedText: String) -> String? {
        let parts: [String?] = [
            status.runnerLabel,
            status.warmState?.displayText,
            elapsedText
        ]
        let cleaned = parts.compactMap { value -> String? in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        return cleaned.isEmpty ? nil : cleaned.joined(separator: " • ")
    }

    private var shouldShowThoughtPreview: Bool {
        guard status.stage != .searching else { return false }
        let runner = status.runnerLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !runner.localizedCaseInsensitiveContains("VIUK Search Engine")
    }

    private var isTicking: Bool {
        guard aiCoach.liveExecutionStartedAt != nil else { return false }
        switch status.stage {
        case .completed, .failed: return false
        default: return true
        }
    }

    // 仕様9.3/9.4: アニメーションでレイアウトを揺らさない。流れるバーは使わない。
    var body: some View {
        // 経過時間を 1 秒ごとに自動更新する。実行中だけ TimelineView の tick を回す。
        // 完了後は再描画させたくないので静的に描画する (TimelineView の schedule 型が分岐できないため
        // ビュー全体を if で分ける)。
        if isTicking {
            TimelineView(.periodic(from: Date(), by: 1.0)) { context in
                cardContent(now: context.date)
            }
        } else {
            cardContent(now: Date())
        }
    }

    @ViewBuilder
    private func cardContent(now: Date) -> some View {
        let elapsedText = liveElapsedText(now: now)
        VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            // ヘッダー行: dot + タイトル + dots indicator
            HStack(spacing: 8) {
                StudioLoadingPulseDot(
                    color: status.stage.tintColor,
                    isAnimating: status.stage.isAnimated,
                    baseSize: compact ? 10 : 12,
                    pulseSize: compact ? 16 : 20
                )
                Text(status.title)
                    .font(.system(size: compact ? 12 : 12.5, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                // 固定フレームの dot indicator（流れる線の代替）
                Text(status.progressText)
                    .font(.system(size: compact ? 10 : 10.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(status.stage.tintColor)
            }

            // 詳細テキスト（1行）
            if !status.detail.isEmpty {
                Text(status.detail)
                    .font(.system(size: compact ? 10.5 : 11, weight: .medium))
                    .foregroundColor(studioMutedText)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // メタデータ（runner/warmState/elapsed）
            if let text = metadataText(elapsedText: elapsedText) {
                Text(text)
                    .font(.system(size: compact ? 9.5 : 10, weight: .medium))
                    .foregroundColor(studioMutedText.opacity(0.7))
                    .lineLimit(1)
            }

            // 思考プレビュー（live preview のみ・仕様9.3）
            if shouldShowThoughtPreview, let thoughtPreview, !thoughtPreview.isEmpty {
                Text(thoughtPreview)
                    .font(.system(size: compact ? 10.5 : 11, weight: .medium))
                    .foregroundColor(.primary.opacity(0.72))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(compact ? 2 : 3)
                    .textSelection(.enabled)
            }
        }
        .padding(compact ? 8 : 10)
        .background(Color.white.opacity(0.03))
        .overlay(
            RoundedRectangle(cornerRadius: compact ? 10 : 12, style: .continuous)
                .stroke(status.stage.tintColor.opacity(0.18), lineWidth: 1)
        )
        .cornerRadius(compact ? 10 : 12)
    }
}

private struct CurrentThreadPanelView: View {
    let thread: AICoachService.ChatThreadSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("現在のスレッド")
                .font(.system(size: 14, weight: .bold))

            if let thread {
                HStack(alignment: .top, spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color.blue.opacity(0.22), Color.purple.opacity(0.12)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 28, height: 28)
                        Image(systemName: thread.kind.iconName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [Color(red: 0.40, green: 0.65, blue: 1.0),
                                             Color(red: 0.65, green: 0.40, blue: 1.0)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                )
                            )
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(thread.title)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(thread.kind == .research ? "Deep Research" : "通常会話")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(studioMutedText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2.5)
                            .background(
                                Capsule().fill(Color.white.opacity(0.06))
                            )
                    }
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.035))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(studioLineColor, lineWidth: 1)
                )
            } else {
                Text("まだスレッドが選択されていません。")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(studioMutedText)
            }
        }
    }
}

private struct ConversationAssistPanelView: View {
    let message: AICoachService.ChatMessage?
    let isLoading: Bool
    let liveExecutionStatus: LocalExecutionStatusUpdate?
    let liveThoughtPreview: String?
    let quickActions: [AICoachService.QuickAction]
    let onTapSuggestedPrompt: (String) -> Void

    @State private var debugCopyFeedback: Bool = false
    /// 開発者モード。設定 (Studio 設定) で ON にした時だけ、内部実行ログ・モデル名・
    /// directiveParseStatus などの実装系情報を右パネルに出す。デフォルト OFF で
    /// エンドユーザーにはクリーンな画面だけが見える。
    @AppStorage("studio.developerMode.enabled") private var isDeveloperModeEnabled = false

    private var debugDetails: AICoachService.ResponseDebugDetails? {
        message?.thoughtDetails?.debugDetails
    }

    private var supportAgentExecutions: [AICoachService.ResponseDebugDetails.SupportAgentExecutionDetails] {
        debugDetails?.supportAgentExecutions ?? []
    }

    private var supportAgentsDegradationReason: String? {
        debugDetails?.supportAgentsDegradationReason
    }

    private var gemmaWebReaderSummaries: [String] {
        debugDetails?.gemmaWebReaderSummaries ?? []
    }

    private var primaryModelStatusLine: String? {
        if let status = primaryModelDirectiveStatusLabel(debugDetails?.directiveParseStatus) {
            return status
        }

        guard let content = message?.content.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else {
            return nil
        }

        if content.hasPrefix("Gemma 4 の応答生成に失敗しました") {
            return "失敗: Gemma 4"
        }

        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // デバッグ用: Thinking / 回答 / 270M planner I/O / 26B Web 読解 などをまとめて 1 回でコピー。
            // 開発者モードでのみ表示する。
            if isDeveloperModeEnabled, hasAnyDebugContent {
                HStack {
                    Spacer()
                    Button(action: copyFullDebugSnapshot) {
                        Label(
                            debugCopyFeedback ? "コピーしました" : "デバッグ全文をコピー",
                            systemImage: debugCopyFeedback ? "checkmark" : "doc.on.doc"
                        )
                        .font(.system(size: 11.5, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.06))
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(studioLineColor, lineWidth: 1)
                        )
                        .clipShape(Capsule(style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("Thinking / 回答 / Gemma 3 270M planner I/O / 26B Web 読解 などを一括でクリップボードに置きます。")
                }
            }

            // 仕様9.3: 返答中は実行ログを目立たせない
            if isLoading, liveExecutionStatus != nil || liveThoughtPreview != nil {
                VStack(alignment: .leading, spacing: 8) {
                    Text("実行中")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(studioMutedText)
                    if let liveExecutionStatus {
                        ExecutionStatusCard(
                            status: liveExecutionStatus,
                            thoughtPreview: liveThoughtPreview,
                            compact: true
                        )
                    } else if let liveThoughtPreview {
                        ThoughtPreviewCard(
                            preview: liveThoughtPreview,
                            loadingState: .analyzing,
                            compact: true
                        )
                    }
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("AIの使用")
                    .font(.system(size: 14, weight: .bold))
                if let thoughtDetails = message?.thoughtDetails {
                    if let durationText = formattedResponseDurationText(thoughtDetails.responseDuration) {
                        Text("• \(durationText)")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundColor(studioMutedText)
                    }
                    ForEach(Array(thoughtDetails.processingLogSummary.enumerated()), id: \.offset) { _, item in
                        Text("• \(item)")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundColor(studioMutedText)
                    }
                    if thoughtDetails.processingLogSummary.isEmpty && formattedResponseDurationText(thoughtDetails.responseDuration) == nil {
                        Text("まだ実行履歴はありません。")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundColor(studioMutedText)
                    }
                } else {
                    Text("まだ実行履歴はありません。")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundColor(studioMutedText)
                }
            }

            // 「主担当モデル」「Gemma 4 26B Web読解 (debug)」「Gemma 3 補助モデル」は
            // 内部実装名を含む技術的な情報なので、開発者モード時のみ表示する。
            if isDeveloperModeEnabled {
                if let primaryModelStatusLine {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("主担当モデル")
                            .font(.system(size: 14, weight: .bold))

                        Text("• \(primaryModelStatusLine)")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundColor(studioMutedText)
                    }
                }

                if !gemmaWebReaderSummaries.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Gemma 4 26B Web読解")
                            .font(.system(size: 14, weight: .bold))

                        ForEach(Array(gemmaWebReaderSummaries.enumerated()), id: \.offset) { index, summary in
                            gemmaWebReaderDebugCard(summary, index: index + 1)
                        }
                    }
                }

                if !supportAgentExecutions.isEmpty || supportAgentsDegradationReason != nil {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Gemma 3 補助モデル")
                            .font(.system(size: 14, weight: .bold))

                        ForEach(Array(supportAgentExecutions.enumerated()), id: \.offset) { _, execution in
                            supportAgentExecutionDebugCard(execution)
                        }

                        if let supportAgentsDegradationReason,
                           !supportAgentsDegradationReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("• 補助モデル全体: \(supportAgentsDegradationReason)")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundColor(studioMutedText)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("次に聞けること")
                    .font(.system(size: 14, weight: .bold))
                if let actions = message?.responseActions, !actions.isEmpty {
                    FlowLayout(actions, spacing: 8) { action in
                        Button(action.title) { onTapSuggestedPrompt(action.prompt) }
                            .buttonStyle(.plain)
                            .font(.system(size: 11.5, weight: .medium))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 7)
                            .background(Color.white.opacity(0.05))
                            .overlay(
                                Capsule(style: .continuous)
                                    .stroke(studioLineColor, lineWidth: 1)
                            )
                            .clipShape(Capsule(style: .continuous))
                    }
                } else if !quickActions.isEmpty {
                    FlowLayout(Array(quickActions.prefix(6)), spacing: 8) { action in
                        Button(action.title) { onTapSuggestedPrompt(action.prompt) }
                            .buttonStyle(.plain)
                            .font(.system(size: 11.5, weight: .medium))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 7)
                            .background(Color.white.opacity(0.05))
                            .overlay(
                                Capsule(style: .continuous)
                                    .stroke(studioLineColor, lineWidth: 1)
                            )
                            .clipShape(Capsule(style: .continuous))
                    }
                } else {
                    Text("候補はまだありません。")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundColor(studioMutedText)
                }
            }
        }
    }

    /// Thinking 全文 / 回答本文 / Gemma 3 270M planner I/O / 26B Web 読解 I/O などをひとつのテキストにまとめてクリップボードに置く。
    /// デバッグ目的: 「どのモデルが何を渡されて何を返したか」を 1 行ずつ追える形でコピーする。
    private func buildFullDebugSnapshotText() -> String {
        var sections: [String] = []
        let dateFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            f.locale = Locale(identifier: "ja_JP")
            return f
        }()

        // ── ヘッダ ─────────────────────────────────────
        var header: [String] = ["=== VIUK One デバッグスナップショット ==="]
        header.append("生成: \(dateFormatter.string(from: Date()))")
        if let thoughtDetails = message?.thoughtDetails {
            header.append("実行モード: \(thoughtDetails.executionDisplayName)")
            header.append("使用モデル: \(thoughtDetails.activeModelDisplayName)")
            if let dur = thoughtDetails.responseDuration {
                header.append(String(format: "応答時間: %.2fs", dur))
            }
            if let think = thoughtDetails.thinkingDuration {
                header.append(String(format: "Thinking 時間: %.2fs", think))
            }
            if thoughtDetails.searchCallCount > 0 {
                header.append("検索呼び出し回数: \(thoughtDetails.searchCallCount)")
            }
            if thoughtDetails.toolUsageCount > 0 {
                header.append("Tool 呼び出し回数: \(thoughtDetails.toolUsageCount)")
            }
        }
        sections.append(header.joined(separator: "\n"))

        // ── 回答本文 ───────────────────────────────────
        if let content = message?.content.trimmingCharacters(in: .whitespacesAndNewlines),
           !content.isEmpty {
            sections.append("=== 回答本文 ===\n\(content)")
        }

        // ── Thinking 全文 ─────────────────────────────
        if let thoughtDetails = message?.thoughtDetails {
            let stream = thoughtDetails.rawThoughtStream.trimmingCharacters(in: .whitespacesAndNewlines)
            if !stream.isEmpty {
                sections.append("=== Thinking (思考全文) ===\n\(stream)")
            } else if !thoughtDetails.rawThoughtSummaries.isEmpty {
                sections.append("=== Thinking (思考全文) ===\n" +
                                thoughtDetails.rawThoughtSummaries.joined(separator: "\n\n"))
            }
        }

        // ── 思考タイムライン ──────────────────────────
        if let timeline = message?.thoughtDetails?.thoughtTimeline, !timeline.isEmpty {
            var lines: [String] = ["=== 思考タイムライン ==="]
            for step in timeline {
                let detail = step.detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if detail.isEmpty {
                    lines.append("- [\(step.type.rawValue)] \(step.title)")
                } else {
                    lines.append("- [\(step.type.rawValue)] \(step.title): \(detail)")
                }
            }
            sections.append(lines.joined(separator: "\n"))
        }

        // ── Gemma 3 270M / 軽量補助モデル実行 I/O ────────
        if !supportAgentExecutions.isEmpty {
            var lines: [String] = ["=== Gemma 3 補助モデル実行 (planner / 軽量) ==="]
            for (idx, exec) in supportAgentExecutions.enumerated() {
                lines.append("")
                lines.append("--- 実行 #\(idx + 1): \(supportAgentExecutionLabel(exec)) ---")
                if let purpose = exec.purpose,
                   !purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    lines.append("目的: \(purpose)")
                }
                if let dur = exec.duration {
                    lines.append(String(format: "所要: %.2fs", dur))
                }
                if exec.degraded {
                    lines.append("状態: 失敗 / degraded")
                }
                if let reason = exec.failureReason,
                   !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    lines.append("失敗理由: \(reason)")
                }
                if let input = exec.inputPreview,
                   !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    lines.append("[渡した入力]")
                    lines.append(input)
                }
                if let output = exec.outputPreview,
                   !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    lines.append("[モデル出力]")
                    lines.append(output)
                }
                if let handoff = exec.handoffPreview,
                   !handoff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    lines.append("[Gemma 4 へ渡した内容]")
                    lines.append(handoff)
                }
            }
            sections.append(lines.joined(separator: "\n"))
        }
        if let degradationReason = supportAgentsDegradationReason,
           !degradationReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("補助モデル全体の degradation: \(degradationReason)")
        }

        // ── Gemma 4 26B Web 読解 ──────────────────────
        if !gemmaWebReaderSummaries.isEmpty {
            var lines: [String] = ["=== Gemma 4 26B Web 読解 ==="]
            for (idx, summary) in gemmaWebReaderSummaries.enumerated() {
                lines.append("")
                lines.append("--- W\(idx + 1) / gemma-4-26b-a4b-it ---")
                lines.append(summary)
            }
            sections.append(lines.joined(separator: "\n"))
        }

        // ── 検索 / Tool 活動 ──────────────────────────
        if let activity = message?.thoughtDetails?.searchActivity, !activity.isEmpty {
            var lines: [String] = ["=== 検索アクティビティ ==="]
            for entry in activity {
                lines.append("- \(entry)")
            }
            sections.append(lines.joined(separator: "\n"))
        }
        if let toolActivity = message?.thoughtDetails?.toolActivity, !toolActivity.isEmpty {
            var lines: [String] = ["=== Tool アクティビティ ==="]
            for entry in toolActivity {
                lines.append("- \(entry)")
            }
            sections.append(lines.joined(separator: "\n"))
        }

        // ── 処理ログ要約 ───────────────────────────────
        if let log = message?.thoughtDetails?.processingLogSummary, !log.isEmpty {
            var lines: [String] = ["=== 処理ログ要約 ==="]
            for entry in log {
                lines.append("- \(entry)")
            }
            sections.append(lines.joined(separator: "\n"))
        }

        return sections.joined(separator: "\n\n")
    }

    private func copyFullDebugSnapshot() {
        let text = buildFullDebugSnapshotText()
        guard !text.isEmpty else { return }
#if os(macOS)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
#else
        UIPasteboard.general.string = text
#endif
        debugCopyFeedback = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            debugCopyFeedback = false
        }
    }

    private var hasAnyDebugContent: Bool {
        message?.thoughtDetails != nil ||
        !(message?.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    private func gemmaWebReaderDebugCard(_ summary: String, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("• W\(index) / gemma-4-26b-a4b-it")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(studioMutedText)

            supportAgentDebugField("読解・要約", summary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.035))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(studioLineColor, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func supportAgentExecutionDebugCard(
        _ execution: AICoachService.ResponseDebugDetails.SupportAgentExecutionDetails
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("• \(supportAgentExecutionLabel(execution))")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(studioMutedText)

            supportAgentDebugField("目的", execution.purpose)
            supportAgentDebugField("渡した内容", execution.inputPreview)
            supportAgentDebugField("Gemma 3 出力", execution.outputPreview)
            supportAgentDebugField("Gemma 4へ渡した内容", execution.handoffPreview)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.035))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(studioLineColor, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func supportAgentDebugField(_ title: String, _ value: String?) -> some View {
        if let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundColor(studioMutedText.opacity(0.78))
                Text(value)
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundColor(.primary.opacity(0.82))
                    .textSelection(.enabled)
                    .lineLimit(nil)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func supportAgentExecutionLabel(
        _ execution: AICoachService.ResponseDebugDetails.SupportAgentExecutionDetails
    ) -> String {
        let role: String = {
            guard let value = execution.role?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else {
                return "support"
            }
            return value
        }()
        let duration: String
        if let seconds = execution.duration, seconds.isFinite, seconds >= 0 {
            duration = String(format: "%.1fs", seconds)
        } else {
            duration = "-"
        }
        let statusPrefix = execution.degraded ? "失敗" : "成功"

        if execution.degraded {
            let reason: String = {
                guard let value = execution.failureReason?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !value.isEmpty else {
                    return "縮退"
                }
                return value
            }()
            return "\(statusPrefix): \(execution.modelDisplayName) / \(role) / \(duration) / \(reason)"
        }

        return "\(statusPrefix): \(execution.modelDisplayName) / \(role) / \(duration)"
    }

    private func primaryModelDirectiveStatusLabel(_ status: String?) -> String? {
        guard let status else { return nil }

        switch status {
        case "local-gemma4-direct":
            return "成功: Gemma 4 / direct"
        case "local-gemma4-direct-failed":
            return "失敗: Gemma 4 / direct"
        case "local-gemma4-native-turn":
            return "成功: Gemma 4 / native turn"
        case "local-gemma4-native-turn-failed":
            return "失敗: Gemma 4 / native turn"
        case "local-gemma4-direct-fallback":
            return "成功: Gemma 4 / direct fallback"
        default:
            return nil
        }
    }
}

private struct ExecutionLogSection: View {
    let title: String
    let items: [String]
    let compact: Bool
    @Binding var isExpanded: Bool

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: compact ? 8 : 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.system(size: compact ? 11.5 : 12.5, weight: .semibold))
                            .foregroundColor(studioMutedText)
                        Spacer(minLength: 0)
                        Text("\(items.count)件")
                            .font(.system(size: compact ? 10 : 10.5, weight: .semibold))
                            .foregroundColor(studioMutedText.opacity(0.8))
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(studioMutedText)
                    }
                }
                .buttonStyle(.plain)

                if isExpanded {
                    VStack(alignment: .leading, spacing: compact ? 7 : 8) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            Text(item)
                                .font(.system(size: compact ? 11 : 11.5, weight: .medium))
                                .foregroundColor(studioMutedText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(compact ? 10 : 12)
                    .background(Color.white.opacity(0.03))
                    .overlay(
                        RoundedRectangle(cornerRadius: compact ? 12 : 14, style: .continuous)
                            .stroke(studioLineColor, lineWidth: 1)
                    )
                    .cornerRadius(compact ? 12 : 14)
                }
            }
        }
    }
}

struct SourcePanelView: View {
    let sources: [AIResultSource]
    let sourceStatus: AIResultSourceStatus?
    let requiredSourceCount: Int
    let distinctSourceDomainCount: Int
    let requiredDistinctDomainCount: Int

    @State private var hoveredSourceID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ソース")
                .font(.system(size: 14, weight: .bold))

            if let sourceStatus {
                ResultSourceStatusView(
                    status: sourceStatus,
                    sourceCount: sources.count,
                    requiredSourceCount: requiredSourceCount,
                    distinctSourceDomainCount: distinctSourceDomainCount,
                    requiredDistinctDomainCount: requiredDistinctDomainCount
                )
            }

            if sources.isEmpty {
                Text("まだソースはありません。")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(studioMutedText)
            } else {
                VStack(spacing: 5) {
                    ForEach(sources) { source in
                        if let destination = safeWebURL(source.url) {
                            Link(destination: destination) {
                                sourceCard(source)
                            }
                            .buttonStyle(.plain)
                        } else {
                            sourceCard(source)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func sourceCard(_ source: AIResultSource) -> some View {
        let isHovered = hoveredSourceID == source.id
        HStack(alignment: .top, spacing: 9) {
            // 左列: favicon + 引用番号
            VStack(alignment: .center, spacing: 4) {
                AsyncImage(
                    url: URL(string: "https://www.google.com/s2/favicons?domain=\(source.domain)&sz=32")
                ) { phase in
                    if let img = phase.image {
                        img.resizable()
                            .interpolation(.high)
                            .frame(width: 16, height: 16)
                            .clipShape(RoundedRectangle(cornerRadius: 3.5, style: .continuous))
                    } else {
                        Image(systemName: "globe")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Color.white.opacity(0.35))
                            .frame(width: 16, height: 16)
                    }
                }
                if let cid = source.citationID {
                    Text(displayCitationLabel(cid))
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Color.blue.opacity(0.85))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                }
            }
            .frame(width: 26, alignment: .top)
            .padding(.top, 1)

            // 右列: ドメイン / タイトル / スニペット
            VStack(alignment: .leading, spacing: 3) {
                Text(source.domain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.42))
                    .lineLimit(1)
                Text(source.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary.opacity(0.9))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                let snippet = source.summary.trimmingCharacters(in: .whitespacesAndNewlines)
                if !snippet.isEmpty {
                    Text(snippet)
                        .font(.system(size: 11.5))
                        .foregroundColor(Color.white.opacity(0.38))
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(isHovered ? 0.075 : 0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    isHovered ? Color.white.opacity(0.15) : Color.white.opacity(0.08),
                    lineWidth: 1
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .onHover { inside in
            hoveredSourceID = inside ? source.id : nil
        }
    }
}

struct RelatedQuestionsView: View {
    let questions: [String]
    let onTap: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("関連質問")
                .font(.system(size: 14, weight: .bold))
            if questions.isEmpty {
                Text("関連質問はまだありません。")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundColor(studioMutedText)
            } else {
                FlowLayout(questions, spacing: 8) { question in
                    Button(question) { onTap(question) }
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .background(Color.white.opacity(0.05))
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(studioLineColor, lineWidth: 1)
                        )
                        .clipShape(Capsule(style: .continuous))
                }
            }
        }
    }
}

struct ResearchFlowPanelView: View {
    let flow: [AIResearchFlowStep]
    let isLoading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("調査の流れ")
                .font(.system(size: 14, weight: .bold))
            if flow.isEmpty {
                Text("調査を始めると、ここに検索と整理の流れが出ます。")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundColor(studioMutedText)
            } else {
                ConnectedResearchFlowView(
                    flow: flow,
                    isLoading: isLoading,
                    compact: true
                )
            }
        }
    }
}

struct InlineInspectorView: View {
    let message: AICoachService.ChatMessage?
    let fallbackStatus: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("詳細")
                .font(.system(size: 14, weight: .bold))

            if let thoughtDetails = message?.thoughtDetails {
                let visibleThoughts = thoughtDetails.displayThoughtSegments.isEmpty
                    ? thoughtDetails.thoughtSummaries
                    : thoughtDetails.displayThoughtSegments

                if !visibleThoughts.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("考え方")
                            .font(.system(size: 13.5, weight: .semibold))
                        ForEach(Array(visibleThoughts.prefix(3).enumerated()), id: \.offset) { _, item in
                            Text("• \(item)")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                    }
                }

                let visibleToolActivity = thoughtDetails.toolActivity.isEmpty
                    ? thoughtDetails.processingLogSummary
                    : thoughtDetails.toolActivity

                if !visibleToolActivity.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("AIの使用")
                            .font(.system(size: 13.5, weight: .semibold))
                        ForEach(Array(visibleToolActivity.enumerated()), id: \.offset) { _, item in
                            Text("• \(item)")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            } else {
                Text(fallbackStatus)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundColor(.secondary)
            }
        }
    }
}

struct StatusIndicatorView: View {
    let loadingState: AIResearchLoadingState
    let isVisible: Bool
    let currentStep: AIResearchFlowStep?
    let executionStatus: LocalExecutionStatusUpdate?
    let liveThoughtPreview: String?

    var body: some View {
        if isVisible {
            VStack(alignment: .leading, spacing: 8) {
                if let executionStatus {
                    HStack(spacing: 8) {
                        StudioLoadingPulseDot(
                            color: executionStatus.stage.tintColor,
                            isAnimating: executionStatus.stage.isAnimated,
                            baseSize: 8,
                            pulseSize: 18
                        )
                        Text("\(executionStatus.stage.displayText) \(executionStatus.progressText)")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(studioMutedText)
                        Spacer()
                    }

                    Text(executionStatus.detail)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    let metadataParts = [
                        executionStatus.runnerLabel,
                        executionStatus.warmState?.displayText,
                        executionStatus.elapsedText
                    ]
                        .compactMap { value -> String? in
                            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                            return trimmed.isEmpty ? nil : trimmed
                        }
                    if !metadataParts.isEmpty {
                        let metadataText = metadataParts.joined(separator: " • ")
                        Text(metadataText)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(studioMutedText)
                    }

                    StudioDeterminateProgressBar(
                        progress: Double(executionStatus.estimatedProgress) / 100,
                        color: executionStatus.stage.tintColor
                    )
                    .frame(height: 4)
                } else {
                    HStack(spacing: 8) {
                        StudioLoadingPulseDot(
                            color: loadingState.tintColor,
                            isAnimating: loadingState.isAnimated,
                            baseSize: 8,
                            pulseSize: 18
                        )
                        Text(loadingState.displayText)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(studioMutedText)
                        if loadingState.isAnimated {
                            StudioThinkingDots(color: loadingState.tintColor)
                        }
                        Spacer()
                    }

                    if let currentStep {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: currentStep.state.iconName)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(currentStep.state.tintColor)
                                .frame(width: 16, height: 16)

                            VStack(alignment: .leading, spacing: 3) {
                                Text("今は「\(currentStep.label)」を進めています")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.primary)
                                if let detail = currentStep.detail, !detail.isEmpty {
                                    Text(detail)
                                        .font(.system(size: 12.5, weight: .medium))
                                        .foregroundColor(studioMutedText)
                                        .lineLimit(2)
                                }
                            }
                        }
                    }

                    if let liveThoughtPreview {
                        Text(liveThoughtPreview)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundColor(studioMutedText)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }

                    if loadingState.isAnimated {
                        StudioLoadingBar(color: loadingState.tintColor)
                            .frame(height: 4)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.04))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(studioLineColor, lineWidth: 1)
            )
            .cornerRadius(12)
        }
    }
}

private struct CurrentResearchStepCard: View {
    let step: AIResearchFlowStep
    let isLoading: Bool
    let loadingState: AIResearchLoadingState
    let liveThoughtPreview: String?
    var compact: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            HStack(spacing: 8) {
                ZStack {
                    if isLoading {
                        StudioLoadingPulseDot(
                            color: step.state.tintColor,
                            isAnimating: true,
                            baseSize: compact ? 18 : 20,
                            pulseSize: compact ? 26 : 30
                        )
                    }
                    Image(systemName: step.state.iconName)
                        .font(.system(size: compact ? 11 : 12, weight: .semibold))
                        .foregroundColor(step.state.tintColor)
                }
                Text(isLoading ? "今どこを考えているか" : "最後に考えていたこと")
                    .font(.system(size: compact ? 12.5 : 13.5, weight: .semibold))
                    .foregroundColor(studioMutedText)
                Spacer(minLength: 0)
                Text(loadingState.displayText)
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundColor(step.state.tintColor)
                if isLoading {
                    StudioThinkingDots(color: step.state.tintColor)
                }
            }

            Text(step.label)
                .font(.system(size: compact ? 14 : 15.5, weight: .bold))
                .foregroundColor(.primary)

            if let detail = step.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: compact ? 12.5 : 13.5, weight: .medium))
                    .foregroundColor(studioMutedText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let liveThoughtPreview, isLoading {
                Text(liveThoughtPreview)
                    .font(.system(size: compact ? 12.5 : 13, weight: .medium))
                    .foregroundColor(.primary.opacity(0.86))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(compact ? 3 : 4)
                    .textSelection(.enabled)
            }
        }
        .padding(compact ? 12 : 14)
        .background(Color.white.opacity(0.04))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(step.state.tintColor.opacity(0.28), lineWidth: 1)
        )
        .overlay(alignment: .bottomLeading) {
            if isLoading {
                StudioLoadingBar(color: step.state.tintColor)
                    .frame(height: 3)
                    .padding(.horizontal, compact ? 12 : 14)
                    .padding(.bottom, 8)
            }
        }
        .cornerRadius(16)
    }
}

private struct ConnectedResearchFlowView: View {
    let flow: [AIResearchFlowStep]
    let isLoading: Bool
    let compact: Bool

    private var activeStepID: String? {
        isLoading ? flow.last?.id : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 12) {
            ForEach(Array(flow.enumerated()), id: \.element.id) { index, step in
                ResearchFlowRowView(
                    step: step,
                    isActive: step.id == activeStepID,
                    showsConnector: index < flow.count - 1,
                    compact: compact
                )
            }
        }
    }
}

private struct ResearchFlowRowView: View {
    let step: AIResearchFlowStep
    let isActive: Bool
    let showsConnector: Bool
    let compact: Bool
    @State private var isHovering = false

    private var isCompleted: Bool {
        // アクティブではないかつ最終状態（success相当）は完了とみなす
        !isActive && step.state.iconName.contains("checkmark")
    }

    private var tooltipText: String {
        var lines: [String] = [step.label]
        if let detail = step.detail, !detail.isEmpty {
            lines.append("")
            lines.append(detail)
        }
        if isActive {
            lines.append("")
            lines.append("🔄 進行中")
        } else if isCompleted {
            lines.append("")
            lines.append("✓ 完了")
        }
        return lines.joined(separator: "\n")
    }

    var body: some View {
        HStack(alignment: .top, spacing: compact ? 10 : 12) {
            // ── タイムラインドット ──────────────────────────────────
            VStack(spacing: 0) {
                ZStack {
                    // アクティブ時のパルスハロー
                    if isActive {
                        Circle()
                            .fill(step.state.tintColor.opacity(0.25))
                            .frame(width: compact ? 22 : 26, height: compact ? 22 : 26)
                            .blur(radius: 4)
                    }
                    // 外側リング
                    Circle()
                        .stroke(
                            isActive
                                ? AnyShapeStyle(
                                    LinearGradient(
                                        colors: [step.state.tintColor, step.state.tintColor.opacity(0.6)],
                                        startPoint: .top, endPoint: .bottom
                                    )
                                )
                                : AnyShapeStyle(Color.white.opacity(0.25)),
                            lineWidth: isActive ? 2 : 1.2
                        )
                        .frame(width: compact ? 14 : 16, height: compact ? 14 : 16)
                    // 内側ドット
                    Circle()
                        .fill(
                            isActive
                                ? AnyShapeStyle(step.state.tintColor)
                                : AnyShapeStyle(Color.white.opacity(0.35))
                        )
                        .frame(width: compact ? 6 : 7, height: compact ? 6 : 7)

                    // アクティブ時の呼吸アニメーション
                    if isActive {
                        TimelineView(.periodic(from: .now, by: 0.1)) { context in
                            let progress = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                            Circle()
                                .stroke(step.state.tintColor.opacity(0.5 * (1 - progress)), lineWidth: 1.5)
                                .frame(
                                    width: (compact ? 14 : 16) + CGFloat(progress) * 14,
                                    height: (compact ? 14 : 16) + CGFloat(progress) * 14
                                )
                        }
                    }
                }
                .frame(width: compact ? 22 : 26, height: compact ? 22 : 26)

                if showsConnector {
                    // グラデーションコネクタライン
                    LinearGradient(
                        colors: [
                            step.state.tintColor.opacity(isActive ? 0.55 : 0.25),
                            Color.white.opacity(0.08)
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(width: 1.5, height: compact ? 28 : 34)
                    .padding(.top, 2)
                }
            }
            .frame(width: compact ? 22 : 26)

            // ── ラベル + 詳細 ──────────────────────────────────────
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(step.label)
                        .font(.system(size: compact ? 12 : 12.5, weight: isActive ? .bold : .semibold))
                        .foregroundColor(isActive ? .primary : .primary.opacity(0.88))
                    if isActive {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(step.state.tintColor)
                                .frame(width: 4, height: 4)
                            Text("進行中")
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundColor(step.state.tintColor)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(
                            Capsule(style: .continuous)
                                .fill(step.state.tintColor.opacity(0.14))
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(step.state.tintColor.opacity(0.22), lineWidth: 0.5)
                        )
                    }
                }

                if let detail = step.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: compact ? 11 : 11.5, weight: .medium))
                        .foregroundColor(studioMutedText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.bottom, showsConnector ? (compact ? 6 : 8) : 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, compact ? 4 : 6)
        .background(
            ZStack {
                if isActive {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    step.state.tintColor.opacity(0.10),
                                    step.state.tintColor.opacity(0.02)
                                ],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                } else if isHovering {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.04))
                }
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovering)
        .help(tooltipText)
    }
}

private struct StudioLoadingPulseDot: View {
    let color: Color
    let isAnimating: Bool
    let baseSize: CGFloat
    let pulseSize: CGFloat

    var body: some View {
        ZStack {
            if isAnimating {
                TimelineView(.periodic(from: .now, by: 0.12)) { context in
                    let progress = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2
                    Circle()
                        .fill(color.opacity(0.18 * (1 - progress)))
                        .frame(
                            width: baseSize + (pulseSize - baseSize) * progress,
                            height: baseSize + (pulseSize - baseSize) * progress
                        )
                }
            }

            Circle()
                .fill(color)
                .frame(width: baseSize, height: baseSize)
        }
        .frame(width: pulseSize, height: pulseSize)
    }
}

private struct StudioThinkingDots: View {
    let color: Color

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.18)) { context in
            let phase = Int(context.date.timeIntervalSinceReferenceDate * 5) % 3
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(color.opacity(phase == index ? 1 : 0.28))
                        .frame(width: 6, height: 6)
                }
            }
        }
        .frame(width: 26, height: 8)
    }
}

private struct StudioLoadingBar: View {
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.periodic(from: .now, by: 0.04)) { context in
                let totalWidth = max(proxy.size.width, 1)
                let highlightWidth = max(totalWidth * 0.24, 42)
                let progress = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                let xOffset = (totalWidth - highlightWidth) * progress

                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.06))

                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [color.opacity(0.12), color.opacity(0.85), color.opacity(0.12)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: highlightWidth)
                        .offset(x: xOffset)
                }
            }
        }
    }
}

private struct StudioDeterminateProgressBar: View {
    let progress: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            let clamped = min(max(progress, 0), 1)
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.08))

                Capsule(style: .continuous)
                    .fill(color.opacity(0.95))
                    .frame(width: max(proxy.size.width * clamped, clamped > 0 ? 8 : 0))
            }
        }
    }
}

private struct StaticConnectorLine: View {
    let color: Color
    let isActive: Bool
    let height: CGFloat

    var body: some View {
        Capsule(style: .continuous)
            .fill(isActive ? color.opacity(0.24) : studioLineColor)
            .frame(width: 2, height: height)
            .overlay(alignment: .top) {
                if isActive {
                    Circle()
                        .fill(color)
                        .frame(width: 6, height: 6)
                }
            }
    }
}

private struct ReasoningListSection: View {
    let title: String
    let items: [String]
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            Text(title)
                .font(.system(size: compact ? 11 : 11.5, weight: .bold))
                .foregroundColor(studioMutedText)

            VStack(alignment: .leading, spacing: compact ? 6 : 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(Color.white.opacity(0.45))
                            .frame(width: 4, height: 4)
                            .padding(.top, compact ? 5 : 6)

                        Text(item)
                            .font(.system(size: compact ? 12 : 13.5, weight: .medium))
                            .foregroundColor(compact ? studioMutedText : .primary.opacity(0.9))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(compact ? 10 : 12)
            .background(Color.white.opacity(0.03))
            .overlay(
                RoundedRectangle(cornerRadius: compact ? 12 : 14, style: .continuous)
                    .stroke(studioLineColor, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: compact ? 12 : 14, style: .continuous))
        }
    }
}

private extension AIResearchLoadingState {
    var tintColor: Color {
        switch self {
        case .idle:
            return studioMutedText
        case .searching:
            return .blue
        case .analyzing:
            return .orange
        case .waitingForSources:
            return .orange
        case .generating:
            return .purple
        case .completed:
            return .green
        }
    }

    var iconName: String {
        switch self {
        case .idle:
            return "pause.circle.fill"
        case .searching:
            return "magnifyingglass.circle.fill"
        case .analyzing:
            return "slider.horizontal.3"
        case .waitingForSources:
            return "pause.circle.fill"
        case .generating:
            return "sparkles"
        case .completed:
            return "checkmark.circle.fill"
        }
    }

    var isAnimated: Bool {
        switch self {
        case .searching, .analyzing, .generating:
            return true
        case .idle, .waitingForSources, .completed:
            return false
        }
    }
}

private extension LocalExecutionStage {
    var tintColor: Color {
        switch self {
        case .preparing:
            return .gray
        case .routing:
            return .blue
        case .warmingRuntime:
            return .orange
        case .loadingModel:
            return .yellow
        case .searchPlanning:
            return .blue
        case .searching:
            return .blue
        case .thinking:
            return .orange
        case .generating:
            return .purple
        case .streaming:
            return .green
        case .completed:
            return .green
        case .failed:
            return .red
        }
    }

    var iconName: String {
        switch self {
        case .preparing:
            return "tray.and.arrow.down"
        case .routing:
            return "point.topleft.down.curvedto.point.bottomright.up"
        case .warmingRuntime:
            return "bolt.horizontal.circle"
        case .loadingModel:
            return "shippingbox"
        case .searchPlanning:
            return "list.bullet.rectangle"
        case .searching:
            return "magnifyingglass"
        case .thinking:
            return "brain.head.profile"
        case .generating:
            return "square.and.pencil"
        case .streaming:
            return "text.line.first.and.arrowtriangle.forward"
        case .completed:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.octagon.fill"
        }
    }

    var isAnimated: Bool {
        switch self {
        case .preparing, .routing, .warmingRuntime, .loadingModel, .searchPlanning, .searching, .thinking, .generating, .streaming:
            return true
        case .completed, .failed:
            return false
        }
    }
}

private struct ResultSourceStatusView: View {
    let status: AIResultSourceStatus
    let sourceCount: Int
    let requiredSourceCount: Int
    let distinctSourceDomainCount: Int
    let requiredDistinctDomainCount: Int

    private var tintColor: Color {
        switch status {
        case .insufficient:
            return .orange
        case .enriching:
            return .blue
        case .ready:
            return .green
        }
    }

    private var detailText: String {
        if requiredDistinctDomainCount > 0 {
            return "\(status.detailPrefix) \(sourceCount) / \(max(requiredSourceCount, 1)) 件、ドメイン \(distinctSourceDomainCount) / \(max(requiredDistinctDomainCount, 1)) 件"
        }
        return "\(status.detailPrefix) \(sourceCount) / \(max(requiredSourceCount, 1)) 件"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: status == .ready ? "checkmark.seal.fill" : "clock.arrow.trianglehead.counterclockwise.rotate.90")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(tintColor)

            VStack(alignment: .leading, spacing: 4) {
                Text(status.title)
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundColor(tintColor)
                Text(detailText)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(studioMutedText)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(tintColor.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(tintColor.opacity(0.18), lineWidth: 1)
        )
        .cornerRadius(12)
    }
}

private func formatThinkingDuration(_ interval: TimeInterval?) -> String? {
    guard let interval, interval > 0.05 else { return nil }
    if interval < 60 {
        return String(format: "思考 %.1f秒", interval)
    }

    let totalSeconds = Int(interval.rounded())
    let minutes = totalSeconds / 60
    let seconds = totalSeconds % 60
    if seconds == 0 {
        return "思考 \(minutes)分"
    }
    return "思考 \(minutes)分 \(seconds)秒"
}

private struct FlowLayout<Data: RandomAccessCollection, Content: View>: View {
    let data: Data
    let spacing: CGFloat
    let content: (Data.Element) -> Content

    init(_ data: Data, spacing: CGFloat = 8, @ViewBuilder content: @escaping (Data.Element) -> Content) {
        self.data = data
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: spacing)], alignment: .leading, spacing: spacing) {
            ForEach(Array(data.enumerated()), id: \.offset) { _, item in
                content(item)
            }
        }
    }
}

// MARK: - WebBrowsingPanelView

#if canImport(WebKit)
import WebKit

// MARK: Platform WKWebView representable

#if os(macOS)
private struct WKWebViewRepresentable: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#else
private struct WKWebViewRepresentable: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#endif

// MARK: - Sub-views

/// 小さな呼吸するスキャンドット
private struct BrowsingScanDot: View {
    @State private var opacity: Double = 1.0
    var color: Color = .blue
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 5, height: 5)
            .opacity(opacity)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.65).repeatForever(autoreverses: true)) {
                    opacity = 0.25
                }
            }
    }
}

/// 円形プログレスリング
private struct BrowsingProgressRing: View {
    let progress: Double
    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.10), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: CGFloat(min(progress, 1.0)))
                .stroke(
                    LinearGradient(
                        colors: [Color(red: 0.25, green: 0.55, blue: 1.0),
                                 Color(red: 0.55, green: 0.35, blue: 1.0)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.35), value: progress)
        }
    }
}

// MARK: Panel

/// AI が WKWebView でブラウジング中に右ペインに表示されるライブパネル。
struct WebBrowsingPanelView: View {
    @ObservedObject var agent: WebBrowsingAgent
    @State private var isCollapsed = false
    @State private var globePulse: CGFloat = 1.0

    // グラデーション定数
    private let blueGrad = LinearGradient(
        colors: [Color(red: 0.22, green: 0.52, blue: 1.0),
                 Color(red: 0.52, green: 0.32, blue: 1.0)],
        startPoint: .leading, endPoint: .trailing
    )

    var body: some View {
        VStack(spacing: 0) {
            topProgressBar
            headerRow
                .padding(.horizontal, 13)
                .padding(.top, 10)
                .padding(.bottom, 8)

            if agent.isActive && !isCollapsed {
                // ── アクティブ: ドメイン行 + WebView ────────────────────
                domainStatusRow
                    .padding(.horizontal, 13)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                Divider()
                    .opacity(0.12)
                    .transition(.opacity)
                webViewPane
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if !agent.isActive {
                // ── アイドル: 待機メッセージ ─────────────────────────────
                idleStateRow
                    .padding(.horizontal, 13)
                    .padding(.bottom, 12)
                    .transition(.opacity)
            }
        }
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            agent.isActive
                                ? Color.blue.opacity(0.45)
                                : Color.white.opacity(0.10),
                            agent.isActive
                                ? Color.purple.opacity(0.25)
                                : Color.white.opacity(0.05)
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(
            color: agent.isActive ? Color.blue.opacity(0.18) : Color.clear,
            radius: 18, x: 0, y: 5
        )
        .onAppear {
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                globePulse = 1.22
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.78), value: agent.isActive)
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: isCollapsed)
    }

    // ── アイドル待機行 ────────────────────────────────────────────────
    private var idleStateRow: some View {
        HStack(spacing: 7) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 10))
                .foregroundColor(.secondary.opacity(0.6))
            Text("Web ブラウジング待機中")
                .font(.system(size: 10.5))
                .foregroundColor(.secondary.opacity(0.6))
            Spacer(minLength: 0)
        }
    }

    // ── 上端グラデーション進捗バー ────────────────────────────────────
    private var topProgressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // トラック
                Color.white.opacity(0.05)

                // フィル
                blueGrad
                    .frame(width: geo.size.width * max(agent.loadProgress,
                                                        agent.isActive ? 0.03 : 0))
                    .animation(.linear(duration: 0.14), value: agent.loadProgress)

                // シマーグロー
                if agent.isActive, agent.loadProgress > 0, agent.loadProgress < 0.99 {
                    Color.white.opacity(0.45)
                        .frame(width: 36)
                        .blur(radius: 9)
                        .offset(x: geo.size.width * max(agent.loadProgress, 0.03) - 18)
                        .animation(.linear(duration: 0.14), value: agent.loadProgress)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(height: 2.5)
        .clipped()
    }

    // ── ヘッダー行 ─────────────────────────────────────────────────────
    private var headerRow: some View {
        HStack(spacing: 10) {
            // パルスするグローブアイコン
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.blue.opacity(0.28), Color.purple.opacity(0.10)],
                            center: .center,
                            startRadius: 0, endRadius: 14
                        )
                    )
                    .frame(width: 28, height: 28)
                    .scaleEffect(globePulse)
                Image(systemName: "globe")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(blueGrad)
            }

            VStack(alignment: .leading, spacing: 1.5) {
                Text("AI ブラウジング")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(.primary)
                if agent.isActive && agent.totalCount > 0 {
                    Text("\(agent.completedCount) / \(agent.totalCount) ページ")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundColor(.secondary)
                } else if !agent.isActive {
                    Text("待機中")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.55))
                }
            }

            Spacer(minLength: 0)

            // 円形プログレスリング（アクティブ時のみ）
            if agent.isActive && agent.totalCount > 0 {
                let frac = Double(agent.completedCount) / Double(agent.totalCount)
                BrowsingProgressRing(progress: frac)
                    .frame(width: 22, height: 22)
            }

            // 折りたたみ・閉じるボタン（アクティブ時のみ）
            if agent.isActive {
            HStack(spacing: 5) {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.72)) {
                        isCollapsed.toggle()
                    }
                } label: {
                    Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.secondary)
                        .frame(width: 22, height: 22)
                        .background(Color.white.opacity(0.07), in: Circle())
                }
                .buttonStyle(.plain)

                Button {
                    agent.cancel()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.secondary)
                        .frame(width: 22, height: 22)
                        .background(Color.white.opacity(0.07), in: Circle())
                }
                .buttonStyle(.plain)
            }
            } // if agent.isActive
        }
    }

    // ── ドメイン・ステータス行 ─────────────────────────────────────────
    private var domainStatusRow: some View {
        HStack(spacing: 8) {
            // ドメインピル
            if let host = agent.currentURL?.host {
                HStack(spacing: 4) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 8))
                        .foregroundColor(.green)
                    Text(host)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(.primary.opacity(0.72))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3.5)
                .background(Color.white.opacity(0.07), in: Capsule())
            }

            Spacer(minLength: 0)

            // ステータスバッジ
            HStack(spacing: 5) {
                if agent.needsUserIntervention {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.orange)
                } else if agent.isActive {
                    BrowsingScanDot()
                }
                Text(agent.statusText)
                    .font(.system(size: 10))
                    .foregroundColor(agent.needsUserIntervention ? .orange : .secondary)
                    .lineLimit(1)
            }
        }
    }

    // ── WKWebView 本体 ─────────────────────────────────────────────────
    private var webViewPane: some View {
        ZStack(alignment: .bottom) {
            WKWebViewRepresentable(webView: agent.webView)
                .frame(height: 210)

            // ボトムフェード
            LinearGradient(
                colors: [.clear, Color.black.opacity(0.28)],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: 38)
            .allowsHitTesting(false)

            // CAPTCHA オーバーレイ（タッチは WebView に通す）
            if agent.needsUserIntervention {
                captchaOverlay
                    .padding(.bottom, 14)
                    .transition(.opacity.animation(.easeInOut(duration: 0.22)))
                    .allowsHitTesting(false)
            }
        }
    }

    // ── CAPTCHA オーバーレイ ──────────────────────────────────────────
    private var captchaOverlay: some View {
        VStack(spacing: 7) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 22))
                .foregroundStyle(
                    LinearGradient(colors: [.orange, .red.opacity(0.85)],
                                   startPoint: .top, endPoint: .bottom)
                )
            Text("CAPTCHA 検出")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.primary)
            Text("手動で解除してください — 完了後に自動続行します")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // ── パネル背景 ────────────────────────────────────────────────────
    private var panelBackground: some View {
        ZStack {
            // ベース: 暗めのglassmorphism
            Color(red: 0.07, green: 0.07, blue: 0.09).opacity(0.96)
            // 左上グラデーションアクセント
            RadialGradient(
                colors: [Color.blue.opacity(0.10), Color.clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 120
            )
        }
    }
}

#endif  // canImport(WebKit)
