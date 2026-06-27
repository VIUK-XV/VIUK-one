/*
仕様:
- 役割: アプリのホーム画面。Web、学習、AIへの入口を1画面に統合する。
- 主な型: `HomeScreenView`.
- 編集ポイント: ホームカード、クイックリンク、学習導線、見た目構成を変えるときに触る。
*/

import SwiftUI

private func dismissHomeKeyboard() {
    #if canImport(UIKit)
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    #endif
}

// MARK: - Enhanced Browser-Style Home Screen
struct HomeScreenView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @FocusState private var searchFieldFocused: Bool
    @Binding var searchText: String
    let onSearch: (String) -> Void
    let onQuickLinkTap: (String) -> Void
    let onOpenAICoach: (() -> Void)?
    @State private var frequentSites: [(url: String, title: String, visits: Int)] = []
    @State private var recentlyClosed: [(url: String, title: String)] = []
    @State private var dashboardSnapshot = DashboardSnapshot.placeholder
    @State private var dashboardRefreshWorkItem: DispatchWorkItem?
    @State private var showCustomization = false
    @State private var showLauncherSettings = false
    @State private var backgroundStyle: BackgroundStyle = .gradient
    @State private var showFavorites = true
    @State private var showFrequentSites = true
    @State private var showRecentlyClosed = true
    @State private var showImportedApps = false
    @State private var showGameCenter = false
    @State private var showLearningLibrary = false
    @State private var showMapWorkspace = false
    @State private var showLoveWorkspace = false
    @State private var showLoveCardWorkspace = false
    @State private var selectedLauncherApp: LauncherAppCard?
    @State private var selectedLauncherDetailPageID = "overview"
    @AppStorage("viuk.home.focusMode") private var focusModeRawValue = HomeFocusMode.explorer.rawValue
    @AppStorage("viuk.home.currentSafetyPreset") private var safetyPresetRawValue = HomeSafetyPreset.balanced.rawValue
    @AppStorage("viuk.home.completedQuestTokens") private var completedQuestTokensStorage = ""
    @AppStorage("viuk.home.rewardPoints") private var rewardPoints = 0
    @AppStorage("viuk.home.lastLearningActionDay") private var lastLearningActionDay = ""
    @AppStorage("viuk.home.lastAICoachActionDay") private var lastAICoachActionDay = ""
    @AppStorage("viuk.home.lastPresetActionDay") private var lastPresetActionDay = ""
    @AppStorage("viuk.home.focusSprintStartTimestamp") private var focusSprintStartTimestamp = 0.0
    @AppStorage("viuk.home.focusSprintEndTimestamp") private var focusSprintEndTimestamp = 0.0
    @AppStorage("viuk.home.lastOpenedWorkspaceID") private var lastOpenedWorkspaceID = ""
    @AppStorage("viuk.home.lastOpenedWorkspaceTitle") private var lastOpenedWorkspaceTitle = ""
    @AppStorage("viuk.home.lastSearchQuery") private var lastSearchQuery = ""
    @AppStorage("viuk.home.showMoreWorkspaces") private var showMoreWorkspaces = false
    @AppStorage("viuk.home.showHubControls") private var showHubControls = false
    @AppStorage("viuk.launcher.backgroundStyle") private var launcherBackgroundStyleRawValue = BackgroundStyle.gradient.rawValue
    @AppStorage("viuk.launcher.autoFocusSearchField") private var launcherAutoFocusSearchField = false
    @AppStorage("viuk.launcher.importedAppsExpanded") private var launcherImportedAppsExpanded = false

    enum BackgroundStyle: String, CaseIterable {
        case gradient = "グラデーション"
        case solid = "単色"
        case blur = "ぼかし"
    }

    private struct DashboardActionCard: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let status: String
        let icon: String
        let palette: [Color]
        let action: () -> Void
    }

    private struct LauncherAppCard: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let category: String
        let status: String
        let icon: String
        let palette: [Color]
        let launchMode: String
        let capabilities: [String]
        let technicalSpecs: [String]
        let dataBoundary: String
        let runtimeNotes: String
        let action: () -> Void
    }

    private struct LauncherDetailPage: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let icon: String
        let groups: [LauncherDetailGroup]
    }

    private struct LauncherDetailGroup: Identifiable {
        let id: String
        let title: String
        let icon: String
        let items: [String]
    }

    private struct ImportedWorkspaceCard: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let status: String
        let icon: String
        let tint: Color
        let action: () -> Void
    }

    private struct DashboardQuest: Identifiable {
        let id: String
        let title: String
        let detail: String
        let progress: Double
        let reward: Int
        let isComplete: Bool
        let accent: Color
        let actionTitle: String
        let action: () -> Void
    }

    private struct DashboardSnapshot {
        let todaySafeVisits: Int
        let todayBlockCount: Int
        let todayPersonalInfoCount: Int
        let topInterestLabel: String
        let safeDayStreak: Int
        let frequentSites: [(url: String, title: String, visits: Int)]
        let recentlyClosed: [(url: String, title: String)]

        static let placeholder = DashboardSnapshot(
            todaySafeVisits: 0,
            todayBlockCount: 0,
            todayPersonalInfoCount: 0,
            topInterestLabel: "読み込み中",
            safeDayStreak: 0,
            frequentSites: [],
            recentlyClosed: []
        )

        static func build(recentlyClosedTabs: [(url: String, title: String)] = []) -> DashboardSnapshot {
            return DashboardSnapshot(
                todaySafeVisits: 0,
                todayBlockCount: 0,
                todayPersonalInfoCount: 0,
                topInterestLabel: "アプリ一覧",
                safeDayStreak: 0,
                frequentSites: [],
                recentlyClosed: recentlyClosedTabs
            )
        }

        private static func dayStamp(for date: Date) -> String {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "ja_JP_POSIX")
            formatter.timeZone = TimeZone.current
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: date)
        }
    }

    private var currentFocusMode: HomeFocusMode {
        get { HomeFocusMode(rawValue: focusModeRawValue) ?? .explorer }
        nonmutating set { focusModeRawValue = newValue.rawValue }
    }

    private var currentSafetyPreset: HomeSafetyPreset {
        get { HomeSafetyPreset(rawValue: safetyPresetRawValue) ?? .balanced }
        nonmutating set { safetyPresetRawValue = newValue.rawValue }
    }

    private var todayStamp: String {
        dayStamp(for: Date())
    }

    private var completedQuestTokens: Set<String> {
        Set(completedQuestTokensStorage.split(separator: ",").map(String.init).filter { !$0.isEmpty })
    }

    private var todaySafeVisits: Int {
        dashboardSnapshot.todaySafeVisits
    }

    private var todayBlockCount: Int {
        dashboardSnapshot.todayBlockCount
    }

    private var todayPersonalInfoCount: Int {
        dashboardSnapshot.todayPersonalInfoCount
    }

    private var topInterestLabel: String {
        dashboardSnapshot.topInterestLabel
    }

    private var safeDayStreak: Int {
        dashboardSnapshot.safeDayStreak
    }

    private var aiStatusLabel: String {
        "AI Studio"
    }

    private var focusSprintDuration: TimeInterval {
        max(0, focusSprintEndTimestamp - focusSprintStartTimestamp)
    }

    private var focusSprintActive: Bool {
        focusSprintRemaining(referenceDate: Date()) > 0
    }

    private var launcherApps: [LauncherAppCard] {
        [
            LauncherAppCard(
                id: "browse",
                title: "Safe Browse",
                subtitle: "検索、URL閲覧、フィルタリングを担当する保護ブラウザ。",
                category: "Browser App",
                status: "今日 \(todaySafeVisits) 件の安全閲覧",
                icon: "shield.checkerboard",
                palette: [Color(red: 0.12, green: 0.45, blue: 0.87), Color(red: 0.14, green: 0.70, blue: 0.76)],
                launchMode: "Main tab route: onQuickLinkTap / onSearch",
                capabilities: ["検索とURL入力", "SafeSearch適用", "URL/本文フィルタリング", "閲覧・ブロック履歴"],
                technicalSpecs: ["Entry: MainView web tab", "History: BrowsingHistoryManager", "Protection: ParentalControlCore / Safe Browse policy", "Launch: openSafeBrowseWorkspace(query:)"],
                dataBoundary: "Safe Browse の履歴、ブロック記録、保護設定を扱う。他アプリの会話・学習データは読まない。",
                runtimeNotes: "VIUK One 本体タブ上で動く。検索欄からも同じSafe Browseへ入る。",
                action: { openSafeBrowseWorkspace() }
            ),
            LauncherAppCard(
                id: "learn",
                title: "Learning Arena",
                subtitle: "教材、復習、提出、学習パックを扱う学習アプリ。",
                category: "Learning App",
                status: "ストリーク \(safeDayStreak) 日",
                icon: "books.vertical.fill",
                palette: [Color(red: 0.16, green: 0.62, blue: 0.58), Color(red: 0.88, green: 0.93, blue: 0.51)],
                launchMode: "WindowGroup: learning-center / sheet fallback",
                capabilities: ["教材ライブラリー", "学習ユニット", "回答・採点", "復習アイテム"],
                technicalSpecs: ["Entry: LearningContentCenterView", "WindowGroup id: learning-center", "SwiftData: LearningContentPackModel and related models", "Launch: openLearningCenter(recordAction:)"],
                dataBoundary: "学習用SwiftDataモデルを使う。Safe Browse のブロック判定や AI Studio のスレッドとは分離する。",
                runtimeNotes: "macOSでは別ウィンドウ、iOSではシートとして開く。",
                action: { openLearningCenter(recordAction: true) }
            ),
            LauncherAppCard(
                id: "ai_assist",
                title: "AI Studio",
                subtitle: "通常会話、Thinking、Deep Research、絆を扱う会話アプリ。",
                category: "AI App",
                status: "AI \(aiStatusLabel)",
                icon: "sparkles.rectangle.stack.fill",
                palette: [Color(red: 0.92, green: 0.33, blue: 0.31), Color(red: 0.99, green: 0.72, blue: 0.27)],
                launchMode: "WindowGroup: ai-center / in-app callback",
                capabilities: ["通常チャット", "検索付き推論", "絆ストーリー", "ローカル/外部モデル状態表示"],
                technicalSpecs: ["Entry: AIStudioWorkspaceView", "WindowGroup id: ai-center", "Local runtime: LocalAssistantRuntimeBridge", "Launch: openAICoachPanel()"],
                dataBoundary: "AI Studio のスレッド、メモリー、モデル設定はAI Studio側で扱う。Safe Browse設定を通常会話へ混ぜない。",
                runtimeNotes: "一般UIではAPIキー管理を前面に出さない。モデル状態はAI Studio内で確認する。",
                action: { openAICoachPanel() }
            ),
            LauncherAppCard(
                id: "map",
                title: "Map Atlas",
                subtitle: "目的地検索、地図、ナビ導線を扱う地図アプリ。",
                category: "Map App",
                status: "iPhone起点UIをMac互換で表示",
                icon: "map.circle.fill",
                palette: [Color(red: 0.10, green: 0.58, blue: 0.89), Color(red: 0.33, green: 0.83, blue: 0.63)],
                launchMode: "WindowGroup: map-center / sheet fallback",
                capabilities: ["地図表示", "目的地検索", "ルート導線", "場所の確認"],
                technicalSpecs: ["Entry: VIUKMapWorkspaceView", "WindowGroup id: map-center", "Framework: MapKit", "Launch: openMapWorkspace()"],
                dataBoundary: "Map固有の状態と場所情報を扱う。AI StudioやLoveの会話状態とは共有しない。",
                runtimeNotes: "macOSでは別ウィンドウ、iOSではシートとして開く。",
                action: { openMapWorkspace() }
            ),
            LauncherAppCard(
                id: "love",
                title: "Love Lab",
                subtitle: "相性診断、相談支援、気分記録を扱う関係性アプリ。",
                category: "Relationship App",
                status: "ローカル完結の関係性ワークスペース",
                icon: "heart.circle.fill",
                palette: [Color(red: 0.93, green: 0.34, blue: 0.54), Color(red: 0.99, green: 0.71, blue: 0.38)],
                launchMode: "WindowGroup: love-center / sheet fallback",
                capabilities: ["相性診断", "相談整理", "気分記録", "関係性ワークスペース"],
                technicalSpecs: ["Entry: VIUKLoveWorkspaceView", "WindowGroup id: love-center", "Launch: openLoveWorkspace()", "Storage: app-local relationship state"],
                dataBoundary: "Love内の記録はLoveの文脈で扱う。Safe BrowseやAI Studioの一般会話とは混ぜない。",
                runtimeNotes: "macOSでは別ウィンドウ、iOSではシートとして開く。",
                action: { openLoveWorkspace() }
            ),
            LauncherAppCard(
                id: "love_cards",
                title: "Love Cards",
                subtitle: "恋愛カードを並べて見るホーム専用のカードアプリ。",
                category: "Card App",
                status: "カード専用UI",
                icon: "heart.rectangle.fill",
                palette: [Color(red: 0.92, green: 0.38, blue: 0.58), Color(red: 0.98, green: 0.67, blue: 0.43)],
                launchMode: "Sheet: VIUKLoveCardHomeWorkspaceView",
                capabilities: ["カード閲覧", "関係テーマの整理", "ホームからの軽量起動"],
                technicalSpecs: ["Entry: VIUKLoveCardHomeWorkspaceView", "Launch: openLoveCardWorkspace()", "Window: sheet-only currently", "Origin: home-accessed separate Swift view"],
                dataBoundary: "Love Cardsはカード表示専用。Love Lab本体の設定やAI Studioの会話とは別導線にする。",
                runtimeNotes: "現状はシート起動。独立アプリ扱いとしてカードUIを維持する。",
                action: { openLoveCardWorkspace() }
            ),
            LauncherAppCard(
                id: "safekids_classic",
                title: "SafeKids Classic",
                subtitle: "SafeKids Search 2.0系の役割を保ったレガシー保護アプリ。",
                category: "Imported App",
                status: "履歴・ブロック・設定を個別アプリ化",
                icon: "shield.lefthalf.filled",
                palette: [Color.indigo, Color.blue],
                launchMode: "WindowGroup: safekids-classic-center",
                capabilities: ["レガシー保護導線", "ブロック履歴", "閲覧履歴", "保護設定"],
                technicalSpecs: ["Entry: SafeKidsClassicWorkspaceView", "WindowGroup id: safekids-classic-center", "Launch: openSafeKidsClassicWorkspace()", "Migration: imported app wrapper"],
                dataBoundary: "SafeKids Classicは旧SafeKids文脈を保つ。VIUK One本体の新ホームに設定を吸収しない。",
                runtimeNotes: "macOSは別ウィンドウで開く。移植元の役割を残す。",
                action: { openSafeKidsClassicWorkspace() }
            ),
            LauncherAppCard(
                id: "enext",
                title: "e next",
                subtitle: "第1世代の学習導線をまとめた独立学習アプリ。",
                category: "Imported App",
                status: "ドリル・計算バトル・プロフィール",
                icon: "graduationcap.fill",
                palette: [Color.green, Color.mint],
                launchMode: "WindowGroup: enext-center",
                capabilities: ["学習ドリル", "計算バトル", "プロフィール", "旧学習導線"],
                technicalSpecs: ["Entry: ENextWorkspaceView", "WindowGroup id: enext-center", "Launch: openENextWorkspace()", "Migration: imported learning app"],
                dataBoundary: "e next固有の学習体験として扱う。Learning Arenaとは別アプリとして見せる。",
                runtimeNotes: "macOSは別ウィンドウで開く。旧アプリの流れを保持する。",
                action: { openENextWorkspace() }
            ),
            LauncherAppCard(
                id: "microwave",
                title: "Microwave",
                subtitle: "電子レンジ時間計算を扱う小型ユーティリティアプリ。",
                category: "Utility App",
                status: "換算・ガイド・設定の3タブ",
                icon: "clock.arrow.trianglehead.counterclockwise.rotate.90",
                palette: [Color.orange, Color.yellow],
                launchMode: "WindowGroup: microwave-center",
                capabilities: ["時間換算", "加熱ガイド", "設定タブ"],
                technicalSpecs: ["Entry: MicrowaveTimeWorkspaceView", "WindowGroup id: microwave-center", "Launch: openMicrowaveWorkspace()", "Scope: standalone utility"],
                dataBoundary: "Microwaveはユーティリティとして独立。保護設定やAI会話とは共有しない。",
                runtimeNotes: "macOSは別ウィンドウで開く。軽量な単機能アプリとして扱う。",
                action: { openMicrowaveWorkspace() }
            ),
            LauncherAppCard(
                id: "science_club",
                title: "Science Club",
                subtitle: "Science Club One2をsource-firstで移植した実験アプリ。",
                category: "Imported App",
                status: "開いた時だけ本体を遅延展開",
                icon: "atom",
                palette: [Color.purple, Color.cyan],
                launchMode: "WindowGroup: science-club-center",
                capabilities: ["実験メモ", "心の記録", "Tetris", "Open World", "Science Club AI"],
                technicalSpecs: ["Entry: ScienceClubWorkspaceView", "WindowGroup id: science-club-center", "SwiftData: ScienceClubSourceMoodEntry / Chat models", "Runtime: deferred load"],
                dataBoundary: "Science Clubは別世界として扱う。VIUK One本体設定やAI Studioのスレッドへ統合しない。",
                runtimeNotes: "初回表示では本体を全読込しない。ユーザーが開いた時に展開する。",
                action: { openScienceClubWorkspace() }
            )
        ]
    }

    private func launcherDetailPages(for app: LauncherAppCard) -> [LauncherDetailPage] {
        let overview = LauncherDetailPage(
            id: "overview",
            title: "概要",
            subtitle: "このアプリがVIUK One内で担当する役割",
            icon: "doc.text.magnifyingglass",
            groups: [
                LauncherDetailGroup(
                    id: "role",
                    title: "アプリの役割",
                    icon: app.icon,
                    items: [
                        app.subtitle,
                        "カテゴリ: \(app.category)",
                        "現在の状態: \(app.status)",
                        "ホームでは独立アプリとして扱い、他アプリの設定やデータをこのカードに混ぜない。"
                    ]
                ),
                LauncherDetailGroup(
                    id: "capabilities",
                    title: "できること",
                    icon: "checkmark.seal.fill",
                    items: app.capabilities
                )
            ]
        )

        let ux = LauncherDetailPage(
            id: "ux",
            title: "UX",
            subtitle: "ユーザーがどこから入り、何をする画面か",
            icon: "rectangle.3.group.fill",
            groups: [
                LauncherDetailGroup(
                    id: "entry",
                    title: "入口と導線",
                    icon: "arrow.up.right.circle.fill",
                    items: [
                        "ホームカードの「開く」から直接起動する。",
                        "詳細シート内の「\(app.title) を開く」からも同じ起動処理を呼ぶ。",
                        "ホームの検索欄はSafe Browse専用のクイック入口。\(app.title)の設定や状態は詳細シート側で確認する。"
                    ]
                ),
                LauncherDetailGroup(
                    id: "display",
                    title: "表示方針",
                    icon: "macwindow.and.cursorarrow",
                    items: [
                        "カードにはタイトル、短い説明、状態、開く/詳細だけを表示する。",
                        "実装名や保存データなどの濃い情報は詳細ページに分離する。",
                        "iPhoneでは1列カード、iPad/macOSではグリッドとして見せる。"
                    ]
                )
            ]
        )

        let technical = LauncherDetailPage(
            id: "technical",
            title: "技術仕様",
            subtitle: "実装名、起動方式、ランタイムの境界",
            icon: "curlybraces.square.fill",
            groups: [
                LauncherDetailGroup(
                    id: "specs",
                    title: "実装仕様",
                    icon: "curlybraces.square.fill",
                    items: app.technicalSpecs
                ),
                LauncherDetailGroup(
                    id: "launch",
                    title: "起動方式",
                    icon: "rectangle.2.swap",
                    items: [
                        app.launchMode,
                        "Launcher action: \(app.id)",
                        "Runtime notes: \(app.runtimeNotes)"
                    ]
                )
            ]
        )

        let boundary = LauncherDetailPage(
            id: "boundary",
            title: "データ境界",
            subtitle: "保存データ、他アプリとの分離、混ぜない情報",
            icon: "internaldrive.fill",
            groups: [
                LauncherDetailGroup(
                    id: "storage",
                    title: "保存データ",
                    icon: "internaldrive.fill",
                    items: [app.dataBoundary]
                ),
                LauncherDetailGroup(
                    id: "separation",
                    title: "他アプリとの境界",
                    icon: "square.3.layers.3d.down.right",
                    items: [
                        "VIUK Oneホームは入口だけを持つ。各アプリの中身、履歴、モデル状態、設定は原則として各アプリ側に置く。",
                        "Safe Browseの保護状態、AI Studioのモデル状態、Love/絆のストーリー状態、Science Clubの世界観データをホーム上部に混ぜない。",
                        "詳細ページは仕様確認用で、通常操作は「開く」ボタンから各アプリ内で行う。"
                    ]
                )
            ]
        )

        switch app.id {
        case "browse":
            return [overview] + [
                LauncherDetailPage(
                    id: "protection",
                    title: "保護仕様",
                    subtitle: "Safe Browseだけが持つ検索・保護の情報",
                    icon: "shield.checkerboard",
                    groups: [
                        LauncherDetailGroup(
                            id: "filters",
                            title: "フィルタリング",
                            icon: "line.3.horizontal.decrease.circle.fill",
                            items: [
                                "SafeSearch、URLポリシー、本文判定、ブロック履歴を扱う。",
                                "今日の安全閲覧: \(todaySafeVisits) 件 / ブロック: \(todayBlockCount) 件 / 個人情報検知: \(todayPersonalInfoCount) 件",
                                "保護プリセット: \(currentSafetyPreset.title)",
                                "この情報はSafe Browse固有。ホームのランチャーヘッダーには出さない。"
                            ]
                        )
                    ]
                )
            ] + [ux, technical, boundary]
        case "ai_assist":
            return [overview] + [
                LauncherDetailPage(
                    id: "models",
                    title: "AI構成",
                    subtitle: "会話、Thinking、絆、モデル状態",
                    icon: "cpu.fill",
                    groups: [
                        LauncherDetailGroup(
                            id: "model-state",
                            title: "モデル表示",
                            icon: "switch.2",
                            items: [
                                "通常チャット、検索付き推論、絆ストーリーはAI Studio側でモデル状態を表示する。",
                                "ローカルモデルとAPIモデルは代替表示にしない。実際に使ったバックエンドを応答メタ情報として扱う。",
                                "ホームではAIのAPIキーやローカル起動状態を大きく出さず、AI Studio内の詳細で確認する。"
                            ]
                        )
                    ]
                )
            ] + [ux, technical, boundary]
        case "science_club":
            return [overview] + [
                LauncherDetailPage(
                    id: "source-first",
                    title: "移植仕様",
                    subtitle: "Science Club One2を独立世界として扱う",
                    icon: "shippingbox.fill",
                    groups: [
                        LauncherDetailGroup(
                            id: "deferred",
                            title: "遅延展開",
                            icon: "hourglass",
                            items: [
                                "ホーム表示時にはScience Club本体を読み込まない。",
                                "ユーザーが開いた時だけ、実験メモ、心の記録、Tetris、Open World、AI導線を展開する。",
                                "VIUK Oneの保護設定やAI Studioの会話履歴へ統合しない。"
                            ]
                        )
                    ]
                )
            ] + [ux, technical, boundary]
        default:
            return [overview, ux, technical, boundary]
        }
    }

    private var importedWorkspaceCards: [ImportedWorkspaceCard] {
        [
            ImportedWorkspaceCard(
                id: "safekids_classic",
                title: "SafeKids Classic",
                subtitle: "SafeKids Search2.0 の役割を保ったレガシー保護アプリ",
                status: "履歴・ブロック・設定を個別アプリ化",
                icon: "shield.lefthalf.filled",
                tint: .indigo,
                action: { openSafeKidsClassicWorkspace() }
            ),
            ImportedWorkspaceCard(
                id: "enext",
                title: "e next",
                subtitle: "第1世代の学習導線をまとめた独立学習アプリ",
                status: "ドリル・計算バトル・プロフィール",
                icon: "books.vertical.fill",
                tint: .green,
                action: { openENextWorkspace() }
            ),
            ImportedWorkspaceCard(
                id: "microwave",
                title: "Microwave",
                subtitle: "電子レンジ時間計算アプリをそのまま別アプリ化",
                status: "換算・ガイド・設定の3タブ",
                icon: "clock.arrow.trianglehead.counterclockwise.rotate.90",
                tint: .orange,
                action: { openMicrowaveWorkspace() }
            ),
            ImportedWorkspaceCard(
                id: "science_club",
                title: "Science Club",
                subtitle: "Science Club One2 を遅延起動で統合した実験ワークスペース",
                status: "起動時は未読込、開いた時だけ本体を展開",
                icon: "atom",
                tint: .purple,
                action: { openScienceClubWorkspace() }
            )
        ]
    }

    private var workspaceCards: [DashboardActionCard] {
        [
            DashboardActionCard(
                id: "browse",
                title: "Safe Browse",
                subtitle: "検索・URL閲覧・保護機能をまとめて使う",
                status: "今日 \(todaySafeVisits) 件の安全閲覧",
                icon: "shield.checkerboard",
                palette: currentFocusMode.palette,
                action: { openSafeBrowseWorkspace() }
            ),
            DashboardActionCard(
                id: "learn",
                title: "Learning Arena",
                subtitle: "教材・復習・学習の流れへそのまま入る",
                status: "ストリーク \(safeDayStreak) 日",
                icon: "books.vertical.fill",
                palette: [Color(red: 0.16, green: 0.62, blue: 0.58), Color(red: 0.88, green: 0.93, blue: 0.51)],
                action: { openLearningCenter(recordAction: true) }
            ),
            DashboardActionCard(
                id: "ai_assist",
                title: "AI Studio",
                subtitle: "要約・相談・学習補助を1ヶ所で使う",
                status: "残り \(aiStatusLabel)",
                icon: "sparkles.rectangle.stack.fill",
                palette: [Color(red: 0.92, green: 0.33, blue: 0.31), Color(red: 0.99, green: 0.72, blue: 0.27)],
                action: { openAICoachPanel() }
            ),
            DashboardActionCard(
                id: "map",
                title: "Map Atlas",
                subtitle: "地図、目的地検索、ナビ導線をワークスペース化",
                status: "iPhone起点 UI を Mac 互換で表示",
                icon: "map.circle.fill",
                palette: [Color(red: 0.10, green: 0.58, blue: 0.89), Color(red: 0.33, green: 0.83, blue: 0.63)],
                action: { openMapWorkspace() }
            ),
            DashboardActionCard(
                id: "love",
                title: "Love Lab",
                subtitle: "相性診断、相談支援、気分記録を統合",
                status: "ローカル完結の関係性ワークスペース",
                icon: "heart.circle.fill",
                palette: [Color(red: 0.93, green: 0.34, blue: 0.54), Color(red: 0.99, green: 0.71, blue: 0.38)],
                action: { openLoveWorkspace() }
            ),
            DashboardActionCard(
                id: "love_cards",
                title: "Love Cards",
                subtitle: "恋愛カードを並べるホーム導線",
                status: "カード専用UI",
                icon: "heart.rectangle.fill",
                palette: [Color(red: 0.92, green: 0.38, blue: 0.58), Color(red: 0.98, green: 0.67, blue: 0.43)],
                action: { openLoveCardWorkspace() }
            ),
            DashboardActionCard(
                id: "sprint",
                title: "Focus Sprint",
                subtitle: "20分集中と5分休けいをすぐ切り替える",
                status: focusSprintActive ? compactRemainingString(focusSprintRemaining(referenceDate: Date())) : "20分スタート可能",
                icon: "timer.circle.fill",
                palette: [Color(red: 0.29, green: 0.24, blue: 0.54), Color(red: 0.88, green: 0.56, blue: 0.32)],
                action: { startFocusSprint(minutes: focusSprintActive ? 5 : 20) }
            )
        ]
    }

    private var suggestionCards: [DashboardActionCard] {
        var cards: [DashboardActionCard] = []

        if let recent = recentlyClosed.first {
            cards.append(
                DashboardActionCard(
                    id: "resume_recent",
                    title: "直前の続きへ",
                    subtitle: recent.title,
                    status: "最近閉じたタブ",
                    icon: "arrow.uturn.backward.circle.fill",
                    palette: [Color(red: 0.14, green: 0.45, blue: 0.89), Color(red: 0.17, green: 0.74, blue: 0.86)],
                    action: { onQuickLinkTap(recent.url) }
                )
            )
        }

        cards.append(
            DashboardActionCard(
                id: "focus_query",
                title: "\(currentFocusMode.title) モード検索",
                subtitle: currentFocusMode.sparks.first ?? "安心して調べよう",
                status: "Search Spark",
                icon: currentFocusMode.icon,
                palette: currentFocusMode.palette,
                action: { triggerSearchSpark(currentFocusMode.sparks.first ?? "子ども向け 学び") }
            )
        )

        cards.append(
            DashboardActionCard(
                id: "learning",
                title: "今日の学習ミッション",
                subtitle: "教材と復習に入る",
                status: lastLearningActionDay == todayStamp ? "今日達成済み" : "1タップで開始",
                icon: "books.vertical.fill",
                palette: [Color(red: 0.16, green: 0.57, blue: 0.48), Color(red: 0.88, green: 0.93, blue: 0.51)],
                action: { openLearningCenter(recordAction: true) }
            )
        )

        cards.append(
            DashboardActionCard(
                id: "ai",
                title: "AI に整理してもらう",
                subtitle: todayBlockCount > 0 ? "最近のブロック理由を説明してもらう" : "気になるテーマをAIに相談する",
                status: "AI \(aiStatusLabel)",
                icon: "brain.head.profile",
                palette: [Color(red: 0.92, green: 0.40, blue: 0.29), Color(red: 0.99, green: 0.72, blue: 0.27)],
                action: { openAICoachPanel() }
            )
        )

        cards.append(
            DashboardActionCard(
                id: "map_jump",
                title: "Map で移動計画",
                subtitle: "目的地検索やルート確認をすぐ始める",
                status: "Map Workspace",
                icon: "location.circle.fill",
                palette: [Color(red: 0.14, green: 0.55, blue: 0.88), Color(red: 0.24, green: 0.83, blue: 0.64)],
                action: { openMapWorkspace() }
            )
        )

        cards.append(contentsOf: [
            DashboardActionCard(
                id: "love_jump",
                title: "Love で会話整理",
                subtitle: "相性診断や相談支援にすぐ入る",
                status: "Love Workspace",
                icon: "heart.text.square.fill",
                palette: [Color(red: 0.92, green: 0.31, blue: 0.47), Color(red: 0.98, green: 0.66, blue: 0.42)],
                action: { openLoveWorkspace() }
            ),
            DashboardActionCard(
                id: "love_cards_jump",
                title: "Love Cards を開く",
                subtitle: "ホームから入る恋愛カード画面",
                status: "Card Workspace",
                icon: "heart.rectangle.fill",
                palette: [Color(red: 0.91, green: 0.37, blue: 0.57), Color(red: 0.98, green: 0.69, blue: 0.44)],
                action: { openLoveCardWorkspace() }
            )
        ])

        return cards
    }

    private var quests: [DashboardQuest] {
        [
            DashboardQuest(
                id: "explore3",
                title: "Safe Explorer",
                detail: "今日は安全なページを3件見る",
                progress: min(1, Double(todaySafeVisits) / 3.0),
                reward: 18,
                isComplete: isQuestComplete("explore3"),
                accent: Color(red: 0.20, green: 0.78, blue: 0.92),
                actionTitle: todaySafeVisits >= 3 ? "達成済み" : "おすすめ検索",
                action: { triggerSearchSpark(currentFocusMode.sparks.first ?? "世界のふしぎ 子ども向け") }
            ),
            DashboardQuest(
                id: "learn",
                title: "Learning Pulse",
                detail: "学習センターを1回開く",
                progress: lastLearningActionDay == todayStamp ? 1 : 0,
                reward: 22,
                isComplete: isQuestComplete("learn"),
                accent: Color(red: 0.18, green: 0.70, blue: 0.57),
                actionTitle: lastLearningActionDay == todayStamp ? "達成済み" : "学習へ",
                action: { openLearningCenter(recordAction: true) }
            ),
            DashboardQuest(
                id: "coach",
                title: "AI Assist",
                detail: "AIに1回相談して整理する",
                progress: lastAICoachActionDay == todayStamp ? 1 : 0,
                reward: 20,
                isComplete: isQuestComplete("coach"),
                accent: Color(red: 0.96, green: 0.58, blue: 0.27),
                actionTitle: lastAICoachActionDay == todayStamp ? "達成済み" : "AIへ",
                action: { openAICoachPanel() }
            ),
            DashboardQuest(
                id: "preset",
                title: "Guardian Switch",
                detail: "今日の保護プリセットを選ぶ",
                progress: lastPresetActionDay == todayStamp ? 1 : 0,
                reward: 16,
                isComplete: isQuestComplete("preset"),
                accent: Color(red: 0.97, green: 0.42, blue: 0.56),
                actionTitle: lastPresetActionDay == todayStamp ? "達成済み" : "プリセット",
                action: { applySafetyPreset(.shield) }
            ),
            DashboardQuest(
                id: "sprint",
                title: "Focus Sprint",
                detail: "20分の集中スプリントを走り切る",
                progress: sprintQuestProgress(referenceDate: Date()),
                reward: 24,
                isComplete: isQuestComplete("sprint"),
                accent: Color(red: 0.52, green: 0.40, blue: 0.96),
                actionTitle: isQuestComplete("sprint") ? "達成済み" : (focusSprintActive ? compactRemainingString(focusSprintRemaining(referenceDate: Date())) : "20分開始"),
                action: { startFocusSprint(minutes: 20) }
            )
        ]
    }

    var body: some View {
        ZStack {
            surfaceBackgroundView

            ScrollView {
                VStack(spacing: 14) {
                    launcherNewsPanel

                    appCatalogPanel

                    if showRecentlyClosed || showFrequentSites {
                        continuePanel
                    }

                    hubControlsPanel
                }
                .padding(.top, 20)
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
        }
        .sheet(isPresented: $showCustomization) {
            HomeCustomizationView(
                backgroundStyle: $backgroundStyle,
                showFavorites: $showFavorites,
                showFrequentSites: $showFrequentSites,
                showRecentlyClosed: $showRecentlyClosed
            )
        }
        .sheet(isPresented: $showGameCenter) {
            KidsGameCenterView()
                .homeLauncherSheetSizing(minWidth: 520, minHeight: 520)
        }
        .sheet(isPresented: $showLearningLibrary) {
            LearningContentCenterView()
                .homeLauncherSheetSizing(minWidth: 1280, minHeight: 860)
        }
        .sheet(isPresented: $showMapWorkspace) {
            VIUKMapWorkspaceView()
                .homeLauncherSheetSizing(minWidth: 1180, minHeight: 800)
        }
        .sheet(isPresented: $showLoveWorkspace) {
            launcherFallbackSheet(title: "Love Lab", message: "Love Lab は独立アプリとして別ウィンドウで開きます。iPhoneではアプリ内のLove導線から開いてください。")
                .homeLauncherSheetSizing(minWidth: 520, minHeight: 360)
        }
        .sheet(isPresented: $showLoveCardWorkspace) {
            launcherFallbackSheet(title: "Love Cards", message: "Love Cards は独立アプリとして扱います。詳細から仕様を確認し、対応環境では別ウィンドウで開きます。")
                .homeLauncherSheetSizing(minWidth: 520, minHeight: 360)
        }
        .sheet(item: $selectedLauncherApp) { app in
            NavigationStack {
                launcherAppDetailView(app)
                    .navigationTitle(app.title)
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("閉じる") {
                                selectedLauncherDetailPageID = "overview"
                                selectedLauncherApp = nil
                            }
                        }
                    }
            }
            .homeLauncherSheetSizing(minWidth: 760, minHeight: 680)
        }
        .onAppear {
            backgroundStyle = BackgroundStyle(rawValue: launcherBackgroundStyleRawValue) ?? .gradient
            showImportedApps = launcherImportedAppsExpanded
            scheduleDashboardRefresh(initial: true)
            #if os(macOS)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                if launcherAutoFocusSearchField && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    searchFieldFocused = true
                }
            }
            #endif
        }
        .onChange(of: backgroundStyle) { _, newValue in
            launcherBackgroundStyleRawValue = newValue.rawValue
        }
        .onChange(of: showImportedApps) { _, newValue in
            launcherImportedAppsExpanded = newValue
        }
    }

    private var primaryWorkspaceCards: [DashboardActionCard] {
        workspaceCards.filter { $0.id != "sprint" }
    }

    private var coreWorkspaceCards: [DashboardActionCard] {
        primaryWorkspaceCards.filter { ["browse", "learn", "ai_assist"].contains($0.id) }
    }

    private var extraWorkspaceCards: [DashboardActionCard] {
        primaryWorkspaceCards.filter { !["browse", "learn", "ai_assist"].contains($0.id) }
    }

    private var recentLaunchShortcut: (title: String, detail: String, systemImage: String, tint: Color, action: () -> Void)? {
        if let workspace = workspaceCards.first(where: { $0.id == lastOpenedWorkspaceID }) {
            return (
                title: "前回のアプリ",
                detail: workspace.title,
                systemImage: workspace.icon,
                tint: workspace.palette.first ?? .blue,
                action: workspace.action
            )
        }

        if let imported = importedWorkspaceCards.first(where: { $0.id == lastOpenedWorkspaceID }) {
            return (
                title: "前回のアプリ",
                detail: imported.title,
                systemImage: imported.icon,
                tint: imported.tint,
                action: imported.action
            )
        }

        return nil
    }

    private var featuredSuggestionCards: [DashboardActionCard] {
        Array(suggestionCards.prefix(4))
    }

    private func rememberWorkspace(id: String, title: String) {
        lastOpenedWorkspaceID = id
        lastOpenedWorkspaceTitle = title
    }

    private func openSafeBrowseWorkspace(query: String? = nil) {
        rememberWorkspace(id: "browse", title: "Safe Browse")
        onQuickLinkTap(query ?? "https://www.google.com")
    }

    private func openLearningCenter(recordAction: Bool = false) {
        rememberWorkspace(id: "learn", title: "Learning Arena")
        if supportsMultipleWindows {
            openWindow(id: "learning-center")
        } else {
            showLearningLibrary = true
        }

        if recordAction {
            lastLearningActionDay = todayStamp
            autoCompleteDataDrivenQuests()
        }
    }

    private func openMapWorkspace() {
        rememberWorkspace(id: "map", title: "Map Atlas")
        if supportsMultipleWindows {
            openWindow(id: "map-center")
        } else {
            showMapWorkspace = true
        }
    }

    private func openLoveWorkspace() {
        rememberWorkspace(id: "love", title: "Love Lab")
        if supportsMultipleWindows {
            openWindow(id: "love-center")
        } else {
            showLoveWorkspace = true
        }
    }

    private func openLoveCardWorkspace() {
        rememberWorkspace(id: "love_cards", title: "Love Cards")
        showLoveCardWorkspace = true
    }

    private func openSafeKidsClassicWorkspace() {
        rememberWorkspace(id: "safekids_classic", title: "SafeKids Classic")
        openWindow(id: "safekids-classic-center")
    }

    private func openENextWorkspace() {
        rememberWorkspace(id: "enext", title: "e next")
        openWindow(id: "enext-center")
    }

    private func openMicrowaveWorkspace() {
        rememberWorkspace(id: "microwave", title: "Microwave")
        openWindow(id: "microwave-center")
    }

    private func openScienceClubWorkspace() {
        rememberWorkspace(id: "science_club", title: "Science Club")
        openWindow(id: "science-club-center")
    }

    private var surfaceBackgroundView: some View {
        let accent = currentFocusMode.palette

        return ZStack {
            Color.appCanvasBackground

            LinearGradient(
                colors: [
                    Color.appCanvasBackground,
                    accent[0].opacity(backgroundStyle == .solid ? 0.03 : 0.05),
                    Color.appSecondaryBackground
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .opacity(backgroundStyle == .blur ? 0.85 : 1)

            if backgroundStyle == .blur {
                Rectangle()
                    .fill(.ultraThinMaterial)
            }

            Circle()
                .fill(accent[0].opacity(0.035))
                .frame(width: 280, height: 280)
                .blur(radius: 58)
                .offset(x: -180, y: -120)
        }
        .ignoresSafeArea()
    }

    private var homeHeaderSection: some View {
        homeSurfacePanel {
            headerStartPanel
        }
        .sheet(isPresented: $showLauncherSettings) {
            NavigationStack {
                VIUKLauncherSettingsView()
            }
            .homeLauncherSheetSizing(minWidth: 760, minHeight: 620)
        }
    }

    private var launcherNewsPanel: some View {
        homeSurfacePanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 10) {
                    Label("VIUK News", systemImage: "sparkles.rectangle.stack")
                        .font(.system(size: 15, weight: .black, design: .rounded))
                        .foregroundColor(.primary)

                    Spacer(minLength: 8)

                    Button("設定") {
                        showLauncherSettings = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        showCustomization = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("表示設定")
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("独立アプリランチャーを追加")
                        .font(.system(size: 18, weight: .black, design: .rounded))
                        .foregroundColor(.primary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.86)

                    Text("Appsから各VIUKアプリを開けます。詳細では役割、保存データ、技術仕様をページごとに確認できます。")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    newsPill("新機能", systemImage: "wand.and.stars", tint: .blue)
                    newsPill("詳細ページ", systemImage: "doc.text.magnifyingglass", tint: .purple)
                    newsPill("Apps優先", systemImage: "square.grid.2x2", tint: .green)
                }
            }
        }
        .sheet(isPresented: $showLauncherSettings) {
            NavigationStack {
                VIUKLauncherSettingsView()
            }
            .homeLauncherSheetSizing(minWidth: 760, minHeight: 620)
        }
    }

    private func newsPill(_ title: String, systemImage: String, tint: Color) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(tint)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(tint.opacity(0.10))
            .clipShape(Capsule())
    }

    private var headerStartPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(AppBrand.displayName)
                        .font(.system(size: 32, weight: .black, design: .rounded))
                    Text("VIUK apps launcher")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.primary)
                    Text("各アプリを独立した入口として開き、詳細から役割・保存データ・技術仕様を確認できます。")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                HStack(spacing: 8) {
                    Button("設定") {
                        showLauncherSettings = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("表示設定") {
                        showCustomization = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("Safe Browse クイック検索")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.secondary)

                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(modeTintColor)

                    TextField("検索、URL、調べたいことを入力", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16, weight: .medium))
                        .focused($searchFieldFocused)
                        .submitLabel(.search)
                        .onSubmit { dismissKeyboardAndRunSearch() }

                    if !searchText.isEmpty {
                        Button(action: { searchText = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 15)
                .background(Color.appSecondaryBackground.opacity(0.88))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(modeTintColor.opacity(0.20), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                HStack(spacing: 10) {
                    Button {
                        runSearch()
                    } label: {
                        Label("検索する", systemImage: "magnifyingglass.circle.fill")
                            .font(.system(size: 13, weight: .bold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)

                    if let recentLaunchShortcut {
                        Button {
                            recentLaunchShortcut.action()
                        } label: {
                            Label(recentLaunchShortcut.detail, systemImage: recentLaunchShortcut.systemImage)
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(recentLaunchShortcut.tint)
                    }
                }
            }
        }
    }

    private var appCatalogPanel: some View {
        homeSurfacePanel(title: "Apps", subtitle: "それぞれを独立したアプリとして開く") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12)], spacing: 12) {
                ForEach(launcherApps) { app in
                    launcherAppCard(app)
                }
            }
        }
    }

    private var hubControlsPanel: some View {
        homeSurfacePanel(title: "Hub Controls", subtitle: "保護プリセット、ミッション、表示設定は補助として残す") {
            DisclosureGroup(isExpanded: $showHubControls) {
                VStack(spacing: 12) {
                    controlsPanelContent
                    recommendationsPanelContent
                    statusSummaryPanelContent
                }
                .padding(.top, 10)
            } label: {
                HStack {
                    Text(showHubControls ? "Hub Controls を閉じる" : "保護・ミッション・状態を表示")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("\(rewardPoints) pt")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var statusSummaryPanelContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                statusMetric(title: "安全閲覧", value: "\(todaySafeVisits)", tint: .green, icon: "checkmark.shield.fill")
                statusMetric(title: "ブロック", value: "\(todayBlockCount)", tint: .red, icon: "xmark.shield.fill")
                statusMetric(title: "情報監視", value: "\(todayPersonalInfoCount)", tint: .orange, icon: "lock.doc.fill")
                statusMetric(title: "連続日数", value: "\(safeDayStreak)", tint: .yellow, icon: "flame.fill")
            }

            HStack(spacing: 10) {
                Button(focusSprintActive ? compactRemainingString(focusSprintRemaining(referenceDate: Date())) : "20分集中") {
                    startFocusSprint(minutes: 20)
                }
                .buttonStyle(.bordered)

                Button("5分休けい") {
                    startFocusSprint(minutes: 5)
                }
                .buttonStyle(.bordered)

                if focusSprintActive {
                    Button("停止") { stopFocusSprint() }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    private var controlsPanelContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("フォーカスモード")
                    .font(.system(size: 14, weight: .semibold))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 10)], spacing: 10) {
                    ForEach(HomeFocusMode.allCases) { mode in
                        Button {
                            currentFocusMode = mode
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: mode.icon)
                                    .foregroundColor(mode.palette[1])
                                Text(mode.title)
                                    .font(.system(size: 12, weight: .bold))
                                Spacer(minLength: 0)
                                if currentFocusMode == mode {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(mode.palette[1])
                                }
                            }
                            .padding(10)
                            .background(Color.appSoftFill)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("保護プリセット")
                    .font(.system(size: 14, weight: .semibold))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 10)], spacing: 10) {
                    ForEach(HomeSafetyPreset.allCases) { preset in
                        Button {
                            applySafetyPreset(preset)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: preset.icon)
                                    .foregroundColor(preset.palette[0])
                                Text(preset.title)
                                    .font(.system(size: 12, weight: .bold))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                if currentSafetyPreset == preset {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(preset.palette[0])
                                }
                            }
                            .padding(10)
                            .background(Color.appSoftFill)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var recommendationsPanelContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("今日のミッション")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("\(rewardPoints) pt")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.secondary)
            }

            ForEach(Array(quests.prefix(3))) { quest in
                missionRow(quest)
            }
        }
    }

    private var workspaceListPanel: some View {
        homeSurfacePanel(title: "ワークスペース", subtitle: "ここから開く") {
            VStack(spacing: 10) {
                ForEach(coreWorkspaceCards) { card in
                    workspaceCard(card)
                }

                if !extraWorkspaceCards.isEmpty {
                    DisclosureGroup(isExpanded: $showMoreWorkspaces) {
                        VStack(spacing: 10) {
                            ForEach(extraWorkspaceCards) { card in
                                workspaceCard(card)
                            }
                        }
                        .padding(.top, 8)
                    } label: {
                        Text(showMoreWorkspaces ? "その他を閉じる" : "Map / Love などを表示")
                            .font(.system(size: 13, weight: .semibold))
                    }
                }
            }
        }
    }

    private var statusSummaryPanel: some View {
        homeSurfacePanel(title: "現在の状態", subtitle: "保護と利用状況") {
            VStack(spacing: 12) {
                VStack(spacing: 10) {
                    statusHighlightCard(
                        title: "フォーカス",
                        value: currentFocusMode.title,
                        detail: topInterestLabel,
                        tint: modeTintColor,
                        systemImage: currentFocusMode.icon
                    )
                    statusHighlightCard(
                        title: "保護",
                        value: currentSafetyPreset.title,
                        detail: "AI \(aiStatusLabel)",
                        tint: currentSafetyPreset.palette[0],
                        systemImage: currentSafetyPreset.icon
                    )
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    statusMetric(title: "安全閲覧", value: "\(todaySafeVisits)", tint: .green, icon: "checkmark.shield.fill")
                    statusMetric(title: "ブロック", value: "\(todayBlockCount)", tint: .red, icon: "xmark.shield.fill")
                    statusMetric(title: "情報監視", value: "\(todayPersonalInfoCount)", tint: .orange, icon: "lock.doc.fill")
                    statusMetric(title: "連続日数", value: "\(safeDayStreak)", tint: .yellow, icon: "flame.fill")
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("集中タイマー")
                            .font(.system(size: 15, weight: .semibold))
                        Spacer()
                        Text(focusSprintActive ? compactRemainingString(focusSprintRemaining(referenceDate: Date())) : "停止中")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.secondary)
                    }

                    ProgressView(value: sprintProgress(referenceDate: Date()))
                        .tint(modeTintColor)

                    ViewThatFits {
                        HStack(spacing: 10) {
                            Button("20分") { startFocusSprint(minutes: 20) }
                                .buttonStyle(.borderedProminent)
                            Button("5分休けい") { startFocusSprint(minutes: 5) }
                                .buttonStyle(.bordered)
                            if focusSprintActive {
                                Button("停止") { stopFocusSprint() }
                                    .buttonStyle(.bordered)
                            }
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            Button("20分") { startFocusSprint(minutes: 20) }
                                .buttonStyle(.borderedProminent)
                            HStack(spacing: 10) {
                                Button("5分休けい") { startFocusSprint(minutes: 5) }
                                    .buttonStyle(.bordered)
                                if focusSprintActive {
                                    Button("停止") { stopFocusSprint() }
                                        .buttonStyle(.bordered)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var integratedAppsPanel: some View {
        homeSurfacePanel(title: "統合アプリ", subtitle: "必要なときだけ開く") {
            DisclosureGroup(isExpanded: $showImportedApps) {
                VStack(spacing: 10) {
                    ForEach(importedWorkspaceCards) { card in
                        compactLinkRow(
                            title: card.title,
                            detail: card.subtitle,
                            systemImage: card.icon,
                            tint: card.tint,
                            action: card.action
                        )
                    }
                }
                .padding(.top, 8)
            } label: {
                Text(showImportedApps ? "閉じる" : "統合アプリを表示")
                    .font(.system(size: 13, weight: .semibold))
            }
        }
    }

    private var continuePanel: some View {
        homeSurfacePanel(title: "最近の続き", subtitle: "必要ならここから戻る") {
            VStack(alignment: .leading, spacing: 16) {
                if showRecentlyClosed {
                    if recentlyClosed.isEmpty {
                        Text("まだ履歴がありません。")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(recentlyClosed.prefix(2), id: \.url) { tab in
                            compactLinkRow(
                                title: tab.title,
                                detail: "最近閉じたページ",
                                systemImage: "arrow.uturn.backward.circle.fill",
                                tint: .blue,
                                action: { onQuickLinkTap(tab.url) }
                            )
                        }
                    }
                }

                if showFrequentSites && !frequentSites.isEmpty {
                    ForEach(frequentSites.prefix(2), id: \.url) { site in
                        compactLinkRow(
                            title: site.title,
                            detail: "\(site.visits) 回利用",
                            systemImage: "clock.arrow.circlepath",
                            tint: .indigo,
                            action: { onQuickLinkTap(site.url) }
                        )
                    }
                }

                if showFavorites && recentlyClosed.isEmpty && frequentSites.isEmpty {
                    HStack(spacing: 10) {
                        ForEach(getFavoriteSites().prefix(3), id: \.url) { site in
                            Button(action: { onQuickLinkTap(site.url) }) {
                                VStack(spacing: 6) {
                                    Image(systemName: site.icon)
                                        .foregroundColor(site.color)
                                    Text(site.title)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(.primary)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.appSoftFill)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var recommendationsPanel: some View {
        homeSurfacePanel(title: "今日のおすすめ", subtitle: "次にやることを迷わないようにする") {
            VStack(alignment: .leading, spacing: 16) {
                VStack(spacing: 10) {
                    ForEach(featuredSuggestionCards) { card in
                        compactActionRow(card)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("今日のミッション")
                            .font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Text("\(rewardPoints) pt")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.secondary)
                    }

                    ForEach(Array(quests.prefix(3))) { quest in
                        missionRow(quest)
                    }
                }
            }
        }
    }

    private var controlsPanel: some View {
        homeSurfacePanel(title: "モードと保護", subtitle: "必要なときだけ変える") {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("フォーカスモード")
                        .font(.system(size: 14, weight: .semibold))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                        ForEach(HomeFocusMode.allCases) { mode in
                            Button {
                                currentFocusMode = mode
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Image(systemName: mode.icon)
                                        Spacer()
                                        if currentFocusMode == mode {
                                            Image(systemName: "checkmark.circle.fill")
                                        }
                                    }
                                    .foregroundColor(currentFocusMode == mode ? mode.palette[1] : .secondary)
                                    Text(mode.title)
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundColor(.primary)
                                    Text(mode.subtitle)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(12)
                                .background(Color.appSoftFill)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(mode.palette[1].opacity(currentFocusMode == mode ? 0.28 : 0.08), lineWidth: 1)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("保護プリセット")
                        .font(.system(size: 14, weight: .semibold))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10)], spacing: 10) {
                        ForEach(HomeSafetyPreset.allCases) { preset in
                            Button {
                                applySafetyPreset(preset)
                            } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: preset.icon)
                                        .foregroundColor(preset.palette[0])
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(preset.title)
                                            .font(.system(size: 13, weight: .bold))
                                            .foregroundColor(.primary)
                                        Text(preset.subtitle)
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundColor(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer(minLength: 0)
                                    if currentSafetyPreset == preset {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(preset.palette[0])
                                    }
                                }
                                .padding(12)
                                .background(Color.appSoftFill)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(preset.palette[0].opacity(currentSafetyPreset == preset ? 0.28 : 0.08), lineWidth: 1)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var quickAccessPanel: some View {
        homeSurfacePanel(title: "学習とクイックアクセス", subtitle: "よく使う入口をまとめる") {
            VStack(alignment: .leading, spacing: 16) {
                compactLinkRow(
                    title: "まなびライブラリー",
                    detail: "教材、復習、提出を開く",
                    systemImage: "books.vertical.fill",
                    tint: .blue,
                    action: { openLearningCenter(recordAction: true) }
                )

                compactLinkRow(
                    title: "ことばチャレンジ",
                    detail: "休けい時に軽く遊ぶ",
                    systemImage: "gamecontroller.fill",
                    tint: .orange,
                    action: { showGameCenter = true }
                )

                VStack(alignment: .leading, spacing: 8) {
                    Text("おすすめサイト")
                        .font(.system(size: 14, weight: .semibold))

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
                        webShortcutButton(title: "Google", systemImage: "magnifyingglass", tint: .blue, url: "https://www.google.com")
                        webShortcutButton(title: "YouTube", systemImage: "play.rectangle.fill", tint: .red, url: "https://www.youtube.com")
                        webShortcutButton(title: "Wikipedia", systemImage: "book.fill", tint: .green, url: "https://www.wikipedia.org")
                        webShortcutButton(title: "NHK", systemImage: "newspaper.fill", tint: .indigo, url: "https://www.nhk.or.jp")
                    }
                }

                if !Array(HomeBadgeDefinition.all.filter { rewardPoints >= $0.requiredPoints }.prefix(3)).isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("獲得バッジ")
                            .font(.system(size: 14, weight: .semibold))
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(Array(HomeBadgeDefinition.all.filter { rewardPoints >= $0.requiredPoints }.prefix(3))) { badge in
                                    HStack(spacing: 8) {
                                        Image(systemName: badge.icon)
                                            .foregroundColor(.orange)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(badge.title)
                                                .font(.system(size: 12, weight: .bold))
                                            Text(badge.subtitle)
                                                .font(.system(size: 10, weight: .medium))
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    .padding(10)
                                    .background(Color.appSoftFill)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var backgroundView: some View {
        let palette = currentFocusMode.palette

        return ZStack {
            switch backgroundStyle {
            case .gradient:
                LinearGradient(colors: palette, startPoint: .topLeading, endPoint: .bottomTrailing)
            case .solid:
                palette.first ?? Color.blue
            case .blur:
                LinearGradient(colors: palette, startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay(Rectangle().fill(.ultraThinMaterial))
            }

            Circle()
                .fill(Color.white.opacity(0.18))
                .frame(width: 340, height: 340)
                .blur(radius: 30)
                .offset(x: -240, y: -280)

            Circle()
                .fill((palette.last ?? Color.white).opacity(0.24))
                .frame(width: 420, height: 420)
                .blur(radius: 60)
                .offset(x: 280, y: -120)

            Circle()
                .fill(Color.black.opacity(0.10))
                .frame(width: 520, height: 520)
                .blur(radius: 80)
                .offset(x: 260, y: 360)

            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [Color.black.opacity(0.08), .clear, Color.black.opacity(0.14)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
        .edgesIgnoringSafeArea(.all)
    }

    private func homeSurfacePanel<Content: View>(
        title: String? = nil,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if let title {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                }
            }

            content()
        }
        .padding(18)
        .viukSurfaceCard(
            cornerRadius: 22,
            fill: Color.appElevatedBackground.opacity(0.96),
            border: Color.appBorder.opacity(0.14),
            shadowOpacity: 0.025,
            shadowRadius: 12,
            shadowY: 6
        )
    }

    private func summaryPill(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.primary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .viukInsetCard(cornerRadius: 12, fill: Color.appSecondaryBackground.opacity(0.9), border: Color.appBorder.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func workspaceCard(_ card: DashboardActionCard) -> some View {
        Button(action: card.action) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: card.palette,
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 42, height: 42)
                    Image(systemName: card.icon)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(card.title)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.primary)
                    Text(card.subtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .viukInsetCard(cornerRadius: 18, fill: Color.appSecondaryBackground.opacity(0.86), border: card.palette[0].opacity(0.12))
        }
        .buttonStyle(.plain)
    }

    private func launcherAppCard(_ app: LauncherAppCard) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: app.palette,
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: app.icon)
                        .font(.system(size: 21, weight: .bold))
                        .foregroundColor(.white)
                }
                .frame(width: 52, height: 52)

                VStack(alignment: .leading, spacing: 4) {
                    Text(app.category)
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .foregroundColor(app.palette.first ?? .accentColor)
                        .lineLimit(1)
                    Text(app.title)
                        .font(.system(size: 18, weight: .black, design: .rounded))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.84)
                    Text(app.subtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .layoutPriority(1)
            }

            Text(app.status)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.secondary)
                .lineLimit(1)

            HStack(spacing: 9) {
                Button {
                    app.action()
                } label: {
                    Label("開く", systemImage: "arrow.up.right.circle.fill")
                        .font(.system(size: 12.5, weight: .bold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(app.palette.first ?? .accentColor)

                Button {
                    selectedLauncherDetailPageID = "overview"
                    selectedLauncherApp = app
                } label: {
                    Label("詳細", systemImage: "info.circle")
                        .font(.system(size: 12.5, weight: .bold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 176, alignment: .topLeading)
        .viukInsetCard(
            cornerRadius: 22,
            fill: Color.appSecondaryBackground.opacity(0.88),
            border: (app.palette.first ?? .accentColor).opacity(0.14)
        )
    }

    private func launcherAppDetailView(_ app: LauncherAppCard) -> some View {
        let pages = launcherDetailPages(for: app)
        let selectedPage = pages.first(where: { $0.id == selectedLauncherDetailPageID }) ?? pages[0]

        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: app.palette,
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        Image(systemName: app.icon)
                            .font(.system(size: 26, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .frame(width: 64, height: 64)

                    VStack(alignment: .leading, spacing: 5) {
                        Text(app.category)
                            .font(.system(size: 11, weight: .black, design: .monospaced))
                            .foregroundColor(app.palette.first ?? .accentColor)
                        Text(app.title)
                            .font(.system(size: 28, weight: .black, design: .rounded))
                            .foregroundColor(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(app.subtitle)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Button {
                    selectedLauncherApp = nil
                    app.action()
                } label: {
                    Label("\(app.title) を開く", systemImage: "arrow.up.right.circle.fill")
                        .font(.system(size: 14, weight: .bold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(app.palette.first ?? .accentColor)

                detailDocumentationLayout(
                    pages: pages,
                    selectedPage: selectedPage,
                    accent: app.palette.first ?? .accentColor
                )
            }
            .padding(20)
        }
        .background(Color.appCanvasBackground.ignoresSafeArea())
    }

    private func launcherFallbackSheet(title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: "app.dashed")
                .font(.system(size: 22, weight: .black, design: .rounded))
            Text(message)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("閉じる") {
                showLoveWorkspace = false
                showLoveCardWorkspace = false
            }
            .buttonStyle(.borderedProminent)
            Spacer(minLength: 0)
        }
        .padding(24)
        .background(Color.appCanvasBackground.ignoresSafeArea())
    }

    @ViewBuilder
    private func detailDocumentationLayout(pages: [LauncherDetailPage], selectedPage: LauncherDetailPage, accent: Color) -> some View {
        #if os(macOS)
        HStack(alignment: .top, spacing: 18) {
            detailPageSidebar(pages: pages, accent: accent)
                .frame(width: 220)

            Divider()

            detailArticleView(page: selectedPage, accent: accent)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        #else
        VStack(alignment: .leading, spacing: 14) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(pages) { page in
                        detailPageChip(page: page, accent: accent)
                    }
                }
                .padding(.horizontal, 1)
            }

            detailArticleView(page: selectedPage, accent: accent)
        }
        #endif
    }

    private func detailPageSidebar(pages: [LauncherDetailPage], accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Documentation")
                .font(.system(size: 11, weight: .black, design: .monospaced))
                .foregroundColor(.secondary)

            ForEach(pages) { page in
                detailPageSidebarButton(page: page, accent: accent)
            }
        }
        .padding(12)
        .viukInsetCard(
            cornerRadius: 18,
            fill: Color.appSecondaryBackground.opacity(0.70),
            border: Color.appBorder.opacity(0.10)
        )
    }

    private func detailPageSidebarButton(page: LauncherDetailPage, accent: Color) -> some View {
        let isSelected = selectedLauncherDetailPageID == page.id

        return Button {
            selectedLauncherDetailPageID = page.id
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: page.icon)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(isSelected ? accent : .secondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 3) {
                    Text(page.title)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.primary)
                    Text(page.subtitle)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .background(isSelected ? accent.opacity(0.12) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func detailPageChip(page: LauncherDetailPage, accent: Color) -> some View {
        let isSelected = selectedLauncherDetailPageID == page.id

        return Button {
            selectedLauncherDetailPageID = page.id
        } label: {
            Label(page.title, systemImage: page.icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(isSelected ? .white : .primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(isSelected ? accent : Color.appSecondaryBackground.opacity(0.82))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func detailArticleView(page: LauncherDetailPage, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 7) {
                Text(page.title)
                    .font(.system(size: 28, weight: .black, design: .rounded))
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(page.subtitle)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Rectangle()
                .fill(accent.opacity(0.55))
                .frame(width: 54, height: 4)
                .clipShape(Capsule())

            ForEach(Array(page.groups.enumerated()), id: \.element.id) { index, group in
                detailArticleSection(
                    index: index + 1,
                    group: group,
                    accent: accent
                )
            }
        }
    }

    private func detailArticleSection(index: Int, group: LauncherDetailGroup, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 10) {
                Text(index < 10 ? "0\(index)" : "\(index)")
                    .font(.system(size: 12, weight: .black, design: .monospaced))
                    .foregroundColor(accent)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(accent.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                Label(group.title, systemImage: group.icon)
                    .font(.system(size: 18, weight: .black, design: .rounded))
                    .foregroundColor(.primary)
            }

            if let lead = group.items.first {
                Text(lead)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if group.items.count > 1 {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(group.items.dropFirst().enumerated()), id: \.offset) { itemIndex, item in
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(itemIndex + 1)")
                                .font(.system(size: 11, weight: .black, design: .monospaced))
                                .foregroundColor(accent)
                                .frame(width: 22, height: 22)
                                .background(accent.opacity(0.10))
                                .clipShape(Circle())

                            Text(item)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(accent)
                Text("VIUK One App Detail")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .foregroundColor(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.top, 2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .viukInsetCard(
            cornerRadius: 18,
            fill: Color.appSecondaryBackground.opacity(0.82),
            border: accent.opacity(0.14)
        )
    }

    private func detailSection(title: String, icon: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.system(size: 16, weight: .bold))
            VStack(alignment: .leading, spacing: 8) {
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 5, weight: .bold))
                            .foregroundColor(.secondary)
                            .padding(.top, 6)
                        Text(item)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(14)
        .viukInsetCard(
            cornerRadius: 16,
            fill: Color.appSecondaryBackground.opacity(0.82),
            border: Color.appBorder.opacity(0.12)
        )
    }

    private func detailBlock(title: String, icon: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.system(size: 16, weight: .bold))
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .viukInsetCard(
            cornerRadius: 16,
            fill: Color.appSecondaryBackground.opacity(0.82),
            border: Color.appBorder.opacity(0.12)
        )
    }

    private func valueRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.primary)
        }
    }

    private func statusMetric(title: String, value: String, tint: Color, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(tint)
                Spacer()
                Text(value)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.primary)
            }
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
        }
        .padding(12)
        .viukInsetCard(cornerRadius: 14, fill: Color.appSecondaryBackground.opacity(0.84), border: tint.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func statusHighlightCard(
        title: String,
        value: String,
        detail: String,
        tint: Color,
        systemImage: String
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(tint)
                .frame(width: 36, height: 36)
                .background(tint.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)
                Text(value)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.primary)
                Text(detail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(12)
        .background(Color.appSecondaryBackground.opacity(0.90))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(tint.opacity(0.10), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func compactLinkRow(
        title: String,
        detail: String,
        systemImage: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(tint)
                    .frame(width: 34, height: 34)
                    .background(tint.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                    Text(detail)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)
            }
            .padding(12)
            .background(Color.appSecondaryBackground.opacity(0.76))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func compactActionRow(_ card: DashboardActionCard) -> some View {
        Button(action: card.action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: card.icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(card.palette[0])
                    .frame(width: 34, height: 34)
                    .background(card.palette[0].opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(card.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                    Text(card.subtitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(card.status)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                }

                Spacer(minLength: 10)
            }
            .padding(12)
            .background(Color.appSecondaryBackground.opacity(0.76))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func missionRow(_ quest: DashboardQuest) -> some View {
        Button(action: quest.action) {
            HStack(alignment: .center, spacing: 12) {
                Circle()
                    .fill(quest.accent.opacity(0.18))
                    .frame(width: 12, height: 12)

                VStack(alignment: .leading, spacing: 3) {
                    Text(quest.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                    Text(quest.detail)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Text(quest.isComplete ? "達成" : "\(Int((quest.progress * 100).rounded()))%")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(quest.isComplete ? .green : .secondary)
            }
            .padding(12)
            .background(Color.appSecondaryBackground.opacity(0.76))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func webShortcutButton(title: String, systemImage: String, tint: Color, url: String) -> some View {
        Button(action: { onQuickLinkTap(url) }) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundColor(tint)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(Color.appSecondaryBackground.opacity(0.76))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var modeTintColor: Color {
        currentFocusMode.palette[0]
    }

    private func quickLaunchButton(
        title: String,
        subtitle: String,
        icon: String,
        tint: Color,
        prominent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(prominent ? .white : tint)
                    .frame(width: 34, height: 34)
                    .background(prominent ? Color.white.opacity(0.18) : tint.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(prominent ? .white : .primary)
                    Text(subtitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(prominent ? Color.white.opacity(0.84) : .secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Group {
                    if prominent {
                        LinearGradient(colors: [tint, tint.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    } else {
                        Color.appSecondaryBackground.opacity(0.82)
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(prominent ? tint.opacity(0.12) : Color.appBorder.opacity(0.18), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func secondaryLaunchButton(
        title: String,
        icon: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundColor(tint)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.appSecondaryBackground.opacity(0.88))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(tint.opacity(0.10), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var topBar: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("VIUK Command Deck")
                    .font(.system(size: 14, weight: .black, design: .monospaced))
                    .foregroundColor(.white.opacity(0.78))
                Text("安全・学習・AI をひとつのコックピットにまとめる")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.84))
            }

            Spacer()

            HStack(spacing: 10) {
                topBadge(title: "MODE", value: currentFocusMode.title)
                topBadge(title: "POINT", value: "\(rewardPoints)")
                Button(action: { showCustomization = true }) {
                    Image(systemName: "paintbrush.fill")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(.white)
                        .padding(12)
                        .background(Color.white.opacity(0.14))
                        .clipShape(Circle())
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(0.16), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 34)
    }

    private var heroDeck: some View {
        let palette = currentFocusMode.palette

        return ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 36, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [palette[0], palette[1], palette[2]],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 36, style: .continuous)
                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                )

            Circle()
                .fill(Color.white.opacity(0.12))
                .frame(width: 180, height: 180)
                .blur(radius: 8)
                .offset(x: 40, y: -20)

            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(currentFocusMode.eyebrow)
                            .font(.system(size: 12, weight: .black, design: .monospaced))
                            .foregroundColor(.white.opacity(0.72))
                        Text("Web・Learning・AI を\n一枚の操縦席に。")
                            .font(.system(size: 48, weight: .black, design: .rounded))
                            .foregroundColor(.white)
                            .lineSpacing(2)
                        Text(AppBrand.tagline)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.white.opacity(0.84))
                    }

                    Spacer(minLength: 12)

                    VStack(alignment: .trailing, spacing: 10) {
                        topBadge(title: "PLAN", value: "Launcher")
                        topBadge(title: "APPS", value: "\(launcherApps.count)")
                        topBadge(title: "STREAK", value: "\(safeDayStreak)日")
                    }
                }

                searchConsole

                HStack(spacing: 10) {
                    signalPill(title: "興味", value: topInterestLabel, icon: "sparkle.magnifyingglass")
                    signalPill(title: "保護", value: currentSafetyPreset.title, icon: currentSafetyPreset.icon)
                    signalPill(title: "AI", value: aiStatusLabel, icon: "brain.head.profile")
                }
            }
            .padding(30)
        }
        .padding(.horizontal, 24)
    }

    private var searchConsole: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white.opacity(0.68))

                TextField("検索、URL、調べたいことを入力", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white)
                    .submitLabel(.search)
                    .onSubmit { dismissKeyboardAndRunSearch() }

                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.white.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .background(Color.white.opacity(0.12))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
            )
            .cornerRadius(22)

            HStack(spacing: 10) {
                Button(action: runSearch) {
                    Label("検索開始", systemImage: "arrow.up.right.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundColor(Color(red: 0.10, green: 0.12, blue: 0.18))

                Button(action: { openLearningCenter(recordAction: true) }) {
                    Label("学習へ", systemImage: "books.vertical.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.white)
                .foregroundColor(.white)

                Button(action: { openAICoachPanel() }) {
                    Label("AIへ", systemImage: "brain.head.profile")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.white)
                .foregroundColor(.white)
            }
        }
    }

    private var cockpitSection: some View {
        ViewThatFits {
            HStack(alignment: .top, spacing: 16) {
                safetyPulseCard
                questBoardCard
                sprintCard
            }
            .padding(.horizontal, 24)

            VStack(spacing: 16) {
                safetyPulseCard
                questBoardCard
                sprintCard
            }
            .padding(.horizontal, 24)
        }
    }

    private var safetyPulseCard: some View {
        dashboardPanel(
            eyebrow: "SAFETY PULSE",
            title: todayBlockCount == 0 ? "今日は安定した閲覧です" : "今日のブロック \(todayBlockCount) 件",
            subtitle: "現在の保護状態と利用の流れをリアルタイムで把握"
        ) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                metricTile(title: "安全閲覧", value: "\(todaySafeVisits)", icon: "checkmark.shield.fill", tint: .green)
                metricTile(title: "ブロック", value: "\(todayBlockCount)", icon: "xmark.shield.fill", tint: .red)
                metricTile(title: "情報監視", value: "\(todayPersonalInfoCount)", icon: "lock.doc.fill", tint: .orange)
                metricTile(title: "連続日数", value: "\(safeDayStreak)", icon: "flame.fill", tint: .yellow)
            }

            HStack(spacing: 8) {
                statusChip(title: "Safe Browsing", enabled: true)
                statusChip(title: "Realtime", enabled: false)
                statusChip(title: "AI Detect", enabled: false)
                statusChip(title: "Strict", enabled: currentSafetyPreset == .shield)
            }

            Text("関心トラック: \(topInterestLabel)")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
        }
    }

    private var questBoardCard: some View {
        dashboardPanel(
            eyebrow: "MISSION BOARD",
            title: "毎日のミッション",
            subtitle: "探索・学習・AI・保護プリセットを1日単位で回す"
        ) {
            VStack(spacing: 12) {
                ForEach(quests) { quest in
                    questRow(quest)
                }
            }
        }
    }

    private var sprintCard: some View {
        dashboardPanel(
            eyebrow: "FOCUS SPRINT",
            title: focusSprintActive ? "いま集中タイマーが動作中" : "20分集中 / 5分休けい",
            subtitle: "勉強や探索を短い区切りで回して、無理なく続ける"
        ) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = focusSprintRemaining(referenceDate: context.date)
                let progress = sprintProgress(referenceDate: context.date)
                let _ = finalizeSprintIfNeeded(referenceDate: context.date)

                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(remaining > 0 ? compactRemainingString(remaining) : "READY")
                            .font(.system(size: 34, weight: .black, design: .rounded))
                        Spacer()
                        Text(progress >= 1 ? "完了" : "\(Int((progress * 100).rounded()))%")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.secondary)
                    }

                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.appSoftFill)
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [currentFocusMode.palette[1], currentFocusMode.palette[2]],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: geometry.size.width * CGFloat(min(max(progress, 0), 1)))
                        }
                    }
                    .frame(height: 10)

                    HStack(spacing: 10) {
                        Button("20分スタート") {
                            startFocusSprint(minutes: 20)
                        }
                        .buttonStyle(.borderedProminent)

                        Button("5分休けい") {
                            startFocusSprint(minutes: 5)
                        }
                        .buttonStyle(.bordered)

                        if focusSprintActive {
                            Button("停止") {
                                stopFocusSprint()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
        }
    }

    private var focusModesSection: some View {
        dashboardPanel(
            eyebrow: "FOCUS MODES",
            title: "今日のモードを切り替える",
            subtitle: "モードで背景、検索の提案、ホームの空気感をまとめて変える"
        ) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
                ForEach(HomeFocusMode.allCases) { mode in
                    Button {
                        currentFocusMode = mode
                    } label: {
                        HStack(alignment: .top, spacing: 14) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(
                                        LinearGradient(
                                            colors: mode.palette,
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .frame(width: 56, height: 56)
                                Image(systemName: mode.icon)
                                    .font(.system(size: 24, weight: .bold))
                                    .foregroundColor(.white)
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text(mode.title)
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundColor(.primary)
                                Text(mode.subtitle)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Spacer()

                            if currentFocusMode == mode {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(mode.palette[1])
                            }
                        }
                        .padding(16)
                        .background(currentFocusMode == mode ? Color.appCanvasBackground : Color.appCardBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .stroke(mode.palette[1].opacity(currentFocusMode == mode ? 0.42 : 0.12), lineWidth: 1)
                        )
                        .cornerRadius(22)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 24)
    }

    private var guardianPresetSection: some View {
        dashboardPanel(
            eyebrow: "GUARDIAN PRESETS",
            title: "保護プリセットをワンタップで切り替える",
            subtitle: "学習寄り、通常、静かな夜の3パターンを即時反映"
        ) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                ForEach(HomeSafetyPreset.allCases) { preset in
                    Button {
                        applySafetyPreset(preset)
                    } label: {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Label(preset.title, systemImage: preset.icon)
                                    .font(.system(size: 15, weight: .bold))
                                Spacer()
                                if currentSafetyPreset == preset {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(preset.palette[0])
                                }
                            }

                            Text(preset.subtitle)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary)

                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: preset.palette,
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(height: 8)
                        }
                        .padding(16)
                        .background(currentSafetyPreset == preset ? Color.appCanvasBackground : Color.appCardBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .stroke(preset.palette[0].opacity(currentSafetyPreset == preset ? 0.44 : 0.12), lineWidth: 1)
                        )
                        .cornerRadius(22)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 24)
    }

    private var searchSparkSection: some View {
        dashboardPanel(
            eyebrow: "SEARCH SPARKS",
            title: "\(currentFocusMode.title) モードの一発スタート",
            subtitle: "言い換えや安全寄りの検索を、考えずにそのまま押せる"
        ) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], spacing: 10) {
                ForEach(currentFocusMode.sparks, id: \.self) { query in
                    Button {
                        triggerSearchSpark(query)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(query)
                                    .font(.system(size: 13, weight: .semibold))
                                    .multilineTextAlignment(.leading)
                                    .foregroundColor(.primary)
                                Text("タップでそのまま検索")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "arrow.up.right.circle.fill")
                                .foregroundColor(currentFocusMode.palette[1])
                        }
                        .padding(14)
                        .background(Color.appCardBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(currentFocusMode.palette[1].opacity(0.14), lineWidth: 1)
                        )
                        .cornerRadius(18)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 24)
    }

    private var workspaceLaunchSection: some View {
        dashboardPanel(
            eyebrow: "WORKSPACE LAUNCHPAD",
            title: "VIUK One の機能を6つの発射台に集約",
            subtitle: "既存のWeb・学習・AI・休けいに、Map と Love を加算して迷わず触れるように並べ直した"
        ) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                ForEach(workspaceCards) { card in
                    actionMosaicCard(card)
                }
            }
        }
        .padding(.horizontal, 24)
    }

    private var momentumSection: some View {
        VStack(spacing: 16) {
            sectionHeading(
                eyebrow: "MOMENTUM DECK",
                title: "お気に入り・最近・習慣をひとつに",
                subtitle: "いつもの流れを止めずに次の一手へつなぐ"
            )

            if showFavorites || (showRecentlyClosed && !recentlyClosed.isEmpty) {
                ViewThatFits {
                    HStack(alignment: .top, spacing: 16) {
                        if showFavorites {
                            favoritesPanel
                        }
                        if showRecentlyClosed && !recentlyClosed.isEmpty {
                            recentPanel
                        }
                    }

                    VStack(spacing: 16) {
                        if showFavorites {
                            favoritesPanel
                        }
                        if showRecentlyClosed && !recentlyClosed.isEmpty {
                            recentPanel
                        }
                    }
                }
            }

            if showFrequentSites && !frequentSites.isEmpty {
                frequentPanel
            }
        }
        .padding(.horizontal, 24)
    }

    private var favoritesPanel: some View {
        dashboardPanel(
            eyebrow: "FAVORITES",
            title: "お気に入り",
            subtitle: "よく使う安全な入口"
        ) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(getFavoriteSites(), id: \.url) { site in
                        FavoriteButton(
                            title: site.title,
                            icon: site.icon,
                            color: site.color,
                            onTap: { onQuickLinkTap(site.url) }
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var recentPanel: some View {
        dashboardPanel(
            eyebrow: "RECENT",
            title: "最近閉じたタブ",
            subtitle: "直前の流れをワンタップで再開"
        ) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(recentlyClosed.prefix(5), id: \.url) { tab in
                        RecentlyClosedCard(
                            title: tab.title,
                            url: tab.url,
                            onTap: { onQuickLinkTap(tab.url) }
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var frequentPanel: some View {
        dashboardPanel(
            eyebrow: "HABITS",
            title: "よく訪れるサイト",
            subtitle: "今日の導線を見て、次の行動を短縮する"
        ) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                ForEach(frequentSites.prefix(6), id: \.url) { site in
                    FrequentSiteCard(
                        title: site.title,
                        url: site.url,
                        visits: site.visits,
                        onTap: { onQuickLinkTap(site.url) }
                    )
                }
            }
        }
    }

    private var recommendationsSection: some View {
        dashboardPanel(
            eyebrow: "NEXT MOVES",
            title: "次にやることを提案",
            subtitle: "履歴、モード、プラン状況から今のおすすめを並べる"
        ) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                ForEach(suggestionCards) { card in
                    actionMosaicCard(card)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(HomeBadgeDefinition.all) { badge in
                        let unlocked = rewardPoints >= badge.requiredPoints
                        VStack(alignment: .leading, spacing: 6) {
                            Image(systemName: badge.icon)
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(unlocked ? .white : .secondary)
                            Text(badge.title)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(unlocked ? .white : .primary)
                            Text(unlocked ? badge.subtitle : "あと \(badge.requiredPoints - rewardPoints)pt")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(unlocked ? .white.opacity(0.84) : .secondary)
                        }
                        .padding(14)
                        .frame(width: 180, alignment: .leading)
                        .background(
                            unlocked
                            ? LinearGradient(
                                colors: [Color(red: 0.13, green: 0.47, blue: 0.88), Color(red: 0.92, green: 0.40, blue: 0.29)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            : LinearGradient(
                                colors: [Color.appCardBackground, Color.appSecondaryBackground],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(unlocked ? Color.white.opacity(0.14) : Color.appBorder.opacity(0.28), lineWidth: 1)
                        )
                        .cornerRadius(18)
                    }
                }
            }
        }
        .padding(.horizontal, 24)
    }

    private var quickLinksSection: some View {
        dashboardPanel(
            eyebrow: "DISCOVERY GRID",
            title: "おすすめサイト",
            subtitle: "すぐに使える安全寄りのショートカット"
        ) {
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 12) {
                Button(action: { onQuickLinkTap("https://www.google.com") }) {
                    QuickLinkContent(
                        title: "Google",
                        subtitle: "検索",
                        icon: "magnifyingglass",
                        gradient: [Color(red: 0.26, green: 0.52, blue: 0.96), Color(red: 0.34, green: 0.71, blue: 0.99)]
                    )
                }
                .buttonStyle(PlainButtonStyle())

                Button(action: { onQuickLinkTap("https://www.youtube.com") }) {
                    QuickLinkContent(
                        title: "YouTube",
                        subtitle: "動画",
                        icon: "play.rectangle.fill",
                        gradient: [Color(red: 1.0, green: 0.0, blue: 0.0), Color(red: 1.0, green: 0.4, blue: 0.0)]
                    )
                }
                .buttonStyle(PlainButtonStyle())

                Button(action: { onQuickLinkTap("https://www.wikipedia.org") }) {
                    QuickLinkContent(
                        title: "Wikipedia",
                        subtitle: "百科事典",
                        icon: "book.fill",
                        gradient: [Color(red: 0.0, green: 0.7, blue: 0.4), Color(red: 0.0, green: 0.9, blue: 0.6)]
                    )
                }
                .buttonStyle(PlainButtonStyle())

                Button(action: { onQuickLinkTap("https://www.nhk.or.jp") }) {
                    QuickLinkContent(
                        title: "NHK",
                        subtitle: "ニュース",
                        icon: "newspaper.fill",
                        gradient: [Color(red: 0.3, green: 0.4, blue: 0.9), Color(red: 0.5, green: 0.6, blue: 1.0)]
                    )
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(.horizontal, 24)
    }

    private var gamesSection: some View {
        dashboardPanel(
            eyebrow: "PLAY + RECOVER",
            title: "遊びとクールダウン",
            subtitle: "休けい時間も安全に、軽く遊んで戻れるようにする"
        ) {
            Button(action: { showGameCenter = true }) {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.98, green: 0.72, blue: 0.28),
                                        Color(red: 0.98, green: 0.45, blue: 0.22)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 58, height: 58)
                        Image(systemName: "gamecontroller.fill")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(.white)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("ことばチャレンジ")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.primary)
                        Text("お題に合うことばを選ぶ、やさしい3択ゲーム")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                        Text("タップしてスタート")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.secondary)
                    }

                    Spacer()
                    Image(systemName: "sparkles")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.orange)
                }
                .padding(18)
                .background(Color.appSoftFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.appBorder.opacity(0.32), lineWidth: 1)
                )
                .cornerRadius(18)
            }
            .buttonStyle(PlainButtonStyle())

            Button(action: { openLearningCenter(recordAction: true) }) {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.22, green: 0.65, blue: 0.86),
                                        Color(red: 0.18, green: 0.42, blue: 0.94)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 58, height: 58)
                        Image(systemName: "books.vertical.fill")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(.white)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("まなびライブラリー")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.primary)
                        Text("国語・算数・理科・社会を、短い教材で学べる")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                        Text("eライブラリ風にさっと学習")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.secondary)
                    }

                    Spacer()
                    Image(systemName: "graduationcap.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.blue)
                }
                .padding(18)
                .background(Color.appSoftFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.appBorder.opacity(0.32), lineWidth: 1)
                )
                .cornerRadius(18)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.horizontal, 24)
    }

    private func scheduleDashboardRefresh(initial: Bool = false) {
        dashboardRefreshWorkItem?.cancel()

        var workItem: DispatchWorkItem?
        workItem = DispatchWorkItem(qos: initial ? .userInitiated : .utility) {
            let snapshot = DashboardSnapshot.build()

            DispatchQueue.main.async {
                guard let workItem, !workItem.isCancelled else { return }
                dashboardSnapshot = snapshot
                frequentSites = snapshot.frequentSites
                recentlyClosed = snapshot.recentlyClosed
                pruneQuestTokens()
                autoCompleteDataDrivenQuests()
                dashboardRefreshWorkItem = nil
            }
        }

        dashboardRefreshWorkItem = workItem
        let delay: TimeInterval = initial ? 0.08 : 0.16
        DispatchQueue.global(qos: initial ? .userInitiated : .utility)
            .asyncAfter(deadline: .now() + delay, execute: workItem!)
    }

    private func refreshDashboard() {
        pruneQuestTokens()
        scheduleDashboardRefresh()
        autoCompleteDataDrivenQuests()
    }

    private func loadFrequentSites() {
        frequentSites = dashboardSnapshot.frequentSites
    }

    private func loadRecentlyClosed() {
        recentlyClosed = dashboardSnapshot.recentlyClosed
    }

    private func runSearch() {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lastSearchQuery = trimmed
        rememberWorkspace(id: "browse", title: "Safe Browse")
        onSearch(trimmed)
    }

    private func dismissKeyboardAndRunSearch() {
        searchFieldFocused = false
        dismissHomeKeyboard()
        runSearch()
    }

    private func triggerSearchSpark(_ query: String) {
        searchFieldFocused = false
        dismissHomeKeyboard()
        searchText = query
        lastSearchQuery = query
        rememberWorkspace(id: "browse", title: "Safe Browse")
        onSearch(query)
    }

    private func openAICoachPanel() {
        rememberWorkspace(id: "ai_assist", title: "AI Studio")
        lastAICoachActionDay = todayStamp
        onOpenAICoach?()
        autoCompleteDataDrivenQuests()
    }

    private func applySafetyPreset(_ preset: HomeSafetyPreset) {
        currentSafetyPreset = preset
        lastPresetActionDay = todayStamp
        autoCompleteDataDrivenQuests()
    }

    private func startFocusSprint(minutes: Int) {
        let now = Date().timeIntervalSince1970
        focusSprintStartTimestamp = now
        focusSprintEndTimestamp = now + (Double(minutes) * 60)
    }

    private func stopFocusSprint() {
        focusSprintStartTimestamp = 0
        focusSprintEndTimestamp = 0
    }

    private func focusSprintRemaining(referenceDate: Date) -> TimeInterval {
        max(0, focusSprintEndTimestamp - referenceDate.timeIntervalSince1970)
    }

    private func sprintProgress(referenceDate: Date) -> Double {
        guard focusSprintDuration > 0 else { return 0 }
        if focusSprintRemaining(referenceDate: referenceDate) <= 0 {
            return isQuestComplete("sprint") ? 1 : 0
        }
        let elapsed = referenceDate.timeIntervalSince1970 - focusSprintStartTimestamp
        return min(max(elapsed / focusSprintDuration, 0), 1)
    }

    private func sprintQuestProgress(referenceDate: Date) -> Double {
        if isQuestComplete("sprint") {
            return 1
        }
        return sprintProgress(referenceDate: referenceDate)
    }

    private func finalizeSprintIfNeeded(referenceDate: Date) {
        guard focusSprintEndTimestamp > 0,
              referenceDate.timeIntervalSince1970 >= focusSprintEndTimestamp else {
            return
        }

        DispatchQueue.main.async {
            guard self.focusSprintEndTimestamp > 0,
                  Date().timeIntervalSince1970 >= self.focusSprintEndTimestamp else {
                return
            }
            self.completeQuest("sprint", reward: 24)
            self.focusSprintStartTimestamp = 0
            self.focusSprintEndTimestamp = 0
        }
    }

    private func dayStamp(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func questToken(_ id: String) -> String {
        "\(todayStamp)|\(id)"
    }

    private func isQuestComplete(_ id: String) -> Bool {
        completedQuestTokens.contains(questToken(id))
    }

    private func completeQuest(_ id: String, reward: Int) {
        var tokens = completedQuestTokens
        let token = questToken(id)
        guard !tokens.contains(token) else { return }
        tokens.insert(token)
        completedQuestTokensStorage = tokens.sorted().joined(separator: ",")
        rewardPoints += reward
    }

    private func pruneQuestTokens() {
        let prefix = "\(todayStamp)|"
        let filtered = completedQuestTokens.filter { $0.hasPrefix(prefix) }
        if filtered != completedQuestTokens {
            completedQuestTokensStorage = filtered.sorted().joined(separator: ",")
        }
    }

    private func autoCompleteDataDrivenQuests() {
        if todaySafeVisits >= 3 {
            completeQuest("explore3", reward: 18)
        }
        if lastLearningActionDay == todayStamp {
            completeQuest("learn", reward: 22)
        }
        if lastAICoachActionDay == todayStamp {
            completeQuest("coach", reward: 20)
        }
        if lastPresetActionDay == todayStamp {
            completeQuest("preset", reward: 16)
        }
        finalizeSprintIfNeeded(referenceDate: Date())
    }

    private func compactRemainingString(_ remaining: TimeInterval) -> String {
        let totalSeconds = Int(max(0, remaining))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func getFavoriteSites() -> [(title: String, icon: String, color: Color, url: String)] {
        [
            ("Google", "magnifyingglass.circle.fill", Color.blue, "https://www.google.com"),
            ("YouTube", "play.circle.fill", Color.red, "https://www.youtube.com"),
            ("Wikipedia", "book.circle.fill", Color.green, "https://www.wikipedia.org"),
            ("NHK", "newspaper.circle.fill", Color.indigo, "https://www.nhk.or.jp"),
            ("Yahoo", "y.circle.fill", Color.purple, "https://www.yahoo.co.jp")
        ]
    }

    private func sectionHeading(eyebrow: String, title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(eyebrow)
                .font(.system(size: 12, weight: .black, design: .monospaced))
                .foregroundColor(.white.opacity(0.70))
            Text(title)
                .font(.system(size: 26, weight: .black, design: .rounded))
                .foregroundColor(.white)
            Text(subtitle)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white.opacity(0.84))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func topBadge(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .foregroundColor(.white.opacity(0.66))
            Text(value)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.12))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .cornerRadius(16)
    }

    private func signalPill(title: String, value: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .foregroundColor(.white.opacity(0.66))
                Text(value)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.10))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .cornerRadius(16)
    }

    private func dashboardPanel<Content: View>(
        eyebrow: String,
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(eyebrow)
                .font(.system(size: 11, weight: .black, design: .monospaced))
                .foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 22, weight: .black, design: .rounded))
                    .foregroundColor(.primary)
                Text(subtitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content()
        }
        .padding(22)
        .background(
            LinearGradient(
                colors: [Color.appCardBackground, Color.appSecondaryBackground],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.appBorder.opacity(0.28), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.10), radius: 26, x: 0, y: 14)
        .cornerRadius(28)
    }

    private func metricTile(title: String, value: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.14))
                    .frame(width: 42, height: 42)
                Image(systemName: icon)
                    .foregroundColor(tint)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)
                Text(value)
                    .font(.system(size: 20, weight: .black, design: .rounded))
                    .foregroundColor(.primary)
            }
            Spacer()
        }
        .padding(14)
        .background(Color.appSoftFill)
        .cornerRadius(18)
    }

    private func statusChip(title: String, enabled: Bool) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .black, design: .monospaced))
            .foregroundColor(enabled ? .green : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(enabled ? Color.green.opacity(0.12) : Color.appSoftFill)
            .clipShape(Capsule())
    }

    private func questRow(_ quest: DashboardQuest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(quest.title)
                        .font(.system(size: 14, weight: .bold))
                    Text(quest.detail)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text("+\(quest.reward)pt")
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .foregroundColor(quest.accent)
            }

            ProgressView(value: quest.progress)
                .tint(quest.accent)

            Group {
                if quest.isComplete {
                    Button(quest.actionTitle) {
                        quest.action()
                    }
                    .buttonStyle(.bordered)
                    .disabled(true)
                } else {
                    Button(quest.actionTitle) {
                        quest.action()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(14)
        .background(Color.appSoftFill)
        .cornerRadius(18)
    }

    private func actionMosaicCard(_ card: DashboardActionCard) -> some View {
        Button(action: card.action) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: card.palette,
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 56, height: 56)
                        Image(systemName: card.icon)
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(.white)
                    }
                    Spacer()
                    Text(card.status)
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                Text(card.title)
                    .font(.system(size: 17, weight: .black, design: .rounded))
                    .foregroundColor(.primary)
                Text(card.subtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 176, alignment: .topLeading)
            .padding(18)
            .background(Color.appSoftFill)
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(card.palette[0].opacity(0.14), lineWidth: 1)
            )
            .cornerRadius(22)
        }
        .buttonStyle(.plain)
    }
}

struct KidsGameCenterView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var score = 0
    @State private var roundIndex = 0
    @State private var selectedAnswer: String?
    @State private var rounds: [KidsGameRound] = KidsGameRound.defaultRounds.shuffled()

    private var currentRound: KidsGameRound {
        rounds[min(roundIndex, rounds.count - 1)]
    }

    private var isFinished: Bool {
        roundIndex >= rounds.count
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.98, green: 0.93, blue: 0.82),
                    Color(red: 0.86, green: 0.94, blue: 1.0)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ことばチャレンジ")
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                        Text("お題に合うことばをえらぼう")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("閉じる") {
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                }

                HStack(spacing: 12) {
                    gameStatCard(title: "スコア", value: "\(score)")
                    gameStatCard(title: "もんだい", value: "\(min(roundIndex + 1, rounds.count))/\(rounds.count)")
                }

                if isFinished {
                    VStack(spacing: 14) {
                        Image(systemName: "star.circle.fill")
                            .font(.system(size: 64))
                            .foregroundColor(.orange)
                        Text("ゲームクリア")
                            .font(.system(size: 24, weight: .bold))
                        Text("ぜんぶ終わったよ。スコアは \(score) 点")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.secondary)
                        Button("もう一度あそぶ") {
                            restartGame()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("おだい")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.secondary)
                            Text(currentRound.prompt)
                                .font(.system(size: 28, weight: .bold, design: .rounded))
                        }

                        VStack(spacing: 12) {
                            ForEach(currentRound.choices, id: \.self) { choice in
                                Button {
                                    choose(choice)
                                } label: {
                                    HStack {
                                        Text(choice)
                                            .font(.system(size: 18, weight: .semibold))
                                        Spacer()
                                        if let selectedAnswer, selectedAnswer == choice {
                                            Image(systemName: choice == currentRound.answer ? "checkmark.circle.fill" : "xmark.circle.fill")
                                                .foregroundColor(choice == currentRound.answer ? .green : .red)
                                        }
                                    }
                                    .padding(16)
                                    .frame(maxWidth: .infinity)
                                    .background(choiceBackground(for: choice))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                                            .stroke(choiceBorder(for: choice), lineWidth: 1)
                                    )
                                    .cornerRadius(16)
                                }
                                .buttonStyle(.plain)
                                .disabled(selectedAnswer != nil)
                            }
                        }

                        if let selectedAnswer {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(selectedAnswer == currentRound.answer ? "せいかい！" : "おしい！")
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundColor(selectedAnswer == currentRound.answer ? .green : .orange)
                                Text(currentRound.explanation)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.secondary)
                                Button(roundIndex == rounds.count - 1 ? "けっかを見る" : "つぎへ") {
                                    advanceRound()
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.appCardBackground.opacity(0.9))
                            .cornerRadius(18)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .padding(24)
        }
    }

    private func choose(_ choice: String) {
        guard selectedAnswer == nil else { return }
        selectedAnswer = choice
        if choice == currentRound.answer {
            score += 10
        }
    }

    private func advanceRound() {
        selectedAnswer = nil
        roundIndex += 1
    }

    private func restartGame() {
        rounds = KidsGameRound.defaultRounds.shuffled()
        score = 0
        roundIndex = 0
        selectedAnswer = nil
    }

    private func choiceBackground(for choice: String) -> Color {
        guard let selectedAnswer else {
            return Color.appCardBackground.opacity(0.9)
        }
        if choice == currentRound.answer {
            return Color.green.opacity(0.18)
        }
        if choice == selectedAnswer {
            return Color.red.opacity(0.14)
        }
        return Color.appSecondaryBackground.opacity(0.8)
    }

    private func choiceBorder(for choice: String) -> Color {
        guard let selectedAnswer else {
            return Color.appBorder.opacity(0.32)
        }
        if choice == currentRound.answer {
            return Color.green.opacity(0.4)
        }
        if choice == selectedAnswer {
            return Color.red.opacity(0.35)
        }
        return Color.appBorder.opacity(0.26)
    }

    private func gameStatCard(title: String, value: String) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Color.appCardBackground)
        .cornerRadius(18)
    }
}

