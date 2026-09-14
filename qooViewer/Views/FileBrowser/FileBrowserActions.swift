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
    var openWindow: OpenWindowAction?

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

    /// 書く操作ができる項目か(ボリュームそのもの・コンピュータの行は動かさない)。
    func canModify(_ entries: [FileBrowserEntry]) -> Bool {
        !entries.isEmpty && !entries.contains(where: \.isVolume)
    }

    func copy(_ entries: [FileBrowserEntry]) {
        state?.operations.copy(entries)
    }

    func cut(_ entries: [FileBrowserEntry]) {
        state?.operations.cut(entries)
    }

    func canPaste(into folder: URL?) -> Bool {
        folder != nil && (state?.operations.canPaste ?? false)
    }

    func paste(into folder: URL?, forceMove: Bool = false) {
        guard let folder else { return }
        state?.operations.paste(into: folder, forceMove: forceMove)
    }

    func moveToTrash(_ entries: [FileBrowserEntry]) {
        guard canModify(entries) else { return }
        state?.operations.moveToTrash(entries)
    }

    func newFolder(in folder: URL?) {
        guard let folder else { return }
        state?.operations.newFolder(in: folder)
    }

    /// 右クリックの「名前を変更」。1 件なら一覧に名前の編集を始めてもらい、複数なら一括リネームのシートを出す(段階 5。Finder と同じ)。
    func beginRename(_ entries: [FileBrowserEntry]) {
        guard canModify(entries) else { return }
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
    func canPerform(_ command: FileBrowserEditCommand) -> Bool
    func perform(_ command: FileBrowserEditCommand)
}

/// 対象は**いまの選択**(リストの選択は`state.selection`へ写してある)、行き先は表示中のフォルダ。
extension FileBrowserActions: FileBrowserEditResponding {
    func canPerform(_ command: FileBrowserEditCommand) -> Bool {
        guard let state else { return false }
        switch command {
        case .copy, .cut, .moveToTrash: return canModify(state.selectedEntries)
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
    case compress
    case extract
    case editMetadata
    case exportBook
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
             [.showInFinder]]
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
             [.showInFinder]]
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
        case .editMetadata: "Edit Metadata…"
        case .exportBook: "Export Book"
        case .showInFinder: "Show in Finder"
        }
    }

    /// 項目の表示名。複数を選んで右クリックしたときの「名前を変更」だけ、件数入りの「N 項目の名前を変更…」にする
    /// (Finder の「^0項目の名称変更…」。押すと一括リネームのシートが出る)。項目の数は変わらない。
    func title(in context: FileBrowserMenuContext, locale: Locale) -> String {
        if self == .rename, context.entries.count > 1 {
            return String(format: String(localized: "Rename %lld Items…", language: locale), context.entries.count)
        }
        return String(localized: title, language: locale)
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
        case .createCollection, .addToCollection, .openWith, .editMetadata, .exportBook:
            // 段階8で既存機能とつなぐ。それまでは淡色で置く(項目の数を変えない)。
            return false
        case .compress, .extract:
            // 段階6。
            return false
        case .rename:
            return actions.canModify(entries)
        case .copy, .cut, .moveToTrash:
            return actions.canModify(entries)
        case .paste:
            return actions.canPaste(into: context.folder)
        case .newFolder:
            return context.folder != nil
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
        case .createCollection, .addToCollection, .openWith, .compress, .extract, .editMetadata, .exportBook: break
        case .rename: actions.beginRename(entries)
        case .copy: actions.copy(entries)
        case .cut: actions.cut(entries)
        case .paste: actions.paste(into: context.folder)
        case .newFolder: actions.newFolder(in: context.folder)
        case .moveToTrash: actions.moveToTrash(entries)
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
                let item = NSMenuItem(
                    title: command.title(in: context, locale: locale),
                    action: #selector(performCommand(_:)), keyEquivalent: ""
                )
                item.target = self
                item.representedObject = CommandBox(command)
                item.isEnabled = command.isEnabled(in: context, actions: actions)
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
struct FileBrowserContextMenuItems: View {
    @Environment(\.locale) private var locale
    let context: FileBrowserMenuContext
    let actions: FileBrowserActions

    var body: some View {
        let groups = FileBrowserMenuCommand.groups(for: context.kind)
        ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
            if index > 0 { Divider() }
            ForEach(Array(group.enumerated()), id: \.offset) { _, command in
                Button(command.title(in: context, locale: locale)) {
                    command.perform(in: context, actions: actions)
                }
                .disabled(!command.isEnabled(in: context, actions: actions))
            }
        }
        if context.kind == .background, let state = actions.state {
            Divider()
            FileBrowserBackgroundMenuItems(state: state)
        }
    }
}

/// 空きスペースの「表示」「表示順序」。
private struct FileBrowserBackgroundMenuItems: View {
    @Environment(\.locale) private var locale
    @ObservedObject var state: FileBrowserState

    var body: some View {
        Picker("View", selection: $state.viewMode) {
            ForEach(FileBrowserViewMode.allCases, id: \.self) { mode in
                Text(String(localized: mode.menuTitle, language: locale)).tag(mode)
            }
        }
        .pickerStyle(.menu)
        Menu("Sort By") {
            Picker(selection: $state.sortKey) {
                ForEach(FolderBrowserSortKey.allCases) { key in
                    Text(key.titleKey).tag(key)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
            Divider()
            Picker(selection: $state.sortDirection) {
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
