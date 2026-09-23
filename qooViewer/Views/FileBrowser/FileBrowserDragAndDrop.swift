import AppKit
import SwiftUI
import UniformTypeIdentifiers

// ファイルブラウザのドラッグ&ドロップ(改善要望7 段階4b、2026-09-13)。
//
// ■ 受け口と出し口
// - 出し口: リスト(NSTableView)・ツリーのフォルダの行(NSOutlineView)・アイコン表示のセル
//   (NSCollectionView)。ペーストボードには**実際のファイルの URL**(`NSURL`)を書く
//   (`NSFilePromiseProvider` は使わない。検討メモ §9)。**アプリの外へも移動を許す**(copy / move / generic)。
//   Finder へ落とすと、Finder 自身が Finder の規則で移動・コピーする(同じボリュームは移動、別はコピー、⌥ でコピー、
//   ⌘ で移動。実機 2026-09-14。移動は Finder が行うのでサンドボックスに掛からない)。こちらは元を消さない
//   (`endedAt` で何もしない)ので、移動を受けて自分で元を消さない相手へ落としてもコピーで済む。
//   最初は「Finder が移動してくれるかは文書に無い」としてコピーだけにしていたが、Finder の代わりに使うと
//   Finder のウインドウ同士と挙動が違うのは期待に反する(ユーザー指摘 2026-09-13)。
//   Dock のゴミ箱へのドロップ(`.delete`)は許していない ―― 足しても合成したドラッグでは Finder からでさえ
//   ゴミ箱が受け付けず、確かめられなかったため。
//   **読み取り専用モードの間はコピーだけを許す**(段階 8.5、`fileBrowserDragSourceMask`)。移動を許すと、Finder へ
//   落としたときに Finder が元を動かす ―― 動かすのが Finder でも、ファイルブラウザから元の場所が変わる。
// - 受け口: リストの行と空きスペース・アイコン表示のセルと余白・ツリーの行・パスバーの項目(いずれも AppKit)、
//   右ペインの残り全部(操作列など。FileBrowserDropDelegate)。
//   **何をするかの判定は `FileBrowserDropDecision` の 1 か所**で、実行は `FileBrowserOperations`。
//
// ■ ウインドウ全体のドロップ先との関係
// ウインドウには本を開くドロップ先が 1 つ付いている(ContentView.applyFileDropTarget)。右ペインは
// 全体を受け口で覆い、**断るときも受け口として断る**(SwiftUI の内側の受け口が断ると外側が拾い、
// 「フォルダを自分の上に落としたら本として開いた」になる)。

/// いまアプリの中から始まっているファイルのドラッグ(出し口が始まりで入れ、終わりで消す)。
///
/// SwiftUI の `DropInfo` にはドラッグ元が無いので、「アプリの中からか」をここで見分ける
/// (AppKit の受け口も同じ答えを使う)。ウインドウをまたいだドラッグもアプリの中として扱う。
@MainActor
enum FileBrowserDragTracker {
    private(set) static var items: [URL]?
    /// ドラッグ元が移動を許しているか。ホームの本のドラッグ(`HomeBookDragTracker`)は**コピーだけ**(2026-09-23 の 3 回目の
    /// 監査の中 12)。AppKit の受け口はドラッグ元の `draggingSourceOperationMask` を読めるが、SwiftUI の受け口(`DropInfo`)は
    /// 読めないので、ここで持つ。以前は SwiftUI の受け口が常に「移動してよい」として判定し、同じボリュームの棚の本を落とすと
    /// 移動になった。
    private(set) static var allowsMove = true

    static func begin(_ urls: [URL], allowsMove: Bool = true) {
        items = urls
        self.allowsMove = allowsMove
    }

    static func end() {
        items = nil
        allowsMove = true
    }
}

/// ドロップされたときにすること。
enum FileBrowserDropDecision: Equatable {
    /// 落とした先のフォルダへ移動・コピーする。
    case transfer(FileDropPlan, into: URL)
    /// 本として開く(他のアプリからのドロップで、環境設定が「ビューアで開く」のとき)。
    case openInViewer
    /// 何もしない(自分の中へ落とす・コンピュータへ落とす・自分のフォルダへの移動だけ)。
    case refuse

