import AppKit

/// キーウインドウにタブがあるときに AppKit がファイルメニューへ足す「ウインドウを閉じる」⇧⌘W を、環境設定「複数のタブが開いている
/// ウインドウを閉じるときに確認する」を通す閉じ方(BookClosingWindowDelegate.closeWindowWithAllTabs)へつなぐ。アプリ全体で 1 つ(shared)。
///
/// ■ AppKit の標準の閉じる項目(2026-09-27、アプリ内でメニューの項目を書き出して実測。macOS 27。AX で読む名前は古いまま残ることがあり、
///   判定に使えなかった)
/// - タブの無いウインドウ: ⌘W「閉じる」(`performClose:`)、⌥ で「すべてを閉じる」(`closeAll:`)。一度タブを使ったあとは、AppKit が
///   ⌘W の名前を「ウインドウを閉じる」にする(Finder と同じ)
/// - タブのあるウインドウ: AppKit が ⌘W を「タブを閉じる」にし、その上に「ウインドウを閉じる」⇧⌘W(`performCloseTabbedWindowGroup:`)と
///   ⌥ の「すべてを閉じる」を足す。⌘W の ⌥ は「その他のタブを閉じる」になる。項目はメニューが開くとき・キーを押したときに作り直される
/// つまり監査(docs/plans/macos-conventions-audit-2026-09-26.md)の 8・9 が求めた並びと名前は、AppKit が標準で出している。自前の
/// 「ウインドウを閉じる」(2026-09-26 に「ウインドウ」メニューへ足したもの)は、ファイルメニューへ移すと同じ名前が 2 つ並ぶ(タブが無いと
/// ⌘W も「ウインドウを閉じる」と名乗る)ので、やめて AppKit の項目を使う。
///
/// ■ 何をつなぎ替えるか
/// AppKit の「ウインドウを閉じる」は確認を出さずにタブをすべて閉じる(実測)。そこで AppKit がこの項目を足したとき
/// (`NSMenu.didAddItemNotification`。同期で届くので、表示やキー入力の照合より前)に、送り先(target)だけをこのオブジェクトにする。
/// action は変えない ―― AppKit はタブが無くなったときに自分の項目を片付けるので、見分けの手掛かりを残しておく。項目の数・並び・名前・
/// ⌥ の代わりの項目は AppKit のまま。
@MainActor
final class TabbedWindowCloseMenuRouter: NSObject, NSMenuItemValidation {
    static let shared = TabbedWindowCloseMenuRouter()

    private static let closeTabbedWindowGroupAction = NSSelectorFromString("performCloseTabbedWindowGroup:")
    private let tokens = NotificationObserverTokens()

    private override init() {
        super.init()
        tokens.add(NotificationCenter.default.addObserver(
            forName: NSMenu.didAddItemNotification, object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, let menu = notification.object as? NSMenu else { return }
                for item in menu.items where item.action == Self.closeTabbedWindowGroupAction && item.target !== self {
                    item.target = self
                }
            }
        })
    }

    /// AppKit の「ウインドウを閉じる」の中身の差し替え。
    @objc func performCloseTabbedWindowGroup(_ sender: Any?) {
        guard let window = NSApp.keyWindow else { return }
        BookClosingWindowDelegate.closeWindowWithAllTabs(
            window, preferences: (NSApp.delegate as? AppDelegate)?.preferences
        )
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        NSApp.keyWindow != nil
    }
}
