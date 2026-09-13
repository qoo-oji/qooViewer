import AppKit
import SwiftUI

/// ウェルカム画面の2つのグリッド(コレクションの札・コレクションの中のカバー)の列の割り付け。
///
/// ■ なぜ`.adaptive(minimum:)`をやめたのか(ユーザー要望 2026-09-13)
/// 以前はスライダーの値を`GridItem(.adaptive(minimum:))`の下限として渡していた。adaptiveは
/// 入るだけ列を作ってから**残りの幅を列へ配り直す**ので、札の実際の幅は「幅 ÷ 列数」で決まり、
/// スライダーを動かしても**列数が変わる瞬間にしか大きさが変わらない**(しかもその瞬間に跳ぶ)。
/// 「スライダー操作で無段階にスムーズに変化してほしい」という要望に合わせて、ページ一覧パネル
/// (ThumbnailGridView)と同じく**固定幅の列**にした。札はつまみの値ちょうどの幅で並び、
/// 列に収まらない余りはグリッドの左右に均等に空く。
///
/// 純粋な値の計算なので、テストから直接確かめられる。
struct WelcomeGridColumns: Equatable {
    /// 列の数(1以上)。
    let count: Int
    /// 1列の幅(= スライダーの値)。
    let itemWidth: CGFloat
    let spacing: CGFloat

    /// - Parameters:
    ///   - availableWidth: ScrollViewの幅(外周の余白を含む)。
    ///   - padding: グリッドの外周の余白(片側)。
    ///   - scrollerWidth: 縦のスクロールバーが中身の幅を削るぶん。nilならシステムの設定から
    ///     求める(常に表示するスクロールバーの設定のときだけ幅を持つ)。
    init(
        availableWidth: CGFloat, itemWidth: CGFloat, spacing: CGFloat, padding: CGFloat,
        scrollerWidth: CGFloat? = nil
    ) {
        let scroller = scrollerWidth ?? Self.systemScrollerWidth
        let usable = max(0, availableWidth - padding * 2 - scroller)
        let width = max(1, itemWidth)
        self.count = max(1, Int(((usable + spacing) / (width + spacing)).rounded(.down)))
        self.itemWidth = width
        self.spacing = spacing
    }

    /// 列を並べた幅(左右の余りを含まない)。
    var contentWidth: CGFloat {
        CGFloat(count) * itemWidth + CGFloat(count - 1) * spacing
    }

    func gridItems(alignment: Alignment) -> [GridItem] {
        Array(repeating: GridItem(.fixed(itemWidth), spacing: spacing, alignment: alignment), count: count)
    }

    /// 「スクロールバーを常に表示」の設定では、縦のスクロールバーが中身の幅を削る。
    /// 見込まないと最後の列がはみ出して右端が切れる(オーバーレイ表示なら0)。
    private static var systemScrollerWidth: CGFloat {
        NSScroller.preferredScrollerStyle == .legacy
            ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
    }
}

/// 検索に一致するものが無いときの案内(一覧・コレクションの中で共通)。
/// すりガラス面に直接置く文字なので輪郭を掛ける(CLAUDE.mdの表)。
struct WelcomeNoMatchesMessage: View {
    let textKey: LocalizedStringKey

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(textKey)
                .foregroundStyle(.secondary)
        }
        .panelOutlinedContent()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// ウェルカム画面の区切り線(改善要望7 段階3、2026-09-13)。帯の下・帯の中(ファイルブラウザとライブラリの間)・
/// ファイルブラウザの左右の間に使う。
///
/// ■ なぜ`Divider()`ではないのか
/// ユーザー指摘: すりガラスの面の上では標準の区切り線(`separatorColor`、ダークで白の約10%)が薄く、
/// 領域の境目が読み取りにくい。文字色を少し濃くした線にする。
///
/// ■ 輪郭(すりガラス面の決まりごと)
/// 線は文字色から作るので、面を文字色で塗りつぶすと線ごと消える。`.panelOutlinedContent()`で
/// 文字と同じ反対色の輪郭を付ける(線の形がそのまま太って縁取られる)。
struct WelcomeSeparator: View {
    enum Axis {
        /// 横に伸びる線(上下の区切り)。
        case horizontal
        /// 縦に伸びる線(左右の区切り)。
        case vertical
    }

    let axis: Axis
    /// 線の長さ。nil なら親の大きさいっぱい。
    var length: CGFloat?

    static let thickness: CGFloat = 1
    static let opacity: Double = 0.28

    var body: some View {
        let line = Rectangle().fill(Color.primary.opacity(Self.opacity))
        Group {
            switch axis {
            case .horizontal:
                line.frame(maxWidth: length ?? .infinity).frame(height: Self.thickness)
            case .vertical:
                line.frame(width: Self.thickness).frame(maxHeight: length ?? .infinity)
            }
        }
        .panelOutlinedContent()
        .accessibilityHidden(true)
    }
}
