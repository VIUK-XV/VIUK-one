/*
仕様:
- 役割: AIチャットのスレッド一覧、選択中スレッド、メッセージ履歴の保存と復元を担当する。
- 主な型: `AIChatPersistence`.
- 編集ポイント: 保存形式、件数制限、キー生成の責務を変えるときに触る。
*/
import Foundation

final class AIChatPersistence {
    static let shared = AIChatPersistence()

    private init() {}

    private let largeDefaultsWriteLimit = 3_500_000
    private let historyDirectoryName = "AIChatHistories"

    private struct StoredChatMessage: Codable {
        let role: String
        let content: String
        let timestamp: Date
        /// 旧バージョン互換: 添付画像本体を JSON に埋め込んでいた頃の生 Data。
        /// 新規保存では使わない (nil 化)。読み込み時に存在すれば自動的に
        /// ChatImageStore へ移行し、以降は attachedImageIDs を使う。
        let attachedImagesData: [Data]?
        /// 新方式: 添付画像本体は `ChatImageStore` のファイルに置き、ここには ID だけ持つ。
        let attachedImageIDs: [String]?
        let thoughtDetails: AICoachService.ResponseThoughtDetails?
        let responseActions: [AICoachService.ResponseAction]?
        let resultPage: AIResultPage?

        enum CodingKeys: String, CodingKey {
            case role, content, timestamp, attachedImagesData, attachedImageIDs
            case thoughtDetails, responseActions, resultPage
        }

        init(
            role: String,
            content: String,
            timestamp: Date,
            attachedImagesData: [Data]?,
            attachedImageIDs: [String]?,
            thoughtDetails: AICoachService.ResponseThoughtDetails?,
            responseActions: [AICoachService.ResponseAction]?,
            resultPage: AIResultPage?
        ) {
            self.role = role
            self.content = content
            self.timestamp = timestamp
            self.attachedImagesData = attachedImagesData
            self.attachedImageIDs = attachedImageIDs
            self.thoughtDetails = thoughtDetails
            self.responseActions = responseActions
            self.resultPage = resultPage
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            role = try c.decode(String.self, forKey: .role)
            content = try c.decode(String.self, forKey: .content)
            timestamp = try c.decode(Date.self, forKey: .timestamp)
            attachedImagesData = try c.decodeIfPresent([Data].self, forKey: .attachedImagesData)
            attachedImageIDs = try c.decodeIfPresent([String].self, forKey: .attachedImageIDs)
            thoughtDetails = try c.decodeIfPresent(AICoachService.ResponseThoughtDetails.self, forKey: .thoughtDetails)
            responseActions = try c.decodeIfPresent([AICoachService.ResponseAction].self, forKey: .responseActions)
            resultPage = try c.decodeIfPresent(AIResultPage.self, forKey: .resultPage)
        }
    }

    struct ThreadState {
        let threads: [AICoachService.ChatThreadSummary]
        let currentThreadID: String
    }

    func saveMessages(
        _ messages: [AICoachService.ChatMessage],
        maxSavedMessages: Int,
        chatHistoryKey: String,
        aliases: [String]
    ) {
        let trimmedMessages = Array(messages.suffix(maxSavedMessages))
        let imageStore = ChatImageStore.shared
        let storedMessages = trimmedMessages.map { message -> StoredChatMessage in
            // 画像 Data は ChatImageStore に書き出し、UserDefaults には ID のみを持たせる。
            // 既に同 message に IDs が紐づいているケースは想定しない (毎回新規 ID 発行)。
            let imageIDs: [String]? = message.attachedImagesData?.compactMap { imageStore.save($0) }
            return StoredChatMessage(
                role: message.role == .user ? "user" : "assistant",
                content: message.content,
                timestamp: message.timestamp,
                attachedImagesData: nil,
                attachedImageIDs: (imageIDs?.isEmpty ?? true) ? nil : imageIDs,
                thoughtDetails: message.thoughtDetails,
                responseActions: message.responseActions,
                resultPage: message.resultPage
            )
        }

        guard let data = try? JSONEncoder().encode(storedMessages) else {
            return
        }

        if persistHistoryDataToFile(data, primaryKey: chatHistoryKey) {
            // Tool/search/debug payload can exceed the CFPreferences 4 MB value
            // limit. Keep chat histories out of UserDefaults and remove stale
            // oversized values so later preference writes stay stable.
            AILegacyCompatibility.removeValue(
                primaryKey: chatHistoryKey,
                aliases: aliases
            )
            return
        }

        guard data.count < largeDefaultsWriteLimit else {
            NSLog("[AIChatPersistence] skipped UserDefaults fallback for oversized chat history: bytes=%d key=%@", data.count, chatHistoryKey)
            return
        }

        AILegacyCompatibility.exportData(
            data,
            primaryKey: chatHistoryKey,
            aliases: aliases
        )
    }

