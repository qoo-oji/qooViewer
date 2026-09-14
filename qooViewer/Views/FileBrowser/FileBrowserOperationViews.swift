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

    /// Finder の「“名前”はロックされています。ゴミ箱に入れますか?」に当たる確認。既定のボタンは「中止」
    /// (ロックは「うっかり消さない」ための印なので、Return で越えさせない)。
    /// 一部だけがロックされているときは「ロックされた項目をスキップ」も出す(2026-09-14。以前は「続ける / 中止」の 2 択で、
    /// ロックされていない項目だけを送る手が無かった ―― 計画 §4.11)。
    func confirmLockedItems(_ urls: [URL], totalCount: Int, action: LockedItemAction) async -> LockedItemsDecision {
        let alert = NSAlert()
        alert.alertStyle = .warning
        let single = urls.count == 1
        let name = urls.first?.lastPathComponent ?? ""
        let information: String
        // 文言は 1 つずつ String(localized:) に書く(String Catalog が文字列リテラルから拾えるように)。
        switch action {
        case .trash:
            alert.messageText = single
                ? String(format: String(localized: "“%@” is locked. Do you want to move it to the Trash anyway?", language: locale), name)
                : String(format: String(localized: "%lld items are locked. Do you want to move them to the Trash anyway?", language: locale), urls.count)
            information = String(localized: "Locked items stay locked in the Trash.", language: locale)
        case .deleteImmediately:
            alert.messageText = single
                ? String(format: String(localized: "“%@” is locked. Do you want to delete it anyway?", language: locale), name)
                : String(format: String(localized: "%lld items are locked. Do you want to delete them anyway?", language: locale), urls.count)
            information = String(localized: "Locked items, or folders that contain locked items, are unlocked and then deleted.", language: locale)
        case .move:
            alert.messageText = single
                ? String(format: String(localized: "“%@” is locked. Do you want to move it anyway?", language: locale), name)
                : String(format: String(localized: "%lld items are locked. Do you want to move them anyway?", language: locale), urls.count)
            information = String(localized: "Locked items are unlocked while they’re moved and locked again at the new location.", language: locale)
        case .rename:
            // 複数は一括リネーム(段階 5)。
            alert.messageText = single
                ? String(format: String(localized: "“%@” is locked. Do you want to rename it anyway?", language: locale), name)
                : String(format: String(localized: "%lld items are locked. Do you want to rename them anyway?", language: locale), urls.count)
            information = single
                ? String(localized: "The item is unlocked while it’s renamed and locked again afterward.", language: locale)
                : String(localized: "Locked items are unlocked while they’re renamed and locked again afterward.", language: locale)
        case let .replace(deletesImmediately):
            alert.messageText = String(format: String(localized: "“%@” is locked. Do you want to replace it anyway?", language: locale), name)
            information = deletesImmediately
                ? String(localized: "Locked items, or folders that contain locked items, are unlocked and then deleted.", language: locale)
                : String(localized: "Locked items stay locked in the Trash.", language: locale)
        }
        alert.informativeText = information
        let proceed = alert.addButton(withTitle: String(localized: "Continue", language: locale))
        let offersSkip = urls.count < totalCount
        if offersSkip {
            alert.addButton(withTitle: String(localized: "Skip Locked Items", language: locale))
        }
        let stop = alert.addButton(withTitle: String(localized: "Stop", language: locale))
        proceed.keyEquivalent = ""
        stop.keyEquivalent = "\r"
        switch await run(alert) {
        case .alertFirstButtonReturn: return .proceed
        case .alertSecondButtonReturn where offersSkip: return .skipLocked
        default: return .stop
        }
    }

    /// 元のフォルダへ書けない項目の移動(Finder などでコピーした項目の ⌥⌘V、外からのドロップ)。
    /// 並びは「移動(既定)/ コピー / 中止」。既定を「移動」にしたのは、利用者が明示的に移動を選んだうえ、
    /// 移動は何も失わない(戻せないのは qooViewer の ⌘Z だけで、Finder でなら戻せる)から。
    func confirmIrreversibleMove(of urls: [URL], totalCount: Int) async -> IrreversibleMoveDecision {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = totalCount == 1
            ? String(format: String(localized: "Moving “%@” can’t be undone.", language: locale), urls[0].lastPathComponent)
            : String(format: String(localized: "Moving these %lld items can’t be undone.", language: locale), totalCount)
        alert.informativeText = urls.count == totalCount
            ? String(
                localized: "qooViewer doesn’t have permission to write to the original folder, so the items can’t be put back. If you copy them instead, the originals stay where they are.",
                language: locale
            )
            : String(
                format: String(
                    localized: "qooViewer doesn’t have permission to write to the original folder of %lld of these items, so they can’t be put back. If you choose Copy, only those items are copied and the rest are moved.",
                    language: locale
                ),
                urls.count
            )
        alert.addButton(withTitle: String(localized: "Move", language: locale))
        alert.addButton(withTitle: String(localized: "Copy", language: locale))
        alert.addButton(withTitle: String(localized: "Stop", language: locale))
        switch await run(alert) {
        case .alertFirstButtonReturn: return .move
        case .alertSecondButtonReturn: return .copy
        default: return .stop
        }
    }

    /// 並びは「両方を残す(既定)/ 置き換える / スキップ / 中止」。Finder の既定は「置き換える」だが、
    /// Return 1 回で既存の項目がゴミ箱へ行かないよう、それまでと同じ「両方を残す」を既定のままにした。
    func resolveConflict(_ conflict: FileConflict, replacingDeletesImmediately: Bool, cancellation: Cancellation) async -> ConflictDecision {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            format: String(localized: "An item named “%@” already exists in this location.", language: locale),
            conflict.destination.lastPathComponent
        )
        var information = String(
            localized: "Do you want to replace it, keep both items, or skip this item?", language: locale
        )
        if replacingDeletesImmediately {
            information += "\n\n" + String(
                localized: "This location doesn’t have a Trash, so if you replace the item, it will be deleted immediately. You can’t undo this action.",
                language: locale
            )
        }
        alert.informativeText = information
        alert.addButton(withTitle: String(localized: "Keep Both", language: locale))
        let replace = alert.addButton(withTitle: String(localized: "Replace", language: locale))
        replace.hasDestructiveAction = replacingDeletesImmediately
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
            return ConflictDecision(.replace, applyToRemaining: applyToAll)
        case .alertThirdButtonReturn:
            return ConflictDecision(.skip, applyToRemaining: applyToAll)
        default:
            // 中止: 残りを止める。この項目はスキップとして返す(エンジンは次の区切りで止まる)。
            cancellation.request()
            return ConflictDecision(.skip)
        }
    }

    func requestBulkRename(_ request: BulkRenameRequest) async -> BulkRenameSettings? {
        await BulkRenamePanel.run(request, on: appState?.hostWindow, locale: locale)
    }

    /// 「保存先を選んで圧縮…」「展開先を選んで展開…」。**NSOpenPanel で選ばせる**(NSSavePanel ではない): 保存パネルで選んだ場所には
    /// そのファイル 1 つぶんの許可しか付かず、同じフォルダに一時ファイルを書いてから置く形(ZipCompressor)が取れない。
    /// フォルダを選べばその中へ書く許可が付き、名前は「ここに圧縮」と同じ規則で決まる(塞がっていれば `name 2`)。
    func chooseDestinationFolder(for purpose: ArchiveDestinationPurpose, startingAt folder: URL) async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        switch purpose {
        case let .compress(count):
            panel.prompt = String(localized: "Compress", language: locale)
            panel.message = count == 1
                ? String(localized: "Choose where to save the compressed item.", language: locale)
                : String(format: String(localized: "Choose where to save the %lld compressed items.", language: locale), count)
        case let .extract(count):
            panel.prompt = String(localized: "Extract", language: locale)
            panel.message = count == 1
                ? String(localized: "Choose where to extract the archive.", language: locale)
                : String(format: String(localized: "Choose where to extract the %lld archives.", language: locale), count)
        }
        let response: NSApplication.ModalResponse
        if let window = appState?.hostWindow, window.attachedSheet == nil, window.isVisible {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = panel.runModal()
        }
        return response == .OK ? panel.url : nil
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
