/*
仕様:
- 役割: StoryWorld の複数人チャット画面。現在の Scene と activeCharacters を表示し、
  発話者名付きの会話として進行する。
- 制約: activeCharacters は StoryScene 側の最大 3 名を尊重する。
*/

import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

#if canImport(AppKit)
private typealias StoryChatPlatformImage = NSImage
#elseif canImport(UIKit)
private typealias StoryChatPlatformImage = UIImage
#endif

private extension Image {
    init(storyChatPlatformImage: StoryChatPlatformImage) {
        #if canImport(AppKit)
        self.init(nsImage: storyChatPlatformImage)
        #elseif canImport(UIKit)
        self.init(uiImage: storyChatPlatformImage)
        #else
        self.init(systemName: "person.crop.square")
        #endif
    }
}

private let storyCanvas = Color(red: 0.07, green: 0.07, blue: 0.08)
private let storyPanel = Color(red: 0.12, green: 0.12, blue: 0.13)
private let storyBubble = Color(red: 0.16, green: 0.16, blue: 0.17)
private let storyPurple = Color(red: 0.08, green: 0.56, blue: 0.52)
private let storyWarmAccent = Color(red: 0.93, green: 0.66, blue: 0.22)
private let storyText = Color.white.opacity(0.92)
private let storyMuted = Color.white.opacity(0.58)

struct StorySessionChatView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let world: StoryWorld
    let initialSessionID: UUID?

    @StateObject private var detailVM: StoryWorldDetailViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var sessionVM: StorySessionViewModel?
    @State private var loadError: String?

    init(world: StoryWorld, initialSessionID: UUID? = nil) {
        self.world = world
        self.initialSessionID = initialSessionID
        _detailVM = StateObject(wrappedValue: StoryWorldDetailViewModel(world: world))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
            if let sessionVM {
                StorySessionChatBody(vm: sessionVM)
            } else if let loadError {
                ContentUnavailableView("ストーリーを開始できません", systemImage: "exclamationmark.triangle", description: Text(loadError))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView("世界を読み込んでいます...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(storyCanvas.ignoresSafeArea())
        .task(id: world.id) {
            guard sessionVM == nil else { return }
            await detailVM.reload()
            guard let (session, scene) = await detailVM.createOrResumeSession(preferredSessionID: initialSessionID) else {
                loadError = "開始シーンがありません。世界観の詳細からシーンを確認してください。"
                return
            }
            let vm = StorySessionViewModel(world: world, session: session, scene: scene)
            await vm.bootstrap()
            sessionVM = vm
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 22, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .foregroundStyle(storyText)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(world.title)
                    .font(.system(size: horizontalSizeClass == .compact ? 18 : 20, weight: .heavy))
                    .foregroundStyle(storyText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                if !world.shortDescription.isEmpty && horizontalSizeClass != .compact {
                    Text(world.shortDescription)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(storyMuted)
                        .lineLimit(1)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 4)

            if let sessionVM {
                StoryGenerationModelPill(vm: sessionVM)
                    .fixedSize(horizontal: true, vertical: false)
            }

            Menu {
                Button("セッションを閉じる") { dismiss() }
            } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(storyText)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, horizontalSizeClass == .compact ? 10 : 13)
        .background(storyCanvas)
    }
}

private struct StoryGenerationModelPill: View {
    @ObservedObject var vm: StorySessionViewModel
    @State private var isHovering = false
    @State private var isShowingDetails = false

    var body: some View {
        Menu {
            ForEach(StoryGenerationModel.allCases) { model in
                Button {
                    vm.generationModel = model
                } label: {
                    Label(model.detailLabel, systemImage: vm.generationModel == model ? "checkmark" : "cpu")
                }
                .help(modelHelpText(model))
            }
            Divider()
            Button {
                isShowingDetails = true
            } label: {
                Label("モデル詳細", systemImage: "info.circle")
            }
        } label: {
            HStack(spacing: 5) {
                Text(vm.generationModel.displayName)
                    .font(.system(size: 13, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(storyText)
            .frame(width: 76, height: 36)
            .padding(.horizontal, 14)
            .background(Capsule().fill(Color.white.opacity(0.16)))
        }
        .buttonStyle(.plain)
        .help(modelHelpText(vm.generationModel))
        .popover(isPresented: $isShowingDetails, arrowEdge: .top) {
            modelDetailPopover
                .padding(4)
        }
        .onHover { isHovering = $0 }
        .overlay(alignment: .topTrailing) {
            if isHovering {
                modelDetailPopover
                    .offset(y: -92)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .bottomTrailing)))
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    private var modelDetailPopover: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(vm.generationModel.detailLabel)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.primary)
            Text(modelShortDescription(vm.generationModel))
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(modelAvailabilityText(vm.generationModel))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(modelAvailabilityColor(vm.generationModel))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: 260, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.18), lineWidth: 1))
        .shadow(color: .black.opacity(0.24), radius: 14, x: 0, y: 8)
    }

    private func modelHelpText(_ model: StoryGenerationModel) -> String {
        "\(model.detailLabel): \(modelShortDescription(model))"
    }

    private func modelShortDescription(_ model: StoryGenerationModel) -> String {
        switch model {
        case .e4b:
            return "標準。短く反応し、会話テンポを優先します。"
        case .b31:
            return "Gemma4 31B API。描写、関係性の機微、場面の空気をより丁寧に出します。"
        }
    }

    private func modelAvailabilityText(_ model: StoryGenerationModel) -> String {
        switch model {
        case .e4b:
            return model.installedModelURL == nil ? "ローカル未導入時は利用可能モデルへフォールバック" : "ローカルモデル検出済み"
        case .b31:
            return StoryGemma31BAPIService.shared.hasAPIKey ? "Gemma4 APIキー検出済み" : "Gemma4 APIキー未設定"
        }
    }

    private func modelAvailabilityColor(_ model: StoryGenerationModel) -> Color {
        switch model {
        case .e4b:
            return model.installedModelURL == nil ? .orange : .green
        case .b31:
            return StoryGemma31BAPIService.shared.hasAPIKey ? .green : .orange
        }
    }
}

