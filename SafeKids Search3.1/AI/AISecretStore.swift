/*
仕様:
- 役割: AI関連の秘密情報を安全に保持し、旧UserDefaults保存から移行する。
- 主な型: `AISecretStore`.
- 編集ポイント: 秘密情報の保存先、移行対象キー、Info.plist / 環境変数の参照順を変えるときに触る。
*/
import Foundation

final class AISecretStore {
    static let shared = AISecretStore()

    enum SecretKey: String {
        case geminiAPIKey = "ai.secret.gemini.apiKey"
        case gemmaWebReaderAPIKey = "ai.secret.gemma.webReader.apiKey"
        case ollamaWebSearchAPIKey = "ai.secret.ollama.webSearch.apiKey"
        case localModelAccessToken = "ai.secret.localModel.accessToken"
        case localSupportModelAccessToken = "ai.secret.localSupportModel.accessToken"
        case textRazorAPIKey = "ai.secret.textrazor.apiKey"
    }

    private let defaults = UserDefaults.standard
    private var cachedAppManagedSecrets: [String: String]?

    private struct AppManagedSecretPayload: Codable {
        var values: [String: String]
    }

    private init() {
        migrateLegacySecretsIfNeeded()
    }

    func string(for key: SecretKey) -> String? {
        let rawValue = appManagedString(for: key)
            ?? KeychainHelper.shared.getString(forKey: key.rawValue)
        let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    func strings(for key: SecretKey) -> [String] {
        guard let value = string(for: key) else { return [] }
        var resolved: [String] = []
        for raw in value.components(separatedBy: CharacterSet(charactersIn: "\n\r,;")) {
            let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, !resolved.contains(normalized) else { continue }
            resolved.append(normalized)
        }
        return resolved
    }

    func setString(_ value: String, for key: SecretKey) {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty {
            removeValue(for: key)
            return
        }
        setAppManagedString(normalized, for: key)
        // Best-effort mirror only. The app-managed file is authoritative for this
        // local experiment so Keychain permission prompts never block usage.
        _ = KeychainHelper.shared.setString(normalized, forKey: key.rawValue)
    }

    func setStrings(_ values: [String], for key: SecretKey) {
        let unique = values.reduce(into: [String]()) { partial, value in
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, !partial.contains(normalized) else { return }
            partial.append(normalized)
        }
        setString(unique.joined(separator: "\n"), for: key)
    }

    func removeValue(for key: SecretKey) {
        KeychainHelper.shared.delete(key: key.rawValue)
        removeAppManagedValue(for: key)
    }

    func availableGeminiAPIKeys() -> [String] {
        []
    }

    func geminiKeySourceLabel() -> String {
        "廃止済み"
    }

    func configuredTextRazorAPIKey() -> String? {
        uniqueNonEmptyValues([
            string(for: .textRazorAPIKey),
            infoOrEnvironmentValue(infoKey: "TEXTRAZOR_API_KEY", environmentKey: "TEXTRAZOR_API_KEY")
        ]).first
    }

    func configuredGemmaWebReaderAPIKey() -> String? {
        uniqueNonEmptyValues([
            string(for: .gemmaWebReaderAPIKey),
            infoOrEnvironmentValue(infoKey: "GEMMA_API_KEY", environmentKey: "GEMMA_API_KEY"),
            infoOrEnvironmentValue(infoKey: "GOOGLE_API_KEY", environmentKey: "GOOGLE_API_KEY"),
            infoOrEnvironmentValue(infoKey: "GEMINI_API_KEY", environmentKey: "GEMINI_API_KEY"),
            string(for: .geminiAPIKey)
        ]).first
    }

    func configuredOllamaWebSearchAPIKeys() -> [String] {
        uniqueNonEmptyValues([
            string(for: .ollamaWebSearchAPIKey),
            infoOrEnvironmentValue(infoKey: "OLLAMA_WEB_SEARCH_API_KEY", environmentKey: "OLLAMA_WEB_SEARCH_API_KEY"),
            infoOrEnvironmentValue(infoKey: "OLLAMA_API_KEY", environmentKey: "OLLAMA_API_KEY")
        ].flatMap { splitSecretList($0) })
    }

    private func migrateLegacySecretsIfNeeded() {
        migrateSecret(
            to: .geminiAPIKey,
            primaryKey: "geminiAPIKey",
            aliases: AILegacyCompatibility.geminiAPIKeyAliases
        )
        migrateSecret(
            to: .gemmaWebReaderAPIKey,
            primaryKey: "gemmaWebReaderAPIKey",
            aliases: AILegacyCompatibility.gemmaWebReaderAPIKeyAliases
        )
        migrateSecret(
            to: .ollamaWebSearchAPIKey,
            primaryKey: "ollamaWebSearchAPIKey",
            aliases: AILegacyCompatibility.webSearchAPIKeyAliases
        )
        migrateSecret(
            to: .localModelAccessToken,
            primaryKey: "localAssistantDownloadToken",
            aliases: AILegacyCompatibility.localModelTokenAliases
        )
        migrateSecret(
            to: .localSupportModelAccessToken,
            primaryKey: "localSupportAssistantDownloadToken",
            aliases: []
        )
    }

    private func migrateSecret(to destination: SecretKey, primaryKey: String, aliases: [String]) {
        guard string(for: destination) == nil else {
            AILegacyCompatibility.removeValue(primaryKey: primaryKey, aliases: aliases, defaults: defaults)
            return
        }

        if let legacyValue = AILegacyCompatibility.stringValue(
            primaryKey: primaryKey,
            aliases: aliases,
            defaults: defaults
        )?.trimmingCharacters(in: .whitespacesAndNewlines),
           !legacyValue.isEmpty {
            let didStore = KeychainHelper.shared.setString(legacyValue, forKey: destination.rawValue)
            if !didStore || string(for: destination) == nil {
                return
            }
        }

        AILegacyCompatibility.removeValue(primaryKey: primaryKey, aliases: aliases, defaults: defaults)
    }

    private func appManagedSecretsURL() -> URL? {
        guard let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }

        return baseURL
            .appendingPathComponent(AppBrand.displayName, isDirectory: true)
            .appendingPathComponent("AI", isDirectory: true)
            .appendingPathComponent("AppManagedSecrets.json", isDirectory: false)
    }

