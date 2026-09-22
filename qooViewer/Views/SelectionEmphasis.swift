import AppKit
import SwiftUI

/// 選択・現在地の強調色。**macOS 標準に合わせ、ウインドウが前(キー)のときだけアクセント色、後ろでは灰色**
/// (2026-09-19、ユーザー判断「乙」)。
///
/// ■ それまで
/// 選択の地・枠・印はウインドウの状態を見ずに常にアクセント色だった(「灰色にすると面の色によっては選択が見えなくなる」
/// という理由)。ところがファイルブラウザの左のツリーだけは`.sourceList`形式で AppKit が自動で淡くするので、
/// **ウインドウが後ろに回ると左ペインの文字だけが灰色になり、右ペインと選択の色はそのまま**という食い違いが出た
/// (ユーザー報告)。どちらかに揃える必要があり、標準の側へ揃えた。面の色に溶ける件は、灰色の選択にも
/// アクセント色のときと同じ反対色の縁(`.panelOutlinedAccent(in:)` / `FileBrowserRowView`)を掛けて防ぐ。
///
/// ■ 何に使うか / 使わないか
/// - 使う: 選択(行・カバー・チップ・モードの切り替え)と「いまここ」(現在の本・ページ・しおり)の強調
/// - 使わない: ドロップの受け口(ドラッグを受けるウインドウは後ろにあるのがふつうで、Finder も後ろのウインドウで
///   アクセント色の強調を出す)、状態の色(残っているページ・登録済みのメタデータなど ―― 選択ではない)
///
/// SwiftUI では`@Environment(\.appearsActive)`を読んで渡す。AppKit の行は`NSTableRowView.isEmphasized`
/// (キーウインドウかつ表がファーストレスポンダ)で決まる。
enum SelectionEmphasis {
    /// 枠・印・薄い重ね(`.opacity(…)`を掛けて使う)・文字に使う強調色。
    static func tint(isActive: Bool) -> Color {
        isActive ? Color.accentColor : Color(nsColor: .systemGray)
    }

    /// 塗りつぶしの地(選択中のチップ・モードボタン)。後ろでは標準の「強調されていない選択」の地。
    static func fill(isActive: Bool) -> Color {
        isActive ? Color.accentColor : Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
    }

    /// `fill(isActive:)` の上の文字・アイコンの色。
    static func foreground(isActive: Bool) -> Color {
        isActive ? Color.white : Color.primary
    }

    /// AppKit で描く選択の地(`FileBrowserRowView`・アイコン表示のセル)。
    static func selectionBackground(isEmphasized: Bool) -> NSColor {
        isEmphasized ? .controlAccentColor : .unemphasizedSelectedContentBackgroundColor
    }
}

/// 選択の枠(コレクションのタイル・本のカバー)。**ウインドウの状態は自分で読む** ―― 呼び出し側(グリッド全体)が
/// `appearsActive` を読むと、ウインドウの前後が変わるたびにグリッドの`body`がまるごと作り直される。
struct SelectionEmphasisBorder<S: InsettableShape>: View {
    let shape: S
    var lineWidth: CGFloat = 3
    /// 一覧がキーの行き先か(スマートライブラリのグリッド、2026-09-22)。false なら前のウインドウでも灰色
    /// (AppKit の一覧の `isEmphasized` と同じ。検索欄へ移ると選択が灰色になる)。
    var isFocused = true
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        shape.strokeBorder(SelectionEmphasis.tint(isActive: appearsActive && isFocused), lineWidth: lineWidth)
    }
}

/// 選択行・現在の行の薄い重ね(サイドパネルの一覧など)。ウインドウの状態は自分で読む(`SelectionEmphasisBorder`と同じ理由)。
struct SelectionEmphasisHighlight<S: Shape>: View {
    let shape: S
    var opacity: Double = 0.15
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        shape.fill(SelectionEmphasis.tint(isActive: appearsActive).opacity(opacity))
    }
}

/// 強調色を受け取って組む(形・線が`SelectionEmphasisBorder`に合わないところ)。ウインドウの状態は自分で読む。
struct SelectionEmphasisReader<Content: View>: View {
    @ViewBuilder let content: (Color) -> Content
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        content(SelectionEmphasis.tint(isActive: appearsActive))
    }
}

private struct SelectionEmphasisForeground: ViewModifier {
    let isOn: Bool
    let otherwise: Color
    @Environment(\.appearsActive) private var appearsActive

    func body(content: Content) -> some View {
        content.foregroundStyle(isOn ? SelectionEmphasis.tint(isActive: appearsActive) : otherwise)
    }
}

extension View {
    /// 「いまここ」の文字・アイコンの色。`isOn`なら強調色(ウインドウが後ろなら灰色)、そうでなければ`otherwise`。
    func selectionEmphasisForeground(_ isOn: Bool, otherwise: Color) -> some View {
        modifier(SelectionEmphasisForeground(isOn: isOn, otherwise: otherwise))
    }
}