private struct StorySessionChatBody: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @ObservedObject var vm: StorySessionViewModel
    @ObservedObject private var service: StorySessionService
    @State private var draft = ""
    @State private var selectedCharacterID: UUID?
    @State private var isShowingCharacterSheet = false
    @FocusState private var composerFocused: Bool

    init(vm: StorySessionViewModel) {
        self.vm = vm
        _service = ObservedObject(wrappedValue: vm.service)
    }

    var body: some View {
        VStack(spacing: 0) {
            sceneStrip
            kizunaStatusStrip
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(vm.session.messages) { message in
                            messageRow(message)
                                .id(message.id)
                        }
                        if service.phase == .thinking, !service.streamingResponse.isEmpty {
                            streamingPreview
                        }
                    }
                    .padding(18)
                }
                .background(storyCanvas)
                .onChange(of: vm.session.messages.count) { _, _ in
                    if let last = vm.session.messages.last?.id {
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
                .onChange(of: service.streamingResponse) { _, _ in
                    if service.phase == .thinking {
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("streaming-preview", anchor: .bottom) }
                    }
                }
                .onChange(of: service.savedTurnRevision) { _, _ in
                    Task { await vm.refreshAfterTurn() }
                }
            }
            composer
        }
        .sheet(isPresented: $isShowingCharacterSheet) {
            StoryCharacterSpotlightSheet(
                characters: vm.activeCharacters,
                selectedCharacterID: selectedCharacterID,
                onSelect: { selectedCharacterID = $0 }
            )
            .presentationDetents([.medium, .large])
        }
    }

    private var sceneStrip: some View {
        Group {
            if horizontalSizeClass == .compact {
                compactSceneStrip
            } else {
                regularSceneStrip
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(storyCanvas)
    }

    private var regularSceneStrip: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(vm.scene.title.isEmpty ? "現在のシーン" : vm.scene.title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(storyText)
                HStack(spacing: 8) {
                    if !vm.scene.location.isEmpty {
                        Label(vm.scene.location, systemImage: "mappin.and.ellipse")
                    }
                    if !vm.scene.timeOfDay.isEmpty {
                        Label(vm.scene.timeOfDay, systemImage: "clock")
                    }
                    if !vm.scene.mood.isEmpty {
                        Label(vm.scene.mood, systemImage: "theatermasks")
                    }
                }
                .font(.system(size: 10.5))
                .foregroundStyle(storyMuted)
                .lineLimit(1)
            }
            Spacer()
            activeCharacterChips
        }
    }

    private var compactSceneStrip: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(vm.scene.title.isEmpty ? "現在のシーン" : vm.scene.title)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(storyText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 5) {
                if !vm.scene.location.isEmpty {
                    compactSceneMeta(icon: "mappin.and.ellipse", text: vm.scene.location)
                }
                if !vm.scene.timeOfDay.isEmpty {
                    compactSceneMeta(icon: "clock", text: vm.scene.timeOfDay)
                }
                if !vm.scene.mood.isEmpty {
                    compactSceneMeta(icon: "theatermasks", text: vm.scene.mood)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                activeCharacterChips
            }
        }
    }

    private func compactSceneMeta(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 14)
                .foregroundStyle(storyMuted)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(storyMuted)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var activeCharacterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
            ForEach(vm.activeCharacters.prefix(StoryConstants.maxActiveCharacters)) { character in
                Button {
                    selectedCharacterID = character.id
                    isShowingCharacterSheet = true
                } label: {
                    HStack(spacing: 5) {
                        characterAvatar(character, size: 18)
                        Text(character.displayName)
                            .font(.system(size: 10.5, weight: .bold))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(selectedCharacterID == character.id ? storyPurple.opacity(0.42) : Color.white.opacity(0.10)))
                    .overlay(Capsule().stroke(selectedCharacterID == character.id ? storyPurple.opacity(0.78) : Color.clear, lineWidth: 1))
                    .foregroundStyle(storyText)
                }
                .buttonStyle(.plain)
            }
            }
        }
    }

    private var kizunaStatusStrip: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "book.pages.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(storyWarmAccent)
                Text(progressTitle)
                    .font(.system(size: horizontalSizeClass == .compact ? 15 : 14, weight: .heavy))
                    .foregroundStyle(storyText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text("\(vm.session.messages.count)件")
                    .font(.system(size: 10.5, weight: .bold).monospacedDigit())
                    .foregroundStyle(storyMuted)
            }
            VStack(alignment: .leading, spacing: 5) {
                progressLine(label: "今回", text: currentTurnProgress)
                progressLine(label: "次", text: currentObjectiveText)
            }
            if !unresolvedHookText.isEmpty, unresolvedHookText != "なし" {
                progressLine(label: "気になること", text: unresolvedHookText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 13)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.065))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.09), lineWidth: 1)
        )
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .background(storyCanvas.opacity(0.96))
    }

    private var unresolvedHookText: String {
        vm.session.unresolvedHooks?.first?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "なし"
    }

    private var progressTitle: String {
        vm.session.progressLabel?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "第1章 きっかけ"
    }

    private var currentTurnProgress: String {
        vm.session.lastTurnProgress?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? vm.session.lastSceneSummary?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? "物語が始まったところ"
    }

    private var currentObjectiveText: String {
        vm.session.currentObjective?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? vm.scene.sceneGoal.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? vm.world.storyGoal.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? "次の会話を進める"
    }

    private func progressLine(label: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(storyWarmAccent.opacity(0.92))
                .frame(width: horizontalSizeClass == .compact ? 54 : 70, alignment: .leading)
            Text(text)
                .font(.system(size: horizontalSizeClass == .compact ? 12 : 12.5, weight: .semibold))
                .foregroundStyle(storyText.opacity(0.82))
                .lineLimit(horizontalSizeClass == .compact ? 3 : 2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func messageRow(_ message: StoryMessage) -> some View {
        switch message.author {
        case .user:
            HStack {
                Spacer(minLength: 80)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(message.text)
                        .font(.system(size: 14.5, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(storyPurple)
                        )
                    Text(message.createdAt, style: .time)
                        .font(.system(size: 10))
                        .foregroundStyle(storyMuted.opacity(0.72))
                }
            }
        case .narrator:
            HStack {
                Spacer(minLength: 28)
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 3) {
                        Image(systemName: "text.quote")
                            .font(.system(size: 14, weight: .semibold))
                        Text("場面")
                            .font(.system(size: 9, weight: .heavy))
                    }
                    .foregroundStyle(storyWarmAccent.opacity(0.78))
                    .frame(width: 34)
                    Text(message.text)
                        .font(.system(size: horizontalSizeClass == .compact ? 17 : 18, weight: .medium))
                        .foregroundStyle(storyText.opacity(0.80))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 620, alignment: .leading)
                Spacer(minLength: 28)
            }
        case let .cast(characterID, displayName):
            HStack(alignment: .bottom, spacing: 9) {
                characterAvatar(vm.characterIndex[characterID], fallbackName: displayName, size: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(displayName)
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(storyMuted)
                    Text(message.text)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(storyText.opacity(0.82))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(storyBubble)
                        )
                    Text(message.createdAt, style: .time)
                        .font(.system(size: 10))
                        .foregroundStyle(storyMuted.opacity(0.72))
                }
                Spacer(minLength: 80)
            }
        }
    }

    @ViewBuilder
    private func characterAvatar(_ character: CharacterProfile?, fallbackName: String = "?", size: CGFloat) -> some View {
        if let data = character?.avatarImageData, let image = storyChatPlatformImage(from: data) {
            Image(storyChatPlatformImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
        } else if let key = character?.imageKey, !key.isEmpty {
            Image(key)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
        } else {
            let name = character.map { $0.displayName.isEmpty ? $0.name : $0.displayName } ?? fallbackName
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.62, green: 0.68, blue: 0.95), Color(red: 0.18, green: 0.21, blue: 0.35)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: size, height: size)
                .overlay(
                    Text(String(name.prefix(1)).isEmpty ? "?" : String(name.prefix(1)))
                        .font(.system(size: max(10, size * 0.4), weight: .bold))
                        .foregroundStyle(.white)
                )
        }
    }

    private func storyChatPlatformImage(from data: Data) -> StoryChatPlatformImage? {
        #if canImport(AppKit)
        return NSImage(data: data)
        #elseif canImport(UIKit)
        return UIImage(data: data)
        #else
        return nil
        #endif
    }

    private var streamingPreview: some View {
        HStack(alignment: .top, spacing: 9) {
            ZStack {
                Circle()
                    .fill(storyPurple.opacity(0.22))
                    .frame(width: 30, height: 30)
                ProgressView()
                    .controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(storyPurple)
                        .frame(width: 7, height: 7)
                    Text("\(service.streamingSpeakerName ?? "キャラ") が話しています")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(storyText.opacity(0.86))
                    Text("Thinking")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(.white.opacity(0.72))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(storyPurple.opacity(0.32)))
                }
                Text(service.streamingResponse)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(storyText.opacity(0.78))
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(storyBubble)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(storyPurple.opacity(0.28), lineWidth: 1)
            )
            Spacer(minLength: 80)
        }
        .id("streaming-preview")
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField("相手に伝える...", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .focused($composerFocused)
                .lineLimit(1...4)
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
                .onSubmit(submit)
            Button {
                if service.phase == .thinking {
                    service.cancel()
                } else {
                    submit()
                }
            } label: {
                Image(systemName: service.phase == .thinking ? "stop.fill" : "paperplane.fill")
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(storyPurple))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(service.phase != .thinking && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(14)
        .background(storyPanel)
        .storyKeyboardDismissToolbar($composerFocused)
    }

    private func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, service.phase != .thinking else { return }
        draft = ""
        composerFocused = false
        vm.send(text)
    }
}