    private func appManagedString(for key: SecretKey) -> String? {
        loadAppManagedSecrets()[key.rawValue]
    }

    private func setAppManagedString(_ value: String, for key: SecretKey) {
        var secrets = loadAppManagedSecrets()
        secrets[key.rawValue] = value
        saveAppManagedSecrets(secrets)
    }

    private func removeAppManagedValue(for key: SecretKey) {
        var secrets = loadAppManagedSecrets()
        secrets.removeValue(forKey: key.rawValue)
        saveAppManagedSecrets(secrets)
    }

    private func loadAppManagedSecrets() -> [String: String] {
        if let cachedAppManagedSecrets {
            return cachedAppManagedSecrets
        }

        guard let fileURL = appManagedSecretsURL(),
              let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(AppManagedSecretPayload.self, from: data) else {
            cachedAppManagedSecrets = [:]
            return [:]
        }

        cachedAppManagedSecrets = payload.values
        return payload.values
    }

    private func saveAppManagedSecrets(_ secrets: [String: String]) {
        cachedAppManagedSecrets = secrets
        guard let fileURL = appManagedSecretsURL() else { return }
        let directoryURL = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let payload = AppManagedSecretPayload(values: secrets)
            let data = try JSONEncoder().encode(payload)
            try data.write(to: fileURL, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: fileURL.path
            )
        } catch {
            assertionFailure("App managed secret save failed: \(error.localizedDescription)")
        }
    }

    /// 以前は起動時に app-managed JSON を Keychain へ移行して削除していた。
    /// ただし CLI で作成された Keychain item は macOS の確認ダイアログを繰り返し出すため、
    /// このローカル実験アプリでは JSON を正本として残す。関数は互換のため残すが呼ばない。
    private func migrateAppManagedSecretsToKeychainIfNeeded() {
        guard let fileURL = appManagedSecretsURL(),
              FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(AppManagedSecretPayload.self, from: data) else {
            return
        }

        var didMigrateAllValues = true
        for (rawKey, value) in payload.values {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { continue }
            // Keychain にまだ無いときだけ移行 (Keychain が真とみなす)
            if KeychainHelper.shared.getString(forKey: rawKey)?.isEmpty != false {
                let didStore = KeychainHelper.shared.setString(normalized, forKey: rawKey)
                if !didStore {
                    didMigrateAllValues = false
                }
            }
            if KeychainHelper.shared.getString(forKey: rawKey)?.isEmpty != false {
                didMigrateAllValues = false
            }
        }

        // Keychain への移行が確認できた場合だけ平文ファイルを削除する。
        // 失敗時に消すと API キーが失われるため、旧ファイルをフォールバックとして残す。
        if didMigrateAllValues {
            try? FileManager.default.removeItem(at: fileURL)
            cachedAppManagedSecrets = nil
        }
    }

    private func infoOrEnvironmentValue(infoKey: String, environmentKey: String) -> String? {
        if let value = Bundle.main.object(forInfoDictionaryKey: infoKey) as? String,
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value
        }

        let environmentValue = ProcessInfo.processInfo.environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return environmentValue?.isEmpty == false ? environmentValue : nil
    }

    private func uniqueNonEmptyValues(_ values: [String?]) -> [String] {
        var resolved: [String] = []
        for value in values {
            let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !normalized.isEmpty, !resolved.contains(normalized) else { continue }
            resolved.append(normalized)
        }
        return resolved
    }

    private func splitSecretList(_ value: String?) -> [String?] {
        guard let value else { return [] }
        return value.components(separatedBy: CharacterSet(charactersIn: "\n\r,;"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
