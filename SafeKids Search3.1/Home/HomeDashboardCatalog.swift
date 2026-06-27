/*
仕様:
- 役割: VIUK One ホームの新UIで使うフォーカスモード、保護プリセット、報酬バッジの定義をまとめる。
- 主な型: `HomeFocusMode`, `HomeSafetyPreset`, `HomeBadgeDefinition`.
- 編集ポイント: ホーム体験の方向性、配色、クイックプリセット、報酬段階を変えるときに触る。
*/

import SwiftUI

enum HomeFocusMode: String, CaseIterable, Identifiable {
    case explorer
    case study
    case calm
    case creator

    var id: String { rawValue }

    var title: String {
        switch self {
        case .explorer: return "Explorer"
        case .study: return "Study"
        case .calm: return "Calm"
        case .creator: return "Creator"
        }
    }

    var subtitle: String {
        switch self {
        case .explorer:
            return "安全に調べて世界を広げる"
        case .study:
            return "学習と復習に集中する"
        case .calm:
            return "刺激を減らして静かに使う"
        case .creator:
            return "AIと学びでつくる日にする"
        }
    }

    var icon: String {
        switch self {
        case .explorer: return "safari.fill"
        case .study: return "books.vertical.fill"
        case .calm: return "moon.stars.fill"
        case .creator: return "sparkles.rectangle.stack.fill"
        }
    }

    var eyebrow: String {
        switch self {
        case .explorer: return "DISCOVERY DECK"
        case .study: return "LEARNING DRIVE"
        case .calm: return "QUIET FLOW"
        case .creator: return "IDEA STUDIO"
        }
    }

    var palette: [Color] {
        switch self {
        case .explorer:
            return [
                Color(red: 0.07, green: 0.16, blue: 0.38),
                Color(red: 0.13, green: 0.47, blue: 0.88),
                Color(red: 0.33, green: 0.80, blue: 0.93)
            ]
        case .study:
            return [
                Color(red: 0.09, green: 0.22, blue: 0.24),
                Color(red: 0.10, green: 0.58, blue: 0.49),
                Color(red: 0.84, green: 0.93, blue: 0.56)
            ]
        case .calm:
            return [
                Color(red: 0.11, green: 0.11, blue: 0.25),
                Color(red: 0.34, green: 0.26, blue: 0.57),
                Color(red: 0.90, green: 0.63, blue: 0.42)
            ]
        case .creator:
            return [
                Color(red: 0.24, green: 0.10, blue: 0.18),
                Color(red: 0.90, green: 0.30, blue: 0.28),
                Color(red: 0.99, green: 0.73, blue: 0.27)
            ]
        }
    }

    var sparks: [String] {
        switch self {
        case .explorer:
            return [
                "宇宙のひみつ 子ども向け",
                "海の生き物 図鑑 やさしい",
                "世界のふしぎ 建物",
                "今日の科学ニュース やさしく"
            ]
        case .study:
            return [
                "分数のコツ 小学生",
                "都道府県 クイズ やさしい",
                "読書感想文 まとめ方",
                "英単語 覚え方 小学生"
            ]
        case .calm:
            return [
                "ねるまえに読む お話",
                "やさしい折り紙 動物",
                "星座の見つけ方 子ども向け",
                "静かな音楽 勉強用"
            ]
        case .creator:
            return [
                "自由研究 アイデア すぐできる",
                "発明のしくみ 子ども向け",
                "絵日記 テンプレート",
                "AIにきく 工作アイデア"
            ]
        }
    }
}

enum HomeSafetyPreset: String, CaseIterable, Identifiable {
    case shield
    case balanced
    case quiet

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shield: return "Study Shield"
        case .balanced: return "Balanced"
        case .quiet: return "Quiet Night"
        }
    }

    var subtitle: String {
        switch self {
        case .shield:
            return "学習向けに保護を強める"
        case .balanced:
            return "通常の探索向けに整える"
        case .quiet:
            return "広告や刺激を減らす"
        }
    }

    var icon: String {
        switch self {
        case .shield: return "shield.lefthalf.filled.badge.checkmark"
        case .balanced: return "dial.high.fill"
        case .quiet: return "moon.zzz.fill"
        }
    }

    var palette: [Color] {
        switch self {
        case .shield:
            return [Color(red: 0.12, green: 0.45, blue: 0.87), Color(red: 0.14, green: 0.70, blue: 0.76)]
        case .balanced:
            return [Color(red: 0.14, green: 0.55, blue: 0.43), Color(red: 0.70, green: 0.84, blue: 0.33)]
        case .quiet:
            return [Color(red: 0.29, green: 0.24, blue: 0.54), Color(red: 0.88, green: 0.56, blue: 0.32)]
        }
    }

    func apply(to settings: ParentalSettingsManager) {
        switch self {
        case .shield:
            settings.enableSafeBrowsing = true
            settings.enableAIDetection = true
            settings.enableRealtimeDetection = true
            settings.enableAICoach = true
            settings.strictMode = true
            settings.confidenceThreshold = 0.92
            settings.blockAds = true
            settings.blockTrackers = true
            settings.blockPopups = true
        case .balanced:
            settings.enableSafeBrowsing = true
            settings.enableAIDetection = true
            settings.enableRealtimeDetection = true
            settings.enableAICoach = true
            settings.strictMode = false
            settings.confidenceThreshold = 0.84
            settings.blockAds = false
            settings.blockTrackers = true
            settings.blockPopups = true
        case .quiet:
            settings.enableSafeBrowsing = true
            settings.enableAIDetection = true
            settings.enableRealtimeDetection = true
            settings.enableAICoach = false
            settings.strictMode = true
            settings.confidenceThreshold = 0.94
            settings.blockAds = true
            settings.blockTrackers = true
            settings.blockPopups = true
            settings.blockRedirects = true
        }
    }
}

struct HomeBadgeDefinition: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let requiredPoints: Int

    static let all: [HomeBadgeDefinition] = [
        HomeBadgeDefinition(
            id: "spark_rookie",
            title: "Spark Rookie",
            subtitle: "最初のホームミッション達成",
            icon: "sparkles",
            requiredPoints: 40
        ),
        HomeBadgeDefinition(
            id: "safe_orbit",
            title: "Safe Orbit",
            subtitle: "安全な使い方が習慣化",
            icon: "shield.checkered",
            requiredPoints: 120
        ),
        HomeBadgeDefinition(
            id: "learning_wave",
            title: "Learning Wave",
            subtitle: "学習と探索の両方を継続",
            icon: "water.waves.and.arrow.trianglehead.forward",
            requiredPoints: 220
        ),
        HomeBadgeDefinition(
            id: "family_pilot",
            title: "Family Pilot",
            subtitle: "VIUK One を使いこなしている",
            icon: "star.circle.fill",
            requiredPoints: 360
        )
    ]
}
