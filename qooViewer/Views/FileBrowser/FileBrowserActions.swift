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
    /// 自動リネーム(2026-09-15。FileBrowserAutoRenameActions.swift)。
    weak var autoRenameStore: AutoRenameStore?
    weak var autoRenameService: AutoRenameService?
    /// 「スマートライブラリの対象に追加」(2026-09-23。FileBrowserLibraryActions.swift)。
    weak var smartLibraryStore: SmartLibraryStore?

    /// シークレットウインドウでは保存を伴う操作(よく使う項目の登録・削除)を塞ぐ(決定事項 Q8)。
    var allowsSaving: Bool { !(appState?.isPrivateWindow ?? true) }

    // MARK: - 開く

    /// ダブルクリック / Return。フォルダは中へ移動する ―― 画像フォルダだけは環境設定
    /// (`fileBrowserImageFolderOpenAction`。既定はほかのフォルダと同じく中へ移動、2026-09-14 から選べる)に従う。
    /// 本と画像は qooViewer で開き、それ以外は既定のアプリで開く。
    ///
    /// 複数を選んでいるとき、フォルダは開かない(移動先は1つしか選べない)。本は
    /// `BookOpenRequest`の規則でまとめる(全部画像なら1冊、それ以外は先頭の1冊)。
    ///
    /// 返す Task は画像フォルダかどうかを調べて開くまで(テストの待ち合わせ用。調べないときは nil)。
    @discardableResult
    func open(_ entries: [FileBrowserEntry]) -> Task<Void, Never>? {
        guard state != nil else { return nil }
        // 何も起きない組み合わせ(複数のフォルダ・リンクを含む)なら鳴らす。黙っていると押しても何も起きないように見える。
        guard canOpen(entries) else {
            if !entries.isEmpty { NSSound.beep() }
            return nil
        }
        if entries.count == 1, let entry = entries.first, entry.isNavigableFolder {
            return openFolder(entry, fromMenu: false)
        }
        if entries.count == 1, let entry = entries.first, entry.isSymbolicLink {
            openSymbolicLink(entry)
            return nil
        }
        let books = entries.filter(\.opensAsBook).map(\.url)
        if !books.isEmpty {
            appState?.open(urls: books)
        }
        for entry in entries where !entry.opensAsBook && !entry.isNavigableFolder {
            NSWorkspace.shared.open(entry.url)
        }
        return nil
    }

    /// 「開く」(右クリック・メニューバー・⌘↓・Return・ダブルクリック)で何かが起きるか。**`open(_:)` の場合分けと同じ**
    /// (2026-09-19 の総点検。それまでの淡色の条件は「フォルダ・本・画像だけ」で、フォルダを 2 つ選ぶと押せるのに何も起きず、
    /// フォルダへのリンク・ふつうのファイルは淡色なのに Return では開けた)。
    /// - 1 件: 何でも開く(フォルダ・リンクは中へ、本と画像は qooViewer、それ以外は既定のアプリ)
    /// - 複数: フォルダ・リンクを含まないときだけ(中へ入れるのは 1 つずつ。本はまとめて開き、それ以外は既定のアプリ)
    func canOpen(_ entries: [FileBrowserEntry]) -> Bool {
        guard !entries.isEmpty else { return false }
        if entries.count == 1 { return true }
        return !entries.contains { $0.isNavigableFolder || $0.isSymbolicLink }
    }

    /// 右クリックの「開く」。画像フォルダでは**ダブルクリックと反対のことをする**(既定の設定なら本として開き、
    /// 「ビューアで開く」にしてあれば中へ移動する)。どちらの設定でも、もう片方の開き方がここに残る。
    @discardableResult
    func openFromMenu(_ entries: [FileBrowserEntry]) -> Task<Void, Never>? {
        guard entries.count == 1, let entry = entries.first, entry.isNavigableFolder else {
            return open(entries)
        }
        return openFolder(entry, fromMenu: true)
    }

    /// フォルダを開く。画像フォルダを本として開く側のときだけ、画像フォルダかどうかをここで1回だけ調べる
    /// (一覧の読み込みでは子フォルダの中を見ない。FileBrowserEntryの型コメント)。中へ移動する側なら調べずにすぐ移動する
    /// (既定のダブルクリックに待ちを足さない)。
    private func openFolder(_ entry: FileBrowserEntry, fromMenu: Bool) -> Task<Void, Never>? {
        guard let state else { return nil }
        let action = preferences?.fileBrowserImageFolderOpenAction ?? .openFolder
        guard action.opensAsBook(fromMenu: fromMenu) else {
            state.navigate(to: entry.url)
            return nil
        }
        let startFolder = state.currentFolder
        return Task { [weak self] in
            let isBook = await Self.isImageFolder(entry.url)
            guard let self, let state = self.state else { return }
            if isBook {
                self.appState?.open(url: entry.url)
            } else if state.currentFolder == startFolder {
                // 調べている間に別のフォルダへ移っていたら、後から引き戻さない。
                state.navigate(to: entry.url)
            }
        }
    }

    /// 新規タブ / 新規ノーマルウインドウ / 新規シークレットウインドウで開く。フォルダは画像フォルダなら
    /// 本として、それ以外はファイルブラウザとして開く。
    func open(_ entry: FileBrowserEntry, in destination: BookOpenDestination) {
        guard let openWindow, let launchCoordinator else { return }
        let source = appState
        if entry.isNavigableFolder {
            Task {
                if await Self.isImageFolder(entry.url) {
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

    /// Finder の「情報を見る」ウインドウを開く(2026-09-18。実体と経路の説明は `FinderReveal.showInfo`)。
    func showInfo(_ entries: [FileBrowserEntry]) {
        FinderReveal.showInfo(entries.map(\.url))
    }

    // MARK: - 書く操作(段階4。実体は FileBrowserOperations)

    /// ホームのライブラリ機能が有効か(環境設定「ライブラリを有効にする」)。OFFなら右クリックにコレクションの項目を出さず、
    /// 操作の入り口でも断る(`allowsSaving`と並べて確かめる)。
    var isLibraryFeatureEnabled: Bool {
        preferences?.libraryFeatureEnabled ?? true
    }

    /// スマートライブラリ機能が有効か(環境設定「スマートライブラリを有効にする」)。OFFなら右クリックに「スマートライブラリの対象に追加」を
    /// 出さず、操作の入り口でも断る(`isLibraryFeatureEnabled` と同じ扱い)。
    var isSmartLibraryFeatureEnabled: Bool {
        preferences?.smartLibraryFeatureEnabled ?? true
    }

    /// ファイルを変える操作ができるか(読み取り専用モードでない。段階 8.5)。項目を淡色にするための読み出しで、
    /// 断るのは `FileBrowserOperations` の入り口(ここで淡色にし忘れても、そこで止まる)。
    var allowsFileChanges: Bool {
        !(state?.operations.isReadOnly ?? true)
    }

    /// 選んだ項目がペーストボードへ載せられるか(ボリュームそのもの・コンピュータの行は運ばない)。⌘C はこれだけで決まる。
    func canModify(_ entries: [FileBrowserEntry]) -> Bool {
        !entries.isEmpty && !entries.contains(where: \.isVolume)
    }

    /// 選んだ項目のファイルそのものを変えられるか(カット・ゴミ箱・名前の変更)。**ビューアで開いている本(と、それを含むフォルダ)は
    /// 淡色** ―― `FileBrowserOperations` が断る(`refusesBecauseOpenInViewer`)ので、以前は名前を打ち終えてから断られた(2026-09-19 の総点検)。
    func canChange(_ entries: [FileBrowserEntry]) -> Bool {
        canWrite(entries) && !isOpenInViewer(entries)
    }

    /// 読み取り専用モードでなく、運べる項目か(圧縮・展開の前提。元のファイルは変えないので、開いている本でもよい)。
    private func canWrite(_ entries: [FileBrowserEntry]) -> Bool {
        allowsFileChanges && canModify(entries)
    }

    /// どれかがビューアで開いている本(またはそれを含む・その中にある)か。`FileBrowserOperations.openBookConflict` と同じ判定。
    func isOpenInViewer(_ entries: [FileBrowserEntry]) -> Bool {
        guard let operations = state?.operations else { return false }
        return FileBrowserOperations.openBookConflict(
            among: entries.map(\.url), openBookPaths: operations.openBookPaths()
        ) != nil
    }

    func copy(_ entries: [FileBrowserEntry]) {
        state?.operations.copy(entries)
    }

    func cut(_ entries: [FileBrowserEntry]) {
        state?.operations.cut(entries)
    }

    /// 「パス名をコピー」ができるか。ファイルに触らないので、ボリュームでも読み取り専用の間でもよい。
    func canCopyPathnames(_ entries: [FileBrowserEntry]) -> Bool {
        !entries.isEmpty
    }

    func copyPathnames(_ entries: [FileBrowserEntry]) {
        state?.operations.copyPathnames(entries)
    }

    func canPaste(into folder: URL?) -> Bool {
        canWriteInto(folder) && (state?.operations.canPaste ?? false)
    }

    /// 新規フォルダを作れるか。
    func canCreateFolder(in folder: URL?) -> Bool {
        canWriteInto(folder)
    }

    /// `folder` へ書き込む操作(ペースト・新規フォルダ)を出してよいか。**表示中のフォルダが読めていないときは淡色**
    /// (「アクセスを許可…」の案内が出ている・見つからない。書いても失敗してダイアログが出るだけだった ―― 2026-09-19 の総点検)。
    /// ツリーの行のフォルダは右ペインの読み込みと関係しないので、表示中のフォルダのときだけ見る。
    func canWriteInto(_ folder: URL?) -> Bool {
        guard allowsFileChanges, let folder else { return false }
        if let state, state.loadError != nil, folder == state.currentFolder { return false }
        return true
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
        guard canWrite(entries), let parent = entries.first?.url.deletingLastPathComponent() else { return false }
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
        panel.directoryURL = favoriteLocationPanelStartDirectory()
        panel.prompt = String(localized: "Add", language: locale)
        panel.message = String(
            localized: "Choose a folder to add to Favorite Locations. qooViewer can then show the files in it.",
            language: locale
        )
        guard panel.runModal() == .OK, let granted = panel.url else { return }
        folderAccess?.add(url: granted)
        favoriteLocations?.add(granted)
        state?.navigate(to: granted)
        // 次の「＋」は**パネルを閉じた時点で見ていた場所**から始める(2026-09-15、ユーザー判断)。FolderB の中まで入って
        // 何も選ばずに「追加」したなら FolderB の中から。
        // 以前の案は「足したフォルダの親」(granted.deletingLastPathComponent())で、入ってから追加しても FolderA に
        // 戻る。要望があればそちらへ戻すかもしれないので、戻すときはこの右辺を親に替えるだけでよい。
        state?.lastAddedFavoriteLocation = (granted, panel.directoryURL ?? granted.deletingLastPathComponent())
    }

    /// 「＋」のパネルをどこから始めるか。基本は一覧で見ているフォルダ。ただし直前の「＋」で足したフォルダへ移動したまま
    /// なら、そのときパネルを閉じた場所から始める ―― FolderA の中で FolderB を選んで足した後、次の「＋」が FolderB の
    /// 中で開かないように(FileBrowserState.lastAddedFavoriteLocation)。一覧を別の場所へ動かしたら今のフォルダに戻る。
    private func favoriteLocationPanelStartDirectory() -> URL? {
        guard let state else { return nil }
        if let last = state.lastAddedFavoriteLocation,
           FileBrowserState.id(of: state.currentFolder) == FileBrowserState.id(of: FileBrowserState.folderURL(last.added)) {
            return last.panelDirectory
        }
        return state.currentFolder
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

    /// ツリーのドラッグでよく使う項目を並べ替える(2026-09-14、ユーザー要望)。登録・削除と同じく、並びも保存されるので
    /// シークレットウインドウでは断る。読み取り専用モードとは関係しない(ファイルは変わらない)。
    func moveFavoriteLocation(id: UUID, to destination: Int) {
        guard allowsSaving else { return }
        favoriteLocations?.move(id: id, to: destination)
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

    /// 画像フォルダ(それ自体が1冊の本)か。棚への登録と同じ規則を、子フォルダの中を全部読まず、保護下の場所にも入らずに
    /// FileIOの上で(ShelfFolderResolver.isSingleBookFolder。2026-09-14 の 2 回目の監査 15 ―― 以前は `role` がホームで
    /// 「書類」などの中まで読み、ダブルクリックや右クリックの「開く」だけで許可のダイアログが出た)。
    private nonisolated static func isImageFolder(_ url: URL) async -> Bool {
        await FileIO.perform { ShelfFolderResolver.isSingleBookFolder(url) }
    }
}

/// キーと編集メニューから届く操作(段階4)。リスト(`FileBrowserTableView`)とアイコン表示が同じ口へ渡す。
enum FileBrowserEditCommand {
    case copy, cut, paste
    /// ⌥⌘C「パス名をコピー」(Finder と同じキー。2026-09-21)。
    case copyPathname
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
        case (8, [.command, .option]): return .copyPathname       // ⌥⌘C
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
        case .copyPathname: return canCopyPathnames(state.selectedEntries)
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
        case .copyPathname: copyPathnames(state.selectedEntries)
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
    /// ⌥ を押している間の「このアプリケーションで開く」(`optionAlternate`)。
    case alwaysOpenWith
    case rename
    case copy
    /// ⌥ を押している間の「コピー」(`optionAlternate`)。
    case copyPathname
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
    /// 「スマートライブラリの対象に追加」(2026-09-23、利用者の指示)。本(画像フォルダ)でないフォルダだけ ―― 本かどうかは
    /// 選んだときに調べる(FileBrowserActions.addToSmartLibrary)。
    case addToSmartLibrary
    /// サブメニュー「自動リネーム」(規則ごとのチェック・このフォルダの規則を作る・設定を開く。2026-09-15)。
    case autoRename
    case showInFinder
    /// Finder の「情報を見る」(FileBrowserActions.showInfo。2026-09-18)。
    case getInfo

    /// 種類ごとの並び。内側の配列が区切り線で分かれる 1 群。
    ///
    /// - Parameters:
    ///   - includesLibrary: false なら「コレクションを作成」「コレクションに登録」の群を省く(環境設定「ライブラリを有効にする」がOFF。
    ///     2026-09-21)。選択の状態で項目の数を変えない決まりとは別の話 ―― 機能そのものが無いので、淡色で残さずに消す。
    ///   - includesSmartLibrary: false なら「スマートライブラリの対象に追加」を省く(「スマートライブラリを有効にする」がOFF。同じ理由)。
    static func groups(
        for kind: FileBrowserMenuKind, includesLibrary: Bool = true, includesSmartLibrary: Bool = true
    ) -> [[FileBrowserMenuCommand]] {
        let groups = allGroups(for: kind)
        guard !includesLibrary || !includesSmartLibrary else { return groups }
        return groups
            .map { group in
                group.filter { command in
                    switch command {
                    case .createCollection, .addToCollection: includesLibrary
                    case .addToSmartLibrary: includesSmartLibrary
                    default: true
                    }
                }
            }
            .filter { !$0.isEmpty }
    }

    private static func allGroups(for kind: FileBrowserMenuKind) -> [[FileBrowserMenuCommand]] {
        switch kind {
        case .folder:
            [[.open, .openInNewTab, .openInNewNormalWindow, .openInNewPrivateWindow],
             [.createCollection, .addToCollection],
             [.openWith],
             [.rename, .copy, .cut, .paste, .newFolder],
             [.moveToTrash],
             [.compress],
             [.editMetadata, .exportBook],
             [.addToFavoriteLocations, .addToSmartLibrary, .autoRename, .showInFinder, .getInfo]]
        case .file:
            [[.open, .openInNewTab, .openInNewNormalWindow, .openInNewPrivateWindow],
             [.createCollection, .addToCollection],
             [.openWith],
             [.rename, .copy, .cut, .paste],
             [.moveToTrash],
             [.compress, .extract],
             [.editMetadata, .exportBook],
             [.showInFinder, .getInfo]]
        case .tree:
            [[.open, .openInNewTab, .openInNewNormalWindow, .openInNewPrivateWindow],
             [.openWith],
             [.newFolder, .paste],
             [.addToFavoriteLocations, .addToSmartLibrary, .autoRename, .showInFinder, .getInfo]]
        case .background:
            // 「表示」「表示順序」のサブメニューは組む側が足す(FileBrowserMenuBuilder)。
            [[.paste, .newFolder]]
        }
    }

    /// 右クリックメニューを開いたまま ⌥ を押している間、この項目と入れ替わる項目(Finder と同じ。2026-09-21)。
    /// AppKit の「代わりの項目」(`NSMenuItem.isAlternate`)で組むので、入れ替わっても**見えている項目の数は変わらない**。
    /// `groups(for:)` には載せない ―― 元の項目のすぐ後ろに、組む側(FileBrowserMenuBuilder)が足す。
    var optionAlternate: FileBrowserMenuCommand? {
        switch self {
        case .copy: .copyPathname
        case .openWith: .alwaysOpenWith
        default: nil
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
        case .alwaysOpenWith: "Always Open With"
        case .rename: "Rename"
        case .copy: "Copy"
        case .copyPathname: "Copy as Pathname"
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
        case .addToSmartLibrary: "Add to Smart Library Targets"
        case .autoRename: "Auto Rename"
        case .showInFinder: "Show in Finder"
        case .getInfo: "Get Info"
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
            // Return・ダブルクリックと同じ判定(canOpen)。段階 4a では「ファイルは本と画像だけ」(要望)だったが、Return では
            // ほかのファイルも既定のアプリで開けたので、2026-09-19 にユーザー判断でそちらへ揃えた。フォルダは中へ
            // (画像フォルダはダブルクリックの反対。openFromMenu)。
            return actions.canOpen(entries)
        case .openInNewTab, .openInNewNormalWindow, .openInNewPrivateWindow:
            return actions.canOpenInNewWindow(entries)
        case .createCollection, .addToCollection:
            // 保存データへの書き込みなので、シークレットウインドウでは淡色(決定事項 Q8)。ライブラリ機能がOFFなら項目ごと出ない。
            return actions.isLibraryFeatureEnabled && actions.allowsSaving && actions.canUseAsBooks(entries)
        case .openWith:
            return !entries.isEmpty && !entries.contains(where: \.isVolume)
        case .alwaysOpenWith:
            return actions.canAlwaysOpenWith(entries)
        case .copyPathname:
            return actions.canCopyPathnames(entries)
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
        case .addToSmartLibrary:
            return actions.canAddToSmartLibrary(entries)
        case .autoRename:
            // 親はフォルダ 1 つ・保存できるウインドウなら開ける。中の項目は autoRenameMenuNodes が 1 つずつ決める(2026-09-19)。
            return actions.canShowAutoRenameMenu(entries)
        case .showInFinder, .getInfo:
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
        case .addToCollection, .openWith, .alwaysOpenWith, .compress, .extract, .exportBook, .autoRename: break
        case .compressHere: actions.compress(entries, choosingDestination: false)
        case .compressTo: actions.compress(entries, choosingDestination: true)
        case .extractHere: actions.extract(entries, placement: .contents, choosingDestination: false)
        case .extractToFolder: actions.extract(entries, placement: .ownFolder, choosingDestination: false)
        case .extractTo: actions.extract(entries, placement: .contents, choosingDestination: true)
        case .rename: actions.beginRename(entries)
        case .copy: actions.copy(entries)
        case .copyPathname: actions.copyPathnames(entries)
        case .cut: actions.cut(entries)
        case .paste: actions.paste(into: context.folder)
        case .newFolder: actions.newFolder(in: context.folder)
        case .moveToTrash: actions.moveToTrash(entries)
        case .addToFavoriteLocations: actions.addToFavoriteLocations(entries)
        case .addToSmartLibrary: actions.addToSmartLibrary(entries)
        case .showInFinder: actions.showInFinder(entries)
        case .getInfo: actions.showInfo(entries)
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
        for group in FileBrowserMenuCommand.groups(
            for: context.kind, includesLibrary: actions.isLibraryFeatureEnabled,
            includesSmartLibrary: actions.isSmartLibraryFeatureEnabled
        ) {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            for command in group {
                menu.addItem(fullMenuItem(for: command, locale: locale, actions: actions))
                // ⌥ を押している間だけ入れ替わる項目(Finder と同じ)。AppKit の決まり: 元の項目の**すぐ後ろ**に置き、
                // キーは同じ(どちらも無し)で修飾キーだけ違える。メニューを開いたまま ⌥ を押す・離すと、その場で入れ替わる。
                if let alternate = command.optionAlternate {
                    let item = fullMenuItem(for: alternate, locale: locale, actions: actions)
                    item.isAlternate = true
                    item.keyEquivalentModifierMask = [.option]
                    menu.addItem(item)
                }
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

    /// 1 項目ぶん(サブメニューを持つものは中身ごと)。
    private func fullMenuItem(for command: FileBrowserMenuCommand, locale: Locale, actions: FileBrowserActions) -> NSMenuItem {
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
        return item
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

    /// 場面で変わるサブメニュー(FileBrowserMenuNode)を NSMenu に。スマートライブラリのリストの右クリックも使う。
    static func menu(from nodes: [FileBrowserMenuNode]) -> NSMenu {
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
                item.showsImageOnMacOS27()
                item.isEnabled = isEnabled
                menu.addItem(item)
            case .toggle(let title, let isOn, let isEnabled, let action):
                let item = NSMenuItem(title: title, action: #selector(MenuNodeBox.invokeAction(_:)), keyEquivalent: "")
                let box = MenuNodeBox(action)
                item.target = box
                item.representedObject = box
                item.state = isOn ? .on : .off
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

/// 場面で変わるサブメニューの中身(SwiftUI 版)。
struct FileBrowserMenuNodeItems: View {
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
                        // macOS 27 SDK ではメニューの画像が既定で隠れる(NSMenuItem.showsImageOnMacOS27 のコメント)。
                        // SwiftUI 側は`.titleAndIcon`で表示を指定する(macOS 27 のリリースノートが示す方法)。
                        Label { Text(verbatim: title) } icon: { Image(nsImage: image) }
                            .labelStyle(.titleAndIcon)
                    } else {
                        Text(verbatim: title)
                    }
                }
                .disabled(!isEnabled)
            case .toggle(let title, let isOn, let isEnabled, let action):
                // Toggle の `set` は渡される値を使わない(HomeMenuItems の型コメント)。
                Toggle(isOn: Binding(get: { isOn }, set: { _ in action() })) {
                    Text(verbatim: title)
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

/// 淡色のサブメニューの代わり。**SwiftUI の `.contextMenu` の中の `Menu` には `.disabled` が効かない**(2026-09-14、macOS 26.6 で実測。
/// `.disabled` を `Menu` / `Group` / `Section` に付ける・`\.isEnabled` を入れる・`menuStyle` を変える・`primaryAction` 付き、のどれも親項目は
/// 押せる見た目のままで、中の項目だけが淡色になった)。押せない `Button` は矢印が出ないが、項目の数は変わらない。
/// ファイルブラウザのアイコン表示は 2026-09-15 に AppKit のメニューへ移ったので、使うのはコレクションの中の右クリック。
struct FileBrowserDisabledSubmenu: View {
    let title: String

    var body: some View {
        Button {} label: { Text(verbatim: title) }
            .disabled(true)
    }
}

extension NSMenuItem {
    /// 画像を必ず表示させる。`FileBrowserMenuNode.item`の画像(「このアプリケーションで開く」のアプリアイコン)用。
    ///
    /// ■ macOS 27 SDK でリンクするとメニューの画像が既定で隠れる(2026-09-18、実機で確認)
    /// macOS 27 から、メニューバーと右クリックメニューの項目の画像は AppKit が表示するかどうかを決め、
    /// 既定では隠す。SF Symbols は 26 SDK 以降でリンクしたアプリから、アプリアイコンのような普通の画像も
    /// **27 SDK でリンクしたアプリから**隠れる(macOS 27 リリースノート 170477566 / 179374305)。
    /// Finder の「このアプリケーションで開く」は 27 でもアイコン付きなので、それに揃えて表示を指定する。
    /// SF Symbols の項目(ほかのメニュー)は OS の新しい既定に任せ、ここは通さない。
    ///
    /// `preferredImageVisibility`は macOS 27 SDK にしかないので、`#if compiler`で 26 SDK(CI の Xcode 26.6)の
    /// ビルドから外す。26 SDK でリンクしたビルドは普通の画像が隠れないので、外れても見た目は変わらない。
    func showsImageOnMacOS27() {
        #if compiler(>=6.4)
        if #available(macOS 27.0, *) {
            preferredImageVisibility = .visible
        }
        #endif
    }
}
