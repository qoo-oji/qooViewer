import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 書く操作の確認と報告(改善要望7 段階4、2026-09-13。2026-10-24 に Finder の形へ揃えた)。
///
/// ■ 何をどこへ出すか(Finder の実測に合わせた ―― docs/15「操作の問い合わせ」)
/// - 操作の途中の問い合わせと、操作の結果の報告 → `FileOperationPromptCenter` の行(Finder の「コピー」「ゴミ箱」ウインドウの行と同じ形)。
///   同じ名前の項目・ロックされた項目・取り消せない移動・名前が長すぎる項目・空き不足や失敗の報告。
/// - 始める前に断る理由と「すぐに削除」の確認 → ウインドウのシートの NSAlert(Finder もこの 2 つはアラートで出す。それ自身への
///   ペースト・すぐに削除の確認を実測)。
/// 文面は、Finder と同じ働きのものは Finder の文(DesktopServicesPriv の Localizable)をそのまま使う。
///
/// **相手のウインドウは weak で引く**(AppState.hostWindow)。答えを待つ閉包がウインドウより長生きしても、閉じたウインドウを
/// 掴まない(CLAUDE.md のリークの件)。行は持ち主のウインドウが閉じたら「中止」で答えて消える(`FileOperationPrompt.answerWhenOwnerCloses`)。
@MainActor
final class FileBrowserSheetPresenter: FileBrowserOperationPresenting {
    weak var appState: AppState?
    private let prompts: FileOperationPromptCenter

    /// - Parameter prompts: 行を出す相手(nil ならアプリに 1 つの `FileOperationPromptCenter.shared`)。
    init(appState: AppState?, prompts: FileOperationPromptCenter? = nil) {
        self.appState = appState
        self.prompts = prompts ?? .shared
    }

    private var locale: Locale { AppLanguage.currentLocale }