private struct StoryCharacterSpotlightSheet: View {
    let characters: [CharacterProfile]
    let selectedCharacterID: UUID?
    var onSelect: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss

    private var selected: CharacterProfile? {
        characters.first(where: { $0.id == selectedCharacterID }) ?? characters.first
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let selected {
                        StoryCharacterHero(character: selected)
                    }
                    if characters.count > 1 {
                        Text("登場キャラ")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            ForEach(characters) { character in
                                Button {
                                    onSelect(character.id)
                                } label: {
                                    VStack(spacing: 7) {
                                        StoryCharacterHero.image(for: character)
                                            .frame(width: 72, height: 72)
                                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                        Text(character.displayName)
                                            .font(.system(size: 11, weight: .bold))
                                            .lineLimit(1)
                                    }
                                    .padding(7)
                                    .background(
                                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                                            .fill(character.id == selected?.id ? storyPurple.opacity(0.18) : Color.primary.opacity(0.045))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                                            .stroke(character.id == selected?.id ? storyPurple.opacity(0.72) : Color.clear, lineWidth: 2)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(18)
            }
            .navigationTitle(selected?.displayName ?? "登場キャラ")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }
}

private struct StoryCharacterHero: View {
    let character: CharacterProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Self.image(for: character)
                .frame(maxWidth: .infinity)
                .frame(height: 360)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 5) {
                Text(character.displayName)
                    .font(.system(size: 30, weight: .heavy))
                    .foregroundStyle(storyText)
                if !character.shortDescription.isEmpty {
                    Text(character.shortDescription)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(storyMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            info("口調", character.speakingStyle)
            info("性格", character.personality)
            info("ユーザーとの関係", character.relationshipToUser)
            info("背景", character.background)
        }
    }

    @ViewBuilder
    static func image(for character: CharacterProfile) -> some View {
        if let data = character.avatarImageData, let image = storySpotlightPlatformImage(from: data) {
            Image(storyChatPlatformImage: image)
                .resizable()
                .scaledToFill()
        } else if let key = character.imageKey, !key.isEmpty {
            Image(key)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                LinearGradient(colors: [storyPurple.opacity(0.75), Color.black.opacity(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Text(String(character.displayName.prefix(1)))
                    .font(.system(size: 56, weight: .heavy))
                    .foregroundStyle(.white)
            }
        }
    }

    private func info(_ title: String, _ value: String) -> some View {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return Group {
            if !trimmed.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                    Text(trimmed)
                        .font(.system(size: 14, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private func storySpotlightPlatformImage(from data: Data) -> StoryChatPlatformImage? {
    #if canImport(AppKit)
    return NSImage(data: data)
    #elseif canImport(UIKit)
    return UIImage(data: data)
    #else
    return nil
    #endif
}

private extension View {
    @ViewBuilder
    func storyKeyboardDismissToolbar(_ focused: FocusState<Bool>.Binding) -> some View {
        #if canImport(UIKit)
        self.toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("閉じる") { focused.wrappedValue = false }
            }
        }
        #else
        self
        #endif
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
