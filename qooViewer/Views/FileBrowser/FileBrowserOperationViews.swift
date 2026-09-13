import AppKit
import SwiftUI

/// 書く操作の確認と報告を、ウインドウのシートで見せる(改善要望7 段階4、2026-09-13)。
///
/// **相手のウインドウは weak で引く**(AppState.hostWindow)。シートの完了を待つ閉包がウインドウより
/// 長生きしても、閉じたウインドウを掴まない(CLAUDE.md のリークの件)。ウインドウが無い・既にシートが
/// 出ているときはモーダルで出す(シートを重ねると後のものが出ずに待ち続ける)。
@MainActor
final class FileBrowserSheetPresenter: FileBrowserOperationPresenting {
    weak var appState: AppState?

    init(appState: AppState?) {
        self.appState = appState
    }

    private var locale: Locale { AppLanguage.currentLocale }

    func confirmImmediateDeletion(of urls: [URL]) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = urls.count == 1
            ? String(format: String(localized: "Are you sure you want to delete “%@”?", language: locale), urls[0].lastPathComponent)
            : String(format: String(localized: "Are you sure you want to delete these %lld items?", language: locale), urls.count)
        alert.informativeText = String(
            localized: "This item is on a volume without a Trash, so it will be deleted immediately. You can’t undo this action.",
            language: locale
        )
        let delete = alert.addButton(withTitle: String(localized: "Delete", language: locale))
        delete.hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "Cancel", language: locale))
        // 取り返しがつかないので、Return で消えないよう既定のボタンを「キャンセル」にする。
        delete.keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"
        return await run(alert) == .alertFirstButtonReturn
    }

    func resolveConflict(_ conflict: FileConflict, cancellation: Cancellation) async -> ConflictDecision {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            format: String(localized: "An item named “%@” already exists in this location.", language: locale),
            conflict.destination.lastPathComponent
        )
        alert.informativeText = String(
            localized: "Do you want to keep both items, or skip this item?", language: locale
        )
        alert.addButton(withTitle: String(localized: "Keep Both", language: locale))
        alert.addButton(withTitle: String(localized: "Skip", language: locale))
        alert.addButton(withTitle: String(localized: "Stop", language: locale))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "Apply to All", language: locale)
        let response = await run(alert)
        let applyToAll = alert.suppressionButton?.state == .on
        switch response {
        case .alertFirstButtonReturn:
            return ConflictDecision(.keepBoth, applyToRemaining: applyToAll)
        case .alertSecondButtonReturn:
            return ConflictDecision(.skip, applyToRemaining: applyToAll)
        default:
            // 中止: 残りを止める。この項目はスキップとして返す(エンジンは次の区切りで止まる)。
            cancellation.request()
            return ConflictDecision(.skip)
        }
    }

    func showProblem(_ problem: FileBrowserProblem) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = problem.title
        alert.informativeText = problem.message
        alert.addButton(withTitle: String(localized: "OK", language: locale))
        Task { _ = await run(alert) }
    }

    private func run(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        if let window = appState?.hostWindow, window.attachedSheet == nil, window.isVisible {
            return await alert.beginSheetModal(for: window)
        }
        return alert.runModal()
    }
}

/// 進捗の帯(決定事項 Q10。右ペインの下、パスバーの上)。
/// 「12 件中 3 件目 — 1.49 GB / 4.29 GB — 残り約 2 分」+ 中止。
///
/// 地は`controlBackgroundColor`(パスバーと同じ不透明な帯)なので、すりガラス面の輪郭は掛けない。
struct FileBrowserProgressBar: View {
    @ObservedObject var operations: FileBrowserOperations
    @Environment(\.locale) private var locale

    var body: some View {
        if let activity = operations.activity {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(activity.title)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let fraction = activity.progress.fraction {
                            ProgressView(value: fraction)
                                .progressViewStyle(.linear)
                        } else {
                            ProgressView()
                                .progressViewStyle(.linear)
                        }
                        // 残り時間は 1 秒ごとに見積もり直す。
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(detail(for: activity, now: context.date))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .monospacedDigit()
                        }
                    }
                    if activity.isCancellable {
                        Button {
                            operations.cancelActivity()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Stop")
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .background(Color(nsColor: .controlBackgroundColor))
        }
    }

    private func detail(for activity: FileBrowserActivity, now: Date) -> String {
        let progress = activity.progress
        var parts: [String] = []
        if progress.totalItems > 0 {
            parts.append(String(
                format: String(localized: "%1$lld of %2$lld", language: locale),
                min(progress.completedItems + 1, progress.totalItems), progress.totalItems
            ))
        }
        if progress.totalBytes > 0 {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            parts.append("\(formatter.string(fromByteCount: progress.completedBytes)) / \(formatter.string(fromByteCount: progress.totalBytes))")
        }
        if let remaining = activity.estimatedSecondsRemaining(now: now) {
            let formatter = DateComponentsFormatter()
            formatter.unitsStyle = .full
            formatter.maximumUnitCount = 1
            formatter.allowedUnits = remaining >= 3600 ? [.hour, .minute] : remaining >= 60 ? [.minute] : [.second]
            var calendar = Calendar.current
            calendar.locale = locale
            formatter.calendar = calendar
            if let text = formatter.string(from: max(1, remaining)) {
                parts.append(String(format: String(localized: "About %@ remaining", language: locale), text))
            }
        }
        return parts.joined(separator: " — ")
    }
}
