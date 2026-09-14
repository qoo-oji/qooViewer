import AppKit
import SwiftUI

/// ファイルブラウザの項目に対してできること(改善要望7 段階3、2026-09-13)。リスト(AppKit)・
/// アイコン(SwiftUI)・ツリー(AppKit)の3つが**同じ1つ**を呼ぶ。
///
/// ■ クラスで、相手はすべて weak
/// AppKitのメニュー項目やセルの閉包は、ウインドウより長生きしうる(CLAUDE.md の
/// ViewerActionRelay の件)。ここが`AppState`などを強く掴むと、閉じたウインドウの
/// AppState/PageLoader/NSWindow が残る。持ち主はペインの`@State`で、AppKitの側も参照を
/// `dismantleNSView`で手放す。
@MainActor
final class FileBrowserActions {
    weak var state: FileBrowserState?
    weak var appState: AppState?
    weak var launchCoordinator: LaunchCoordinator?
    weak var folderAccess: FolderAccessStore?
    weak var favoriteLocations: FavoriteLocationStore?
    weak var preferences: AppPreferences?
    /// 新しいタブ/ウインドウを開く口。値なので weak にできない。**ペインが消えたら外す**(`FileBrowserPane` の `onDisappear`。
    /// この箱は `.contextMenu` を通じてウインドウより長生きしうるので、閉じたウインドウの SwiftUI の中身を抱えさせない。監査 10)。
    var openWindow: OpenWindowAction?
    /// 既存機能との接続(段階 8。FileBrowserLibraryActions.swift)。
    weak var collectionStore: CollectionStore?
    weak var coverExtractor: CollectionCoverExtractor?
    weak var bookmarkStore: BookmarkStore?
    weak var layoutStore: LayoutStore?
    weak var metadataStore: BookMetadataStore?
    /// 「コレクションに登録」のサブメニューの中身(FileBrowserActions.collectionMenuLibraries)。
    var collectionMenuCache: CollectionMenuCache?

    /// シークレットウインドウでは保存を伴う操作(よく使う項目の登録・削除)を塞ぐ(決定事項 Q8)。
    var allowsSaving: Bool { !(appState?.isPrivateWindow ?? true) }

    // MARK: - 開く

    /// ダブルクリック / Return。**フォルダは(画像フォルダでも)常に中へ移動する**(要望)。
    /// 本と画像は qooViewer で開き、それ以外は既定のアプリで開く。
    ///
    /// 複数を選んでいるとき、フォルダは開かない(移動先は1つしか選べない)。本は
    /// `BookOpenRequest`の規則でまとめる(全部画像なら1冊、それ以外は先頭の1冊)。
    func open(_ entries: [FileBrowserEntry]) {
        guard let state else { return }
        if entries.count == 1, let entry = entries.first, entry.isNavigableFolder {
            state.navigate(to: entry.url)
            return
        }
        if entries.count == 1, let entry = entries.first, entry.isSymbolicLink {
            openSymbolicLink(entry)
            return
        }
        let books = entries.filter(\.opensAsBook).map(\.url)
        if !books.isEmpty {
            appState?.open(urls: books)
        }
        for entry in entries where !entry.opensAsBook && !entry.isNavigableFolder {
            NSWorkspace.shared.open(entry.url)
        }
    }

    /// 右クリックの「開く」。ダブルクリックと違い、**画像フォルダは本として開く**
    /// (中へ移動したければダブルクリック)。画像フォルダかどうかはここで1回だけ調べる
    /// (一覧の読み込みでは子フォルダの中を見ない。FileBrowserEntryの型コメント)。
    func openFromMenu(_ entries: [FileBrowserEntry]) {
        guard entries.count == 1, let entry = entries.first, entry.isNavigableFolder else {
            open(entries)
            return
        }
        let order = preferences?.siblingBookOrder ?? .byName
        Task { [weak self] in
            let isBook = await Self.isImageFolder(entry.url, order: order)
            guard let self else { return }
            if isBook {
                self.appState?.open(url: entry.url)
            } else {
                self.state?.navigate(to: entry.url)
            }
        }
    }

