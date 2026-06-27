/*
仕様:
- 役割: 検索 planner / Deep Research 用 Gemma 3 軽量補助モデルの保存、削除、状態表示を管理する。
- 主な型: `LocalSupportModelManager`.
- 編集ポイント: DL 導線、保存場所、runtime 確認の文言を変える時に触る。
*/
import Foundation
import Combine

final class LocalSupportModelManager: NSObject, ObservableObject {
    static let shared = LocalSupportModelManager()

    @Published var sourceURLString: String
    @Published var accessToken: String
    @Published private(set) var statusMessage: String = "未導入"
    @Published private(set) var downloadedBytes: Int64 = 0
    @Published private(set) var expectedBytes: Int64 = 0
    @Published private(set) var transferRateBytesPerSecond: Double?
    @Published private(set) var estimatedRemainingSeconds: TimeInterval?
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var installedFileName: String?
    @Published private(set) var installedFileSize: Int64 = 0
    @Published private(set) var isDownloading: Bool = false
    @Published private(set) var runtimeAvailabilitySnapshot: LocalAssistantRuntimeAvailability = .modelMissing

    private let defaults = UserDefaults.standard
    private let sourceURLKey = "localSupportModelSourceURL"
    private let installedFileNameKey = "localSupportInstalledFileName"
    private let secretStore = AISecretStore.shared

    private var resolvedInstalledModelURL: URL?
    private var downloadSession: URLSession?
    private var downloadTask: URLSessionDownloadTask?
    private var progressSamples: [(time: TimeInterval, bytes: Int64)] = []
    private var didAttemptAutomaticDownloadThisLaunch = false

    private override init() {
        let persistedSourceURL = UserDefaults.standard.string(forKey: "localSupportModelSourceURL")
        self.sourceURLString = Self.normalizedSourceURL(persistedSourceURL)
        self.accessToken = secretStore.string(for: .localSupportModelAccessToken) ?? ""
        super.init()
        if Self.shouldReplacePersistedSourceURL(persistedSourceURL) {
            defaults.set(sourceURLString, forKey: sourceURLKey)
        } else if defaults.string(forKey: sourceURLKey) == nil {
            defaults.set(sourceURLString, forKey: sourceURLKey)
        }
        refreshEnvironment()
        scheduleStartupSelfCheck()
    }

