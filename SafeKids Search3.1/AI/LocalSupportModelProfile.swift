/*
仕様:
- 役割: 検索 planner / Deep Research の補助サブエージェント用ローカルモデル設定をまとめる。
- 主な型: `LocalSupportModelProfile`.
- 編集ポイント: Gemma 3 軽量モデルの保存先、DL URL、runtime 既定値を変える時に触る。
*/
import Foundation

enum LocalSupportModelProfile {
    struct RuntimePreset {
        let contextSize: Int
        let batchSize: Int
        let microBatchSize: Int
        let threadCount: Int
        let batchThreadCount: Int
        let gpuLayers: Int
        let flashAttentionEnabled: Bool
        let disableKVOffload: Bool
    }

    // Gemma 3 270M (公式 Google モデル) に切り替え
    // 旧: Gemma 3n E4B 4bit (~2.5GB) → 新: Gemma 3 270M Q4_K_M (~200MB)
    // 270M は sub-agent 専任として planner / auditor / architect を高速に処理する
    static let modelName = "Gemma 3 270M"
    #if os(iOS)
    static let internalModelName = "Gemma 3 270M q8 LiteRT-LM"
    #else
    static let internalModelName = "Gemma 3 270M UD-Q4_K_XL"
    #endif
    static let capabilitySummary = "超軽量 / 下調べ専任 / planner・auditor・architect 用"
    static let defaultDownloadLabel = "\(internalModelName) 標準リンク"
    #if os(iOS)
    static let defaultDownloadURL = "https://huggingface.co/litert-community/gemma-3-270m-it/resolve/main/gemma3-270m-it-q8.litertlm?download=true"
    static let defaultFileName = "gemma3-270m-it-q8.litertlm"
    static let storageFolderName = "Gemma3Support270MLiteRTLM"
    static let minimumAcceptedModelSizeBytes: Int64 = 200 * 1024 * 1024
    #else
    static let defaultDownloadURL = "https://huggingface.co/unsloth/gemma-3-270m-it-GGUF/resolve/main/gemma-3-270m-it-UD-Q4_K_XL.gguf?download=true"
    static let defaultFileName = "gemma-3-270m-it-UD-Q4_K_XL.gguf"
    static let storageFolderName = "Gemma3Support270M"
    static let minimumAcceptedModelSizeBytes: Int64 = 50 * 1024 * 1024
    #endif
    // 旧モデルを使っていたユーザーがいた場合に既存フォルダを legacy 扱いにする
    static let legacyStorageFolderNames = ["Gemma3MiniSupportE4B4bit"]

    private static let physicalMemoryBytes = ProcessInfo.processInfo.physicalMemory

    // 270M は CPU 専用で動かす。理由:
    // - サンドボックス内サブプロセスで Metal を初期化すると失敗するケースがある
    // - メイン Gemma 4 と GPU を奪い合い WKWebView が不安定になる
    // - ~200MB の超軽量モデルなので CPU でも十分高速（Apple Silicon で 40〜80 tok/s）
    // - Metal shader 初回コンパイル（~10s）を完全に回避でき、コールドスタートが速い

    static let runtimePreset = RuntimePreset(
        // evidenceSections（検索結果 + Gemma ノート）が含まれると 1024 では不足するため 2048 に拡張
        // 270M Q4_K_M の KV キャッシュは 2048 tokens でも ~30MB 未満 (GQA 4 heads) で収まる
        contextSize: 2048,
        batchSize: 128,
        microBatchSize: 32,
        threadCount: min(max(ProcessInfo.processInfo.activeProcessorCount - 1, 2), 6),
        batchThreadCount: min(max(ProcessInfo.processInfo.activeProcessorCount / 4, 1), 2),
        gpuLayers: 0,
        flashAttentionEnabled: false,
        disableKVOffload: false
    )

    // 270M は速いので maxTokens は控えめに（sub-agent 出力は短い箇条書き）
    static let generationMaxTokens = 320
    static let generationTemperature: Float = 0.20
    static let generationTopP: Float = 0.84
    static let generationTopK = 32
    static let generationSeed: UInt32 = 41
    // self-check タイムアウト: 初回ロード（ディスク I/O 込み）を考慮して 45s に拡張
    // 270M は軽量なので通常 5〜10s で応答するが、低速ストレージ / 初回コールドスタート対策
    static let timeoutSeconds = 45
}