    /// 新規タブ / 新規ノーマルウインドウ / 新規シークレットウインドウで開く。フォルダは画像フォルダなら
    /// 本として、それ以外はファイルブラウザとして開く。
    func open(_ entry: FileBrowserEntry, in destination: BookOpenDestination) {
        guard let openWindow, let launchCoordinator else { return }
        let source = appState
        if entry.isNavigableFolder {
            let order = preferences?.siblingBookOrder ?? .byName
            Task {
                if await Self.isImageFolder(entry.url, order: order) {
                    BookWindowOpener.open(
                        BookOpenRequest(entry.url), to: destination, from: source,
                        launchCoordinator: launchCoordinator, openWindow: openWindow
                    )
                } else {
                    BookWindowOpener.openFolder(entry.url, to: destination, from: source, openWindow: openWindow)
                }
            }
        } else if entry.opensAsBook {
            BookWindowOpener.open(
                BookOpenRequest(entry.url), to: destination, from: source,
                launchCoordinator: launchCoordinator, openWindow: openWindow
            )
        }
    }

    /// 新しいタブ/ウインドウで開けるか(1件用。本かフォルダだけ)。
    func canOpenInNewWindow(_ entries: [FileBrowserEntry]) -> Bool {
        guard entries.count == 1, let entry = entries.first else { return false }
        return entry.isNavigableFolder || entry.opensAsBook
    }

    func showInFinder(_ entries: [FileBrowserEntry]) {
        guard !entries.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(entries.map(\.url))
    }

    // MARK: - 書く操作(段階4。実体は FileBrowserOperations)

    /// ファイルを変える操作ができるか(読み取り専用モードでない。段階 8.5)。項目を淡色にするための読み出しで、
    /// 断るのは `FileBrowserOperations` の入り口(ここで淡色にし忘れても、そこで止まる)。
    var allowsFileChanges: Bool {
        !(state?.operations.isReadOnly ?? true)
    }

    /// 選んだ項目がペーストボードへ載せられるか(ボリュームそのもの・コンピュータの行は運ばない)。⌘C はこれだけで決まる。
    func canModify(_ entries: [FileBrowserEntry]) -> Bool {
        !entries.isEmpty && !entries.contains(where: \.isVolume)
    }

    /// 選んだ項目のファイルそのものを変えられるか(カット・ゴミ箱・名前の変更)。
    func canChange(_ entries: [FileBrowserEntry]) -> Bool {
        allowsFileChanges && canModify(entries)
    }

    func copy(_ entries: [FileBrowserEntry]) {
        state?.operations.copy(entries)
    }

    func cut(_ entries: [FileBrowserEntry]) {
        state?.operations.cut(entries)
    }

    func canPaste(into folder: URL?) -> Bool {
        allowsFileChanges && folder != nil && (state?.operations.canPaste ?? false)
    }

    /// 新規フォルダを作れるか。
    func canCreateFolder(in folder: URL?) -> Bool {
        allowsFileChanges && folder != nil
    }

    func paste(into folder: URL?, forceMove: Bool = false) {
        guard let folder else { return }
        state?.operations.paste(into: folder, forceMove: forceMove)
    }

    func moveToTrash(_ entries: [FileBrowserEntry]) {
        guard canChange(entries) else { return }
        state?.operations.moveToTrash(entries)
    }

    func newFolder(in folder: URL?) {
        guard canCreateFolder(in: folder), let folder else { return }
        state?.operations.newFolder(in: folder)
    }

    /// 圧縮できるか(段階 6)。同じフォルダの項目だけ(1 つの zip の置き場所が決まらない)。
    func canCompress(_ entries: [FileBrowserEntry]) -> Bool {
        guard canChange(entries), let parent = entries.first?.url.deletingLastPathComponent() else { return false }
        let parentID = FileBrowserState.id(for: parent)
        return entries.allSatisfy { FileBrowserState.id(for: $0.url.deletingLastPathComponent()) == parentID }
    }

    /// 展開できるか(段階 6)。**選んだ全部が書庫のときだけ**(書庫でない項目が混ざったら淡色。何が展開されるのか曖昧にしない)。
    func canExtract(_ entries: [FileBrowserEntry]) -> Bool {
        canCompress(entries) && entries.allSatisfy(\.isExtractableArchive)
    }

    func compress(_ entries: [FileBrowserEntry], choosingDestination: Bool) {
        guard canCompress(entries) else { return }
        state?.operations.compress(entries, choosingDestination: choosingDestination)
    }

    func extract(_ entries: [FileBrowserEntry], placement: ArchiveExtractor.Placement, choosingDestination: Bool) {
        guard canExtract(entries) else { return }
        state?.operations.extract(entries, placement: placement, choosingDestination: choosingDestination)
    }

    /// 右クリックの「名前を変更」。1 件なら一覧に名前の編集を始めてもらい、複数なら一括リネームのシートを出す(段階 5。Finder と同じ)。
    func beginRename(_ entries: [FileBrowserEntry]) {
        guard canChange(entries) else { return }
        if entries.count == 1, let entry = entries.first {
            state?.requestRename(entry.id)
        } else {
            state?.operations.bulkRename(entries)
        }
    }