    var installationDirectoryURL: URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return baseURL
            .appendingPathComponent(AppBrand.displayName, isDirectory: true)
            .appendingPathComponent("LocalModels", isDirectory: true)
            .appendingPathComponent(LocalSupportModelProfile.storageFolderName, isDirectory: true)
    }

    var installedModelURL: URL? {
        resolvedInstalledModelURL
    }

    var resolvedSourceURLString: String {
        Self.normalizedSourceURL(sourceURLString)
    }

    var sourceDisplayLabel: String {
        resolvedSourceURLString == LocalSupportModelProfile.defaultDownloadURL
            ? LocalSupportModelProfile.defaultDownloadLabel
            : "カスタムURL"
    }

    var sourceHostLabel: String {
        URL(string: resolvedSourceURLString)?.host ?? "標準ソース"
    }

    var progressValue: Double? {
        guard expectedBytes > 0 else { return nil }
        return min(max(Double(downloadedBytes) / Double(expectedBytes), 0), 1)
    }

    var transferRateSummary: String? {
        guard let transferRateBytesPerSecond, transferRateBytesPerSecond > 0 else { return nil }
        return "\(ByteCountFormatter.string(fromByteCount: Int64(transferRateBytesPerSecond), countStyle: .file))/秒"
    }

    var estimatedRemainingSummary: String? {
        guard let estimatedRemainingSeconds, estimatedRemainingSeconds > 0, estimatedRemainingSeconds.isFinite else {
            return nil
        }

        let rounded = Int(estimatedRemainingSeconds.rounded(.up))
        if rounded < 60 {
            return "残り約\(max(1, rounded))秒"
        }
        let minutes = Int((Double(rounded) / 60).rounded(.up))
        if minutes < 60 {
            return "残り約\(minutes)分"
        }
        let hours = minutes / 60
        let restMinutes = minutes % 60
        return restMinutes == 0 ? "残り約\(hours)時間" : "残り約\(hours)時間\(restMinutes)分"
    }

    var runtimeAvailability: LocalAssistantRuntimeAvailability {
        runtimeAvailabilitySnapshot
    }

    var statusTitle: String {
        if isDownloading {
            return "ダウンロード中"
        }

        switch runtimeAvailability {
        case .executable:
            return "実行可能"
        case .recentFailure:
            return "直近失敗"
        case .savedOnly:
            return "保存のみ"
        case .modelMissing:
            return "未導入"
        }
    }

    var runnerStatusLabel: String {
        switch runtimeAvailability {
        case .executable:
            return "サブエージェント実行可"
        case .recentFailure:
            return "直近失敗"
        case .savedOnly:
            return "未確認"
        case .modelMissing:
            return "未導入"
        }
    }

    var downloadStateSummary: String {
        if isDownloading {
            if let progressValue {
                return "\(LocalSupportModelProfile.modelName) 補助モデルを受信中 \(Int(progressValue * 100))%"
            }
            return "\(LocalSupportModelProfile.modelName) 補助モデルを受信しています。"
        }

        if let lastErrorMessage, !lastErrorMessage.isEmpty {
            return lastErrorMessage
        }

        if installedModelURL != nil {
            return "検索 planner / Deep Research の補助サブエージェントとして使えます。"
        }

        return "Gemma 4 とは別スロットで、\(LocalSupportModelProfile.modelName) を保存できます。"
    }

    var runtimeStatusSummary: String {
        switch runtimeAvailability {
        case .executable:
            return "\(LocalSupportModelProfile.modelName) 補助モデルを検索 planner / Deep Research のサブエージェントで使えます。"
        case .recentFailure:
            return LocalSubagentRuntimePool.shared.lastRuntimeErrorMessage ?? "サブエージェントの起動に失敗しました。必要なら再確認してください。"
        case .savedOnly:
            return "モデルは保存済みですが、サブエージェントの動作確認はまだです。"
        case .modelMissing:
            return "\(LocalSupportModelProfile.modelName) 補助モデルは未導入です。"
        }
    }

    func updateSourceURL(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        sourceURLString = Self.normalizedSourceURL(trimmed)
        defaults.set(sourceURLString, forKey: sourceURLKey)
    }

    func updateAccessToken(_ value: String) {
        accessToken = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if accessToken.isEmpty {
            secretStore.removeValue(for: .localSupportModelAccessToken)
        } else {
            secretStore.setString(accessToken, for: .localSupportModelAccessToken)
        }
    }

    func resetSourceURLToDefault() {
        sourceURLString = LocalSupportModelProfile.defaultDownloadURL
        defaults.set(sourceURLString, forKey: sourceURLKey)
    }

    func refreshEnvironment() {
        refreshInstalledState()
        refreshRuntimeAvailability()
        applyStatusPresentation()
    }

    func recheckRuntimeAvailability() {
        guard let installedModelURL else {
            refreshEnvironment()
            return
        }

        statusMessage = "Gemma 3 サブエージェントの実行を確認しています"
        Task { [weak self] in
            guard let self else { return }
            _ = await LocalSubagentRuntimePool.shared.performSelfCheck(installedModelURL: installedModelURL)
            await MainActor.run {
                self.refreshEnvironment()
            }
        }
    }

    func startDownload() {
        guard !isDownloading else { return }
        guard let url = URL(string: resolvedSourceURLString),
              let scheme = url.scheme?.lowercased(),
              ["https", "http"].contains(scheme) else {
            applyFailure("\(LocalSupportModelProfile.modelName) 補助モデルの URL を解決できません。")
            return
        }

        do {
            try FileManager.default.createDirectory(at: installationDirectoryURL, withIntermediateDirectories: true, attributes: nil)
        } catch {
            applyFailure("保存先フォルダを作成できませんでした。")
            return
        }

        isDownloading = true
        downloadedBytes = 0
        expectedBytes = 0
        transferRateBytesPerSecond = nil
        estimatedRemainingSeconds = nil
        lastErrorMessage = nil
        progressSamples = []
        statusMessage = "\(LocalSupportModelProfile.modelName) 補助モデルをダウンロードしています"

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 60 * 60
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        downloadSession = session

        var request = URLRequest(url: url)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        if shouldAttachAuthorization(to: url), !accessToken.isEmpty {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }

        let task = session.downloadTask(with: request)
        downloadTask = task
        task.resume()
    }

    @discardableResult
    func startAutomaticDownloadIfNeeded() -> Bool {
        guard installedModelURL == nil else { return false }
        guard !isDownloading else { return false }
        guard didAttemptAutomaticDownloadThisLaunch == false else { return false }

        didAttemptAutomaticDownloadThisLaunch = true
        statusMessage = "検索 planner / Deep Research 用の \(LocalSupportModelProfile.modelName) 補助モデルを自動導入しています"
        startDownload()
        return isDownloading
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        downloadSession?.invalidateAndCancel()
        downloadSession = nil
        isDownloading = false
        applyStatusPresentation()
    }

    func removeInstalledModel() {
        cancelDownload()
        if let installedModelURL, FileManager.default.fileExists(atPath: installedModelURL.path) {
            try? FileManager.default.removeItem(at: installedModelURL)
        }
        resolvedInstalledModelURL = nil
        installedFileName = nil
        installedFileSize = 0
        lastErrorMessage = nil
        downloadedBytes = 0
        expectedBytes = 0
        transferRateBytesPerSecond = nil
        estimatedRemainingSeconds = nil
        refreshEnvironment()
        statusMessage = "\(LocalSupportModelProfile.modelName) 補助モデルを削除しました"
    }

    private func refreshInstalledState() {
        let rememberedFileName = defaults.string(forKey: installedFileNameKey)
        let directoryURL = installationDirectoryURL
        let fileManager = FileManager.default

        let candidateURLs: [URL]
        if let rememberedFileName {
            candidateURLs = [directoryURL.appendingPathComponent(rememberedFileName)]
        } else if let urls = try? fileManager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) {
            candidateURLs = urls
        } else {
            candidateURLs = []
        }

        let resolvedURL = candidateURLs.first { url in
            guard Self.isAcceptedModelFileExtension(url.pathExtension.lowercased()) else { return false }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            return size >= LocalSupportModelProfile.minimumAcceptedModelSizeBytes
        }

        resolvedInstalledModelURL = resolvedURL
        installedFileName = resolvedURL?.lastPathComponent
        installedFileSize = resolvedURL.flatMap {
            (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        } ?? 0

        if let installedFileName {
            defaults.set(installedFileName, forKey: installedFileNameKey)
        } else {
            defaults.removeObject(forKey: installedFileNameKey)
        }
    }

    private func refreshRuntimeAvailability() {
        runtimeAvailabilitySnapshot = LocalSubagentRuntimePool.shared.availability(installedModelURL: installedModelURL)
    }

    private func scheduleStartupSelfCheck() {
        guard let url = installedModelURL else { return }
        guard LocalSubagentRuntimePool.shared.isBundledRunnerAvailable else { return }
        Task { [weak self] in
            guard let self else { return }
            _ = await LocalSubagentRuntimePool.shared.performSelfCheck(installedModelURL: url)
            await MainActor.run {
                self.refreshEnvironment()
            }
        }
    }

    private func applyStatusPresentation() {
        if isDownloading {
            return
        }

        switch runtimeAvailability {
        case .executable:
            statusMessage = "Gemma 3 補助サブエージェントをこの端末で使えます"
        case .recentFailure:
            statusMessage = LocalSubagentRuntimePool.shared.lastRuntimeErrorMessage ?? "サブエージェントの起動に失敗しました"
        case .savedOnly:
            statusMessage = "\(LocalSupportModelProfile.modelName) 補助モデルは保存済みです"
        case .modelMissing:
            statusMessage = "\(LocalSupportModelProfile.modelName) 補助モデルは未導入です"
        }
    }

    private func applyFailure(_ message: String) {
        isDownloading = false
        lastErrorMessage = message
        statusMessage = message
        transferRateBytesPerSecond = nil
        estimatedRemainingSeconds = nil
    }

    private static func normalizedSourceURL(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return LocalSupportModelProfile.defaultDownloadURL }
        if shouldReplacePersistedSourceURL(trimmed) {
            return LocalSupportModelProfile.defaultDownloadURL
        }
        return trimmed
    }

    private static func shouldReplacePersistedSourceURL(_ value: String?) -> Bool {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard !trimmed.isEmpty else { return false }
        if trimmed.contains("gemma-3n-e4b")
            || trimmed.contains("gemma3minisupporte4b4bit")
            || trimmed.contains("gemma-3n") {
            return true
        }
#if os(iOS)
        return trimmed.hasSuffix(".gguf") ||
            trimmed.contains(".gguf?") ||
            trimmed.contains("unsloth/gemma-3-270m-it-gguf")
#else
        return trimmed.hasSuffix(".litertlm") ||
            trimmed.contains(".litertlm?") ||
            trimmed.contains("litert-community/gemma-3-270m-it")
#endif
    }

    private static func isAcceptedModelFileExtension(_ pathExtension: String) -> Bool {
#if os(iOS)
        return pathExtension == "litertlm"
#else
        return pathExtension == "gguf"
#endif
    }

    private func shouldAttachAuthorization(to url: URL) -> Bool {
        guard !accessToken.isEmpty else { return false }
        let host = url.host?.lowercased() ?? ""
        return host.contains("huggingface.co")
    }
}