    /// - Parameters:
    ///   - urls: 落とされた項目。他のアプリからのドラッグで、まだ中身を読めない段階(SwiftUI の
    ///     カーソルの判定)では空でよい。
    ///   - destination: 落とす先のフォルダ。nil はコンピュータ(ボリュームの一覧)。
    ///   - isInternal: アプリの中から始まったドラッグか(FileBrowserDragTracker)。
    ///   - allowsMove: ドラッグ元が移動を許しているか。
    ///   - allowsFileChanges: 読み取り専用モードでないか。false なら運ばない(「ビューアで開く」はそのまま。段階 8.5)。
    static func make(
        urls: [URL], destination: URL?, isInternal: Bool, allowsMove: Bool, modifiers: FileDropPlan.Modifiers,
        externalAction: FileBrowserExternalDropAction, allowsFileChanges: Bool, isOnSameVolume: (URL, URL) -> Bool
    ) -> FileBrowserDropDecision {
        if !isInternal, externalAction == .openInViewer { return .openInViewer }
        guard allowsFileChanges, let destination, !urls.isEmpty,
              let plan = FileDropPlan.make(
                items: urls, destination: destination, modifiers: modifiers, allowsMove: allowsMove,
                isOnSameVolume: isOnSameVolume
              )
        else { return .refuse }
        return .transfer(plan, into: destination)
    }

    /// AppKit のカーソルに出す操作。
    func dragOperation(sourceMask: NSDragOperation) -> NSDragOperation {
        switch self {
        case .refuse:
            return []
        case .openInViewer:
            // 開くだけなので「+」を出さない(generic)。元が generic を許さなければコピー。
            return sourceMask.contains(.generic) ? .generic : sourceMask.intersection(.copy)
        case .transfer(let plan, _):
            if plan.isMove { return sourceMask.contains(.move) ? .move : .generic }
            return .copy
        }
    }

    /// SwiftUI のカーソルに出す操作。
    var dropProposal: DropProposal {
        switch self {
        case .refuse: DropProposal(operation: .forbidden)
        // SwiftUI には generic が無い。「+」を出さない move で代える(開くだけで何も動かさない)。
        case .openInViewer: DropProposal(operation: .move)
        case .transfer(let plan, _): DropProposal(operation: plan.isMove ? .move : .copy)
        }
    }
}

extension FileDropPlan.Modifiers {
    /// いま押されている修飾キー。**ドロップの瞬間に読む**(判定を非同期にすると離されている。検討メモ §9)。
    @MainActor
    static var current: FileDropPlan.Modifiers {
        // マウスのイベントの処理中ならそのイベントの修飾キーを読む。`NSEvent.modifierFlags` は「いまの」キーの
        // 状態で、ボタンを離した直後に ⌥ も離されていると、離した瞬間のイベントを処理している間にもう
        // ⌥ なしを返した(ドロップが同じフォルダへの移動 = 何もしない、に化けた。実機 2026-09-13)。
        let mouseTypes: Set<NSEvent.EventType> = [.leftMouseDragged, .leftMouseUp, .leftMouseDown]
        let flags = NSApp.currentEvent.flatMap { mouseTypes.contains($0.type) ? $0.modifierFlags : nil }
            ?? NSEvent.modifierFlags
        var modifiers: FileDropPlan.Modifiers = []
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.command) { modifiers.insert(.command) }
        return modifiers
    }
}

extension NSDragOperation {
    /// ドラッグ元が移動を許しているか。⌘ を押すと AppKit はマスクを generic だけに絞るので、generic も移動に数える。
    var allowsFileMove: Bool {
        !isDisjoint(with: [.move, .generic])
    }
}

extension FileDropPlan {
    /// SwiftUI の受け口に、ほかのアプリから落とされた項目を**移動してよいか**(2026-09-14 の 2 回目の監査)。
    ///
    /// SwiftUI の `DropInfo` にはドラッグ元が許す操作(`draggingSourceOperationMask`)が無いので、以前は常に「許す」とみなし、
    /// コピーしか許さないアプリ(メールの添付・書類のプロキシアイコンなど)から同じボリュームへ落とした項目を、元のアプリの知らないうちに
    /// 移動していた(AppKit の受け口はマスクを見ている)。ドラッグの間はドラッグ元のアプリが最前面のままなので、**Finder からのときだけ**
    /// 移動を許す(Finder は移動を許す出し口。ファイルを移動で運ぶ期待があるのも Finder のウインドウからだけ)。ほかはコピーになる。
    @MainActor
    static var externalSourceAllowsMoveForSwiftUIDrop: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder"
    }
}

