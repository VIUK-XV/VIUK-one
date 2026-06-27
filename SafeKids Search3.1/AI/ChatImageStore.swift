/*
仕様:
- 役割: チャットの添付画像 (JPEG Data) を Application Support 下のファイルとして保存し、
  ChatMessage 側からは「画像 ID」だけを参照することで UserDefaults の 4MB 上限を回避する。
- 主な型: `ChatImageStore`.
- 編集ポイント: 添付画像のファイル配置、命名、削除ポリシーを変えるときに触る。
- 背景: 旧実装は ChatMessage.attachedImagesData ([Data]) を Codable に乗せ、80件のメッセージ全部を
  UserDefaults に丸ごと書き込んでいた。1MB の画像 × 数件で 4MB 上限を超えて履歴が消える事故が
  実環境で確認されたため、画像本体は外部ファイル、index には ID のみを残す方式に切り替える。
*/

import CryptoKit
import Foundation

final class ChatImageStore {
    static let shared = ChatImageStore()

    private let fileManager = FileManager.default
    private let directoryURL: URL
    private let queue = DispatchQueue(label: "viuk.ai.chat-image-store", qos: .utility)

    private init() {
        let base = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory
        directoryURL = base
            .appendingPathComponent(AppBrand.keychainService, isDirectory: true)
            .appendingPathComponent("ChatAttachments", isDirectory: true)
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    /// 画像 Data を保存して識別子 (ファイル名) を返す。失敗時は nil。
    /// ID は内容ハッシュ (SHA256) なので、同じ Data を何度 save しても同じ ID が返り、
    /// 既存ファイルがある場合は書き込みをスキップする (idempotent)。これにより、毎ターン save が
    /// 呼ばれてもオーファンが増えない。
    @discardableResult
    func save(_ data: Data) -> String? {
        let digest = SHA256.hash(data: data)
        let id = digest.compactMap { String(format: "%02x", $0) }.joined()
        let url = directoryURL.appendingPathComponent(id).appendingPathExtension("bin")
        if fileManager.fileExists(atPath: url.path) {
            return id
        }
        do {
            try data.write(to: url, options: [.atomic])
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            var mutableURL = url
            try? mutableURL.setResourceValues(resourceValues)
            return id
        } catch {
            NSLog("[ChatImageStore] 保存失敗: \(error)")
            return nil
        }
    }

    /// ID から画像 Data を読み出す。存在しない or 読込失敗時は nil。
    func load(id: String) -> Data? {
        let url = directoryURL.appendingPathComponent(id).appendingPathExtension("bin")
        return try? Data(contentsOf: url)
    }

    /// 指定 ID 群以外のファイルを削除する (オーファン回収)。
    /// 履歴からメッセージが削除されたあとに呼び出すと、参照されていない画像ファイルが消える。
    func purgeOrphans(keepIDs: Set<String>) {
        queue.async { [self] in
            guard let entries = try? fileManager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil) else { return }
            for url in entries {
                let id = url.deletingPathExtension().lastPathComponent
                if !keepIDs.contains(id) {
                    try? fileManager.removeItem(at: url)
                }
            }
        }
    }
}