    /// Finder の「すぐに削除」の確認と同じ文と並び(左「キャンセル」、右の赤い「削除」)。**既定のボタンは無い**: Finder も
    /// どちらも青くせず、Return では何も起きない。Esc は「キャンセル」(実測)。ゴミ箱の無い場所(SMB)でも Finder は同じ文を出す
    /// (以前は「ゴミ箱の無いボリュームにあるため…」と理由を変えていた)。
    func confirmImmediateDeletion(of urls: [URL], reason: ImmediateDeletionReason) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = urls.count == 1
            ? String(format: String(localized: "Are you sure you want to delete “%@”?", language: locale), urls[0].lastPathComponent)
            : String(format: String(localized: "Are you sure you want to delete the %lld selected items?", language: locale), urls.count)
        alert.informativeText = urls.count == 1
            ? String(localized: "This item will be deleted immediately. You can’t undo this action.", language: locale)
            : String(format: String(localized: "%lld items will be deleted immediately. You can’t undo this action.", language: locale), urls.count)
        let delete = alert.addButton(withTitle: String(localized: "Delete", language: locale))
        delete.hasDestructiveAction = true
        delete.keyEquivalent = ""
        let cancel = alert.addButton(withTitle: String(localized: "Cancel", language: locale))
        cancel.keyEquivalent = "\u{1b}"
        return await run(alert) == .alertFirstButtonReturn
    }

    /// Finder の「項目“名前”はロックされています。ゴミ箱に入れますか?」に当たる確認(ゴミ箱へ入れる 1 件は Finder の文そのまま)。
    /// 並びは左から「(ロックされた項目をスキップ)/ 中止 / 続ける」。一部だけがロックされているときは「ロックされた項目をスキップ」も出す
    /// (2026-09-14。以前は「続ける / 中止」の 2 択で、ロックされていない項目だけを送る手が無かった ―― 計画 §4.11)。
    func confirmLockedItems(_ urls: [URL], totalCount: Int, action: LockedItemAction) async -> LockedItemsDecision {
        let single = urls.count == 1
        let name = urls.first?.lastPathComponent ?? ""
        let message: String
        var information: String?
        // 文言は 1 つずつ String(localized:) に書く(String Catalog が文字列リテラルから拾えるように)。
        switch action {
        case .trash:
            message = single
                ? String(format: String(localized: "Item “%@” is locked. Do you want to move it to the Trash anyway?", language: locale), name)
                : String(format: String(localized: "%lld items are locked. Do you want to move them to the Trash anyway?", language: locale), urls.count)
        case .deleteImmediately:
            message = single
                ? String(format: String(localized: "“%@” is locked. Do you want to delete it anyway?", language: locale), name)
                : String(format: String(localized: "%lld items are locked. Do you want to delete them anyway?", language: locale), urls.count)
            information = String(localized: "Locked items, or folders that contain locked items, are unlocked and then deleted.", language: locale)
        case .move:
            message = single
                ? String(format: String(localized: "“%@” is locked. Do you want to move it anyway?", language: locale), name)
                : String(format: String(localized: "%lld items are locked. Do you want to move them anyway?", language: locale), urls.count)
            information = String(localized: "Locked items are unlocked while they’re moved and locked again at the new location.", language: locale)
        case .rename:
            // 複数は一括リネーム(段階 5)。
            message = single
                ? String(format: String(localized: "“%@” is locked. Do you want to rename it anyway?", language: locale), name)
                : String(format: String(localized: "%lld items are locked. Do you want to rename them anyway?", language: locale), urls.count)
            information = single
                ? String(localized: "The item is unlocked while it’s renamed and locked again afterward.", language: locale)
                : String(localized: "Locked items are unlocked while they’re renamed and locked again afterward.", language: locale)
        case let .replace(deletesImmediately):
            message = String(format: String(localized: "“%@” is locked. Do you want to replace it anyway?", language: locale), name)
            information = deletesImmediately
                ? String(localized: "Locked items, or folders that contain locked items, are unlocked and then deleted.", language: locale)
                : String(localized: "Locked items stay locked in the Trash.", language: locale)
        }
        let offersSkip = urls.count < totalCount
        var buttons: [String] = []
        if offersSkip { buttons.append(String(localized: "Skip Locked Items", language: locale)) }
        buttons.append(String(localized: "Stop", language: locale))
        buttons.append(String(localized: "Continue", language: locale))
        let stopIndex = buttons.count - 2
        // ゴミ箱へ入れる確認は Finder と同じくゴミ箱のアイコン、ほかは項目のアイコン。
        let icon = action == .trash ? Self.trashIcon : await Self.icon(for: urls.first)
        let answer = await prompts.ask(FileOperationPrompt(
            icon: icon, message: Self.joined(message, information), buttons: buttons, checkboxTitle: nil,
            answerWhenOwnerCloses: stopIndex, windowTitle: windowTitle(for: action)
        ), owner: appState?.hostWindow)
        switch answer.button {
        case buttons.count - 1: return .proceed
        case 0 where offersSkip: return .skipLocked
        default: return .stop
        }
    }

    /// 元のフォルダへ書けない項目の移動(Finder などでコピーした項目の ⌥⌘V、外からのドロップ)。Finder に同じ問い合わせは無いので、
    /// 行の形だけ揃える。並びは左から「コピー / 中止 / 移動」(右端がその操作を進める答え ―― Finder の行の並び)。
    func confirmIrreversibleMove(of urls: [URL], totalCount: Int) async -> IrreversibleMoveDecision {
        let message = totalCount == 1
            ? String(format: String(localized: "Moving “%@” can’t be undone.", language: locale), urls[0].lastPathComponent)
            : String(format: String(localized: "Moving these %lld items can’t be undone.", language: locale), totalCount)
        let information = urls.count == totalCount
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
        let answer = await prompts.ask(FileOperationPrompt(
            icon: await Self.icon(for: urls.first), message: Self.joined(message, information),
            buttons: [String(localized: "Copy", language: locale), String(localized: "Stop", language: locale), String(localized: "Move", language: locale)],
            checkboxTitle: nil, answerWhenOwnerCloses: 1, windowTitle: String(localized: "Move", language: locale)
        ), owner: appState?.hostWindow)
        switch answer.button {
        case 2: return .move
        case 0: return .copy
        default: return .stop
        }
    }

    /// 同じ名前の項目。Finder の行と同じ文とボタン(実測 2026-10-24):
    /// - ファイル(と、型の違う項目): 「両方とも残す / 中止 / 置き換える」。
    /// - フォルダ同士のコピー: 「中止 / 置き換える / 結合」(「両方とも残す」は出ない)。文に結合の説明が続く。
    /// - フォルダ同士の移動: 「中止 / 置き換える」(結合も両方とも残すも出ない)。文はファイルと同じ。
    /// 文は宛先の項目のほうが新しい・古いで変わる(変更日で比べる。1 項目だけを運ぶときだけ ―― Finder も複数のときは書き分けない)。
    /// 「すべてに適用」は後にも項目が残っているときだけ。ゴミ箱の無い場所(SMB)でも文は足さない(Finder も足さない。以前は
    /// 「置き換えると元の項目はすぐに削除されます」と続けていた ―― 2026-10-24 に Finder に揃えて外した)。
    /// 既定のボタンは無い(Finder の行と同じ。以前の「両方を残す」を既定にした安全側の決めは、Finder に揃える決定で外した ―― 2026-10-24)。
    func resolveConflict(_ conflict: FileConflict, replacingDeletesImmediately: Bool, cancellation: Cancellation) async -> ConflictDecision {
        let facts = await FileIO.perform { ConflictFacts(conflict) }
        let age = conflict.isSingleItem ? facts.age : .same
        let name = conflict.destination.lastPathComponent
        let message: String
        let stop = String(localized: "Stop", language: locale)
        let replace = String(localized: "Replace", language: locale)
        var buttons: [String]
        var policies: [ConflictPolicy?]
        if facts.isFolderPair, !conflict.isMove {
            switch age {
            case .same:
                message = String(format: String(localized: "A folder named “%@” already exists in this location. Do you want to merge or replace it with the one you’re copying?", language: locale), name)
                    + "\n\n" + mergeDescription(facts.keptByMerge)
            case .destinationNewer:
                message = String(format: String(localized: "A newer folder named “%@” already exists in this location. Do you want to merge or replace it with the older one you’re copying?", language: locale), name)
                    + "\n\n" + mergeDescription(facts.keptByMerge)
            case .destinationOlder:
                message = String(format: String(localized: "An older folder named “%@” already exists in this location. Do you want to merge or replace it with the newer one you’re copying?", language: locale), name)
                    + "\n\n" + mergeDescription(facts.keptByMerge)
            }
            buttons = [stop, replace, String(localized: "Merge Folders", language: locale)]
            policies = [nil, .replace, .merge]
        } else {
            switch (age, conflict.isMove) {
            case (.same, false):
                message = String(format: String(localized: "An item named “%@” already exists in this location. Do you want to replace it with the one you’re copying?", language: locale), name)
            case (.destinationNewer, false):
                message = String(format: String(localized: "A newer item named “%@” already exists in this location. Do you want to replace it with the older one you’re copying?", language: locale), name)
            case (.destinationOlder, false):
                message = String(format: String(localized: "An older item named “%@” already exists in this location. Do you want to replace it with the newer one you’re copying?", language: locale), name)
            case (.same, true):
                message = String(format: String(localized: "An item named “%@” already exists in this location. Do you want to replace it with the one you’re moving?", language: locale), name)
            case (.destinationNewer, true):
                message = String(format: String(localized: "A newer item named “%@” already exists in this location. Do you want to replace it with the older one you’re moving?", language: locale), name)
            case (.destinationOlder, true):
                message = String(format: String(localized: "An older item named “%@” already exists in this location. Do you want to replace it with the newer one you’re moving?", language: locale), name)
            }
            if facts.isFolderPair {
                buttons = [stop, replace]
                policies = [nil, .replace]
            } else {
                buttons = [String(localized: "Keep Both", language: locale), stop, replace]
                policies = [.keepBoth, nil, .replace]
            }
        }
        let stopIndex = buttons.firstIndex(of: stop) ?? 0
        let answer = await prompts.ask(FileOperationPrompt(
            icon: Self.icon(for: conflict.source, isDirectory: facts.sourceIsDirectory, isPackage: facts.sourceIsPackage),
            message: message, buttons: buttons,
            checkboxTitle: conflict.hasMoreItems ? String(localized: "Apply to All", language: locale) : nil,
            answerWhenOwnerCloses: stopIndex,
            windowTitle: conflict.isMove ? String(localized: "Move", language: locale) : String(localized: "Copy", language: locale)
        ), owner: appState?.hostWindow)
        guard answer.button < policies.count, let policy = policies[answer.button] else {
            // 中止: 残りを止める。この項目はスキップとして返す(エンジンは次の区切りで止まる)。
            cancellation.request()
            return ConflictDecision(.skip)
        }
        return ConflictDecision(policy, applyToRemaining: answer.checkboxIsOn)
    }

    /// Finder の結合の説明(「新しい方の項目(“名前”など)がすべて保持されます」)。名前は運ぶ側で残る項目の 1 つ目。
    private func mergeDescription(_ kept: ConflictFacts.KeptItems) -> String {
        switch kept.count {
        case 0:
            return String(localized: "Merge will combine the two folders, preserving all the newer items.", language: locale)
        case 1:
            return String(format: String(localized: "Merge will combine the two folders, preserving all the newer items such as “%@”.", language: locale), kept.firstName)
        case 2:
            return String(format: String(localized: "Merge will combine the two folders, preserving all the newer items such as “%1$@” and %2$lld other item.", language: locale), kept.firstName, 1)
        default:
            return String(format: String(localized: "Merge will combine the two folders, preserving all the newer items such as “%1$@” and %2$lld other items.", language: locale), kept.firstName, kept.count - 1)
        }
    }

    /// Finder の「これらの項目の一部はコピーできません。コピー先ボリュームで使用するには名前が長すぎます。…」(「中止 / スキップ」)。
    func confirmSkippingLongNames(_ urls: [URL]) async -> Bool {
        let answer = await prompts.ask(FileOperationPrompt(
            icon: await Self.icon(for: urls.first),
            message: String(
                localized: "You can’t copy some of these items because their names are too long for the destination volume. Do you want to skip these items and continue copying the other items?",
                language: locale
            ),
            buttons: [String(localized: "Stop", language: locale), String(localized: "Skip", language: locale)],
            checkboxTitle: nil, answerWhenOwnerCloses: 0, windowTitle: String(localized: "Copy", language: locale)
        ), owner: appState?.hostWindow)
        return answer.button == 1
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
        return await WindowSheet.chooseURLs(panel, for: appState?.hostWindow)?.first
    }

    func showProblem(_ problem: FileBrowserProblem) {
        switch problem.presentation {
        case .alert:
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = problem.title
            alert.informativeText = problem.message
            alert.addButton(withTitle: String(localized: "OK", language: locale))
            Task { _ = await run(alert) }
        case let .row(item):
            let owner = appState?.hostWindow
            let text = Self.joined(problem.title, problem.message)
            let title = String(localized: "File Operations", language: locale)
            let ok = String(localized: "OK", language: locale)
            Task { [prompts] in
                let icon = await Self.icon(for: item)
                prompts.report(FileOperationPrompt(
                    icon: icon, message: text, buttons: [ok], checkboxTitle: nil, answerWhenOwnerCloses: nil, windowTitle: title
                ), owner: owner)
            }
        }
    }

    private func run(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        await WindowSheet.run(alert, for: appState?.hostWindow)
    }

    private func windowTitle(for action: LockedItemAction) -> String {
        switch action {
        case .trash: String(localized: "Move to Trash", language: locale)
        case .deleteImmediately: String(localized: "Delete", language: locale)
        case .move: String(localized: "Move", language: locale)
        case .rename: String(localized: "Rename", language: locale)
        case .replace: String(localized: "Replace", language: locale)
        }
    }

    /// 行の本文。題と説明を空行で分ける(Finder の結合の行と同じ形)。空のほうは付けない。
    static func joined(_ title: String, _ message: String?) -> String {
        guard let message, !message.isEmpty else { return title }
        return title.isEmpty ? message : title + "\n\n" + message
    }

    /// ゴミ箱(中身あり)のアイコン ―― Finder の「ゴミ箱」ウインドウの行と同じ。
    static var trashIcon: NSImage {
        NSImage(named: NSImage.trashFullName) ?? NSWorkspace.shared.icon(for: .folder)
    }

    /// 項目のアイコン。フォルダかどうかだけ FileIO で確かめる(**メインで stat しない** ―― 応答しない共有で止まる。CLAUDE.md)。
    static func icon(for url: URL?) async -> NSImage {
        guard let url else { return NSWorkspace.shared.icon(for: .data) }
        let kind = await FileIO.perform { () -> ItemKind in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            return ItemKind(isDirectory: values?.isDirectory == true, isPackage: values?.isPackage == true)
        }
        return icon(for: url, isDirectory: kind.isDirectory, isPackage: kind.isPackage)
    }

    private nonisolated struct ItemKind: Sendable {
        let isDirectory: Bool
        let isPackage: Bool
    }

    /// 型から引くアイコン(ファイルに触らない)。Finder の行は項目そのもののアイコンだが、テキスト・フォルダでは型のアイコンと
    /// 同じ絵になる(画素で確かめた)。独自のアイコンを付けた項目だけが違う。
    static func icon(for url: URL, isDirectory: Bool, isPackage: Bool) -> NSImage {
        let pathExtension = url.pathExtension
        if isDirectory, !isPackage { return NSWorkspace.shared.icon(for: .folder) }
        if !pathExtension.isEmpty, let type = UTType(filenameExtension: pathExtension) {
            return NSWorkspace.shared.icon(for: type)
        }
        return NSWorkspace.shared.icon(for: isDirectory ? .package : .data)
    }
}