extension FileBrowserActions {
    /// 判定(`FileBrowserDropDecision.make`)に、環境設定・マウント表・アプリの中からのドラッグかを足す。
    func dropDecision(
        urls: [URL], into destination: URL?, allowsMove: Bool = true,
        modifiers: FileDropPlan.Modifiers? = nil
    ) -> FileBrowserDropDecision {
        let internalItems = FileBrowserDragTracker.items
        let mountTable = MountTable.current()
        return FileBrowserDropDecision.make(
            urls: internalItems ?? urls, destination: destination, isInternal: internalItems != nil,
            allowsMove: allowsMove, modifiers: modifiers ?? .current,
            externalAction: preferences?.fileBrowserExternalDropAction ?? .openInViewer,
            allowsFileChanges: allowsFileChanges,
            isOnSameVolume: mountTable.areOnSameVolume
        )
    }

    /// 判定を実行する。`urls` は本として開くときに使う(移動・コピーは判定に入っている)。
    func performDrop(_ decision: FileBrowserDropDecision, urls: [URL]) {
        switch decision {
        case .refuse:
            break
        case .openInViewer:
            guard !urls.isEmpty else { return }
            appState?.open(urls: urls)
        case let .transfer(plan, destination):
            state?.operations.drop(plan, into: destination)
        }
    }

    /// AppKit の受け口の共通部分: ペーストボードの URL を読んで判定する。
    func dropDecision(for info: NSDraggingInfo, into destination: URL?) -> (FileBrowserDropDecision, [URL]) {
        // **ほかのアプリからのドラッグ(ドラッグ元が見えない)なら、残っている記録は古い**(2026-09-14 の監査)。記録を下ろすのは
        // 出し口の `draggingSession(_:endedAt:operation:)` だけで、それが届かない終わり方をすると、次の外からのドラッグが
        // 「アプリの中から、前に運んだ項目を」と取り違えられた。AppKit の受け口はドラッグ元を確かめられるので、ここで捨てる
        // (SwiftUI の `DropInfo` には元が無いので、この受け口を一度通るまでは古い記録のまま)。
        if info.draggingSource == nil { FileBrowserDragTracker.end() }
        let urls = FileBrowserDragTracker.items ?? Self.fileURLs(in: info.draggingPasteboard)
        let decision = dropDecision(
            urls: urls, into: destination, allowsMove: info.draggingSourceOperationMask.allowsFileMove
        )
        return (decision, urls)
    }

    static func fileURLs(in pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    /// 出し口のペーストボードに書くもの(ボリュームそのものは運ばない)。
    static func pasteboardWriter(for entry: FileBrowserEntry) -> NSPasteboardWriting? {
        entry.isVolume ? nil : entry.url as NSURL
    }
}

/// 出し口が許す操作。アプリの外へも移動を許すが、読み取り専用モードの間はコピーだけ(ファイル冒頭のコメント)。
/// AppKit の一覧は `draggingSession(_:sourceOperationMaskFor:)` を上書きしてドラッグのたびにこれを引く
/// (`setDraggingSourceOperationMask` は作ったときの 1 回なので、あとから切り替えた設定が効かない)。
/// よく使う項目の行の並べ替えのドラッグが運ぶ型(2026-09-14、ユーザー要望)。中身は項目の id。
///
/// **ファイルの URL は書かない** ―― 書くとリストやフォルダの行・Finder へ落としたときに、登録したフォルダそのものが
/// 移動・コピーされてしまう(ツリーの根を掴んで運べないようにしている理由と同じ。FileBrowserTreeView の型コメント)。
/// アプリの独自の型だけなら、ほかの受け口(ファイルの URL を待つもの)はどれも反応しない。
let fileBrowserFavoriteLocationPasteboardType = NSPasteboard.PasteboardType("com.qooProject.qooViewer.favoriteLocation")

func fileBrowserDragSourceMask(allowsFileChanges: Bool) -> NSDragOperation {
    allowsFileChanges ? [.copy, .move, .generic] : .copy
}

/// AppKit の出し口が共有する設定。アプリの外へも移動を許す(ファイル冒頭のコメント)。
@MainActor
func configureFileBrowserDragSource(_ table: NSTableView) {
    table.registerForDraggedTypes([.fileURL])
    table.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
    table.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: false)
    table.verticalMotionCanBeginDrag = true
}