private struct KidsGameRound {
    let prompt: String
    let choices: [String]
    let answer: String
    let explanation: String

    static let defaultRounds: [KidsGameRound] = [
        KidsGameRound(
            prompt: "あかい くだものは？",
            choices: ["りんご", "きゅうり", "バナナ"],
            answer: "りんご",
            explanation: "りんごは赤いものが多いね。きゅうりはみどり、バナナは黄色。"
        ),
        KidsGameRound(
            prompt: "そらを とぶ ものは？",
            choices: ["ひこうき", "でんしゃ", "じてんしゃ"],
            answer: "ひこうき",
            explanation: "ひこうきは空を飛ぶ乗りものだよ。"
        ),
        KidsGameRound(
            prompt: "うみで およぐ いきものは？",
            choices: ["さかな", "いぬ", "きりん"],
            answer: "さかな",
            explanation: "さかなは海や川で泳ぐ生きものだよ。"
        ),
        KidsGameRound(
            prompt: "よるに みえる ものは？",
            choices: ["つき", "たいよう", "にじ"],
            answer: "つき",
            explanation: "夜の空には月が見えやすいね。"
        ),
        KidsGameRound(
            prompt: "ほんを よむ ばしょは？",
            choices: ["としょかん", "プール", "こうえん"],
            answer: "としょかん",
            explanation: "図書館は本を読んだり借りたりする場所だよ。"
        )
    ]
}