    // MARK: - アクセス権・よく使う項目

    /// いま見ようとしているフォルダの読み取りを許可してもらう(SidePanelBrowserState.requestFolderAccessと同じ形)。
    func requestAccessToCurrentFolder() {
        guard let state, let folder = state.currentFolder else { return }
        let locale = preferences?.effectiveLocale ?? .autoupdatingCurrent
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        panel.prompt = String(localized: "Grant Access", language: locale)
        panel.message = String(
            localized: "To show files in this folder, please select and grant access to it.",
            language: locale
        )
        guard panel.runModal() == .OK, let granted = panel.url else { return }
        folderAccess?.add(url: granted)
        state.reload()
    }

    /// よく使う項目に足す(「＋」)。選んだフォルダの読み取りも同時に許可される
    /// (FavoriteLocationStoreの型コメント)。
    func addFavoriteLocation() {
        guard allowsSaving else { return }
        let locale = preferences?.effectiveLocale ?? .autoupdatingCurrent
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = state?.currentFolder
        panel.prompt = String(localized: "Add", language: locale)
        panel.message = String(
            localized: "Choose a folder to add to Favorite Locations. qooViewer can then show the files in it.",
            language: locale
        )
        guard panel.runModal() == .OK, let granted = panel.url else { return }
        folderAccess?.add(url: granted)
        favoriteLocations?.add(granted)
        state?.navigate(to: granted)
    }

    /// 右クリックの「よく使う項目に登録」(2026-09-14、ユーザー要望)。まだ登録していないフォルダがあるときだけ押せる
    /// (全部登録済みなら淡色)。フォルダだけ(ファイルが混ざったら淡色)。
    func canAddToFavoriteLocations(_ entries: [FileBrowserEntry]) -> Bool {
        guard allowsSaving, let favoriteLocations, !entries.isEmpty,
              entries.allSatisfy(\.isNavigableFolder)
        else { return false }
        return entries.contains { !favoriteLocations.contains($0.url) }
    }

    /// 登録するのはパスだけ。**ここではアクセス権を足さない**: 一覧に見えている時点で読めているフォルダで、読めなくなれば
    /// 行は残って「アクセスを許可…」の案内に落ちる(FavoriteLocationStore の型コメント。「＋」とはここが違う)。
    func addToFavoriteLocations(_ entries: [FileBrowserEntry]) {
        guard canAddToFavoriteLocations(entries) else { return }
        for entry in entries { favoriteLocations?.add(entry.url) }
    }

    func removeFavoriteLocation(id: UUID) {
        guard allowsSaving else { return }
        favoriteLocations?.remove(id: id)
    }

    // MARK: - 下請け

    /// 記号リンク: 実体がフォルダなら中へ、ファイルなら実体を開く。
    private func openSymbolicLink(_ entry: FileBrowserEntry) {
        let link = entry.url
        Task { [weak self] in
            let target = await FileIO.perform { () -> (URL, Bool) in
                let resolved = link.resolvingSymlinksInPath()
                var isDirectory: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory)
                return (resolved, exists && isDirectory.boolValue)
            }
            guard let self else { return }
            if target.1 {
                self.state?.navigate(to: target.0)
            } else if isArchiveFile(target.0.lastPathComponent) || isPDFFile(target.0.lastPathComponent)
                        || isEpubFile(target.0.lastPathComponent) || isImageFile(target.0.lastPathComponent) {
                self.appState?.open(url: target.0)
            } else {
                NSWorkspace.shared.open(target.0)
            }
        }
    }

    /// 画像フォルダ(それ自体が1冊の本)か。棚への登録と同じ判定(ShelfFolderResolver.role)を
    /// FileIOの上で。
    private nonisolated static func isImageFolder(_ url: URL, order: SiblingBookOrder) async -> Bool {
        await FileIO.perform {
            if case .book = ShelfFolderResolver.role(of: url, order: order) { return true }
            return false
        }
    }
}

/// キーと編集メニューから届く操作(段階4)。リスト(`FileBrowserTableView`)とアイコン表示が同じ口へ渡す。
enum FileBrowserEditCommand {
    case copy, cut, paste
    /// ⌥⌘V「ここに項目を移動」。
    case moveItemHere
    /// ⌘⌫。
    case moveToTrash
    case goBack, goForward, goUp

    /// 一覧のキー操作から引く(⌘C/⌘X/⌘V は編集メニューが受けるのでここには無い)。
    static func forKey(_ event: NSEvent) -> FileBrowserEditCommand? {
        forKey(keyCode: event.keyCode, flags: event.modifierFlags)
    }

