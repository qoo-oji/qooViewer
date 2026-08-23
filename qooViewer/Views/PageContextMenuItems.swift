import SwiftUI

/// 1ページ(サムネイル1枚)を右クリックしたときに出すメニューの中身。
///
/// ユーザー要望: サイドパネルのページモード・本の中身ブラウザ、およびページ一覧パネルの
/// サムネイルで、「Finderで開く」と「画像をエクスポート」を使えるようにしたい。
/// **3箇所で内容と挙動を必ず揃える**(要望の明示的な指示)ため、項目の並びも有効条件も
/// このビュー1つに集約している。どこかに項目を足すときは、ここへ足せば3箇所に同時に出る。
///
/// 判断そのもの(何をFinderで示すのか/書き出しの導線が要るのか)は`PageFileAccess`が持つ。
struct PageContextMenuItems: View {
    let page: PageRef
    /// 本そのものの場所。入れ子のアーカイブのページで、一時ファイルではなく本を指すために使う
    /// (PageFileAccess.revealTargetURL(for:bookSourceURL:)参照)。
    let bookSourceURL: URL?
    /// 「画像をエクスポート」が選ばれたときに呼ぶ。nilなら項目自体を出さない
    /// (本を開いていない・書き出しの橋渡しがまだ張られていない場合)。
    var onExport: (() -> Void)?

    /// このページに既にブックマークが付いているか。項目の文言を「追加」「削除」で切り替える
    /// (ユーザーの指示)。ツールバー・メニューバー・ビューアの右クリックと同じトグルの作法で、
    /// **文言そのものが登録状態を伝える** ―― ページ一覧パネルにはブックマークの印が無いため、
    /// ここだけは文言が唯一の手がかりになる。
    var isBookmarked = false

    /// falseなら、ブックマークの項目を出したまま無効にする(シークレットウインドウと、
    /// 画像を直接開いたその場限りの本)。それらのウインドウでは登録・編集の項目を
    /// 「消す」のではなく「グレーアウトする」のが、このアプリ全体の約束
    /// (AppState.isPrivateWindowのコメント参照)。
    var allowsBookmarking = true

    /// ブックマークの追加/削除。nilなら項目自体を出さない(橋渡しがまだ張られていない場合。
    /// onExportと同じ扱い)。実装はViewerView.toggleBookmark(atIndex:)で、常にこの1ページ
    /// だけを対象にする(見開きの相方ページには触れない)。
    var onToggleBookmark: (() -> Void)?

    var body: some View {
        // ページそのものへの操作なので、ファイル側の操作(Finder・書き出し)より前に置き、
        // 区切り線で分ける。
        if let onToggleBookmark {
            Button(isBookmarked ? "Remove This Page from Bookmarks" : "Add This Page to Bookmarks") {
                onToggleBookmark()
            }
            .disabled(!allowsBookmarking)
            Divider()
        }
        Button("Show in Finder") {
            FinderReveal.reveal(PageFileAccess.revealTargetURL(for: page, bookSourceURL: bookSourceURL))
        }
        // 書庫やPDFの中の画像は、Finderで示せるのが入れ物のファイルだけなので、
        // 代わりに1枚を取り出す導線を置く(逆に、フォルダの本の画像はFinderで実物を
        // 選択できるので、この項目は出さない。PageFileAccess.isInsideContainer参照)。
        if PageFileAccess.isInsideContainer(page), let onExport {
            Button("Export Image…") {
                onExport()
            }
        }
    }
}