#if false
struct LearningLibraryView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("learningCompletedLessonIDs") private var completedLessonIDsStorage = ""
    @AppStorage("learningRecentLessonIDs") private var recentLessonIDsStorage = ""
    @AppStorage("learningWeakQuestionIDs") private var weakQuestionIDsStorage = ""
    @AppStorage("learningBestPracticeScore") private var bestPracticeScore = 0
    @State private var selectedGrade: StudyGrade = .grade2
    @State private var selectedSubjectID = ""
    @State private var workspaceMode: StudyWorkspaceMode = .overview
    @State private var completedLessonIDs: Set<String> = []
    @State private var recentLessonIDs: [String] = []
    @State private var weakQuestionIDs: [String] = []
    @State private var practiceIndex = 0
    @State private var selectedPracticeAnswer: String?
    @State private var practiceAnswered = 0
    @State private var practiceScore = 0

    private var allSubjects: [StudySubject] {
        StudySubject.defaultSubjects
    }

    private var visibleSubjects: [StudySubject] {
        let filtered = allSubjects.filter { $0.grades.contains(selectedGrade) }
        return filtered.isEmpty ? allSubjects : filtered
    }

    private var selectedSubject: StudySubject {
        if let match = visibleSubjects.first(where: { $0.id == selectedSubjectID }) {
            return match
        }
        return visibleSubjects.first ?? allSubjects[0]
    }

    private var visibleLessons: [StudyLesson] {
        selectedSubject.lessons.filter { $0.grades.contains(selectedGrade) }
    }

    private var allVisibleLessons: [StudyLesson] {
        visibleSubjects.flatMap { subject in
            subject.lessons.filter { $0.grades.contains(selectedGrade) }
        }
    }

    private var practiceQuestions: [StudyPracticeQuestion] {
        let questions = visibleSubjects.flatMap { $0.practiceQuestions.filter { $0.grades.contains(selectedGrade) } }
        return questions.isEmpty ? allSubjects.flatMap(\.practiceQuestions) : questions
    }

    private var currentPracticeQuestion: StudyPracticeQuestion? {
        guard !practiceQuestions.isEmpty, practiceIndex < practiceQuestions.count else { return nil }
        return practiceQuestions[practiceIndex]
    }

    private var completionRate: Int {
        let total = allVisibleLessons.count
        guard total > 0 else { return 0 }
        let completed = allVisibleLessons.filter { completedLessonIDs.contains($0.id) }.count
        return Int((Double(completed) / Double(total) * 100).rounded())
    }

    private var recommendedLesson: StudyLesson? {
        allVisibleLessons.first(where: { !completedLessonIDs.contains($0.id) }) ?? allVisibleLessons.first
    }

    private var recentLessons: [StudyLesson] {
        recentLessonIDs.compactMap { id in
            allSubjects.flatMap(\.lessons).first(where: { $0.id == id })
        }
    }

    private var weakQuestions: [StudyPracticeQuestion] {
        weakQuestionIDs.compactMap { id in
            allSubjects.flatMap(\.practiceQuestions).first(where: { $0.id == id })
        }
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.93, green: 0.97, blue: 1.0),
                    Color(red: 0.97, green: 0.95, blue: 0.89)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("まなびライブラリー")
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                        Text("教科・学年・問題演習をまとめた、eライブラリ風の学習ルーム")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("閉じる") {
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                }

                HStack(spacing: 12) {
                    studyStatCard(title: "学習済み", value: "\(allVisibleLessons.filter { completedLessonIDs.contains($0.id) }.count)")
                    studyStatCard(title: "達成率", value: "\(completionRate)%")
                    studyStatCard(title: "演習スコア", value: "\(practiceScore)")
                    studyStatCard(title: "ベスト", value: "\(bestPracticeScore)")
                }

                gradeSelector
                workspaceModeSelector

                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("教科")
                            .font(.system(size: 14, weight: .bold))

                        ScrollView {
                            VStack(spacing: 10) {
                                ForEach(visibleSubjects) { subject in
                                    Button {
                                        selectedSubjectID = subject.id
                                    } label: {
                                        HStack(spacing: 12) {
                                            ZStack {
                                                Circle()
                                                    .fill(subject.color.opacity(0.16))
                                                    .frame(width: 42, height: 42)
                                                Image(systemName: subject.icon)
                                                    .foregroundColor(subject.color)
                                            }

                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(subject.title)
                                                    .font(.system(size: 15, weight: .bold))
                                                    .foregroundColor(.primary)
                                                Text(subject.subtitle)
                                                    .font(.system(size: 11, weight: .medium))
                                                    .foregroundColor(.secondary)
                                            }

                                            Spacer()

                                            if selectedSubjectID == subject.id || (selectedSubjectID.isEmpty && subject.id == visibleSubjects.first?.id) {
                                                Image(systemName: "checkmark.circle.fill")
                                                    .foregroundColor(subject.color)
                                            }
                                        }
                                        .padding(12)
                                        .background(selectedSubject.id == subject.id ? Color.appCanvasBackground : Color.appCardBackground)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                                .stroke(subject.color.opacity(selectedSubject.id == subject.id ? 0.28 : 0.08), lineWidth: 1)
                                        )
                                        .cornerRadius(16)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .frame(width: 250)

                    contentPanel
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Color.appSecondaryBackground)
                    .cornerRadius(24)
                }
            }
            .padding(24)
            .onAppear {
                loadStoredProgress()
                if selectedSubjectID.isEmpty {
                    selectedSubjectID = visibleSubjects.first?.id ?? allSubjects.first?.id ?? ""
                }
            }
            .onChange(of: selectedGrade) { _, _ in
                selectedSubjectID = visibleSubjects.first?.id ?? allSubjects.first?.id ?? ""
                practiceIndex = 0
                selectedPracticeAnswer = nil
            }
            .onChange(of: completedLessonIDs) { _, _ in
                persistStoredProgress()
            }
            .onChange(of: recentLessonIDs) { _, _ in
                persistStoredProgress()
            }
            .onChange(of: weakQuestionIDs) { _, _ in
                persistStoredProgress()
            }
        }
    }

    private var gradeSelector: some View {
        HStack(spacing: 8) {
            ForEach(StudyGrade.allCases, id: \.self) { grade in
                Button {
                    selectedGrade = grade
                } label: {
                    Text(grade.label)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(selectedGrade == grade ? .white : .primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(selectedGrade == grade ? Color.blue : Color.appCardBackground)
                        .cornerRadius(999)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    private var workspaceModeSelector: some View {
        HStack(spacing: 8) {
            ForEach(StudyWorkspaceMode.allCases, id: \.self) { mode in
                Button {
                    workspaceMode = mode
                } label: {
                    Text(mode.label)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(workspaceMode == mode ? .white : .primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(workspaceMode == mode ? Color.indigo : Color.appCardBackground)
                        .cornerRadius(999)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var contentPanel: some View {
        switch workspaceMode {
        case .overview:
            overviewPanel
        case .lessons:
            lessonsPanel
        case .practice:
            practiceWorkspacePanel
        }
    }

    private var overviewPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let recommendedLesson {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("今日のおすすめ")
                            .font(.system(size: 14, weight: .bold))
                        Text(recommendedLesson.title)
                            .font(.system(size: 20, weight: .bold))
                        Text(recommendedLesson.summary)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.secondary)
                        Button("この教材を開く") {
                            if let subject = visibleSubjects.first(where: { $0.lessons.contains(where: { $0.id == recommendedLesson.id }) }) {
                                selectedSubjectID = subject.id
                            }
                            workspaceMode = .lessons
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.appCardBackground)
                    .cornerRadius(18)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("教科ごとの進み具合")
                        .font(.system(size: 14, weight: .bold))
                    ForEach(visibleSubjects) { subject in
                        let subjectLessons = subject.lessons.filter { $0.grades.contains(selectedGrade) }
                        let completed = subjectLessons.filter { completedLessonIDs.contains($0.id) }.count
                        let total = max(subjectLessons.count, 1)
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(subject.title)
                                    .font(.system(size: 14, weight: .bold))
                                Spacer()
                                Text("\(completed)/\(subjectLessons.count)")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.secondary)
                            }
                            GeometryReader { geometry in
                                ZStack(alignment: .leading) {
                                    Capsule()
                                        .fill(Color.appSoftFill)
                                    Capsule()
                                        .fill(subject.color)
                                        .frame(width: geometry.size.width * CGFloat(Double(completed) / Double(total)))
                                }
                            }
                            .frame(height: 8)
                        }
                        .padding(12)
                        .background(Color.appCardBackground)
                        .cornerRadius(14)
                    }
                }

                if !recentLessons.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("最近の学習")
                            .font(.system(size: 14, weight: .bold))
                        ForEach(recentLessons.prefix(4)) { lesson in
                            Text("・\(lesson.title)")
                                .font(.system(size: 13, weight: .medium))
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.appCardBackground)
                    .cornerRadius(18)
                }

                if !weakQuestions.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("復習おすすめ")
                            .font(.system(size: 14, weight: .bold))
                        ForEach(weakQuestions.prefix(3)) { question in
                            Text("・\(question.prompt)")
                                .font(.system(size: 13, weight: .medium))
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.appCardBackground)
                    .cornerRadius(18)
                }
            }
        }
    }

    private var lessonsPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(selectedSubject.title)
                        .font(.system(size: 22, weight: .bold))
                    Text(selectedSubject.subtitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text("\(visibleLessons.count)レッスン")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(selectedSubject.color)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(selectedSubject.color.opacity(0.12))
                    .cornerRadius(999)
            }

            ScrollView {
                VStack(spacing: 14) {
                    ForEach(visibleLessons) { lesson in
                        lessonCard(lesson)
                    }
                }
            }
        }
    }

    private var practiceWorkspacePanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("問題演習")
                    .font(.system(size: 22, weight: .bold))
                Spacer()
                Text("正答数 \(practiceScore / 10)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)
            }

            if let question = currentPracticeQuestion {
                practicePanel(question: question)
            } else {
                Text("この学年の問題は準備中です。")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.secondary)
            }

            if !weakQuestions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("まちがえた問題")
                        .font(.system(size: 14, weight: .bold))
                    ForEach(weakQuestions.prefix(5)) { question in
                        Text("・\(question.prompt)")
                            .font(.system(size: 13, weight: .medium))
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.appCardBackground)
                .cornerRadius(18)
            }
        }
    }

    private func lessonCard(_ lesson: StudyLesson) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(lesson.title)
                        .font(.system(size: 16, weight: .bold))
                    Text(lesson.gradeLabel)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(selectedSubject.color)
                }
                Spacer()
                if completedLessonIDs.contains(lesson.id) {
                    Label("学習済み", systemImage: "checkmark.seal.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.green)
                }
            }

            Text(lesson.summary)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(lesson.points, id: \.self) { point in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 5))
                            .foregroundColor(selectedSubject.color)
                            .padding(.top, 6)
                        Text(point)
                            .font(.system(size: 13))
                    }
                }
            }

            Button(completedLessonIDs.contains(lesson.id) ? "もう一度読む" : "学習済みにする") {
                markLessonCompleted(lesson)
            }
            .buttonStyle(.borderedProminent)
            .tint(selectedSubject.color)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.appCardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(selectedSubject.color.opacity(0.12), lineWidth: 1)
        )
        .cornerRadius(18)
    }

    private func practicePanel(question: StudyPracticeQuestion) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("問題演習モード")
                    .font(.system(size: 15, weight: .bold))
                Spacer()
                Text("\(min(practiceIndex + 1, practiceQuestions.count))/\(practiceQuestions.count)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)
            }

            Text(question.prompt)
                .font(.system(size: 15, weight: .semibold))

            HStack(spacing: 10) {
                ForEach(question.choices, id: \.self) { choice in
                    Button {
                        choosePracticeAnswer(choice, correct: question.answer)
                    } label: {
                        Text(choice)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(practiceChoiceTextColor(choice, answer: question.answer))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity)
                            .background(practiceChoiceBackground(choice, answer: question.answer))
                            .cornerRadius(12)
                    }
                    .buttonStyle(.plain)
                    .disabled(selectedPracticeAnswer != nil)
                }
            }

            if let selectedPracticeAnswer {
                VStack(alignment: .leading, spacing: 6) {
                    Text(selectedPracticeAnswer == question.answer ? "正解です" : "もう少し")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(selectedPracticeAnswer == question.answer ? .green : .orange)
                    Text(question.explanation)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                    Button(practiceIndex == practiceQuestions.count - 1 ? "最初にもどる" : "次の問題") {
                        advancePractice()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(16)
        .background(Color.appCardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.blue.opacity(0.1), lineWidth: 1)
        )
        .cornerRadius(18)
    }

    private func choosePracticeAnswer(_ choice: String, correct: String) {
        guard selectedPracticeAnswer == nil else { return }
        selectedPracticeAnswer = choice
        practiceAnswered += 1
        if choice == correct {
            practiceScore += 10
            if practiceScore > bestPracticeScore {
                bestPracticeScore = practiceScore
            }
            if let currentPracticeQuestion {
                weakQuestionIDs.removeAll { $0 == currentPracticeQuestion.id }
            }
        } else if let currentPracticeQuestion, !weakQuestionIDs.contains(currentPracticeQuestion.id) {
            weakQuestionIDs.insert(currentPracticeQuestion.id, at: 0)
        }
    }

    private func advancePractice() {
        selectedPracticeAnswer = nil
        if practiceQuestions.isEmpty {
            practiceIndex = 0
            return
        }
        if practiceIndex >= practiceQuestions.count - 1 {
            practiceIndex = 0
            practiceAnswered = 0
        } else {
            practiceIndex += 1
        }
    }

    private func markLessonCompleted(_ lesson: StudyLesson) {
        completedLessonIDs.insert(lesson.id)
        recentLessonIDs.removeAll { $0 == lesson.id }
        recentLessonIDs.insert(lesson.id, at: 0)
        if recentLessonIDs.count > 8 {
            recentLessonIDs = Array(recentLessonIDs.prefix(8))
        }
    }

    private func loadStoredProgress() {
        completedLessonIDs = Set(completedLessonIDsStorage.split(separator: "|").map(String.init).filter { !$0.isEmpty })
        recentLessonIDs = recentLessonIDsStorage.isEmpty
            ? []
            : recentLessonIDsStorage.split(separator: "|").map(String.init).filter { !$0.isEmpty }
        weakQuestionIDs = weakQuestionIDsStorage.split(separator: "|").map(String.init).filter { !$0.isEmpty }
    }

    private func persistStoredProgress() {
        completedLessonIDsStorage = completedLessonIDs.sorted().joined(separator: "|")
        recentLessonIDsStorage = recentLessonIDs.joined(separator: "|")
        weakQuestionIDsStorage = weakQuestionIDs.joined(separator: "|")
    }

    private func practiceChoiceBackground(_ choice: String, answer: String) -> Color {
        guard let selectedPracticeAnswer else {
            return Color.blue.opacity(0.08)
        }
        if choice == answer {
            return Color.green.opacity(0.18)
        }
        if choice == selectedPracticeAnswer {
            return Color.red.opacity(0.12)
        }
        return Color.gray.opacity(0.08)
    }

    private func practiceChoiceTextColor(_ choice: String, answer: String) -> Color {
        guard let selectedPracticeAnswer else {
            return .primary
        }
        if choice == answer {
            return .green
        }
        if choice == selectedPracticeAnswer {
            return .red
        }
        return .secondary
    }

    private func studyStatCard(title: String, value: String) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color.appCardBackground)
        .cornerRadius(16)
    }
}