    static func forKey(keyCode: UInt16, flags modifierFlags: NSEvent.ModifierFlags) -> FileBrowserEditCommand? {
        let flags = modifierFlags.intersection([.command, .option, .shift, .control])
        switch (keyCode, flags) {
        case (51, [.command]): return .moveToTrash                // ⌘⌫
        case (9, [.command, .option]): return .moveItemHere       // ⌥⌘V
        case (33, [.command]): return .goBack                     // ⌘[
        case (30, [.command]): return .goForward                  // ⌘]
        case (126, [.command]): return .goUp                      // ⌘↑
        default: return nil
        }
    }
}

@MainActor
protocol FileBrowserEditResponding: AnyObject {
    /// 名前の欄の編集を始めてよいか(読み取り専用モードの間は、クリックからも始めない。段階 8.5)。
    var allowsFileChanges: Bool { get }
    func canPerform(_ command: FileBrowserEditCommand) -> Bool
    func perform(_ command: FileBrowserEditCommand)
}

/// 対象は**いまの選択**(リストの選択は`state.selection`へ写してある)、行き先は表示中のフォルダ。
extension FileBrowserActions: FileBrowserEditResponding {
    func canPerform(_ command: FileBrowserEditCommand) -> Bool {
        guard let state else { return false }
        switch command {
        case .copy: return canModify(state.selectedEntries)
        case .cut, .moveToTrash: return canChange(state.selectedEntries)
        case .paste, .moveItemHere: return canPaste(into: state.currentFolder)
        case .goBack: return state.canGoBack
        case .goForward: return state.canGoForward
        case .goUp: return state.canGoUp
        }
    }

    func perform(_ command: FileBrowserEditCommand) {
        guard let state, canPerform(command) else { return }
        switch command {
        case .copy: copy(state.selectedEntries)
        case .cut: cut(state.selectedEntries)
        case .paste: paste(into: state.currentFolder)
        case .moveItemHere: paste(into: state.currentFolder, forceMove: true)
        case .moveToTrash: moveToTrash(state.selectedEntries)
        case .goBack: state.goBack()
        case .goForward: state.goForward()
        case .goUp: state.goUp()
        }
    }
}

/// 右クリックメニューの種類(要望の一覧どおり、フォルダ・ファイル・空きスペース・ツリーで並びが違う)。
/// **項目の数は選択の状態で変えない**(できない項目は淡色 ―― 計画 段階4)。
enum FileBrowserMenuKind {
    case folder
    case file
    /// 一覧の空きスペース。
    case background
    /// 左のツリーの行(共通の右クリックメニュー)。
    case tree

    /// 右クリックした項目から決める(複数選択でも、右クリックした 1 件の種類で決める)。
    static func of(_ entry: FileBrowserEntry) -> FileBrowserMenuKind {
        entry.isNavigableFolder ? .folder : .file
    }
}

/// 右クリックメニューの対象。
struct FileBrowserMenuContext {
    let kind: FileBrowserMenuKind
    let entries: [FileBrowserEntry]
    /// 「ペースト」「新規フォルダ」の行き先。一覧では表示中のフォルダ、ツリーではその行のフォルダ。
    let folder: URL?
}

/// 右クリックメニューの項目(リスト・アイコン・ツリーで共有)。
enum FileBrowserMenuCommand {
    case open
    case openInNewTab
    case openInNewNormalWindow
    case openInNewPrivateWindow
    case createCollection
    case addToCollection
    case openWith
    case rename
    case copy
    case cut
    case paste
    case newFolder
    case moveToTrash
    /// サブメニュー「圧縮」(ここに圧縮 / 保存先を選んで圧縮…)。
    case compress
    /// サブメニュー「展開」(ここに展開 / 「〈名前〉」に展開 / 展開先を選んで展開…)。
    case extract
    case compressHere
    case compressTo
    case extractHere
    case extractToFolder
    case extractTo
    case editMetadata
    case exportBook
    case addToFavoriteLocations
    case showInFinder

