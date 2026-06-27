/*
仕様:
- 役割: オフライン時の超軽量 SML 安全判定器。危険語と安全文脈を重み付けし、誤認識を減らす。
- 主な型: `UltraLightSafetySML`, `UltraLightSMLSignal`, `UltraLightSMLEvaluation`.
- 編集ポイント: カテゴリ語彙、重み、誤認識を抑える減衰語、ブロック閾値を変えるときに触る。
*/
import Foundation

struct UltraLightSMLSignal {
    let category: String
    let probability: Double
    let rawScore: Double
    let matchedKeywords: [String]
    let dampeningKeywords: [String]
    let positiveScore: Double
    let negativeScore: Double

    var isLikelyFalsePositive: Bool {
        let dampeningDominant = negativeScore >= max(positiveScore * 0.66, 0.95)
        let weakRiskContext = matchedKeywords.count <= 2 || positiveScore < 2.4
        return dampeningDominant && weakRiskContext && probability < 0.90
    }
}

struct UltraLightSMLEvaluation {
    let signals: [UltraLightSMLSignal]

    var topSignal: UltraLightSMLSignal? {
        signals.first
    }

    func signal(matching category: String) -> UltraLightSMLSignal? {
        let normalizedCategory = category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return signals.first {
            $0.category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedCategory
        }
    }

    func shouldBlock(strictMode: Bool) -> Bool {
        guard let topSignal else { return false }
        let threshold = strictMode ? 0.68 : 0.76
        return topSignal.probability >= threshold
            && !topSignal.isLikelyFalsePositive
            && (topSignal.matchedKeywords.count >= 2 || topSignal.rawScore >= 1.45)
    }
}

final class UltraLightSafetySML {
    static let shared = UltraLightSafetySML()

    private struct WeightedToken {
        let token: String
        let weight: Double
    }

    private struct ReinforcingPair {
        let left: String
        let right: String
        let bonus: Double
    }

    private struct CategoryModel {
        let canonicalCategory: String
        let aliases: [String]
        let bias: Double
        let positiveTokens: [WeightedToken]
        let urlTokens: [WeightedToken]
        let safeContextTokens: [WeightedToken]
        let reinforcingPairs: [ReinforcingPair]

        func matchesAllowedCategories(_ requestedCategories: Set<String>) -> Bool {
            guard !requestedCategories.isEmpty else { return true }
            return requestedCategories.contains { requested in
                let normalizedRequested = requested.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if canonicalCategory.lowercased() == normalizedRequested {
                    return true
                }
                return aliases.contains { $0.lowercased() == normalizedRequested }
            }
        }

        func displayCategory(for requestedCategories: Set<String>) -> String {
            guard !requestedCategories.isEmpty else { return canonicalCategory }
            for requested in requestedCategories.sorted() {
                let normalizedRequested = requested.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if canonicalCategory.lowercased() == normalizedRequested {
                    return requested
                }
                if aliases.contains(where: { $0.lowercased() == normalizedRequested }) {
                    return requested
                }
            }
            return canonicalCategory
        }
    }

    private let globalSafeContextTokens: [WeightedToken] = [
        .init(token: "教育", weight: 0.28),
        .init(token: "学習", weight: 0.28),
        .init(token: "研究", weight: 0.28),
        .init(token: "教材", weight: 0.24),
        .init(token: "解説", weight: 0.22),
        .init(token: "辞典", weight: 0.20),
        .init(token: "百科", weight: 0.20),
        .init(token: "対策", weight: 0.30),
        .init(token: "防止", weight: 0.30),
        .init(token: "予防", weight: 0.26),
        .init(token: "被害", weight: 0.24),
        .init(token: "相談", weight: 0.24),
        .init(token: "ニュース", weight: 0.22),
        .init(token: "報道", weight: 0.22),
        .init(token: "医療", weight: 0.25),
        .init(token: "学校", weight: 0.20),
        .init(token: "授業", weight: 0.20),
        .init(token: "health", weight: 0.24),
        .init(token: "education", weight: 0.28),
        .init(token: "research", weight: 0.28),
        .init(token: "history", weight: 0.22),
        .init(token: "wikipedia", weight: 0.20),
        .init(token: "guide", weight: 0.18),
        .init(token: "safety", weight: 0.22)
    ]

