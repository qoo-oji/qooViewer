import AppKit

/// `NSMenu.didBeginTrackingNotification`が、メニューバー(NSApp.mainMenu)のメニューによるものか
/// どうかを判定する。
///
/// FavoritesStore/RecentFilesStore/BookmarkStoreは、いずれも「メニューバーに出す一覧を開く直前に
/// 念のため最新化する」ための保険として、この通知を購読してreload()を呼んでいる
/// (それぞれのmenuTrackingObserver参照)。
///
/// ところがこの通知は、メニューバーだけでなく**アプリ内のあらゆるNSMenu**が開かれるたびに飛ぶ。
/// SwiftUIのPicker/Menu(ドロップダウン)も内部的にはNSMenuのため、例えば「ブックマーク・レイアウトの
/// 編集」ウインドウの並べ替えドロップダウンを開いただけで、3つのストアのreload()が同時に走って
/// いた(ユーザー報告: 並べ替えのドロップダウンが一瞬残像のように残る。sampleで実測したところ、
/// Bookmarkテーブルの全件フェッチと、履歴のセキュリティスコープ付きブックマーク解決+ファイル
/// 存在確認のディスクI/Oが、メニューを閉じる描画をメインスレッド上で止めていた)。
///
/// 保険の目的からすると、対象はメニューバーのメニューだけで足りる(これらの一覧はいずれも
/// メニューバーにしか出ない)。ウインドウ内のポップアップでは何もしない。
@MainActor
enum MenuBarTracking {
    static func isMainMenu(_ notification: Notification) -> Bool {
        guard let menu = notification.object as? NSMenu, let mainMenu = NSApp.mainMenu else {
            return false
        }
        // メニューバー直下のメニュー(「ファイル」「表示」など)とその下のサブメニューは、
        // supermenuを辿るとNSApp.mainMenuに行き着く。ウインドウ内のPicker/Menuのポップアップや
        // コンテキストメニューはこの連鎖に含まれないため、ここでfalseになる。
        var current: NSMenu? = menu
        while let candidate = current {
            if candidate === mainMenu { return true }
            current = candidate.supermenu
        }
        return false
    }
}
