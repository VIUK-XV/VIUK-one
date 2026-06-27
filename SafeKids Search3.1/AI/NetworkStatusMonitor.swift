/*
仕様:
- 役割: 端末のオンライン/オフライン状態を監視し、AI機能のオンライン補助判定に使う。
- 主な型: `NetworkStatusMonitor`.
- 編集ポイント: 接続判定ルール、表示文言、使用するインターフェース種別を変えるときに触る。
*/
import Combine
import Foundation
import Network

final class NetworkStatusMonitor: ObservableObject {
    static let shared = NetworkStatusMonitor()

    // デフォルトをオンライン扱いにする (sandbox / Network framework のコールバックが
    // 起動初期に遅延・欠落するケースで、検索系の gate が永久に閉じてしまう問題を回避)。
    // 本当にオフラインの場合は URLSession が即時 -1009 等で失敗するため、上層の
    // エラー処理に任せる方が確実。
    @Published private(set) var isOnline: Bool = true
    @Published private(set) var statusSummary: String = "オンライン"
    @Published private(set) var interfaceLabel: String = "ネット接続"

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "viuk.one.network-status")

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.apply(path)
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }

    private func apply(_ path: NWPath) {
        isOnline = path.status == .satisfied

        if path.usesInterfaceType(.wifi) {
            interfaceLabel = "Wi-Fi"
        } else if path.usesInterfaceType(.wiredEthernet) {
            interfaceLabel = "Ethernet"
        } else if path.usesInterfaceType(.cellular) {
            interfaceLabel = "Cellular"
        } else {
            interfaceLabel = isOnline ? "ネット接続" : "未接続"
        }

        statusSummary = isOnline ? "オンライン (\(interfaceLabel))" : "オフライン"
    }
}
