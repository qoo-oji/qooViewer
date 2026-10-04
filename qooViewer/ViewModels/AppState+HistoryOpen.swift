import SwiftUI

extension AppState {
    /// 履歴(メニューバー「ファイル」→「最近使った項目を開く」、サイドパネルの「履歴」モード)から本を開く
    /// (2026-09-28、利用者の要望)。環境設定「本を開く」の「履歴から」(`AppPreferences.historyOpenBehavior`)に従い、
    /// 「Finderから」「お気に入りから」と同じ考え方で分岐する:
    /// - まだ本を表示していない(ホーム)なら、設定に関わらずこのウインドウで開く(閉じるべき「現在の本」が無い)
    /// - 本を表示中なら、この本を閉じて開く / 新規タブ / 新規ウインドウ(シークレットかどうかはこのウインドウを引き継ぐ。
    ///   `BookWindowOpener`)
    ///
    /// ホームの「履歴から開く」ポップオーバーと以前のウェルカム画面の「最近開いた本」は、本を開いていないウインドウにしか
    /// 無いので、ここを通さず `open(url:)` のまま(結果は同じ)。
    ///
    /// - Returns: このウインドウで開いた(置き換えた)なら true。呼び出し側がサイドパネルを閉じるかどうかの判断に使う
    ///   (別のタブ/ウインドウに開いたときは、一覧から次々に開けるようパネルを残す。`SidePanelView.onOpenInNewWindow` と同じ)。
    ///
    /// - Parameter intent: 履歴の解決を待つ前に取った開く意図(`historyOpenReplacesCurrentBook` のときだけ。AppState.OpenIntent、
    ///   2026-10-04 のレビューの R6-1)。この窓で開くときに照合する。
    @discardableResult
    func openFromHistory(
        _ url: URL, intent: OpenIntent? = nil, launchCoordinator: LaunchCoordinator, openWindow: OpenWindowAction
    ) -> Bool {
        let destination: BookOpenDestination
        switch Self.historyOpenDestination(hasOpenBook: currentBook != nil, preference: preferences?.historyOpenBehavior ?? .replaceCurrentBook) {
        case nil:
            open(url: url, intent: intent)
            return true
        case .some(let wanted):
            destination = wanted
        }
        BookWindowOpener.open(
            BookOpenRequest(url), to: destination, from: self, launchCoordinator: launchCoordinator, openWindow: openWindow
        )
        return false
    }

    /// 履歴から開くと、この窓の本を置き換えるか(`openFromHistory` と同じ分岐)。置き換えるなら、解決を待ち始めるときに開く意図を
    /// 進める(後から頼んだ方が勝つ。新しいタブ・ウインドウへ開くなら、この窓の本とは競わない。2026-10-04 のレビューの R6-1)。
    var historyOpenReplacesCurrentBook: Bool {
        Self.historyOpenDestination(
            hasOpenBook: currentBook != nil, preference: preferences?.historyOpenBehavior ?? .replaceCurrentBook
        ) == nil
    }

    /// 履歴から開く先。nil は「このウインドウで開く(置き換える)」。本を表示していなければ設定に関わらず nil。
    nonisolated static func historyOpenDestination(hasOpenBook: Bool, preference: FinderOpenBehavior) -> BookOpenDestination? {
        guard hasOpenBook else { return nil }
        switch preference {
        case .replaceCurrentBook: return nil
        case .newTab: return .newTab
        case .newWindow: return .newWindow
        }
    }
}