extension LocalSupportModelManager: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        DispatchQueue.main.async {
            self.downloadedBytes = totalBytesWritten
            self.expectedBytes = max(totalBytesExpectedToWrite, self.expectedBytes)
            let now = Date().timeIntervalSinceReferenceDate
            self.progressSamples.append((time: now, bytes: totalBytesWritten))
            self.progressSamples = self.progressSamples.suffix(5)
            if let first = self.progressSamples.first, let last = self.progressSamples.last, last.time > first.time, last.bytes > first.bytes {
                let bytesDelta = Double(last.bytes - first.bytes)
                let timeDelta = last.time - first.time
                let rate = bytesDelta / timeDelta
                self.transferRateBytesPerSecond = rate
                if rate > 0, totalBytesExpectedToWrite > 0 {
                    self.estimatedRemainingSeconds = Double(totalBytesExpectedToWrite - totalBytesWritten) / rate
                }
            }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let sourceURL = URL(string: resolvedSourceURLString)
        let candidateFileName = sourceURL?.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileName = (candidateFileName?.isEmpty == false ? candidateFileName : nil) ?? LocalSupportModelProfile.defaultFileName
        let destinationURL = installationDirectoryURL.appendingPathComponent(fileName)

        do {
            try FileManager.default.createDirectory(at: installationDirectoryURL, withIntermediateDirectories: true, attributes: nil)
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.moveItem(at: location, to: destinationURL)

            DispatchQueue.main.async {
                self.isDownloading = false
                self.downloadTask = nil
                self.downloadSession?.finishTasksAndInvalidate()
                self.downloadSession = nil
                self.lastErrorMessage = nil
                self.refreshEnvironment()
                self.statusMessage = "\(LocalSupportModelProfile.modelName) 補助モデルを保存しました"
            }
        } catch {
            DispatchQueue.main.async {
                self.applyFailure("\(LocalSupportModelProfile.modelName) 補助モデルの保存に失敗しました。")
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        DispatchQueue.main.async {
            if (error as NSError).code == NSURLErrorCancelled {
                self.isDownloading = false
                self.statusMessage = "\(LocalSupportModelProfile.modelName) 補助モデルのダウンロードを停止しました"
                return
            }
            self.applyFailure("\(LocalSupportModelProfile.modelName) 補助モデルのダウンロードに失敗しました。")
        }
    }
}