/// 衝突の文とボタンを決めるために、両方の項目を 1 回だけ見る(FileIO の上で)。
nonisolated struct ConflictFacts: Sendable {
    enum Age: Sendable { case same, destinationNewer, destinationOlder }

    /// 結合で運ぶ側から残る項目(宛先に無い・宛先より新しいファイル)。多ければ上限まで見て止める。
    struct KeptItems: Sendable {
        var firstName = ""
        var count = 0
    }

    let isFolderPair: Bool
    let sourceIsDirectory: Bool
    let sourceIsPackage: Bool
    let age: Age
    var keptByMerge = KeptItems()

    init(_ conflict: FileConflict) {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .contentModificationDateKey]
        let source = try? conflict.source.resourceValues(forKeys: keys)
        let destination = try? conflict.destination.resourceValues(forKeys: keys)
        sourceIsDirectory = source?.isDirectory == true
        sourceIsPackage = source?.isPackage == true
        isFolderPair = FileOperationService.isMergeableFolder(conflict.source) && FileOperationService.isMergeableFolder(conflict.destination)
        if let a = source?.contentModificationDate, let b = destination?.contentModificationDate, a != b {
            age = b > a ? .destinationNewer : .destinationOlder
        } else {
            age = .same
        }
        if isFolderPair, !conflict.isMove {
            keptByMerge = Self.keptItems(merging: conflict.source, into: conflict.destination)
        }
    }

    /// 数える上限(大きなフォルダで尋ねるのを待たせない)。
    static let visitLimit = 10_000

    /// 結合で運ぶ側から残る項目(`FileOperationService.merge` と同じ決め方)。
    static func keptItems(merging source: URL, into destination: URL) -> KeptItems {
        var kept = KeptItems()
        var visited = 0
        func note(_ name: String) {
            if kept.count == 0 { kept.firstName = name }
            kept.count += 1
        }
        func walk(_ from: URL, _ to: URL) {
            guard let names = try? FileOperationService.directoryEntryNames(atPath: from.path) else { return }
            for name in names.sorted() {
                visited += 1
                guard visited <= visitLimit else { return }
                let child = from.appendingPathComponent(name)
                let target = to.appendingPathComponent(name)
                if !FileOperationService.itemExists(at: target) {
                    note(name)
                } else if FileOperationService.isMergeableFolder(child), FileOperationService.isMergeableFolder(target) {
                    walk(child, target)
                } else if FileOperationService.isNewer(child, than: target) {
                    note(name)
                }
            }
        }
        walk(source, destination)
        return kept
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
                        HStack(spacing: 6) {
                            Text(activity.title)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                // 題には項目の名前が入り、中間が省略されうる(2026-10-12)。
                                .help(activity.title)
                            // 後ろに並んでいる操作(2026-10-06 の応答性の点検 R6-1)。
                            if operations.queuedOperationCount > 0 {
                                Text(String(
                                    format: String(localized: "%lld more waiting", language: locale),
                                    operations.queuedOperationCount
                                ))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .layoutPriority(1)
                            }
                        }
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