private enum StudyGrade: CaseIterable {
    case grade1
    case grade2
    case grade3
    case grade4

    var label: String {
        switch self {
        case .grade1: return "小1"
        case .grade2: return "小2"
        case .grade3: return "小3"
        case .grade4: return "小4"
        }
    }
}

private enum StudyWorkspaceMode: CaseIterable {
    case overview
    case lessons
    case practice

    var label: String {
        switch self {
        case .overview: return "全体"
        case .lessons: return "教材"
        case .practice: return "演習"
        }
    }
}

private struct StudySubject: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    let grades: [StudyGrade]
    let lessons: [StudyLesson]
    let practiceQuestions: [StudyPracticeQuestion]

    static let defaultSubjects: [StudySubject] = [
        StudySubject(
            id: "life",
            title: "生活",
            subtitle: "学校・まち・いきもの",
            icon: "figure.and.child.holdinghands",
            color: .teal,
            grades: [.grade1, .grade2],
            lessons: [
                StudyLesson(
                    id: "life-1",
                    title: "がっこうたんけん",
                    summary: "学校の場所や使い方を知って、安心して生活する学習です。",
                    points: [
                        "教室や保健室、図書室の場所をおぼえる。",
                        "学校で助けてくれる人を知る。",
                        "安全にすごすための約束をたしかめる。"
                    ],
                    grades: [.grade1]
                ),
                StudyLesson(
                    id: "life-2",
                    title: "まちの人となかよく",
                    summary: "地域で働く人や場所に親しみをもつ学習です。",
                    points: [
                        "近くのお店や公園の役わりを知る。",
                        "みんなで使うものを大切にする。",
                        "安全に道を歩くことを考える。"
                    ],
                    grades: [.grade1, .grade2]
                ),
                StudyLesson(
                    id: "life-3",
                    title: "いきものとしょくぶつ",
                    summary: "身近な生きものや植物を育てながら観察します。",
                    points: [
                        "水や日光で育ち方が変わる。",
                        "生きものの変化を続けて見る。",
                        "やさしく世話をする気持ちを育てる。"
                    ],
                    grades: [.grade2]
                )
            ],
            practiceQuestions: [
                StudyPracticeQuestion(
                    id: "life-q1",
                    prompt: "学校で本を読む場所は？",
                    choices: ["図書室", "校庭", "げた箱"],
                    answer: "図書室",
                    explanation: "図書室は本を読んだり借りたりする場所です。",
                    grades: [.grade1]
                )
            ]
        ),
        StudySubject(
            id: "japanese",
            title: "国語",
            subtitle: "ことばと読解",
            icon: "text.book.closed.fill",
            color: .pink,
            grades: [.grade1, .grade2, .grade3, .grade4],
            lessons: [
                StudyLesson(
                    id: "jp-1",
                    title: "主語と述語",
                    summary: "文の中心になることばを見つける練習です。",
                    points: [
                        "主語は『だれが・なにが』にあたることば。",
                        "述語は『どうする・どんなだ』にあたることば。",
                        "短い文で主語と述語を探すと読みやすくなる。"
                    ],
                    grades: [.grade2, .grade3]
                ),
                StudyLesson(
                    id: "jp-2",
                    title: "気持ちを表すことば",
                    summary: "うれしい・かなしいなど、気持ちの言い方を学びます。",
                    points: [
                        "気持ちのことばを知ると感想を書きやすい。",
                        "同じ気持ちでも、少しずつ言い方がちがう。",
                        "読んだ話の登場人物の気持ちも考えやすくなる。"
                    ],
                    grades: [.grade1, .grade2]
                ),
                StudyLesson(
                    id: "jp-3",
                    title: "段落の見つけ方",
                    summary: "文章のまとまりをとらえるコツです。",
                    points: [
                        "話題が変わるところで段落が分かれやすい。",
                        "一つの段落には一つの中心がある。",
                        "段落ごとに短くまとめると読みやすい。"
                    ],
                    grades: [.grade3, .grade4]
                )
            ],
            practiceQuestions: [
                StudyPracticeQuestion(
                    id: "jp-q1",
                    prompt: "『ねこが ねむる。』の主語は？",
                    choices: ["ねこが", "ねむる", "。"],
                    answer: "ねこが",
                    explanation: "『だれが』にあたる『ねこが』が主語です。",
                    grades: [.grade2, .grade3]
                )
            ]
        ),
        StudySubject(
            id: "math",
            title: "算数",
            subtitle: "数と考え方",
            icon: "sum",
            color: .blue,
            grades: [.grade1, .grade2, .grade3, .grade4],
            lessons: [
                StudyLesson(
                    id: "math-1",
                    title: "くり上がりの考え方",
                    summary: "たし算を10のまとまりで考える方法です。",
                    points: [
                        "9 + 4 は 9 に 1 を足して 10 をつくる。",
                        "残りの 3 を足して 13。",
                        "10 を先につくると計算がはやくなる。"
                    ],
                    grades: [.grade1, .grade2]
                ),
                StudyLesson(
                    id: "math-2",
                    title: "長さくらべ",
                    summary: "cm の見方と、ものの長さのくらべ方です。",
                    points: [
                        "同じものさしを使うとくらべやすい。",
                        "数字が大きいほど長い。",
                        "目で見るだけでなく、測ってたしかめる。"
                    ],
                    grades: [.grade2]
                ),
                StudyLesson(
                    id: "math-3",
                    title: "わり算の入口",
                    summary: "同じ数ずつ分ける考え方を学びます。",
                    points: [
                        "12こを3人で分けると1人4こ。",
                        "同じ数ずつに分けるのがポイント。",
                        "かけ算の逆から考えると分かりやすい。"
                    ],
                    grades: [.grade3, .grade4]
                )
            ],
            practiceQuestions: [
                StudyPracticeQuestion(
                    id: "math-q1",
                    prompt: "8 + 5 はいくつ？",
                    choices: ["12", "13", "14"],
                    answer: "13",
                    explanation: "8に2を足して10、残り3を足して13です。",
                    grades: [.grade1, .grade2]
                )
            ]
        ),
        StudySubject(
            id: "science",
            title: "理科",
            subtitle: "身のまわりのふしぎ",
            icon: "leaf.fill",
            color: .green,
            grades: [.grade3, .grade4],
            lessons: [
                StudyLesson(
                    id: "science-1",
                    title: "植物の育ち方",
                    summary: "たねから芽が出て育つ流れを見ます。",
                    points: [
                        "たねに水がしみこむと芽が出やすくなる。",
                        "日光は葉が元気に育つ手助けをする。",
                        "毎日少しずつ様子を観察すると変化が見える。"
                    ],
                    grades: [.grade3]
                ),
                StudyLesson(
                    id: "science-2",
                    title: "かげのでき方",
                    summary: "光とかげの関係を学びます。",
                    points: [
                        "光が当たると、反対側にかげができる。",
                        "光の向きが変わるとかげの向きも変わる。",
                        "かげの長さは時間でも変わる。"
                    ],
                    grades: [.grade3]
                ),
                StudyLesson(
                    id: "science-3",
                    title: "電気の通り道",
                    summary: "電池と豆電球をつないで回路の基本を学びます。",
                    points: [
                        "電池から出た電気がぐるっと回ると光る。",
                        "どこかが切れると豆電球はつかない。",
                        "つなぎ方を変えてためしてみる。"
                    ],
                    grades: [.grade4]
                )
            ],
            practiceQuestions: [
                StudyPracticeQuestion(
                    id: "science-q1",
                    prompt: "かげは光のどちら側にできる？",
                    choices: ["同じ側", "反対側", "上"],
                    answer: "反対側",
                    explanation: "光が当たる反対側にかげができます。",
                    grades: [.grade3, .grade4]
                )
            ]
        ),
        StudySubject(
            id: "social",
            title: "社会",
            subtitle: "くらしと地図",
            icon: "globe.asia.australia.fill",
            color: .orange,
            grades: [.grade3, .grade4],
            lessons: [
                StudyLesson(
                    id: "social-1",
                    title: "地図のきまり",
                    summary: "地図記号や方角の見方を学びます。",
                    points: [
                        "上が北、右が東の地図が多い。",
                        "地図記号で学校や病院がわかる。",
                        "広い場所も地図ならわかりやすく見られる。"
                    ],
                    grades: [.grade3]
                ),
                StudyLesson(
                    id: "social-2",
                    title: "町のしごと",
                    summary: "店や学校、駅などの役わりを整理します。",
                    points: [
                        "お店は買い物をする場所。",
                        "駅は人が移動するときに使う。",
                        "いろいろな場所が協力して町が成り立つ。"
                    ],
                    grades: [.grade3]
                ),
                StudyLesson(
                    id: "social-3",
                    title: "県と地方",
                    summary: "日本の地域の分け方を学びます。",
                    points: [
                        "県はいくつか集まって地方になる。",
                        "住む場所によって気候や名物がちがう。",
                        "地図で場所を見ながら覚えると分かりやすい。"
                    ],
                    grades: [.grade4]
                )
            ],
            practiceQuestions: [
                StudyPracticeQuestion(
                    id: "social-q1",
                    prompt: "地図で上は何の方角？",
                    choices: ["北", "南", "西"],
                    answer: "北",
                    explanation: "多くの地図では上が北です。",
                    grades: [.grade2, .grade3]
                )
            ]
        ),
        StudySubject(
            id: "foreign-activities",
            title: "外国語活動",
            subtitle: "あいさつと音に親しむ",
            icon: "character.book.closed.fill",
            color: .purple,
            grades: [.grade3, .grade4],
            lessons: [
                StudyLesson(
                    id: "foreign-1",
                    title: "あいさつ",
                    summary: "Hello や Thank you など、音や表現に親しむ学習です。",
                    points: [
                        "Hello は『こんにちは』。",
                        "Thank you は『ありがとう』。",
                        "意味だけでなく、音やリズムに慣れることが大切。"
                    ],
                    grades: [.grade3, .grade4]
                ),
                StudyLesson(
                    id: "foreign-2",
                    title: "色の名前",
                    summary: "red, blue, yellow など色の英語です。",
                    points: [
                        "red は赤、blue は青。",
                        "ものを見ながら言うと覚えやすい。",
                        "知っている言葉を少しずつ増やす。"
                    ],
                    grades: [.grade3, .grade4]
                )
            ],
            practiceQuestions: [
                StudyPracticeQuestion(
                    id: "foreign-q1",
                    prompt: "『ありがとう』に近い英語は？",
                    choices: ["Thank you", "Good night", "Apple"],
                    answer: "Thank you",
                    explanation: "Thank you は『ありがとう』です。",
                    grades: [.grade3, .grade4]
                )
            ]
        ),
        StudySubject(
            id: "music",
            title: "音楽",
            subtitle: "うたとリズム",
            icon: "music.note",
            color: .indigo,
            grades: [.grade1, .grade2, .grade3, .grade4],
            lessons: [
                StudyLesson(
                    id: "music-1",
                    title: "リズムにあわせる",
                    summary: "手拍子や声で、拍のまとまりを感じる学習です。",
                    points: [
                        "同じ速さでくり返すとリズムになる。",
                        "声や体を使って楽しく表せる。",
                        "友だちと合わせると音楽が広がる。"
                    ],
                    grades: [.grade1, .grade2]
                ),
                StudyLesson(
                    id: "music-2",
                    title: "音のつよさと高さ",
                    summary: "強い音・弱い音、高い音・低い音の違いに気付きます。",
                    points: [
                        "音にはいろいろなちがいがある。",
                        "ちがいを聞き分けると表現が豊かになる。",
                        "歌や楽器でためしてみるとわかりやすい。"
                    ],
                    grades: [.grade3, .grade4]
                )
            ],
            practiceQuestions: [
                StudyPracticeQuestion(
                    id: "music-q1",
                    prompt: "音がつよいのはどれ？",
                    choices: ["大きな音", "小さな音", "しずかな音"],
                    answer: "大きな音",
                    explanation: "大きな音は、つよく聞こえる音です。",
                    grades: [.grade1, .grade2]
                )
            ]
        )
    ]
}

