import Foundation

/// 利用者が本 1 冊ぶんの「レイアウト」「ブックマークとレイアウト」を消す操作と、書き出し後の片付けが、**何を消すか**の一か所。
///
/// 消すのは狭義のレイアウト(読み方向・見開き・ページ順・ページ単位の設定 ―― `LayoutStore.discardPageLayout`)で、コレクション表紙・
/// 切り出し位置・書き出し用のカバー・補正は残す(2026-10-04 の監査 BE-2 / §3 の決定 7。以前は呼び出し側がそれぞれ行ごと消して
/// いた)。呼び出し側(ブックマーク・レイアウトの編集ウインドウの 2 つの確認、`ViewerView.cleanUpExportedBook`)からここを通すのは、
/// テストが**呼び出し側の選んだ消し方**を確かめられるように(2026-10-04 のレビューの R1-4 ―― 以前のテストは
/// `discardPageLayout` そのものを見ていて、呼び出し側が行ごと消す形に戻っても通った)。
@MainActor
enum BookDataDeletion {
    /// 「レイアウトをすべて削除」(確認の後)。
    static func deleteLayout(forBookID bookID: String, layoutStore: LayoutStore) {
        layoutStore.discardPageLayout(forBookID: bookID)
    }

    /// 「ブックマークおよびレイアウトをすべて削除」(確認の後)。
    static func deleteBookmarksAndLayout(
        forBookID bookID: String, bookmarkStore: BookmarkStore, layoutStore: LayoutStore
    ) {
        bookmarkStore.deleteAllBookmarks(forBookID: bookID)
        layoutStore.discardPageLayout(forBookID: bookID)
    }

    /// 書き出した本の保存データの片付け(環境設定の書き出しの「保存データ」が「削除」のとき)。お気に入り・コレクション・
    /// コレクション表紙は残す(設定の説明文のとおり)。読書位置は開いているビューアが行を握っているので、呼び出し側が
    /// `ViewerViewModel.discardReadingState()` で消す(ここで消すと、消した行へページ送りのたびに書き込もうとする)。
    static func deleteAfterExport(
        forBookID bookID: String, bookmarkStore: BookmarkStore, layoutStore: LayoutStore,
        metadataStore: BookMetadataStore
    ) {
        bookmarkStore.deleteAllBookmarks(forBookID: bookID)
        layoutStore.discardPageLayout(forBookID: bookID)
        metadataStore.delete(forBookID: bookID)
    }
}