// MARK: - SwiftUI の受け口

/// 右ペインの残り全部(操作列・トースト。今のフォルダ)の受け口。一覧(リスト・アイコン表示)とパスバーは AppKit の受け口が先に受ける
/// (2026-09-15 にアイコン表示を AppKit にしたので、ここで受けるのは一覧の外だけ)。
///
/// **断るときも `validateDrop` は true を返す**(ファイル全体の型コメント「ウインドウ全体のドロップ先との関係」)。
/// 断るのは `dropUpdated` の `.forbidden` と `performDrop` の false で行う。
struct FileBrowserDropDelegate: DropDelegate {
    let destination: URL?
    let actions: FileBrowserActions
    /// 受け口として反応している間 true(セルの強調に使う)。
    var onTargetChange: ((Bool) -> Void)?

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) {
        onTargetChange?(currentProposal().isAccepted && !Self.justDropped)
    }

    func dropExited(info: DropInfo) {
        onTargetChange?(false)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let current = currentProposal()
        onTargetChange?(current.isAccepted && !Self.justDropped)
        return current.proposal
    }

    func performDrop(info: DropInfo) -> Bool {
        onTargetChange?(false)
        // **ドロップの後にもう1回 dropUpdated が届き**、消したはずの強調が付き直って残った(アイコン表示の
        // フォルダのセル。performDrop の直後に届くのをログで確かめた 2026-09-13)。しばらくは付け直さない。
        Self.droppedAt = Date()
        let modifiers = FileDropPlan.Modifiers.current
        let allowsMove = FileDropPlan.externalSourceAllowsMoveForSwiftUIDrop
        if FileBrowserDragTracker.items != nil {
            let decision = actions.dropDecision(
                urls: [], into: destination, allowsMove: FileBrowserDragTracker.allowsMove, modifiers: modifiers
            )
            actions.performDrop(decision, urls: [])
            return decision.isAccepted
        }
        // 他のアプリから: 中身は NSItemProvider から読む(サンドボックスの読み取りの許可はこの経路で付く)。
        // 修飾キーは読み終わるのを待たずにここで控える。
        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else { return false }
        let destination = destination
        let actions = actions
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                if let url = await Self.loadFileURL(from: provider) { urls.append(url) }
            }
            let decision = actions.dropDecision(urls: urls, into: destination, allowsMove: allowsMove, modifiers: modifiers)
            actions.performDrop(decision, urls: urls)
        }
        return true
    }

    /// カーソルの判定。他のアプリからのドラッグの中身はドラッグのペーストボードから読む
    /// (読めなければ空のまま判定し、移動かコピーかはドロップの瞬間に決め直す)。
    /// 最後に落とした時刻(上の performDrop のコメント)。
    @MainActor private static var droppedAt: Date?

    @MainActor private static var justDropped: Bool {
        droppedAt.map { Date().timeIntervalSince($0) < 0.5 } ?? false
    }

    private func currentProposal() -> (proposal: DropProposal, isAccepted: Bool) {
        let isExternal = FileBrowserDragTracker.items == nil
        let urls = isExternal ? FileBrowserActions.fileURLs(in: NSPasteboard(name: .drag)) : []
        let decision = actions.dropDecision(
            urls: urls, into: destination,
            allowsMove: isExternal ? FileDropPlan.externalSourceAllowsMoveForSwiftUIDrop : FileBrowserDragTracker.allowsMove
        )
        // 中身が読めなかった他のアプリからのドラッグは、断らずに「+」で受ける(決め直しはドロップの瞬間)。
        if decision == .refuse, isExternal, urls.isEmpty, destination != nil {
            return (DropProposal(operation: .copy), true)
        }
        return (decision.dropProposal, decision.isAccepted)
    }

    private static func loadFileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }
}

extension FileBrowserDropDecision {
    var isAccepted: Bool { self != .refuse }
}