    func loadMessages(
        chatHistoryKey: String,
        aliases: [String]
    ) -> [AICoachService.ChatMessage] {
        let data: Data?
        if let fileData = loadHistoryDataFromFile(primaryKey: chatHistoryKey) {
            data = fileData
        } else {
            data = AILegacyCompatibility.dataValue(primaryKey: chatHistoryKey, aliases: aliases)
        }

        guard let data,
              let storedMessages = try? JSONDecoder().decode([StoredChatMessage].self, from: data) else {
            return []
        }

        let imageStore = ChatImageStore.shared
        return storedMessages.map { stored in
            // 新方式: ID から Data を復元
            let fromIDs: [Data] = (stored.attachedImageIDs ?? []).compactMap { imageStore.load(id: $0) }
            // 旧方式: 直埋め込み Data。あればそのまま使う (次回 save 時に ID 化される)。
            let combined: [Data]? = {
                if !fromIDs.isEmpty { return fromIDs }
                return stored.attachedImagesData
            }()
            return AICoachService.ChatMessage(
                role: stored.role == "user" ? .user : .assistant,
                content: stored.content,
                timestamp: stored.timestamp,
                attachedImagesData: combined,
                thoughtDetails: stored.thoughtDetails,
                responseActions: stored.responseActions,
                resultPage: stored.resultPage
            )
        }
    }

    private func persistHistoryDataToFile(_ data: Data, primaryKey: String) -> Bool {
        guard let url = historyFileURL(for: primaryKey) else { return false }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: [.atomic])
            return true
        } catch {
            NSLog("[AIChatPersistence] file history save failed: %@ key=%@", error.localizedDescription, primaryKey)
            return false
        }
    }

    private func loadHistoryDataFromFile(primaryKey: String) -> Data? {
        guard let url = historyFileURL(for: primaryKey) else { return nil }
        return try? Data(contentsOf: url)
    }

    private func historyFileURL(for primaryKey: String) -> URL? {
        guard let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let encodedKey = Data(primaryKey.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return baseURL
            .appendingPathComponent(historyDirectoryName, isDirectory: true)
            .appendingPathComponent(encodedKey)
            .appendingPathExtension("json")
    }

    func loadThreadState(
        threadIndexKey: String,
        threadAliases: [String],
        currentThreadKey: String,
        currentThreadAliases: [String],
        defaultTitleProvider: () -> String
    ) -> ThreadState {
        let threads: [AICoachService.ChatThreadSummary]
        if let data = AILegacyCompatibility.dataValue(primaryKey: threadIndexKey, aliases: threadAliases),
           let decoded = try? JSONDecoder().decode([AICoachService.ChatThreadSummary].self, from: data),
           !decoded.isEmpty {
            threads = decoded.sorted { $0.updatedAt > $1.updatedAt }
        } else {
            threads = []
        }

        let selectedThread = AILegacyCompatibility.stringValue(
            primaryKey: currentThreadKey,
            aliases: currentThreadAliases
        )

        if let selectedThread, threads.contains(where: { $0.id == selectedThread }) {
            return ThreadState(threads: threads, currentThreadID: selectedThread)
        }

        if let first = threads.first {
            return ThreadState(threads: threads, currentThreadID: first.id)
        }

        let initialThread = AICoachService.ChatThreadSummary(
            id: UUID().uuidString,
            title: defaultTitleProvider(),
            updatedAt: Date()
        )
        return ThreadState(threads: [initialThread], currentThreadID: initialThread.id)
    }

    func saveThreadIndex(
        _ threads: [AICoachService.ChatThreadSummary],
        threadIndexKey: String,
        aliases: [String]
    ) {
        if let data = try? JSONEncoder().encode(threads) {
            AILegacyCompatibility.exportData(
                data,
                primaryKey: threadIndexKey,
                aliases: aliases
            )
        }
    }

    func saveCurrentThreadSelection(
        _ currentThreadID: String,
        currentThreadKey: String,
        aliases: [String]
    ) {
        AILegacyCompatibility.exportString(
            currentThreadID,
            primaryKey: currentThreadKey,
            aliases: aliases
        )
    }
}