    /// 種類ごとの並び。内側の配列が区切り線で分かれる 1 群。
    static func groups(for kind: FileBrowserMenuKind) -> [[FileBrowserMenuCommand]] {
        switch kind {
        case .folder:
            [[.open, .openInNewTab, .openInNewNormalWindow, .openInNewPrivateWindow],
             [.createCollection, .addToCollection],
             [.openWith],
             [.rename, .copy, .cut, .paste, .newFolder],
             [.moveToTrash],
             [.compress],
             [.editMetadata, .exportBook],
             [.addToFavoriteLocations, .showInFinder]]
        case .file:
            [[.open, .openInNewTab, .openInNewNormalWindow, .openInNewPrivateWindow],
             [.createCollection, .addToCollection],
             [.openWith],
             [.rename, .copy, .cut, .paste],
             [.moveToTrash],
             [.compress, .extract],
             [.editMetadata, .exportBook],
             [.showInFinder]]
        case .tree:
            [[.open, .openInNewTab, .openInNewNormalWindow, .openInNewPrivateWindow],
             [.openWith],
             [.newFolder, .paste],
             [.addToFavoriteLocations, .showInFinder]]
        case .background:
            // 「表示」「表示順序」のサブメニューは組む側が足す(FileBrowserMenuBuilder / FileBrowserBackgroundMenuItems)。
            [[.paste, .newFolder]]
        }
    }

    var title: String.LocalizationValue {
        switch self {
        case .open: "Open"
        case .openInNewTab: "Open in New Tab"
        case .openInNewNormalWindow: "Open in New Normal Window"
        case .openInNewPrivateWindow: "Open in New Private Window"
        case .createCollection: "Create Collection"
        case .addToCollection: "Add to Collection"
        case .openWith: "Open With"
        case .rename: "Rename"
        case .copy: "Copy"
        case .cut: "Cut"
        case .paste: "Paste"
        case .newFolder: "New Folder"
        case .moveToTrash: "Move to Trash"
        case .compress: "Compress"
        case .extract: "Extract"
        case .compressHere: "Compress Here"
        case .compressTo: "Compress To…"
        case .extractHere: "Extract Here"
        case .extractToFolder: "Extract to Folder"
        case .extractTo: "Extract To…"
        case .editMetadata: "Edit Metadata…"
        case .exportBook: "Export Book"
        case .addToFavoriteLocations: "Add to Favorite Locations"
        case .showInFinder: "Show in Finder"
        }
    }

    /// 項目の表示名。複数を選んで右クリックしたときの「名前を変更」だけ、件数入りの「N 項目の名前を変更…」にする
    /// (Finder の「^0項目の名称変更…」。押すと一括リネームのシートが出る)。項目の数は変わらない。
    func title(in context: FileBrowserMenuContext, locale: Locale) -> String {
        if self == .rename, context.entries.count > 1 {
            return String(format: String(localized: "Rename %lld Items…", language: locale), context.entries.count)
        }
        // 「〈名前〉に展開」は作るフォルダの名前を出す(Finder の「アーカイブユーティリティ」は名前を見せずに作るので、何ができるか分からない)。
        if self == .extractToFolder {
            if context.entries.count == 1, let entry = context.entries.first {
                return String(
                    format: String(localized: "Extract to “%@”", language: locale), ArchiveExtractor.folderName(for: entry.url)
                )
            }
            return String(localized: "Extract Each to Its Own Folder", language: locale)
        }
        return String(localized: title, language: locale)
    }

    /// サブメニューの中身(サブメニューを持たない項目は nil)。
    var submenu: [FileBrowserMenuCommand]? {
        switch self {
        case .compress: [.compressHere, .compressTo]
        case .extract: [.extractHere, .extractToFolder, .extractTo]
        default: nil
        }
    }

    @MainActor
    func isEnabled(in context: FileBrowserMenuContext, actions: FileBrowserActions) -> Bool {
        let entries = context.entries
        switch self {
        case .open:
            // ファイルは本と画像だけ(要望)。フォルダは中へ(画像フォルダなら本として)。
            return !entries.isEmpty && entries.allSatisfy { $0.isNavigableFolder || $0.opensAsBook }
        case .openInNewTab, .openInNewNormalWindow, .openInNewPrivateWindow:
            return actions.canOpenInNewWindow(entries)
        case .createCollection, .addToCollection:
            // 保存データへの書き込みなので、シークレットウインドウでは淡色(決定事項 Q8)。
            return actions.allowsSaving && actions.canUseAsBooks(entries)
        case .openWith:
            return !entries.isEmpty && !entries.contains(where: \.isVolume)
        case .editMetadata:
            return actions.allowsSaving && actions.canUseAsSingleBook(entries)
        case .exportBook:
            return actions.canUseAsSingleBook(entries) && actions.state?.bookSheet == nil
        case .compress, .compressHere, .compressTo:
            return actions.canCompress(entries)
        case .extract, .extractHere, .extractToFolder, .extractTo:
            return actions.canExtract(entries)
        // 読み取り専用モードの間は、ファイルを変える項目を淡色にする(消さない ―― 項目の数を変えない。段階 8.5)。
        case .rename, .cut, .moveToTrash:
            return actions.canChange(entries)
        case .copy:
            return actions.canModify(entries)
        case .paste:
            return actions.canPaste(into: context.folder)
        case .newFolder:
            return actions.canCreateFolder(in: context.folder)
        case .addToFavoriteLocations:
            return actions.canAddToFavoriteLocations(entries)
        case .showInFinder:
            return !entries.isEmpty
        }
    }