    private lazy var models: [CategoryModel] = [
        CategoryModel(
            canonicalCategory: "成人向けコンテンツ",
            aliases: ["性教育コンテンツ"],
            bias: -2.15,
            positiveTokens: [
                .init(token: "アダルト", weight: 1.45),
                .init(token: "ポルノ", weight: 1.70),
                .init(token: "エロ", weight: 1.55),
                .init(token: "sex", weight: 1.10),
                .init(token: "xxx", weight: 1.65),
                .init(token: "porn", weight: 1.70),
                .init(token: "adult", weight: 1.45),
                .init(token: "nude", weight: 1.05),
                .init(token: "無修正", weight: 1.85),
                .init(token: "風俗", weight: 1.25),
                .init(token: "fanza", weight: 1.55),
                .init(token: "セックス", weight: 1.35),
                .init(token: "live chat", weight: 0.90)
            ],
            urlTokens: [
                .init(token: ".xxx", weight: 1.45),
                .init(token: ".adult", weight: 1.10),
                .init(token: "18+", weight: 0.85),
                .init(token: "/adult", weight: 0.75)
            ],
            safeContextTokens: [
                .init(token: "性教育", weight: 1.45),
                .init(token: "保健", weight: 0.95),
                .init(token: "教育", weight: 0.90),
                .init(token: "学習", weight: 0.80),
                .init(token: "医療", weight: 0.80),
                .init(token: "health", weight: 0.70),
                .init(token: "research", weight: 0.72),
                .init(token: "ニュース", weight: 0.52),
                .init(token: "被害", weight: 0.68)
            ],
            reinforcingPairs: [
                .init(left: "adult", right: "live chat", bonus: 0.50),
                .init(left: "アダルト", right: "動画", bonus: 0.40),
                .init(left: "18+", right: "無料", bonus: 0.32)
            ]
        ),
        CategoryModel(
            canonicalCategory: "暴力",
            aliases: [],
            bias: -2.20,
            positiveTokens: [
                .init(token: "暴力", weight: 1.05),
                .init(token: "殺人", weight: 1.55),
                .init(token: "グロ", weight: 1.55),
                .init(token: "死体", weight: 1.45),
                .init(token: "拷問", weight: 1.30),
                .init(token: "銃", weight: 1.05),
                .init(token: "weapon", weight: 1.00),
                .init(token: "gore", weight: 1.45),
                .init(token: "murder", weight: 1.45)
            ],
            urlTokens: [
                .init(token: "/gore", weight: 1.00),
                .init(token: "/violence", weight: 0.85)
            ],
            safeContextTokens: [
                .init(token: "ニュース", weight: 0.70),
                .init(token: "報道", weight: 0.75),
                .init(token: "歴史", weight: 0.70),
                .init(token: "教材", weight: 0.60),
                .init(token: "防犯", weight: 0.60),
                .init(token: "事件解説", weight: 0.60)
            ],
            reinforcingPairs: [
                .init(left: "殺人", right: "事件", bonus: 0.18),
                .init(left: "gore", right: "video", bonus: 0.45)
            ]
        ),
        CategoryModel(
            canonicalCategory: "不適切な表現",
            aliases: [],
            bias: -2.35,
            positiveTokens: [
                .init(token: "fuck", weight: 1.10),
                .init(token: "shit", weight: 1.00),
                .init(token: "死ね", weight: 1.35),
                .init(token: "ヘイト", weight: 1.10),
                .init(token: "差別", weight: 1.05),
                .init(token: "侮辱", weight: 0.95)
            ],
            urlTokens: [],
            safeContextTokens: [
                .init(token: "引用", weight: 0.55),
                .init(token: "ニュース", weight: 0.52),
                .init(token: "教材", weight: 0.50),
                .init(token: "研究", weight: 0.55)
            ],
            reinforcingPairs: [
                .init(left: "差別", right: "ヘイト", bonus: 0.30)
            ]
        ),
        CategoryModel(
            canonicalCategory: "勧誘、カジノ、金融等",
            aliases: ["ギャンブル"],
            bias: -2.05,
            positiveTokens: [
                .init(token: "カジノ", weight: 1.55),
                .init(token: "オンラインカジノ", weight: 1.80),
                .init(token: "賭博", weight: 1.55),
                .init(token: "bet", weight: 1.15),
                .init(token: "casino", weight: 1.55),
                .init(token: "競馬", weight: 1.00),
                .init(token: "競輪", weight: 1.00),
                .init(token: "競艇", weight: 1.00),
                .init(token: "パチンコ", weight: 1.00),
                .init(token: "baccarat", weight: 1.20),
                .init(token: "slot", weight: 0.92),
                .init(token: "free spin", weight: 1.10)
            ],
            urlTokens: [
                .init(token: ".bet", weight: 1.35),
                .init(token: ".casino", weight: 1.35),
                .init(token: "/casino", weight: 0.85)
            ],
            safeContextTokens: [
                .init(token: "依存", weight: 0.95),
                .init(token: "対策", weight: 0.78),
                .init(token: "違法", weight: 0.95),
                .init(token: "規制", weight: 0.90),
                .init(token: "ニュース", weight: 0.68),
                .init(token: "相談", weight: 0.66),
                .init(token: "被害", weight: 0.66)
            ],
            reinforcingPairs: [
                .init(left: "casino", right: "bonus", bonus: 0.50),
                .init(left: "カジノ", right: "無料", bonus: 0.35),
                .init(left: "bet", right: "odds", bonus: 0.45)
            ]
        ),
        CategoryModel(
            canonicalCategory: "出会い系",
            aliases: [],
            bias: -2.10,
            positiveTokens: [
                .init(token: "出会い系", weight: 1.75),
                .init(token: "マッチング", weight: 0.95),
                .init(token: "不倫", weight: 1.25),
                .init(token: "援助", weight: 1.20),
                .init(token: "パパ活", weight: 1.55),
                .init(token: "escort", weight: 1.45),
                .init(token: "hookup", weight: 1.30),
                .init(token: "即会い", weight: 1.45)
            ],
            urlTokens: [
                .init(token: "/dating", weight: 0.95),
                .init(token: "match", weight: 0.42)
            ],
            safeContextTokens: [
                .init(token: "被害", weight: 0.82),
                .init(token: "対策", weight: 0.80),
                .init(token: "相談", weight: 0.86),
                .init(token: "安全", weight: 0.66),
                .init(token: "ニュース", weight: 0.62),
                .init(token: "恋愛相談", weight: 1.05),
                .init(token: "相性", weight: 0.98),
                .init(token: "relationship", weight: 0.72),
                .init(token: "advice", weight: 0.62),
                .init(token: "パートナー", weight: 0.62),
                .init(token: "カップル", weight: 0.58),
                .init(token: "心理", weight: 0.48)
            ],
            reinforcingPairs: [
                .init(left: "出会い系", right: "無料", bonus: 0.35),
                .init(left: "マッチング", right: "即会い", bonus: 0.65),
                .init(left: "escort", right: "private", bonus: 0.45)
            ]
        ),
        CategoryModel(
            canonicalCategory: "薬物",
            aliases: ["飲酒喫煙"],
            bias: -2.15,
            positiveTokens: [
                .init(token: "麻薬", weight: 1.65),
                .init(token: "覚醒剤", weight: 1.75),
                .init(token: "大麻", weight: 1.35),
                .init(token: "違法薬物", weight: 1.85),
                .init(token: "ドラッグ", weight: 1.05),
                .init(token: "cocaine", weight: 1.60),
                .init(token: "mdma", weight: 1.70),
                .init(token: "weed", weight: 1.10),
                .init(token: "たばこ", weight: 0.90),
                .init(token: "喫煙", weight: 0.85)
            ],
            urlTokens: [
                .init(token: "/drug", weight: 0.82),
                .init(token: "/weed", weight: 0.82)
            ],
            safeContextTokens: [
                .init(token: "医療", weight: 1.00),
                .init(token: "治療", weight: 1.00),
                .init(token: "依存", weight: 0.88),
                .init(token: "対策", weight: 0.78),
                .init(token: "教育", weight: 0.66),
                .init(token: "保健", weight: 0.84),
                .init(token: "ニュース", weight: 0.65)
            ],
            reinforcingPairs: [
                .init(left: "大麻", right: "販売", bonus: 0.48),
                .init(left: "cocaine", right: "buy", bonus: 0.60)
            ]
        ),
        CategoryModel(
            canonicalCategory: "個人情報詐欺",
            aliases: ["既知の悪質なサイト"],
            bias: -2.10,
            positiveTokens: [
                .init(token: "password", weight: 1.00),
                .init(token: "verify", weight: 1.05),
                .init(token: "wallet", weight: 1.18),
                .init(token: "seed phrase", weight: 1.80),
                .init(token: "credit card", weight: 1.30),
                .init(token: "ログイン", weight: 0.78),
                .init(token: "本人確認", weight: 0.78),
                .init(token: "パスワード", weight: 1.00),
                .init(token: "クレジットカード", weight: 1.30),
                .init(token: "口座番号", weight: 1.55),
                .init(token: "secret recovery phrase", weight: 1.95)
            ],
            urlTokens: [
                .init(token: "login", weight: 0.65),
                .init(token: "signin", weight: 0.65),
                .init(token: "verify", weight: 0.72),
                .init(token: "wallet", weight: 0.78)
            ],
            safeContextTokens: [
                .init(token: "対策", weight: 1.00),
                .init(token: "防止", weight: 1.00),
                .init(token: "注意", weight: 0.76),
                .init(token: "警察", weight: 0.82),
                .init(token: "公式ヘルプ", weight: 0.72),
                .init(token: "サポート", weight: 0.44),
                .init(token: "news", weight: 0.55),
                .init(token: "guide", weight: 0.45)
            ],
            reinforcingPairs: [
                .init(left: "login", right: "password", bonus: 0.55),
                .init(left: "wallet", right: "seed phrase", bonus: 0.92),
                .init(left: "本人確認", right: "クレジットカード", bonus: 0.72)
            ]
        )
    ]