private struct StudyLesson: Identifiable {
    let id: String
    let title: String
    let summary: String
    let points: [String]
    let grades: [StudyGrade]

    var gradeLabel: String {
        grades.map(\.label).joined(separator: "・")
    }
}

private struct StudyPracticeQuestion: Identifiable {
    let id: String
    let prompt: String
    let choices: [String]
    let answer: String
    let explanation: String
    let grades: [StudyGrade]
}
#endif
// MARK: - Quick Link Content View
struct QuickLinkContent: View {
    let title: String
    let subtitle: String
    let icon: String
    let gradient: [Color]
    
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: gradient),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 50, height: 50)
                
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundColor(.white)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.8))
            }
            
            Spacer()
            
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white.opacity(0.5))
        }
        .padding(16)
        .background(Color.white.opacity(0.2))
        .cornerRadius(16)
    }
}

// MARK: - Favorite Button Component
struct FavoriteButton: View {
    let title: String
    let icon: String
    let color: Color
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.25))
                        .frame(width: 64, height: 64)
                    
                    Image(systemName: icon)
                        .font(.system(size: 28))
                        .foregroundColor(.white)
                }
                
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
            }
            .frame(width: 80)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Frequent Site Card
struct FrequentSiteCard: View {
    let title: String
    let url: String
    let visits: Int
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                // サムネイルエリア
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(
                            LinearGradient(
                                gradient: Gradient(colors: [
                                    Color.white.opacity(0.3),
                                    Color.white.opacity(0.2)
                                ]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(height: 90)
                    
                    Image(systemName: getFaviconForURL(url))
                        .font(.system(size: 36))
                        .foregroundColor(.white.opacity(0.8))
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    
                    HStack(spacing: 4) {
                        Image(systemName: "eye.fill")
                            .font(.system(size: 10))
                        Text("\(visits)回")
                            .font(.system(size: 11))
                    }
                    .foregroundColor(.white.opacity(0.7))
                }
                .padding(.horizontal, 4)
            }
            .padding(10)
            .background(Color.white.opacity(0.15))
            .cornerRadius(14)
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    private func getFaviconForURL(_ url: String) -> String {
        let lowercased = url.lowercased()
        if lowercased.contains("google") { return "magnifyingglass" }
        if lowercased.contains("youtube") { return "play.rectangle.fill" }
        if lowercased.contains("wikipedia") { return "book.fill" }
        if lowercased.contains("nhk") || lowercased.contains("news") { return "newspaper.fill" }
        if lowercased.contains("yahoo") { return "y.circle.fill" }
        return "globe"
    }
}

// MARK: - Recently Closed Card
struct RecentlyClosedCard: View {
    let title: String
    let url: String
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 16))
                        .foregroundColor(.white.opacity(0.8))
                    Spacer()
                    Image(systemName: "arrow.up.left")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.6))
                }
                
                Spacer()
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(2)
                    
                    Text(url)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.6))
                        .lineLimit(1)
                }
            }
            .padding(14)
            .frame(width: 180, height: 120)
            .background(Color.white.opacity(0.15))
            .cornerRadius(14)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Quick Link Button