    @MainActor
    func perform(in context: FileBrowserMenuContext, actions: FileBrowserActions) {
        let entries = context.entries
        switch self {
        case .open: actions.openFromMenu(entries)
        case .openInNewTab: entries.first.map { actions.open($0, in: .newTab) }
        case .openInNewNormalWindow: entries.first.map { actions.open($0, in: .newNormalWindow) }
        case .openInNewPrivateWindow: entries.first.map { actions.open($0, in: .newPrivateWindow) }
        case .createCollection: actions.createCollection(from: entries)
        case .editMetadata: actions.editMetadata(entries)
        // サブメニューを持つ項目(中身は submenu / dynamicChildren)。
        case .addToCollection, .openWith, .compress, .extract, .exportBook: break
        case .compressHere: actions.compress(entries, choosingDestination: false)
        case .compressTo: actions.compress(entries, choosingDestination: true)
        case .extractHere: actions.extract(entries, placement: .contents, choosingDestination: false)
        case .extractToFolder: actions.extract(entries, placement: .ownFolder, choosingDestination: false)
        case .extractTo: actions.extract(entries, placement: .contents, choosingDestination: true)
        case .rename: actions.beginRename(entries)
        case .copy: actions.copy(entries)
        case .cut: actions.cut(entries)
        case .paste: actions.paste(into: context.folder)
        case .newFolder: actions.newFolder(in: context.folder)
        case .moveToTrash: actions.moveToTrash(entries)
        case .addToFavoriteLocations: actions.addToFavoriteLocations(entries)
        case .showInFinder: actions.showInFinder(entries)
        }
    }
}

/// AppKitの一覧(リスト・ツリー)の右クリックメニューを組む。項目は`FileBrowserMenuCommand`に委ねる。
@MainActor
final class FileBrowserMenuBuilder: NSObject {
    private var context = FileBrowserMenuContext(kind: .background, entries: [], folder: nil)
    private weak var actions: FileBrowserActions?