    private init() {}

    func evaluate(
        text: String,
        url: String = "",
        allowedCategories: Set<String> = [],
        seedKeywords: [String] = []
    ) -> UltraLightSMLEvaluation {
        let normalizedText = normalize(text)
        let normalizedURL = normalize(url)
        let combined = normalizedURL + " " + normalizedText
        let activeModels = models.filter { $0.matchesAllowedCategories(allowedCategories) }

        var signals: [UltraLightSMLSignal] = []
        for model in activeModels {
            guard let signal = score(
                model: model,
                combined: combined,
                normalizedURL: normalizedURL,
                seedKeywords: seedKeywords,
                requestedCategories: allowedCategories
            ) else {
                continue
            }
            signals.append(signal)
        }

        signals.sort {
            if $0.probability == $1.probability {
                return $0.rawScore > $1.rawScore
            }
            return $0.probability > $1.probability
        }
        return UltraLightSMLEvaluation(signals: signals)
    }

    private func score(
        model: CategoryModel,
        combined: String,
        normalizedURL: String,
        seedKeywords: [String],
        requestedCategories: Set<String>
    ) -> UltraLightSMLSignal? {
        var rawScore = model.bias
        var positiveScore = 0.0
        var negativeScore = 0.0
        var matchedKeywords = Set<String>()
        var dampeningKeywords = Set<String>()

        for feature in model.positiveTokens {
            guard combined.contains(feature.token.lowercased()) else { continue }
            let boost = feature.weight
            rawScore += boost
            positiveScore += boost
            matchedKeywords.insert(feature.token)
        }

        for feature in model.urlTokens {
            guard normalizedURL.contains(feature.token.lowercased()) else { continue }
            let boost = feature.weight
            rawScore += boost
            positiveScore += boost
            matchedKeywords.insert(feature.token)
        }

        for keyword in Set(seedKeywords.map { $0.lowercased() }) {
            guard !keyword.isEmpty, combined.contains(keyword) else { continue }
            rawScore += 0.18
            positiveScore += 0.18
            matchedKeywords.insert(keyword)
        }

        for feature in model.safeContextTokens {
            guard combined.contains(feature.token.lowercased()) else { continue }
            rawScore -= feature.weight
            negativeScore += feature.weight
            dampeningKeywords.insert(feature.token)
        }

        for feature in globalSafeContextTokens {
            guard combined.contains(feature.token.lowercased()) else { continue }
            rawScore -= feature.weight
            negativeScore += feature.weight
            dampeningKeywords.insert(feature.token)
        }

        for pair in model.reinforcingPairs {
            guard combined.contains(pair.left.lowercased()),
                  combined.contains(pair.right.lowercased()) else {
                continue
            }
            rawScore += pair.bonus
            positiveScore += pair.bonus
        }

        guard !matchedKeywords.isEmpty else {
            return nil
        }

        if matchedKeywords.count == 1 && positiveScore < 1.9 {
            rawScore -= 0.35
        } else if matchedKeywords.count >= 3 {
            rawScore += 0.24
            positiveScore += 0.24
        }

        if dampeningKeywords.count >= 2 {
            rawScore -= 0.28
            negativeScore += 0.28
        }

        let probability = sigmoid(rawScore)
        if probability < 0.34 {
            return nil
        }

        return UltraLightSMLSignal(
            category: model.displayCategory(for: requestedCategories),
            probability: probability,
            rawScore: rawScore,
            matchedKeywords: Array(matchedKeywords).sorted(),
            dampeningKeywords: Array(dampeningKeywords).sorted(),
            positiveScore: positiveScore,
            negativeScore: negativeScore
        )
    }

    private func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }

    private func sigmoid(_ value: Double) -> Double {
        1.0 / (1.0 + exp(-value))
    }
}