struct QuickLinkButton: View {
    let title: String
    let subtitle: String
    let icon: String
    let gradient: [Color]
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                gradient: Gradient(colors: gradient),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 50, height: 50)
                    
                    Image(systemName: icon)
                        .font(.system(size: 22))
                        .foregroundColor(.white)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.8))
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white.opacity(0.5))
            }
            .padding(16)
            .background(Color.white.opacity(0.2))
            .cornerRadius(16)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Home Customization View
struct HomeCustomizationView: View {
    @Binding var backgroundStyle: HomeScreenView.BackgroundStyle
    @Binding var showFavorites: Bool
    @Binding var showFrequentSites: Bool
    @Binding var showRecentlyClosed: Bool
    @Environment(\.presentationMode) private var presentationMode
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("背景スタイル")) {
                    Picker("スタイル", selection: $backgroundStyle) {
                        ForEach(HomeScreenView.BackgroundStyle.allCases, id: \.self) { style in
                            Text(style.rawValue).tag(style)
                        }
                    }
                    .pickerStyle(SegmentedPickerStyle())
                }
                
                Section(header: Text("表示項目")) {
                    Toggle("お気に入りを表示", isOn: $showFavorites)
                    Toggle("よく訪れるサイトを表示", isOn: $showFrequentSites)
                    Toggle("最近閉じたタブを表示", isOn: $showRecentlyClosed)
                }
                
                Section {
                    Button("デフォルトに戻す") {
                        backgroundStyle = .gradient
                        showFavorites = true
                        showFrequentSites = true
                        showRecentlyClosed = true
                    }
                    .foregroundColor(.blue)
                }
            }
            .navigationTitle("ホーム画面のカスタマイズ")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("完了") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
        #if os(iOS)
        .navigationViewStyle(StackNavigationViewStyle())
        #endif
    }
}

