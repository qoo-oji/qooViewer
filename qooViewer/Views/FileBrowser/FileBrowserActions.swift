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

/// 右クリックメニューの項目(3つの一覧で同じ並び)。
enum FileBrowserMenuCommand: CaseIterable {
    case open
    case openInNewTab
    case openInNewNormalWindow
    case openInNewPrivateWindow
    case showInFinder

    /// 区切り線を**この項目の前に**入れる。
    var startsGroup: Bool {
        switch self {
        case .openInNewTab, .showInFinder: true
        default: false
        }
    }

    var title: String.LocalizationValue {
        switch self {
        case .open: "Open"
        case .openInNewTab: "Open in New Tab"
        case .openInNewNormalWindow: "Open in New Normal Window"
        case .openInNewPrivateWindow: "Open in New Private Window"
        case .showInFinder: "Show in Finder"
        }
    }

    /// 1件用の項目を複数選択中に淡色にする(**項目の数は状態で変えない** ―― 計画 段階4)。
    @MainActor
    func isEnabled(for entries: [FileBrowserEntry], actions: FileBrowserActions) -> Bool {
        switch self {
        case .open, .showInFinder:
            return !entries.isEmpty
        case .openInNewTab, .openInNewNormalWindow, .openInNewPrivateWindow:
            return actions.canOpenInNewWindow(entries)
        }
    }

    @MainActor
    func perform(on entries: [FileBrowserEntry], actions: FileBrowserActions) {
        switch self {
        case .open: actions.openFromMenu(entries)
        case .openInNewTab: entries.first.map { actions.open($0, in: .newTab) }
        case .openInNewNormalWindow: entries.first.map { actions.open($0, in: .newNormalWindow) }
        case .openInNewPrivateWindow: entries.first.map { actions.open($0, in: .newPrivateWindow) }
        case .showInFinder: actions.showInFinder(entries)
        }
    }
}

/// AppKitの一覧(リスト・ツリー)の右クリックメニューを組む。項目は`FileBrowserMenuCommand`に委ねる。
@MainActor
final class FileBrowserMenuBuilder: NSObject {
    private var targets: [FileBrowserEntry] = []
    private weak var actions: FileBrowserActions?

    /// `menu`の中身を`entries`向けに作り直す。
    func rebuild(_ menu: NSMenu, for entries: [FileBrowserEntry], actions: FileBrowserActions?, locale: Locale) {
        menu.removeAllItems()
        targets = entries
        self.actions = actions
        guard let actions, !entries.isEmpty else { return }
        for command in FileBrowserMenuCommand.allCases {
            if command.startsGroup, !menu.items.isEmpty { menu.addItem(.separator()) }
            let item = NSMenuItem(
                title: String(localized: command.title, language: locale),
                action: #selector(performCommand(_:)), keyEquivalent: ""
            )
            item.target = self
            item.representedObject = CommandBox(command)
            item.isEnabled = command.isEnabled(for: entries, actions: actions)
            menu.addItem(item)
        }
    }

    @objc private func performCommand(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? CommandBox, let actions else { return }
        box.command.perform(on: targets, actions: actions)
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
    let entries: [FileBrowserEntry]
    let actions: FileBrowserActions

    var body: some View {
        ForEach(Array(FileBrowserMenuCommand.allCases.enumerated()), id: \.offset) { index, command in
            if command.startsGroup, index > 0 { Divider() }
            Button(String(localized: command.title, language: locale)) {
                command.perform(on: entries, actions: actions)
            }
            .disabled(!command.isEnabled(for: entries, actions: actions))
        }
    }
}
