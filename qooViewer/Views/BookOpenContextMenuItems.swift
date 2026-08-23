import SwiftUI

/// 「本1冊」を表す行を右クリックしたときに出す、開き方の項目群。
///
/// ユーザー要望: サイドパネルのフォルダブラウザ・履歴・お気に入り、および「お気に入りの
/// 編集」「ブックマーク・レイアウトの編集」ウインドウの本の行から、開く先を選べるようにする。
/// **5箇所で内容と並びを必ず揃える**ため、`PageContextMenuItems`(ページ1枚を右クリック
/// したときのメニュー)と同じ考え方で、このビュー1つに集約している。どこかに項目を足すときは
/// ここへ足せば5箇所に同時に出る。
///
/// 並びはファイルメニューの「新しいウインドウで開く…」→「新しいタブで開く…」と同じく
/// **ウインドウが先、タブが後**(Safari/Chromeのリンクの右クリックとは逆だが、このアプリの
/// 中での一貫性を優先。ユーザーの指示)。
///
/// ■ このクロージャの中でディスクを触らないこと
/// SwiftUIの`.contextMenu`の中身は、右クリックした瞬間ではなく**行の本体評価の一部として**
/// 組み立てられる(SidePanelContextMenuHighlightの型コメント参照)。項目の出し分けに使う
/// 判定は、呼び出し側があらかじめ確定値として持っておくこと ―― フォルダブラウザが
/// `DirectoryBrowser.Entry.containsImageFile`を一覧の読み込み時に確定させているのはそのため。
///
/// ■ 「新規シークレットウインドウで開く」を常に出す理由
/// 環境設定「シークレットモードで起動」の値や、今のウインドウがシークレットかどうかに
/// 関わらず、3項目とも常に同じ並びで出す。ファイルメニューの「新規ノーマルウインドウ」/
/// 「新規シークレットウインドウ」を常に両方並べているのと同じ理由で、**名前だけでどちらが
/// 記録の残るウインドウか分かる**ようにするため(QooViewerApp.swiftの該当箇所のコメント参照)。
struct BookOpenContextMenuItems: View {
    /// 「開く」(今のウインドウでそのまま開く)。nilならその項目と続く区切り線を出さない
    /// ―― 呼び出し側が既に自前の「開く」を持っている場合に使う。
    var onOpen: (() -> Void)?
    /// 「新規◯◯で開く」が選ばれたときに呼ぶ。実際に開くのは`BookWindowOpener.open`。
    let onOpenIn: (BookOpenDestination) -> Void

    var body: some View {
        if let onOpen {
            Button("Open") { onOpen() }
            Divider()
        }
        Button("Open in New Normal Window") { onOpenIn(.newNormalWindow) }
        Button("Open in New Private Window") { onOpenIn(.newPrivateWindow) }
        // タブだけノーマル/シークレットを選ばせない理由はBookOpenDestination.newTabのコメント参照
        // (このタブは、今のウインドウの性質をそのまま引き継ぐ)。
        Button("Open in New Tab") { onOpenIn(.newTab) }
    }
}
