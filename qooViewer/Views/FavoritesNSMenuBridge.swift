import AppKit

/// ツールバーの「お気に入り一覧」をネイティブのNSMenuとして表示するための橋渡し役。
///
/// メニューバー側(QooViewerApp.swiftのCommandMenu("Favorites")内のMenu("Favorites List"))は、
/// SwiftUIのMenu同士をネストするだけで、ホバーするだけでサブメニューが展開する本来のNSMenuの
/// 挙動がそのまま手に入る(FavoritesMenuContent.swift参照)。
///
/// しかしツールバー側は、ボタンのクリックだけでなくキーボードショートカット
/// (ViewerAction.showFavoritesList)からもプログラム的に一覧を開けるようにする必要があり、
/// SwiftUIのMenuには「コードから開く」ためのAPI(.popover(isPresented:)のような仕組み)が
/// 無いため、SwiftUIのMenuをそのままツールバーへ使うことができない。
/// (以前はList+DisclosureGroupの独自実装(FavoritesListPopoverContent.swift。現在は未使用だが
/// 参考として残してある)で代替していたが、フォルダを開くたびにクリックが必要で、
/// メニューバー側のようにホバーだけでサブフォルダが展開する使い勝手にはならなかった)。
///
/// そこで、AppKitのNSMenuを直接組み立て、`popUp(positioning:at:in:)`で表示することで、
/// ボタンクリック・キーボードショートカットのどちらから呼び出しても、メニューバー側と同じ
/// 「ホバーで展開するネイティブのお気に入り一覧」を表示できるようにする。
@MainActor
final class FavoritesNSMenuBridge: NSObject {
    private let favoritesStore: FavoritesStore
    private let onOpen: (FavoriteBook) -> Void

    init(favoritesStore: FavoritesStore, onOpen: @escaping (FavoriteBook) -> Void) {
        self.favoritesStore = favoritesStore
        self.onOpen = onOpen
        super.init()
    }

    /// 現在のマウス位置(画面座標)にお気に入り一覧のメニューを表示する。
    /// ボタンのクリック・キーボードショートカットのどちらから呼んでも、「今マウスがある場所」に
    /// 表示するという単純な方針にしている(popUp自体は表示中ずっとブロックする同期呼び出しのため、
    /// このメソッドの呼び出し元は、メニューが閉じるまで処理がここで止まることに注意)。
    @discardableResult
    func show() -> Bool {
        let menu = buildMenu()
        return menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        populate(menu, folders: favoritesStore.rootFolders, books: favoritesStore.rootBooks)
        if menu.items.isEmpty {
            let empty = NSMenuItem(title: String(localized: "(No Favorites)"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        return menu
    }

    /// フォルダ・お気に入りの一覧を、指定したNSMenuへ再帰的に追加していく。
    /// (SwiftUI版のFavoritesMenuContent/FavoriteFolderMenuと同じ考え方だが、NSMenuItemを
    /// 直接組み立てるため、`some View`の再帰呼び出し制約は関係なく、通常の再帰関数でよい)
    private func populate(_ menu: NSMenu, folders: [FavoriteFolder], books: [FavoriteBook]) {
        for folder in folders {
            let folderItem = NSMenuItem(title: folder.name, action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            let subfolders = favoritesStore.subfolders(of: folder)
            let subbooks = favoritesStore.books(in: folder)
            if subfolders.isEmpty && subbooks.isEmpty {
                let empty = NSMenuItem(title: String(localized: "(Empty)"), action: nil, keyEquivalent: "")
                empty.isEnabled = false
                submenu.addItem(empty)
            } else {
                populate(submenu, folders: subfolders, books: subbooks)
            }
            folderItem.submenu = submenu
            menu.addItem(folderItem)
        }
        for favorite in books {
            let item = NSMenuItem(title: favorite.title, action: #selector(selectFavorite(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = favorite
            menu.addItem(item)
        }
    }

    @objc private func selectFavorite(_ sender: NSMenuItem) {
        guard let favorite = sender.representedObject as? FavoriteBook else { return }
        onOpen(favorite)
    }
}