    /// `menu`の中身を`context`向けに作り直す。空きスペースには「表示」「表示順序」のサブメニューも付ける。
    func rebuild(_ menu: NSMenu, for context: FileBrowserMenuContext, actions: FileBrowserActions?, locale: Locale) {
        menu.removeAllItems()
        // 既定の autoenablesItems = true は、対象がアクションに応答するだけで項目を有効にし、`isEnabled` を
        // 無視する(段階3から、淡色にしたはずの項目がすべて押せる状態だった。段階4の実機検証 2026-09-13)。
        menu.autoenablesItems = false
        self.context = context
        self.actions = actions
        guard let actions else { return }
        for group in FileBrowserMenuCommand.groups(for: context.kind) {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            for command in group {
                let item = menuItem(for: command, locale: locale, actions: actions)
                if let nodes = command.dynamicChildren(in: context, actions: actions, locale: locale) {
                    item.action = nil
                    item.submenu = Self.menu(from: nodes)
                } else if let children = command.submenu {
                    item.action = nil
                    let submenu = NSMenu()
                    submenu.autoenablesItems = false
                    for child in children {
                        submenu.addItem(menuItem(for: child, locale: locale, actions: actions))
                    }
                    item.submenu = submenu
                }
                menu.addItem(item)
            }
        }
        guard context.kind == .background, let state = actions.state else { return }
        menu.addItem(.separator())
        let view = NSMenu()
        for mode in FileBrowserViewMode.allCases {
            let item = NSMenuItem(title: String(localized: mode.menuTitle, language: locale),
                                  action: #selector(chooseViewMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = state.viewMode == mode ? .on : .off
            view.addItem(item)
        }
        let viewItem = NSMenuItem(title: String(localized: "View", language: locale), action: nil, keyEquivalent: "")
        viewItem.submenu = view
        menu.addItem(viewItem)

        let sort = NSMenu()
        for key in FolderBrowserSortKey.allCases {
            let item = NSMenuItem(title: String(localized: key.titleValue, language: locale),
                                  action: #selector(chooseSortKey(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = key.rawValue
            item.state = state.sortKey == key ? .on : .off
            sort.addItem(item)
        }
        sort.addItem(.separator())
        for direction in FolderBrowserSortDirection.allCases {
            let item = NSMenuItem(title: String(localized: direction.titleValue, language: locale),
                                  action: #selector(chooseSortDirection(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = direction.rawValue
            item.state = state.sortDirection == direction ? .on : .off
            sort.addItem(item)
        }
        let sortItem = NSMenuItem(title: String(localized: "Sort By", language: locale), action: nil, keyEquivalent: "")
        sortItem.submenu = sort
        menu.addItem(sortItem)
    }

    private func menuItem(for command: FileBrowserMenuCommand, locale: Locale, actions: FileBrowserActions) -> NSMenuItem {
        let item = NSMenuItem(
            title: command.title(in: context, locale: locale),
            action: #selector(performCommand(_:)), keyEquivalent: ""
        )
        item.target = self
        item.representedObject = CommandBox(command)
        item.isEnabled = command.isEnabled(in: context, actions: actions)
        return item
    }

    /// 場面で変わるサブメニュー(FileBrowserMenuNode)を NSMenu に。
    private static func menu(from nodes: [FileBrowserMenuNode]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for node in nodes {
            switch node {
            case .separator:
                menu.addItem(.separator())
            case .item(let title, let image, let isEnabled, let action):
                let item = NSMenuItem(title: title, action: #selector(MenuNodeBox.invokeAction(_:)), keyEquivalent: "")
                let box = MenuNodeBox(action)
                item.target = box
                // target は weak なので、箱は項目の representedObject に持たせて生かす。
                item.representedObject = box
                item.image = image
                item.isEnabled = isEnabled
                menu.addItem(item)
            case .submenu(let title, let isEnabled, let children):
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.submenu = Self.menu(from: children)
                item.isEnabled = isEnabled
                menu.addItem(item)
            }
        }
        return menu
    }

    /// 場面で変わる項目の閉包を NSMenuItem の target にするための箱。
    ///
    /// **action を `perform(_:)` と名付けない**(段階 8 の実機検証 2026-09-14)。NSObject の `perform(_:)`(`performSelector:`)と
    /// 名前がぶつかり、`#selector` がそちらを指して、項目を押しても何も起きなかった(テストはメニューを通らないので通っていた)。
    private final class MenuNodeBox: NSObject {
        let action: @MainActor () -> Void
        init(_ action: @escaping @MainActor () -> Void) { self.action = action }
        @objc func invokeAction(_ sender: NSMenuItem) { action() }
    }

    @objc private func performCommand(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? CommandBox, let actions else { return }
        box.command.perform(in: context, actions: actions)
    }

    @objc private func chooseViewMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = FileBrowserViewMode(rawValue: raw) else { return }
        actions?.state?.viewMode = mode
    }

    @objc private func chooseSortKey(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let key = FolderBrowserSortKey(rawValue: raw) else { return }
        actions?.state?.sortKey = key
    }

    @objc private func chooseSortDirection(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let direction = FolderBrowserSortDirection(rawValue: raw) else { return }
        actions?.state?.sortDirection = direction
    }

    /// 項目の`representedObject`に列挙型を載せるための箱。
    private final class CommandBox: NSObject {
        let command: FileBrowserMenuCommand
        init(_ command: FileBrowserMenuCommand) { self.command = command }
    }
}

/// SwiftUIの一覧(アイコン表示)の右クリックメニュー。AppKitの側と同じ項目・同じ並び。
///
/// **淡色のサブメニューは `Menu` ではなく押せない `Button` で描く**(`FileBrowserDisabledSubmenu`)。`.contextMenu` の中の `Menu` には
/// `.disabled` が効かない(2026-09-14、macOS 26.6 で実測。`.disabled` を `Menu` / `Group` / `Section` に付ける・`\.isEnabled` を入れる・
/// `menuStyle` を変える・`primaryAction` 付き、のどれも親項目は押せる見た目のままで、中の項目だけが淡色になった)。
/// 押せない `Button` は矢印が出ないが、項目の数は変わらない。
struct FileBrowserContextMenuItems: View {
    @Environment(\.locale) private var locale
    let context: FileBrowserMenuContext
    let actions: FileBrowserActions

    var body: some View {
        let groups = FileBrowserMenuCommand.groups(for: context.kind)
        ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
            if index > 0 { Divider() }
            ForEach(Array(group.enumerated()), id: \.offset) { _, command in
                item(for: command)
            }
        }
        if context.kind == .background, let state = actions.state {
            Divider()
            FileBrowserBackgroundMenuItems(state: state)
        }
    }

    @ViewBuilder
    private func item(for command: FileBrowserMenuCommand) -> some View {
        let nodes = command.dynamicChildren(in: context, actions: actions, locale: locale)
        if nodes != nil || command.submenu != nil, !command.isEnabled(in: context, actions: actions) {
            FileBrowserDisabledSubmenu(title: command.title(in: context, locale: locale))
        } else if let nodes {
            Menu(command.title(in: context, locale: locale)) {
                FileBrowserMenuNodeItems(nodes: nodes)
            }
        } else if let children = command.submenu {
            Menu(command.title(in: context, locale: locale)) {
                ForEach(Array(children.enumerated()), id: \.offset) { _, child in
                    button(for: child)
                }
            }
        } else {
            button(for: command)
        }
    }

    private func button(for command: FileBrowserMenuCommand) -> some View {
        Button(command.title(in: context, locale: locale)) {
            command.perform(in: context, actions: actions)
        }
        .disabled(!command.isEnabled(in: context, actions: actions))
    }
}

/// 場面で変わるサブメニューの中身(SwiftUI 版)。
private struct FileBrowserMenuNodeItems: View {
    let nodes: [FileBrowserMenuNode]

    var body: some View {
        ForEach(Array(nodes.enumerated()), id: \.offset) { _, node in
            switch node {
            case .separator:
                Divider()
            case .item(let title, let image, let isEnabled, let action):
                Button {
                    action()
                } label: {
                    if let image {
                        Label { Text(verbatim: title) } icon: { Image(nsImage: image) }
                    } else {
                        Text(verbatim: title)
                    }
                }
                .disabled(!isEnabled)
            case .submenu(let title, let isEnabled, let children):
                if isEnabled {
                    Menu {
                        FileBrowserMenuNodeItems(nodes: children)
                    } label: {
                        Text(verbatim: title)
                    }
                } else {
                    FileBrowserDisabledSubmenu(title: title)
                }
            }
        }
    }
}

/// 淡色のサブメニューの代わり(FileBrowserContextMenuItems の型コメント。`.contextMenu` の中の `Menu` は `.disabled` が効かない)。
private struct FileBrowserDisabledSubmenu: View {
    let title: String

    var body: some View {
        Button {} label: { Text(verbatim: title) }
            .disabled(true)
    }
}

/// 空きスペースの「表示」「表示順序」。
///
/// **`FileBrowserState` を強く掴まない**(2026-09-14 の監査 10)。`.contextMenu` の中身は AppKit のメニュー項目へ渡り、ウインドウより
/// 長生きしうる(CLAUDE.md の ViewerActionRelay の件)。以前は `@ObservedObject var state` の `$state.viewMode` を渡していて、
/// 閉じたウインドウの `FileBrowserState`(一覧の `entries`・取り消し履歴)を残しえた。Binding は state を weak で捕まえる閉包で作る。
/// メニューは開くたびに作り直されるので、観測しなくてもチェックは開いた時点の値で正しい。
private struct FileBrowserBackgroundMenuItems: View {
    @Environment(\.locale) private var locale
    private let viewMode: Binding<FileBrowserViewMode>
    private let sortKey: Binding<FolderBrowserSortKey>
    private let sortDirection: Binding<FolderBrowserSortDirection>

    init(state: FileBrowserState) {
        let currentMode = state.viewMode
        let currentKey = state.sortKey
        let currentDirection = state.sortDirection
        viewMode = Binding(get: { [weak state] in state?.viewMode ?? currentMode }, set: { [weak state] in state?.viewMode = $0 })
        sortKey = Binding(get: { [weak state] in state?.sortKey ?? currentKey }, set: { [weak state] in state?.sortKey = $0 })
        sortDirection = Binding(
            get: { [weak state] in state?.sortDirection ?? currentDirection }, set: { [weak state] in state?.sortDirection = $0 }
        )
    }

    var body: some View {
        Picker("View", selection: viewMode) {
            ForEach(FileBrowserViewMode.allCases, id: \.self) { mode in
                Text(String(localized: mode.menuTitle, language: locale)).tag(mode)
            }
        }
        .pickerStyle(.menu)
        Menu("Sort By") {
            Picker(selection: sortKey) {
                ForEach(FolderBrowserSortKey.allCases) { key in
                    Text(key.titleKey).tag(key)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
            Divider()
            Picker(selection: sortDirection) {
                ForEach(FolderBrowserSortDirection.allCases) { direction in
                    Text(direction.titleKey).tag(direction)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
        }
    }
}
