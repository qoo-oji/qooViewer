import CoreGraphics
import SwiftUI

/// コレクション1つ分のタイル(改善要望5)。中身のカバーを敷き詰めた角丸の札で、クリックすると
/// その中へ入る。
///
/// ■ 割り付けはライブラリの縦横比で決まる
/// 2:3 なら3列2行で最大6冊、1:1 なら2列2行で最大4冊(CoverAspectRatio.tileColumns)。どちらも
/// **札全体がほぼ正方形になる**組み合わせで、縦横比の指定を別に書かなくても正方形に落ち着く
/// ので、タイルの大きさはスライダーの値(LazyVGridの`.adaptive(minimum:)`)にそのまま従わせられる
/// (計算はCoverAspectRatio.tileColumnsのコメント)。
///
/// ■ 編集モードでは「選ぶ」
/// 編集モード中はクリックが**中へ入る**から**選ぶ/選び直す**に変わり、左上に選択の印
/// (SelectionCheckmarkBadge)が出る。選んだコレクションは右上のゴミ箱でまとめて削除できる。
/// 編集モード中に中へ入りたいときは右クリックの「開く」から(CollectionGridView)。
///
/// ■ 輪郭(すりガラス面の決まりごと)
/// - カバー画像・自前の地を持つ冊数バッジ・選択の印 → 何も付けない
/// - 札の下に置く名前 → `.panelOutlinedContent()`
/// - 選択中を示すアクセント色の枠 → `.panelOutlinedAccent(in:)`(面をアクセント色で
///   塗られると、枠だけが頼りの「選んである」が地に溶けるため)
struct CollectionTile: View {
    let collection: BookCollection
    /// 表示する本(並び替え済み)。先頭`aspectRatio.tileCellCount`冊だけを描く。
    let items: [CollectionItem]
    /// この本の実体が見つかっているか。
    let exists: (CollectionItem) -> Bool
    /// いま抽出中か。
    let isExtracting: (CollectionItem) -> Bool
    /// この本のカバーで残す位置(本ごとの上書き ?? ライブラリの既定)。
    let cropAnchor: (CollectionItem) -> CoverCropAnchor
    let coverStore: CollectionCoverStore
    /// このライブラリのカバーの縦横比。セルの形とここの割り付けの両方がこれで決まる。
    let aspectRatio: CoverAspectRatio
    /// 札の地の色(ライブラリの設定。既定は明暗どちらにも馴染む薄い地)。
    var backgroundColor: Color = Color.primary.opacity(0.07)
    /// タイルの一辺の目安(スライダーの値)。角丸とセルの復号サイズの見積もりに使う。
    let size: CGFloat
    /// 札の下に出す名前の文字の大きさ(pt。環境設定「外観」→「ウェルカム画面」)。
    /// 既定の13ptは、設定にする前の`Text`の既定(macOSの`.body`)そのもの。
    var nameFontSize: CGFloat = 13
    var onImageRetained: ((CGImage) -> Void)?
    /// 編集モードか。クリックの意味(開く/選ぶ)がこれで変わる。
    var isEditing: Bool = false
    var isSelected: Bool = false
    let onOpen: () -> Void
    /// 編集モード中のクリック。
    var onToggleSelection: () -> Void = {}

    /// セルの間隔(ユーザー指摘 2026-09-09で3ptから広げた ―― 詰まりすぎて、6冊が1枚の
    /// 大きな絵のように見えていた)。
    ///
    /// 札がぴったり正方形にならないのはこの値のぶん(CoverAspectRatio.tileColumnsの計算)なので、
    /// 広げるほど正方形から離れる。180ptの札で6ptのずれ = 3%程度なので、並べたときに気づく差には
    /// ならない。
    private static let cellSpacing: CGFloat = 6
    /// 札の内側の余白。セルの間隔より狭いと、外周だけが窮屈に見えるので少し広く取る。
    private static let padding: CGFloat = 8

    /// セル1つの実寸の見積もり(復号サイズの上限にだけ使う。実際の割り付けはGridが決める)。
    private var cellWidth: CGFloat {
        let columns = CGFloat(aspectRatio.tileColumns)
        return (size - Self.padding * 2 - Self.cellSpacing * (columns - 1)) / columns
    }

    /// 札の角丸。選択の枠も同じ形で描く。
    private var cornerRadius: CGFloat { size * 0.08 }

    var body: some View {
        VStack(spacing: 6) {
            Button {
                if isEditing {
                    onToggleSelection()
                } else {
                    onOpen()
                }
            } label: {
                artwork
            }
            .buttonStyle(.plain)

            Text(collection.name)
                .font(.system(size: nameFontSize))
                .lineLimit(1)
                .truncationMode(.middle)
                .panelOutlinedContent()
        }
        .help(collection.name)
    }

    private var artwork: some View {
        Grid(horizontalSpacing: Self.cellSpacing, verticalSpacing: Self.cellSpacing) {
            ForEach(0..<aspectRatio.tileRows, id: \.self) { row in
                GridRow {
                    ForEach(0..<aspectRatio.tileColumns, id: \.self) { column in
                        cell(row * aspectRatio.tileColumns + column)
                    }
                }
            }
        }
        .padding(Self.padding)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(backgroundColor)
        )
        // 冊数バッジ。自前の塗り地を持つので輪郭は付けない(すりガラス面の決まりごとの例外側)。
        .overlay(alignment: .bottomTrailing) {
            Text("\(collection.items.count)")
                .font(.caption)
                .monospacedDigit()
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.black.opacity(0.55))
                .foregroundStyle(Color.white)
                .clipShape(Capsule())
                .padding(6)
        }
        // 選択中の枠。印だけだと、札が小さいときにどれを選んだのか一目で分からない。
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 3)
                .opacity(isSelected ? 1 : 0)
        }
        .panelOutlinedAccent(
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
            isEnabled: isSelected
        )
        // 選択の印。編集モードのときだけ出す。
        .overlay(alignment: .topLeading) {
            if isEditing {
                SelectionCheckmarkBadge(isSelected: isSelected, size: size)
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func cell(_ index: Int) -> some View {
        if index < items.count {
            let item = items[index]
            CollectionCoverThumbnail(
                item: item,
                coverStore: coverStore,
                aspectRatio: aspectRatio,
                anchor: cropAnchor(item),
                displayWidth: cellWidth,
                exists: exists(item),
                isExtracting: isExtracting(item),
                onImageRetained: onImageRetained
            )
        } else {
            // 枠を埋めきらないぶんは、同じ大きさの空きとして残す(詰めて並べると、冊数によって
            // 札の中の割り付けが変わり、一覧が揃って見えない)。
            Color.clear
                .aspectRatio(aspectRatio.value, contentMode: .fit)
        }
    }
}