// MARK: - ウェルカムセクション
struct WelcomeSection: View {
    @State private var currentHour = Calendar.current.component(.hour, from: Date())
    
    var greeting: String {
        switch currentHour {
        case 5..<12: return "おはよう！☀️"
        case 12..<17: return "こんにちは！🌤️"
        default: return "こんばんは！🌙"
        }
    }
    
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "safari")
                .font(.system(size: 60))
                .foregroundStyle(
                    LinearGradient(colors: [.blue, Color(red: 0.2, green: 0.7, blue: 1.0)], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
            
            Text(greeting)
                .font(.title)
                .fontWeight(.bold)
            
            Text("今日は何を見る？")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .padding(.top, 40)
    }
}

// MARK: - 検索バー
struct SearchBar: View {
    @Binding var searchText: String
    var onSearch: (String) -> Void
    
    var body: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            
            TextField("検索またはURLを入力", text: $searchText)
                .textFieldStyle(PlainTextFieldStyle())
                .submitLabel(.search)
                .onSubmit {
                    dismissHomeKeyboard()
                    onSearch(searchText)
                }
            
            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(12)
        .background(Color.appElevatedBackground)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.appBorder.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
    }
}

// MARK: - 人気サービスセクション（大きいボタン）
struct PopularServicesSection: View {
    var onTap: (String) -> Void
    
