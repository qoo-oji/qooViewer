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

    var body: some View {
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
