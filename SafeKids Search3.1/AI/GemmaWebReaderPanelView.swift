/*
仕様:
- 役割: Gemma 4 26B Web 読解 (OllamaWebSearchService.makeGemmaWebReaderContext) の
  実行状況を右パネルに表示する。読中の URL、完了したページの全文サマリー、失敗ステータス
  を実時間で見せる。
- 主な型: `GemmaWebReaderPanelView`.
- 編集ポイント: 読解中の見た目、サマリー全文の展開/折り畳み挙動を変えるときに触る。
*/

import SwiftUI

struct GemmaWebReaderPanelView: View {
    @ObservedObject private var service = OllamaWebSearchService.shared
    @State private var expandedIDs: Set<UUID> = []

    /// `lastStatusMessage` がレート制限を示している場合 true。
    /// バナー表示の判定に使う。
    private var isRateLimited: Bool {
        let status = service.lastStatusMessage
        return status.contains("レート制限") || status.contains("HTTP 429") || status.contains("使用上限")
    }

    private var livePages: [OllamaWebSearchService.GemmaReadingPage] {
        service.liveGemmaReadingPages.filter { $0.status == .reading || expandedIDs.contains($0.id) }
    }

    private var panelMaxHeight: CGFloat {
        expandedIDs.isEmpty ? 112 : 220
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if isRateLimited {
                rateLimitBanner
            }
            if service.liveGemmaReadingPages.isEmpty {
                diagnosticRow
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(livePages) { page in
                            row(for: page)
                        }
                    }
                }
                .frame(maxHeight: panelMaxHeight)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
    }

    /// レート制限時の目立つバナー。ユーザーが「いつまで使えないか」を判断できるように
    /// 状況メッセージをそのまま見せる。
    private var rateLimitBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "hourglass.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("API レート制限に到達中")
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundColor(.primary)
                Text(service.lastStatusMessage)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.orange.opacity(0.40), lineWidth: 1)
        )
    }

    /// gate のどれが原因で動かないかを見せる。
    /// (ユーザーが「いつ間にか機能しなくなった」を自己診断できる)
    private var diagnosticRow: some View {
        let reasons: [(String, Bool)] = [
            ("Web Search オン", service.isEnabled),
            ("Ollama Web Search API キー", service.hasAPIKey),
            ("AI ブラウジング (検索後本文取得) オン", service.webBrowsingEnabled),
            ("Gemma 4 26B 読解オン", service.gemmaWebReaderEnabled),
            ("Gemma Web 読解 API キー", service.hasGemmaWebReaderAPIKey),
            ("オンライン", NetworkStatusMonitor.shared.isOnline)
        ]
        let allOK = reasons.allSatisfy { $0.1 }
        return VStack(alignment: .leading, spacing: 4) {
            if allOK {
                Text("待機中。次の質問で検索後にトップページを 26B が読みます。")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            } else {
                Text("動作条件が揃っていません:")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.orange)
                ForEach(reasons, id: \.0) { item in
                    HStack(spacing: 5) {
                        Image(systemName: item.1 ? "checkmark.circle" : "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(item.1 ? .green : .orange)
                        Text(item.0)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(item.1 ? .secondary : .primary)
                    }
                }
            }
            // 直近の Ollama Web Search ステータス (HTTP エラーや空結果も含む)
            let status = service.lastStatusMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            if !status.isEmpty, status != "未設定" {
                Divider().opacity(0.15).padding(.vertical, 2)
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text(status)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text.viewfinder")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tint)
            Text("Gemma 4 26B Web 読解")
                .font(.system(size: 11.5, weight: .bold))
                .foregroundColor(.primary)
            Spacer(minLength: 0)
            Text("\(livePages.count) 件")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private func row(for page: OllamaWebSearchService.GemmaReadingPage) -> some View {
        let isExpanded = expandedIDs.contains(page.id)
        VStack(alignment: .leading, spacing: 4) {
            Button {
                guard page.summary?.isEmpty == false else { return }
                withAnimation(.easeInOut(duration: 0.15)) {
                    if isExpanded {
                        _ = expandedIDs.remove(page.id)
                    } else {
                        _ = expandedIDs.insert(page.id)
                    }
                }
            } label: {
                HStack(alignment: .center, spacing: 7) {
                    statusBadge(page.status)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(page.title.isEmpty ? page.domain : page.title)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(page.domain)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    if page.summary?.isEmpty == false {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(page.summary?.isEmpty != false)

            if isExpanded, let summary = page.summary, !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 11.5, weight: .regular))
                    .foregroundColor(.primary.opacity(0.86))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(0.04))
                    )
                if let url = URL(string: page.url),
                   let scheme = url.scheme?.lowercased(),
                   scheme == "http" || scheme == "https" {
                    Link(destination: url) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 10, weight: .semibold))
                            Text(page.url)
                                .font(.system(size: 10.5, weight: .medium))
                                .lineLimit(1)
                        }
                        .foregroundColor(.blue)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.02))
        )
    }

    @ViewBuilder
    private func statusBadge(_ status: OllamaWebSearchService.GemmaReadingPage.Status) -> some View {
        switch status {
        case .reading:
            ZStack {
                Circle()
                    .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
                    .frame(width: 14, height: 14)
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 5, height: 5)
                // 0.1s 間隔で十分滑らか (リング 1 周 = 1.3s → 13 frame で更新)。
                TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
                    let p = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.3) / 1.3
                    Circle()
                        .stroke(Color.accentColor.opacity(0.4 * (1 - p)), lineWidth: 1.2)
                        .frame(width: 14 + CGFloat(p) * 14, height: 14 + CGFloat(p) * 14)
                }
            }
            .frame(width: 14, height: 14)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.green)
                .frame(width: 14, height: 14)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.orange)
                .frame(width: 14, height: 14)
        }
    }
}
