import SwiftUI

/// ウインドウが後ろ(キーでない)のとき、**ホームの操作の帯と左ペインを薄くし、中身は濃いまま**にする
/// (2026-09-30、利用者の指摘「薄くなるものとならないものが混在している」と判断「Finder 基準で揃える」)。
///
/// ■ それまで
/// 薄くなるかどうかを決めている所はどこにも無く、部品の種類で結果が分かれていた(macOS 27 で実測。部品だけの検証アプリ):
/// - `.sourceList` 形式の `NSOutlineView`(ファイルブラウザの左のツリー) → AppKit がセルの `textField` / `imageView` を **50%** にする
///   (セルに足したボタンは濃いまま ―― 見出しの「＋」は `FileBrowserTreeView.GroupCellView` が自分で合わせる)
/// - SwiftUI の文字・ボタン(`.plain` / `.borderless` / `.link` / 標準のベゼル)・`Menu`・ふつうの `NSTableView` → **何も変わらない**
///   (変わるのはアクセント色だけ: スライダー・チェックボックス・`.borderedProminent` が灰色になる)
/// つまり後ろへ回ると、ファイルブラウザの左ペインだけが薄くなり、同じ役割のスマートライブラリの左ペインも、上の帯も、
/// 各画面の操作列も濃いままだった。
///
/// ■ 決まり(Finder と同じ分け方)
/// - **薄くする**(Finder のツールバーとサイドバーに当たるもの): ホームのいちばん上の帯、各画面の操作列(戻る・名前・検索欄・
///   並べ替え・表示切替・大きさのスライダーなど)、左ペイン(ファイルブラウザのツリー = AppKit まかせ、スマートライブラリの左ペイン)、
///   旧ウェルカム画面の「直前の本へ戻る」(帯の左端の代わり)
/// - **薄くしない**(Finder の中身に当たるもの): カバー・タイルとその題名、リストの行と列の見出し、空のときの案内、
///   ファイルブラウザのパスバーと進捗の帯、旧ウェルカム画面の中央の塊
/// 選択の色(アクセント色 → 灰色)は従来どおり `SelectionEmphasis` が決め、薄くする所ではその上からさらに薄くなる。
///
/// ■ 濃さと契機
/// 濃さは AppKit のツリーと同じ 50%(並んだときに同じ薄さになる)。契機は `appearsActive` ―― ツリーが薄くなる契機と一致する
/// ことを実測した(別のウインドウがキー・アプリが後ろ・**このウインドウにシートが出ている間**はどちらも薄く、ポップオーバーを
/// 出しただけでは薄くならない)。
///
/// ■ ドロップの受け口
/// ドラッグを受けるウインドウは後ろにあるのがふつうなので、受け口の強調は薄くしない(`SelectionEmphasis` の型コメントと同じ理由)。
/// 薄くする区画の中に受け口があるときは、乗っている間だけ `unless:` でその区画を濃く戻す。
///
/// ホームに新しい帯・操作列・左ペインを足したら、その入れ物に `.dimsInInactiveWindow()` を付ける。付け忘れても濃いまま残るだけ。
enum InactiveWindowDimming {
    /// 後ろのウインドウでの濃さ(`.sourceList` のツリーの実測値と同じ)。
    static let opacity: Double = 0.5
}

/// ウインドウの状態は自分で読む(呼び出し側の大きな `body` を、ウインドウの前後が変わるたびに作り直させない。
/// `SelectionEmphasisBorder` と同じ理由)。
private struct DimsInInactiveWindow: ViewModifier {
    let isSuspended: Bool
    @Environment(\.appearsActive) private var appearsActive

    func body(content: Content) -> some View {
        content.opacity(appearsActive || isSuspended ? 1 : InactiveWindowDimming.opacity)
    }
}

extension View {
    /// 後ろのウインドウではこの区画を薄くする(`InactiveWindowDimming` の決まり)。
    /// - Parameter suspended: true の間は薄くしない(区画の中のドロップの受け口にドラッグが乗っている間)。
    func dimsInInactiveWindow(unless suspended: Bool = false) -> some View {
        modifier(DimsInInactiveWindow(isSuspended: suspended))
    }
}
