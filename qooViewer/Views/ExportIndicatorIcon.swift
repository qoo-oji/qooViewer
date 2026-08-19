import SwiftUI

/// EPUB出力・PDF出力ウインドウの一覧の右端に並ぶ、「この本が何を持っているか」を示す
/// インジケータのアイコン1つ分。
///
/// バグ修正(ユーザー報告: エクスポート画面でインジケータの列が一直線に並ばない):
/// 以前は各アイコンを次のように書いていた。
///
/// ```swift
/// Group {
///     if row.hasBookmarks {
///         Image(systemName: "bookmark.fill")
///     }
/// }
/// .frame(width: 16)
/// ```
///
/// 一見すると、条件が偽のときも16ptのスロットが確保されるように読める。しかし
/// `Group`の中身が空になった場合に出来上がるのは`EmptyView`で、SwiftUIはこれを
/// 「レイアウトに一切参加しないもの」として扱う。`.frame(width:)`を付けても幅は確保されず、
/// HStack上では文字どおり存在しないものとして詰められる。その結果、
/// 「レイアウトのアイコンが無い行では、ブックマークのアイコンが1つ手前の位置へ動く」という
/// 形で、行ごとにアイコンの縦の並びが揃わなくなっていた(実測で確認)。
///
/// アイコンを出す/出さないを`if`で切り替えるのではなく、常に同じ大きさのスロットを描き、
/// 見せないときは`opacity`で透明にすることで、どの組み合わせでも位置が動かないようにする。
///
/// ツールチップ(`help`)は実際に表示されているときだけ付ける。透明なスロットにツールチップが
/// 付いていると、何も無いように見える場所にカーソルを置いたときだけ説明が出てしまうため。
/// 表示・非表示のどちらの分岐も同じ`frame`を通るので、この出し分け自体はレイアウトに影響しない。
struct ExportIndicatorIcon: View {
    let systemName: String
    let isOn: Bool
    let help: LocalizedStringKey

    /// アイコン1つ分のスロット幅と、スロット同士の間隔。呼び出し側(各出力ウインドウ)が
    /// インジケータ領域全体の幅を算出するのにも使う。
    static let slotWidth: CGFloat = 16
    static let slotSpacing: CGFloat = 6

    /// アイコンをn個並べたときの領域の幅。
    static func totalWidth(iconCount: Int) -> CGFloat {
        guard iconCount > 0 else { return 0 }
        return slotWidth * CGFloat(iconCount) + slotSpacing * CGFloat(iconCount - 1)
    }

    var body: some View {
        let icon = Image(systemName: systemName)
            .foregroundStyle(.secondary)
            .opacity(isOn ? 1 : 0)
            .frame(width: Self.slotWidth)
        if isOn {
            icon.help(help)
        } else {
            // 透明なスロットは、VoiceOver等の読み上げ対象からも外しておく。
            icon.accessibilityHidden(true)
        }
    }
}