    let services: [PopularService] = [
        PopularService(
            title: "YouTube",
            subtitle: "動画を見よう",
            icon: "play.rectangle.fill",
            colors: [.red, .pink],
            url: "https://www.youtube.com/"
        ),
        PopularService(
            title: "Yahoo!きっず",
            subtitle: "安全に検索",
            icon: "magnifyingglass.circle.fill",
            colors: [.blue, Color(red: 0.2, green: 0.7, blue: 1.0)],
            url: "https://kids.yahoo.co.jp/"
        ),
        PopularService(
            title: "ポケモン",
            subtitle: "公式サイト",
            icon: "sparkles",
            colors: [.yellow, .orange],
            url: "https://www.pokemon.co.jp/"
        ),
        PopularService(
            title: "Nintendo",
            subtitle: "ゲーム情報",
            icon: "gamecontroller.fill",
            colors: [.red, .orange],
            url: "https://www.nintendo.co.jp/"
        )
    ]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("人気サービス")
                .font(.headline)
                .padding(.horizontal)
            
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 12) {
                ForEach(services) { service in
                    PopularServiceButton(service: service, onTap: onTap)
                }
            }
        }
    }
}

struct PopularServiceButton: View {
    let service: PopularService
    var onTap: (String) -> Void
    
    var body: some View {
        Button(action: { onTap(service.url) }) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: service.icon)
                        .font(.title)
                        .foregroundStyle(
                            LinearGradient(colors: service.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                    Spacer()
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(service.title)
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    Text(service.subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 100, alignment: .leading)
            .background(Color.appElevatedBackground)
            .cornerRadius(16)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.appBorder.opacity(0.14), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.05), radius: 8, y: 4)
        }
    }
}

// MARK: - クイックリンクセクション




struct BookmarkCard: View {
    let bookmark: Bookmark
    var onTap: (String) -> Void
    
    var body: some View {
        Button(action: { onTap(bookmark.url) }) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "globe")
                        .font(.title2)
                        .foregroundColor(.blue)
                    Spacer()
                }
                
                Text(bookmark.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .foregroundColor(.primary)
                
                Text(bookmark.url)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 140, height: 100)
            .padding(12)
            .background(Color.appElevatedBackground)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.appBorder.opacity(0.14), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
        }
    }
}

// MARK: - 最近見たサイトセクション
struct RecentSitesSection: View {
    let sites: [HistoryItem]
    var onTap: (String) -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "clock.fill")
                    .foregroundColor(.gray)
                Text("最近見たサイト")
                    .font(.headline)
            }
            .padding(.horizontal)
            
            VStack(spacing: 8) {
                ForEach(sites) { site in
                    Button(action: { onTap(site.url) }) {
                        HStack {
                            Image(systemName: "globe")
                                .foregroundColor(.blue)
                                .frame(width: 32)
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text(site.title)
                                    .font(.subheadline)
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                
                                Text(site.url)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                            
                            Spacer()
                            
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(12)
                        .background(Color.appElevatedBackground)
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.appBorder.opacity(0.14), lineWidth: 1)
                        )
                    }
                }
            }
            .padding(.horizontal)
        }
    }
}

// MARK: - 学習コンテンツセクション
struct LearningContentSection: View {
    var onTap: (String) -> Void
    
    let learningLinks: [LearningLink] = [
        LearningLink(title: "NHK for School", description: "教育番組を見よう", icon: "tv.fill", color: .red, url: "https://www.nhk.or.jp/school/"),
        LearningLink(title: "キッズgoo", description: "安全な検索", icon: "magnifyingglass", color: .green, url: "https://kids.goo.ne.jp/"),
        LearningLink(title: "学研キッズネット", description: "自由研究・学習", icon: "book.fill", color: .blue, url: "https://kids.gakken.co.jp/"),
        LearningLink(title: "プログラミン", description: "プログラミング学習", icon: "chevron.left.forwardslash.chevron.right", color: .purple, url: "https://www.mext.go.jp/programin/"),
        LearningLink(title: "こどもちゃれんじ", description: "通信教育", icon: "graduationcap.fill", color: .orange, url: "https://www2.shimajiro.co.jp/"),
        LearningLink(title: "青空文庫", description: "無料で本を読もう", icon: "text.book.closed.fill", color: Color(red: 0.2, green: 0.7, blue: 1.0), url: "https://www.aozora.gr.jp/")
    ]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "graduationcap.fill")
                    .foregroundColor(.orange)
                Text("おすすめの学習サイト")
                    .font(.headline)
            }
            .padding(.horizontal)
            
            VStack(spacing: 8) {
                ForEach(learningLinks) { link in
                    Button(action: { onTap(link.url) }) {
                        HStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(link.color.opacity(0.1))
                                    .frame(width: 44, height: 44)
                                
                                Image(systemName: link.icon)
                                    .foregroundColor(link.color)
                            }
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text(link.title)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .foregroundColor(.primary)
                                
                                Text(link.description)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            Image(systemName: "arrow.right.circle.fill")
                                .foregroundColor(link.color)
                        }
                        .padding(12)
                        .background(Color.appElevatedBackground)
                        .cornerRadius(12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.appBorder.opacity(0.14), lineWidth: 1)
                        )
                    }
                }
            }
            .padding(.horizontal)
        }
        .padding(.bottom, 32)
    }
}

struct VIUKLauncherSettingsView: View {
    @AppStorage("viuk.launcher.backgroundStyle") private var backgroundStyleRawValue = HomeScreenView.BackgroundStyle.gradient.rawValue
    @AppStorage("viuk.launcher.autoFocusSearchField") private var autoFocusSearchField = false
    @AppStorage("viuk.launcher.importedAppsExpanded") private var importedAppsExpanded = false

    var body: some View {
        Form {
            Section("VIUK One について") {
                Text("この設定は VIUK One ランチャー専用です。Safe Browse、AI Studio、Science Club など各アプリの設定とは共有しません。")
                    .foregroundColor(.secondary)
                LabeledContent("著作権", value: AppBrand.copyrightNotice)
            }

            Section("ホーム") {
                Picker("背景スタイル", selection: $backgroundStyleRawValue) {
                    ForEach(HomeScreenView.BackgroundStyle.allCases, id: \.self) { style in
                        Text(style.rawValue).tag(style.rawValue)
                    }
                }

                Toggle("起動時に検索欄へフォーカス", isOn: $autoFocusSearchField)
                Toggle("統合アプリを最初から展開", isOn: $importedAppsExpanded)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("VIUK One 設定")
    }
}

private extension View {
    @ViewBuilder
    func homeLauncherSheetSizing(minWidth: CGFloat, minHeight: CGFloat) -> some View {
        #if os(macOS)
        self.frame(minWidth: minWidth, minHeight: minHeight)
        #else
        self.presentationDetents([.large])
            .presentationDragIndicator(.visible)
        #endif
    }
}

// MARK: - データモデル
struct PopularService: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let icon: String
    let colors: [Color]
    let url: String
}

struct QuickLink: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let color: Color
    let url: String
}

struct Bookmark: Identifiable {
    let id = UUID()
    let title: String
    let url: String
}

struct HistoryItem: Identifiable {
    let id = UUID()
    let url: String
    let title: String
}

struct LearningLink: Identifiable {
    let id = UUID()
    let title: String
    let description: String
    let icon: String
    let color: Color
    let url: String
}

// MARK: - ブックマークマネージャー
class BookmarkManager {
    static let shared = BookmarkManager()
    
    func getAllBookmarks() -> [Bookmark] {
        guard let data = UserDefaults.standard.data(forKey: "bookmarks"),
              let bookmarks = try? JSONDecoder().decode([BookmarkData].self, from: data) else {
            return []
        }
        return bookmarks.map { Bookmark(title: $0.title, url: $0.url) }
    }
    
    func addBookmark(title: String, url: String) {
        var bookmarks = getAllBookmarks()
        bookmarks.append(Bookmark(title: title, url: url))
        saveBookmarks(bookmarks)
    }
    
    func removeBookmark(id: UUID) {
        var bookmarks = getAllBookmarks()
        bookmarks.removeAll { $0.id == id }
        saveBookmarks(bookmarks)
    }
    
    private func saveBookmarks(_ bookmarks: [Bookmark]) {
        let data = bookmarks.map { BookmarkData(title: $0.title, url: $0.url) }
        if let encoded = try? JSONEncoder().encode(data) {
            UserDefaults.standard.set(encoded, forKey: "bookmarks")
        }
    }
}

struct BookmarkData: Codable {
    let title: String
    let url: String
}
